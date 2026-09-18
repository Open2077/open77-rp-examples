# rp_fixer — the fixer's gig board

Gigs for a Night City RP server on Open77 (build `2.31.13+op77.76`). The fixer publishes
gigs on a board at the office — Rogue's meeting room at the back of **The Afterlife**; mercs
accept one at a time, run it against a clock, and are paid in cash on success. The fixer's society takes a **15 % cut**, every success earns
**+1 reputation**, and reputation tiers gate the better-paid templates.

Server-authoritative: the server owns the board, the phases, the clock, the pay, the
reputation and every NPC. The client only draws the office prompt and the current
objective (ring + E prompt + map pin + GPS waypoint) and relays a key press; the server
re-measures the distance itself.

## The four gig kinds

| Kind | Flow | Objective 1 | Objective 2 |
|---|---|---|---|
| `delivery` | pick a **sealed package** (1 kg, illegal) up at A, bring it to B | E prompt at A → `gig_package` in the pockets | E prompt at B → the package is taken, pay |
| `retrieval` | grab an **encrypted shard** (0.05 kg, illegal) guarded by **2 Maelstrom goons**, bring it to the office | E prompt at the zone (guards attack inside 25 m) → `gig_datashard` | E prompt at the office → pay |
| `escort` | walk an NPC from A to B | E prompt at A → the NPC **follows you** | arrival = the NPC stands within **5 m** of B |
| `extraction` | pull a target NPC out of a guarded zone, bring them to the office | E prompt at the zone (2 guards) → the NPC follows you | arrival = the NPC within 5 m of the office |

NPCs, from the devkit's own catalogue notes:

- **Guards**: `Character.cpz_maelstrom_grunt1_ranged1_lexington_wa` (the Maelstrom record
  behind the `hostile_female_ranged_lab` alias, documented as a ranged hostile with the
  combat capability), numeric `damagePolicy = 0` (mortal, 150 HP), two per point, in the
  relationship group `rp_fixer_guards`. Hostile behaviour is real and comes from three
  cards: `Open77.npcs.setAttitude(id, "hostile", { towards = <mercId> })` at spawn (hostile
  to the merc only), `Open77.npcs.tasks.guard(id, post, 8)` as a leash, and
  `Open77.npcs.tasks.attack(id, mercId)` the moment the merc comes within
  `Config.guards.engageDistance` (25 m) — the engine's combat AI drives them from there.
