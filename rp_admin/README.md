# rp_admin — the moderation kit

Server-authoritative admin tooling for an Open77 RP server (build `2.31.13+op77.76`): an
**admin panel** (`/rpadmin`, UI kit context menu) listing everyone online with their RP name,
job, cash and zone, per-player actions (grade, cash, bank, warn, freeze, spectate, revive,
teleport, bring, criminal record), **restricted slash equivalents**, an **admin mode** (a red
`[ADMIN]` tag over your body for everyone, god mode), **player reports** (`/report`) with a
**ticket queue** (`/tickets`), and a **journal** of every action (`rp_admin_actions`, `rp_logs`
when it runs, and the `rp_admin:action` event).

It duplicates nothing the platform already owns: `tp goto bring kick ban announce revive` are
`open77_admin` / freeroam, `setjob` is `rp_jobs`, `giveitem` is `rp_inventory`. Teleports here
are the panel's convenience over `Open77.players.teleport`, kick and ban stay with the platform.

## Files

| File | Runtime | Role |
|---|---|---|
| `open77.lua` | manifest | dependencies, permissions, scripts |
| `shared/config.lua` | both | `RpAdminConfig`: the admin right, the tag look, limits, spectate camera, spawn |
| `server/main.lua` | server | everything: ACL check, panel, commands, admin mode, tickets, journal, persistence |
| `client/main.lua` | client | draws the `[ADMIN]` nameplate the server relays; nothing else |

Dependencies (both ship a client half): `open77_uikit` (server twins `context` and `input`),
`open77_notifications` (toasts). `rp_jobs`, `rp_economy`, `rp_bank`, `rp_identity`, `rp_ncpd`,
`rp_trauma`, `rp_zones`, `rp_inventory` and `rp_logs` are reached through exports inside `pcall`
and are **not** declared (this manifest is delivered to clients, and a client-delivered manifest
cannot depend on a server-only resource). A missing one degrades to a chat line
(`rp_economy is offline: no wallet to set.`).

## Who is an admin

`isAdmin(playerId)` = the player's identity holds the ACL right **`command.rpadmin`**
(`Open77.acl.isAllowed`, `RpAdminConfig.AdminRight`). That right opens the panel, receives the
`/report` toasts and is what the export answers. The nickname and the session id never count:
the ACL is resolved on the identity behind the session.

Every admin command is **restricted** (`RegisterCommand(..., true)`): the platform refuses a
player without `command.<name>` before the handler runs (the refusal lands in the Open77
terminal, not in chat), and the **dedicated console is always allowed** (`source 0`). Grant in
`acl.jsonc` then `acl.reload`:

```json
"permissions": [ "command.rpadmin", "command.setgrade", "command.setmoney", "command.setbank",
                 "command.warn", "command.freeze", "command.spectate", "command.tickets" ]
```

or simply `command.*` / `*`. `acl.check <playerId> command.rpadmin` in the server console tells
whether a connected player is an admin for this resource.

**On the eval server** the owner identity holds `*` and is therefore an admin; the bot player
is **not**. So, for testing:

| From the server console (`source 0`) | Needs an in-game admin (a body) |
|---|---|
| `tickets`, `tickets prendre <id>`, `tickets fermer <id> <answer>` | `/rpadmin` (the panel is a dialog on a client) |
| `setgrade <id> <0-3>`, `setmoney <id> <amount>`, `setbank <id> <amount>` | `/rpadmin mode` (the tag and god mode are on the caller's body) |
| `warn <id> <text>`, `freeze <id>` | `/spectate <id>` (the camera is the caller's; the ghost is the caller's body) |
| — (`report` answers `run it from the game`) | the panel's **Teleport to** / **Bring here** (they move the caller or move to the caller) |

The console reads every answer in the server log (`[rp_admin] ...`).

## Commands

| Command | Who | Effect |
|---|---|---|
| `/rpadmin` | admin (`command.rpadmin`) | Opens the panel (below). |
| `/rpadmin mode` | admin, in game | Toggles **admin mode**: a red `[ADMIN] <name>` nameplate over you for every other player (60 m), plus **god mode** (`Open77.players.setGodMode`, `GodModeInAdminMode = true`). Cleared on disconnect and when the resource stops. |
| `/setgrade <id> <0-3>` | `command.setgrade` or console | Sets the player's grade in **their current job** (`rp_jobs:setJob(id, job, grade)`). No job → `Give one first with /setjob`. The player is told. |
| `/setmoney <id> <amount>` | `command.setmoney` or console | Sets the player's **cash** to `amount` (0..1e9): the difference goes through `rp_economy:add` / `remove` with reason `admin:setmoney`. |
| `/setbank <id> <amount>` | `command.setbank` or console | Sets the player's **bank account** to `amount`. The bank only moves money between cash and the account, so a raise is `rp_economy:add` then `rp_bank:deposit`, a cut is `rp_bank:withdraw` then `rp_economy:remove`; the first step is rolled back when the second refuses. Cash is unchanged at the end. |
| `/warn <id> <text>` | `command.warn` or console | `[WARNING] <text>. Next time it is a kick, choom.` in the target's chat, plus a warning toast. Journaled. |
| `/freeze <id>` | `command.freeze` or console | Toggles **this resource's** hold on the player (`Open77.players.setFrozen`). A frozen player keeps chat, voice, camera and can still be shot. Thawing drops only our claim: if another script still holds them (cuffs, the Trauma "down" state) the answer says so. |
| `/spectate <id>` | `command.spectate`, in game | Ghosts you, hides your body and puts your camera behind the target (`Open77.players.spectate`), then teleports your ghost next to them so the world streams there. `/spectate` alone gives your body back. Ends by itself if either side dies, disconnects or changes bucket. Run it again if the target travels far. |
| `/report <text>` | **anyone** in game | Files a ticket (`rp_admin_tickets`, status `open`): you read `Report #n filed`, every online admin gets a toast and a chat line with `/tickets prendre n`. No admin online: `your report is saved for them`. |
| `/tickets` | `command.tickets` or console | Lists the open and taken tickets (newest last, 20 max): `#3 [open] Vince Rocker (4m ago): stuck in a wall`. |
| `/tickets prendre <id>` | idem | Takes the ticket: the reporter (if online) reads `<admin> is looking into your report #3.` A ticket taken by somebody else is refused. |
| `/tickets fermer <id> <answer>` | idem | Closes it with an answer. The reporter is told in chat and by toast; if offline, on their next visit (`While you were away, report #3 was closed: ...`). |

Every refusal is explained in chat (`No player #9 on the server.`, `Grade must be 0 to 3.`,
`rp_bank refused the deposit: insufficient_cash.`, `Spectate refused: different_bucket.`, …).
Player ids are the session ids (`/players`). Names come from `rp_identity` (`fullName`) when it
runs, else the account name.

## The panel (`/rpadmin`)

A UI kit **context** menu driven by the server (`Open77.exports.call("open77_uikit", "context",
playerId, ...)`), one dialog at a time:

1. **Root**: one row per online player — `Vince Rocker  #3` with `ncpd 2/3 · 1 200 €$ cash ·
   Afterlife` and a metadata block (job, cash, bank, zone) — then **Reports: n open**, **Admin
   mode: on/off**, and **Stop spectating** while you spectate. Sixty players at most (the kit
   caps a menu at 64 rows).
2. **Player**: Set grade, Set cash, Set bank account (each opens a numeric **input** dialog whose
   description shows the current value), Warn (a text dialog), Freeze / Thaw, Spectate, Revive,
   Teleport to, Bring here, Criminal record, Back. The result lands in chat and as a toast, and
   the player menu reopens so actions can be chained. Escape closes everything; the panel also
   closes itself after 60 s without a click (`PanelTimeoutMs`).
3. **Reports**: one row per ticket → Take it / Close with an answer (text dialog) / Back.

The menu shows only what the server knows: every pick is re-validated on the server (the
target still online, the amount in range, the ACL through the restricted command).

- **Revive** is `rp_trauma:revive(id, adminId)` (no fee). Without `rp_trauma` the platform's
  `Open77.players.revive` is used on a dead player, full health, 3 s grace.
- **Criminal record** prints the last 10 entries of `rp_ncpd:record(id)` in your chat.
- **Teleport to / Bring here** use `Open77.players.teleport` with `dismount = true`, a 1.5 m side
  offset and the anchor's routing bucket, and wait for the body to settle (`arrived (settled)`);
  a refusal (`player_not_alive`, `settle_timeout`, …) is reported as such.
- **Spectate** is available because the platform has a server-side spectate primitive
  (`Open77.players.spectate`, permission `players.spectate`); Warden cannot offer it (no body),
  an in-game admin can.

## Admin mode

`/rpadmin mode` (or the panel row). The server keeps `adminMode[adminId]` in memory and relays
`rp_admin:tag (playerId, enabled, name)` to every client; each client sets or removes its own
nameplate override (`Open77.nameplates.set`, red, 60 m). A client that starts later asks for
the roster (`rp_admin:clientReady` → `rp_admin:roster`). You never see your own tag (the
nameplate API only overrides remote players). Which override wins when `rp_identity` (RP name)
or `rp_jobs` (duty tag) also overrides the same body is not documented by the platform: measure
it; if the job tag wins, clock out (`/service`) before switching admin mode on.

God mode is `Open77.players.setGodMode(adminId, enabled)` and is checked by the server, so a Lua
damage arbiter cannot override it. The resource switches it off for everyone in admin mode when
it stops.

## Exports (server, synchronous, never yield)

```lua
exports.rp_admin:isAdmin(playerId)   -- boolean: the identity behind the session holds command.rpadmin
```

Accepts the string form host events deliver; `0`, `nil` and unknown sessions answer `false`.
Call it inside `pcall` from another resource; a resource **with** a client script must not
declare `dependency "rp_admin"` (this manifest is delivered to clients).

## Events (host bus, `TriggerEvent`)

```lua
AddEventHandler("rp_admin:action", function(adminId, action, targetId, text) end)
```

`adminId` is the session id, or `0` for the console. `targetId` is the target's session id, or
`0` when the action has none (`mode_on` / `mode_off`) or the target is offline (a ticket whose
reporter left). `action` is one of `setgrade setmoney setbank warn freeze unfreeze spectate
spectate_stop goto bring revive record mode_on mode_off ticket_take ticket_close`; `text` is the
detail (`ncpd grade 2`, `5000 (was 1200)`, the warning, `#3 <answer>`…). The same line goes to
`rp_logs:log("admin", text, data)` when `rp_logs` runs, and a `/report` to
`rp_logs:log("report", …)`.

Internal net events (`rp_admin:tag`, `rp_admin:roster`, `rp_admin:clientReady`) are this
resource's client/server transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS` (permission
`database.access`), keyed by `Open77.players.identifier` (never the session id):

