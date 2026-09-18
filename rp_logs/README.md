# rp_logs — audit trail

Server-only resource. It listens to every `rp_*` event the Night City RP stack raises,
plus the platform lifecycle (join, leave, death, admin acts, resource start/stop), turns
each one into a row of `rp_logs_events`, keeps the newest 500 rows in memory for the
synchronous `query` export, and mirrors the sensitive kinds to a Discord webhook.

It declares **no dependency** on purpose: an audit trail must keep running when any other
resource stops. The two cross-resource lookups it makes (`rp_identity:fullName` for the
Discord name, `rp_needs:get` for the threshold sampler) are wrapped in `pcall` and are
optional.

Build: written for and validated against `2.31.13+op77.76`.

## Commands

All sub-commands live under one restricted command, `/logs` (ACL entry `command.logs`;
the server console and Warden always may — the console answers with `print`).

| Command | What it does |
|---|---|
| `/logs` | The last 10 events, oldest first, one chat line each (`#id HH:MM:SS kind [player] text`). From SQL when the database is ready (pending rows are flushed first), else from the memory cache. |
| `/logs <n>` | The last `n` events (1..50). |
| `/logs <kind> [n]` | Events whose kind contains `<kind>`: `/logs bank`, `/logs ncpd 20`, `/logs admin`, `/logs player:death`. |
| `/logs stats` | Row counters, database state, webhook state and queue, and the counted-only events (zones entered/left per zone, SMS count). |
| `/logs test [text]` | Writes a `rp_logs:test` row and, since that kind is sensitive, queues a Discord embed. The one-player way to prove the webhook. |
| `/logs webhook <url>` | Stores the Discord webhook URL (validated: `https://discord.com/api/webhooks/<id>/<token>`). Only the webhook id is ever echoed back. |
| `/logs webhook off` | Clears it. |
| `/logs webhook status` (or `/logs webhook`) | Configured / off / disabled, and why. |
| `/logs help` | The list above. |

Player-facing text is English. `/logs` from a player without `command.logs` is refused by
the platform before the handler runs.

## Exports

Both are **synchronous** server exports (`exports.rp_logs:log(...)`, called inside `pcall`
because a missing resource raises). Neither yields.

### `log(kind, text, data) -> true | nil, reason`

Writes one row. `kind` matches `^[A-Za-z0-9_:.-]+$` (48 chars max); a kind without `:` is
prefixed by the calling resource (`exports.rp_logs:log("lookup", ...)` from `rp_mdt` becomes
`rp_mdt:lookup`). `text` is cut to 512 bytes. `data` is an optional plain table stored as JSON
(2 KB max — a larger payload is replaced by `{"truncated":true,"bytes":N}`); two of its keys
are also lifted into columns: `data.playerId` (resolved to the durable identifier and the
display name) or `data.identifier`. The caller's name is added as `data.source`.
Reasons: `invalid_kind`, `invalid_text`, `invalid_data`.

```lua
pcall(function()
    exports.rp_logs:log("lookup", ("looked up %s"):format(plate), { playerId = source, plate = plate })
end)
```

### `query({ kind=, identifier=, playerId=, since=, limit= }) -> rows`

Answers from the **in-memory cache only** (the newest 500 rows), newest first, so it never
yields and is safe to call from another synchronous export. Filters: `kind` (exact or
substring), `identifier` (exact) or `playerId` (resolved to its identifier; an unknown player
answers `{}`), `since` (unix seconds, inclusive), `limit` (default 50, max 500). Each row is
`{ id, seq, at, kind, identifier, player_name, text, data }` — `id` is the SQL id once the
batch reached the database (`nil` for a row still in flight), `seq` a local counter.

SQL history beyond the cache is the `/logs` command (it may yield; an export may not).

## Events consumed

