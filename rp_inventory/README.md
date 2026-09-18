# rp_inventory

The pockets of a Night City RP server. Server-authoritative: items live in the
server's memory for every connected player, every change is written straight
through to SQL (`rp_inventory_items`, `rp_inventory_stashes`) or, when the
server has no database, to the resource's `Open77.kvp` store. Clients only
render and request.

- Max carry weight: **40 kg** (`RpInventoryConfig.maxCarryWeight`).
- Items: `shared/items.lua` (`id, label, weight, usable, illegal, effect`).
- The pockets panel: a WebUI page shipped by this resource (`web/index.html`),
  opened by `/inv`, fed by the server (`rp_inventory:panel`) and driving it with
  intents (`rp_inventory:intent`); a chat listing replaces it when the client
  has no WebUI. Stashes (`openStash`) are the same panel with a second column.
- Player-to-player actions: ALT+click a player (`open77_contextmenu`),
  slash commands as the fallback.
- Ground drops: the loot API (`Open77.loot.*`), picked up with the game's own
  prompt or `/ramasser`.

## Commands

| Command | What it does |
|---|---|
| `/inv` | Opens the **POCKETS** panel: your RP name, the weight bar (`9.0 / 40 kg`), a tile per item (label, count, weight, category glyph, illegal items in red) and, for the selected tile, **Use / Give / Drop** with a count field. Escape or the `x` closes it. Falls back to a chat listing when the client has no WebUI (`Panel unavailable (webui_unavailable); listed in chat.`). |
| `/use <item>` | Uses one unit. A 3 s progress bar (cancellable), then the effect. |
| `/drop <item> [n]` | Removes `n` (default 1) from the pockets and creates a pickable ground drop at the player's feet (30 min TTL). |
| `/ramasser` | Picks up the nearest `rp_inventory` drop within 3 m, for when the native prompt is not convenient. |
| `/give <playerId> <item> [n]` | Hands items to a player within 3 m; the server checks the distance and the receiver's carry weight. ALT+click > **Give item** opens the same thing as a dialog. |
| `/fouiller <playerId>` | Searches a player who is **held by the RP kit** (`open77_rp_basics`) **or has hands up** (`handsup` RP profile). Lists their pockets and names the contraband. ALT+click > **Search pockets** does the same. |
| `/saisir <playerId> <item>` | Seizes every unit of an **illegal** item from a searched player. `implant_box` counts as legal for a `medecin` (rp_jobs). |
| `/giveitem <playerId> <item> [n]` | Admin/console (ACL `command.giveitem`): puts items into a player's pockets. Works from the server console. |

`<item>` accepts the id (`burrito`), the label (`Burrito`) or an unambiguous
prefix (`bur`).

### The panel

`/inv` opens `web/index.html` (created hidden by `client/main.lua` at start,
shown with keyboard + cursor focus, hidden again on Escape / the `x`). The page
is presentation only: the **server owns the panel** and pushes its whole state
through `rp_inventory:panel` when it opens and after **every** change of the
pockets or of the open stash, whoever caused it (a command, the page, another
resource through `add` / `remove`, another player storing into the same stash).
The `I` key is not bound (the game uses it).

State payload (`rp_inventory:panel`, server -> client -> page `state` event):

```lua
{
  open = true, playerId = 3, name = "Vincent Marino",       -- rp_identity fullName, else the account name
  pockets = { id = 3, entries = { ... }, weight = 9.0, capacity = 40 },
  stash   = { id = "home:12", entries = { ... }, weight = 12.5, capacity = 200 },  -- only while a stash is open
  nearest = { playerId = 4, name = "Jackie Welles", distance = 1.2 },            -- the Give target, or nil
  notice  = { ok = true, text = "Used Burrito." },                              -- the answer to the last intent, or nil
}
-- entries: { id, label, count, weight, total, usable, illegal, category } sorted by label
-- category (tile glyph only): heal food drink fuel smoke drug stamina tech tool material cargo misc
{ open = false }   -- closes the panel
```

