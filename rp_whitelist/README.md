# rp_whitelist - the door of Night City

Connection control for the RP server: a **whitelist** (strict allowlist, or a **priority
queue** that lets listed players in first when the city is full), **temporary RP bans**
with the reason and the time left on the refused player's screen, and the `/wl` admin
command that works from the server console as well as from the game.

Everything is decided server-side in `onPlayerConnecting` through the host's deferrals.
The lists live in SQL (`rp_whitelist_entries`, `rp_whitelist_bans`) and are mirrored in
memory, so the exports never yield; when no database answers, the resource falls back to
its own `Open77.kvp` store and says so in the log.

**The eval configuration ships with the whitelist OFF** (`Config.enabled = false`) so the
test bot and the owner keep connecting. Bans are enforced regardless (`Config.bansWhenDisabled`).

## Files

| File | Runtime | Role |
|---|---|---|
| `open77.lua` | manifest | dependencies, permissions, scripts |
| `shared/config.lua` | server (loaded as a `server_script`: nothing reaches a client) | every operator setting and every sentence a refused player reads |
| `server/main.lua` | server | gate, queue, lists, storage, `/wl`, exports, events |

Dependencies declared: `rp_identity` (RP name in listings and as the default note),
`rp_logs` (audit lines). Both are called through `pcall` and are optional at runtime, but a
**declared dependency must be in the load list or this resource never starts** - and a gate
that does not start lets everyone in. If `rp_logs` is not deployed yet, comment its
`dependency` line out.

Permissions: `players.gate` (the connect gate), `database.access`, `network.events`
(`chat:ready` for the `/wl` suggestion only).

## Who may run `/wl`

The command is registered restricted: a player needs the ACL right `command.wl`
(`acl.jsonc`, or `command.*`); the server console and Warden's console always may. From the
console the answer is printed in the log; from the game it comes back in chat as `GATE`.

## Commands

| Command | Does |
|---|---|
| `/wl ajouter <identifier\|playerId> [note...]` | Adds (or updates) an entry. With a session id the identifier is resolved from the online player and, without a note, the note becomes their RP name (`rp_identity`), else their account name. The player is told in chat. |
| `/wl retirer <identifier\|playerId>` | Removes the entry. A running session is not touched: the next connect is refused (allowlist mode). |
| `/wl liste` | Every entry: identifier, note, who added it, how long ago, and `online as <RP name> [id]` when the identity is in. Chat shows 30, the console shows all. |
| `/wl ban <identifier\|playerId> <minutes> <reason...>` | Temporary RP ban; `0` minutes = permanent. **The player is NOT kicked**: they may finish the session (they read the ban sentence in chat), and every connect until the ban expires is refused with the reason and the time left. Use the platform `/kick` to remove them now. |
| `/wl unban <identifier\|playerId>` | Lifts a ban. |
| `/wl statut` | State (enabled / mode / storage), counts, soft cap and online count, the queue with positions, the active bans with time left, and the last refusals the host reported (`onPlayerRejected`). |
| `/wl activer` / `/wl desactiver` | Flips the whitelist at runtime. Persisted in this resource's KVP store (`enabled`), so it survives a restart and overrides `Config.enabled`. Enabling does not kick anyone; the next connects are checked. |
| `/wl` | Usage. |

Identifiers are the durable `userId` (`Open77.players.identifier`), the same key
`rp_identity` uses. A player reads their own with `identity.dump` in the client console;
an admin reads it from `/wl liste`, `/wl statut` (refusals) or the server log line
`Player '<name>' (<userId>) refused (...)`.

## How the gate decides (in this order)

1. **Storage not loaded yet** (first seconds after a start): the player is held up to
   `Config.loadWaitSeconds` (5 s). Still not loaded: refused with `Config.errorText` when
   the whitelist is enabled and `Config.failClosed` is true, admitted unchecked otherwise
   (a warning is logged either way).
2. **Ban**: an active ban refuses with `Config.banText` - `Banned from Night City for 42 min:
   <reason>` (or `permanently`). An expired ban is dropped on sight and never refuses.
   Bans apply even while the whitelist is disabled unless `Config.bansWhenDisabled = false`.
3. **Whitelist disabled**: admitted.
4. **Mode `allowlist`**: an identity that is not listed is refused with `Config.refusalText`
   (`This server is whitelisted. Apply on the Discord: <Config.discordLink>`).
   **Mode `queue`**: unlisted identities may connect, but listed ones go first when the
   city is full (next step).
