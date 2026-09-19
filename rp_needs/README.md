# rp_needs

Hunger, thirst and fatigue for a Night City RP server. The three values are **satiety** levels (100 = full, 0 = starving / parched / exhausted); the HUD labels them Food / Water / Energy. Below 0 food or water the body loses 1 HP every 10 s down to 10 HP until the player eats or drinks (`/needs`, the kiosks, `/setneeds` for admins). Server-only resource
(no client script): the server owns the three values, persists them, applies
the effects and pushes warnings to the player's biomonitor.

- Three values per player, `0..100`, `100` = fine.
- Decay per minute: hunger `-0.8`, thirst `-1.2`, fatigue `-0.4`.
- Fatigue recovers `+2/min` while the player sits still (< 0.5 m/s) in a
  vehicle seat. Sitting on a chair through an RP animation is **not** detected
  (see "Limits").
- Ticks every 10 s; saved to SQL every 60 s and on disconnect.

## Commands

| Command | Who | What |
|---|---|---|
| `/needs` | any player | Shows `Hunger x% \| Thirst y% \| Fatigue z%` in chat. Refuses the console politely. |
| `/setneeds <playerId> <hunger> <thirst> <fatigue>` | ACL `command.setneeds`, or the server console | Sets a loaded player's three values (clamped to 0..100), applies the effects at once and emits `rp_needs:changed`. Testing tool. |

Both commands are published as chat suggestions (`chat:ready` and once at
resource start).

## Exports (server, synchronous)

```lua
-- { hunger, thirst, fatigue } rounded to integers, or nil when the player is unknown / not loaded.
local needs = exports.rp_needs:get(playerId)

-- true, or nil, reason. Reasons: "not_consumable", "player_not_found", "invalid_player".
local ok, reason = exports.rp_needs:consume(playerId, itemId)
```

Call them inside `pcall`: a synchronous export raises when the resource is not
running. Neither export yields, so both are safe on the synchronous path.
`rp_inventory` calls `consume` from `/use`.

```lua
exports.rp_needs:apply(playerId, { thirst = 25, fatigue = -5 }, "Cold beer")  -- true | nil, reason
```

`apply` is the generic form for another resource's consumables (a bar drink, a ripper's
sedative): each of `hunger`, `thirst`, `fatigue` is optional (-100..100), the label is shown
in the toast, and the same effects/thresholds run as for a built-in item.

### Consumables

| Item id | Effect |
|---|---|
| `water` | thirst +30 |
| `nicola` | thirst +20, fatigue +5 |
| `burrito` | hunger +35 |
| `cigarettes` | fatigue +5, hunger -2 |
| `synthcoke` | fatigue +40 now, fatigue -20 five minutes later (the crash; skipped if the player has left) |

Unknown ids answer `nil, "not_consumable"`. Every consume sends the player a
short toast and emits `rp_needs:changed` immediately.

## Event

`rp_needs:changed (playerId, hunger, thirst, fatigue)` on the host-wide bus,
integers. Raised at most once per minute per player by the tick, on load, and
on every `consume` / `/setneeds`.

## Effects

| Condition | Effect | Native |
|---|---|---|
| hunger < 20 **or** thirst < 20 | stamina maximum halved (current value clamped by the host); restored when both are back >= 20, on resource stop, and by the host on disconnect | `Open77.stats.setStaminaMax` |
| hunger == 0 **or** thirst == 0 | 1 hp lost every 10 s down to 10 hp; never below, so never lethal and never through life authority | `Open77.stats.setHealth` |
| fatigue < 20 | the native "exhausted" stamina overlay held on the player's own view until fatigue is back >= 20 (re-armed after a respawn) | `Open77.effects.screen(playerId, "exhausted")` |
| any need < 30, then < 10 | one toast per threshold crossing (re-armed once the value climbs back over the line) | `Open77.notifications.send` |

A dead player neither decays nor takes starvation damage.

## Persistence

