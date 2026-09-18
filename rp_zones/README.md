# rp_zones

Named zones for the Night City RP build: an announcement on entry, a server-authoritative
`zoneOf`, safe zones where nobody can be hurt, a map pin per zone and a ground ring around the
small ones. Every job resource (`rp_ncpd`, `rp_trauma`, `rp_mecano`, `rp_delamain`, ...) reads
this resource; it depends on no `rp_*` resource itself.

Build target: **2.31.13+op77.76**. Dependencies: `open77_notifications`, `open77_worldui`.
Permissions: `network.events`, `combat.config`, `ui.vanilla.map`.

## How it works

- **Zones** live in `shared/config.lua` (`Config.zones`): `name`, `label`, `kind`, a shape
  (`circle` = centre + radius + `maxHeight` band, `sphere`, `box`, or `polygon` = points +
  `minZ`/`maxZ`), an optional `announce` text and optional `flags`. Kinds and their flavour
  lines, toast type, blip sprite and ring style are in `Config.kinds`.
- **Detection is server-side.** Every `Config.tickMs` (500 ms) the server reads
  `Open77.players.positions()` once and tests each prepared zone with `Open77.zones.contains`,
  the platform's shared geometry module (planar distance for circles, crossing-number test for
  polygons, the same bytes the client embeds). The exit test carries `Config.hysteresis` metres of
  grace so a player on the boundary does not flap. The client never reports membership.
- **Entry**: a toast (`Open77.notifications.send`) with the zone label and one flavour line per
  kind; `badlands` also writes "Out of NCPD coverage" in chat. **Leaving a safe zone** shows a
  short warning toast.
- **Safe zones** (`kind = "safe"`): a server damage arbiter (`Open77.combat.onDamage`) cancels
  every hit whose victim stands in a safe zone, and — `Config.safe.blockDamageFromInside` — every
  hit whose attacker stands in one. Nothing is toggled on the player, so an admin `/god` is never
  clobbered and nothing leaks when the resource stops.
- **Map**: the client creates one vanilla map pin per zone (`Open77.blips.create`, sprite per kind)
  and, for zones with a radius of at most `Config.ringMaxRadius` (25 m), a native ground ring
  through `open77_worldui` (`create` with no `label`, so no E prompt).
- **No SQL table**: membership is recomputed from live positions every tick; nothing is durable.

## Commands

| Command | What it does |
|---|---|
| `/zones` | Lists every zone with its label, kind and the planar distance from you to its centre, nearest first; the zones you stand in are marked `[HERE]`. |
| `/zone` | The zone you are in (the smallest one, plus the others you overlap), or "Open Night City". |

Both refuse the server console politely.

## Exports (server, synchronous — never yield)

```lua
exports.rp_zones:zoneOf(playerId)   -- { name, label, kind, flags } | nil   (smallest zone first)
exports.rp_zones:isIn(playerId, name)   -- boolean
exports.rp_zones:list()                 -- { { name, label, kind }, ... } in config order
exports.rp_zones:playersIn(name)        -- { playerId, ... } ascending
```

`flags` is an extra field beyond the phase-2 contract (a copy of the zone's `flags` table, empty
when none). Call inside `pcall`: a synchronous export raises when the resource is not running.

```lua
local ok, zone = pcall(function() return exports.rp_zones:zoneOf(source) end)
if ok and zone and zone.kind == "clinic" then ... end
```

## Events (host bus, `TriggerEvent`)

| Event | Arguments | When |
|---|---|---|
| `rp_zones:entered` | `playerId, name, kind` | Raised for **every** zone the player enters (a player can be in several overlapping zones). |
| `rp_zones:left` | `playerId, name, kind` | Raised for every zone the player leaves — including one `left` per zone on disconnect, so consumers' counts stay consistent. |

`playerId` is a number. Handlers registered with `AddEventHandler` receive them.

## Shipped zones

Real Night City places, measured on 2026-09-18 (walked points in Kabuki, AMM interiors for the
landmarks). The freeroam spawn is **Kabuki Market Centre** `-1191.30, 2006.88, 7.82` (Watson).
Circles (`maxHeight` 15 m unless noted) except `badlands`, which is a polygon. Zones with a
radius of at most 25 m draw a ground ring.

