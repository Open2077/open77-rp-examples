# rp_trauma — Trauma Team and RP death

Open77 Lua resource (build `2.31.13+op77.76`) that replaces the automatic freeroam respawn
with an RP death: a player who dies is **down** for `Config.downSeconds`, on-duty Trauma Team
employees are dispatched (chat, toast, map pin with distance), and the player either gets
revived where they fell or gives up with `/respawn` and wakes up at the hospital with a bill.
It **absorbs `rp_medic`**: `/soin /reanimer /911 /medic` live here with the same names, now
gated by `rp_jobs` (`hasJob(id, "trauma")` **and** `onDuty(id)`). Unload `rp_medic` when this
resource is loaded — a command name registered twice is served by the first resource only.

Server-authoritative: the client renders (map pins, input block, countdown hint) and requests
(ALT+click actions); every decision — money, jobs, distances, life state — is made in
`server/main.lua`.

## Files

| File | Runtime | Role |
|---|---|---|
| `open77.lua` | manifest | dependencies, permissions, scripts |
| `shared/config.lua` | both | every number and position (`Config`) |
| `server/main.lua` | server | the down state, medic acts, hospital, AV, contracts, bills, exports, events |
| `client/main.lua` | client | input block + countdown hint while down; medic map pins; ALT+click actions |

Dependencies (all ship a client half): `open77_uikit` (progress bars, `/contrat` menu — server
twins), `open77_contextmenu` (ALT+click), `open77_notifications` (toasts). `rp_jobs`,
`rp_zones`, `rp_bank`, `rp_economy`, `rp_identity` are reached through `pcall` and are **not**
declared (their READMEs ask a resource with a client script not to; `rp_economy` is server-only).
Without `rp_jobs` every medic verb refuses with "roster unavailable"; without `rp_bank` /
`rp_economy` the cash path / the unpaid bill path takes over; without `rp_zones` `/trauma av`
refuses; without `rp_identity` account names are used.

## The death flow

**What the platform offers.** There is no death-hold API, no cancellable death event and no
freeroam export or tunable that a resource could use to hold or cancel the freeroam respawn
(searched: `open77_search`, `open77_events` prefixes `death`/`life`/`player`, the
`server-api`, `player-stats`, `player-freeze`, `gamemode-kernel`, `resource-exports` guides and
the `server.jsonc` schema). `onPlayerLifeStateChanged` is a plain host event (not cancellable),
`open77_death` is a client read-only package, and the only life mutators are `kill`, `revive`,
`respawn`.

**So the respawn happens, and the down state is re-applied.** On the `dead` phase the server
records the death position and dispatches the medics. The moment the phase is back to `alive`
(the freeroam respawn), the server:

1. `Open77.players.teleport` the body back to the death position (fade, settle watch);
2. `Open77.players.setFrozen(id, true)` — the engine's own `NoMovement` restriction;
3. `Open77.stats.setHealth` to `Config.downHealthFraction` (5 %) of the maximum and
   `setHealthRegenEnabled(false)`;
4. tells the client, which takes the whole input stream (`Open77.input.blockAll` — chat and
   voice keep working, so `/respawn` can be typed) and shows a UI-kit hint with the countdown;
5. sends "You are down. Trauma Team has been notified." (chat + toast) and repeats it every
   `Config.downReminderSeconds`.

