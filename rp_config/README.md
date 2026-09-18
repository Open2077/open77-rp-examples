# rp_config

Central, hot-reloadable settings store for the Night City RP resources. **Server-only**
(no client script). Build `2.31.13+op77.76`.

- `shared/defaults.lua` is the catalogue: every tunable worth centralising (prices, salaries,
  rents, fees, timings, cycles, distances, positions of POIs and zones) of every delivered
  `rp_*` resource, with its **current** value, as dotted keys -- `rp_bank.transferFeePercent`,
  `rp_jobs.salary.ncpd.3`, `rp_zones.kabuki_market.radius`, `rp_trauma.downSeconds`,
  `rp_housing.homes.kabuki_flat.price`, `rp_bank.atms.atm_kabuki.position.x`. 793 keys across
  29 sections after the Night City placement (706 at delivery).
- An **override** is a row of `rp_config_values`. The resource keeps every value in memory:
  `get` is synchronous and never yields, `set` writes through to SQL and announces
  `rp_config:changed`, `reload` re-reads the table without a restart.
- Nothing else was touched: the other resources keep their own `shared/config.lua` and are
  frozen. `tools/migrate-configs.md` says, per resource, which line reads an override.

## Commands

One command, `/config`, registered **restricted**: a player needs the ACL right
`command.config` (or `command.*`) in `acl.jsonc`; the server console always may (answers
go to the log). A refusal reaches the caller through the platform's `open77:command:result`,
not in chat.

| Command | What it does |
|---|---|
| `/config get <key>` | The effective value. A leaf prints `key = value`, or `* key = value (default d) -- by who at unix` when overridden. A branch (`rp_bank.atms.atm_kabuki.position`) prints its JSON and how many leaves are overridden. |
| `/config set <key> <value>` | Sets an override, live at once, persisted, `rp_config:changed` raised. The value is parsed against the default's type: a number, `true/false/on/off/yes/no/1/0`, or free text (spaces kept) for a string. A branch takes `x=381,y=-2401,z=182` (dotted names allowed: `position.x=370`) or a JSON object. |
| `/config unset <key>` | Removes the override (leaf or whole branch): back to the default, row deleted, `rp_config:changed` raised with the default. A key the catalogue no longer knows still gets its stale row purged. `reset` is an alias. |
| `/config list [prefix]` | Every key under the prefix with its effective value, `*` marking overrides, header line first. From chat the listing is capped at `rp_config.chatListMax` (30, itself a tunable); the console prints everything. |
| `/config reload` | Re-reads `rp_config_values` (or the KVP fallback), replaces the cache, announces exactly the keys whose effective value moved, answers `Reloaded from sql: N override(s) live, M value(s) changed.` |
| `/config export` | Prints every override as a Lua block (`RpConfigOverrides = { ["key"] = value, -- by who at unix }`) in chat and in the server log, ready to paste into a config file. |
| `/config help` / `/config` | Usage. |

The command is published as a chat suggestion on `chat:ready` and once at start.

## Exports (server, synchronous, never yield)

```lua
exports.rp_config:get(key, default)   -- override, else catalogue default, else `default`
exports.rp_config:set(key, value)     -- true | nil, reason
exports.rp_config:unset(key)          -- number of live overrides removed | nil, reason
exports.rp_config:reload()            -- true, "scheduled" (SQL) | true, "kvp"
exports.rp_config:all(prefix)         -- { [key] = effectiveValue } for every catalogue key under prefix
```

Call them in `pcall`: a synchronous export raises when the resource is not running. A resource
that ships a `client_script` must not declare `dependency "rp_config"` (a client manifest may
not depend on a server-only resource); rely on the `pcall` and on your own default.

```lua
-- The one-liner every consumer needs (default = your current config value):
local ok, v = pcall(exports.rp_config.get, exports.rp_config, "rp_bank.transferFeePercent", Config.TransferFeePercent)
if ok and v ~= nil then Config.TransferFeePercent = v end
```

