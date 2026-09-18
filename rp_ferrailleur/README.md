# rp_ferrailleur — scrap and salvage out of town

The "miner" job of Night City for an Open77 RP server (build `2.31.13+op77.76`): a scrapper
clocks in, pries wrecks open in the **Rancho Coronado junkyard** with a **crowbar** that wears
out, and sells the junk to a **scrap dealer NPC** whose prices drift every ten minutes. Server-authoritative: the
client only draws the rings and forwards the E prompt; the server checks the distance, the job,
the tool, the wreck's state, rolls the loot, moves the eddies and keeps the durability in SQL.

## Where it is

The yard is the **real Rancho Coronado junkyard** on the Badlands edge (AMM point `1374.9,
-1674.9, 49.3`), the `junkyard` zone of `rp_zones` (same centre, radius 90 m, kind industrial).
From the Kabuki Market spawn (`-1191.3, 2006.9, 7.8`) it is about **4.5 km south-east** as the
crow flies: take a car. Follow the map pin (rp_zones). All positions are in
`shared/config.lua`:

| What | Position | Notes |
|---|---|---|
| Scrap dealer (NPC + ring + prompt) | `1368.0, -1676.0, 49.4`, yaw -173 | `Config.dealer` |
| Wreck 1 — Burnt-out Thorton | `1380.0, -1682.0, 49.4` | trash prop 1.5 m south-east |
| Wreck 2 — Gutted Quadra | `1386.0, -1676.0, 49.4` | |
| Wreck 3 — Rusted Mizutani | `1388.0, -1664.0, 49.4` | |
| Wreck 4 — Crushed Archer | `1376.0, -1660.0, 49.4` | corrugated sheet 2 m north-east |
| Wreck 5 — Stripped Makigai | `1366.0, -1664.0, 49.4` | |
| Wreck 6 — Flipped Villefort | `1362.0, -1686.0, 49.4` | |
| Wreck 7 — Scorched Chevillon | `1372.0, -1690.0, 49.4` | |

Seven wrecks within 17 m of the yard centre, 6 m or more apart, clear of the other junkyard
spots (rp_crime's fence `1381, -1668`, rp_gangs' buyer `1370, -1670`, rp_mecano's impound
`1370, -1680`); the dealer stands near the middle. `z = 49.4` is the AMM ground height + 0.1;
the yard is not flat, so if a ring is not visible, stand on the spot, `/pos`, and paste the
real height — a ring drawn inside the floor reports success and shows nothing. The server
tolerates 4 m of height error (`Config.heightTolerance`).

**Props.** At start the server spawns `Config.props` through `Open77.props.create` (permission
`world.props`, curated prop aliases (see `prop.catalog`) — a raw `.mesh` path renders as a white
slab) and removes them at stop: a barrel (`container.barrel`) by the dealer (`1366.6, -1674.6`),
industrial trash (`garbage.industrial_trash`) by wreck 1 (`1381.4, -1683.4`), a corrugated sheet
(`debris.corrugated_sheet`) by wreck 4 (`1377.5, -1658.6`). A refused prop is logged (`prop N (...) not
spawned: <reason>`); the yard works without it.

## What the player sees

- One ground ring per wreck (`open77_worldui`): **interaction** style with an E prompt
  **Search the wreck** while it is ready (`promptDistance` 3 m, look at it to press), an
  **objective** ring with no prompt while someone works it, a **danger** ring with no prompt
  while it is picked clean (5 min). The server pushes every state change to every client.
- One ring + prompt **Talk to the scrap dealer** at the dealer's feet; the NPC stands on it.
- Pressing E on a wreck: the server checks you are within 3.5 m, hold the `ferrailleur` job
  **and are on duty** (`rp_jobs`), and carry a **crowbar** (`rp_inventory`). Then an 8 s
  progress bar (UI kit, cancellable with **X**, move and combat disabled) while your body kneels
  (RP profile `examine`, server-driven). At the end the server re-checks you are still there and
  rolls: **scrap ×2–4 (60 %)**, **component ×1–2 (30 %)**, **chip ×1 (10 %)**, put in your
  pockets. `too_heavy`: you are told and get nothing — the wreck is still spent and the crowbar
  still worn. The wreck regenerates after **5 min**.
