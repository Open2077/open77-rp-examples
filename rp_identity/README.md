# rp_identity - the civil registry of Night City

One persistent citizen record per durable identity (`Open77.players.identifier`), a
registration form on first connection, an ID card you can read or show to somebody standing
next to you, an admin edit command, and the RP name over every registered body.

Server-authoritative: the client renders the form and forwards the answers; every rule
(names, dates, ages, enums, distance, ACL) lives in `server/main.lua`.

## Files

| File | Runtime | Role |
|---|---|---|
| `open77.lua` | manifest | dependencies, permissions, scripts |
| `server/main.lua` | server | registry, validation, storage, commands, exports, events |
| `client/main.lua` | client | registration form (`open77_uikit` `input`), ALT+click "Show ID" (`open77_contextmenu`), RP nameplates (`Open77.nameplates`) |

Dependencies: `open77_uikit`, `open77_contextmenu`, `open77_notifications` (all three must be
in the server's load list, before this resource). Permissions: `database.access`,
`network.events`, `ui.nameplates`.

## Storage

Table `rp_identity_citizens`, created inside `Open77.database.ready(...)`:

| Column | Type | |
|---|---|---|
| `id` | INT UNSIGNED AUTO_INCREMENT | the citizen id printed on the card |
| `identifier` | VARCHAR(64) UNIQUE | `Open77.players.identifier(playerId)` |
| `first_name`, `last_name` | VARCHAR(24) | letters, spaces, hyphens; 2..24 characters |
| `birth` | CHAR(10) | `YYYY-MM-DD`; age 18..90 on the day of the check |
| `sex` | CHAR(1) | `m`, `f`, `x` |
| `origin` | VARCHAR(16) | `night_city`, `badlands`, `corpo`, `nomad`, `offworld` |
| `created_at`, `updated_at` | DATETIME | maintained by the database |

If `Open77.database.isReady()` is false when a record is read or written, the resource
falls back to `Open77.kvp` (key `citizen:<identifier>`, JSON) and says so once in the log.
Records are cached per session, so the exports never touch the database.

## Player flow

1. `onPlayerReady`: the record is loaded. Registered: "Welcome back", nameplate set.
   Unregistered: a chat line and the registration form (first name, last name, birth date,
   sex, origin). Cancelling is fine; NCID reminds the player every 60 s (chat line and the
   form again) until they register. `/carte` reopens the form at any time.
2. The server validates the answers and tells the player exactly what was refused, then
   reopens the form. On success: row written, nameplate set, "Welcome to Night City,
   <name>." broadcast, toast, log line, `rp_identity:changed`.

## Commands

| Command | Who | Does |
|---|---|---|
| `/carte` | anyone in game | Your own ID card: toast + chat lines (full name, birth date, age, sex, origin, citizen id). Unregistered: reopens the registration form. |
| `/montrercarte <playerId>` | anyone in game | Shows **your** card to that player. The target must be within 5 m; the target (not you) receives the card. |
| ALT+click a player > **Show ID** | anyone in game | Same as `/montrercarte`, through the context menu; the server rechecks the range. |
| `/civil <playerId> <field> <value>` | ACL `command.civil`, or the console | Edits one field of an online citizen and re-applies the nameplate. `field`: `first_name`, `last_name`, `birth`, `sex`, `origin`. Quote a multi-word value from chat (`/civil 3 last_name "De Silva"`); from the console the remaining words are joined. |

Refusals are explained in chat (or in the log for the console): not registered, unknown
player, too far, bad value (with the rule that failed), registry down.

## Exports (server, synchronous-safe)

```lua
exports.rp_identity:get(playerId)          -- { firstName, lastName, birth, sex, origin } | nil
exports.rp_identity:fullName(playerId)     -- "First Last", or Open77.players.name(playerId), or "Unknown citizen"
exports.rp_identity:isRegistered(playerId) -- boolean
```

They answer from the session cache and never yield, so both `exports.rp_identity:...` (in a
`pcall`) and `Open77.exports.call("rp_identity", ...)` work.

## Events

| Event | Side | Payload | When |
|---|---|---|---|
| `rp_identity:changed` | host bus (`TriggerEvent`) | `(playerId)` | after a registration or a `/civil` edit |

Internal net events (`rp_identity:register`, `rp_identity:showTo`, `rp_identity:clientReady`,
`rp_identity:formRefused`, `rp_identity:formClosed`, `rp_identity:openRegistration`,
`rp_identity:nameplate`, `rp_identity:directory`) are the client/server transport of this
resource and are not an API.

## Log lines (grep-able)

```text
[rp_identity] player 3 registered id=12 name="V Rocker"
[rp_identity] player 3 edited id=12 field=last_name value="Silverhand" by=player 1
[rp_identity] database not ready (database_unavailable): falling back to Open77.kvp for citizen records
```

## Test in 2 minutes

1. Start the server with `open77_uikit`, `open77_contextmenu`, `open77_notifications` and
   `rp_identity` in the load list. Log: `[rp_identity] schema ready: rp_identity_citizens`
   and `[rp_identity] civil registry online`.
2. Connect with a fresh identity. Chat: "No citizen record on file..." and the registration
   form opens. Press Escape: chat says registration is postponed; wait 60 s: the reminder and
   the form come back.
3. Fill the form with a birth date such as `2001-13-40` and press Register: chat explains
   the refusal and the form reopens. Enter `1998-07-14`, a name like `V` (one letter): refused
   again with "2 to 24 characters". Enter `Vince Rocker`, `1998-07-14`, `Male`, `Night City
   native`: everybody reads "Welcome to Night City, Vince Rocker.", a toast shows
   "Citizen record created", the log has `player <id> registered id=<n> name="Vince Rocker"`.
4. `/carte`: toast plus three chat lines (`NCID #<n> - Vince Rocker`, born/age/sex, origin).
5. Second client, registered too, standing 2 m away: on the first client hold ALT, click the
   other body, pick **Show ID**. The second client (only) receives Vince's card; the first
   reads "You showed your ID to ...". Walk 10 m away and retry (or `/montrercarte <id>`):
   "Too far away (x m). Get within 5 m...".
6. Other clients see `Vince Rocker` over the body instead of the account name.
7. From the console: `civil <id> last_name Silverhand`. The player reads "NCID updated your
   record", the nameplate changes, the log has the `edited` line. From a client without
   `command.civil` the command is refused by the ACL before the handler runs.
8. Reconnect: "Welcome back to Night City, Vince Silverhand." with no form.
