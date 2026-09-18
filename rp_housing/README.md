# rp_housing - apartments and hideouts

A roof over your head in Night City, for an Open77 RP server (build `2.31.13+op77.76`).
Five real flats — V's apartment in Megabuilding H10, Judy's, Northside, Japantown, the Glen —
a real-estate agency at Kabuki Market that sells them, keys you can
hand to a choom, a private stash inside, a rent every payday, an eviction when you stop
paying, and the option to wake up at home when you reconnect.

Server-authoritative: the server owns the deeds (`rp_housing_homes`), the keys
(`rp_housing_keys`), the rent clock and the "who is inside" state. The client only draws
rings, E prompts and map pins, and sends the minimum intent (`door <id>`, `stash <id>`,
`agency`, `giveKey <playerId>`); every request is re-checked on the server: distance, life
state, ownership, keys, money.

## Real flats, one door each

Every home is a **real Night City apartment**: `interior` is an AMM interior point (the floor
spawn-at-home lands on, `heading` the body yaw there) and the door is the flat's **own front
door**, found at runtime (next section). The door is a **two-sided pass-through**: two
`Apartment door` rings, one on each side of it (`door_a`, `door_b`), and E on either one is an
`Open77.players.teleport` to the other side behind a fade (`Config.enterFade`, 400 ms each way).
Which side is the flat proper is **not knowable** from the door snapshot (Northside, measured
2026-09-18: the AMM `interior` point `-1503.8, 2224.9` is the corridor in front of unit 1242,
not the flat), so the flat's "inside" is simply **whichever side of the door the player crosses
to**: the server's `inside` flag toggles on every pass-through (first crossing = in, next = out,
log `passed through the door of <id>: side A -> side B, inside=true`). A **Stash** ring (E opens
`rp_inventory:openStash(playerId, "home:<id>", 200)`) stands on the interior side, 1.2 m further
from the door than the interior point; it refuses anybody not flagged inside and anybody
without a key.

### The auto door

On start (once the registry is loaded) and then every `Config.autoDoor.retrySec` (60 s) while
unresolved, the server calls `exports.open77_doors:near(interior, 0, 6)` (`Open77.exports.call`,
awaited in a thread, wrapped in `pcall`) for each home whose `doorId` is empty: the answer is
`{ doors, total, truncated }`, nearest first, and a door row carries `id` (a `0x...` string),
`bucket`, `position` and the state flags — **no facing**. The nearest door becomes the home's
`doorId` and **the three rings are derived from it** along the interior -> door axis (the
"outside" direction is the door's facing when a row reports one, otherwise from the interior
point towards the door, +x when the door sits on the interior point itself):

| Ring / point | Rule (`Config.autoDoor`) | Northside, door `0x5AC234B6C1F41703` at `-1503.4, 2227.3, 22.2` |
|---|---|---|
| **Apartment door** side A (`door_a`) | door - `ring` (2.0 m) along the axis, door z | `-1503.7, 2225.3` (corridor) |
| **Apartment door** side B (`door_b`) | door + `ring` (2.0 m) along the axis, door z | `-1503.1, 2229.3` (in the flat) |
| landing after a pass A -> B | door + `land` (2.5 m) | `-1503.0, 2229.8` |
| landing after a pass B -> A | door - `land` (2.5 m) | `-1503.8, 2224.8` |
| **Stash** | interior + `stashInside` (1.2 m) further from the door, interior z | `-1504.0, 2223.7` |

Both door rings carry the same label, description (`<home> - Unit door - pass through (keys
required)`) and intent (`rp_housing:poi:door:<id>` -> `rp_housing:door`): the server measures the
player against both rings (`promptDistance + serverTolerance` = 5.5 m; they are 4 m apart so both
can be in reach) and takes the **nearer** one as the side the player stands on, then teleports
to the other side's landing point, half a metre past the far ring so the next E goes back. The
key / owner checks are unchanged (`for sale`, `Locked. ... you hold no key`). The door itself is
claimed through the existing path (`register` / `configure { automatic = true, autoClose = true,
defaultAccess = false }` / `setAccess` for the owner and the key holders, re-applied on every
`onPlayerReady`). The server pushes the resolved rings to every client in the `rp_housing:state`
snapshot (`sideA`, `sideB`, `stashes = { [homeId] = {x, y, z} }`) and the client re-creates its
POIs there and moves the map pin (pinned on side B). A hand-set `doorId` goes through the same
derivation the first time `open77_doors:get` sees the door.