Intents (page `intent` event -> client -> `rp_inventory:intent` -> server). Every
one lands in the function the matching command uses, is re-validated there and is
followed by a state push carrying the `notice`:

| intent | payload | server path |
|---|---|---|
| `use` | `{ item }` | `/use`: 3 s progress bar, effect, one unit debited |
| `drop` | `{ item, count }` | `/drop`: ground drop at the feet, 30 min |
| `give` | `{ item, count }` | `/give` to the **nearest other player within 3 m** (`Open77.players.closest`), same distance / weight checks |
| `store` | `{ item, count }` | pockets -> open stash (capacity checked, rollback on failure) |
| `take` | `{ item, count }` | open stash -> pockets (carry weight checked, rollback on failure) |
| `refresh` | | a fresh state, nothing moved |
| `close` | | the server forgets the panel (Escape, the `x`, a client restart) |
| `unavailable` | `{ reason }` | sent by the client when `Open77.webui.create` failed: the pockets (and the stash) are listed in chat instead |

Money is not an item and never appears on the panel (`rp_economy` owns it).

### Items

| id | label | kg | usable | effect |
|---|---|---|---|---|
| `water` | Bottle of water | 0.5 | yes | `rp_needs:consume` (thirst) |
| `burrito` | Burrito | 0.4 | yes | `rp_needs:consume` (hunger) |
| `nicola` | NiCola | 0.4 | yes | `rp_needs:consume` (thirst) |
| `chooh2` | CHOOH2 fuel can | 5.0 | yes | `open77_fuel:refuel(vehicle, 20)` on the vehicle the player sits in |
| `bandage` | Bandage | 0.2 | yes | `Open77.players.heal` +25 |
| `maxdoc` | MaxDoc Mk.1 | 0.3 | yes | heal +60 |
| `bounceback` | Bounce Back Mk.1 | 0.3 | yes | heal +40 and full stamina |
| `phone` | Holophone | 0.3 | no | |
| `radio` | Radio | 0.8 | no | |
| `lockpick` | Lockpick | 0.1 | no | |
| `scrap` | Scrap | 1.0 | no | |
| `component` | Component | 0.5 | no | |
| `chip` | Data chip | 0.05 | no | |
| `cigarettes` | Pack of cigarettes | 0.1 | yes | flavour |
| `synthcoke` | Synthcoke | 0.1 | yes | **illegal**; full stamina |
| `implant_box` | Implant box | 2.0 | no | **illegal** unless the holder has the `medecin` job |
| `crate` | Cargo crate | 25.0 | no | heavy cargo |

A heal is refused at full health, food and drink are refused when `rp_needs`
says so (`nil, reason`), and the fuel can is refused outside a vehicle or when
no fuel system runs. In every case the item stays in the pockets and the
player is told why.

## Exports (server)

Phase 1 contract, all synchronous-safe (nothing yields), so both spellings work:

```lua
exports.rp_inventory:add(playerId, "burrito", 2)             -- true | nil, reason
local ok = exports.rp_inventory:remove(playerId, "burrito", 1) -- true | nil, "not_enough" | reason
exports.rp_inventory:has(playerId, "chooh2", 1)              -- boolean
exports.rp_inventory:count(playerId, "scrap")                -- number
local entries, weight, capacity = exports.rp_inventory:list(playerId)
-- entries = { { id, label, count, weight, total, usable, illegal }, ... } sorted by label
exports.rp_inventory:openStash(playerId, "house_12", 200)    -- true (panel scheduled) | nil, reason
```

Reasons: `invalid_player`, `player_not_found`, `not_loaded` (the pockets are
still being read), `unknown_item`, `invalid_count`, `too_heavy`, `not_enough`,
`invalid_stash`, `invalid_capacity`.

`openStash(playerId, stashId, capacity)` opens the panel in its two-column
form (**POCKETS | STASH `<stashId>`** with the stash capacity, **Store** on a
pocket tile, **Take** on a stash tile, both with a count) on the given player;
`capacity` is in kg (default 100). The stash is loaded from
`rp_inventory_stashes` on first use and every move is persisted. Housing and
vehicle trunks call this with their own stash ids (`home:12`). `/inv` while a
stash is open goes back to the pockets-only panel.