- The crowbar loses **1 durability per search** (20 per crowbar) and **breaks at 0**: it is
  removed from the pockets and you are told. The dealer sells a new one for **250 €$**.
- The dealer menu (UI kit context menu): **Sell scrap** (everything sellable, at today's
  prices; the per-item rows show the price and what you carry), **Buy a crowbar** (250 €$,
  refused while you already carry one), **Prices today**, **Leave**.
- Prices: base `scrap 15 / component 60 / chip 200 €$`, each redrawn **±20 %** every
  **10 min** (`Config.priceVariation`, `Config.priceIntervalMs`). A sale pays **90 % in cash**
  to the scrapper (`rp_economy`) and **10 % to the `ferrailleur` society** (`rp_bank`,
  `Config.societyShare`; set it to `0` to give the scrapper everything). A crowbar's price
  also goes to the society, which is what pays the scrappers' payroll in `rp_jobs`.

Every refusal is one chat line from `Scrapyard` (the author name): too far (with the distance), not a scrapper,
off duty, no crowbar, wreck busy / picked clean (with the time left), pockets too heavy, not
enough eddies, a sibling resource offline.

## Commands

| Command | Effect |
|---|---|
| `/ferraille` | Your status: job/duty, crowbar durability (`12/20 searches left`, or where to buy one), today's prices with their trend and the time to the next change, how many wrecks are picked clean and when the next one is back, and the yard's coordinates. |
| `/vendre` | Sells every scrap, component and chip in your pockets to the dealer — **within 5 m** of him (`Config.dealer.reach`). The fallback for the prompt. Refused elsewhere with the distance and the yard's position. |

Both refuse the server console (`run it from the game, choom`). Suggestions are published on
`chat:ready` and once with `-1` from `onResourceStart`.

## Exports (server, synchronous, never yield)

```lua
exports.rp_ferrailleur:prices()            -- { scrap = 14, component = 66, chip = 181 }  (today's unit prices)
exports.rp_ferrailleur:durability(playerId) -- 0..20 (0 = no crowbar) | nil, "invalid_player_id" | "player_not_found" | "not_loaded"
exports.rp_ferrailleur:pointStates()       -- { { index, state = "ready"|"busy"|"depleted", readyAt = unix }, ... }
```

Call them inside `pcall`; this resource ships a client script, so a resource **with** a client
script must not declare `dependency "rp_ferrailleur"` — one without may.

## Events

Raised on the host bus (`TriggerEvent`):

```lua
AddEventHandler("rp_ferrailleur:searched", function(playerId, index, itemId, count) end) -- loot pocketed
AddEventHandler("rp_ferrailleur:sold",     function(playerId, total, payout, societyCut) end)
```

Consumed: `onResourceStart` (own start, and `rp_inventory` restarting → the crowbar is
re-declared through `exports.rp_inventory:define`), `onResourceStop`, `onPlayerReady`,
`onPlayerDisconnected`, `chat:ready`.

Internal client/server transport (not an API): `rp_ferrailleur:clientReady`,
`rp_ferrailleur:search (index)`, `rp_ferrailleur:dealer` (client → server);
`rp_ferrailleur:pointState (index, state, readyAt)`, `rp_ferrailleur:allState (list)`
(server → client). Local client events `rp_ferrailleur:prompt_<n>` / `prompt_dealer` are what
the world-UI prompts fire.

## Items

The **crowbar** (`crowbar`, "Crowbar", 1.5 kg, not usable, legal) is declared in `rp_inventory`
through `exports.rp_inventory:define` from this resource's `onResourceStart` and again whenever
`rp_inventory` restarts. `scrap`, `component` and `chip` are `rp_inventory`'s own items.