Dying again while down keeps the same countdown. A player who disconnects while down comes back
free (no bill). Stopping the resource frees everyone it holds. A medic revive or a hospital
respawn removes the down entry **before** acting, so the next `alive` phase is left alone.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/respawn` | a down player | Refused while the countdown runs **and** at least one other medic is on duty (`Trauma Team is on duty (1 medic). /respawn opens in N s.`) — or, with `Config.countdownWithoutMedics = true` (this eval config), while the countdown runs at all (`Hold on, choom: /respawn opens in N s.`). Otherwise: hold released, body moved to the hospital (`Config.hospital.respawn`; `Open77.players.respawn` if still dead, `Open77.players.teleport` if already respawned), full health, **`Config.hospitalBill` (500 €$)** collected: `rp_bank:charge(id, 500, "trauma", "hospital")`, else what cash covers (`rp_economy:remove` + `societyAdd`), else an unpaid row in `rp_trauma_bills`. Raises `rp_trauma:revived (id, nil)`. |
| `/soin <playerId>` | Trauma Team on duty | Stabilise a **hurt, standing** patient within 5 m: 5 s progress bar (UI kit, movement and combat disabled), then full health and **100 €$** billed to the patient (same account → cash → bill order). |
| `/reanimer <playerId>` | Trauma Team on duty | Revive a **down** (or still dead) patient within 5 m: 8 s progress bar, then `Open77.players.revive` (dead) or the hold released (held) at 50 % health, **300 €$** billed — **free for contract holders**. Raises `rp_trauma:revived (id, medicId)`. |
| ALT+click a player → **Revive** / **Stabilise** | Trauma Team on duty | The same two acts from the context menu (3 m). The client only shows the entry when it was told the player is a medic and the target is down/hurt; the server re-checks everything. |
| `/911 <message>` | everyone | The message and the caller's rounded position go to every on-duty medic and NCPD officer (chat + toast) and `rp_ncpd:alert("911", position, message, callerId)` is raised for `rp_ncpd`. |
| `/medic` | everyone | On-duty medics nearest first with their distance; a medic also sees their counters. |
| `/trauma` | everyone | Your status: down or not, contract, unpaid bills. An on-duty medic also gets the dispatch list (who is down, where, how far). |
| `/trauma av` | Trauma Team on duty, **inside the `hospital` zone** | Spawns the Trauma Team AV (`Config.av.record` = `Vehicle.av_trauma`) 8 m in front of the medic and warps them into the driver seat. One AV per medic; calling it again replaces it. `/trauma av off` removes it. |
| `/trauma factures` | everyone | Lists your unpaid Trauma Team bills. |
| `/trauma payer` | everyone | Pays them oldest first, each from the account then from cash; stops at the first one you cannot cover. |
| `/contrat` | everyone (not while down) | UI-kit menu: **Subscribe** (1 000 €$ per 30 min of server time, charged from the account through `rp_bank:charge(id, 1000, "trauma", "contract")`), or **My contract** / **Cancel my contract** when active. |

Every command refuses the server console politely (`run it from the game`); every refusal is
explained in chat. Player ids are the session ids (`/id`, `/players`).

Medic rules shared by the two acts: one act at a time per medic, `Config.medicCooldownSeconds`
(10 s) between two paid acts, never on yourself, never on a player not yet in the world, range
re-checked after the progress bar, a cancelled bar (X / Escape) does nothing and charges nothing.
Fees are paid **into the `trauma` society** (`rp_bank`), which pays the medics through the
`rp_jobs` payroll.

### The contract

Holders get **free revives**, `[CONTRACT]` in front of their name in the dispatch line, a
different (gold `important` sprite) map pin — a per-blip colour does not exist on 2.31 — and
a distinct toast title (`Trauma Team: contract holder down`) on every medic's screen. Every 30 s the server renews the contracts of
connected players whose period ended: a successful charge extends it by `Config.contractMinutes`;
a failed charge (`insufficient_funds`, bank offline…) counts one failure, warns the player and
grants one more period; the **second consecutive failure cancels** the contract
(`Config.contractMaxFailures`). Offline players are not charged; their period is caught up when
they come back. Cancelling gives no refund.

## Exports (server, synchronous, never yield)

```lua
exports.rp_trauma:isDown(playerId)                 -- boolean: has a down entry (dead, or held at the death spot)
exports.rp_trauma:revive(playerId, byPlayerId)     -- true | nil, reason  (no fee: the caller owns the money)
exports.rp_trauma:heal(playerId, byPlayerId)       -- true | nil, reason  (full health; refuses a down patient with patient_down)
exports.rp_trauma:hasContract(playerId)            -- boolean
```

Reasons: `invalid_player_id`, `player_not_found`, `patient_down` (heal), `patient_not_down`
(revive), or the platform's own (`invalid_argument`, …). `revive` raises `rp_trauma:revived`
with `byPlayerId` (a number or `nil`). Call them inside `pcall`.

## Events (host bus, `TriggerEvent`)

| Event | Arguments | When |
|---|---|---|
| `rp_trauma:down` | `playerId, position { x, y, z }` | The player just died and is now down (once per down episode, not on a re-death while down). |
| `rp_trauma:revived` | `playerId, byPlayerId \| nil` | A medic revived them (`byPlayerId` = the medic, or whatever id the `revive` export was given), or they took the hospital respawn (`nil`). |

Consumed: `rp_jobs:duty`, `rp_jobs:changed` (to refresh the medic state on the client).
Raised for others: `rp_ncpd:alert("911", position, text, callerId)`.

Internal net events (`rp_trauma:clientReady`, `rp_trauma:action`, `rp_trauma:hold`,
`rp_trauma:medic`, `rp_trauma:downBlip`, `rp_trauma:downClear`) are this resource's
client/server transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`, keyed by the durable `Open77.players.identifier`:

