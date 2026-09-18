# rp_vigile — private security

Guard contracts for an Open77 RP server (build `2.31.13+op77.76`): a security guard (`rp_jobs`
job `vigile`) guards **a place** (a zone from `rp_zones`) or **a person** (a bodyguard) and is paid
**per guarded minute**. Inside a guarded zone the guard may **escort** a troublemaker out
(ALT+click, released automatically at the ring) or **expel** them (teleport 20 m past the ring),
and a **camera log** records who entered and left while the zone was watched.

Server-authoritative: contracts, money, the minute clock, the rights and the log live in
`server/main.lua`. The client only registers the ALT+click actions and renders what the server
pushes.

## Money

| Setting (`shared/config.lua`) | Default | Meaning |
|---|---|---|
| `ratePerMinute` | 20 €$ | what one guarded minute costs the client |
| `societyShare` | 20 % | the cut of each paid minute kept by the `vigile` society (`rp_bank`) |

So every paid minute is **16 €$ cash to the guard** (`rp_economy:add(guard, 16, "guard")`) and
**4 €$ to the `vigile` society** (`rp_bank:societyAdd`). Who pays depends on the contract:

| Contract | Client | Each paid minute |
|---|---|---|
| zone with a society (`zoneSociety[zone]`, e.g. `afterlife` → `barman`) | that job's society | `rp_bank:societyRemove(<job>, 20, "vigile:<id>")`, then the guard and the cut. A dry society = the minute is **not paid** and the guard is told why. |
| zone without a society (`kabuki_market`, ...) | "corpo": the platform | `rp_economy:add` only; the cut is minted into the `vigile` society. |
| person (bodyguard) | the hiring citizen's **bank account** | the whole fee (`minutes × 20`) is charged at posting through `rp_bank:charge(client, fee, "vigile", "bodyguard:<guardId>")` — refused when the account is short — and sits in the `vigile` society; each paid minute moves 16 €$ to the guard. Unguarded minutes are **refunded in cash** when the contract ends (kept as `refund_due` and paid on the next connection when the client is offline). |

