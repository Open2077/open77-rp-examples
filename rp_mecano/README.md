# rp_mecano — the garage job

Repairs, towing, paint jobs, invoices, the impound lot and refuelling for the Night City RP
build (Open77 `2.31.13+op77.76`). Server-authoritative: the server checks the job and the duty
state (`rp_jobs`), the pockets (`rp_inventory`), the cash (`rp_economy`), the society
(`rp_bank`) and the zone (`rp_zones`) on every command; the client only adds ALT+click entries
that send a request.

Every command needs the **`mecano` job, on duty** (`/agence` to sign, `/service` to clock in).
Only **server vehicles** are seen (`/car`, the dealership, another resource's spawn): vanilla
traffic has no canonical id and every command answers `No server vehicle within reach`.

## Commands

| Command | What it does |
|---|---|
| `/reparer` | Repairs the vehicle you sit in, or the nearest one within **4 m**. Needs a `toolkit` in the pockets (kept) and consumes **2 `component`**. A UI-kit progress bar of **15 s**, cancellable (X / Escape), movement and firing blocked. Everything is checked again when the bar ends (still on duty, still next to the car, still has the parts) before `Open77.vehicles.repair(id, "full")` and `setHealth(id, 1.0)`. A mint car or a wreck is refused; panels already torn off cannot come back (engine limit, the player is told). |
| `/remorquer` | From the **driver's seat** of your truck: hooks the nearest **empty** server vehicle within **8 m**. Every **2 s** the towed car is moved **6 m behind** the truck (`Open77.vehicles.setTransform`, same heading) — there is no attach/tow native on op77.76, see below. `/remorquer` again releases. The tow also ends when you leave the wheel, clock out, disconnect, when the car is removed, or when somebody climbs into it. |
| `/peindre <colour> [second]` | Paints the nearest vehicle within **6 m** (or the one you sit in). Colours: `black white grey silver chrome red crimson orange yellow gold green lime teal cyan blue navy purple pink magenta brown sand arasaka militech samurai` or `#RRGGBB`. The **driver** (else the first passenger) receives an invoice of **250 €$** through the invoice flow; the paint goes on and the **`paint_can`** is consumed **when they pay**. No one aboard, or the mechanic at the wheel: painted at once, on the house. |
| `/facture <playerId> <amount> [reason]` | Hands an invoice to a player within **10 m**. The customer gets the platform **accept / decline prompt** (`open77_player_interactions`, kind `custom`) — or, when the prompt cannot be used (customer in a vehicle, too far, already reserved), a **chat consent**: `/facture ok` pays, `/facture non` refuses, 60 s to answer. On accept the cash is taken with `rp_economy:remove`: **70 %** to the mechanic, **30 %** to the `mecano` society (`rp_bank:societyAdd`). Short on cash → refused, both told. Cap **50 000 €$**. `/facture` alone shows the invoice waiting for you. |
| `/fourriere` | Inside the **`junkyard`** zone (`rp_zones`, the Rancho Coronado junkyard): removes the nearest server vehicle within **8 m** with **nobody seated**, credits **100 €$** to the society and logs the record, the plate (state-bag key `plate`, `none` when the car has none) and the position in `rp_mecano_impound`. `/fourriere registre` prints the last five entries. |
| `/plein` | Refuels the vehicle you sit in or the nearest within **4 m** through `exports.open77_fuel:refuel` (to the brim by default, `Config.fuel.litresPerCan` for a fixed amount) and consumes one **`chooh2`** can. Without `open77_fuel` the can stays and the player is told. |

Every refusal is one chat line: not a mechanic, off duty, no toolkit / parts / can, nothing in
reach, too far (with the distance), mint condition, wreck, somebody aboard, not in the garage
zone, wallet or bank offline, customer short on eddies... From the server console every command
answers `run it from the game`.

**ALT+click** (`open77_contextmenu`), shown only to an on-duty mechanic (the server pushes the
duty state, and checks again on every request): on a player **Hand an invoice (garage)** (a UI-kit
form: amount + reason, then the same consent flow); on a vehicle **Repair**, **Paint job**
(colour picker), **Hook / release tow**, **Refuel**, **Impound**.

## Where things are

| What | Position | Notes |
|---|---|---|
| Workshop ring — **Afterlife street garage** | `-1396.0, 966.0, 23.5`, r 3 | the real street outside The Afterlife's ramp (Little China, Watson): probed, crosswalk, a car fits. `Config.workshop` |
| CHOOH2 pump ring | `-1390.0, 972.0, 23.5`, r 1.5 | 6 m along the same street. `Config.pump` |
| Garage sign prop | `-1392.4, 966.0, 26.0`, yaw 90 | `sign.street`, pavement side |
| Tyre blockers (2) | `-1393.2, 963.0` and `-1393.2, 969.0`, z 23.5 | `barrier.tire_blocker` (twice), pavement side |
| Gas pump prop | `-1392.0, 973.0, 23.5`, yaw 90 | `industrial.gas_pump`, by the pump ring |
| Impound / tow yard | `junkyard` zone, centre `1370, -1680, 49.3`, r 90 | Rancho Coronado junkyard, ~4.5 km from Kabuki |
| Spawn (`Config.spawn`) | `-1191.3, 2006.9, 7.82` | Kabuki Market Centre |

The two rings are bare markers (`open77_worldui`, nothing to press): every command works
wherever the car is, the rings say where the garage lives. From the Kabuki Market spawn the
workshop is about **1.1 km south** as the crow flies; the Kabuki market lanes themselves are
pedestrian, drive out by the South Gate street (`-1218, 1950`).

**Props.** At start the server spawns `Config.props` through `Open77.props.create` (permission
`world.props`, curated prop aliases (see `prop.catalog`) — a raw `.mesh` path renders as a white
slab) and removes them at stop. A refused prop is logged (`prop N (...) not spawned: <reason>`);
the garage works without it.

## Items

Registered in `rp_inventory` through `exports.rp_inventory:define` on start and again whenever
`rp_inventory` restarts (`shared/items.lua`):

| id | label | kg | usable |
|---|---|---|---|
| `toolkit` | Mechanic's toolkit | 3.0 | no — required by `/reparer`, never consumed |
| `paint_can` | Spray paint can | 1.0 | no — one per paint job |

`component` (repair) and `chooh2` (refuel) are `rp_inventory`'s own items.

## Exports (server, synchronous, never yield)

```lua
exports.rp_mecano:repair(vehicleId, byPlayerId)
-- true | nil, "invalid_vehicle_id" | "vehicle_not_found" | "vehicle_destroyed" | "repair_failed"
-- A full repair + health 1.0, no progress bar, no item cost: the caller decides those.
-- Raises rp_mecano:repaired(vehicleId, byPlayerId or 0, "full").

exports.rp_mecano:bill(fromPlayerId, toPlayerId, amount, reason)
-- billId | nil, "invalid_player_id" | "invalid_from" | "invalid_to" | "self_bill" | "invalid_amount"
--        | "amount_too_large" | "invalid_reason" | "player_not_found" | "mechanic_not_found" | "target_busy"
-- Starts the consent flow (prompt, else chat) and returns at once; the outcome arrives on the
-- rp_mecano:bill event. Money split as for /facture. No distance check for export callers.
```

Call them inside `pcall` from another resource. `rp_mecano` ships a client script, so a resource
that also ships one may still declare `dependency "rp_mecano"`.

## Events (host bus, `TriggerEvent`)

| Event | Arguments | When |
|---|---|---|
| `rp_mecano:bill` | `billId, fromPlayerId, toPlayerId, amount, status` | Every settled invoice. `status`: `paid`, `declined:<reason>` (`declined`, `timeout`, `customer_left`, `mechanic_left`, the interaction's own reason...), `refused:insufficient_funds`, `refused:economy_offline`, `void:<why>` (a paint job whose car drove off or whose mechanic lost the can). |
| `rp_mecano:repaired` | `vehicleId, byPlayerId, scope` | After `/reparer`, the ALT+click repair or the export. |
| `rp_mecano:painted` | `vehicleId, byPlayerId, primary, secondary` | After a paint job went on. |
| `rp_mecano:tow` | `vehicleId, mechanicId, hooked:boolean, reason` | Hook (`hooked`) and release (`released`, `left_wheel`, `vehicle_gone`, `truck_gone`, `someone_aboard`, `transform_refused`, `off_duty`, `disconnected`). |
| `rp_mecano:impounded` | `vehicleId, byPlayerId, record, plate` | After the vehicle was removed and logged. |
| `rp_mecano:refuelled` | `vehicleId, byPlayerId, litres` | After `/plein`. |

Internal net events (`rp_mecano:duty`, `rp_mecano:whoami`, `rp_mecano:action`,
`rp_mecano:billMenu`) are the client/server transport of the ALT+click entries, not an API.

## Persistence

Both tables are created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`
(permission `database.access`) and written through with the callback forms — the exports never
touch the database:

```sql
rp_mecano_impound (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    vehicle_id    BIGINT       NOT NULL,   -- the canonical vehicle id at the time
    record        VARCHAR(256) NOT NULL,   -- Vehicle.* TweakDB record
    plate         VARCHAR(16)  NULL,       -- state-bag `plate` key, NULL when none
    x, y, z       DOUBLE       NOT NULL,   -- where it stood
    by_identifier VARCHAR(64)  NOT NULL,   -- Open77.players.identifier of the mechanic
    by_name       VARCHAR(80)  NOT NULL,
    fee           INT          NOT NULL,   -- eddies credited to the society
    at            BIGINT       NOT NULL    -- unix seconds
)
rp_mecano_invoices (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    from_identifier VARCHAR(64) NOT NULL,  -- the mechanic
    to_identifier   VARCHAR(64) NOT NULL,  -- the customer
    amount          INT         NOT NULL,
    reason          VARCHAR(64) NOT NULL,
    status          VARCHAR(48) NOT NULL,  -- paid | declined:<why> | refused:<why> | void:<why>
    at              BIGINT      NOT NULL
)
```

**No database** (`ready` answers `database_unavailable`, or nothing answers 15 s after start):
both ledgers fall back to the resource's `Open77.kvp` store (`impound:<n>` / `invoice:<n>`,
pipe-separated lines) and the log says `[rp_mecano] store=kvp reason=...`. Pending invoices and
tows live in memory only and are dropped on disconnect and on restart.

## Configuration (`shared/config.lua`)

Everything is in `Config`: reaches, the 15 s / 2 components of a repair, the tow tick /
distance, the colour table and the 250 €$ paint price, the invoice cap / timeout / 70 % share,
the impound zone name / fee, the refuel amount. Positions:

- `Config.spawn` — the freeroam spawn, Kabuki Market Centre `-1191.3, 2006.9, 7.82`.
- `Config.workshop` / `Config.pump` — the two street rings above; `Config.props` — the four
  props.
- `Config.impound.zone = "junkyard"` — the `rp_zones` Rancho Coronado junkyard: centre
  **1374.9, -1674.9, 49.3**, radius 90 m (the owner moves it by editing
  `rp_zones/shared/config.lua`; this resource only knows the name).
  `Config.impound.fallbackCenter / fallbackRadius` (`1370, -1680`, 90 m) copy that circle for a
  server without `rp_zones`.
- **`Config.impoundAnywhereForTesting`** (default `false`): when `true`, `/fourriere` also works
  within **6 m** (`testingReach`) of the Kabuki Market Centre or the workshop ring
  (`testingSpots`), so a tester never has to drive to the junkyard.

## Towing without an attach native

The op77.76 catalogue has no server-side attach / tow / trailer native (`open77_search` for
*tow*, *attach*, *trailer*, *rope*; `open77_fivem_equivalent AttachEntityToEntity` answers
"not in the alias table"). The tow is therefore a **2 s tick**: read the truck's
`getPosition` / `getHeading`, compute the point 6 m behind, `Open77.vehicles.setTransform` the
towed car there with the truck's yaw. The tick is skipped while the truck has not moved 0.3 m,
so a parked pair does not jitter. Yaw 0 faces +y on this engine; the rotation sign of the
forward vector is not documented, so `Config.tow.yawSign` is only a starting guess and the
resource **calibrates it once** against the truck's velocity (`getVelocity`, `reversing`) the
first time the truck drives faster than 1.5 m/s — if the towed car ever appears in front of the
truck it flips on the next tick and logs `tow: yaw sign flipped`. It is a teleport chain, not
physics: the towed car has no wheels on the ground between ticks.

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
| `/reparer` | `examine` kneel, looped (`repair` / `mechanic`) | `tool.welder` in the right hand, `container.toolbox` at the feet | 15 s bar |
| `/peindre` | `drink` profile's own can held (`stand__rh_can__01__shuffle__01`), looped: the spray can | none (the profile's can) | 8 s bar, before the paint (on the house) or after the customer pays |
| `/plein` | `examine` kneel at the tank, looped (`mechanic`) | `container.gas_can` in the right hand | 6 s bar |
| `/facture`, ALT+click invoice | `phone` one-shot: the bill typed on the holo | none (the profile's holo) | 3 s, then the consent prompt |
| `/fourriere` | `phone` looped: calling the yard | none | 4 s bar |
| `/remorquer` | none: the mechanic is at the wheel (`player_in_vehicle`) | -- | -- |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_mecano] player 3 stage repair: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=tool.welder@RightHand place=container.toolbox 15000 ms -> ok
[rp_mecano] player 3 stage paint: pose=drink/stand__rh_can__01__shuffle__01 prop=none place=none 8000 ms -> ok
[rp_mecano] player 3 stage refuel: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=container.gas_can@RightHand place=none 6000 ms -> ok
[rp_mecano] player 3 gesture invoice: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 3000 ms
[rp_mecano] player 3 stage impound: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none place=none 4000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.
A paid paint job: the customer pays first, then the mechanic sprays for the bar's length and the paint goes on; capping the can early keeps the payment and tells the mechanic to `/peindre` again on the house.

## Manifest

Permissions `world.vehicles` (every vehicle read and write), `database.access`,
`network.events` (net events, toasts), `players.interactions.control` / `.read` (the consent
flow, as the player-interactions guide requires), `world.props` (the street props).
Dependencies — all ship a client half — `open77_uikit`, `open77_worldui` (the two rings),
`open77_contextmenu`, `open77_player_interactions`, `open77_notifications`, `rp_jobs`,
`rp_inventory`. `rp_economy`, `rp_bank`, `rp_identity` (names) are server-only and
reached through `pcall`; `rp_zones` and `open77_fuel` are optional (fallbacks above).

## Log (grep-able)

```text
[rp_mecano] props spawned: 4
[rp_mecano] started: job=mecano society=mecano repair=15000 ms / 2 components, tow every 2000 ms at 6 m, paint 250, impound zone=junkyard fee=100 testing=false
[rp_mecano] store=sql tables=rp_mecano_impound,rp_mecano_invoices
[rp_mecano] items registered: toolkit,paint_can (rejected: 0)
[rp_mecano] player 1 repaired vehicle 12 (Vehicle.v_standard2_archer_hella_player, scope=full, 2.3 m)
[rp_mecano] invoice #1: 1 -> player 2, 250 eddies, paint job red, mode=chat
[rp_mecano] invoice #1 paid: 250 from player 2 to player 1 (mechanic 175, society 75, paint job red)
[rp_mecano] player 1 painted vehicle 12 #C8102E / #C8102E
[rp_mecano] player 1 tows vehicle 12 (Vehicle...) behind truck 13
[rp_mecano] player 1 tow of vehicle 12 ended: released
[rp_mecano] player 1 impounded vehicle 12 (Vehicle...) plate=none via zone
[rp_mecano] impound row 1: vehicle 12 (Vehicle...) plate=none by <identifier>
```

## Test in 2 minutes

Two clients on the Afterlife street (`-1396, 966, 23.5`, the workshop ring — drive there from
the Kabuki Market spawn, ~1.1 km south, or console `tp <id> -1396 966 23.6`): **1** = mechanic,
**2** = customer. `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_bank`, `rp_zones`, `open77_uikit`,
`open77_contextmenu`, `open77_player_interactions`, `open77_notifications` running (and
`open77_fuel` for step 8). Start log: `[rp_mecano] started: ...`, `store=sql ...`,
`items registered: toolkit,paint_can`, `props spawned: 4`. At the street: the workshop ring
with the garage sign and two tyre blockers on the pavement side, the pump ring 6 m along the
street with its gas pump.

1. **Console:** `setjob 1 mecano 1` · `giveitem 1 toolkit 1` · `giveitem 1 component 4` ·
   `giveitem 1 paint_can 2` · `giveitem 1 chooh2 1`. Player 2 keeps the default 500 €$ cash.
2. Player 1: `/reparer` → `Clock in first: /service.` Then `/service` → clocked in.
   Player 2: `/reparer` → `You are no mechanic, choom. ...`
3. Player 2 spawns a server vehicle (`/car`) on the workshop ring and bumps it into the
   concrete a few times so the body takes damage. Player 1, 10 m away: `/reparer` → `No server vehicle
   within reach...`; within 4 m: `/reparer` → bottom progress bar **Fixing the <car>** for 15 s
   (press X: `Repair cancelled.`, nothing spent); let it finish → `<car> repaired (full). 2
   components used.` `/inv` shows 2 components left. `/reparer` again → `... mint condition.`
4. Player 2 sits at the wheel. Player 1 within 6 m: `/peindre red` → player 1 `Paint job red on
   the <car>: 250 €$ invoiced to <name>. The paint goes on when they pay.`; player 2 gets the
   toast **Garage invoice** and the chat line `... /facture ok to pay, /facture non to refuse
   (60 s).` (chat mode: a seated customer cannot take the prompt). Player 2: `/facture ok` →
   the car turns red, player 2 `Paid 250 €$ to <mechanic> ... Cash left: 250 €$.`, player 1
   `... Your cut: 175 €$, garage: 75 €$.` and one paint can is gone. `/job` on player 1 shows
   the society at 75 €$.
5. Both on foot, 3 m apart. Player 1: `/facture 2 100 oil change` → player 2 sees the
   platform **accept / decline** prompt (or `/interaction accept`) → `Paid 100 €$ ...`.
   `/facture 2 100` again and player 2 **declines** → `<name> declined invoice #3 ...`.
   `/facture 2 999999` → `... caps an invoice at 50 000 €$`. `/facture 2 400` with player 2
   at 150 €$ cash, accepted → `<name> is short on eddies: invoice #4 of 400 €$ refused.`
6. ALT+click player 2 → **Hand an invoice (garage)** → form amount 50, reason `tyres` → the
   same flow. ALT+click the car → the five **Garage** entries (player 2 sees none).
7. Player 1 spawns a second vehicle (the "truck"), sits at the wheel within 8 m of player 2's
   empty car: `/remorquer` → `<car> hooked (x m). It follows 6 m behind your truck; /remorquer
   again to release.` Drive down the street: the car re-appears 6 m behind every 2 s (log
   `tow: yaw sign flipped` once if the starting guess was wrong). `/remorquer` → `Tow released.`
   Step out during a tow → `You left the wheel: tow released.`
8. Player 1 in a car: `/plein` → `<car> refuelled: N L in the tank. One CHOOH2 can used.`
   (without `open77_fuel`: `No fuel system on this server ...`, can kept).
9. Player 1 drives an empty car to the Rancho Coronado junkyard (`1374.9, -1674.9`, east
   then south into the Badlands edge; `/zone` → `junkyard`), steps out, `/fourriere` → `<car>
   impounded (plate none, x m). Garage +100 €$ (society 175 €$).` — the car is gone;
   `/fourriere registre` lists it; the row is in `rp_mecano_impound`. From the street:
   `/fourriere` → `The impound lot is the Rancho Coronado junkyard (zone junkyard, around 1370,
   -1680)...` unless `Config.impoundAnywhereForTesting = true`, which allows it within 6 m of
   the Kabuki Market Centre or the workshop ring.
10. From another resource: `print(exports.rp_mecano:repair(vehicleId, 1))` → `true`;
    `print(exports.rp_mecano:bill(1, 2, 30, "test"))` → a bill id, then the prompt on player 2
    and `rp_mecano:bill(billId, 1, 2, 30, "paid")` on the bus.
