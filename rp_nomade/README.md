# rp_nomade — convoys and crate deliveries in the Badlands

The scripted run of the `nomade` job (rp_jobs v2), replacing the v1 courier mission. Build
target **2.31.13+op77.76**. Server-authoritative: the client draws rings and prompts and sends
intents; the server decides the job gate, the money, the truck, the crates, the zones, the
ambush and the pay.

The run, as one player sees it:

1. **Contracts board** — a ring, a map pin and an `E` prompt at the Aldecaldos camp
   (`open77_worldui`, `promptDistance = 3.0`). It opens a UI-kit context menu of contract templates
   (`shared/config.lua`): crates 2–4, destination zone, pay per crate, time limit.
2. **Accept** — the truck deposit (**100 €$ cash**) is taken, a **Thorton Mackinaw**
   (`Vehicle.v_standard3_thorton_mackinaw_player`, a player-spawnable `_player` record) is spawned
   at the camp's truck spot, and N **crate props** (`crate.small`, `Open77.props`) appear at the
   loading points. Each crate gets its own ring + `E` prompt **Pick up the crate**.
3. **Carry** — `E` on a crate: you bend down (`Carry.steps.pickup`, 2.5 s, profile `scavenge` /
   `examine`), then the crate prop is attached in front of your chest (`Open77.props.attach`, root
   binding, `Carry.offset`: everybody sees you carrying it) and a two-hand carry pose loops
   (`Open77.animations.play`, profile `tablet2` or `phone`, see
   [Carrying and the bed](#carrying-and-the-truck-bed-how-to-tune)). One crate at a time. The pose
   is a workspot: it stops while you walk and comes back once you stand still.
4. **Load** — `E` on the rented truck, within 4 m: **Load the crate**. You lift it in
   (`Carry.steps.load`, 2 s, profile `give`); when the clip is over the crate leaves your arms and
   is **attached to the truck** in the next free bed slot (`Truck.bed.slots`, vehicle attachment),
   so the cargo is visible in the back. Log:
   `[rp_nomade] player 3 loaded crate 2/3 (load=give/... 2000ms, bed slot 2, attached to truck 17)`.
5. **Drive** — the destination is pinned on the map from acceptance; once the last crate is in
   the truck the chat names the destination with its distance and the vanilla **GPS route** is
   set (`Open77.blips.setWaypoint`). A ring marks the destination. The **first** time the loaded
   truck crosses the ambush circle on the road, **3 hostile NPCs** spawn 15 m away and attack the
   driver; they are removed after 3 minutes or when the contract ends.
6. **Unload** — inside the destination zone (`rp_zones:isIn`; a planar-distance check for a
   destination rp_zones does not know, `zone = false`), `E` on the truck: **Unload**. A
   sequence per crate, all animated and server-driven: take it out of the bed (`steps.take`, 2 s,
   `give`; the crate jumps from the bed to your arms), carry it a moment (`steps.carryMs`, 1.5 s,
   the carry loop), put it down (`steps.putdown`, 2.5 s, `scavenge` / `examine`; the crate is
   placed on the ground beside the truck, where it stays 30 s or until the run ends). Walking off
   between two crates stops the unloading. Then the pay: **150 €$ per crate** in cash, a
   **25 % convoy bonus** (split between the nomads on duty within 30 m of the truck, driver
   included, when there are two or more), and **15 %** of the gross credited to the `nomade`
   society (`rp_bank:societyAdd`, on top of the pay). The contract is written to SQL.
   Log: `[rp_nomade] player 3 delivered 3 crates pay=450 bonus=0 convoy=1 society=+68`.
7. **Return** — after the delivery the map pin and GPS route move to the camp. Bring the truck
   back inside the camp zone, `E` on it: **Return the truck**. The truck is removed and the
   100 €$ deposit refunded. `/convoi annuler` at any time drops the run (a carried crate is put
   down first, then truck and crates are removed, deposit kept by the clan).

Time limit: **20 minutes** from acceptance to the last unloaded crate (the return has no clock;
the vehicle registry removes a forgotten truck after 40 min).

## Carrying and the truck bed: how to tune

Everything below is a **measured guess** the owner is expected to tune from the game; the numbers
live in `shared/config.lua` and reload with the resource (`refresh` then `restart rp_nomade`).

**The crate in the hands** (`RpNomadeConfig.Carry`). The binding is the one of
`wiki/attachments.md`: `Open77.props.attach(propId, { parentType = "player", parentId, bone,
offset, rotation })`. `bone` is a named slot of the player rig (`RightHand`, `LeftHand`, `Chest`,
`Head`) or `""` for the body root; `offset` is metres **in that slot's own frame**, `rotation`
degrees (x roll, y pitch, z yaw). The resource binds to the **root** (`bone = ""`) on purpose: it
is the only frame whose axes are known (+y where the player faces, +x their right, +z up, origin
at the feet), and a hand slot swings with the arm while the root keeps the box level in front of
the torso whatever the arms do. Defaults for `crate.small`:

| Key | Default | Effect |
|---|---|---|
| `Carry.bone` | `""` (root) | `"Chest"` binds to the spine slot instead: the box then follows crouching, but the slot's axes are not measured, so start from `offset = {0,0,0}` and move one axis at a time |
| `Carry.offset.y` | `0.45` | forward: the box sits in the body → raise; it floats away from the forearms → lower |
| `Carry.offset.z` | `0.85` | height of the crate pivot (forearm height): too high → lower |
| `Carry.offset.x` | `0.0` | sideways |
| `Carry.rotation` | `{0,0,0}` | z turns the box around the vertical |

For `crate.cargo` (~0.9 m cube) start from `y = 0.6, z = 0.7`. The crate mesh's pivot was not
measured: if it sits at the bottom of the mesh the box appears higher than the number says.

**The carry pose** (`RpNomadeConfig.Carry.animation`). A synchronized RP animation
(`Open77.animations.play(playerId, profile, { clip, loop = true })`, permission
`players.animations.control`), looped while the crate is held and stopped on load, drop (downed),
cancel, disconnect and death. **No catalogue on 2.31 ships a box-carry clip** (the vanilla
`bodycarry` / `jackie__stand__rh_flathead_box` names in `docs/data/emote-animations.txt` are not
addressable by any shipped device). `profiles` are tried in order at start and the first one the
server's `open77_animations` catalogue knows is used:

| Profile | Catalogue | Clip | Why |
|---|---|---|---|
| `tablet2` | 76-profile (`Work on tablet`) | default `stand__2h_tablet__02__use_tablet__01` | two hands holding a tablet at chest height, the closest two-hand hold |
| `phone` | 18-profile (`Use a phone`, the one deployed) | `stand__2h_phone__03__shuffle__01` | both hands in front of the chest, idle shuffle (no tapping) |

RP animations are workspots, and the platform cancels one as soon as the player walks more than
0.5 m, gets in a vehicle or dies; locomotion is never frozen and there is no upper-body mask
(`upperBody` is refused by the API). So the pose plays at pickup, drops while you walk, and comes
back once you have stood still for `resumeAfterMs` (1500 ms, moved less than `stillDistance` =
0.15 m between two server ticks). Each start briefly switches the local view to the third-person
body. `resume = false` keeps only the pickup pose; `enabled = false` carries the crate alone. A
refused pose is logged once per crate and never blocks the run.

**The steps** (`RpNomadeConfig.Carry.steps`). Nothing moves instantly any more: every crate move
is a one-shot clip (`Open77.animations.play(playerId, profile, { loop = false, durationMs = ms })`)
and the prop move (attach / detach / place) happens **when the step timer ends**. The timer is
the resource own: no catalogue exposes clip lengths and the API `durationMs` is a scheduling
duration, so `ms` is what you tune to the clip. While a step runs (`busy` in the snapshot) the
truck prompts are hidden and every intent answers `Finish what you are doing first.`

| Step | When | Profiles tried (first known wins) | Default `ms` | At the end of the timer |
|---|---|---|---|---|
| `pickup` | E on a crate | `scavenge` (76-profile, kneel and rummage), `examine` (18-profile, kneel and inspect the ground) | 2500 | crate attached to the player, carry loop starts |
| `load` | E Load on the truck | `give` (arms extend to hand an item over) | 2000 | crate detached from the player, attached to the bed slot |
| `take` | each crate at unloading | `give` | 2000 | crate detached from the bed, attached to the player, carry loop |
| `carryMs` | between take and put-down | the carry loop | 1500 | put-down starts |
| `putdown` | unloading, `/convoi annuler` while carrying, downed while carrying | `scavenge`, `examine` | 2500 | crate placed on the ground (`groundGap` 1.2 m from the truck on the driver side, `groundSpacing` 0.9 m, rows of two) for `groundTtlMs` (30 s), or back at the loading bay when downed |

No shipped profile is a real "lift a box" or "put a box down": the kneel-to-the-ground profiles
stand in for bending, `give` for lifting into and out of the bed. A step whose profiles are all
unknown, or whose `ms` is under 1000 (the API minimum), still waits `ms` without a clip.

**The truck bed** (`RpNomadeConfig.Truck.bed`). A loaded crate is
`Open77.props.attach(propId, { parentType = "vehicle", parentId = truckId, bone = "", offset,
rotation })`: offsets are metres in the **vehicle frame** (+x right, +y towards the cab, -y behind
it, +z up), `yaw` turns the crate around z. Crate n takes `slots[((n - 1) % #slots) + 1]`; with
more crates than slots the next layer sits `stackHeight` (0.55 m) higher. Four slots ship for the
Mackinaw (templates go up to four crates):

```lua
slots = {
    { x = -0.55, y = -1.5, z = 0.9, yaw = 0.0 },   -- front left, behind the cab
    { x =  0.55, y = -1.5, z = 0.9, yaw = 0.0 },   -- front right
    { x = -0.55, y = -2.4, z = 0.9, yaw = 0.0 },   -- rear left
    { x =  0.55, y = -2.4, z = 0.9, yaw = 0.0 },   -- rear right
},
```

Tune with a loaded truck in front of you: a crate that sinks into the bed floor → raise `z`; one
that hangs off the tailgate → move `y` towards -1.0; one inside the cab → move `y` towards -2.6.
Attached props are visual-only (no collision) so nothing here can push the truck. If the vehicle
attachment is refused the prop is removed and the crate is still counted (log:
`attach of crate ... to truck ... refused: <reason> (prop removed, crate still counted)`).
Bed crates are removed one by one at unloading and all at once by every path that ends the
contract (cancel, return, expiry, lost truck, `onVehicleRemoved`, disconnect, resource stop) —
the platform detaches them when the truck vanishes, the resource then removes the props.

**Navigation** (`RpNomadeConfig.Navigation`, client, permission `ui.vanilla.map`). A map pin
(`Open77.blips.create`, sprite `destinationSprite` = `objective`) on the destination from
acceptance, the vanilla GPS route (`Open77.blips.setWaypoint`, a routable custom-position pin the
minimap draws a road path to) once every crate is loaded (`gpsFrom = "accepted"` to route from
acceptance), then a pin (`campSprite` = `quest`) + route on the camp once everything is delivered.
Pin and route are removed on unload, cancel, return, disconnect and resource stop. The chat line
at the last load names the destination and its planar distance and bearing
(`The Rancho Coronado junkyard is 4012 m south from here: the GPS route is on your map.`).

## Commands

| Command | Who | Effect |
|---|---|---|
| `/convoi` | anyone | Status of your contract: template and destination, crates loaded / delivered / carried, time left, the truck, the current convoy (nomads on duty within 30 m), whether the Wraiths already hit you. |
| `/convoi annuler` | driver | Drops the contract: crates and truck removed, ambush cleared, the deposit is **not** refunded. |
| `/convois` | nomad **boss** (`rp_jobs:isBoss` + job `nomade`) | The last 10 contracts from SQL: who, template, destination, crates delivered, pay, bonus, society cut, convoy size, status, duration, when. |
| `/camp` | anyone | The camp's coordinates and how far / which way it is from you. |

`/contrat` from the plan sheet was **renamed `/convoi`**: `contrat` is already registered by
`rp_trauma` (Trauma Team contracts) and a second registrant is served silently. From the server
console, `/convoi` `/convois` answer `run this from the game`; `/camp` prints the coordinates.

Every refusal is explained in chat (`Convoys` author, sand colour): not a nomad, off duty, too
far from the board / crate / truck (with the distance), hands full, wrong truck, not at the
warehouse, cargo still in the back, not inside the camp, wallet short, wallet or bank offline.

## Prompts (client) and intents (server)

| Where | Prompt | Client event → server event | Server re-checks |
|---|---|---|---|
| Camp, `Config.Camp.board` | **Contracts board** (`open77_worldui`) | `rp_nomade:ui:board` → `rp_nomade:board` | within `board.reach` (5 m), job `nomade` + on duty, no contract running |
| Each crate on the ground | **Pick up the crate** (`open77_worldui`, one POI per crate) | `rp_nomade:ui:crate<i>` → `rp_nomade:pickup (i)` | contract active, crate `i` on the ground, hands empty, within 3.5 m |
| Rented truck | **Load the crate** (`open77_interactions` globalVehicle, `canInteract = "canLoad"`) | `rp_nomade:ui:load` → `rp_nomade:load (vehicleId)` | it is *your* truck, within 4 m, carrying a crate |
| Rented truck, in the destination zone | **Unload** (`canInteract = "canUnload"`) | `rp_nomade:ui:unload` → `rp_nomade:unload (vehicleId)` | your truck, within 4 m, `rp_zones:isIn(destination)`, crates in the back |
| Rented truck, in the camp zone | **Return the truck** (`canInteract = "canReturn"`) | `rp_nomade:ui:return` → `rp_nomade:return (vehicleId)` | your truck, within 4 m, `rp_zones:isIn(nomad_camp)`, nothing carried, nothing left in the back |

The three truck prompts are one `globalVehicle` target each; their `canInteract` exports read
only the last snapshot the server pushed (`rp_nomade:state`), so a prompt never shows on somebody
else's Mackinaw and the player is never asked to press something the server would refuse. The
snapshot also rebuilds the crate POIs and the destination ring after a client reload
(`rp_nomade:clientReady`).

## Exports (server, synchronous — never yield)

```lua
exports.rp_nomade:activeContract(playerId)
-- { id, template, label, destination, crates, loaded, delivered, carrying, status, truckId, ambushed } | nil
exports.rp_nomade:hasContract(playerId)   -- boolean
```

`status` is `active` (running) or `delivered` (paid, waiting for the truck to come back). Call
them inside `pcall`: this resource ships a client script, so a resource **with** a client script
must not declare `dependency "rp_nomade"`.

## Events

None of its own on the host bus. It **consumes** `rp_zones:entered` / `rp_zones:left` (the
destination and camp flags that reveal the Unload / Return prompts), `onPlayerDisconnected`
(contract abandoned, everything removed), `onPlayerLifeStateChanged` (down while carrying: the
crate goes back to its loading point), `onVehicleRemoved` (truck lost: the run ends) and
`open77:helditem:completed` (log only, `held` carry mode) and `onPlayerAnimationChanged` (the
carry pose was cancelled by the platform, typically because the carrier walked: the tick replays
it once they stand still).

Internal net events (`rp_nomade:state`, `rp_nomade:clientReady`, `rp_nomade:board`,
`rp_nomade:pickup`, `rp_nomade:load`, `rp_nomade:unload`, `rp_nomade:return`) are this
resource's client/server transport, not an API.

## Money and pay (all through pcall'd exports)

| Movement | Call |
|---|---|
| Deposit at acceptance | `rp_economy:remove(driver, 100, "nomade:rental")` — refused → no truck |
| Deposit back at the return | `rp_economy:add(driver, 100, "nomade:rental_refund")` |
| Pay per delivered crate | `rp_economy:add(driver, crates × 150, "nomade:delivery")` |
| Convoy bonus | 25 % of the gross, `floor(bonus / members)` to each member, `"nomade:convoy"` — only when ≥ 2 nomads on duty (driver included) are within 30 m of the truck at the moment of payment |
| Society | `rp_bank:societyAdd("nomade", 15 % of the gross, "nomade:contract:<id>")` — on top of the pay, not deducted |

`RpNomadeConfig.Contract` holds every number. A wallet or bank that refuses is logged and the
player told; the contract row keeps what was actually paid.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`:

```sql
rp_nomade_contracts (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    identifier  VARCHAR(64)  NOT NULL,      -- Open77.players.identifier of the driver, never the session id
    player_name VARCHAR(80)  NOT NULL DEFAULT '',
    template    VARCHAR(32)  NOT NULL,      -- template id (scav_parts, ...)
    destination VARCHAR(32)  NOT NULL,      -- rp_zones name
    crates      TINYINT      NOT NULL DEFAULT 0,
    delivered   TINYINT      NOT NULL DEFAULT 0,
    pay         INT          NOT NULL DEFAULT 0,   -- cash actually paid to the driver
    bonus       INT          NOT NULL DEFAULT 0,   -- convoy bonus, total
    society_cut INT          NOT NULL DEFAULT 0,   -- credited to the nomade society
    convoy      TINYINT      NOT NULL DEFAULT 1,   -- largest convoy seen at a payment
    status      VARCHAR(16)  NOT NULL DEFAULT 'active',
                -- active, delivered, returned (truck back before any delivery), cancelled,
                -- expired, abandoned (disconnect), truck_lost, resource_stopped
    started_at  BIGINT       NOT NULL DEFAULT 0,   -- unix seconds
    ended_at    BIGINT       NOT NULL DEFAULT 0,
    INDEX idx_rp_nomade_identifier (identifier)
)
```

A row is inserted at acceptance and updated at the end (callback forms; nothing yields on an
export). **No database** (`ready` answers `database_unavailable`, or the database still is not
answering 15 s after start): finished contracts go to the resource's `Open77.kvp` store (key
`history`, last 50, JSON) and the log says `[rp_nomade] store=kvp reason=...`. `/convois` reads
whichever store is in use and says so. Running contracts are in memory only: a server restart
ends them.

## Configuration (`shared/config.lua`)

| Key | What |
|---|---|
| `Camp.position`, `Camp.zone` | camp centre (`/camp`), rp_zones name for the return |
| `Camp.board` | board position, ring radius, `promptDistance`, server `reach`, copy |
| `Camp.truckSpawn` | where the truck appears (x, y, z, yaw) |
| `Camp.loadingPoints` | one crate per point, in order (4 shipped: templates up to 4 crates) |
| `Camp.props` | decoration spawned by the server at start and removed at stop (`world.props`) |
| `Destinations[name]` | label, ring position, radius — keyed by rp_zones name; `zone = false` for a place rp_zones does not know (distance check only) |
| `Templates` | id, label, description, crates, destination |
| `Contract` | pay per crate, convoy bonus / radius / minimum, society share, time limit, unload seconds, history rows |
| `Truck` | records tried in order, deposit, reach, safety TTL, `bed.slots` / `bed.stackHeight` (where loaded crates sit, vehicle frame) |
| `Crate` | prop aliases tried in order, pickup distance, prompt distance, ring radius, copy |
| `Carry` | `mode = "attach"` (prop bound to `bone` with `offset` / `rotation`, root by default) or `"held"` (hidden prop + `Open77.heldItems.hold` item record); `animation` = the carry pose (`profiles` tried in order, `resume`, `resumeAfterMs`, `stillDistance`); `steps` = the one-shot clips and timers around every crate move (`pickup`, `load`, `take`, `carryMs`, `putdown`, `groundTtlMs`, `groundGap`, `groundSpacing`) |
| `Navigation` | map pin + GPS route on the destination then the camp: `enabled`, `gpsFrom` (`"loaded"` / `"accepted"`), sprites |
| `Ambush` | on/off, circle, `minTravel`, count, spawn distance and spread, lifetime, `Character.*` records, `damagePolicy` (numeric, 0 = normal), combat group, announcement |
| `Items` | `nomad_crate` (25 kg) declared in `rp_inventory` through `define` |
| `Ui` | tick, colour, chat prefix |

## Where things are

Real places (world metres; AMM points carry +0.1 m for the rings, walked points are exact). The
camp is the **Aldecaldos camp** in the north-eastern Badlands, around V's nomad tent.

| Point | Coordinates | Notes |
|---|---|---|
| Camp centre (`nomad_camp`, r 120) | 1792.9, 2248.9, 180.2 | V's tent (AMM); what `/camp` reports |
| Contracts board | 1790.0, 2252.0, 180.3 | ring r 1, E prompt **Aldecaldos contracts board** |
| Cargo crate props (2) | 1788.2, 2253.6 and 1791.8, 2253.8 | `Camp.props`, 1.2 m off the board ring |
| Truck bay | 1800.0, 2240.0, 180.2 (yaw 58.6) | 12 m south-east of the board; yaw = the tent's heading, the road's was not measured (`/pos` in the truck facing the road) |
| Loading points | 1786/1788/1790/1792, 2256..2258.5, 180.3 | 4–6 m north of the board |
| Ambush circle | 1600, 600, r 60 m | on the road between the camp and the junkyard; planar check, refine the centre with `groundz <playerId> 1600 600` at replay time |
| Destination: Rancho Coronado junkyard (`junkyard`, r 30 ring / zone r 90) | 1374.9, -1674.9, 49.4 | ~4.0 km south of the camp |
| Destination: Watson, the Afterlife street (`afterlife_street`, r 25 planar ring) | -1408.0, 960.0, 23.5 | the street outside the Afterlife ramp; ~3.4 km south-west of the camp |
| Destination: Badlands Drive-In Theater (`drive_in`, r 40, `zone = false`) | -81.2, 1963.3, 100.8 | no rp_zones zone: distance check only; ~1.9 km west of the camp |

Distances are as the crow flies; the runs are real drives. The camp lies in the `badlands`
zone (no NCPD coverage) and outside every safe zone, so the ambushers' hits land. **Every `z`
is the AMM ground + 0.1:** the camp and the junkyard are not flat — if a ring is not visible,
stand on the spot, `/pos`, and paste the ground height into the config.

**Props.** At start the server spawns `Camp.props` through `Open77.props.create` (permission
`world.props`, curated prop aliases (see `prop.catalog`) — a raw `.mesh` path renders as a white
slab) and removes them at stop: two cargo crates (`crate.cargo`) by the board. A refused prop is logged (`camp prop N (...) not
spawned: <reason>`); the board works without it. The contract crates are separate props at the
loading points.

## Log (grep-able)

```text
[rp_nomade] camp props spawned: 2
[rp_nomade] started: 3 templates, camp at 1792.9 2248.9 180.2, board at 1790.0 2252.0, ambush on at 1600.0 600.0 r=60, carry=attach bone=root pose=phone/stand__2h_phone__03__shuffle__01, bed slots=4
[rp_nomade] store=sql table=rp_nomade_contracts
[rp_nomade] rp_inventory items defined: registered=1 rejected=0
[rp_nomade] player 3 accepted contract 'scav_parts' crates=3 dest=junkyard truck=17 record=Vehicle.v_standard3_thorton_mackinaw_player deposit=100
[rp_nomade] crate steps: pickup=examine/2500ms load=give/2000ms take=give/2000ms putdown=examine/2500ms
[rp_nomade] player 3 picked up crate 1/3 (pickup=examine/kneel__rk_on_ground__01__inspect_ground__01 2500ms, attached:root pose=phone/stand__2h_phone__03__shuffle__01)
[rp_nomade] player 3 loaded crate 1/3 (load=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 2000ms, bed slot 1, attached to truck 17)
[rp_nomade] player 3 loaded crate 2/3 (load=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 2000ms, bed slot 2, attached to truck 17)
[rp_nomade] player 3 loaded crate 3/3 (load=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 2000ms, bed slot 3, attached to truck 17)
[rp_nomade] player 3 ambushed at 1612.4 587.9: 3/3 npcs record=Character.cpz_maelstrom_grunt1_ranged1_lexington_wa
[rp_nomade] player 3 took crate 1/3 out of the bed (take=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 2000ms, slot 1, attached:root)
[rp_nomade] player 3 delivered crate 1/3 (putdown 2500ms, on the ground at 1376.2 -1672.1, bed slot 1 cleared)
[rp_nomade] player 3 took crate 2/3 out of the bed (take=give/... 2000ms, slot 2, attached:root)
[rp_nomade] player 3 delivered crate 2/3 (putdown 2500ms, on the ground at 1375.3 -1672.1, bed slot 2 cleared)
[rp_nomade] player 3 took crate 3/3 out of the bed (take=give/... 2000ms, slot 3, attached:root)
[rp_nomade] player 3 delivered crate 3/3 (putdown 2500ms, on the ground at 1377.1 -1671.2, bed slot 3 cleared)
[rp_nomade] player 3 delivered 3 crates pay=450 bonus=0 convoy=1 society=+68
[rp_nomade] player 3 ambush cleared: 3/3 npcs removed (delivered)
[rp_nomade] player 3 contract #12 scav_parts delivered: crates=3 pay=450 bonus=0 society=68 convoy=1
[rp_nomade] player 3 returned the truck, deposit refunded
[rp_nomade] player 3 contract #12 scav_parts ended: delivered crates=3/3 pay=450 bonus=0 society=68
[rp_nomade] player 3 dropped crate 2/3 (life phase downed), back at the loading bay
[rp_nomade] player 3 put crate 2/3 down (cancel, putdown 2500ms)
[rp_nomade] player 3 contract #13 chooh2_barrels ended: cancelled crates=0/2 pay=0 bonus=0 society=0
```

A pickup whose pose could not start reads `(attached:root pose=phone/... not playing)` and is
preceded by `carry pose phone refused for player 3: <reason> (the crate is carried without it)`;
a server without the RP animation service logs `carry pose off: animations_api_unavailable` (or
`no_known_profile`) at start and `pose=none` from then on.

Refusals from the platform are logged with their reason (`truck record ... refused: ...`,
`crate model ... refused: ...`, `attach ... refused: ... (falling back to a hidden prop)`,
`attach of crate ... to truck ... refused: ... (prop removed, crate still counted)`,
`carry pose ... refused ...`, `ambush record ... refused: ...`,
`society nomade credit ... refused: ...`). Client side: `navigation pin refused: ...` /
`GPS route refused: ...`.

## Manifest

Permissions: `network.events`, `database.access`, `world.vehicles`, `world.props`, `world.npcs`,
`players.animations.control` (the carry pose), `ui.vanilla.map` (client: pins + GPS route).
Dependencies (all ship a client half): `open77_uikit` (menu + progress, server twins),
`open77_worldui` (board, crates, destination ring), `open77_interactions` (truck prompts),
`open77_props` (the crate projection, the carry and bed attachments), `open77_notifications`
(payout toasts). The carry pose needs the platform's `open77_animations` system resource running
(it is auto-started and not declared as a dependency: without it the pose is refused and logged,
the run is unchanged). `rp_jobs`, `rp_zones`, `rp_inventory`, `rp_economy`, `rp_bank`, `rp_identity` are
reached through `pcall`'d exports: without `rp_jobs` the board answers "the clan roster is
offline"; without `rp_zones` the destination and camp checks fall back to a planar distance
against `Destinations[...].radius` / 9 m; without `rp_economy` no deposit can be taken, so no
truck; without `rp_bank` the society cut is logged as refused; without `rp_identity` account
names are used; without `rp_inventory` the `nomad_crate` item is simply not declared.

`Carry.mode = "held"` additionally needs the bundled `open77_helditems` client (not declared as
a dependency, so a server without it still starts this resource; the hold then times out and
the crate is carried as a hidden prop).

## Test in 2 minutes (one player)

Prerequisites: `rp_jobs`, `rp_zones`, `rp_economy`, `rp_bank`, `rp_inventory` running; you are
player `1` at the Aldecaldos camp (drive out from Kabuki, or console `tp 1 1790 2252 180.3`
onto the board) with the default 500 €$ cash. Log on start: `[rp_nomade] camp props spawned:
2`, `started: 3 templates, ...` then `store=sql table=rp_nomade_contracts`. The run itself is a
real Badlands drive: allow the 20 minutes.

1. **Console:** `setjob 1 nomade 3` (boss, so `/convois` works too). In game: `/service` →
   clocked in at Nomad.
2. `/camp` → `Nomad camp: 1793, 2249 (z 180), 5 m south-east of you...`. The small ring with
   the `Aldecaldos contracts board` pin sits between two cargo crates, 4 m north-west of V's
   tent. Look at it, press **E**. Before clocking in, the same prompt answers `Clock in first
   (/service)...`; 10 m away it answers `Get closer to the contracts board (10 m).`
3. Pick **Scav parts run** (3 crates → Rancho Coronado junkyard, 450 €$, 20 min). Chat:
   `Contract signed: Scav parts run. 3 crates to the Rancho Coronado junkyard, 150 €$ per crate,
   20 minutes. Deposit 100 €$ taken for the truck.` `/money` → 400 €$. A Mackinaw stands at the
   truck bay (12 m south-east), three crates with rings at the loading points (north of the
   board), a ring on the map at the junkyard. Log: `player 1 accepted contract 'scav_parts'
   crates=3 dest=junkyard ...`.
4. `/convoi` → `Crates: 0/3 loaded, 0/3 delivered.`, `Time left: 20 min`, `Convoy: none...`.
5. Walk to crate 1, look at it, **E** → its ring goes, you kneel for 2.5 s, then
   `Crate 1/3 in your arms...`: the crate hangs in front of your chest, both hands come up to hold
   it (the view flips to the third-person body). Walk: the hands drop, the crate stays; stop for
   2 s: the hands come back. **E** on another crate → `Your hands are full, choom.`
6. Walk to the truck (within 4 m), look at it: **Load the crate** — **E** → arms extend for 2 s
   (the prompt is gone meanwhile), then `Crate 1/3 loaded. 2 to go.`; the crate now sits in the
   bed behind the cab. Log `player 1 loaded crate 1/3 (load=give/... 2000ms, bed slot 1, attached
   to truck ...)`. Repeat for crates 2 and 3 → `All 3 crates loaded. The Rancho
   Coronado junkyard is 4012 m south from here: the GPS route is on your map...`; the minimap
   draws the road route, the map shows the objective pin (there since acceptance).
7. Get in the truck and drive south on the Badlands road towards the junkyard (~4 km). Where
   the road passes the ambush circle (around `1600, 600`) the log shows `player 1 ambushed at
   ...` and chat `Wraiths on the road!`: three gangers spawn 15 m ahead and open fire — it hurts,
   the Badlands are no safe zone. (If the road never comes within 60 m of the point, refine
   `Ambush.center` from `/pos` on the road.)
8. Stop inside the junkyard ring (toast `Junkyard` from rp_zones, chat `You made it. Park, get
   out and press E on the truck to unload.`). Get out, look at the truck: **Unload** — **E**.
   Per crate (`Unloading crate 1/3...`): 2 s arms out, the crate jumps from the bed to your arms,
   1.5 s carry loop, 2.5 s kneel, the crate is on the ground beside the truck (6 s per crate;
   walk more than 6 m from the truck between two crates to stop and keep the rest in the bed).
   The three crates stay on the ground 30 s.
   Then: `Delivered 3 crates: +450 €$ cash. Wallet: 850 €$.`, toast `Delivery paid`, `Run
   complete. Bring the truck back...`. Log `player 1 delivered 3 crates pay=450 bonus=0
   convoy=1 society=+68`, then `ambush cleared`. `/societe` (rp_bank, job nomade) → 68 €$.
9. `/convois` → `Last 1 convoys (sql):` and `#1 <name>: scav_parts -> junkyard, 3/3 crates, 450
   €$ +0 €$ bonus, society +68 €$, convoy 1, delivered in 9 min, 9 min ago.`
10. The pin and GPS route are now on the camp. Drive back into the camp zone (120 m around V's
    tent), get out, look at the truck: **Return the truck** — **E** →
    `Truck returned. Deposit 100 €$ refunded. Wallet: 950 €$.` The truck vanishes. `/convoi` →
    `No contract running...`. Outside the camp ring the prompt is not offered (a forged intent is
    answered `Bring the truck inside the camp ring to return it.`).
11. Take a second contract, pick up a crate, `/convoi annuler` → `Contract ... dropped...`; crate,
    rings and truck are gone, `/money` is 100 €$ lighter (deposit kept). **Militech salvage**
    goes to the Drive-In Theater, which has no rp_zones zone: the `Unload` prompt appears from
    the 1 s tick once the truck is within 40 m of the screen (no `Drive-In` toast).
12. **Convoy (optional, two clients):** second player `setjob 2 nomade 0`, `/service`, stands
    within 30 m of the truck at unload time → driver `+450 €$` and both `Convoy bonus: +56 €$ (2
    nomads rode together).` (25 % of 450 = 113, split in two); log `... bonus=113 convoy=2`.

## Known limits

- One truck spot: two nomads accepting at the same second get two Mackinaws on one spot. Add a
  second `truckSpawn` policy if the clan grows.
- The ambush uses the platform's validated ranged combatant record (`Character.cpz_maelstrom_grunt1_ranged1_lexington_wa`,
  the `hostile_female_ranged_lab` alias); the devkit's NPC catalogue does not expose `Character.*`
  ids for the Wraiths, so pick one from the npc-catalogue browser and put it first in
  `Ambush.records` once it is proven on your build.
- `crate.small` is the only crate alias the devkit documents; the family has seven, `prop.catalog`
  in game lists them. A raw `.mesh` path works for the standing crate but cannot be attached
  to the hand (the carry then hides the prop).
- Running contracts do not survive a server restart (props, NPCs and non-persistent vehicles do
  not either); the SQL row is left `active` and shows as such in `/convois`.
- The carry pose is a stationary workspot: it cannot play while walking (the platform cancels it
  past 0.5 m, and there is no upper-body mask), so on the move only the crate shows the carry.
  No shipped animation catalogue has a real box-carry clip; `tablet2` / `phone` are the closest
  two-hand holds. Both catalogues list their clips as `asset_verified_runtime_pending`.
- Carry offsets, bed slots, the pose and the step timers were written from the API and the
  vehicle/rig frames, not measured in game: expect one tuning pass on `Carry.offset`,
  `Truck.bed.slots` and `Carry.steps.*.ms`.
- The one-shot steps are stationary workspots too: a player who walks during a step cancels its
  clip, but the timer and the prop move still complete (server-driven), so the crate can appear
  in the bed or on the ground while the player is already elsewhere.