A minute is paid when the guard was **on duty** and **inside the zone** (or within
`bodyguardRange` = 15 m of the client) for at least `minuteCoverage` (75 %) of the 5-second samples
of that minute. After `unpaidWarnAfter` (2) consecutive unpaid minutes the guard is told the
reason in chat, every minute until it is fixed. Clocking out (`/service`), losing the job or
disconnecting ends the contract.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/garde` | anyone | **Your contract** (kind, minutes left, minutes paid, earnings, inside/outside the zone or the distance to your client) when you have one, as guard or as client. Otherwise, for an on-duty guard, the **board**: a UI-kit menu of the standing zone contracts (`templates`, one per zone that nobody guards) and of the contracts posted by players (bodyguard offers addressed to you or to any guard, zone contracts posted through the export). Pick one to start it. |
| `/garde engager <guardId> <minutes>` | anyone | Hire that on-duty guard as your bodyguard. The fee (`minutes × 20 €$`) is charged to your bank account now; the guard has `offerTimeoutSec` (180 s) to accept on `/garde`, else the offer expires and you are refunded. Refused: unknown id, not a guard, off duty, guard busy, you already have a contract, account short (with the amount needed). |
| `/garde fin` | guard or client | Ends the contract from either side. Bodyguard contracts refund the unguarded minutes to the client (cash); a pending offer is refunded in full. |
| `/garde journal` | guard, society, poster | The **camera log** of the guarded zone: the last 50 entries with a UTC time — `entered`, `left`, `was inside when the watch began`, `was thrown out by security`, `was escorted out`. Readable by the guard of that zone, by any employee of the society that pays for it (`rp_jobs:getJob`), and by the player who posted the contract. |
| `/garde escorter <playerId>` | guard in the zone | Slash fallback of the ALT+click **Escort out (security)** action: `open77_rp_basics:escort` within 3 m; the person is released automatically when they leave the zone, with the chat line *You have been escorted out of <zone>.* |
| `/garde relacher <playerId>` | guard | Slash fallback of the ALT+click **Release (security)** action. |
| `/garde aide` | anyone | This list. |
| `/expulser <playerId>` | guard in the zone | Teleports the player 20 m past the ring (`Open77.players.teleport`, `dismount = true`, ground height from `Open77.world.groundZ` when a client can see it). Refused on an **NCPD officer on duty** (`rp_ncpd:isOnDuty`, or `rp_jobs` job `ncpd` on duty), outside your guarded zone, on a player who is not inside it, and on yourself. Logged in the camera log and in the server log. |

`/garde` and `/expulser` refuse the server console (`run it from the game`). Every refusal is
explained in chat, in English.

**ALT+click** on a player inside the zone you guard shows **Escort out (security)** (within 3 m)
and, while you escort them, **Release (security)**. The entries only appear while the server has
told your client that you guard a zone; the server re-checks contract, zone, distance and life on
every click.

**Escort needs the role-play kit.** `open77_rp_basics` ships `auto_start false` and its `escort`
verb answers `not_authorised` until the ACL entry `rp.escort` is granted to the guards. Without
it the guard reads `Security has no escort rights here (ACL rp.escort not granted to guards). Use
/expulser.` — expulsion does not depend on the kit.

## Exports (server, synchronous, never yield)

```lua
exports.rp_vigile:postContract(kind, target, minutes, byPlayerId)  -- contractId | nil, reason
exports.rp_vigile:activeContract(playerId)                         -- table | nil
```

`postContract("zone", "afterlife", 30, posterId)` puts a zone contract on the board (paid by the
zone's society, or by the platform when the zone has none); `posterId` (optional, `nil`/`0` for
nobody) may read the camera log and end the contract. `postContract("person", protectedId, 15,
clientId)` posts a bodyguard contract open to every on-duty guard: `clientId` pays now (`nil` =
the platform pays). Reasons: `store_not_ready`, `invalid_minutes` (1..240), `invalid_kind`,
`invalid_zone`, `unknown_zone`, `zone_guarded`, `zone_already_posted`, `unavailable:rp_zones`,
`invalid_player_id`, `player_not_found`, `client_not_found`, `client_busy`, `target_busy`, and the
bank's own (`insufficient_funds`, `bank_not_ready`, `unavailable:rp_bank`).

`activeContract(playerId)` answers for the guard, the client and the protected person:
`{ id, kind, zone, state ("open"|"active"), payer, guardId, clientId, protectedId, minutes,
minutesLeft, paidMinutes, rate, guardShare, earned, fee, postedAt, startedAt }`.

Both read the in-memory registry (SQL is written through with callback forms). Call them inside
`pcall` from another resource (`rp_fixer`, a business): a synchronous export raises when the
provider is missing.

## Events (host bus, `TriggerEvent`)

```lua
AddEventHandler("rp_vigile:contract", function(contractId, phase, guardId, clientId) end)
```

`phase` is `posted` (on the board), `started` (a guard took it), `ended` (an active contract is
over: completed, ended by a side, guard off duty / gone, client gone, resource stop), `expired`
(an offer nobody took in time) or `cancelled` (an offer withdrawn). `guardId` is `nil` before
`started`; `clientId` is `nil` for corpo contracts. The contract's `end_reason` is in the table.

Consumed: `rp_zones:entered` / `rp_zones:left` (camera log, escort release at the ring),
`rp_jobs:duty` / `rp_jobs:changed` (a guard who clocks out or changes job loses the contract).

Internal net events (`rp_vigile:escort`, `rp_vigile:release`, `rp_vigile:clientReady`,
`rp_vigile:state`) are the client/server transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS` (permission
`database.access`). Rows are keyed by the durable `Open77.players.identifier`, never the session id:

```sql
rp_vigile_contracts (
    id                   INT UNSIGNED PRIMARY KEY,   -- allocated by the resource (MAX(id)+1 at boot)
    kind                 VARCHAR(8),                 -- zone | person
    zone                 VARCHAR(32),
    payer                VARCHAR(48),                -- society:<job> | corpo | account
    guard_identifier, client_identifier, protected_identifier  VARCHAR(64),
    minutes, rate, paid_minutes, fee, earned, society_cut, refund_due  INT,
    state                VARCHAR(8),                 -- open | active | done
    end_reason           VARCHAR(32),                -- completed guard_ended client_ended guard_left client_left
                                                     -- off_duty job_lost expired resource_stop server_restart
    posted_at, started_at, ended_at  BIGINT          -- unix seconds
)
```

