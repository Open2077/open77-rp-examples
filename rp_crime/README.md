# rp_crime — robberies, vehicle theft, street deals, contraband and a fence

The crime side of the Night City RP build, the thing that gives the NCPD work. Build target
**2.31.13+op77.76**. **Server-only**: no client script. Every distance, weapon check, item,
eddie, cooldown and alert is decided in `server/main.lua`; the player sees chat lines, toasts, a
UI-kit progress bar and, on the fence NPC, one **E** prompt that the server declares through
`open77_interactions` (`globalNpc` target, `onNpcInteracted` round trip — no client half needed).

| Crime | Command | What it needs | What it gives | Who is told |
|---|---|---|---|---|
| **Shop robbery** | `/braquer` | within 3 m of an `rp_shops` vendor, **weapon drawn**, 20 s bar | the register's cash (`rp_shops:rob`, 200–600 €$) | NCPD paged at the start (blip), criminal record if an officer was on duty |
| **Vehicle theft** | `/crocheter` | within 4 m of a **locked** server vehicle you hold **no key** for, a `lockpick`, 12 s bar | the door opens (`Open77.vehicles.setLocked(id, false)`), the lockpick snaps 50 % of the time | NCPD paged, plate flagged **WANTED** (`rp_garage:setWanted`), the owner told, on-duty officers within 20 m read an APB every 30 s |
| **Street deal** | `/dealer <playerId>` | a `drug_pack`, the buyer within 3 m with 120 €$ cash, their **consent** | 120 €$ to the dealer, the pack to the buyer, +1 gang influence in the zone | 20 % chance the NCPD is paged |
| **Contraband** | `/voler` | within 3 m of a nomad crate (`rp_nomade` prop) that is not yours, 8 s bar | `stolen_parts` x1 (2 kg, illegal) | the convoy driver(s) |
| **Fence** | `/receler` or **E** on Vik | at the junkyard fence, **22:00–06:00** world time | 300 €$ per `stolen_parts`, 40 % of the ripper's price per `implant_box*` | nobody (that is the point) |

Every refusal is one chat line from `CRIME` that says why: too far (with the distance), dead,
in a vehicle, no weapon drawn, shop still hot (minutes left), not locked, you hold a key, no
lockpick, nothing to sell, buyer broke, busy, already gutted, your own crate, daylight (with the
hour), pockets offline, and so on. From the server console every command answers that it must be
run from the game.

## Where things are (real Night City; freeroam spawn = Kabuki Market Centre `-1191.30, 2006.88, 7.82`)

Everything is in `shared/config.lua` (`RpCrimeConfig`). The five shops are the Kabuki Market
stalls (walked points, 2026-09-18); the fence works the Rancho Coronado junkyard out in the
Badlands.