**Client POI ids are never reused in a session.** A ring re-created by `worldui remove` +
`create` under the id it had before kept a frozen distance (`3.0 m`) and its E never fired
(measured 2026-09-18, Northside, after the auto door resolved), while rings created once at
start worked. Every id therefore carries a generation suffix — `door_a:<id>:<n>`,
`door_b:<id>:<n>`, `stash:<id>:<n>`, `agency:<n>` — and each move increments it: the client
removes the old handle first, creates the new POI, and logs
`[rp_housing] door_a ring of northside_container recreated as door_a:northside_container:2`.

Until a client has **streamed the flat** (walked past it) `open77_doors` has discovered
nothing there, `near` answers an empty list, and the **static fallback** stays in force: side A
is the **interior point itself**, side B is `interior + 3 m along x` (`Config.autoDoor.fallback`),
a pass-through lands on the far ring itself, and the stash is `interior + 1.5 m along x` — drawn,
prompted and used by the teleports exactly like the derived rings. Log: `auto door of h10_studio:
no door discovered within 6 m of the interior yet (...); static rings A -1391.9, 1271.7, 123.1 /
B -1388.9, 1271.7, 123.1 in force, retry every 60 s`, then `auto door of northside_container:
0x5AC234B6C1F41703 at -1503.4, 2227.3, 22.2; door ring A moved to -1503.7, 2225.3, 22.2; door
ring B to -1503.1, 2229.3, 22.2; stash ring to -1504.0, 2223.7, 22.2` once found. A hand-set
`doorId` in `shared/config.lua` skips the search; `autoDoor = false` keeps the static rings for
good. Without `open77_doors` at all, `near` answers `nil, reason` and the static rings are simply
permanent. A door that was found but could not be claimed is retried on the same 60 s clock (log
line `door ... could not be claimed`).

## Where things are (world metres, real Night City)

| What | Position | Notes |
|---|---|---|
| **Night City Real Estate** (agency) | `-1218.65, 2022.93, 7.82` | Kabuki Market, **The Crossing** (walked), 32 m west of the market centre; ring + E prompt, map pin, and an `electronics.monitor.device` listings terminal prop (curated alias, see `prop.catalog`) 2.6 m east of the ring (`-1216.05, 2022.93`; the config lists the same alias twice as its fallback; spawned on start, removed on stop) |
| No-Tell Motel - room Venus (Kabuki) (`northside_container`) | inside `-1202.2, 1333.2, 20.0` | Northside, Watson — **9 000 €$**, the cheapest; 380 m north-west of the market |
| Glen Apartment (`badlands_hideout`) | inside `-1524.0, -992.6, 9.1` | The Glen, Heywood — 15 000 €$; 3 km south |
| Megabuilding H10 — V's Apartment (`h10_studio`) | inside `-1391.9, 1271.7, 123.1`, heading -99.3 | Little China, Watson (`rp_zones` `h10`) — 25 000 €$; 760 m south-west |
| Judy's Apartment (`kabuki_flat`) | inside `-906.3, 1868.7, 42.4` | Kabuki, Watson — 30 000 €$; 320 m east |
| Japantown Apartment (`japantown_loft`) | inside `-785.3, 992.6, 12.0` | Japantown, Westbrook — 40 000 €$; 1.1 km south-east |

