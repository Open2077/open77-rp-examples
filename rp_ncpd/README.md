# rp_ncpd — the NCPD

The police of the Night City RP build (Open77 build `2.31.13+op77.76`): cuff / uncuff / escort,
search and seizure, fines the citizen accepts or refuses, seating a suspect in the cruiser, jail
time that survives a disconnect, criminal records, warrants with a level, a dispatch radio and
alerts other resources can raise.

**Server-authoritative.** Every action needs the job `ncpd` **and** `rp_jobs onDuty` — the server
checks both on every command and every ALT+click request; the client only shows the actions to an
officer, blocks the weapon wheel of a prisoner and draws alert pins. Holds are the platform's
`open77_rp_basics` (never reimplemented), money goes through `rp_bank` (society `ncpd`) and
`rp_economy` (cash), pockets through `rp_inventory`, names through `rp_identity`.

## Setup

1. Load list (`resources.load`): `open77_contextmenu`, `open77_uikit`, `open77_player_interactions`,
   `open77_notifications` (declared dependencies, all ship a client half), **`open77_rp_basics`**
   (the RP kit ships `auto_start false` — add it explicitly, or `ensure open77_rp_basics`),
   `rp_jobs` v2, `rp_zones`, `rp_inventory`, `rp_bank`, `rp_economy`, `rp_identity` (reached
   through `pcall`, each degrades to a chat line when missing).
2. **The RP kit's ACL gate.** `open77_rp_basics` answers `not_authorised` unless the officer's
   account holds `rp.cuff`, `rp.escort` and `rp.search`. Give them to the police accounts once in
   `acl.jsonc` (`permissions: ["rp.cuff", "rp.escort", "rp.search"]` on the principal, then
   `acl.reload`), **or** set `Config.grantKitRights = true` and add `"acl.grant:rp.*"` to the
   manifest permissions: the resource then grants the three rights when an officer clocks in and
   revokes them when they clock out (the devkit validator 0.1.x rejects that scoped permission as
   unknown although the ACL guide documents it, which is why it ships off).
3. Positions live in `shared/config.lua`. The precinct is the **real NCPD building** in the
   city centre: the conference room (AMM `-1761.5, -1010.8, 94.3`) is the `ncpd_hq` zone centre
   of `rp_zones` (radius 30); the cell is 6 m east of it (`-1755.5, -1010.8, 94.3`), the desk —
   where a released prisoner is put (`Config.entrance`) — 4 m north (`-1761.5, -1006.8, 94.3`).
   It is 3.1 km south of the freeroam spawn (Kabuki Market Centre `-1191.30, 2006.88, 7.82`):
   cops drive. A **Kabuki-side patrol outpost** (`Config.outpost`) marks the real street outside
   the Afterlife ramp (`-1408, 960, 23.6`, probed crosswalk, 1.1 km south-west of the market):
   a ring + floating label on every client and, from the server, a keep-out sign
   (`sign.rect.keep_out`) and a road barrier (`barrier.road`) — curated prop aliases, see
   `prop.catalog` — (`Open77.props.create`, removed on stop) — a radio/status point for patrols, nothing
   to press. **If a prisoner lands in the ground**, stand on the spot, `/pos`, and paste the
   height into `Config.cell.z` / `Config.entrance.z`.
4. Job: `setjob <id> ncpd 3` from the console, then `/service` in game.

## Commands (all need job `ncpd` + on duty, except `/amende payer`)