`define(items) -> registered, rejected` lets another resource declare its own
items in the `shared/items.lua` shape (`id = { label, weight, usable, illegal,
effect?, permit? }`, ids `^[a-z0-9_]+$`, label up to 48 chars, weight 0..100 kg).
An item defined this way owns its effect: `/use` only debits one unit and raises
`rp_inventory:used (playerId, itemId)` for the definer to act on; an
`effect = { needs = { thirst = 25 }, text = "Cold and bitter. Good." }` is applied here through
`rp_needs:apply` before the event. Call it from your `onResourceStart` and again whenever `rp_inventory` restarts
(its VM comes back with the built-in table only; rows of an undefined id stay in
SQL and reappear once the id is defined again and the player reconnects):

```lua
local MY_ITEMS = { crowbar = { label = "Crowbar", weight = 1.5, usable = false, illegal = false } }
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() or name == "rp_inventory" then
        pcall(function() exports.rp_inventory:define(MY_ITEMS) end)
    end
end)
```

## Events (host-wide bus)

```lua
AddEventHandler("rp_inventory:changed", function(playerId, itemId, delta) end) -- every credit/debit
AddEventHandler("rp_inventory:used", function(playerId, itemId) end)           -- after a successful /use
```

Client -> server requests (internal): `rp_inventory:giveMenu(targetPlayerId)`,
`rp_inventory:search(targetPlayerId)`, raised by the ALT+click actions;
`rp_inventory:intent(payload)` from the panel. Server -> client:
`rp_inventory:panel(state)` (see *The panel*).

## Logs

Every change is one grep-able line:

```
[rp_inventory] player 3 +2 burrito total=2 (export add)
[rp_inventory] player 3 -1 burrito total=1 (used)
[rp_inventory] player 3 -1 crate total=0 (dropped as loot 17)
[rp_inventory] player 4 +1 crate total=1 (picked up loot 17)
[rp_inventory] stash house_12 +3 scrap total=3 by player 3
[rp_inventory] player 5 searched player 3
```

## Persistence

```sql
rp_inventory_items   (identifier VARCHAR(64), item_id VARCHAR(32), count INT, PRIMARY KEY (identifier, item_id))
rp_inventory_stashes (stash_id   VARCHAR(64), item_id VARCHAR(32), count INT, PRIMARY KEY (stash_id, item_id))
```

Both tables are created inside `Open77.database.ready` with
`CREATE TABLE IF NOT EXISTS`. Rows are keyed by `Open77.players.identifier`,
never the session id. A player's pockets are read on `onPlayerReady` (the
resource waits up to 10 s for a database that is still connecting) and on a hot
reload for everyone already connected; nothing is written at disconnect because
every change was already written. When the server has **no** database
(`database_unavailable`) the kvp store is used instead and the log says so
(`loaded from kvp: database not ready (...)`). A failed SQL read never marks the
pockets loaded: the player is told to reconnect rather than risk a later write
erasing real rows.

## Ground drops

A drop is an `Open77.loot.create` with the documented `Items.money` /
`Items.MoneyShard` pair (the only record pair the devkit guarantees), the RP
label, and a 30 min TTL. The resource keeps `lootId -> { itemId, count }`, so
`onLootPickup` credits the real RP item, not eddies. A picker who cannot carry
it gets the drop re-created at their feet and a message. Per item,
`record` / `visual` in `shared/items.lua` override the TweakDB records once
verified on your build.

## Manifest permissions

`network.events` (events), `database.access` (SQL), `world.loot` (drops),
`world.vehicles` (the seat read for the fuel can), `players.stats.read` /
`players.stats.apply` (heals), `players.animations.read` (hands-up check).
`web_files { "web/**" }` ships the panel page; `Open77.webui.create` needs no
permission (same lines as `rp_mdt`). Dependencies: `open77_uikit` (the /use
progress bar and the ALT+click Give dialog), `open77_contextmenu`, `open77_loot`
(all ship a client half). `rp_needs`, `open77_fuel`, `open77_rp_basics` and `rp_jobs` are
reached through exports inside `pcall` and are optional at runtime.