The home ids are unchanged from the first build (SQL rows, `home:<id>` stashes and the
`rp_config` keys keep working); the labels are what players read. The door of every home is
its front door, drawn as two pass-through rings 2 m on each side of it (see *The auto door*
above), or the interior point / `interior + 3 m along x` until the door is discovered; the stash
ring follows the same door (1.2 m beyond the interior point, away from the door), or stands
1.5 m along x until then. Rent is **500 €$ per payday** (every 10 min) for every home
(`Config.rent`, overridable per home). The prompt is pressable within 3 m (`promptDistance =
3.0`) while looking at the ring; the server tolerates 2.5 m more on every ring (both door sides
and the stash alike, measured against the same derived positions).

## Commands

| Command | What it does |
|---|---|
| `/maison` | Your place: label, price paid, rent, next payday, unpaid count, spawn-at-home flag, and who holds keys. Without a home: says so, and lists the keys you hold. |
| `/maison cles <playerId>` | Hands a key to a connected player within 3 m. ALT+click that player > **Give a key** does the same. |
| `/maison retirer <playerId>` / `/maison retirer tous` | Takes a key back (the holder must be connected), or voids every key. A holder standing inside is put back on the street. |
| `/maison spawn` | Toggles **spawn at home**: on your next connection you wake up inside your place instead of Kabuki Market. |
| `/maison vendre` | Sells your place back at **70 %** (`Config.sellBackRatio`), paid in cash. A UI-kit confirmation opens; `/maison vendre oui` confirms in chat when the kit is unavailable. |
| `/maison acheter <homeId>` | Buys a home by id, **at the agency desk only** (within 4 m). Without an id: lists the market in chat. The fallback when the menu cannot open. |
| `/loyer` | Rent status: amount, next payday, unpaid count. |
| `/loyer payer` | Pays now: the arrears when there are any (`unpaid x rent`, keeps the home), otherwise one payday in advance. |
| `/agence_immo` | Opens the agency menu, within 4 m of the desk (the same as pressing E on its ring). |

Every command refuses the server console politely (`run this from the game`). Refusals
are explained in chat as `NC Housing` lines, in English.

### The agency menu

A UI-kit context menu (server twin, `open77_uikit`) with one row per home: price, rent and
district in the metadata, `For sale` / `Owned by X` (disabled) / `Yours - sell it back for
N €$` (pick it to sell). A pick opens a confirmation (`alert`), then the deed is signed:
`rp_bank:charge(playerId, price, "housing", "buy:<id>")`; when the account is short the
**cash wallet** is tried (`rp_economy:remove`), so a tester only needs `givemoney` from the
console. One roof per citizen: a second purchase is refused until the first is sold.

## Money

- Purchases and rents go `account -> society "housing"` through `rp_bank:charge`. The
  society is a sink: it is not a job, nobody withdraws from it; every movement is logged
  (`[rp_housing] player 3 <identifier> paid rent 500 for h10_studio from account`) and
  sits in the `rp_bank` ledger as `society:housing`.
- When the account is short the cash wallet pays (`rp_economy:remove`); when both are
  short, the rent is **unpaid**.
- A sale pays 70 % of the price back **in cash** (`rp_economy:add`), and debits the housing
  society for the ledger when it can.

## Rent and eviction

A server thread checks every 60 s (`Config.rentTickSec`). A **connected** owner whose
`rent_due_at` has passed is charged one rent, and the next payday is scheduled 10 min
later (`Config.rentIntervalSec`). Rent is only collected while the owner is connected: a
long absence costs one rent on return, not one per missed payday. On a failure the unpaid
counter grows and the player is warned (`RENT UNPAID (1/2)`); at **two** consecutive unpaid
rents (`Config.evictAfter`) the owner is evicted: deed deleted, every key voided, anybody
inside is put back on the street, event `evicted`. `/loyer payer` clears the arrears and
resets the counter.

## Respawn at home

There is **no spawn-point API** on this host: `Open77.players.respawn` only works on a
dead player, and the freeroam gamemode places every connecting body at Kabuki Market. So
`/maison spawn` stores a flag, and on `onPlayerReady` the server waits until the player's
life phase is `alive` (`Open77.players.getLifeState`, up to 30 s - a connecting client
reports a `dead` phase once, and a placement on the continue screen crashes the client),
waits 1.5 s more for the spawn placement to settle, then teleports the body to the
interior behind a fade and marks the player inside. Expect a short black hop from the
market to the home; a `settle_superseded` from the gamemode's own placement is reported in
chat (`Could not bring you home (...)`) and logged.