- `get(key, default)`: a leaf answers its scalar; a branch key answers the table assembled from
  its leaves (`get("rp_jobs.salary.ncpd")` -> `{ [0]=300, [1]=450, [2]=600, [3]=800 }`,
  `get("rp_ncpd.cell")` -> `{ x, y, z, heading, radius }`); an unknown key answers `default`
  (which may be nil). Never yields, never raises on a bad key.
- `set(key, value)`: validates against the catalogue default -- an integer default only takes
  integral numbers (`not_integer` otherwise), a float default any number, a boolean only a
  boolean, a string only a string of at most 1024 bytes. A branch takes a table whose leaves
  must all exist (`unknown_key:<leaf>`); the check is atomic, nothing is written when one
  leaf is refused. Reasons: `invalid_key`, `unknown_key`, `type_mismatch:number|boolean|string|table`,
  `not_integer`, `string_too_long`, `invalid_value`. `updated_by` is the calling resource
  (`GetInvokingResource()`), or the player's durable identifier from `/config set`.
- `unset(key)`: leaf or branch; announces the default for every removed leaf.
- `reload()`: never yields -- the SQL read lands in a callback, the cache is swapped when it
  answers. `rp_config:reloaded` follows.
- `all(prefix)`: raw string prefix (`"rp_bank."`, `"rp_"`, `""` for everything); only catalogue
  keys, effective values.

## Events (host-wide bus)

| Event | Payload | When |
|---|---|---|
| `rp_config:changed` | `(key, value)` | After every `set` (one per leaf for a branch), every `unset` (value = the default), and for every key whose effective value moved during a load or a `reload`. |
| `rp_config:reloaded` | `(count, source)` | After a load/reload: `count` live overrides, `source` = `"sql"` or `"kvp"`. |

A consumer that reads its config once at start subscribes to `rp_config:changed` and matches
by prefix (`key:sub(1, 8) == "rp_bank."`) to re-apply, or simply re-reads everything on
`rp_config:reloaded`. Keys do not carry the resource's `source`; a listener acting on a
key must not assume who set it.

## Keys

`^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$`, at most 190 bytes, case-sensitive. The first segment is
the resource (`rp_bank`), the rest mirrors that resource's config structure in lowerCamelCase
(`Config.TransferFeePercent` -> `transferFeePercent`); arrays keyed by an id in the source are
keyed by that id here (`rp_shops.shops.pharmacy.prices.maxdoc`), grade ladders by grade
(`rp_jobs.salary.ncpd.3`), zones by name (`rp_zones.afterlife.centre.y`). Only catalogue keys
can be set: adding a key = adding it to `shared/defaults.lua` and restarting `rp_config`.

## Storage

**SQL first.** Inside `Open77.database.ready`:

```sql
CREATE TABLE IF NOT EXISTS `rp_config_values` (
    `key`        VARCHAR(190) NOT NULL,      -- the dotted key
    `value`      TEXT NOT NULL,              -- JSON of the scalar: 2, 1.5, true, "text"
    `updated_at` BIGINT NOT NULL DEFAULT 0,  -- unix seconds
    `updated_by` VARCHAR(128) NOT NULL DEFAULT '',
    PRIMARY KEY (`key`)
)
```

Writes are `INSERT ... ON DUPLICATE KEY UPDATE` (callback form, no yield). A row whose key is
not in the catalogue or whose value no longer fits the default is ignored with a log line and
left in place (`/config unset <key>` purges it). A row edited by hand is picked up by
`/config reload`.

**KVP fallback** only while the database is not ready (`database_connecting`,
`database_unreachable`) or does not exist (`database_unavailable`): overrides go to this
resource's `Open77.kvp` store under `override:<key>` and the log says so. When SQL answers
later, those overrides are migrated into the table (they win over an older row, they were set
later) and removed from KVP.

Log lines (grep `[rp_config]`):