Every subscription uses `AddEventHandler` on the host-wide bus. Payloads follow the
delivered contracts; an event whose payload is not in the contract is captured generically
(all arguments rendered in the text and stored in `data.args`; the first argument that
resolves to a connected player becomes the row's player).

| Event | Row kind | Stored as |
|---|---|---|
| `rp_economy:changed (playerId, newBalance, delta, reason)` | same | `cash +200 €$ (payday), now 1200 €$` |
| `rp_bank:changed (playerId\|nil, identifier, newBalance, delta, kind)` | same | `bank +100 €$ (deposit), now 350 €$` |
| `rp_jobs:changed (playerId, name\|nil)` / `rp_jobs:duty (playerId, name, onDuty)` | same | `job set to ncpd` / `ncpd duty on` |
| `rp_inventory:changed (playerId, itemId, delta)` / `rp_inventory:used (playerId, itemId)` | same | `inventory water -1` / `used water` |
| `rp_identity:changed (playerId)` | same | `identity updated: V Vega` |
| `rp_needs:changed` | same, **sampled** | only when hunger/thirst/fatigue crosses 25 or 0 in either direction (`needs: thirst ok -> low (22)`); values come from the event payload when it carries the needs table, else from `rp_needs:get` |
| `rp_zones:entered/left` | **not stored**, counted | per zone in `/logs stats` |
| `rp_ncpd:alert (kind, position, text, byPlayerId)` | same | `NCPD alert [robbery] ...` |
| `rp_ncpd:arrest` (payload not in the contract) | same, **Discord** | generic capture |
| `rp_trauma:down (playerId, position)` / `rp_trauma:revived` | same | `went down, Trauma Team paged` / generic |
| `rp_delamain:ride`, `rp_mecano:bill`, `rp_mecano:impounded`, `rp_vigile:contract` | same | generic capture |
| `rp_fixer:gig (gigId, phase, playerId)` | same | `gig 12 delivered` |
| `rp_netrunner:jammed (boolean)` | same | `NET jammed by a netrunner` |
| `rp_garage:changed (identifier, plate, action)` / `rp_garage:stolen (plate, byPlayerId)` | same | `vehicle NC-1234 stored` / `vehicle NC-1234 stolen` |
| `rp_shops:sale (shopId, playerId, itemId, count, price)` / `rp_shops:robbed (shopId, byPlayerId, amount)` | same | `bought 2 x water at kiosk_1 for 20 €$` |
| `rp_housing:changed (identifier, homeId, action)` | same | `home h12 rented` |
| `rp_gangs:changed (playerId, gang\|nil)` / `rp_gangs:war (zone, attacker, defender, phase)` | same, war is **Discord** | `gang war in scrapyard: maelstrom vs valentinos (started)` |
| `rp_crime:robbery (kind, position, byPlayerId)` | same, **Discord** | `robbery: shop` |
| `rp_admin:action (adminId, action, targetId, text)` | same, **Discord** | `warn -> Jackie: no RDM` |
| `rp_phone:sms` | **not stored**, counted | count only, the text is never read |
| `onPlayerReady` / `onPlayerDisconnected` | `player:join` / `player:leave` | `V joined Night City` / `left (connection_closed)` |
| `onPlayerLifeStateChanged` phase `dead` | `player:death` | `flatlined (<cause>, <weapon>)`; the connect-time dead phase (`registered`, `restored`, `resync_requested`) and the admin tp/goto kill (`weapon = open77_admin:*`) are ignored |
| `open77:admin:playerBanned/Kicked/Warned/announcement` | `admin:ban` (**Discord**), `admin:kick` (**Discord**), `admin:warn`, `admin:announce` | `banned by warden (7d)` |
| `onResourceStart` / `onResourceStop` (other resources) | `resource:start` / `resource:stop` | `rp_bank stopped (reload)` |
| own start/stop, `open77:admin:serverShuttingDown` | `rp_logs:start` / `rp_logs:stop` / `server:shutdown` | pending rows are flushed on stop |

The sensitive set is `RpLogsConfig.sensitiveKinds` in `shared/config.lua`.

rp_logs raises no event of its own.

## SQL

Created inside `Open77.database.ready(...)`:

```sql
CREATE TABLE IF NOT EXISTS rp_logs_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    at BIGINT NOT NULL,              -- unix seconds (UTC)
    kind VARCHAR(48) NOT NULL,
    identifier VARCHAR(64) NULL,     -- Open77.players.identifier, never the session id
    player_name VARCHAR(64) NULL,
    text VARCHAR(512) NOT NULL,
    data JSON NULL,                  -- <= 2 KB
    PRIMARY KEY (id),
    KEY idx_kind_at (kind, at),
    KEY idx_identifier_at (identifier, at)
)
```

Rows are written with the **callback form** of `Open77.database.insert`, batched: a flush
every 2 s or as soon as 10 rows wait (the bridge refuses more than 64 positional parameters per
statement), one multi-row `INSERT` per batch. A failed batch is
retried twice and then dropped with an `ERR` line. On start the newest 500 rows are read back
into the cache so `query` is useful right after a restart.

**No database** (`database_unavailable`): rows stay in the memory cache, the newest 100 are
mirrored into `Open77.kvp` (`rp_logs:fallback`, under the resource's own `data/` directory)
so a short trail survives a restart, and a `WRN` line says so. A database that is merely
still connecting keeps up to 2000 rows waiting and flushes them when it answers.

## Discord webhook

Sensitive kinds are POSTed as embeds (title = kind, description = text, fields = RP name
from `rp_identity`, identifier, UTC time), **at most one per second** (queue of 100, oldest
dropped; a 429 pauses the queue for 5 s).

**The URL is never in the resource.** On op77.76 there is no `Open77.env`, no `Open77.config`
and no `resources.settings` block; what exists is `GetConvar` (server.jsonc `convars` block,
then the calling resource's own tunables by exact key) and `Open77.tunables` (typed,
persisted by the host in `tunables.json` next to `server.jsonc`, editable live from the
Warden panel). rp_logs declares the string tunable `rp_logs_webhook` and reads
`GetConvar("rp_logs_webhook", "")`, so the URL can come from either place, in this order:

1. `server.jsonc` → `"convars": { "rp_logs_webhook": "https://discord.com/api/webhooks/..." }`.
   The platform documents this block as tracked and credential-free, so use it only if your
   `server.jsonc` is not committed.
2. The tunable `rp_logs_webhook`: set it from the Warden panel (group "Discord"), or in game
   with `/logs webhook <url>` (restricted). The host persists it in **`tunables.json` next to
   `server.jsonc` — do not commit that file.** A convar, when present, overrides the tunable;
   `/logs webhook` tells you when that happens.

Outbound HTTP must be enabled and `discord.com` allow-listed, or the webhook disables itself
with an `ERR` line (`http_unavailable` / `host_not_allowed`) until the URL is set again:

```jsonc
// server.jsonc
"http": { "enabled": true, "allowedHosts": ["discord.com"] }
```

Only the webhook id (never the token) is echoed to chat or the log. `/logs webhook off`
clears the tunable. Note that a URL typed in chat stays in that client's own chat history:
prefer the Warden panel on a shared screen.

## Files

- `open77.lua` — manifest; permissions `database.access`, `http.request`,
  `players.life.read`, `network.events`.
- `shared/config.lua` — every tunable of the resource (batch sizes, cache size, sensitive
  kinds, embed colours, counted-only events, thresholds). Loaded as a server script: rp_logs
  ships nothing to clients.
- `server/main.lua` — the resource.

## Test in 2 minutes (freeroam spawn Kabuki Market `-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`)

You need `command.logs` in the ACL (or run the `logs` lines from the server console, which
always may). One player is enough for everything except the arrest.

1. Connect. In chat, `/logs` → a `player:join` row for you and `rp_logs:start`.
2. Deposit at the ATM ring 3 m east of Kabuki Market Centre (`atm_kabuki`): `/bank deposit 100` (rp_bank; use its deposit
   sub-command if the syntax differs) → `rp_bank:changed` (+ `rp_economy:changed` for the
   cash side). Check with `/logs bank`.
3. Duty: an admin gives you a job (`/setjob <yourId> ncpd 1`, rp_jobs) → `rp_jobs:changed`;
   then `/service` → `rp_jobs:duty` (`ncpd duty on`).
4. Inventory: `/giveitem <yourId> water 1` (rp_inventory, admin) → `rp_inventory:changed`;
   `/use water` → `rp_inventory:used` (+ `rp_needs:changed` only if thirst crosses 25 or 0 —
   force it with rp_needs' `setneeds` command: set thirst to 20 then back to 80 → two rows).
5. Death: `/suicide` (freeroam) → `player:death`; `/revive` to get up. An admin `/goto` or
   `/tp` does **not** produce a death row.
6. Webhook: set it once (`/logs webhook https://discord.com/api/webhooks/...` or the Warden
   panel), then `/logs test hello choom` → a `rp_logs:test` row **and** an embed in the
   channel within a few seconds. `/logs webhook status` shows the queue and any refusal.
7. Sensitive kinds from the delivered commands: `/warn <id> <reason>` (rp_admin) →
   `rp_admin:action` → Discord; a Warden kick → `admin:kick` → Discord; `/braquer` at a shop
   (rp_crime) → `rp_crime:robbery` → Discord, and its NCPD page → `rp_ncpd:alert`;
   `/embarquer <id>` by an on-duty officer on a cuffed player (two players) → `rp_ncpd:arrest`
   → Discord. There is no console `TriggerEvent`, so `rp_ncpd:alert` cannot be raised from
   the console: `/logs test` is the one-player path to the webhook.
8. Zones: walk 70 m off the market (`kabuki_market`, radius 70 — past the South Gate alley at
   `-1218, 1950`) and back → nothing stored, but `/logs stats` shows `kabuki_market 1/1`.
9. `/logs 10`, `/logs stats`, `/logs admin 5`.

## Limits and assumptions

- `rp_ncpd:arrest`, `rp_trauma:revived`, `rp_delamain:ride`, `rp_mecano:bill/impounded` and
  `rp_vigile:contract` have no documented payload: their rows are the generic capture. If one
  of them puts an amount before the player id and that number happens to be a connected
  session id, the row names the wrong player — edit its descriptor in `server/main.lua` once
  the payload is known.
- The life snapshot's field names for the killing blow (`cause`, `weapon`, `killer`) are
  read defensively; a build that spells them differently still writes the death row, with the
  transition `reason` only.
- The SQL `id` of a cached row is derived from the first auto-increment id the multi-row
  `INSERT` answers (consecutive ids per statement) — right on MariaDB/MySQL defaults.
- A resource that publishes an event with more than 32 arguments, or with a table the
  marshaller refuses, is not seen at all (bus limits).