## Exports (server; synchronous-safe, nothing yields)

```lua
exports.rp_housing:homeOf(playerId)        -- { id, label, position = door ring, side B } | nil
exports.rp_housing:hasKey(playerId, homeId) -- boolean (the owner counts as a key holder)
exports.rp_housing:stashOf(homeId)          -- "home:<id>" | nil for an unknown home
exports.rp_housing:isInside(playerId)       -- homeId | nil
```

Call them inside `pcall` from another resource (a synchronous export raises when the
resource is not running). `rp_housing` ships a client script, so a resource that has one
too may declare `dependency "rp_housing"`.

## Events (host bus)

```lua
AddEventHandler("rp_housing:changed", function(identifier, homeId, action) end)
```

`action` is one of `bought`, `sold`, `evicted`, `rent_paid`, `rent_unpaid`, `spawn_on`,
`spawn_off`, `key_given`, `key_revoked`. For the two key actions `identifier` is the **key
holder's** identifier; for every other action it is the owner's.

Internal transport (not an API): client -> server `rp_housing:clientReady`,
`rp_housing:door` (both sides; `rp_housing:exit` is kept as an alias of it for older clients),
`rp_housing:stash`, `rp_housing:agency`, `rp_housing:giveKey`; server -> client
`rp_housing:state` (`{ mine, owned, keys, inside, sideA, sideB, stashes }`, drives the map pins,
the three rings per home and the ALT+click predicate).

## Persistence