| Command | What it does |
|---|---|
| `/menotter <id>` | Cuffs the player (`open77_rp_basics:cuff`): frozen, hands up, controls taken. Within 3 m. |
| `/demenotter <id>` | Releases the kit's hold (cuff or escort). |
| `/escorter <id>` | Escorts the player (a leash: they walk, tethered to you). The same command again stops it. |
| `/fouille <id>` | Searches a player who is **cuffed or has hands up** (`handsup` RP profile): lists the pockets (`rp_inventory:list`) and names the contraband. `/fouille <id> saisir` **seizes** every illegal item into your pockets (`rp_inventory:remove` + `add`, both told). `implant_box` is legal on a Trauma medic. |
| `/amende <id> <amount> <reason>` | Offers a fine (1–100 000 €$). The citizen answers `/interaction accept` or `/interaction decline` (`open77_player_interactions`, 30 s). Accepted → `rp_bank:charge(citizen, amount, "ncpd", "fine:<reason>")`; account short → cash for what is there (`rp_economy:remove`, credited to the society) and the remainder is an **unpaid fine row** plus a level-1 warrant; declined / no answer → a warrant. |
| `/amende payer` | Anyone: pays your unpaid fines, cash first then account, oldest first; the automatic warrant is lifted when nothing is left. |
| `/embarquer <id>` | Puts the player into your cruiser (`Open77.vehicles.warpPlayerIntoVehicle`, back seat first, door locked), or takes them out if they are seated (`forcePlayerOutOfVehicle`). You must be within 5 m of a **server-spawned** vehicle (the one you drove up in, `/car`) or seated in it. |
| `/prison <id> <minutes>` | 1–120 minutes: contraband destroyed at booking, hold released, teleport to `Config.cell`, weapon wheel and trigger blocked on their client, a toast every minute, automatic release to `Config.entrance`. The sentence is in `rp_ncpd_sentences`: a disconnect pauses it, it resumes on reconnect. A prisoner who walks more than 6 m from the cell or gets into a vehicle is put back. Raises `rp_ncpd:arrest`. |
| `/liberer <id>` | Releases a prisoner early. |
| `/casier <id>` | Criminal record: warrant, unpaid fines, current sentence, then the last 20 entries (`date [KIND] text - officer <RP name>`): fines, arrests, warrants, seizures, releases. |
| `/mandat <id> [level 1-5] <reason>` | Warrant on a player (level 1 when omitted). `/mandat lever <id>` lifts it. Stored in `rp_ncpd_warrants`; with `Config.warrant.nativeHeat = true` the level is also pushed as the player's native NCPD heat (`Open77.players.setWanted`, off by default: native police are local AI). |
| `/ncpd` | Precinct status: officers on duty, open warrants (name, level, reason), prisoners with their time left. Needs the job (duty not required). |
| `/ncpd <text>` | Radio line to every on-duty officer, tagged `[NCPD RADIO] <your name>`. On-duty officers are also put in the `NCPD dispatch` **voice** channel (`Open77.voice.createChannel` mode `radio` + `addPlayer`) when the server's voice is on. |

Refusals are explained in chat: not NCPD, off duty, too far (with the distance), not cuffed nor
surrendering, no vehicle within 5 m, no free seat, kit not running / not authorised, and so on.
From the server console every command answers that it must be run from the game (`/ncpd` prints
the status).

## ALT+click (open77_contextmenu)

Hold **ALT**, click a player: **Cuff**, **Uncuff**, **Escort / stop escorting**, **Search**,
**Seize contraband** (confirmation dialog), **Fine** (dialog: amount + reason), **Put in / take
out of vehicle**, **Jail** (dialog: minutes), **Release from cell**, **Criminal record**. The
entries are shown only while the server says you are an on-duty officer; the server checks
again on every request (`rp_ncpd:action`).

## Exports (server, synchronous — never yield)

```lua
exports.rp_ncpd:isOnDuty(playerId)                  -- boolean: job ncpd AND rp_jobs onDuty
exports.rp_ncpd:wanted(playerId)                    -- { level, reason } | nil
exports.rp_ncpd:setWanted(playerId, level, reason)  -- true | nil, reason   (0 lifts the warrant)
exports.rp_ncpd:record(playerId)                    -- { entries = { { kind, text, officer, at, date }, ... } } newest first
exports.rp_ncpd:addRecord(playerId, kind, text, byPlayerId)  -- true | nil, reason  (kind: ^[a-z_]+$)
```

Reasons: `player_not_found`, `invalid_level` (0..5), `no_warrant`, `invalid_kind`,
`invalid_identifier`. Call them inside `pcall`; a resource **with** a client script must not
declare `dependency "rp_ncpd"` (this manifest is delivered to clients).

## Events (host bus)

```lua
-- raised by OTHER resources (rp_shop, rp_bank, rp_trauma...); consumed here:
TriggerEvent("rp_ncpd:alert", "robbery", { x = -1201.1, y = 2035.6, z = 5.6 }, "Lower Walkway dealer hit", byPlayerId)
--> chat line `[NCPD DISPATCH] ROBBERY: ... (distance)` + toast to every on-duty officer, and a
--> temporary map pin (60 s) on their maps (client relay: the blip API is client-only on this build)

-- raised here after /prison:
AddEventHandler("rp_ncpd:arrest", function(playerId, byPlayerId, minutes) end)
```

