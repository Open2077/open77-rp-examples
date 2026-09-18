# rp_jobs v2 — grades, bosses, duty, societies and payroll

Server-authoritative jobs for an Open77 RP server (build `2.31.13+op77.76`). Replaces the
phase-0 `rp_jobs` in place: the `getJob` / `hasJob` exports and the `rp_jobs:changed` event are
kept, the courier run is gone (see "Removed from v1" at the end).

A player holds **one job** with a **grade 0..3** (`recruit`, `employee`, `senior`, `boss`), can
clock in and out (`/service`), and is paid **in cash** from the job's **society** (`rp_bank`)
every 10 minutes while on duty. Civil jobs are joined at the **employment agency** (a ring and an
E prompt by the spawn); the others are staffed by their **boss** (ALT+click or `/embaucher`) or
by an admin (`/setjob`).

## The twelve jobs

| name | label | joined how | salary per payroll (grade 0 / 1 / 2 / 3) | tag colour |
|---|---|---|---|---|
| `ncpd` | NCPD | boss or admin | 300 / 450 / 600 / 800 €$ | blue |
| `trauma` | Trauma Team | boss or admin | 300 / 450 / 600 / 800 €$ | red |
| `delamain` | Delamain | agency | 200 / 300 / 400 / 550 €$ | yellow |
| `mecano` | Mechanic | agency | 200 / 300 / 400 / 550 €$ | orange |
| `ripper` | Ripperdoc | boss or admin | 250 / 400 / 550 / 750 €$ | purple |
| `nomade` | Nomad | agency | 180 / 260 / 360 / 500 €$ | sand |
| `ferrailleur` | Scrapper | agency | 150 / 220 / 300 / 420 €$ | grey |
| `barman` | Bartender | agency | 150 / 220 / 300 / 420 €$ | pink |
| `fixer` | Fixer | boss or admin | 250 / 400 / 550 / 750 €$ | cyan |
| `netrunner` | Netrunner | boss or admin | 250 / 400 / 550 / 750 €$ | green |
| `vigile` | Security guard | agency | 180 / 260 / 360 / 500 €$ | steel |
| `gang` | Gang | **reserved** (nobody may hold it yet) | 0 | — |

Everything above is `shared/config.lua` (`RpJobsConfig.Jobs`, `.Grades`, `.PayrollIntervalMs`,
`.SocietyStartingFund`, `.HireDistance`, `.Agency`, `.NameplateMaxDistance`). The legacy names
`police`, `medecin` and `taxi` are aliases of `ncpd`, `trauma` and `delamain` (accepted by
`hasJob`, `setJob`, `listOnDuty`, `salary` and `/setjob`), so `rp_medic`, `rp_inventory`
(`implant_box` for a `medecin`) and `eval_taxi` keep working.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/jobs` | anyone | The job board: every job, whether it is an agency job, and **who is on duty** in it. Yours is marked `[yours]`. |
| `/job` | anyone | Your file: job, grade (`2/3 senior`), `ON DUTY` / `off duty`, your salary, and the **society balance** (`rp_bank`). |
| `/service` | employees | Clock in / clock out. Refused without a job. Your on-duty colleagues are told; your tag appears over your body for everyone else. |
| `/agence` | anyone | The employment agency menu (UI kit context menu): join a civil job, resign from your current one, or leave. Works within `Agency.reach` (12 m) of the agency ring; set `reach = 0` to allow it anywhere. |
| `/embaucher <playerId> [grade]` | boss | Hires the player into your job as `grade` 0 (recruit), 1 or 2 — never 3. The target must be **within 5 m** and jobless. ALT+click a player > **Hire into <job>** does the same at grade 0. |
| `/virer <playerId>` | boss | Fires an employee of your job. They are told. |
| `/promouvoir <playerId> <grade>` | boss | Sets an employee's grade 0..2. `3` **hands over the boss seat**: they become boss, you step down to senior. |
| `/setjob <playerId> <job\|none> [grade]` | admin (ACL `command.setjob`) or the console | Gives or removes a job, any grade 0..3. The first time a job gets a boss this way, its society is **seeded** with `SocietyStartingFund` (50 000 €$) through `rp_bank`. |

Every player-facing refusal is explained in chat: no job, not the boss, too far (with the
distance), already employed elsewhere, unknown player, reserved job, invalid grade. From the
server console, `/jobs` `/job` `/service` `/agence` `/embaucher` `/virer` `/promouvoir` answer
`run it from the game`; `setjob` answers in the console.

Player ids are the session ids (`/players`). Names in chat come from `rp_identity` (`fullName`)
when it runs, else from the account name.

## Duty, tags and payroll

- Duty is in memory only. It is **cleared on disconnect** and when the resource stops; a player
  who comes back is off duty (and told they still hold the job).
- While on duty, every *other* client draws your nameplate as `[NCPD] Vince Rocker` in the job
  colour (`Open77.nameplates.set`, `maxDistance` 40 m). The nameplate API only overrides remote
  players, so you never see your own tag. The server broadcasts the roster; clients only render.
- **Payroll** runs every `PayrollIntervalMs` (10 min): for every on-duty employee,
  `exports.rp_bank:societyRemove(job, salary, "payroll")` then
  `exports.rp_economy:add(playerId, salary, "salary")`. A dry society pays nothing and the
  employee reads `No payroll this time: the NCPD society is dry.`; if the wallet refuses, the
  society is refunded. One log line per payment.
- The society starts empty. `/setjob <id> <job> 3` seeds it once per job (flag kept in the
  resource's kvp store: `seeded:<job>`). Fines, bills and sales from the other resources feed it
  afterwards.

## Exports (server, synchronous, never yield)

```lua
exports.rp_jobs:getJob(playerId)               -- "ncpd" | nil
exports.rp_jobs:hasJob(playerId, "police")     -- true | false   (aliases: police, medecin, taxi)
exports.rp_jobs:getGrade(playerId)             -- { level = 2, label = "senior" } | nil
exports.rp_jobs:isBoss(playerId)               -- boolean
exports.rp_jobs:onDuty(playerId)               -- boolean
exports.rp_jobs:setJob(playerId, "trauma", 1)  -- true | nil, reason
exports.rp_jobs:setJob(playerId, nil)          -- true (job removed)
exports.rp_jobs:listOnDuty("ncpd")             -- { 3, 7 }  (player ids, ascending)
exports.rp_jobs:salary("ncpd", 2)              -- 600
```

`setJob` reasons: `invalid_player_id`, `player_not_found`, `not_loaded` (the file is still being
read), `unknown_job`, `reserved_job` (`gang`), `invalid_grade`. `getJob`/`getGrade` answer `nil`
and `hasJob`/`isBoss`/`onDuty` answer `false` for a player whose file is not loaded.

They read the in-memory cache only. Call them inside `pcall` from another resource (a
synchronous export raises when the resource is missing). A resource **without** a client script
may declare `dependency "rp_jobs"`; a resource with one must not (this manifest is delivered to
clients, and `rp_jobs` itself ships a client script).

## Events (host-wide bus, `TriggerEvent`)

```lua
AddEventHandler("rp_jobs:changed", function(playerId, jobName) end)       -- jobName is nil when the job was removed
AddEventHandler("rp_jobs:duty",    function(playerId, jobName, onDuty) end) -- onDuty is a boolean
```

`rp_jobs:duty (…, false)` is raised before `rp_jobs:changed` when an on-duty player changes or
loses their job, with the **old** job name.

Internal net events (`rp_jobs:clientReady`, `rp_jobs:agency`, `rp_jobs:hire`, `rp_jobs:plate`,
`rp_jobs:roster`, `rp_jobs:self`) are this resource's client/server transport, not an API.

## Persistence

Table created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`:

```sql
rp_jobs_employees (
    identifier VARCHAR(64) PRIMARY KEY,   -- Open77.players.identifier, never the session id
    job        VARCHAR(32) NOT NULL,
    grade      TINYINT     NOT NULL DEFAULT 0,
    on_duty    TINYINT(1)  NOT NULL DEFAULT 0,   -- informative: cleared on disconnect and on stop
    hired_at   BIGINT      NOT NULL DEFAULT 0,   -- unix seconds
    hired_by   VARCHAR(80) NOT NULL DEFAULT ''   -- the boss's identifier, "agency", "console", "admin:<identifier>", "export"
)
```

A row exists only while the player holds a job (`none` deletes it). The file is read on
`onPlayerReady` (and for everyone already connected on a hot start); every change is written
through with the callback forms, so the exports never touch the database. A failed SQL read is
never treated as "no job": the player is told to reconnect.

**No database** (`ready` answers `database_unavailable`, or the database still is not answering
15 s after the first player is ready): records fall back to `Open77.kvp` (key
`emp:<identifier>`), the log says `[rp_jobs] store=kvp reason=...`, and the choice is kept for
the whole boot.

## Log (grep-able)

```text
[rp_jobs] job board prop 123456 at -1172.3 2088.3 11.9
[rp_jobs] started: 12 jobs, payroll every 10 min, agency at -1173.1 2087.4 11.9
[rp_jobs] store=sql table=rp_jobs_employees
[rp_jobs] player 3 loaded job=ncpd grade=3 (sql)
[rp_jobs] player 3 job=ncpd grade=3 (setjob by console)
[rp_jobs] society ncpd seeded +50000 balance=50000
[rp_jobs] player 3 duty=on job=ncpd (player_request)
[rp_jobs] player 4 job=ncpd grade=0 (hired by player 3)
[rp_jobs] payroll player 3 ncpd grade=3 +800 cash=1300 society=49200
[rp_jobs] player 4 duty=off job=ncpd (disconnected)
```

## The agency POI

