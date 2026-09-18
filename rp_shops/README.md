# rp_shops v2 — shops in the world

Five real stalls of Kabuki Market (Watson), each with a **vendor NPC** standing behind the
counter, a real stall prop, a ring + map pin + **E** prompt, a UI-kit catalogue, a quantity dialog, and a payment
taken **in cash first, then from the bank account**. Goods land in the pockets
(`rp_inventory`), guns come through the platform relay (`open77_weapons`) behind an **NCPD gun
licence**, the clothes shop charges a styling fee and opens the platform **wardrobe**, and the
**black market** only trades at night (server-world time). A shop can be **player-run**
(`society = "<job>"`): 70 % of its sales go to that society and its shelves are finite. A
`rob()` export lets `rp_crime` hold a vendor up.

Replaces `rp_shop`: `/shop`, `/buy` and `/sell` are gone; the commands are `/boutiques` and
`/acheter`. Build target **2.31.13+op77.76**. Server-authoritative: the client only draws the
prompts and forwards a press; every price, hour, licence, stock count and payment is decided on
the server, which re-checks the distance after every dialog.

## The shops (`shared/config.lua`)

Five real stalls of **Kabuki Market** (Watson), the hub of the server: every ring stands on a
walked market spot (2026-09-18, z exact), the vendor NPC stands 1.2 m behind the ring facing it
(`vendorPosition`, `yaw`), and one real prop dresses each stall 0.8 m off the ring next to the
vendor (`prop.models`, curated prop aliases — see `prop.catalog`; a raw `.mesh` path renders as
a white slab — tried in order, spawned by the server on start with `Open77.props.create` —
permission `world.props` — and removed on stop; a refused model only logs). Distances are from Kabuki Market Centre (`-1191.30, 2006.88, 7.82`, the freeroam spawn).

| id | Label | Vendor | Ring (x, y, z) | From the centre | Prop | Sells |
|---|---|---|---|---|---|---|
| `supermarket` | Kabuki Market — Noodle Row | Rosa | -1178.66, 2028.45, 7.95 | 25 m NE | market shelf (`market.shelf.chinese`, fallback `light.lantern.chinese`) | water 10, burrito 25, nicola 15, chooh2 60, cigarettes 20 |
| `pharmacy` | Med-Point — The Stalls | Dr. Osei | -1223.91, 1989.45, 7.98 | 37 m SW | vending machine (`electronics.vending_machine.small`, fallback `electronics.vending_machine`) | bandage 40, maxdoc 120, bounceback 90 — **run by `trauma`**, stock 10 each |
| `gunshop` | 2nd Amendment — East Row | Wilson | -1160.50, 2019.06, 7.76 | 33 m E | weapon rack (`military.weapon_rack`, fallback `military.case`) | pistol 400 (`Items.Preset_Lexington_Default`, slot 1), rifle 1 200 (`Items.Preset_Copperhead_Default`, slot 2), katana 900 (`Items.Preset_Katana_Default`, slot 3) — **licence required**, 500 €$ once |
| `clothes` | Jinguji Threads — Vendor Lane | Kimiko | -1212.26, 1978.53, 7.98 | 35 m SW | market stand (`market.stand.small`, fallback `light.spotlight`) | styling session 200 €$ → opens the wardrobe |
| `blackmarket` | Lower Walkway Dealer | Dex | -1201.07, 2035.60, 5.60 | 30 m N, **under the market** (Lower Walkway) | cargo crate (`crate.cargo`, fallback `electronics.monitor.device`) | synthcoke 150, lockpick 80, qh_ping 120 — **22:00–06:00 only**, inside the `kabuki_market` zone |

Every vendor is `Character.Judy` (`RpShopsConfig.vendor.record`, overridable per shop with
`vendor.record`), invulnerable (`damagePolicy = 2`), combat off, non-persistent (recreated on
every start). When a customer opens the shop the vendor looks at them and plays the `greeting`
voice line; when robbed, `fear_beg` and the `handsup` workspot for 20 s.

Prices, positions, fees, hours, loot and cooldowns are all in `RpShopsConfig`. To move a stall,
edit its `position` and shift `vendorPosition` and `prop.position` by the same amount.

## Commands