```sql
rp_trauma_contracts (
    identifier VARCHAR(64) PRIMARY KEY,
    active     TINYINT(1) NOT NULL DEFAULT 1,   -- 0 once cancelled (by the player or by two failed renewals)
    until_at   BIGINT     NOT NULL DEFAULT 0,   -- unix seconds, end of the paid period
    failures   TINYINT    NOT NULL DEFAULT 0,   -- consecutive failed renewals
    started_at BIGINT     NOT NULL DEFAULT 0,
    renewed_at BIGINT     NOT NULL DEFAULT 0
)
rp_trauma_bills (
    id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    identifier VARCHAR(64) NOT NULL,
    amount     INT NOT NULL,
    reason     VARCHAR(32) NOT NULL DEFAULT '',   -- hospital | heal | revive
    created_at BIGINT NOT NULL DEFAULT 0,
    paid_at    BIGINT NULL                        -- NULL = unpaid
)
```

Both are cached in memory (loaded per player on `onPlayerReady`) and written through with the
callback forms, so the exports never touch the database. Medic counters (`heal:<identifier>`,
`revive:<identifier>`) stay in `Open77.kvp`.

**No database** (`ready` answers `database_unavailable`, or the database still is not answering
20 s after the first player is ready): contracts fall back to `Open77.kvp`
(`contract:<identifier>:active|until|failures|started`) and bills to a single running total
(`debt:<identifier>`); the log says `[rp_trauma] store=kvp reason=...`. The choice is kept for
the whole boot.

## Eval configuration (`shared/config.lua`)

| Key | Eval value | Production suggestion |
|---|---|---|
| `downSeconds` | **60** | 600 |
| `countdownWithoutMedics` | **true** (the timer applies even with nobody on duty, so one tester sees it) | false (`/respawn` immediate when no medic is on duty) |
| `hospitalBill` | 500 €$ | |
| `healFee` / `reviveFee` | 100 / 300 €$ | |
| `stabiliseMs` / `reviveMs` | 5 000 / 8 000 ms | |
| `contractPrice` / `contractMinutes` / `contractMaxFailures` | 1 000 €$ / 30 min / 2 | |
| `actionRange` / `commandRange` | 3 m / 5 m | |
| `downHealthFraction` / `reviveHealthFraction` | 0.05 / 0.5 | |
| `medicCooldownSeconds` / `downReminderSeconds` | 10 s / 30 s | |
| `hospital.zone` / `hospital.respawn` | `viktor_clinic` / `-1546, 1231, 11.6` (heading 180) | |
| `av.record` / `av.pad` | `Vehicle.av_trauma` / `-1408, 960, 23.5` r 15 (the Afterlife street) | |
| `blip.sprite` / `blip.contractSprite` | `SOSsignalVariant` / `important` | |

**"The hospital" is Vik's.** In the lore you wake up at Viktor Vektor's, so `/respawn` puts the
body in **Vik's clinic** (Little China, Watson): the rp_zones `viktor_clinic` zone (radius 12 m,
centre `-1548, 1230, 11.6`, the AMM chair room), 855 m south-west of the freeroam spawn (Kabuki
Market Centre `-1191.30, 2006.88, 7.82`); `Config.hospital.respawn` is 2 m off the chair. The
config keys keep the `hospital` name (rp_config overrides `rp_trauma.hospital.*`); the
player-facing lines say Vik's. **The AV pad** is not the clinic (an interior cannot take an AV)
but the real street outside the Afterlife ramp — `Config.av.pad` `-1408, 960, 23.5`, probed
crosswalk, 15 m radius, 73 m from the Afterlife's bar floor: `/trauma av` needs the medic
standing on it.