Internal net events (`rp_ncpd:action`, `rp_ncpd:clientReady`, `rp_ncpd:self`, `rp_ncpd:jailed`,
`rp_ncpd:alertBlip`) are this resource's client/server transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS` (permission
`database.access`), keyed by `Open77.players.identifier` (never the session id):

| Table | Columns |
|---|---|
| `rp_ncpd_records` | `id`, `identifier`, `kind`, `text`, `officer` (identifier), `officer_name` (RP name), `created_at` |
| `rp_ncpd_warrants` | `identifier` (PK), `level`, `reason`, `kind` (`manual` / `fine`), `officer`, `officer_name`, `citizen_name`, `created_at` |
| `rp_ncpd_fines` | `id`, `identifier`, `amount`, `remaining`, `reason`, `officer`, `officer_name`, `created_at`, `paid_at` |
| `rp_ncpd_sentences` | `identifier` (PK), `remaining` (seconds), `total_minutes`, `officer`, `officer_name`, `started_at` |

Records and unpaid fines are cached per online player (read on `onPlayerReady`), warrants for
everyone at boot, sentences per player; every change is written through with the callback forms,
so the exports never touch the database. A sentence is persisted every minute and on disconnect.
**No database** (`ready` answers `database_unavailable`, or nothing answers 15 s after the first
player): `Open77.kvp` (`rec:<id>`, `fines:<id>`, `sentence:<id>`, `warrants`) and the log says
`store=kvp reason=...`.

## Honest limits (measured against the devkit, not guessed)

- **Vehicle entry cannot be blocked** on 2.31 (`EnterVehicle` is not in the input vocabulary): a
  jailed player who gets into a vehicle is ejected by the server (`onPlayerEnteredVehicle` →
  `forcePlayerOutOfVehicle`). The weapon wheel block is proven; the `Attack` block is marked
  *inferred* by the platform — a prisoner may still swing a melee weapon.
- `Open77.vehicles.closest` only sees **server-spawned** vehicles: a vanilla traffic car cannot be
  used for `/embarquer`.
- `/casier` and the exports work on **connected** players (session ids); offline files stay in SQL.
- The fine dialog and the citizen's answer ride `open77_player_interactions`: both must be alive, on
  foot, within 3 m and in the same bucket; the citizen has 30 s.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``Config.Stage` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/menotter`, ALT+click Cuff | `give` looped: the officer reaches for the wrists | none | 3 s bar, then the kit's cuff |
| the cuffed suspect | `handsup` looped until released (`handsback` = hands behind the back once it exists); an escort drops it while walking | none | until `/demenotter` / release / booking |
| `/fouille`, ALT+click Search | `examine` bent over the suspect, looped (`frisk`) | none | 4 s bar, then the pocket list |
| Seize contraband | same, looped | none | 3 s bar |
| `/amende` | `phone` one-shot: the ticket | the profile's holo | 3 s, then the consent prompt |
| `/prison` | `phone` looped: the booking | the profile's holo | 4 s bar, then the transfer |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_ncpd] player 3 stage cuff: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=none place=none 3000 ms -> ok
[rp_ncpd] player 4 hold cuffed: pose=handsup/stand__2h_up__03__look_around__01 prop=none
[rp_ncpd] player 3 stage search: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=none place=none 4000 ms -> ok
[rp_ncpd] player 3 gesture fine: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 3000 ms
[rp_ncpd] player 3 stage book: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none place=none 4000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.
If `open77_rp_basics` already poses the cuffed suspect, the `cuffed` hold answers `animation_owned` once in the log and the kit's pose stays; the `handsup` pose also satisfies the hands-up checks of `/fouille` and rp_gangs' robbery, which cuffed players already passed.

## Log (grep-able)

```
[rp_ncpd] started: cell -1755.5 -1010.8 94.3, entrance -1761.5 -1006.8 94.3, jail 1-120 min, fines 1-100000 eddies
[rp_ncpd] store=sql tables=rp_ncpd_records,rp_ncpd_warrants,rp_ncpd_fines,rp_ncpd_sentences
[rp_ncpd] voice channel 3 created (NCPD dispatch)
[rp_ncpd] player 1 cuffed player 2
[rp_ncpd] player 1 searched player 2: 3 item(s), 1 illegal
[rp_ncpd] fine 500 offered to player 2 by 1 (speeding) interaction=...
[rp_ncpd] fine 500 for player 2: paid=120 unpaid=380 reason=speeding officer=1
[rp_ncpd] warrant L2 on player 2 by 1: armed robbery
[rp_ncpd] player 1 jailed player 2 for 5 min
[rp_ncpd] prisoner 2 left with 3 min 40 s to serve; the clock resumes on reconnect
[rp_ncpd] prisoner abcd1234.. released (served)
```