| Command | Who | Effect |
|---|---|---|
| **E** on a vendor | anyone alive, within 3 m, looking at them | Opens the shop: the vendor's line in chat, then the catalogue (UI kit context menu, one row per item with the price and, for a society shop, the stock). Pick an item → quantity dialog (1–20) → paid → delivered. The menu comes back after each purchase; **Leave** / Escape closes it. |
| `/boutiques` | anyone | Every shop with its distance from you, the black market's open/closed state and the owning society. |
| `/boutiques <shopId>` | anyone | That shop's catalogue in chat (with stock for a society shop, and the licence line for the gun shop). |
| `/boutiques restock <shopId>` | the society **boss** (`rp_jobs:isBoss` + same job) or the console | Refills every shelf of a society shop to its `restockTo`, paid from the society at 50 % of retail per unit (`restockCostRatio`). Refused when the society is dry, with the cost. |
| `/acheter <item> [count]` | anyone alive within 3 m of a vendor | Buys without the menu from the nearest vendor. `<item>` is the id (`water`), the label or an unambiguous prefix; `licence` at the gun shop buys the NCPD licence. |

Refusals are explained in chat: too far (with the distance), dead, position unknown, sold out
(with what is left), not enough eddies (with the price), pockets full, unknown item, black
market closed, no licence, wanted by the NCPD, another screen open, vendor still held up. From
the server console `boutiques` prints the list/catalogue to the log and `boutiques restock
<shopId>` is an admin tool; `acheter` answers "run this from the game".

## Rules the server applies

- **Payment**: `rp_economy:remove` (cash). If `insufficient_funds`, `rp_bank:withdraw` the
  amount to cash and take it (`paid=account`); a failed second step puts the withdrawal back.
  No split between cash and account.
- **Society shops** (`society = "<job>"`): `rp_bank:societyAdd(society, floor(price × 0.70),
  "sale:<shop>:<item>")` after every sale; stock decremented and persisted; the first boot
  seeds every item at `restockTo` (free opening stock). A shop without `society` has unlimited
  stock and pays nobody.
- **Gun licence**: NCPD members (`rp_jobs:hasJob(id, "ncpd")`, `gunLicenceExemptJobs`) need
  none. Everybody else buys one once (`gunLicenceFee` 500 €$): refused when `rp_ncpd:wanted`
  answers a warrant or `rp_ncpd:record(id).warrant` is set. Paid cash (credited to the `ncpd`
  society with `societyAdd`) or by `rp_bank:charge(id, 500, "ncpd", "gun_licence")`. Stored in
  `rp_shops_licences` (kvp `licence:<identifier>` without a database). The NCPD veto is
  re-checked at **every** gun sale, licence or not.
- **Guns**: `Open77.weapons.assign(playerId, record, slot, { active = true })`; the money is
  taken first, the sale is logged and told on `open77:weapons:completed` (`accepted`), refunded
  in cash otherwise or after 15 s without an answer.
- **Clothes**: the styling fee is charged **at once**, then the client runs the platform's
  `wardrobe` command locally (`Open77.runtime.executeCommand("wardrobe")`). The chat line always
  says "if the wardrobe didn't pop, type /wardrobe" — see *Honest limits*.
- **Black market**: `Open77.environment.getState().hour` must be in `[22, 6)`
  (`RpShopsConfig.blackmarket`); by day the dealer plays `rep_ask_to_leave` and answers with
  the `closedLine`. No clock authority (`open77_weather` absent) = never closed, logged once.
  The dealer also checks `rp_zones:isIn(id, "kabuki_market")` when `rp_zones` runs (the Lower
  Walkway is under the market).
- A dead player (`Open77.players.isDead`) buys nothing; the position snapshot must be younger
  than 5 s; one shop dialog per player at a time.

## Exports (server, synchronous — never yield)

```lua
exports.rp_shops:openShop(playerId, shopId)   -- true (dialog scheduled, no distance check) | nil, "invalid_player" | "unknown_shop"
exports.rp_shops:stock(shopId)                -- { { itemId, price, count }, ... } | nil, "unknown_shop"   (count = -1: unlimited)
exports.rp_shops:rob(shopId, byPlayerId)      -- loot (cash handed to the robber) | nil, reason
```

`rob` reasons: `unknown_shop`, `invalid_player`, `cooldown` (20 min per shop), `too_far`
(robber more than 5 m from the vendor), `position_stale` / `player_not_found`,
`register_empty` (society shop whose society is dry), `economy_offline`. On success the robber
receives `math.random(200, 600)` €$ in cash (`rp_economy:add`, reason `robbery:<shop>`), a
society shop loses the same from its society (as far as it goes), the vendor raises hands and
begs, `rp_shops:robbed` is raised and `rp_ncpd:alert("robbery", position, "<label> robbed",
byPlayerId)` pages the police. Call it inside `pcall`; a resource **with** a client script must
not declare `dependency "rp_shops"` (this manifest is delivered to clients).

## Events (host bus, `TriggerEvent`)