- **Escorts / targets**: legacy alias `civilian_female_relaxed_01` (= `Character.Panam`, the
  devkit's non-hostile human with locomotion; natively invulnerable), numeric
  `damagePolicy = 2`, `behavior = { combatEnabled = false, voiceEnabled = false }`. They
  stand still with `Open77.npcs.tasks.hold` until the merc presses E, then
  `Open77.npcs.tasks.follow(id, mercId, { distance = 2.5, speed = "run" })`. Arrival is
  read from `Open77.npcs.get(id)` every second.

Every NPC of a gig is removed when the gig ends, when the player disconnects and when the
resource stops.

## Commands

| Command | Who | Effect |
|---|---|---|
| **E** on the board ring at the office, or `/gigs` | anyone (see `openBoardWithoutFixer`) | Opens the board: a UI-kit context menu, one row per open gig with **Pay** (net, and the fixer's cut), **Time limit**, **Rep needed**, **Posted by**. Rows above your tier are greyed out. Pick one → an **Accept the gig / Not now** dialog. Works within `Config.boardReach` (15 m) of the office. |
| `/gig` | anyone | Your running gig: title, kind, current objective and its distance, time left, pay. Without a gig: your reputation. |
| `/gig abandonner` | anyone | Walks away from the gig: **reputation −1**, the fixer's item is taken back, the NPCs vanish, the template goes back on the board a minute later. |
| `/fixer` | job `fixer` (rp_jobs), or the console | Board stats: open gigs, running gigs (who, phase, time left), session counters, the `fixer` society balance (rp_bank), the template ids. |
| `/fixer publier <template>` | a fixer **on duty**, or the console | Publishes a new instance of a template. The gig is posted **under the fixer's name**: the board shows it, the success row and the log carry their identifier, and they read `Posted by you` in the success notice. Everyone is told a new gig is up. |

Every refusal is a chat line from `FIXER`: too far (with the distance), already on a gig,
reputation too low (with the tier and score needed), pockets full, item lost, no fixer on
duty, board full, unknown template, contact never showed. From the server console `/gigs`
and `/gig` answer `run it from the game`; `/fixer` answers in the console.

Nothing here collides with a platform or delivered command (`gigs`, `gig`, `fixer`).

## Money, commission, reputation

- A template's `pay` is the **gross**. On success the merc receives `pay − cut` in cash
  (`exports.rp_economy:add(playerId, net, "gig:<template>")`) and the cut goes to the
  society (`exports.rp_bank:societyAdd("fixer", cut, "gig:<template>")`). Both are pcall'd:
  a bank or wallet that is down is reported in chat and in the log, never silently.
- Reputation: **+1** per success, **−1** on abandon or timeout, floored at 0, nothing on a
  disconnect. Tiers: `street` 0–2, `known` 3–5, `trusted` 6+. Each template names its
  `minTier`. A tier-up is announced in chat.
- Timeout: the clock starts on accept; one warning at 60 s left; at 0 the gig fails.
- One active gig per player. A disconnect ends the gig as `dropped` (no penalty).

## Exports (server, synchronous, never yield — call them inside `pcall`)

```lua
exports.rp_fixer:reputation(playerId)              -- integer score, 0 when unknown / not loaded
exports.rp_fixer:postGig("delivery_meds", nil)     -- gigId | nil, reason  (nil = posted by the board)
exports.rp_fixer:postGig("retrieval_shard", 3)     -- posted under player 3's name
exports.rp_fixer:activeGig(playerId)               -- { id, templateId, kind, title, phase, phaseLabel,
                                                   --   timeLeft, pay, commission, publisher } | nil
```

`postGig` reasons: `invalid_template`, `unknown_template`, `board_full`, `invalid_player_id`,
`player_not_found`. A resource **without** a client script may declare `dependency "rp_fixer"`;
a resource with one must not (this manifest is delivered to clients).

## Event (host-wide bus)

```lua
AddEventHandler("rp_fixer:gig", function(gigId, phase, playerId) end)
```

`phase` is `published` (playerId = the publishing fixer, or 0 for the board), `accepted`, the
key of every objective entered after the first (`dropoff`, `return`, `walk`), then one of
`success`, `timeout`, `abandoned`, `dropped`. Internal net events (`rp_fixer:board`,
`rp_fixer:interact`, `rp_fixer:objective`) are the client transport, not an API.

## Where things are

Real Night City places (world metres; walked points exact, AMM points +0.1 m for the rings):

| Point (`Config.points`) | Place | Position |
|---|---|---|
| `office` | The Afterlife — Rogue's meeting room (Little China, Watson) | `-1436.8, 977.0, 17.0` |
| `kabuki_market` | Kabuki Market Centre (the spawn) | `-1191.3, 2006.9, 7.82` |
| `kabuki_noodle_row` | Kabuki Market — Noodle Row | `-1178.7, 2028.5, 7.95` |
| `lizzies` | Lizzie's Bar, inside (Kabuki) | `-1188.9, 1566.2, 23.0` |
| `h10` | Megabuilding H10 — V's apartment floor | `-1391.9, 1271.7, 123.2` |
| `junkyard` | Rancho Coronado junkyard (Badlands edge) | `1374.9, -1674.9, 49.4` |

Distances (straight line): Kabuki Market → Lizzie's ≈ 440 m, Lizzie's → the Afterlife ≈ 640 m, Kabuki Market →
the Afterlife ≈ 1.0 km, the Afterlife → H10 ≈ 300 m (plus the elevator), Kabuki Market → the
junkyard ≈ 4.5 km (drive). The guarded points (junkyard, Lizzie's) are outside the
`kabuki_market` safe zone on purpose: inside it the guards would shoot without doing damage.

**Props.** At start the server spawns `Config.props` through `Open77.props.create` (permission
`world.props`, curated prop alias (see `prop.catalog`) — a raw `.mesh` path renders as a white
slab) and removes them at stop: a data terminal (`electronics.monitor.device`) at the booth
(`-1435.6, 978.0, 16.9`, yaw 83), 1.3 m off the board ring. A refused prop is logged (`prop 1 (...) not spawned: <reason>`); the board works
without it.

## Persistence

SQL first, created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`
(permission `database.access`). Rows are keyed by the durable `Open77.players.identifier`.

```sql
rp_fixer_reputation (
    identifier VARCHAR(64) PRIMARY KEY,
    score      INT    NOT NULL DEFAULT 0,
    completed  INT    NOT NULL DEFAULT 0,
    failed     INT    NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT 0      -- unix seconds
)
rp_fixer_gigs (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    gig_id      INT NOT NULL,                 -- the board's instance id (per server boot)
    identifier  VARCHAR(64) NOT NULL,         -- the merc
    player_name VARCHAR(80) NOT NULL,
    template    VARCHAR(32) NOT NULL,
    kind        VARCHAR(16) NOT NULL,         -- delivery | retrieval | escort | extraction
    outcome     VARCHAR(16) NOT NULL,         -- success | timeout | abandoned | dropped
    pay         INT NOT NULL,                 -- what the merc actually received (net)
    commission  INT NOT NULL,                 -- what the society actually received
    publisher   VARCHAR(80) NOT NULL,         -- the fixer's identifier, or 'board'
    accepted_at BIGINT NOT NULL,
    ended_at    BIGINT NOT NULL,
    INDEX (identifier)
)
```

Reputation is cached in memory per connected player (read on `onPlayerReady` with the
`.await` form, and for everyone already connected on a hot start) and written through with
the callback forms, so the exports never touch the database. A failed SQL read is never
treated as "no reputation": the player is told to reconnect.

**No database** (`ready` answers `database_unavailable`, or nothing answers within 15 s of
the first player): everything falls back to `Open77.kvp` (`rep:<identifier>`,
`repc:`, `repf:`, `gigs:count`, `gig:<n>` = one pipe-separated row) and the log says
`[rp_fixer] store=kvp reason=...`.

## Log (grep-able)

```text
[rp_fixer] started: office at -1436.8 977.0 17.0, board without fixer=true, commission=15%
[rp_fixer] items registered in rp_inventory: 2 (rejected: 0)
[rp_fixer] props spawned: 1
[rp_fixer] store=sql tables=rp_fixer_gigs,rp_fixer_reputation
[rp_fixer] gig 1 published template=delivery_hot pay=1200 net=1020 cut=180 by=board
[rp_fixer] player 1 reputation loaded score=0 tier=street (sql)
[rp_fixer] gig 3 accepted player=1 (Vince Rocker) template=delivery_meds deadline=600s
[rp_fixer] gig 3 phase=dropoff player=1
[rp_fixer] gig 3 success player=1 template=delivery_meds paid=510 commission=90 rep=1 publisher=board
[rp_fixer] gig 5 abandoned player=1 template=retrieval_shard paid=0 commission=0 rep=0 publisher=board
[rp_fixer] gig 7 guard attitude refused: npc_attitude_target_invalid
```

## Configuration (`shared/config.lua`)

| Key | Default | Meaning |
|---|---|---|
| `openBoardWithoutFixer` | `true` | `false` = the board only answers while a fixer is on duty (or to that fixer). |
| `office` | `-1436.8, 977.0, 17.0` | Rogue's meeting room at The Afterlife (`afterlife` zone): board, retrieval and extraction drop. |
| `props` | 1 terminal | Server-spawned decoration at the booth (`world.props`), removed at stop. |
| `boardReach` / `interactReach` / `promptDistance` | 15 / 4.5 / 3.0 m | Board distance, server-side prompt distance, client prompt distance. |
| `arrivalDistance` | 5 m | Escort / extraction success distance (planar). |
| `points` | real places | `kabuki_market`, `kabuki_noodle_row`, `lizzies`, `h10`, `junkyard` — see "Where things are". |
| `tiers`, `reputation`, `commissionRate`, `society` | see file | The rules above. |
| `maxOpenGigs`, `autoPublish`, `republishDelaySec`, `warnBeforeDeadlineSec` | 20 / true / 60 / 60 | Board behaviour. |
| `items` | `gig_package`, `gig_datashard` | Registered in `rp_inventory` through `define` at start and whenever `rp_inventory` restarts. |
| `guards`, `escort` | see file | Records, policies, distances. |
| `templates` | 6 templates | `delivery_meds` (street, 600, Noodle Row → junkyard, 20 min), `escort_witness` (street, 800, Lizzie's → Kabuki Market, 15 min), `retrieval_shard` (street, 1000, junkyard → office, 25 min), `extraction_techie` (street, 1500, Lizzie's → office, 20 min), `delivery_hot` (known, 1200, H10 → Lizzie's, 10 min), `extraction_vip` (trusted, 3000, junkyard → office, 30 min). |

**`z` matters.** A ring drawn inside the floor is invisible although everything reports
success, and the server measures the prompt distance in 3D. Walked points carry their exact
floor height, AMM points +0.1 m; if a ring is not visible, stand on the spot, `/pos`, and
paste the ground height.

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
| E at the pickup point (delivery / retrieval) | `give` looped (`carry_pickup`) | `military.case` in the right hand (`fixer.case` once it exists) | 3 s bar, then the item is pocketed |
| E at the drop point / the office | `give` looped (`carry_putdown`) | same case | 3 s bar, then the item leaves the pockets |
| E on the board | `phone` one-shot (`phonecheck`) | the profile's holo | 2.5 s |
| escort / extraction | none: the NPC walks | -- | -- |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_fixer] player 3 stage pickup: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=military.case@RightHand place=none 3000 ms -> ok
[rp_fixer] player 3 stage handover: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=military.case@RightHand place=none 3000 ms -> ok
[rp_fixer] player 3 gesture board: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 2500 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Manifest

Permissions: `network.events` (net events both sides), `database.access` (SQL),
`world.npcs` (guards, escorts, targets), `ui.vanilla.map` (client pins and waypoint),
`world.props` (the booth terminal).
Dependencies: `open77_uikit >=1.0.0` (the board and the accept dialog, server twins),
`open77_worldui >=0.1.0` (rings and prompts). `rp_jobs`, `rp_zones`, `rp_inventory`,
`rp_economy`, `rp_bank` and `rp_identity` are server-only and reached through `pcall`:
without `rp_inventory` delivery and retrieval refuse at the pickup and say so; without
`rp_economy` / `rp_bank` the success is recorded and the player told the eddies did not come
through; without `rp_jobs` the `/fixer` command refuses everyone but the console and the
board opens for anyone (`openBoardWithoutFixer`).

## Test in 2 minutes

One client, id `1`, with a car (`/car`) — the gigs cross Watson and one goes to the Badlands;
`rp_inventory`, `rp_economy`, `rp_bank`, `rp_jobs`, `rp_zones` running. Log on start:
`[rp_fixer] started: ...`, `items registered in rp_inventory: 2`, `props spawned: 1`,
`store=sql ...`, six `gig N published` lines.

1. Open the map: a **The Afterlife - fixer's booth** pin about 1 km south of the Kabuki Market
   spawn. Drive to the Afterlife, walk in, and go to Rogue's meeting room at the back
   (`-1436.8, 977`): a cyan ring, an **E — Fixer's board** prompt and the data terminal on
   the booth.
2. From the spawn, `/gigs` → `The board is at the fixer's office, 1059 m from you. Walk.`
   At the ring, press **E** (or `/gigs`): the board lists six gigs; `Hot package` and `VIP
   extraction` are greyed out (`Rep needed: known (3+)` / `trusted (6+)`).
3. Pick **Meds run** → the dialog shows the story, `Pay: 510 €$ ... the fixer keeps 90 €$`,
   `Clock: 20 min 00 s`. **Accept the gig** → chat `Gig accepted: Meds run. Pick up the sealed
   package. You have 20 min 00 s. ...`, a ring + **E — Grab the sealed package** at Kabuki
   Market's Noodle Row (`-1178.7, 2028.5`, ~1 km north), a map pin and a GPS route.
4. `/gig` → `Gig: Meds run (Delivery). Now: Pick up the sealed package, 1083 m away. Time left:
   19 min 40 s. Pay 510 €$.`
5. Drive to Kabuki, walk to the Noodle Row ring, look at it, press **E** → `You pocket the
   sealed package. Now move.` then `Next: Deliver the sealed package. 15 min ... left.`; `/inv`
   shows `Sealed package` (1 kg). The objective moves to the Rancho Coronado junkyard
   (`1374.9, -1674.9`, ~4.5 km by road, east then south).
6. Press **E** at the junkyard → `Handed over the sealed package.` then `Gig done: Meds run.
   510 €$ in cash (fixer's cut 90 €$). Reputation 1 (street).`; `/money` is up by 510; log
   `gig N success ... paid=510 commission=90 rep=1`. Console: `/fixer` shows the `fixer`
   society at 90 €$ (if the society existed; rp_bank creates it on first use).
7. Back at the board: **Junkyard shard** → Accept. Two Maelstrom goons stand at the junkyard.
   Inside 25 m: `Maelstrom made you. Guns out, choom.` and they open fire (on you only — the
   junkyard is outside every safe zone, so it hurts). Take the shard with **E** (`Take the
   encrypted shard`), drive it back to the office ring at the Afterlife, **E** → paid 850 €$,
   reputation 2.
8. **Witness walk** → Accept. Kess waits inside Lizzie's Bar (`-1188.9, 1566.2`). **E** on the
   ring → `Kess falls in behind you. Keep them close and walk.` Walk her 440 m north to the
   Kabuki Market Centre ring: when she stands within 5 m of it, `Kess made it.` then the pay
   line. Reputation 3 → `Word gets around: you are now known. Better-paid gigs are on the
   board.` — the board now offers **Hot package**.
9. **Techie extraction** → Accept, then `/gig abandonner` → `You walked away from Techie
   extraction. Reputation 2.`; the guards and the techie vanish; a minute later
   `gig N published template=extraction_techie` is back.
10. Fixer side: console `setjob 1 fixer 3`, then in game `/service`, `/fixer` → the stats,
    `/fixer publier delivery_hot` → `Posted #N Hot package: 1 020 €$ net to the merc, 180 €$
    to the fixer society under your name.` and everyone reads `New gig on the board: Hot
    package (1 020 €$)`. Complete it: the success notice says `Posted by <your name>` and the
    SQL row's `publisher` is your identifier.
11. Let a gig run out (or lower `timeLimitSec`): `60 s left on ... Move it.` then `Too slow:
    ... is off. The fixer is not happy. Reputation N.`
12. Reconnect: `player 1 reputation loaded score=N (sql)`; `/gig` shows the score.
13. From another resource: `print(exports.rp_fixer:reputation(1))`,
    `print(exports.rp_fixer:postGig("delivery_meds"))`, `print(exports.rp_fixer:activeGig(1))`.