5. **Capacity** (`Config.maxPlayers`, or the convar `Config.maxPlayersConvar` when set;
   `0` = no soft cap, queue off): the player enters the priority queue - listed players
   first, then by first knock - and is held while a slot is awaited (see the limits below).
   Position <= free slots: admitted, and the slot is counted as taken until the player shows
   up in `onPlayerConnected` (or `Config.queue.reserveSeconds`). Otherwise, at the end of the
   hold: refused with `Config.fullText` - `Night City is full (32/32). Queue #2 - reconnect
   to keep your place.` The position is kept for `Config.queue.ttlSeconds` (120 s) and the
   same identity reconnecting keeps it.

A handler error is caught (`pcall`): refused with `Config.errorText` when the whitelist is
enabled and `Config.failClosed` is true, admitted otherwise - the host's own default on a
crashed handler is to admit, this resource chooses to fail closed once armed.

## Limits - read before relying on the queue

These are facts of the platform, measured through the devkit for build 2.31.13+op77.76,
not design choices:

- **The host's own capacity check runs before the resource gate.** A player who arrives
  when `network.maximumPlayers` sessions are in is refused `server_full` and this resource
  never sees them. The queue therefore only works with `Config.maxPlayers` **strictly
  below** `network.maximumPlayers` in `server.jsonc`: the difference is the pool of slots
  only the queue hands out. Example: `maximumPlayers = 40`, `Config.maxPlayers = 32`.
- **No native exposes the real slot count** on this build (`Open77.players` has no
  capacity read; `GetConvarInt` only reads the `convars` block). The cap is therefore a
  config value, optionally mirrored through a convar (`rp_whitelist_max_players`, or set
  `Config.maxPlayersConvar = "sv_maxPlayers"` if you already keep it there). Do not mirror
  the hard `maximumPlayers` itself: the queue would never trigger.
- **A hold cannot outlive the gate deadline**: `simulation.connectGateTimeoutSeconds`,
  default 8 s (allowed 0.5-9; the client abandons the handshake after 10 s). The player
  is held `Config.queue.holdSeconds` (6.5 s) and then either admitted or refused with
  their position. There is no way to hold somebody for minutes at the door.
- **`deferrals.update()` never reaches the player**: the host writes it to the server log
  (`connecting '<name>': queue #2 of 3, 32/32 online (priority)`), the handshake has no
  progress channel. So "a position message every 10 s" is, honestly: one log line per
  hold (`Config.queue.positionEveryMs` matters only if the deadline were ever raised), and
  **the player reads their position in the refusal sentence, at every reconnect**. The
  launcher does not auto-retry for them.
- **A refused player cannot be pushed a slot later**: they are disconnected. What the
  queue guarantees is the order - a listed identity that keeps knocking is admitted before
  any unlisted one, and among listed ones the first knock wins - and the memory of the
  position across reconnects for `ttlSeconds`.
- The refusal sentence is trimmed by the host to 127 bytes of UTF-8 (the resource trims it
  cleanly first). Keep the texts in `shared/config.lua` short.
- **Enabling the whitelist or removing an entry does not disconnect anyone** (the built-in
  `whitelist.on` of the platform does; this resource deliberately does not). A ban does
  not kick either. `/kick` is the platform's.

## Exports (server, synchronous-safe, never yield)

```lua
exports.rp_whitelist:isAllowed(identifier)
-- true, or false, reason:
--   "banned" | "not_whitelisted" | "invalid_identifier" | "not_loaded"
-- "Would this identity pass the gate right now?": in queue mode an unlisted identity is
-- allowed (it would only wait); the capacity is not part of the answer.

exports.rp_whitelist:ban(identifier | playerId, minutes, reason)
-- true, or nil, reason: "invalid_identifier" | "player_not_found" | "invalid_minutes" | "not_loaded"
-- 0 minutes = permanent. Does NOT disconnect the player. `by` is the calling resource.
```

Call them inside `pcall` (a synchronous export raises when the resource is not running).

## Events

| Event | Side | Payload | When |
|---|---|---|---|
| `rp_whitelist:changed` | host bus (`TriggerEvent`) | `(identifier, action, by)` | `added`, `removed`, `banned`, `unbanned`; and `enabled` / `disabled` with identifier `*` |

`rp_logs` receives every change as an `rp_*:changed` subscriber and additionally through
`exports.rp_logs:log("whitelist", text, data)` (in `pcall`). Refusals are not re-raised:
the host's `onPlayerRejected (userId, name, code, message)` already reaches every resource.