```sql
rp_admin_tickets (
    id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    identifier    VARCHAR(64)  NOT NULL,          -- the reporter
    reporter_name VARCHAR(80)  NOT NULL DEFAULT '',
    text          VARCHAR(300) NOT NULL,
    status        VARCHAR(16)  NOT NULL DEFAULT 'open',   -- open | taken | closed
    taken_by      VARCHAR(64)  NOT NULL DEFAULT '',       -- admin identifier, or "console"
    taken_by_name VARCHAR(80)  NOT NULL DEFAULT '',
    answer        VARCHAR(300) NOT NULL DEFAULT '',
    notified      TINYINT(1)   NOT NULL DEFAULT 0,        -- 0 = the reporter has not read the answer yet
    created_at    BIGINT       NOT NULL DEFAULT 0,        -- unix seconds
    closed_at     BIGINT       NOT NULL DEFAULT 0
)

rp_admin_actions (
    id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    admin       VARCHAR(64)  NOT NULL,            -- admin identifier, or "console"
    admin_name  VARCHAR(80)  NOT NULL DEFAULT '',
    action      VARCHAR(32)  NOT NULL,
    target      VARCHAR(64)  NOT NULL DEFAULT '', -- target identifier, '' when none
    target_name VARCHAR(80)  NOT NULL DEFAULT '',
    text        VARCHAR(300) NOT NULL DEFAULT '',
    at          BIGINT       NOT NULL DEFAULT 0   -- unix seconds
)
```

Open and taken tickets are cached in memory (loaded once when the database answers); takes,
closes and journal rows are written through with the callback forms, so the `isAdmin` export
never touches the database. `/report` inserts with `.await` inside its command handler to get
the ticket id back (a handler is a managed task; an export is not).

**No database** (`ready` answers `database_unavailable`, or the database is still not answering
15 s after start, `DatabaseWaitMs`): tickets and actions fall back to `Open77.kvp`
(`ticket:<id>`, `tickets:open`, `tickets:next`, `action:<n>`, `actions:next`,
`pending:<identifier>` for answers to deliver later) and the log says `[rp_admin] store=kvp
reason=...`. The choice is kept for the whole boot; actions journaled before the choice are
flushed once it is made.

## Log (grep-able)

```text
[rp_admin] started: admin right command.rpadmin, panel timeout 60 s, god mode in admin mode: true
[rp_admin] store=sql tables=rp_admin_tickets,rp_admin_actions open_tickets=0
[rp_admin] action=setmoney by=Vince Rocker (<identifier>) target=Judy Alvarez (<identifier>) text=5000 (was 1200)
[rp_admin] action=freeze by=console (console) target=Judy Alvarez (<identifier>) text=
[rp_admin] report #3 by Judy Alvarez (<identifier>): stuck in a wall (admins told: 1)
[rp_admin] action=ticket_close by=Vince Rocker (<identifier>) target=Judy Alvarez (<identifier>) text=#3 pulled you out
[rp_admin] store=kvp reason=database_unavailable (no database: tickets and actions fall back to Open77.kvp) open_tickets=0
```

## Test in 2 minutes

