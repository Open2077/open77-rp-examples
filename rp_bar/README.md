# rp_bar — the Afterlife bar counter

The bartender job for a Night City RP server on Open77 (build `2.31.13+op77.76`). An on-duty
`barman` (rp_jobs v2) works a counter inside the `afterlife` zone: mixes drinks from ingredients
in their pockets, restocks those ingredients with the till's money, reads the till, and serves
customers who **see the price and accept** before paying in cash. Drinking a glass raises a
per-player **buzz** that wobbles the screen and, past a point, makes the drinker stumble. A
synthesized club ambience plays around the counter.

Server-authoritative: the job, the duty, the distance, the pockets, the money and the ledger
are all decided on the server. The client renders the counter ring/prompt and the ALT+click
action, and requests.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/bar` | anyone | Customers: the **card** (every drink, its price, its buzz) and your own buzz. Barman on duty: the till, your ingredient stock, your drinks and your buzz in chat, then — within `counter.reach` (8 m) of the counter — the **counter menu** (same as the E prompt). Off-duty barman: the card plus a `/service` hint. |
| `/servir <playerId> <drink>` | barman on duty | Fallback for ALT+click: offers `drink` (`beer`, `whisky`, `johnny_silverhand`, `synth_soda`, a label or an unambiguous prefix) to a customer within 3 m. Refused on yourself. |
| `/interaction accept` / `decline` | the customer | The platform's own answer to the offer (`open77_player_interactions`), for a client without the invitation UI. |

Both commands refuse the server console (`run this from the game`). They are published as chat
suggestions on `chat:ready` and once at start.

## Where it is

The bar is **The Afterlife** (Little China, Watson) — the real one, inside, at the end of its
bar counter. `RpBarConfig.counter.position = { x = -1451.5, y = 1012.5, z = 17.8 }` (a bot
stood on that exact spot on 2026-09-18; `z` is the walked floor height). It sits inside the
`afterlife` zone of `rp_zones` (centre `-1453, 1017, 16.6`, radius 50). From the Kabuki Market
spawn (`-1191.3, 2006.9, 7.8`) it is about **1 km south**: follow the map pin, or a Delamain.

| What | Position | Notes |
|---|---|---|
| Bar counter ring + E prompt | `-1451.5, 1012.5, 17.8`, radius 3.5 | `RpBarConfig.counter`; on-duty barman only |
| Bar floor (entrance stairs side) | `-1453.0, 1016.7, 16.5` | the `afterlife` zone centre |
| Jukebox prop | `-1450.3, 1013.5, 18.9`, yaw -138.5 | `RpBarConfig.props[1]` (`electronics.jukebox`), server-spawned |

While a barman is on duty their client draws a ring, a map pin and an `E` prompt **The
Afterlife - bar counter** there (`open77_worldui`, `promptDistance = 4.0`, style `interaction`);
customers see nothing (`showCounterToCustomers = false`). The server re-checks the duty and the
distance (`counter.reach`, 8 m; `0` = anywhere) before opening anything.

The config knows **one counter**. Lizzie's Bar (`-1188.9, 1566.2, 22.9`, zone `lizzies`) is not
a second counter: that would need a second counter table, POI and ambience sweep.

**Props.** At start the server spawns the entries of `RpBarConfig.props` through
`Open77.props.create` (permission `world.props`, curated prop alias (see `prop.catalog`) — a
raw `.mesh` path renders as a white slab) and removes them at stop. The bar exists, so there is
no counter prop — only a jukebox (`electronics.jukebox`) against the wall behind the counter's
end. A refused prop is logged (`prop 1 (...) not spawned: <reason>`) and nothing else changes.

The counter menu (UI kit `context`, server-driven):

- **Recipes** — one row per drink with its recipe, price, how many you carry and what is
  missing (greyed out when an ingredient is short). Picking one runs a 4 s progress bar
  (cancellable, movement and combat blocked) with the RP `give` profile
  (`Open77.animations.play`; the bar works without the animation), re-checks the pockets, takes
  the ingredients and puts the drink in your pockets.
- **Restock** — one row per ingredient with its cost; picking one takes the cost from the
  **till** (`rp_bank:societyRemove("barman", cost, "restock:<id>")`) and puts one unit in your
  pockets. A dry till, an offline bank or full pockets are refused and explained (the till is
  refunded when the pockets refuse).
- **Till** — the society balance and today's sales (from `rp_bar_sales`; this session's counters
  when there is no database).
- **Leave the counter**.

The menu reopens after every action until you leave, Escape or the 60 s timeout.

## The card

| id | label | price | alcohol (buzz per glass) | recipe (from the barman's pockets) | thirst |
|---|---|---|---|---|---|
| `beer` | Beer | 30 €$ | +1 | 1 × Mixer (keg) | +25 |
| `synth_soda` | Synth soda | 20 €$ | 0 | 1 × Ice (bag) | +30 |
| `whisky` | Whisky | 60 €$ | +2 | 1 × Spirits (bottle), 1 × Ice (bag) | +10 |
| `johnny_silverhand` | Johnny Silverhand | 120 €$ | +3 | 1 × Spirits, 1 × Mixer, 1 × Ice | +15 |

Ingredients (not usable): `ingredient_spirits` 1.0 kg, 40 €$ · `ingredient_mixer` 1.0 kg, 15 €$ ·
`ingredient_ice` 0.5 kg, 10 €$. Drinks weigh 0.5 kg (beer) / 0.4 kg (others), are `usable`, legal.

All of it is `shared/config.lua` (`RpBarConfig.drinks`, `.ingredients`, `.craft`, `.sale`,
`.drunk`, `.ambience`). Every item is declared through `exports.rp_inventory:define` at start and
again whenever `rp_inventory` restarts; the `effect = { needs = { thirst = … }, text = … }` is
applied by `rp_inventory` through `rp_needs:apply` on `/use`; `price`, `alcohol`, `recipe` and
`flavour` are read by this resource only.

## Serving a customer

1. The barman holds **ALT**, clicks the customer, picks **Serve a drink** (`open77_contextmenu`,
   shown only while the server said you are a barman on duty; 3 m). A menu lists the drinks in
   the barman's pockets with their price; pick one. Or `/servir <playerId> <drink>`.
2. The server checks: on duty, not yourself, customer connected, within `sale.distance` (3 m),
   the drink in your pockets, the customer not already reserved. The customer reads the offer
   and the **price** in chat and as a toast, and the platform invitation opens
   (`Open77.playerInteractions.request(barman, customer, "give", { consent = true,
   durationMs = 4000, inviteTimeoutMs = 20000 })`).
3. The customer accepts (invitation UI or `/interaction accept`): both play the give hand-over
   for 4 s. On `onPlayerInteractionCompleted` the server settles: **cash** from the customer
   (`rp_economy:remove`), the drink moves from the barman's pockets to the customer's, **70 %**
   of the price to the till (`rp_bank:societyAdd("barman", …, "sale:<drink>")`), **30 %** to the
   barman as a cash tip (`rp_economy:add`), one row in `rp_bar_sales`, the `rp_bar:sold` event.
   A customer who cannot pay, cannot carry the glass, or a barman whose glass vanished: no
   money moves (or it is refunded) and both are told why. Decline, timeout, walking away,
   death or a vehicle cancel the offer; both are told.
4. Without the interaction service (`interactions_unavailable`), the customer answers a UI-kit
   dialog that shows the price instead (`Pay 30 €$` / `No thanks`), then the same settlement.

Every refusal is a short English chat line (`Afterlife`, pink). One offer at a time per barman.

## The buzz

`/use beer` goes through `rp_inventory`, which debits the glass, restores thirst and raises
`rp_inventory:used (playerId, itemId)`. This resource listens for its own drink ids:

- **level** 0..10 per player, `+alcohol` per glass, **−1 every minute** (`drunk.tickMs`). Shown as
  `Buzz: 4/10 (drunk)` in `/bar` and after every glass (`sober` 0, `buzzed` 1–3, `drunk` 4–7,
  `wasted` 8–10). In memory only: cleared on disconnect and on resource stop.
- the RP `drink` profile plays on the drinker for 4 s (`players.animations.control`).
- **above 3**: the game's own drunk overlay on the drinker's screen —
  `Open77.effects.screen(playerId, "drunk", { strength, duration })`, permission
  `players.screenfx`; `strength` 0.2 / 0.5 / 1.0 picks `drunk.light` / `.medium` / `.heavy` for
  levels 4–5 / 6–7 / 8–10. The overlay is re-applied every tick with a 65 s duration and expires
  by itself once the level is back to 3 (nothing another resource put on the screen is cleared).
  A chat line marks the crossing.
- **above 7**: a stumble — `Open77.players.ragdoll(playerId, { durationMs = 2000 })`, the engine's
  knockdown with a clock (since op77.73; its card names `players.motion.control`, a permission
  the platform does not define, and checks none) — right after the glass and once per tick
  while wasted, with a chat line. The stumble is refused (and only the line shows) on a server
  **without a database** (`motion_unavailable`: the motion lease belongs to the cyberware store),
  in a vehicle or while down (`body_unavailable`), or within 1.5 s of another fall
  (`motion_busy`); the refusal is logged once.

## Ambience

`sfx/afterlife_ambience.wav` — 12 s, mono, 22 050 Hz, 529 KB, **entirely synthesized** by
`tools/make-ambience.mjs` (sub-bass drone, muffled kick, low-passed crowd murmur; no sample, no
recording — royalty free by construction; `node tools/make-ambience.mjs` regenerates it byte
for byte). It is declared in `files { }` and played per player by the server:
`Open77.sound.play(playerId, "sfx/afterlife_ambience.wav", { id = "afterlife_ambience", loop = true,
position = counter, maxDistance = 32, refDistance = 4, volume = 0.5 })` for everyone within
`ambience.radius` (30 m) of the counter, stopped beyond 34 m (`Open77.sound.stop`), swept every 5 s
with `Open77.players.nearby(counter, 34)`. The file rides the client resource image (the manifest
has a client script, as `open77_sound` requires) and is HRTF-spatial at the counter. Set
`ambience.file = false` to disable.

## Exports (server, synchronous, never yield)

```lua
exports.rp_bar:getDrunk(playerId)         -- 0..10 (0 for an unknown player)
exports.rp_bar:addDrunk(playerId, amount) -- new level | nil, reason (a ripper's sedative, a quest)
exports.rp_bar:card()                     -- { { id, label, price, alcohol }, ... } in card order
exports.rp_bar:isBarmanOnDuty(playerId)   -- boolean
```

Call them inside `pcall` from another resource. This manifest has a client script, so it never
declares an `rp_*` dependency; `rp_jobs`, `rp_inventory`, `rp_bank`, `rp_economy` and
`rp_identity` are reached through `pcall(Open77.exports.callSync, …)` and their absence is
explained in chat (`The bank is offline`, `The pockets system (rp_inventory) is offline`, …).

## Events (host-wide bus)

```lua
AddEventHandler("rp_bar:sold",  function(barmanId, customerId, drinkId, price) end)
AddEventHandler("rp_bar:drunk", function(playerId, level) end)   -- every level change
```

Consumed: `rp_inventory:used` (the buzz), `rp_jobs:duty` / `rp_jobs:changed` (the client's
duty flag), `onPlayerInteractionCompleted` / `onPlayerInteractionCancelled` (settlement),
`onResourceStart` of `rp_inventory` (re-define the items) and `rp_jobs` (re-push duty).
Internal net events (`rp_bar:clientReady`, `rp_bar:counter`, `rp_bar:serve`, `rp_bar:duty`) are
this resource's transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`:

```sql
rp_bar_sales (
    id       BIGINT      AUTO_INCREMENT PRIMARY KEY,
    barman   VARCHAR(64) NOT NULL,   -- Open77.players.identifier of the barman
    customer VARCHAR(64) NOT NULL,   -- Open77.players.identifier of the customer
    drink    VARCHAR(32) NOT NULL,   -- the drink id
    price    INT         NOT NULL,   -- what the customer paid
    at       BIGINT     NOT NULL,   -- unix seconds
    INDEX (at), INDEX (barman)
)
```

Rows are written with the callback form of `Open77.database.insert` (never on an export path).
**No database** (`ready` answers `database_unavailable`, or it is still not answering
`persistence.dbWaitMs` = 15 s after start): the ledger goes to the resource KVP store
(`sales:count`, `sales:<n>` = `barman|customer|drink|price|at`) and the log says
`[rp_bar] store=kvp reason=...`; sales made before the choice are queued and flushed. The till
itself lives in `rp_bank` (society `barman`); the buzz is in memory.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``RpBarConfig.Stage` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| Mix a drink | `give` looped (`rubhands`) | `food.bourbon` bottle in the right hand (`food.bottle` once it exists) | 4 s bar (`craft.durationMs`) |
| Restock | `give` one-shot (`carry`) | `container.keg` lifted in front of the chest (root frame) | 2.5 s |
| Serve a drink | the platform's `give` interaction animates both players (no pose of ours) | `food.bourbon` in the bartender's hand from the offer to the hand-over | the interaction (4 s) |
| the customer | `drink` one-shot after the hand-over (`bottle`) | the profile's own can | 4 s |
| `/use <drink>` | `drink` one-shot (`drunk.profile`, unchanged) | the profile's own can | 4 s |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_bar] player 3 stage mix: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=food.bourbon@RightHand place=none 4000 ms -> ok
[rp_bar] player 3 gesture restock: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=container.keg@root 2500 ms
[rp_bar] player 3 hold serve: pose=none prop=food.bourbon@RightHand
[rp_bar] player 5 gesture sip: pose=drink/stand__rh_can__01__drink__01 prop=none 4000 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Manifest

Permissions: `network.events` (net events, toasts, `Open77.sound`), `database.access`,
`players.animations.control` (`Open77.animations.play`), `players.interactions.control` +
`players.interactions.read` (`Open77.playerInteractions.request` / `cancel` / `current`),
`players.screenfx` (`Open77.effects.screen`), `world.props` (`Open77.props.create` / `remove`,
the neon frame). Dependencies (all ship a client half):
`open77_uikit`, `open77_worldui`, `open77_contextmenu`, `open77_player_interactions`,
`open77_notifications`, `open77_sound`. `open77_animations` must run on the server for clients to
render the profiles (the server API accepts without it). Files: `sfx/afterlife_ambience.wav`.

## Log (grep-able)

```text
[rp_bar] props spawned: 1
[rp_bar] started: counter at -1451.5 1012.5 17.8 (reach 8.0 m), 4 drinks, 3 ingredients, society 'barman', ambience on
[rp_bar] items defined (start): registered=beer,ingredient_ice,... rejected=none
[rp_bar] store=sql table=rp_bar_sales
[rp_bar] player 1 restocked ingredient_mixer for 15 till=49985
[rp_bar] player 1 mixed beer
[rp_bar] offer beer: 1 -> 2 for 30 (interaction 3f2a...)
[rp_bar] sale beer: <identifier> -> <identifier> for 30 (till +21, tip +9, via interaction)
[rp_bar] player 2 buzz 0 -> 1 (drank beer)
[rp_bar] stumble refused (motion_unavailable); only the chat line is shown
[rp_bar] RP animation 'give' refused (unknown_profile); the bar works without it
```

## Test in 2 minutes (one player)

Inside The Afterlife (walk in from Kabuki Market, ~1 km south, or console `tp 1 -1453 1017 16.6`
onto the bar floor), with `rp_jobs`, `rp_bank`, `rp_economy`, `rp_inventory` (and ideally
`rp_needs`, `rp_zones`) running. Player id `1`.

1. **Console:** `setjob 1 barman 3` — you are boss at the bar; the log shows `society barman
   seeded +50000` (rp_jobs seeds the till once). `/bar` → the card, then `You are the staff
   here: /service to clock in...`.
2. `/service` → `Clocked in at Bartender...` and `Behind the counter. The ring is at -1452, 1012:
   press E there or /bar.` A pink ring and an `E` prompt **The Afterlife - bar counter** appear
   at the end of the bar counter, a few metres from the entrance stairs (map pin too), with the
   neon frame on the wall behind it. Walk there: the club ambience fades in around 30 m.
3. `/bar` (within 8 m) → `Till: 50 000 €$...`, `Stock: Spirits (bottle) x0, ...`, `Buzz: 0/10
   (sober)`, then the counter menu. Or look at the ring and press **E**.
4. **Restock** → **Mixer (keg) - 15 €$** → `Restocked 1 x Mixer (keg) for 15 €$. Till: 49 985 €$.
   You carry 1.` Buy a **Spirits** and an **Ice** too. `/inv` shows the three ingredients.
5. **Recipes** → **Beer** (greyed rows are the ones you lack ingredients for) → a 4 s bar `Mixing
   a Beer` (the `give` pose plays when `open77_animations` runs) → `Beer ready. You now carry 1.
   Sells for 30 €$.` Press X during the bar: `You put the shaker down. Nothing was used.`
6. `/servir 1 beer` → `You cannot serve yourself, choom. Pour one and /use it.` (ALT+click your
   own body shows no **Serve a drink** either.)
7. With a second player `2` next to you: ALT+click them > **Serve a drink** > **Beer x1 - 30 €$**
   (or `/servir 2 beer`). Player 2 reads `... offers you a Beer for 30 €$...` and accepts the
   invitation (`/interaction accept`); after the 4 s hand-over: you read `Served a Beer to ...
   for 30 €$. Tip: 9 €$ ... Till: 49 956 €$` (49 935 after the three restocks, +21), they read `... slides you a Beer. -30 €$. /use beer
   to drink it.`; `/money` on player 2 dropped by 30. Decline instead → `... passed on the Beer.`
   Alone: **console** `giveitem 1 beer 2` fills your own pockets instead.
8. `/use beer` → rp_inventory's 3 s bar, `Cold and bitter. Good.`, thirst +25, then `A Broseph
   from the tap... Buzz: 1/10 (buzzed)` and the `drink` pose. Three more glasses (`/use beer`)
   → at 4 the screen wobbles and `The room starts to tilt...`; mix a **Johnny Silverhand**
   (spirits + mixer + ice) and `/use johnny_silverhand` → at 8 `Your legs have opinions of their
   own now...` and you fall for 2 s (with a database; without one the log says
   `stumble refused (motion_unavailable)`).
9. `/bar` → `Buzz: 8/10 (wasted)`; every minute the level drops by one, the wobble follows,
   and at 0: `Sober again...`.
10. **Till** in the counter menu → `Till: 49 956 €$. Today: 1 drink(s) sold for 30 €$.`; from
    another resource `print(exports.rp_bar:getDrunk(1))`.

## Limits

- The buzz is not persisted; a reconnect sobers you up.
- The overlay is re-armed every minute for its 65 s: after sobering below 4 it lingers at most
  five seconds; the resource never calls `clearScreen`, so another resource's overlay is safe.
- Ambience is per client and not sample-synchronized between clients (`open77_sound` is not
  Wwise); it does not follow the game's volume sliders.
- A player already inside the ambience radius when the resource starts hears it on the next
  5 s sweep; the counter prompt appears for the barman on the next `rp_bar:duty` push (sent at
  start, on `/service`, and when the client script starts).
