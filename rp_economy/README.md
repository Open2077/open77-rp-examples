# rp_economy — server-side wallet (eurodollars)

**Server-only** resource for Open77 (build `2.31.13+op77.76`). Every player owns an integer
balance in €$, bound to their durable identifier (`Open77.players.identifier`), loaded when the
player is ready (`onPlayerReady`) and saved to SQL on every change. A new player starts with
**500 €$**.

## Persistence

Wallets live in the server database (permission `database.access`), one row per identifier:

```sql
CREATE TABLE IF NOT EXISTS rp_economy_wallets (
    identifier VARCHAR(64) PRIMARY KEY,
    name       VARCHAR(64),          -- display name at the last write, informative only
    balance    BIGINT NOT NULL,
    updated_at BIGINT NOT NULL       -- unix seconds of the last write
)
```

The table is created inside `Open77.database.ready`. Every change is written at once with
`INSERT … ON DUPLICATE KEY UPDATE` through the callback form (the exports never yield); a
failed write is logged as `sql write failed for player <id> (<userId>): <reason>` and the
in-memory balance stays authoritative until the next write. A wallet is read on
`onPlayerReady` (and by `/money` when it is not loaded yet); a read failure never invents a
balance: the player is told `Wallet unavailable (storage_unavailable)`.

The store is decided **once per boot** and logged:

| Situation | Log line | Effect |
|---|---|---|
| Database answers | `[rp_economy] store=sql wallets=<rows>` | SQL for the whole boot. |
| No database bridge, or permission missing | `[rp_economy] store=kvp reason=database_unavailable` (or `permission_denied:database.access`) | The resource's own KVP store (`kvp.json` next to the resource, **wiped by a redeploy that replaces the folder**). |
| Database still connecting 15 s after the first player is ready | `[rp_economy] store=kvp reason=database_connecting` (or `database_unreachable`) | Same KVP fallback, for this boot only; a database that answers later is ignored (`database answered after the KVP fallback was chosen; staying on KVP for this boot`). |
| Schema creation or migration fails | `[rp_economy] schema or migration failed: <error>` then `store=kvp reason=sql_boot_failed` | KVP fallback. |

**One-time migration**: on the first SQL start, every `balance:<userId>` key still found in the
KVP store (the phase-0 layout) is copied into the table (`migrated <n> wallet(s) from kvp to sql
(<f> failed)`); a row already present in SQL wins. The KVP keys are left in place and the marker
key `migrated:sql` prevents a second run (a run with failures is retried at the next SQL start).
Balances changed during a KVP-fallback boot are **not** merged back into SQL afterwards.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/money` | any player | Shows the balance in chat (and a notification when `open77_notifications` is running). |
| `/pay <playerId> <amount>` | any player | Sends `amount` €$ to a connected, ready player. Refused when: the amount is not a positive integer, insufficient funds, target offline, or yourself. Both players are told. |
| `/givemoney <playerId> <amount>` | admin (ACL `command.givemoney`) or console | Credits a player. From the console only the credited player is told. |
| `/payday` | admin (ACL `command.payday`) or console | Triggers an immediate payday for every ready player. |

**Automatic payday**: every 10 minutes, each connected and ready player receives 200 €$ with the
chat line `Payday: +200 €$`.

Restricted commands use `RegisterCommand(..., true)`: a player without the ACL right is refused
by the server before the handler runs (the answer lands in the Open77 terminal, not in chat).
To authorise an admin, add `command.givemoney` and `command.payday` (or `command.*`) to their
principal in `acl.jsonc`, then `acl.reload`.

## Server exports (shared contract)

```lua
exports.rp_economy:getBalance(playerId)        -- integer, 0 when unknown
exports.rp_economy:add(playerId, amount, reason)    -- newBalance | nil, reason
exports.rp_economy:remove(playerId, amount, reason) -- newBalance | nil, "insufficient_funds" | nil, reason
```

Validation: `playerId` is a positive integer of a **loaded** player (otherwise `invalid_player_id` /
`player_not_found`), `amount` a positive integer (`invalid_amount`), `reason` a string of 1 to 64
bytes without control characters, or `nil` (`invalid_reason`). `balance_limit` when the balance
would exceed 10^12. After every change:

```lua
TriggerEvent("rp_economy:changed", playerId, newBalance, delta, reason)
```

The exports are synchronous and never yield: calling `exports.rp_economy:add(...)` is safe.
Declare `dependency "rp_economy"` in the calling resource's manifest.

## Log

Every change is printed in a grep-able form:

```
[rp_economy] +200 player 3 payday balance=700
[rp_economy] -50 player 3 pay:to:4 balance=650
[rp_economy] +50 player 4 pay:from:3 balance=550
[rp_economy] +1000 player 4 givemoney:by:0 balance=1550
```

At start: `[rp_economy] started` then `[rp_economy] store=sql wallets=<rows>` (or the KVP line
of the table above). At a join: `[rp_economy] new wallet player <id> <userId> balance=500` the
first time, `[rp_economy] loaded player <id> <userId> balance=<n>` afterwards.

## Test it in 2 minutes

1. Drop the folder in the server's resource root (`auto_start true`), start the server: the log
   shows `[rp_economy] started` then `[rp_economy] store=sql wallets=<rows>`.
2. Connect with a client: on entering the world the chat shows `Balance: 500 €$`, and the server
   log `[rp_economy] new wallet player <id> <userId> balance=500`.
3. `/money` → `Balance: 500 €$` (+ toast when notifications are running).
4. Server console: `givemoney <id> 1000` → the player sees `An admin credited you 1000 €$.
   Balance: 1500 €$`.
5. Server console: `payday` → the player sees `Payday: +200 €$`, log `+200 player <id> payday`.
6. With a second client (`id2`): `/pay id2 300` → both players see the transfer line;
   `/pay id2 999999` → `Insufficient funds`; `/pay <self> 10` → refused.
7. Disconnect and come back: the balance is kept (`[rp_economy] loaded player ...`).
8. Restart the server (or redeploy the resource folder) and come back: the balance survives,
   the log shows `store=sql wallets=1` then `loaded player <id> <userId> balance=<n>`, and
   `SELECT * FROM rp_economy_wallets` shows the row.
9. From another resource: `print(exports.rp_economy:getBalance(id))`.