SQL first: table `rp_needs_state` (`identifier VARCHAR(128) PK, hunger, thirst,
fatigue FLOAT, updated_at BIGINT` unix seconds), created inside
`Open77.database.ready`, keyed by `Open77.players.identifier`. Rows are
upserted every 60 s when dirty, on disconnect and on resource stop (callback
form, no yield). A missing row means a fresh citizen at 100/100/100.

When `Open77.database.isReady()` is false (or the table is not created yet)
the resource falls back to `Open77.kvp` under `needs:<identifier>` and logs
`[rp_needs] database not ready (<reason>) -- using KVP fallback ...` for each
load or save that took that path. A server without any database logs
`database not available (database_unavailable)` once at start.

## Log lines

```text
[rp_needs] player 3 hunger=42 thirst=18 fatigue=77
[rp_needs] player 3 loaded from sql hunger=88 thirst=71 fatigue=93
[rp_needs] database not ready (database_connecting) -- using KVP fallback to load <identifier>
[rp_needs] schema ready (rp_needs_state)
```

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``NEEDS_STAGE` and the `stage` field of `CONSUMABLES` in `server/main.lua` (this resource has no shared config)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| water, NiCola | `drink` one-shot (`bottle` once it exists) | the profile's own can | 4 s, after rp_inventory's 3 s "Using" bar |
| burrito | `think` one-shot, hand to the face (`takeout` once it exists -- it ships its own box, drop the `eat.prop` line then) | `food.street_food` in the right hand | 4 s |
| cigarettes | `smoke` one-shot | the profile's own cigarette | 6 s |
| synthcoke | `think` one-shot (`rubhands`) | none | 3 s |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_needs] player 3 gesture drink: pose=drink/stand__rh_can__01__drink__01 prop=none 4000 ms
[rp_needs] player 3 gesture eat: pose=think/stand__rh_on_chin__01__rub_chin__01 prop=food.street_food@RightHand 4000 ms
[rp_needs] player 3 gesture smoke: pose=smoke/stand__rh_cigarette__01__smoke__01 prop=none 6000 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Permissions

`network.events` (toasts, `chat:ready`), `database.access`, `players.stats.read`,
`players.stats.apply`, `players.life.read`, `players.screenfx`. Dependency:
`open77_notifications`.

## Limits

- "Seated" only means a canonical vehicle seat reported by
  `onPlayerEnteredVehicle` / `onPlayerLeftVehicle` (no `world.vehicles` grant
  needed). A player already sitting in a car when the resource is reloaded is
  not counted as seated until they re-enter. RP-animation chairs are not detected.
- The stamina penalty remembers the maximum it saw when the penalty was
  applied; another resource changing the maximum while a player is hungry is
  not merged, the restore writes back that remembered value.
- A player loaded from KVP while the database was still connecting keeps
  those values; the first SQL save then overwrites the SQL row.

## Test in 2 minutes

1. Start the server with `rp_needs` and `open77_notifications` in the load
   list; check the log for `[rp_needs] schema ready (rp_needs_state)` (or the
   KVP fallback line if no database is configured).
2. Join. The log prints `player <id> loaded from sql ...` and a first
   `player <id> hunger=100 thirst=100 fatigue=100` line. Type `/needs` in chat:
   the BIOMONITOR line shows the three values.
3. From the server console: `setneeds <id> 25 25 25`. Within 10 s three
   warning toasts arrive (each need crossed 30). Sprint: nothing changes yet.
4. `setneeds <id> 15 15 15`. Within 10 s: the "10%" toasts do not fire (still
   above 10), the stamina bar is halved, and the exhausted overlay darkens the
   edges of the screen.
5. `setneeds <id> 0 5 50`. Every 10 s one hp is lost; the health bar stops at
   10 hp. The overlay is gone (fatigue 50), stamina still halved (thirst 5).
6. From `rp_inventory` (`/use burrito`, `/use water`) or from any server
   resource: `exports.rp_needs:consume(<id>, "water")`. Thirst goes to 35, the
   stamina maximum is restored on the next tick, and the log prints the new
   values immediately. `consume(<id>, "sushi")` answers `nil, "not_consumable"`.
7. Disconnect and reconnect: `/needs` shows the saved values.