```text
[rp_config] catalogue: 793 key(s) across 29 resource section(s)
[rp_config] schema ready (rp_config_values); 3 override(s) loaded from SQL, 0 migrated from KVP, 0 ignored, 3 value(s) changed
[rp_config] rp_bank.transferFeePercent = 2 (by user-..., sql)
[rp_config] database not ready -- override rp_trauma.downSeconds kept in the KVP fallback until SQL answers
[rp_config] database unavailable (database_unavailable) -- overrides live in this resource's KVP store
[rp_config] ignoring stored override rp_gone.key from sql: unknown_key
[rp_config] reloaded 3 override(s) from SQL, 1 value(s) changed, by console
[rp_config] rp_housing.rent reset to default 500 (by user-...)
```

## Migration (the owner's later pass; nothing here edits another resource)

Every consumer keeps its `shared/config.lua` as the default and reads the override at start
(and, if it wants live changes, on `rp_config:changed`). The exact line per resource, with the
key it reads and the field it feeds, is in **`tools/migrate-configs.md`**; the pattern is
always the same four-line helper once per file, then one line per field:

```lua
local function cfg(key, fallback)
    local ok, v = pcall(exports.rp_config.get, exports.rp_config, key, fallback)
    if ok and v ~= nil then return v end
    return fallback
end
Config.TransferFeePercent = cfg("rp_bank.transferFeePercent", Config.TransferFeePercent)
```

Two resources already read it and need **no change**: `rp_ambiance` (its `Config.overrides`
list: `rp_ambiance.realHoursPerDay`, `.weatherMinMinutes`, `.weatherMaxMinutes`, `.badlands`,
`.noticeIntervalMinutes`, `.figurantsEnabled`, `.musicVolume`, `.alertsEnabled`, re-read by
`/ambiance reload`) and `rp_radio` (`rp_radio.requireItem`, `.badlandsCut`,
`.rememberFrequency`). The catalogue carries those names exactly.

Headline one-liners (the rest is in the sheet):

| Resource | Line (server/main.lua, where the config is first used) |
|---|---|
| rp_bank | `Config.TransferFeePercent = cfg("rp_bank.transferFeePercent", Config.TransferFeePercent)` |
| rp_jobs | `job.salary[g] = cfg(("rp_jobs.salary.%s.%d"):format(job.name, g), job.salary[g])` (in the loop over `RpJobsConfig.Jobs`, g = 0..3) |
| rp_trauma | `Config.downSeconds = cfg("rp_trauma.downSeconds", Config.downSeconds)` |
| rp_housing | `Config.rent = cfg("rp_housing.rent", Config.rent)` |
| rp_zones | `zone.radius = cfg("rp_zones." .. zone.name .. ".radius", zone.radius)` (in the loop over `Config.zones`) |
| rp_economy | `PAYDAY_AMOUNT = cfg("rp_economy.payday.amount", 200)` |
| rp_shops | `entry.price = cfg(("rp_shops.shops.%s.prices.%s"):format(shop.id, entry.id), entry.price)` |
| rp_garage | `Config.impound.fee = cfg("rp_garage.impound.fee", Config.impound.fee)` |
| rp_gangs | `Config.warMinutes = cfg("rp_gangs.warMinutes", Config.warMinutes)` |
| rp_vigile | `VigileConfig.ratePerMinute = cfg("rp_vigile.ratePerMinute", VigileConfig.ratePerMinute)` |

**Positions are read by both runtimes.** A client draws its rings and prompts from the
`shared_script` copy of the config in its own VM, which cannot reach a server export. A
server-side override of a position therefore moves the server's distance check only, until
the resource forwards the value to its clients (`TriggerClientEvent` at `onPlayerReady` and on
`rp_config:changed`). The sheet marks those keys; until that pass, move a POI by editing the
file, and use `rp_config` for what the server alone decides (prices, fees, salaries, rents,
timings, server-checked distances, switches).

## Test in 2 minutes

Grant `command.config` to your principal in `acl.jsonc` (`acl.reload`), or run the same lines
without the slash from the server console. Stand anywhere -- the freeroam spawn
`-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)` is fine, the store has no POI.