Two tables, created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`,
keyed by the durable `Open77.players.identifier`:

| Table | Columns |
|---|---|
| `rp_housing_homes` | `home_id` (PK), `identifier`, `owner_name`, `paid`, `bought_at`, `rent_due_at`, `unpaid_rent`, `spawn_at_home` |
| `rp_housing_keys` | `home_id`, `identifier` (PK pair), `holder_name`, `granted_by`, `granted_at` |

Everything is cached in memory at start and written through with the callback forms
(`Open77.database.update(sql, params, cb)`); the exports never touch the database. A row
for a `home_id` that is no longer in `shared/config.lua` is kept but ignored (logged).
**No database** (`ready` answers `database_unavailable`, or nothing answers within 20 s):
`Open77.kvp` (`homes`, `keys` as JSON) takes over and the log says
`[rp_housing] store=kvp reason=...`. The choice is made once per boot. The stash content
itself lives in `rp_inventory_stashes` (`rp_inventory`).

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
| E on the stash | `examine` crouch, looped (`carry_pickup`) | none | 2 s bar, then the POCKETS panel |
| the doors | none: a teleport under a fade | -- | -- |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_housing] player 3 stage stash: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=none place=none 2000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Manifest

Dependencies: `open77_worldui`, `open77_uikit`, `open77_contextmenu`, `open77_notifications`
(all four ship a client half). `rp_inventory`, `rp_bank`, `rp_economy`, `rp_identity`,
`rp_zones` are server-only and reached through `pcall`; `open77_doors` through
`Open77.exports.call` (optional: without it the static rings are permanent). Permissions:
`network.events`, `database.access`, `players.teleport`, `players.life.read`, `ui.vanilla.map`,
`world.props` (the agency terminal, removed on stop).

## Log lines (grep-able)

```
[rp_housing] started, 5 homes, agency at -1218.6, 2022.9, 7.8
[rp_housing] prop 1044 of agency at -1216.1 2022.9 7.8 (electronics.monitor.device)
[rp_housing] store=sql homes=0 keys=0
[rp_housing] auto door of h10_studio: no door discovered within 6 m of the interior yet (a client must stream the flat); static rings A -1391.9, 1271.7, 123.1 / B -1388.9, 1271.7, 123.1 in force, retry every 60 s
[rp_housing] auto door of northside_container: 0x5AC234B6C1F41703 at -1503.4, 2227.3, 22.2; door ring A moved to -1503.7, 2225.3, 22.2; door ring B to -1503.1, 2229.3, 22.2; stash ring to -1504.0, 2223.7, 22.2
[rp_housing] door 0x5AC234B6C1F41703 locked to the owner and key holders of northside_container
[rp_housing] 16 world prompts created                 (client)
[rp_housing] door_a ring of northside_container moved to -1503.7, 2225.3, 22.2 (auto door)   (client)
[rp_housing] door_a ring of northside_container recreated as door_a:northside_container:2   (client)
[rp_housing] door_b ring of northside_container moved to -1503.1, 2229.3, 22.2 (auto door)   (client)
[rp_housing] door_b ring of northside_container recreated as door_b:northside_container:2   (client)
[rp_housing] stash ring of northside_container moved to -1504.0, 2223.7, 22.2 (auto door)   (client)
[rp_housing] stash ring of northside_container recreated as stash:northside_container:2   (client)
[rp_housing] player 3 <identifier> bought northside_container for 9000 from cash
[rp_housing] player 3 passed through the door of northside_container: side A -> side B, inside=true
[rp_housing] player 3 opened stash home:northside_container
[rp_housing] player 3 passed through the door of northside_container: side B -> side A, inside=false
[rp_housing] player 3 gave a key of northside_container to player 4 <identifier>
[rp_housing] player 3 <identifier> paid rent 500 for northside_container from account
[rp_housing] player 3 <identifier> missed rent 500 for northside_container (1/2): insufficient_funds / insufficient_funds
[rp_housing] <identifier> evicted from northside_container: unpaid rent
[rp_housing] player 3 spawn at home northside_container: true
[rp_housing] player 3 spawned at home northside_container
[rp_housing] player 3 <identifier> sold northside_container for 6300 (70%)
```

## Test in 2 minutes (one player, from the Kabuki Market spawn)

1. Start the server with `rp_housing` next to `rp_bank`, `rp_economy`, `rp_inventory`,
   `rp_identity`, `rp_zones`, `open77_doors` and the four `open77_*` packages. Log:
   `[rp_housing] started, 5 homes, agency at -1218.6, 2022.9, 7.8`, `prop <id> of agency at
   -1216.1 2022.9 7.8 (...)`, then `store=sql homes=0 keys=0` (or `store=kvp`) and five `auto
   door of <id>: no door discovered ... static rings A ... / B ... in force` lines.
2. Connect. Open the map: a **vendor** pin `Night City Real Estate` at The Crossing (32 m west
   of the spawn) and five **apartment** pins `... - For sale` across Watson, Westbrook and
   Heywood.
3. Console: `givemoney <id> 10000`. `/money` says 10 500.
4. Walk 32 m west to the agency ring at The Crossing (`-1218.65, 2022.93`), the data terminal
   beside it, look at the ring, press **E** (or `/agence_immo`). The `Night City Real Estate`
   menu opens. Pick **No-Tell Motel - room Venus (Kabuki)** (9 000 €$, the cheapest), then **Sign**. Chat:
   `No-Tell Motel - room Venus (Kabuki) is yours (paid from cash) ...`, toast `Deed signed`. The pin now reads
   `No-Tell Motel - room Venus (Kabuki) - Your place`. Log: `player <id> ... bought northside_container for
   9000 from cash`.
5. `/maison` -> `No-Tell Motel - room Venus (Kabuki) (northside_container) - bought for 9 000 €$ - rent
   500 €$/payday - next rent in 10 min - unpaid 0/2 - spawn at home: off` and
   `Keys: nobody but you ...`.
6. Go to Northside (380 m north-west; console `tp <id> -1503.8 2224.9 22.2` puts you on the
   interior point, which at Northside is the **corridor** in front of unit 1242). Until the flat's
   front door is discovered the two `Apartment door` rings are the static ones: side A under your
   feet (`-1503.8, 2224.9`), side B 3 m east (`-1500.8, 2224.9`). Once you have walked past the
   flat with `open77_doors` running, the next retry (<= 60 s) logs `auto door of
   northside_container: 0x5AC234B6C1F41703 at -1503.4, 2227.3, 22.2; door ring A moved to
   -1503.7, 2225.3, 22.2; door ring B to -1503.1, 2229.3, 22.2; stash ring to -1504.0, 2223.7,
   22.2` and the client lines `door_a / door_b / stash ring of northside_container moved to ...`
   each followed by `... ring recreated as door_a:northside_container:2` (and `door_b:...:2`,
   `stash:...:2`): the rings now stand 2 m on each side of the real door — A in the corridor, B
   in the flat — with a **live distance** on every card, and the door opens for you alone. Stand
   in the corridor, look at the side A ring, press **E**. Fade to black, you stand in the flat
   half a metre past the side B ring (`-1503.0, 2229.8, 22.2`): `Welcome home. E on the stash,
   E on the door again to step back out.` Log: `player <id> passed through the door of
   northside_container: side A -> side B, inside=true`. From another resource,
   `exports.rp_housing:isInside(<id>)` now answers `northside_container`. The flat's "inside" is
   whichever side of the door you crossed to: there is no separate exit ring, the same
   `Apartment door` card on this side takes you back.
7. Press **E** on the door again from the flat side: fade, you are back in the corridor half a
   metre past the side A ring (`-1503.8, 2224.8`): `You step out of No-Tell Motel - room Venus (Kabuki).`, log
   `... side B -> side A, inside=false`. The **Stash** ring stands 1.2 m further down the
   corridor (`-1504.0, 2223.7`): it is on the interior side, which at Northside is the corridor,
   and it only opens while the flag says inside. So: cross in once more with E (`inside=true`),
   then walk back out **on foot** through the real door (it opens for key holders, and walking
   keeps the flag as long as you stay within 8 m of the interior point), stand at the Stash ring,
   press **E**: the `rp_inventory` Take / Store menu opens (200 kg). Store something, close,
   reopen: it is still there. (On the four other homes the interior point is the flat proper and
   the stash is simply next to the landing point.)
8. From the street side (flag inside=false), try the **Stash** ring: `Get inside first. The stash
   does not open from the street.`; press it from further than 5.5 m: `Too far from the stash.`
   Press E on the door from more than 5.5 m from both rings: `Too far from the door of Northside
   Apartment.` Sell or get evicted while flagged inside: you are put on side B's landing point.
9. `/maison spawn` -> `Spawn at home ON ...`. You do **not** need to reconnect to check
   the flag: `/maison` shows `spawn at home: ON` and the row says `spawn_at_home = 1`.
   What a reconnect would do: the server waits for your body to be alive at Kabuki Market,
   then fades and moves it to `-1202.2, 1333.2, 20.0`, chat `Home sweet home: you wake up in
   No-Tell Motel - room Venus (Kabuki).`, log `player <id> spawned at home northside_container`.
   Reconnecting **does** exercise it, if you have a second minute.
10. `/loyer` -> `No-Tell Motel - room Venus (Kabuki): rent 500 €$ per payday (every 10 min), next in N
    min, unpaid 0/2`. `/loyer payer` -> `Paid one payday in advance ...` (cash, since the
    account is empty). Empty the wallet (`/pay <other> <all of it>`) and keep the account
    at 0 to see `RENT UNPAID (1/2)` at the next payday; twice in a row = `EVICTED`.
11. Two players: stand 2 m from the other client, `/maison cles <id2>` (or ALT+click them
    > **Give a key**): both are told; `/maison` lists the holder; the other client's pin
    turns `You hold a key` and their **E** on the door lets them in (`You let yourself into
    ... with <you>'s key`). `/maison retirer <id2>` takes it back.
12. `/maison vendre` -> confirmation -> `Sold No-Tell Motel - room Venus (Kabuki) for 6 300 €$ in cash.`
    The pin is `For sale` again, `/maison` says you own nothing. Reconnect: nothing to
    restore; before the sale, a reconnect shows `Welcome back. No-Tell Motel - room Venus (Kabuki) is
    waiting for you (rent in order).`