```lua
AddEventHandler("rp_shops:sale",   function(shopId, playerId, itemId, count, price) end) -- every paid delivery (items, weapons, licence, styling)
AddEventHandler("rp_shops:robbed", function(shopId, byPlayerId, amount) end)
```

Also raised: `rp_ncpd:alert` (robbery). Consumed: `open77:weapons:completed`, `onNpcRemoved`. Internal net
events (`rp_shops:open` client→server, `rp_shops:wardrobe` server→client) are this resource's
transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`, keyed by `Open77.players.identifier` (never the session id):

| Table | Columns |
|---|---|
| `rp_shops_stock` | `shop_id`, `item_id`, `count` — PK (`shop_id`, `item_id`); society shops only |
| `rp_shops_sales` | `id`, `shop_id`, `kind` (`item` / `weapon` / `licence` / `service`), `item_id`, `count`, `price`, `buyer` (identifier), `buyer_name`, `paid_with` (`cash` / `account`), `created_at` (unix) — every sale; `WHERE kind = 'weapon'` is the NCPD's gun ledger |
| `rp_shops_licences` | `identifier` (PK), `name`, `fee`, `created_at` |

Stock and licences are cached in memory and written through with the callback forms, so the
exports never touch the database; a licence is read on `onPlayerReady` (or lazily at the gun
shop). **No database** (`ready` answers `database_unavailable`, or nothing answers 15 s after
start): stock lives in kvp `stock:<shopId>` (JSON) and licences in `licence:<identifier>`,
the log says `store=kvp reason=...`, and there is no sales ledger (sales are still printed).

## Log (grep-able)

```
[rp_shops] 5 shops open around -1191, 2007; gun licence 500, styling 200, black market 22:00-06:00
[rp_shops] store=sql tables=rp_shops_stock,rp_shops_sales,rp_shops_licences stock rows=3
[rp_shops] vendor Rosa of supermarket spawned at -1178.1 2029.5 8.0 (npc 12)
[rp_shops] prop 1043 of supermarket at -1179.4 2030.3 8.0 (market.shelf.chinese)
[rp_shops] prop of clothes refused (invalid_model): market.stand.small
[rp_shops] no prop spawned for clothes: the vendor alone marks the stall
[rp_shops] sale shop=supermarket item=water x2 price=20 player 3 (<identifier>) paid=cash
[rp_shops] society trauma +28 (sale:pharmacy:bandage) balance=50028
[rp_shops] licence issued to player 3 (<identifier>) paid=account
[rp_shops] sale shop=gunshop weapon=pistol x1 price=400 player 3 (<identifier>) paid=cash
[rp_shops] Med-Point Pharmacy restocked: 4 units for 130 €$ from the trauma society. (by 2)
[rp_shops] ROBBERY shop=supermarket by player 4 loot=412
[rp_shops] no clock authority (environment_unavailable): the black market never closes
```

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``RpShopsConfig.Stage` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| an item bought | `give` one-shot (`carry_putdown`) on the buyer, and the vendor NPC plays `give` too (`Open77.npcs.tasks.workspot`, `Stage.vendorWorkspot`) | `crate.cardboard` bag in the right hand (`shop.bag` once it exists) | 2.5 s |
| a weapon bought | same hand-over | `military.case` in the right hand | 2.5 s, the weapon arrives through the relay |
| the gun licence | `phone` one-shot | the profile's holo | 3 s |
| a styling session | none: the wardrobe opens | -- | -- |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_shops] player 3 gesture purchase: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=crate.cardboard@RightHand 2500 ms
[rp_shops] player 3 gesture weapon: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=military.case@RightHand 2500 ms
[rp_shops] vendor workspot give refused: <reason> (the vendors stay still)
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Manifest

Permissions: `network.events` (net events, `TriggerClientEvent`, `Open77.weapons.assign`),
`database.access`, `world.npcs` (vendors), `players.life.read` (`isDead`),
`world.environment` (`getState` for the hours), `world.props` (the stall props, removed on stop). Dependencies: `open77_uikit`,
`open77_worldui`, `open77_weapons` — all ship a client half. `rp_economy`, `rp_bank`,
`rp_inventory`, `rp_jobs`, `rp_ncpd`, `rp_zones`, `rp_identity` are reached through `pcall`
and degrade to a chat line: no economy = no sale; no bank = cash only, no society share; no
jobs = nobody is exempt and nobody can restock; no NCPD = no veto; no identity = account names.

## Honest limits

- **The wardrobe opening is best-effort.** `open77_wardrobe`'s exports (`beginPreview` /
  `endPreview`) refuse every caller but `open77_wardrobe_ui`, and no documented native opens
  the wardrobe screen on a player from the server; the platform's `/wardrobe` command is the
  only door. The client runs it against its local command registry — if the command turns out
  to be server-side on this build it answers `unknown_command`, the fee is still charged, and
  the chat line tells the customer to type `/wardrobe` themselves.