| What | Position | From spawn | Config key |
|---|---|---|---|
| Noodle Row market (Rosa) | -1178.66, 2028.45, 7.95 | 25 m NE | `robbery.shops.supermarket` |
| The Stalls pharmacy (Dr. Osei) | -1223.91, 1989.45, 7.98 | 37 m SW | `robbery.shops.pharmacy` |
| East Row gun stall (Wilson) | -1160.50, 2019.06, 7.76 | 33 m E | `robbery.shops.gunshop` |
| Vendor Lane threads (Kimiko) | -1212.26, 1978.53, 7.98 | 35 m SW | `robbery.shops.clothes` |
| Lower Walkway dealer (Dex) | -1201.07, 2035.60, 5.60 | 30 m N, under the market | `robbery.shops.blackmarket` (rp_shops' shop id, not a zone) |
| Nomad loading bay (crates) | Aldecaldos camp, `1792.9, 2248.9, 180.2` area | 3.0 km E | (rp_nomade's) |
| **Vik the Fence** (NPC + E prompt + two cargo crates) | **1381, -1668, 49.4**, yaw 225 | 4.5 km SE, inside the `junkyard` zone (1374.9, -1674.9 r 90), between the wrecks | `fence.position`, `fence.props` |

The vendor positions are `rp_shops`' own (it exposes no export for them): keep the two configs in
sync when a shop moves — these are the market points `rp_shops` moves to. `z = 49.3` is the
yard's AMM height; if Vik stands in the ground, `/pos` on the spot and paste the height. The
server tolerates 4 m of height error on every reach check. The two crates beside Vik are
`Open77.props.create` (the curated prop alias `crate.cargo`, twice — see `prop.catalog`), removed
on stop; a refusal only logs.

## Rules the server applies

- **Robbery.** `Open77.weapons.get(id).drawn` must be `true` (`robbery.requireWeaponDrawn`; the
  cache is the owner's last report, refreshed at 20 Hz). The shop's own cooldown (20 min,
  `robbery.cooldownMs`) starts the moment the alert goes out, whether or not the till is emptied —
  `rp_shops:rob` keeps its own 20 min cooldown from a successful hit on top. The alert
  `rp_ncpd:alert("robbery", position, "<label> is being robbed", robber)` is raised **before** the
  bar; `rp_shops:rob` raises a second one (`"<label> robbed"`) when the loot is handed over. After
  the 20 s bar the server re-checks life, seat and distance (5 m), then calls `rp_shops:rob`; the
  loot is what that export hands over. `rp_ncpd:addRecord(robber, "robbery", ...)` is written only
  when at least one officer was on duty at alert time (the first one is the recording officer).
  Cancelling the bar (**X**) or walking away logs `robbery_aborted` — the NCPD is still coming.
- **Vehicle theft.** `Open77.vehicles.nearby(id, 4)` sees **server-spawned vehicles only** (a
  dealership car, `/car`, a rented truck), never vanilla traffic. The lock test is
  `Open77.vehicles.isLockedForPlayer(vehicle, thief)` — the canonical bit **or** a per-player
  exception, which is how `rp_garage` locks a bought car "for the street with an exception for the
  buyer and the key holders". A key holder (`rp_garage:hasKey`) is sent to `/verrouiller` instead.
  On success the durable lock is cleared for everybody (a jimmied lock is a broken lock; the owner
  re-locks with `/verrouiller`), a short horn plays, the lockpick is consumed with probability
  `theft.lockpickBreakChance` (0.5) **on success only**, the plate (`rp_garage:plateOf`) is flagged
  through `rp_garage:setWanted(plate, true, "stolen")` so `/plaque` shows **WANTED** and every
  on-duty officer gets rp_garage's APB, the owner (`rp_garage:ownerOf`, when online and not a
  society fleet) is told, and `rp_ncpd:alert("vehicle_theft", ...)` pages the police. A vehicle
  **without a plate** (`/car`) is still tracked by this resource (`vehicle#<id>`) but `/plaque`
  keeps calling it an unregistered ride — only rp_garage's rows carry the flag it prints.
- **APB tick.** Every `theft.spotTickMs` (30 s), for every wanted vehicle still in the world and
  every officer on duty (`rp_ncpd:isOnDuty`) within `theft.spotDistance` (20 m) of it: one
  `[APB] Wanted vehicle in sight: <label>, plate NC-XXXX, 12 m away.` line + toast. The list is
  rebuilt from `rp_garage:vehiclesOf` on start and on every `onPlayerReady` (vehicles out and
  flagged), and cleared by `rp_garage:changed` (`unwanted`, `stored`, `impounded`, `lost`) and
  `onVehicleRemoved`.
- **Street deal.** The consent rides `open77_player_interactions` (`Open77.playerInteractions
  .request(dealer, buyer, "give", ...)`): both alive, on foot, within 3 m, same bucket, neither
  already reserved; the buyer answers `/interaction accept` / `/interaction decline` within 30 s.
  Nothing moves until `onPlayerInteractionCompleted`; then the server **re-validates** the pack and
  the wallet, takes `rp_economy:remove(buyer, 120, "deal:drugs")`, moves the pack
  (`rp_inventory:remove` / `add`; `too_heavy` on the buyer refunds and returns the pack), pays the
  dealer, and adds `deal.influence` (1) for the dealer's gang (`rp_gangs:gangOf`) in the zone he
  stands in (`rp_zones:zoneOf`; a zone that is not a territory answers `unknown_zone` and is
  ignored). With probability `deal.alertChance` (0.20) `rp_ncpd:alert("drugs", position, "Street
  deal spotted near <zone>", dealer)` is raised and the dealer is warned.
- **Contraband.** A crate is any prop whose snapshot `resource` is `rp_nomade` (`contraband
  .ownerResource`), read through `Open77.props.all(bucket)` — the registry is readable across
  resources, the `resource` field is provenance. A crate on somebody's shoulder (attachment kind
  `player`) cannot be gutted; your own shoulder answers with a joke. If you hold the **only**
  active contract (`rp_nomade:activeContract`) the crate is yours and you are sent to `/convoi`;
  with several contracts running the ownership is ambiguous and every other driver is told. After
  the 8 s bar the prop, its attachment and the distance are re-read, then `stolen_parts` x1 lands
  in the pockets (`too_heavy` = nothing taken). A gutted crate is remembered by prop id until
  `onPropRemoved`, so it cannot be gutted twice.
- **Fence.** `Open77.environment.getState().hour` must be in `[fence.openHour, fence.closeHour)`
  = `[22, 6)`. No clock authority (`open77_weather` absent → `environment_unavailable`) = never
  closed when `fence.openWithoutClock` is true, logged once. The sale takes every `stolen_parts`
  at `fence.stolenPartsPrice` (300) and every item whose id starts with `implant_box` at
  `floor(price × fence.implantRatio)` where `price` is `fence.implantPrices[id]` or
  `implantPrices.default` (1000 → 400 €$): **paste the ripper's real prices there** (rp_ripperdoc's
  contract is not part of this phase's sheet, see *Honest limits*). Items are removed first, the
  eddies added with `rp_economy:add(id, total, "fence:<item>")`; a refused payout puts the goods
  back. Both the prompt (`onNpcInteracted`, the server's own distance) and `/receler` apply
  `fence.reach` (5 m).
- One crime at a time per player while a bar runs; a dead player, a seated player or an unknown
  position refuses everything.

## Commands

| Command | Effect |
|---|---|
| `/braquer` | Hold up the vendor within 3 m: alert, 20 s **Emptying the till...** bar (X bails), loot. |
| `/crocheter` | Pick the lock of the nearest locked server vehicle within 4 m you hold no key for: 12 s **Jimmying the lock...** bar, unlock, WANTED, alert. |
| `/dealer <playerId>` | Offer one drug pack for 120 €$ to a player within 3 m; they `/interaction accept`. |
| `/voler` | Gut the nearest nomad crate within 3 m that is not yours: 8 s **Prying the crate open...** bar, `stolen_parts` x1. |
| `/receler` | Sell `stolen_parts` and `implant_box*` to Vik within 5 m, 22:00–06:00. **E** on Vik does the same. |

Suggestions are published on `chat:ready` and once with `-1` from `onResourceStart`. None of the
five names collides with a platform or delivered command (`voler` is the plan's fallback for the
crate prompt).

## Exports (server, synchronous — never yield; call inside `pcall`)

```lua
exports.rp_crime:wantedVehicles()   -- { "NC-K7P2", "vehicle#12", ... } sorted; plates of flagged
                                    -- vehicles still in the world, "vehicle#<id>" for a plateless ride
```

## Events (host bus, `TriggerEvent`)

```lua
AddEventHandler("rp_crime:robbery", function(kind, position, byPlayerId) end)
-- kind: "robbery" (shop), "vehicle_theft", "crate_theft", "drugs" (only when the NCPD was paged)
```

Raised **to** other resources: `rp_ncpd:alert (kind, position, text, byPlayerId)` with kinds
`robbery`, `vehicle_theft`, `drugs`. Consumed: `onPlayerInteractionCompleted` /
`onPlayerInteractionCancelled` (this resource's deals only), `onNpcInteracted` (the fence prompt),
`onNpcRemoved` (the fence respawns after 5 s), `onPropRemoved`, `onVehicleRemoved`,
`rp_garage:changed`, `onPlayerReady`, `onPlayerDisconnected`, `onResourceStart` (own start, and
`rp_inventory` restarting → `stolen_parts` re-declared), `onResourceStop`, `chat:ready`.

## Items

`stolen_parts` (Stolen parts, 2 kg, **illegal**, not usable) is declared in `rp_inventory` through
`exports.rp_inventory:define` from this resource's `onResourceStart` and again whenever
`rp_inventory` restarts. `lockpick`, `synthcoke`, `implant_box` are `rp_inventory` built-ins,
`drug_pack` is declared by `rp_gangs`, `implant_box_*` by `rp_ripperdoc`.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`, keyed by `Open77.players.identifier` (never the session id):

```sql
rp_crime_log (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    identifier  VARCHAR(64) NOT NULL,      -- the criminal
    player_name VARCHAR(80) NOT NULL,      -- RP name at the time
    kind        VARCHAR(24) NOT NULL,      -- robbery | robbery_aborted | vehicle_theft | deal | crate_theft | fence
    target      VARCHAR(64) NOT NULL,      -- shop id | plate or vehicle#<id> | buyer identifier | prop#<id> | item id
    amount      INT         NOT NULL,      -- eddies (0 when none changed hands)
    `at`        BIGINT      NOT NULL,      -- unix seconds
    INDEX idx_rp_crime_identifier (identifier),
    INDEX idx_rp_crime_kind (kind)
)
```

Rows are written with the callback form (`Open77.database.insert`), never awaited on a command
path. **No database** (`ready` answers `database_unavailable`, or nothing answers 15 s after start —
`database.graceMs`): rows go to the resource's `Open77.kvp` store (`log:<seq>` JSON, the last 200
kept) and the log says `store=kvp reason=...`. Rows logged before the store answered are queued and
flushed. Cooldowns, the wanted list, gutted crates and pending deals live in memory.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``RpCrimeConfig.stage` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/braquer` | none: the iron stays on the vendor (a workspot would holster it) | `garbage.bag` loot bag in the left hand once the till is empty (`container.duffel` once it exists) | 20 s bar, then a 4 s gesture |
| `/crocheter` | `examine` crouch at the lock, looped (`lockpick`) | none (`tool.lockpick` once it exists) | 12 s bar |
| `/dealer` | the platform's `give` interaction animates both players | `crate.ammo_box` pack in the dealer's hand from the offer to the hand-over (`crime.drug_pack` once it exists) | the interaction (3 s) |
| `/voler` | `examine` crouch at the crate, looped (`lockpick`) | none; then the parts (`crate.ammo_box`) held up 2.5 s (`give`) | 8 s bar |
| `/receler`, E on Vik | `give` looped (`carry_putdown`) | `crate.ammo_box` in the right hand | 3 s bar |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_crime] player 3 stage robbery: pose=none prop=none place=none 20000 ms -> ok
[rp_crime] player 3 gesture loot: pose=none prop=garbage.bag@LeftHand 4000 ms
[rp_crime] player 3 stage lockpick: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=none place=none 12000 ms -> ok
[rp_crime] player 3 hold deal: pose=none prop=crate.ammo_box@RightHand
[rp_crime] player 3 stage pry: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=none place=none 8000 ms -> ok
[rp_crime] player 3 stage fence: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=crate.ammo_box@RightHand place=none 3000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Log (grep-able)

```text
[rp_crime] started: 5 shops to rob (cooldown 20 min), lockpick theft 12 s, deal 120 eddies, fence Vik the Fence at 1381.0 -1668.0 49.4 open 22:00-06:00
[rp_crime] items defined in rp_inventory: registered=1 rejected=0
[rp_crime] store=sql table=rp_crime_log
[rp_crime] fence Vik the Fence spawned template=gang_tygerclaws_ranged_01 record=Character.... id=... at 1381.0 -1668.0 49.4
[rp_crime] fence prompt declared (Sell stolen goods) on record Character....
[rp_crime] robbery started shop=supermarket by player 1 officers_on_duty=1
[rp_crime] robbery player 1 (<identifier>) target=supermarket amount=412
[rp_crime] vehicle_theft player 1 (<identifier>) target=NC-K7P2 amount=0
[rp_crime] deal offered dealer=1 buyer=2 price=120 interaction=...
[rp_crime] deal player 1 (<identifier>) target=<buyer identifier> amount=120
[rp_crime] crate_theft player 1 (<identifier>) target=prop#17 amount=0
[rp_crime] fence player 1 (<identifier>) target=stolen_parts amount=300
[rp_crime] fence sale player 1 paid=300 via=prompt
[rp_crime] no clock authority (environment_unavailable): the fence never closes
[rp_crime] fence record unknown: no E prompt (it would show on every NPC); /receler still works
```

## Manifest

Permissions: `network.events` (`chat:ready`, toasts), `database.access`, `world.vehicles`
(`nearby`, `getPosition`, `isLockedForPlayer`, `setLocked`, `triggerHorn`, `getPlayerSeat`),
`world.props` (`all`, `get` for the nomad crates; `create`, `remove` for the fence's own two
crates), `world.npcs` (the fence), `world.environment`
(`getState`), `players.life.read` (`isDead`), `player.weapons.read` (`weapons.get`),
`players.interactions.read` / `players.interactions.control` (the deal consent — the guide
requires them, the cards list no check, declared as rp_ncpd does).

Dependencies: `open77_uikit`, `open77_player_interactions`, `open77_interactions`,
`open77_notifications` (platform packages driven from the server), and — because this manifest is
**not** delivered to clients — the RP resources whose exports it calls: `rp_economy`, `rp_inventory`,
`rp_identity`, `rp_zones`, `rp_ncpd`, `rp_shops`, `rp_garage`, `rp_gangs`, `rp_nomade`. Every export is
still called inside `pcall` and degrades to a chat line. `rp_config` is optional: every number can
be overridden through `exports.rp_config:get("rp_crime.<path>")` (e.g. `rp_crime.deal.price`).
`rp_ferrailleur` is not called (the fence is this resource's own NPC, a few metres from the
scrappers' dealer in the same yard).

## Honest limits (measured against the devkit, not guessed)

- **A nomad crate cannot be removed or hidden by this resource**: `Open77.props.remove` / `update`
  answer `owned_by_another_resource` for `rp_nomade`'s props. The gutted crate stays where it is
  and `rp_nomade` still counts it — the driver can still pick it up and get paid for the box. Closing
  that needs an `rp_nomade` export (`crateStolen(propId)`) this phase does not define.
- **No E prompt on the crates.** The props API has no `data` field and no per-entity interaction
  hook a server-only resource could target; a `class` target would need the crate host's RTTI class,
  which the devkit does not document; and `rp_nomade` already owns a `Pick up the crate` prompt on
  every crate, so a second card on the same spot would fight it in the arbiter. `/voler` within 3 m
  is the plan's fallback and is what ships.
- **The fence prompt is filtered by record**: a `globalNpc` target matches every NPC, and a
  server-only resource cannot ship the client predicate `rp_gangs` uses, so the declarative
  `canInteract = { record = { <fence record> } }` keeps it on NPCs of the fence's own record. If
  another resource spawns the same record the card shows on theirs too — pressing it does nothing
  (the server checks the NPC id). When the record cannot be learned (alias with no record in
  `Open77.npcs.templates()`), no prompt is declared and `/receler` is the only door.
- **Weapon check is the owner's report.** `Open77.weapons.get` is a cache fed by the client's 20 Hz
  snapshot; a modified client could claim a drawn weapon. It decides, it does not assert.
- **`/plaque` on a `/car` ride never says WANTED**: rp_garage only prints its own rows. The APB tick
  and `wantedVehicles()` still cover it.
- **The ripper's prices are config.** `rp_ripperdoc` is not on this phase's contract sheet; until its
  prices are pasted into `fence.implantPrices`, every `implant_box*` sells at 40 % of 1000 €$.
- Voice lines (`greeting`, `rep_ask_to_leave`) are queued, not proven heard, and depend on the fence
  record's voiceset. `npc_not_streamed` (nobody near) is silent by design.

## Test in 2 minutes (one player, id `1`, at the Kabuki Market spawn)

Prerequisites: `rp_economy`, `rp_inventory`, `rp_identity`, `rp_zones`, `rp_ncpd`, `rp_shops`,
`rp_garage`, `rp_gangs`, `rp_nomade`, `open77_uikit`, `open77_player_interactions`,
`open77_interactions`, `open77_notifications`, `open77_weather`, `open77_weapons` running. Log on
start: `[rp_crime] started: 5 shops ...`, `items defined ...`, `store=sql ...`, `fence ... spawned`,
`fence prompt declared`.

1. **Robbery.** Walk 25 m north-east to Rosa on Noodle Row (-1178.7, 2028.5). `/braquer` with nothing in hand → `Rosa
   laughs at your empty hands. Draw a weapon first.` Get a gun (buy one at Wilson's: `/acheter licence`
   then `/acheter pistol`, or the platform's admin weapon command), draw it, `/braquer` → `You point your iron at Rosa...`,
   the **Emptying the till...** bar (20 s, X bails), log `robbery started shop=supermarket ...`. An
   officer on duty (console `setjob 2 ncpd 3`, `/service` on client 2) reads
   `[NCPD DISPATCH] ROBBERY: Noodle Row market is being robbed ...` with a map pin. At the end: `Rosa
   empties the register: 4xx eddies in your pocket. Now run.`, a toast, `/money` went up, log
   `robbery player 1 ... amount=4xx`, then a second dispatch line from rp_shops. With an officer on
   duty: `An officer was on duty: the robbery lands on your criminal record.` and `/casier 1` from
   the officer lists `[ROBBERY] Armed robbery of Noodle Row market (4xx eddies)`. `/braquer` again →
   `Noodle Row market was hit not long ago ... 20 min to go.` Walk 10 m away → `No vendor within 3 m
   (nearest: Noodle Row market, 10 m)`.
2. **Vehicle theft.** `/car` next to you, get out, stand 2 m from it. `/crocheter` → `That ... is
   not locked. Just open the door.` `/lock` (eval_carlock) then `/crocheter` → `No lockpick in your
   pockets...`. Console `giveitem 1 lockpick 2`. `/crocheter` → **Jimmying the lock...** (12 s), a
   short horn, `The lock gives. The ... is yours for the night (-- your lockpick snapped, half the
   time). Every badge in town will be looking for that ride.`; `/inv` shows 1 or 2 lockpicks; the
   door opens. Log `vehicle_theft player 1 ... target=vehicle#N`. The officer within 20 m reads
   `[APB] Wanted vehicle in sight: ..., no plate on file, 8 m away.` every 30 s. With a **dealership
   car** (console `givemoney 1 20000`, `/concession`, buy the Hella, it spawns locked) and a second
   player without a key: `/crocheter` from player 2 → unlock, `/plaque` on it shows **WANTED by the
   NCPD** (reason `stolen` for an officer), the owner reads `Somebody just jimmied the lock of your
   Archer Hella (plate NC-XXXX). Call the NCPD.`; the owner's own `/crocheter` answers `You hold a
   key to that Archer Hella. Open it the honest way: /verrouiller.`
3. **Street deal (two players).** Console `giveitem 1 drug_pack 1`; player 2 within 3 m with 120 €$
   cash. `/dealer 2` → player 2 reads `<name> offers you a drug pack for 120 eddies (cash).
   /interaction accept ...` + toast; `/interaction accept` → the give animation, then `Deal done:
   <name> took the pack for 120 eddies. Cash: ...` on both sides, `/inv` on player 2 shows the pack,
   `/money` moved 120 €$. With player 1 in a gang (`/gang creer maelstrom`) and standing in the
   market (the `kabuki_market` territory): `maelstrom influence in Kabuki Market: 1.` and
   `/territoire` shows it. One deal
   in five: `Somebody saw that. Badges are on their way.` and the officer's dispatch line. `/interaction
   decline` → `Deal off with <name> (declined).` Player 2 with 50 €$ → `<name> cannot cover 120
   eddies in cash. No deal.`
4. **Contraband.** Player 2 as a nomad (`setjob 2 nomade 0`, `/service`) accepts a contract at the
   Aldecaldos camp board (3.0 km east, `1790, 2252`): three crates appear at the camp's loading
   bay (rp_nomade's `Camp.loadingPoints`). Player 1 walks up to one:
   `/voler` → **Prying the crate open...** (8 s) → `You gut the crate: Stolen parts x1 in your
   pockets...`, player 2 reads `Somebody is gutting one of your crates at the loading bay!`, log
   `crate_theft player 1 ... target=prop#N`. `/voler` on the same crate → `That crate is already
   gutted.` Player 2 `/voler` on their own crate (only contract running) → `Steal your own cargo?
   Load it in the truck instead (/convoi).` A crate on player 2's shoulder → `It is in somebody's
   hands. Wait until it touches the ground.`
5. **Fence.** Drive 4.5 km south-east to the Rancho Coronado junkyard (toast **Badlands** and
   **Rancho Coronado Junkyard** on the way in); Vik stands at 1381, -1668 between two cargo
   crates with a **Sell stolen goods** card (E within 2.5 m, looking at him). By day, `/receler`
   (or E) → `Vik the Fence does not
   trade in daylight. Come back between 22:00 and 06:00 (it is 14:07).` Console
   `weather.time.set 23:00`. E → `Vik the Fence counts out 300 eddies for 1 x Stolen parts @ 300.
   "Never saw you."`, toast, `/money` +300, `/inv` no longer lists the parts, log `fence player 1 ...
   amount=300` and `fence sale player 1 paid=300 via=prompt`. Console `giveitem 1 implant_box 1`,
   `/receler` → `... 400 eddies for 1 x Implant box @ 400`. Nothing to sell → `Vik the Fence looks you
   over: "Nothing I want on you, choom..."`. From 10 m: `Vik the Fence is not within 5 m (you are 10 m
   away)...`
6. **From another resource:** `print(table.concat(exports.rp_crime:wantedVehicles(), ", "))` →
   `NC-XXXX, vehicle#12`. `SELECT kind, target, amount, player_name FROM rp_crime_log ORDER BY id
   DESC LIMIT 10;` lists the five crimes above.