`RpJobsConfig.Agency.position = { x = -1173.12, y = 2087.44, z = 11.94 }` — **The Gallery**, the
elevated walkway at the north end of Kabuki Market, 83 m north-east of the freeroam spawn
(Kabuki Market Centre `-1191.30, 2006.88, 7.82`; walk north past The Arch and up the steps):
a ring, a map pin and an `E` prompt (`open77_worldui`, `promptDistance = 3.0`,
`style = "interaction"`), plus a **job-board terminal** the server spawns 1.2 m behind the ring
(`Open77.props.create`, the curated prop alias `electronics.monitor.device` — see
`prop.catalog` —, removed on stop; a refusal only logs). `z` is the walked height — if the ring is not visible, stand on the spot,
`/pos`, and paste the ground height. The Gallery is outside the `kabuki_market` safe zone (70 m)
and inside the `kabuki` district. The prompt fires `rp_jobs:agency`; the server checks the
distance again (`Agency.reach`) before opening the menu, so the client cannot open it from
anywhere.

## Manifest

Permissions: `network.events`, `database.access`, `ui.nameplates`, `world.props`. Dependencies:
`open77_uikit` (the agency menu, server twin `context`), `open77_worldui` (the POI),
`open77_contextmenu` (the hire action) — all three ship a client half. `rp_bank`, `rp_economy`
and `rp_identity` are server-only and reached through `pcall`: without `rp_bank` payroll and
`/job`'s balance say the bank is offline; without `rp_economy` the society is refunded and the
employee told; without `rp_identity` account names are used.

## Test in 2 minutes

Two clients at the freeroam spawn (Kabuki Market Centre), ids `1` and `2`; `rp_bank`, `rp_economy` and (optionally)
`rp_identity` running. Log on start: `[rp_jobs] started: 12 jobs, ...` then `[rp_jobs]
store=sql table=rp_jobs_employees`.

1. **Console:** `setjob 1 ncpd 3` → console `Player 1 (...) is now boss at NCPD.`, player 1 reads
   `An admin made you boss at NCPD. /service to clock in.`, log `society ncpd seeded +50000`.
2. Player 1: `/job` → `Job: NCPD (ncpd) - grade 3/3 boss - off duty.`, `Salary: 800 €$ per
   payroll ...`, `Society NCPD: 50 000 €$.`
3. Player 1: `/service` → `Clocked in at NCPD as boss. 0 colleagues on duty. ...` Player 2 now
   sees `[NCPD] <name>` in blue over player 1's body. `/jobs` on player 2 lists `NCPD (ncpd): on
   duty: <name>`.
4. Player 1 stands 10 m from player 2: `/embaucher 2` → `Too far away (10 m). Get within 5 m to
   hire someone.` Walk next to them, hold **ALT**, click player 2, pick **Hire into NCPD** (or
   `/embaucher 2 1`) → player 1 `You hired <name> at NCPD as recruit.`, player 2 `Welcome to
   NCPD, choom: ... /service to clock in.`
5. Player 2: `/service` → both are on duty; player 1 reads `<name> clocked in (NCPD, recruit).`
6. Player 1: `/promouvoir 2 2` → player 2 is `senior`. `/promouvoir 2 3` → player 2 becomes
   boss, player 1 reads `You handed the NCPD boss seat to ... You are now senior.`
   Player 2: `/virer 1` → player 1 reads `... fired you from NCPD. Hand in your badge, choom.`
   and `/service` now answers `No job, no shift. /agence to find one.`
7. Player 1 walks 83 m north to The Gallery (map pin `Employment agency — Kabuki Gallery`, a
   terminal behind the ring), looks at the ring, presses **E** (or types `/agence` within 12 m):
   from the spawn `/agence` answers `The employment agency is 83 m away (the ring and map pin on
   the Kabuki Gallery walkway). Walk over.` The menu lists Delamain, Mechanic, Nomad, Scrapper,
   Bartender, Security guard with their pay. Pick **Delamain** → `Signed: you now work for
   Delamain as recruit.` `/agence` again: Delamain is greyed out, **Resign from Delamain** is
   offered.
8. Wait for the payroll tick (10 min, or lower `PayrollIntervalMs` in `shared/config.lua` for the
   test): the on-duty boss reads `Payday from NCPD: +800 €$ as boss. Cash: ...`, log `payroll
   player 2 ncpd grade=3 +800 ...`; player 1's Delamain society is empty, so on duty they read
   `No payroll this time: the Delamain society is dry.`
9. Disconnect player 2 and reconnect: `Welcome back: you still work for NCPD as boss.`, off duty,
   the tag is gone for everyone until the next `/service`.
10. From another resource: `print(exports.rp_jobs:getJob(2), exports.rp_jobs:isBoss(2),
    exports.rp_jobs:hasJob(2, "police"))` → `ncpd true true`.

## Removed from v1

`/mission` and `/stopmission` (the courier run, its van and its waypoints) are **gone**: the
courier job is replaced by `rp_nomade` later in this phase. The v1 job names `livreur`, `taxi`,
`medecin`, `police` map to nothing / `delamain` / `trauma` / `ncpd`; a v1 KVP job file is not
migrated (v1 saved under `job:<identifier>`, v2 uses SQL or `emp:<identifier>`).