## Test in 2 minutes

1. Start the server with `rp_inventory`, `open77_uikit`, `open77_contextmenu`
   and `open77_loot` in the load list; connect two players (ids 1 and 2). The
   client log says nothing about the page unless it failed
   (`[rp_inventory] webui unavailable: <reason>`).
2. From the server console: `giveitem 1 burrito 3`, `giveitem 1 maxdoc 1`,
   `giveitem 1 synthcoke 2`, `giveitem 1 crate 1`. Player 1 sees the toasts in
   chat; the log shows `player 1 +3 burrito total=3 (giveitem by 0)`.
3. Player 1: `/inv`. The POCKETS panel opens with the player's name top right,
   the header bar reading `27.6 / 40 kg` (69%, cyan), four tiles: `Burrito x3`,
   `Cargo crate x1`, `MaxDoc Mk.1 x1` and `Synthcoke x2` tinted red with an
   `ILLEGAL` tag. Click **Burrito**: the right column shows `x3`, `0.4 kg`,
   `1.2 kg`, a count field and **Use / Give / Drop** (Give reads `nobody within
   3 m` and is greyed while alone). **Use**: the button reads `Working...`, a
   3 s bar, chat `You eat the burrito. Better.` (or the `rp_needs` answer), then
   the tile reads `x2`, the bar `27.2 / 40 kg` and a toast `Used Burrito.`
   Escape (or the `x`) closes the panel and gives the game its keys back;
   `/inv` reopens it. Log: `player 1 -1 burrito total=2 (used)`.
4. Player 1: `/use maxdoc` at full health: `You are already at full health.`
   Take some damage, use it again: `+60 health`.
5. Player 1: `/drop crate`. A drop appears at the feet; the console
   `giveitem 1 crate 1` again shows `too heavy` only once the pockets exceed
   40 kg. Player 2 walks over and uses the native **Take** prompt, or
   `/ramasser`: `Picked up Cargo crate x1`, log `player 2 +1 crate ... (picked up loot N)`.
6. Player 1 stands next to player 2, `/inv`, click **Burrito**: the Give
   button now reads `to <player 2's name> (1.x m)`. Count `1`, **Give**: chat
   `You hand Burrito x1 to <name>.` on 1, `<name> hands you Burrito x1.` on 2,
   toast `Handed Burrito x1 to <name>.`, the tile drops to `x1`; player 2's own
   open panel (if any) refreshes at once. ALT+click player 2 > **Give item**
   still opens the targeted dialog. Walk 5 m away and `/give 2 burrito`:
   `Get closer. Three metres, arm's length.` From the panel at that distance the
   Give button is greyed (`nobody within 3 m`).
7. Player 2 raises hands (`handsup` RP profile) or is cuffed by an officer with
   the RP kit. Player 1: `/fouiller 2` lists player 2's pockets and names
   `synthcoke` as contraband; `/saisir 2 synthcoke` moves both units. Without
   hands up: `They are neither cuffed nor surrendering.`
8. Reconnect player 1: the pockets come back from SQL (`loaded from sql`).
9. From another resource (rp_housing does it from its home prompt):
   `exports.rp_inventory:openStash(1, "test_stash", 50)`. The panel opens with
   two columns, **POCKETS | STASH `test_stash`** `0.0 / 50 kg`. Click a pocket
   tile: **Store** (`into test_stash`) joins the actions; store two burritos:
   toast `Stored Burrito x2.`, chat the same, the tile moves to the stash
   column, log `stash test_stash +2 burrito total=2 by player 1`. Click the
   stash tile: **Take** brings it back. Escape, reopen: still there
   (`rp_inventory_stashes`). Storing the crate into a 50 kg stash that already
   holds 26 kg: `The stash is full.`
10. Client without a WebUI (or `Open77.webui.create` refused): `/inv` answers
    in chat `Pockets - 27.6 / 40 kg`, the listing, then
    `Panel unavailable (webui_unavailable); listed in chat. Commands: /use /drop /give.`