| Name | Kind | Centre (x, y, z) | Radius | From the spawn |
|---|---|---|---|---|
| `kabuki_market` | safe (`noWeapons`) | -1191.30, 2006.88, 7.82 | 70 m | 0 m (the walked market: Noodle Row, The Stalls, Vendor Lane, East Row, Lower Walkway, South Gate, West Approach, Far Corner) |
| `kabuki` | district | -1200, 1900, 10 | 420 m, `maxHeight` 200 | the district around it (pin only, no ring); Lizzie's is inside it |
| `afterlife` | bar | -1453, 1017, 16.6 | 50 m | 1.0 km south-west (bar floor, counter, Rogue's room, back room; no ring, the radius is above 25 m) |
| `lizzies` | bar | -1188.9, 1566.2, 23.0 | 18 m | 440 m south |
| `h10` | residential | -1391.9, 1271.7, 123.1 | 45 m | 760 m south-west (V's floor of Megabuilding H10, the gym included) |
| `viktor_clinic` | clinic | -1548, 1230, 11.6 | 12 m | 855 m south-west (Vik's chair room) |
| `ncpd_hq` | ncpd | -1761.5, -1010.8, 94.3 | 30 m | 3.1 km south (the NCPD building's conference room, city centre - drive) |
| `junkyard` | industrial | 1374.9, -1674.9, 49.3 | 90 m, `maxHeight` 30 | 4.5 km south-east (Rancho Coronado, Badlands edge) |
| `nomad_camp` | camp | 1792.9, 2248.9, 180.2 | 120 m, `maxHeight` 30 | 3.0 km east (Aldecaldos camp) |
| `westbrook_dealer` | dealership | -1442.2, 127.4, 18.0 | 40 m | 1.9 km south (the Westbrook dealership lot) |
| `badlands` | badlands | polygon `900,-4000` → `5000,-4000` → `5000,4000` → `900,4000`, `minZ` -200 / `maxZ` 1200 | everything east of x 900 | everything east of the city (no ring); the junkyard and the Aldecaldos camp are inside it |

The Gallery (`-1173.12, 2087.44, 11.94`, the rp_jobs agency) is 83 m from the market centre:
outside `kabuki_market`, inside `kabuki`. `badlands` is a polygon rather than a circle because
the platform caps a circle radius at 2 000 m (`open77_zones.lua` `MAX_RADIUS`, `invalid_radius`
at start): the rectangle east of x 900 covers the Aldecaldos camp (`1793, 2249`), the junkyard
(`1375, -1675`), the oil fields and the road out of the city, while the city itself stays out
(see the config comment).

## Test in 2 minutes

1. Connect; you spawn inside `kabuki_market` (and `kabuki`). Expect two toasts top-right -
   "Kabuki Market / No heat in here, choom..." and "Kabuki / Kabuki, Watson. Tyger Claws
   turf..." - and no chat line (only `badlands` writes one).
2. `/zone` → `You are in Kabuki Market (kabuki_market, safe) - also inside: kabuki`.
3. `/zones` → eleven lines, nearest first; `kabuki_market` and `kabuki` marked `[HERE]`.
4. Open the map: eleven pins (a `fast_travel` pin on the market, the Kabuki district pin over
   it, bar pins at Lizzie's (440 m south) and the Afterlife, meds at Vik's, NCPD in the city
   centre, junk and nomad far east, tech at Westbrook, the outpost pin on the Badlands).
5. Walk 70 m out of the market (the South Gate alley at `-1218, 1950` is 63 m from the centre,
   seven more metres down the street does it): toast **Leaving Kabuki Market / You're fair game
   again, choom**.
6. Drive south to the Afterlife (`-1453, 1017`, 1.0 km): the zone (50 m, pin only - no ground
   ring above 25 m) covers the whole bar; toast **The Afterlife / The bar's open...**; `/zone`
   → `afterlife`. Walk back out: no toast for `afterlife` (only safe zones announce their exit).
7. Same with `lizzies` (`-1188.9, 1566.2`, on the way) and `viktor_clinic` (`-1548, 1230`):
   every job zone is a short drive from the market.
8. Safe zone check (two players): both stand in the market; shoot the other - no health loss.
   Step one player outside the ring, shoot back in - still no damage (victim protected); the
   inside player shooting out - refused too (`blockDamageFromInside`). Both outside - normal damage.
9. Drive east past the city limit (anything east of x 900, e.g. the junkyard at `1375, -1675`
   or the Aldecaldos camp at `1793, 2249`): toast **Badlands / You're past the city limits...**
   plus the orange chat line **Out of NCPD coverage**.
10. Server log shows `11 zone(s) prepared: ...` and `safe-zone damage arbiter installed` at start.