Durability is **per scrapper, not per crowbar**: one row per identifier. A crowbar with no
recorded wear (bought elsewhere, `/giveitem`, picked up after the last one broke) counts as a
fresh one (20) the first time it is used. When one breaks and you carry a spare, the spare
starts fresh.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`:

```sql
rp_ferrailleur_tools (
    identifier VARCHAR(64) PRIMARY KEY,   -- Open77.players.identifier, never the session id
    durability INT        NOT NULL DEFAULT 0,
    updated_at BIGINT     NOT NULL DEFAULT 0   -- unix seconds
)
```

The row is read on `onPlayerReady` (callback form) and for everyone already connected on a hot
start; every change is written through with the callback form (`INSERT ... ON DUPLICATE KEY
UPDATE`), so the exports never touch the database. Until the row is read, searching and buying
answer `Your tool file is still loading` rather than risk overwriting real wear.

**No database** (`ready` answers `database_unavailable`, or the database still is not
answering 15 s after the first player is ready — `Config.databaseGraceMs`): durability falls
back to `Open77.kvp` (key `tool:<identifier>`) and the log says `[rp_ferrailleur] store=kvp
reason=...`. The choice is kept for the whole boot.

Wreck states and prices live in memory only: a restart brings every wreck back and redraws
the prices.

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
| E on a wreck | `examine` kneel, looped (`scavenge`) | `tool.fire_axe` in the right hand (the crowbar, `tool.crowbar` once it exists) | 8 s bar (`Config.searchMs`) |
| the loot | `give` one-shot | `crate.ammo_box` held up (`debris.scrap` once it exists) | 2.5 s |
| Sell scrap / `/vendre` | `give` looped (`carry_putdown`) | `crate.ammo_box` in the right hand | 3 s bar, a cancel puts the goods back |
| Buy a crowbar | `give` one-shot (`carry_putdown`) | `tool.fire_axe` in the right hand | 2.5 s |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_ferrailleur] player 3 stage search: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=tool.fire_axe@RightHand place=none 8000 ms -> ok
[rp_ferrailleur] player 3 gesture loot: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=crate.ammo_box@RightHand 2500 ms
[rp_ferrailleur] player 3 stage sell: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=crate.ammo_box@RightHand place=none 3000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Manifest

Permissions: `network.events` (net events, toasts), `database.access` (SQL), `world.npcs`
(the dealer), `players.animations.control` (the kneel), `world.props` (the decoration). Dependencies: `open77_uikit` (server
twins `progress` and `context`), `open77_worldui` (rings + prompts), `open77_notifications`
(toasts) — all three ship a client half. `rp_jobs`, `rp_zones`, `rp_inventory`, `rp_economy`
and `rp_bank` are server-only and reached through `pcall`'d exports: without `rp_jobs` a
search is refused (`guild offline`), without `rp_inventory` nothing can be pocketed or sold,
without `rp_economy` a sale gives the goods back, without `rp_bank` the society's share is only
logged.

The dealer is spawned with `Open77.npcs.create` (numeric `damagePolicy = 2`, combat and voice
disabled). `Config.dealer.record` (a `Character.*` id) is tried first when set; the default is
the documented passive civilian alias `civilian_female_relaxed_01` (resolves to
`Character.Panam`, invulnerable by TweakDB). If both are refused the log says so and the ring,
the prompt and `/vendre` still work at the spot.

## Work outfit (suggestion, not implemented)

A scrapper's look through the wardrobe (`open77_wardrobe` / the Equipment Lua API), applied on
`/service` by `rp_jobs` or by this resource on `rp_jobs:duty`: a stained work jacket
(`Items.Jacket_*` nomad or worker variant), cargo pants, heavy boots, welding goggles on the
forehead, fingerless gloves. Nothing here touches the wardrobe; the hook would be
`AddEventHandler("rp_jobs:duty", function(playerId, job, onDuty) ... end)` filtered on
`job == "ferrailleur"`.

## Log (grep-able)

```text
[rp_ferrailleur] started: 7 wrecks, dealer at 1368.0 -1676.0 49.4, regen 5 min, crowbar 20 searches / 250 €$
[rp_ferrailleur] items defined in rp_inventory: registered=1 rejected=0
[rp_ferrailleur] prices scrap=14 component=66 chip=181 (next roll in 10 min)
[rp_ferrailleur] dealer spawned template=civilian_female_relaxed_01 id=... at 1368.0 -1676.0 49.4
[rp_ferrailleur] props spawned: 3
[rp_ferrailleur] store=sql table=rp_ferrailleur_tools
[rp_ferrailleur] player 3 tool loaded durability=nil (sql)
[rp_ferrailleur] player 3 bought a crowbar for 250 cash=250
[rp_ferrailleur] player 3 wreck 2 +3 scrap durability=19
[rp_ferrailleur] wreck 2 regenerated
[rp_ferrailleur] player 3 sold 3 x scrap @ 14, 1 x component @ 66 total=108 payout=97 society=11 cash=347
```

## Test in 2 minutes

One client at the Kabuki Market spawn (id `1`) with a car; `rp_jobs`, `rp_inventory`,
`rp_economy`, `rp_bank` and `rp_zones` running. Log on start: the `started:` line, `items
defined in rp_inventory`, `prices ...`, `dealer spawned ...`, `props spawned: 3`, then
`store=sql ...`.

1. **Console:** `setjob 1 ferrailleur 0` (or walk to the agency ring at Kabuki's Gallery, press
   **E**, pick **Scrapper**). Then in game `/service` → `Clocked in at Scrapper ...`.
2. `/ferraille` → `Scrapper on duty. No crowbar. Rusty sells one for 250 €$.`, the prices
   line, `All 7 wrecks are ready to be searched. Yard: 1368, -1676.`
3. Drive to the Rancho Coronado junkyard, ~4.5 km south-east (rp_zones map pin; the toast
   `Junkyard` fires 90 m out). Seven rings among the real wrecks, a standing NPC by a trash
   drum with a ring under her. Console `givemoney 1 500` if short on cash (`/money`).
4. Look at the dealer's ring, press **E**: the menu `Rusty, scrap dealer`. **Buy a crowbar** →
   `Bought a crowbar for 250 €$. Good for 20 searches. Cash: ...`. `/inv` lists `Crowbar`.
   Open the menu again, **Buy a crowbar** → `You already carry a crowbar. Wear it out first.`
5. Look at a wreck ring, press **E**: the bar `Searching the wreck` (8 s) while you kneel;
   press **X** half-way → `You stop searching.` and the ring is back to normal. Press **E**
   again and wait: `Pried open Gutted Quadra: +3 x scrap. Crowbar 19/20.` and a toast. The
   ring turns to the **danger** style with no prompt; `/ferraille` → `1 of 7 wrecks picked
   clean, next one back in 5 min.`
6. Press **E** on the same wreck from 4 m away with the prompt of a neighbour: nothing — walk
   to a ready one instead. Search two or three more wrecks (different loot rolls).
7. `/service` (clock out), press **E** on a wreck → `Clock in first: /service.` Clock back in.
8. Walk 10 m away, `/vendre` → `Rusty is not within 5 m (you are 10 m away). The yard is at
   1368, -1676.` Walk back next to the dealer, `/vendre` → `Sold 3 x scrap @ 14, 1 x component @ 66 for 108 €$. You
   pocket 97 €$, the guild takes 11 €$. Cash: ...`; `/money` went up; `/societe` as a scrapper
   shows the society balance.
9. Console `giveitem 1 crate 1` then search a wreck: `You dig out 2 x scrap but your pockets
   are too heavy. It stays in the dirt.` — the wreck is still spent and the crowbar still worn.
10. Wait 5 min (or lower `Config.regenMs`): the ring goes back to the **interaction** style
    with its prompt, log `wreck N regenerated`.
11. Lower `Config.crowbar.durability` to `2`, reload, `/ferraille` (a fresh crowbar reads
    `2/2`), search twice: `Your crowbar is bending: 1 searches left.` then `Your crowbar
    snapped in half. The dealer sells a new one for 250 €$.`; `/inv` no longer lists it.
12. Reconnect: `/ferraille` shows the same durability (`player 1 tool loaded durability=...`
    in the log). Wait 10 min (or lower `Config.priceIntervalMs`): `prices ...` again in the
    log, `/ferraille` shows the new numbers and trends.
13. From another resource: `print(exports.rp_ferrailleur:prices().scrap,
    exports.rp_ferrailleur:durability(1))`.