## Test in 2 minutes

Two clients at the freeroam spawn (Kabuki Market Centre `-1191.30, 2006.88, 7.82`), ids `1` (officer) and `2`
(citizen); `rp_jobs`, `rp_inventory`, `rp_bank`, `rp_economy`, `open77_rp_basics` running, the
officer's account holding `rp.cuff` / `rp.escort` / `rp.search` (Setup, step 2).

1. Console: `setjob 1 ncpd 3`, `giveitem 2 synthcoke 2`, `giveitem 2 burrito 1`. Player 1:
   `/service` → `Badge on. ALT+click a citizen...`; player 2 sees `[NCPD] <name>` over player 1.
2. Player 2, 10 m away. Player 1: `/menotter 2` → `Too far (10 m). Get within 3 m.` Walk up, hold
   **ALT**, click player 2, **Cuff** → player 2 freezes with hands up and reads `Officer ... cuffed
   you.` (`not_authorised` here = step 2 of Setup was skipped).
3. **Search** (or `/fouille 2`) → `... carries: Burrito x1, Synthcoke x2 [ILLEGAL]` then
   `Contraband: Synthcoke x2. Seize it with /fouille 2 saisir`. **Seize contraband** → confirm →
   `Seized from ...: Synthcoke x2 (in your pockets)`; player 1 `/inv` shows the synthcoke.
4. **Uncuff**. Player 2 walks 4 m away; **Escort / stop escorting** → player 2 is pulled back
   beside player 1 whenever they drift past 5 m; same action again → `You stopped escorting ...`.
5. **Fine** → amount `300`, reason `jaywalking` → player 2 reads the offer and types
   `/interaction accept` → `Fine paid from your account: 300 €$` (player 2 had deposited at the
   ATM) or `Fine: 120 €$ taken from your cash ... You still owe 180 €$` (+ warrant). Player 2:
   `/amende payer` once they have eddies → `Paid 180 €$. Your fines are settled.` and `Your NCPD
   warrant has been lifted.` A second fine answered with `/interaction decline` → `You refused the
   ... fine ... NCPD now has a warrant on you.`
6. `/mandat 2 3 armed robbery` → player 2 reads `NCPD has a warrant on you (level 3)`. `/ncpd` →
   officers on duty, `Open warrants (1): <name> (#2) L3 - armed robbery`. `/mandat lever 2`.
7. Player 1: `/car` (freeroam) next to player 2, then **Put in / take out of vehicle** (or
   `/embarquer 2`) → player 2 is on the back seat, door locked (`ExitVehicle` does nothing);
   `/embarquer 2` again → they are out.
8. **Jail** → `5` (or `/prison 2 5`) → player 2 is teleported to the cell in the NCPD building
   (3.1 km south, inside the `ncpd_hq` zone of rp_zones: toast **NCPD Headquarters**), reads
   `... booked you: 5 minutes ...`, cannot open the weapon wheel,
   gets a toast every minute. Walk out of the cell → `Nice try. Back in the cell.` Disconnect and
   reconnect player 2 → `Back in the NCPD cell: 3 min 40 s left` and back in the cell. `/liberer 2`
   (or wait) → teleport to the desk (`Config.entrance`, 4 m north of the conference room),
   `Time served.` / `Released early by officer ...`.
9. `/casier 2` → the arrest, the seizure, the fines and the warrants with dates and `officer
   <RP name>`. Reconnect player 2: `/casier 2` still lists everything (SQL).
10. From another resource: `TriggerEvent("rp_ncpd:alert", "robbery", { x = -1201.1, y = 2035.6, z = 5.6 },
    "Lower Walkway dealer hit", 2)` → player 1 reads `[NCPD DISPATCH] ROBBERY: Lower Walkway
    dealer hit - <name> (30 m)`, a toast, and a `danger` pin under the market on the map for a
    minute. Drive to the Afterlife street (`-1408, 960`): a blue ring, the floating
    `NCPD — Afterlife street outpost` label, a keep-out sign and a road barrier mark the patrol
    point (nothing to press there).
    `/ncpd all units, code 3` → every officer reads `[NCPD RADIO] <name>: all units, code 3`.