**The AV.** `Vehicle.av_trauma` is the "AV Trauma" record of the 2.31 catalogue (class `av`,
4 seats; `open77_data vehicles "av_trauma"`). No AV record has a `_player` variant and the
catalogue carries no "player-spawnable" flag, so the record is the lore-correct pick, not a
proven one: if `Open77.vehicles.create` refuses it (the medic reads `AV request refused
(<reason>)`), set `Config.av.record` to `Vehicle.av_rayfield_excalibur` and try again.

## Log (grep-able)

```text
[rp_trauma] started: down=60 s, hospital bill=500, fees heal=100 revive=300, contract=1000 €$/30 min, hospital at -1546, 1231, 12, av=Vehicle.av_trauma
[rp_trauma] store=sql tables=rp_trauma_contracts,rp_trauma_bills
[rp_trauma] player 3 down at -1191, 2007, 8, 1 medic(s) notified, 60 s
[rp_trauma] player 3 held down at -1191, 2007, 8, 55 s left
[rp_trauma] player 4 revived player 3 fee=300 dead=false
[rp_trauma] player 3 hospital respawn: account=500 cash=0 debt=0
[rp_trauma] player 3 owes 200 (hospital), total debt 200
[rp_trauma] player 3 contract signed until 1789000000 account=4000
[rp_trauma] player 4 spawned AV 12 (Vehicle.av_trauma) at -1408, 968, 25 seat=true
```

## Test in 2 minutes (one player, freeroam spawn)

Load `open77_uikit`, `open77_contextmenu`, `open77_notifications`, `rp_economy`, `rp_bank`,
`rp_jobs`, `rp_zones`, `rp_identity` and `rp_trauma` (and **not** `rp_medic`). Log on start:
`[rp_trauma] started: down=60 s ...` then `store=sql ...`.

1. Connect (id `1`), stand at the spawn, Kabuki Market Centre `-1191.30, 2006.88, 7.82`.
   `/trauma` → `Trauma Team: you are on your feet; no contract (/contrat); unpaid bills 0 €$.`
2. `/suicide` (freeroam test command). Chat: `You are down. Trauma Team has been notified.
   /respawn opens in 60 s (Vik's bill 500 €$).` + red toast. The freeroam respawn runs, then
   the screen fades and you are back **at the death spot**, frozen, at 5 % health, with the
   bottom hint `DOWN - Trauma Team notified - /respawn opens in N s`. W/A/S/D, jump and fire do
   nothing; the chat still opens. Log: `player 1 down at ...` then `player 1 held down at ...`.
3. `/respawn` right away → `Hold on, choom: /respawn opens in N s.` (eval config:
   `countdownWithoutMedics = true`; in production, with nobody on duty, it would be accepted at
   once). Wait 60 s: chat `/respawn is open: Vik's clinic takes you for 500 €$...`, the hint
   changes, a toast confirms.
4. `/respawn` → fade, you stand in Vik's clinic next to the chair (`-1546, 1231`, 855 m from
   the market; toast **Vik's Clinic** from rp_zones), full health, chat `Trauma Team dropped
   you at Vik's clinic. Bill: 500 €$ from your account.` (or `... in cash`, or `... 200 €$ still
   owed (/trauma payer)` when broke). `/solde` shows the debit; `/trauma factures` lists a debt
   if any; `/trauma payer` settles it once you have money. The `ATM — Vik's Clinic` ring is
   3 m away at the door.
5. `/contrat` → menu; **Subscribe** → `Trauma Team contract signed: 1000 €$ charged...`
   (fund the account first: `/bank` at the clinic ATM or console `givemoney 1 2000` then
   deposit). `/contrat` again shows **My contract** / **Cancel my contract**.