The row is the ledger; live contracts are in memory. At boot, rows left `open`/`active` by a
previous run are closed with `server_restart` and an unspent bodyguard escrow becomes
`refund_due`, paid in cash on the client's next `onPlayerReady`.

**No database** (`ready` answers `database_unavailable`, or the database is still silent
`storeFallbackAfterSec` = 15 s after start): contracts go to `Open77.kvp` (`contract:<id>`,
`next_id`, `refund:<identifier>`) and the log says `[rp_vigile] store=kvp reason=...`. The choice
is made once per boot.

## Log (grep-able)

```text
[rp_vigile] started: 3 templates, 20 €$/min (16 €$ guard + 4 €$ company), bodyguard range 15 m, expel 20 m past the ring
[rp_vigile] store=sql table=rp_vigile_contracts next_id=1
[rp_vigile] contract 1 posted kind=zone zone=afterlife by=nil payer=society:barman minutes=30
[rp_vigile] contract 1 started kind=zone zone=afterlife guard=3 client=nil payer=society:barman minutes=30
[rp_vigile] contract 1 minute 1 paid guard=3 +16 cut=4
[rp_vigile] contract 1 minute 4 unpaid reason=you were outside Afterlife
[rp_vigile] contract 1 guard 3 expelled 4 from afterlife to -1421.8 1035.2 22.7 (settled)
[rp_vigile] player 4 escorted out of afterlife by 3
[rp_vigile] contract 1 ended reason=guard_ended paid_minutes=2 earned=32 cut=8
[rp_vigile] contract 2 posted kind=person protected=4 client=4 offerTo=3 minutes=5 fee=100
[rp_vigile] contract 2: refund of 60 kept for <identifier>
```

## Manifest

Permissions: `network.events` (net events both ways), `database.access` (SQL), `players.teleport`
(named by the `Open77.players.teleport` card), `world.query` (`Open77.world.groundZ`).
Dependencies: `open77_uikit` (the board, server twin `context`), `open77_contextmenu` (the
ALT+click actions), `rp_jobs`, `rp_zones`, `rp_bank`, `rp_identity` (all four ship a client half).
`rp_economy` is server-only and reached through `pcall`; so are the optional `open77_rp_basics`,
`rp_ncpd` and `rp_fixer`. Every cross-resource call is a `pcall`: without `rp_bank` a bodyguard
cannot be hired and society contracts go unpaid (the guard is told), without `rp_economy` nothing
is paid, without `rp_identity` account names are used.

## Map

The **freeroam spawn** is Kabuki Market Centre `-1191.30, 2006.88, 7.82` (`VigileConfig.testSpots`),
real Night City. The zones come from `rp_zones` (`shared/config.lua` there); their centres are
copied into `VigileConfig.zoneGeometry` for the expulsion point. The three standing contracts:

| Zone | Centre | Radius | Client | From spawn |
|---|---|---|---|---|
| `afterlife` | -1453, 1017, 16.6 | 50 m (rp_zones; `zoneGeometry.afterlife.radius` still says 25) | `barman` society | 1.0 km south-west (drive; the bar under the ramp) |
| `lizzies` | -1188.9, 1566.2, 23.0 | 18 m | `barman` society | 440 m south |
| `kabuki_market` | -1191.30, 2006.88, 7.82 | 70 m | corpo | 0 m (the market around the spawn) |

Any other rp_zones zone can be posted by a business through `postContract` (the geometry table
also carries `h10`, `viktor_clinic` → `ripper`, `ncpd_hq` → `ncpd`, `junkyard` → `ferrailleur`,
`nomad_camp` → `nomade`, `westbrook_dealer` → `mecano`).

## Test in 2 minutes (one player, a zone contract)

`rp_jobs`, `rp_zones`, `rp_bank`, `rp_economy`, `rp_identity`, `open77_uikit` and
`open77_contextmenu` running; you are player `1` at the freeroam spawn. Log on start:
`[rp_vigile] started: 3 templates, ...` then `[rp_vigile] store=sql table=rp_vigile_contracts next_id=1`.