## SQL tables

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`; column
names are back-quoted in every statement because `until` and `by` are reserved words.

`rp_whitelist_entries`

| Column | Type | |
|---|---|---|
| `identifier` | VARCHAR(64) PRIMARY KEY | the durable `userId` |
| `note` | VARCHAR(64) | free text, defaults to the RP / account name |
| `added_by` | VARCHAR(64) | identifier of the admin, or `console` |
| `at` | BIGINT | unix seconds |

`rp_whitelist_bans` (one active ban per identity: a new ban replaces the old one)

| Column | Type | |
|---|---|---|
| `identifier` | VARCHAR(64) PRIMARY KEY | the durable `userId` |
| `until` | BIGINT | unix seconds; `0` = permanent |
| `reason` | VARCHAR(128) | what the player reads |
| `by` | VARCHAR(64) | identifier of the admin, `console`, or the calling resource |

Expired bans are deleted at load and dropped on sight afterwards. Fallback when
`Open77.database.ready` answers `database_unavailable` (or the load fails): keys
`entry:<identifier>` and `ban:<identifier>` (JSON) in this resource's KVP store, logged as
`falling back to Open77.kvp`. A bridge that is still `connecting` after
`Config.storageWaitSeconds` (15 s) falls back the same way for the whole boot (a late
`database ready` is logged and ignored). The `enabled` flag is always in KVP (key `enabled`).

## Log lines (grep-able)

```text
[rp_whitelist] registry loaded from sql: 12 entries, 1 bans, whitelist disabled (allowlist)
[rp_whitelist] gate online: whitelist disabled, mode allowlist, soft cap 0, hold 6.5s
[rp_whitelist] gate: slot 32/32 handed to V (userId), 2 still waiting
WRN [rp_whitelist] database not ready (database_unavailable): falling back to Open77.kvp for the whitelist and the bans
WRN [rp_whitelist] gate: storage not loaded in time, refusing V (userId)
WRN [rp_whitelist] gate error: ...
```

plus the host's own `Player '<name>' (<userId>) refused (Refused): <sentence>` for every
refusal and `connecting '<name>': queue #...` for every hold.

## Test in 2 minutes (console, with the eval bot)

Nothing here needs the player to move: Kabuki Market, the freeroam spawn
`-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`, is where the bot stands when it is in.

1. Load list: `rp_identity`, `rp_logs` (or comment that dependency out), `rp_whitelist`.
   Log: `[rp_whitelist] registry loaded from sql: ...` then `gate online: whitelist
   disabled, mode allowlist, soft cap 0`.
2. Bot connected. Console: `wl liste` -> `Whitelist: 0 entries (disabled).`
3. Console: `wl ajouter <botPlayerId>` (its session id, from `players`). Answer:
   `Added <userId> on the whitelist as "<RP name>".` and the bot reads in chat
   `GATE: You are on the whitelist now, choom...`. `wl liste` shows the entry
   `online as <RP name> [id]`.
4. Console: `wl statut` -> `Whitelist disabled, mode allowlist, storage sql.`,
   `Entries: 1. Active bans: 0 (0 permanent). Bans while disabled: yes.`,
   `Capacity: no soft cap (1 online), the queue is off.`
5. Console: `wl ban <botPlayerId> 1 loud in the market` -> `<RP name> banned for 1 min: loud
   in the market. Not kicked - the next connect is refused (the platform /kick removes them
   now).` **The bot is still in** (this is deliberate); it reads the red `GATE` line.
   `wl statut` now lists `ban <userId> 1 min left: loud in the market (by console)`.
6. **The owner does this part**: disconnect the bot and reconnect it within the minute. The
   connection is refused and the shell shows `Banned from Night City for 42s: loud in the
   market`. Log: `Player '<name>' (<userId>) refused (Refused): Banned from Night City...`.
   `wl statut` shows it under `Last refusals`.
7. Wait for the minute to pass (or `wl unban <userId>`), reconnect: admitted. `wl statut`:
   `Active bans: 0`.
8. Whitelist itself: `wl activer` -> `Whitelist ENABLED (allowlist)...`. The bot, listed,
   reconnects fine. `wl retirer <userId>` then reconnect: refused with `This server is
   whitelisted. Apply on the Discord: https://discord.open2077.net`. `wl ajouter <userId>
   Test bot` (offline add by identifier) and reconnect: admitted. `wl desactiver` to leave
   the eval server as it was; the flag is persisted, so check `wl statut` after a restart.
9. Queue (optional, needs two clients and a server with `network.maximumPlayers` above the
   cap): set `Config.maxPlayers = 1` (or the convar `rp_whitelist_max_players`), `wl activer`
   with `Config.mode = "queue"`. First client in. Second client, unlisted: held ~6.5 s
   (log `connecting '<name>': queue #1 of 1, 1/1 online`), then refused `Night City is full
   (1/1). Queue #1 - reconnect to keep your place.` Add a third identity to the list and
   knock with it: it is `#1 (priority)` and the unlisted one is `#2`. Disconnect the first
   client and reconnect the listed one within 120 s: admitted (`gate: slot 1/1 handed to
   ...`); the unlisted one still reads `#1` until a slot frees for it.