6. Console: `setjob 1 trauma 3`, then in game `/service` → you are an on-duty medic. `/trauma`
   now adds `Dispatch: nobody is down.` Drive to the street outside the Afterlife ramp
   (`-1408, 960`, the NCPD outpost ring of rp_ncpd marks the same crosswalk), `/trauma av` →
   the AV appears in front of you and you are in its seat; `/trauma av off`. Anywhere else the
   command answers `The AV pad is on the Afterlife street (-1408, 960), N m from you: stand on
   it first.`
7. `/soin 1` → `You can't treat yourself, choom.`; `/soin 99` → `Player 99 not found`.
8. **Two players** (second client id `2`, no job): player 2 `/suicide` → player 1 (on duty)
   reads `<name> (id 2) is down at ..., 12 m away. ALT+click the body: Revive.`, gets a toast
   and a `SOS` pin on the map whose title carries the live distance. Player 2 `/respawn` →
   `Trauma Team is on duty (1 medic). /respawn opens in N s.`
9. Player 1 walks to the body, holds **ALT**, clicks it, picks **Revive (Trauma Team, 300 €$)**:
   8 s bar (X cancels), then player 2 stands up at 50 % health, reads `Medic <name> revived
   you: 300 €$ from your account.`, the pin disappears, the trauma society gains 300 €$
   (`/societe` on player 1). With a contract on player 2: `Contract holder: no charge.`
10. Player 2 loses some health (fall, fight) → ALT+click → **Stabilise (Trauma Team, 100 €$)**
    → 5 s bar → full health, 100 €$. `/soin 2` / `/reanimer 2` do the same from 5 m.
11. Player 2 `/911 shots fired` → player 1 reads the `911` line with the position and a toast;
    player 2 reads `Call relayed to 1 responder(s) on duty (Trauma Team and NCPD).`
12. `/medic` on player 2 → `1 medic(s) on duty:` + `- <name> (id 1): 8 m`. Player 1
    `/service` (clock out) → `/medic` says `No medic on duty: /respawn is immediate if you go
    down.`
13. Other resources: `print(exports.rp_trauma:isDown(2), exports.rp_trauma:hasContract(2))`,
    `exports.rp_trauma:revive(2, 1)`.

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
| Stabilise (`/soin`, ALT+click) | `examine` kneel over the patient, looped (`medical`) | `medical.device` in the right hand (`medical.injector` once it exists) | 5 s bar (`stabiliseMs`) |
| Revive (`/reanimer`, ALT+click) | same kneel, looped | same injector + `medical.container` kit at the medic's feet (root frame) | 8 s bar (`reviveMs`) |
| the down player | `wounded` (seated, hand on the belly), looped from the hold to the revive / respawn | none | the whole down state |
| `/911` | `phone` one-shot: the call | the profile's holo | 3 s |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_trauma] player 3 stage stabilise: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=medical.device@RightHand place=none 5000 ms -> ok
[rp_trauma] player 3 stage revive: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=medical.device@RightHand place=medical.container 8000 ms -> ok
[rp_trauma] player 5 hold down: pose=wounded/sit_ground_lean180__rh_on_belly__01__deep_breath__01 prop=none
[rp_trauma] player 5 gesture call: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 3000 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.
The `wounded` pose on a frozen body is not proven on 2.31: if the platform refuses it (`player_not_alive`, `position_unavailable`), the line `stage down: pose wounded refused ...` appears once and the down state works as before.

## Manifest permissions

`players.stats.read` (`Open77.stats.get`, both sides), `players.stats.apply` (`setHealth`,
`restoreHealth`, `setHealthRegenEnabled`), `players.life.read` (`isDead`, `getLifeState`, both
sides), `players.life.revive` (`revive`), `players.life.respawn` (`respawn`),
`players.life.freeze` (`setFrozen`), `players.teleport` (`teleport`), `world.vehicles`
(`vehicles.create` / `remove` / `warpPlayerIntoVehicle`), `network.events`
(`RegisterNetEvent`, `TriggerClientEvent`, `Open77.notifications.send`, `TriggerServerEvent`),
`database.access` (`Open77.database.*`), `input.blockAll` (`Open77.input.blockAll`, client),
`ui.vanilla.map` (`Open77.blips.*`, client).