1. Server log at start: `[rp_config] catalogue: 793 key(s) across 29 resource section(s)`, then
   `schema ready (rp_config_values); 0 override(s) loaded from SQL ...` (or the
   `database unavailable` line and the KVP fallback on a box without SQL).
2. `/config get rp_bank.transferFeePercent` -> `rp_bank.transferFeePercent = 1`.
3. `/config set rp_bank.transferFeePercent 2` -> `Set * rp_bank.transferFeePercent = 2 (default 1) (was 1). Live now; saved to SQL.`
   The log shows `rp_bank.transferFeePercent = 2 (by <identifier>, sql)`; `SELECT * FROM
   rp_config_values` shows the row with `value = 2`, `updated_by` = your identifier.
4. `/config set rp_bank.transferFeePercent 1.5` -> `Refused: not_integer.`;
   `/config set rp_radio.badlandsCut maybe` -> `Refused: expected true or false.`;
   `/config set rp_nothing.here 1` -> `Refused: unknown key.`
5. `/config set rp_ncpd.cell x=-1755.5,y=-1010.8,z=94.3,heading=90,radius=6` -> `Set rp_ncpd.cell =
   {...}. Live now.`; `/config get rp_ncpd.cell.heading` -> `* rp_ncpd.cell.heading = 90.0 (default 270.0) ...`
6. `/config list rp_trauma` -> a header `28 key(s) under 'rp_trauma', 0 overridden ...` then one
   line per key, in order. `/config list` alone stops after 30 lines and says how many more.
7. `/config export` -> a `RpConfigOverrides = { ... }` block with the two overrides, also in the log.
8. Edit the row by hand (`UPDATE rp_config_values SET value = '3' WHERE `key` =
   'rp_bank.transferFeePercent'`), then `/config reload` -> `Re-reading rp_config_values...`
   then `Reloaded from sql: 6 override(s) live, 1 value(s) changed.`; `/config get` shows 3.
9. `/config unset rp_ncpd.cell` -> `5 override(s) removed under rp_ncpd.cell, back to the
   defaults.`; the rows are gone.
10. From any server resource: `print(exports.rp_config:get("rp_bank.transferFeePercent"))` -> 3;
    `AddEventHandler("rp_config:changed", print)` then `/config set rp_bank.transferFeePercent 4`
    prints `rp_config:changed rp_bank.transferFeePercent 4`.
11. Restart the server: the overrides come back from SQL (`3 override(s) loaded from SQL`).

## Limits and notes

- The catalogue is data: `RpConfigDefaults` is never rewritten; `/config export` is the way to
  turn overrides back into a file.
- An override set before the database answered is served from memory immediately and lands in
  SQL when the connection comes; a server that is hard-killed in that window keeps it in KVP.
- Values are scalars; a branch is only sugar over its leaves. Lists whose length would change
  (a shop's catalogue, a zone's polygon) are not tunables here: change those in the file.
- Secrets never belong in the catalogue (the `rp_logs` webhook URL stays in the server convars).
- `rp_mdt` and `rp_crime`, written in parallel, are not in the catalogue yet: add their
  sections to `shared/defaults.lua` once their configs are frozen. `rp_crime` already reads
  `rp_crime.<path>` through its own `tunable()` helper (19 keys, listed in the sheet): until
  its section exists those reads answer `unknown key` and the file value stands.
- The catalogue was re-synced on 2026-09-18 after the move from the eval plateau to the real
  Night City map: every position, zone name (`kabuki_market`, `kabuki`, `afterlife`, `lizzies`,
  `h10`, `viktor_clinic`, `ncpd_hq`, `junkyard`, `nomad_camp`, `westbrook_dealer`, `badlands`),
  ATM id and home price now mirrors the resources' current `shared/config.lua`; `rp_housing`
  homes lost their `entrance` keys (the front door is found at runtime, see the sheet).