1. **Console:** `setjob 1 barman 3` (seeds the bar's society with 50 000 €$ — the Afterlife's
   and Lizzie's client; skip it and take the **kabuki_market** contract instead if you want the
   platform to pay), then `setjob 1 vigile 0`. Chat confirms the job (`/job` → `Security guard
   (vigile) - grade 0/3 recruit`).
2. `/service` → `Clocked in at Security guard as recruit.`
3. `/garde` → the **Security contracts** board: *Guard The Afterlife — 30 min - client: the bar*,
   *Guard Lizzie's Bar ...*, *Guard Kabuki Market ...*. Pick **Guard The Afterlife** → chat
   `Contract #1: guard The Afterlife for 30 min at 20 €$/min (16 €$ to you, 4 €$ to the company).
   Stay inside the ring; ...`, log `contract 1 started kind=zone zone=afterlife guard=1 ...`.
4. Drive 1.0 km south-west to the Afterlife and walk down the ramp into the bar (`-1453, 1017`,
   toast **The Afterlife**; the 50 m zone covers the whole floor). `/garde` →
   `Contract #1: guarding The Afterlife - 30/30 minute(s) left, 0 paid, 0 €$ earned (16 €$/min).`
   and `You are inside the zone: the minute counts.`
5. Stand there **2 minutes**: `+16 €$ (minute 1/30 guarded). Total 16 €$.` then `+16 €$ (minute
   2/30 guarded). Total 32 €$.`; `/money` is up by 32; log `contract 1 minute 1 paid guard=1 +16
   cut=4` (twice); `/societe` shows the `vigile` society at 8 €$.
6. Walk back up the ramp, 30 m out of the ring: `You left The Afterlife: the clock keeps running,
   but a minute spent outside is not paid.` Step back in (toast). `/garde journal` → `Camera log of
   The Afterlife (last 3,
   UTC):`, `[hh:mm:ss] <you> (#1) entered`, `... left`, `... entered` (a contract taken while
   already inside the ring starts with `... was inside when the watch began` instead).
7. Stay outside for 2 minutes: `No pay for the last 2 minute(s): you were outside Afterlife.`
8. `/garde fin` → `Contract #1 over (the guard ended it): 2/30 minute(s) paid, 32 €$ earned.`;
   `/garde` shows the board again. Log `contract 1 ended reason=guard_ended paid_minutes=2 ...`.
9. `/service` (clock out) while guarding → the contract ends with `the guard clocked out`.

With a **second player** (`2`, no job, at the spawn):

10. Player 2: `/garde engager 1 5` → `Offer #2 sent to <you>: 5 min for 100 €$ (charged to your
    account, ...)`; short account → `Not enough eddies in your account: 100 €$ needed.` Player 1:
    `... wants to hire you as a bodyguard for 5 min (16 €$/min for you). /garde to accept` →
    `/garde` → pick **Bodyguard for <player 2>**. Stay within 15 m: `+16 €$ (minute 1/5 guarded)`.
    Player 2 `/garde fin` after 2 minutes → player 2 reads `Refund: 60 €$ for the 3 minute(s)
    nobody guarded. Cash.`
11. Player 1 guarding Afterlife, both inside the ring: hold **ALT**, click player 2, **Escort out
    (security)** → (with `open77_rp_basics` running and `rp.escort` granted) player 2 walks out
    tethered and reads `You have been escorted out of Afterlife.` at the ring. Without the kit:
    `The role-play kit (open77_rp_basics) is not running on this server: no escort, use /expulser.`
12. `/expulser 2` inside the ring → player 2 lands `zoneGeometry` radius + 20 m from the centre
    (ground height from `groundZ`; with the stale 25 m copy that is 45 m out, still inside the
    50 m `afterlife` zone of rp_zones — update `zoneGeometry.afterlife.radius` to 50 to land
    them on the Afterlife lot) and reads `Security threw you out of The Afterlife. Don't
    come back, choom.`; `/garde journal` has `... was thrown out by
    security`. Give player 2 `setjob 2 ncpd 0` + `/service` and retry: `That is an NCPD officer on
    duty. Security does not throw out badges.`
13. From another resource: `print(exports.rp_vigile:postContract("zone", "nomad_camp", 20, 0))` →
    `2` (on the board for every guard), `print(exports.rp_vigile:activeContract(1).zone)`.