At the freeroam spawn, Kabuki Market Centre (`-1191.30, 2006.88, 7.82`, `RpAdminConfig.Spawn`).
Player **1** is the
owner (ACL `*`, in game), player **2** is the bot (not an admin). `rp_economy`, `rp_bank`,
`rp_jobs`, `rp_identity` running. Log on start: `[rp_admin] started: ...` then
`[rp_admin] store=sql ...`.

1. Player 2: `/report stuck in a wall by the ATM` → player 2 reads `Report #1 filed. An admin
   will get back to you, choom.`; player 1 gets a warning toast `Report #1` and the chat line
   `[REPORT #1] <name>: stuck in a wall by the ATM   (/tickets prendre 1)`.
   Player 2: `/tickets` → refused by the ACL (nothing in chat: the refusal is in the terminal).
2. Console: `tickets` → `[rp_admin] 1 open report(s):` / `#1 [open] <name> (20s ago): stuck...`.
   Console: `tickets prendre 1` → player 2 reads `console is looking into your report #1.`
   Player 1: `/tickets fermer 1 pulled you out, choom` → player 2 reads `Your report #1 is
   closed. <name>: pulled you out, choom` + a success toast; player 1 reads `Report #1 closed
   (the reporter was told).`
3. Player 1: `/rpadmin` → the panel lists both players with job, cash and zone (`Kabuki Market`
   / `kabuki_market` when `rp_zones` runs). Pick player 2 → **Set cash** → the dialog says
   `<name> has 500 €$ in hand.` → type `5000` → Apply → chat `<name>: cash 500 €$ -> 5 000 €$.`,
   player 2 reads `An admin set your cash to 5 000 €$ (+4 500 €$).` and `/money` says 5000.
4. Still in the player menu: **Set bank account** → `2000` → player 2's `/solde` shows
   `Account: 2 000 €$`, cash unchanged. **Warn** → type `keep it civil` → player 2 reads
   `[WARNING] keep it civil. Next time it is a kick, choom.` and a warning toast.
5. **Freeze** → player 2 cannot walk, can still type; the row now reads **Thaw**. **Thaw** →
   `<name> is free to move again.` (Slash form: console `freeze 2` twice.)
6. Console: `setjob 2 ncpd 0` (rp_jobs), then console `setgrade 2 2` → `[rp_admin] <name> is now
   ncpd grade 2/3.`, player 2 reads `An admin set your ncpd grade to 2/3.`; `setgrade 2 7` →
   `Grade must be 0 to 3.`
7. Player 1 walks 30 m away, `/rpadmin` → player 2 → **Teleport to** → the screen fades, player 1
   lands 1.5 m beside player 2, chat `You are beside <name> (settled).` **Bring here** does the
   reverse and player 2 reads `An admin brought you to them.`
8. Player 1: `/spectate 2` → player 1's body vanishes for player 2, the camera hangs behind
   player 2's shoulder; `/spectate` → `Back in your own body.` `/spectate 1` → `You cannot
   spectate yourself.`
9. Player 1: `/rpadmin mode` → `Admin mode ON: everyone sees your [ADMIN] tag. God mode on.`;
   player 2 sees a red `[ADMIN] <name>` over player 1's body; player 2 shooting player 1 does no
   damage. `/rpadmin mode` again → tag gone, god mode off.
10. Player 2 dies (`/suicide`), player 1: panel → player 2 → **Revive** → `<name> is back on their
    feet (Trauma Team).` (or `(rp_trauma offline: platform revive)` without `rp_trauma`).
11. `SELECT action, target_name, text FROM rp_admin_actions ORDER BY id` lists every step above
    with the admin's identifier; from another resource
    `AddEventHandler("rp_admin:action", print)` prints them live, and
    `print(exports.rp_admin:isAdmin(1), exports.rp_admin:isAdmin(2))` → `true false`.

## Honest limits

- The `/rpadmin` panel, `/rpadmin mode`, `/spectate` and the panel's teleports need a body: the
  console gets a one-line answer instead. Everything else works from the console.
- Restricted refusals are the platform's and land in the Open77 terminal, not in chat.
- Spectate and teleport are refused across routing buckets (`different_bucket`); a spectated
  target who travels far outruns the ghost's streaming: run `/spectate <id>` again.
- The bank has no "set" export: **Set bank** is composed from a cash move and a bank move (see
  `/setbank`); the journal keeps the intent (`5000 (was 1200)`), `rp_bank`'s ledger keeps the moves.
- Freeze is a claim of this resource; the Warden panel's freeze and a gamemode's are separate
  claims. `isFrozen` answers true while anybody holds the player, which is why Thaw reports
  `another script still holds them` rather than pretending.
- `players.teleport` is declared because the `Open77.players.teleport` card says the native
  requires it, although the validator notes no catalogued native checks it on this build.