- Voice lines (`greeting`, `fear_beg`, `rep_ask_to_leave`) are queued, not proven heard:
  `speak` cannot report a line the record's voiceset lacks. Test by ear on `Character.Judy`.
- `qh_ping` exists only while `rp_netrunner` runs; without it the dealer answers "item unknown"
  and refunds. `synthcoke` and `lockpick` are built-in `rp_inventory` items.
- The exports work on **connected** players (session ids). `Character.Judy` is the platform
  documentation's own shopkeeper record; the devkit catalogue does not list civilian
  `Character.*` ids, so a different look means editing `vendor.record` and testing it.

## Test in 2 minutes

One client at the freeroam spawn, Kabuki Market Centre `-1191.30, 2006.88, 7.82`, id `1`;
`rp_economy`, `rp_inventory`, `rp_bank`, `rp_jobs`, `rp_ncpd`, `rp_zones`, `open77_weather`,
`open77_uikit`, `open77_worldui`, `open77_weapons` running. Start with `rp_shop` unloaded. Log
on start: `[rp_shops] 5 shops open around -1191, 2007 ...`, `store=sql ...`, five `vendor ...
spawned` lines and five `prop ... of <shop>` lines (or `prop of <shop> refused (...)`).

1. `/boutiques` → five lines with distances (`Kabuki Market — Noodle Row (supermarket) - 25 m -
   5 lines`, `Lower Walkway Dealer (blackmarket) - 30 m - 3 lines [closed until 22:00]`,
   `Med-Point — The Stalls ... [trauma]`). Open the map: five pins on the market.
2. Walk 25 m north-east to **Noodle Row** (-1178.7, 2028.5): Rosa stands behind the ring, the
   shelf beside her. Press **E** → chat `Rosa: Water, burritos, NiCola...`, the menu opens.
   **Bottle of water** → quantity `2` → **Buy** → `Bought 2 x Bottle of water for 20 €$ (cash).
   It's in your pockets.`; `/inv` shows them. Pick **Leave**. Walk 10 m away and `/acheter
   water` → `No vendor within 3 m.`
3. **The Stalls** (-1223.9, 1989.5), the vending cage next to Dr. Osei: **E** → the rows read
   `10 in stock`. Buy a bandage → `9 in stock`, log `society trauma +28`. Console: `setjob 1
   trauma 3` then `/boutiques restock pharmacy` → `Med-Point — The Stalls restocked: 1 units
   for 20 €$ from the trauma society.` (`setjob` seeded the society). `/boutiques pharmacy` →
   `stock 10` again.
4. **East Row** (-1160.5, 2019.1), the weapon rack: **E** → the first row is **NCPD gun licence
   — 500 €$**. Pick **M-10AF Lexington** first → `No NCPD gun licence on file. Buy one here for
   500 €$ (/acheter licence).` Pick the licence → `NCPD gun licence issued for 500 €$ (cash)`.
   Pick the pistol → `... delivery in progress...` then `Delivered: M-10AF Lexington (slot 1)`;
   the gun is in hand. Log: two `sale shop=gunshop` lines with your identifier. With an NCPD
   warrant (`/mandat 1 2 test` from an officer) the same purchase answers `NCPD has a warrant
   on you`.
5. **Vendor Lane** (-1212.3, 1978.5), the mannequin: **E** → **Styling session** → `Styling fee
   200 €$ (cash) paid. The racks are yours...` and the wardrobe opens (or type `/wardrobe`).
6. **Lower Walkway** (-1201.1, 2035.6, z 5.6 — take the stairs down under the market) by day:
   **E** → `Dex: Not in daylight, choom. Come back after 22:00...`. Console: `weather.time.set
   23:00`. **E** again → the menu; buy a lockpick → `Bought 1 x Lockpick for 80 €$`. `/acheter
   synthcoke 2` at the crate works too.
7. Empty your cash (`/pay` it away or spend it), deposit at an ATM (`rp_bank`, one stands 3 m
   east of the market centre), buy again: the line ends with `(account)`.
8. From another resource: `exports.rp_shops:stock("pharmacy")` → three rows with counts;
   `exports.rp_shops:rob("supermarket", 1)` while standing at Rosa → Rosa raises hands, chat
   `Rosa empties the register: 4xx €$ in cash...`, an on-duty officer reads the NCPD dispatch
   line, log `ROBBERY shop=supermarket by player 1 loot=...`; a second call answers `cooldown`.
9. Reconnect: the licence is still on file (no licence row offered at the gun shop).
