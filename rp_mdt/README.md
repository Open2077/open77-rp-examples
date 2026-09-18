# rp_mdt — the NCPD / Trauma Team tablet

A WebUI **mobile data terminal** for the Night City RP build (Open77 `2.31.13+op77.76`): a
900×600 dark panel — NCPD blue for the police, Trauma red for the medics — opened with `/mdt`
by an officer or a medic **on duty**. It reads what the other resources already know
(identity, criminal records, warrants, fines, plates, gun licences, Trauma contracts, bills,
the audit log) and lets the officer act on it through the same exports the chat commands use.

**Server-authoritative.** The **server decides the mode** from `rp_jobs` (`ncpd` → police
tablet, `trauma` → medical tablet), re-checks duty on **every** page action, and is the only
side that reads or writes anything. The page renders and requests: every click is an
`rp_mdt:intent` net event the server answers with `rp_mdt:data`. A client that lost its badge
gets its tablet closed on the next click.

No exports (by contract). One table of its own: `rp_mdt_reports`.

## Files

| File | Runtime | Role |
|---|---|---|
| `open77.lua` | manifest | permissions `network.events`, `database.access`; `web_files { "web/**" }` |
| `shared/config.lua` | both | modes, tabs, colours, panel size, caps, warrant levels, record kinds |
| `server/main.lua` | server | duty gate, mode, every lookup and action, reports, dispatch cache |
| `client/main.lua` | client | creates the WebUI page hidden, shows/hides it on the server's word, relays intents |
| `web/index.html` | WebUI | the tablet page, no external asset (inline CSS/JS, system font) |

Dependencies: **none declared** on purpose — this manifest ships a client script, so it must
not depend on a server-only resource (`missing_dependency`). `rp_jobs`, `rp_identity`,
`rp_ncpd`, `rp_trauma`, `rp_garage` and `rp_logs` are reached through `pcall`'d synchronous
exports (`Open77.exports.callSync`) and every missing one degrades to an **"… offline"** line on
the tablet, never to a crash. Without `rp_jobs` nobody can open the tablet at all (no badge
check, no tablet).

## Commands

| Command | Who | Effect |
|---|---|---|
| `/mdt` | job `ncpd` or `trauma` (`rp_jobs`), **on duty** | Opens the tablet in the mode the server picked. The page takes keyboard and mouse (`page:setFocus(true, true)`). |
| `/mdt fermer` (or `/mdt close`) | same | Puts the tablet away. **Escape** and the **×** button do the same from the page. |

Refusals in chat: `No badge, no tablet, choom…`, `Your job has no tablet…`, `Clock in first
(/service)…`, `The job roster (rp_jobs) is offline…`. From the server console `mdt` prints the
store, the open tablets and the alerts kept. Clocking out (`rp_jobs:duty … false`), losing the
job (`rp_jobs:changed`) or disconnecting closes the tablet.

## The tabs (the server decides which ones exist)

NCPD: **Citizens · Vehicles · Reports · Dispatch · Net traces**. Trauma Team: **Citizens ·
Medical · Reports · Dispatch** (911 calls only).

### Citizens

Search by **name** (substring) or **citizen id** (`1` or `#1`); a plain number also matches a
**session id**. Connected players are found through the exports (works without a database);
everybody else comes from the civil registry table. Click a hit → the file:

- **Identity**: name, NCID, born / sex / origin, account name, online + session id, `DOWN`
  badge, Trauma Team contract (`rp_trauma:hasContract`, else `rp_trauma_contracts`).
- **NCPD mode only**: **Warrant** (`rp_ncpd:wanted`, else `rp_ncpd_warrants`) with a **Set /
  update warrant** form (level 1–5 + reason → `rp_ncpd:setWanted`) and **Lift warrant**
  (`setWanted(…, 0)`); **Unpaid fines** (`rp_ncpd_fines WHERE paid_at = 0 AND remaining > 0` —
  rp_ncpd stores `paid_at` as `BIGINT NOT NULL DEFAULT 0`, never NULL; total);
  **Criminal record** (`rp_ncpd:record`, else `rp_ncpd_records`) with an **Add to record** form
  (kind `report / warning / arrest / seizure / note` + text → `rp_ncpd:addRecord(…, byPlayerId)`);
  **Vehicles** (`rp_garage:vehiclesOf`, else `rp_garage_vehicles`) with the WANTED flag; **Gun
  licence** (`rp_shops_licences`).
- **Trauma mode only**: **Unpaid Trauma Team bills** (`rp_trauma_bills WHERE paid_at IS NULL`).
- **MDT reports on this citizen** (click → full text) and a **File report** form attached to
  that NCID.

Every block prints `<registry> offline (<reason>)` when neither the export nor the table
answered, so an empty section is never mistaken for a clean one.

### Vehicles (NCPD)

Search by **plate** (`NC-XXXX`, with or without the prefix) or **owner name**: plate, model,
owner (with a `file` button to the citizen), state (`stored / out / impounded` + reason), WANTED
flag with its reason. **Flag stolen** (optional reason → `rp_garage:setWanted(plate, true,
reason)`: every officer on duty gets rp_garage's APB line) and **Clear**. Without a database
only the vehicles of **connected** owners are searchable (`vehiclesOf` per player).

### Reports (both modes, separate per mode)

Free-text reports in `rp_mdt_reports`: title, body, an optional citizen (attached from the
citizen file, or typed as a free name), author (RP name), date. Search over title, text,
citizen and author. Police reports and medical reports are stored with `mode` and never shown
to the other side.

### Dispatch

The last **20** `rp_ncpd:alert (kind, position, text, byPlayerId)` events seen on the bus
since the resource started (robberies from `rp_shops`, `911` calls from `rp_trauma`, whatever
`rp_crime` raises…), newest first, with the caller's RP name, the time, the rounded position and
**your distance** to it (`Open77.players.position` of the viewer at refresh time). Medics only
see the `911` kind (`Config.modes.trauma.dispatchKinds`). The list is memory only: a restart
empties it.

### Medical (Trauma)

Who is **down** right now (`rp_trauma:isDown` over every connected player, with distance and
the `/reanimer <id>` hint), **contract holders online**, **unpaid bills** for everybody
(`rp_trauma_bills` joined with the civil registry for the names, click → the citizen file), and
the **last revives** from `rp_logs:query({ kind = "rp_trauma:revived" })` — or `Logs offline`.

### Net traces (NCPD)

`rp_logs:query({ kind = "rp_netrunner", limit = 30 })`: jamming, traces, breaches — or `Logs
offline (rp_logs is not running)`.

## Exports and events

**No exports.** Events:

| Event | Side | Payload | Role |
|---|---|---|---|
| `rp_mdt:intent` | client → server (`TriggerServerEvent`) | `{ action = "…", … }` | every page action; the server re-checks duty, then answers |
| `rp_mdt:data` | server → client | `{ kind = "citizen_search" \| "citizen_card" \| "vehicle_search" \| "reports" \| "report" \| "dispatch" \| "medical" \| "nettrace" \| "notice", … }` | the answer, forwarded to the page as-is |
| `rp_mdt:open` / `rp_mdt:close` | server → client | `{ mode, label, title, tabs, officer, store, panel }` / `()` | show / hide the page |

These are this resource's transport, not an API. Consumed from the bus: `rp_ncpd:alert`,
`rp_jobs:duty`, `rp_jobs:changed`, `onPlayerDisconnected`, `chat:ready`, `onResourceStart` /
`onResourceStop`. Raised: nothing. When `rp_logs` runs, every lookup and action is written to it
(`exports.rp_logs:log`) under `rp_mdt:lookup`, `rp_mdt:warrant`, `rp_mdt:record`,
`rp_mdt:plate`, `rp_mdt:report`.

Page ↔ client bridge: the page emits `ready`, `intent` and `close` through
`window.Open77.emit`; the client sends `open`, `close` and `data` through `page:send`.

## Persistence

Created inside `Open77.database.ready(...)`, permission `database.access`, keyed by the durable
`Open77.players.identifier` (never the session id):

```sql
rp_mdt_reports (
    id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    mode        VARCHAR(8)  NOT NULL,         -- ncpd | trauma
    author      VARCHAR(64) NOT NULL,         -- identifier of the officer / medic
    author_name VARCHAR(80) NOT NULL,         -- RP name at the time of writing
    target      VARCHAR(64) NOT NULL DEFAULT '',   -- identifier of the citizen, '' when none
    target_name VARCHAR(80) NOT NULL DEFAULT '',
    title       VARCHAR(80) NOT NULL,
    text        TEXT        NOT NULL,         -- 2000 characters max
    at          BIGINT      NOT NULL,         -- unix seconds
    KEY (mode, at), KEY (target)
)
```

Reads are done with the `.await` forms inside the net-event handler (a managed task); nothing
is awaited inside an export because there is none. **No database** (`ready` answers
`database_unavailable`, or nothing answers 15 s after start): reports live in the resource's
`Open77.kvp` store (`reports` as JSON, the last 100 / 60 KB, `nextId`), the citizen and plate
searches are limited to **connected** players, fines / licences / bills / offline warrants read
as `offline`, and the log says `[rp_mdt] store=kvp reason=...`. The choice is kept for the boot.

### Read-only couplings (documented, never written)

No export covers these, so the tablet issues plain `SELECT`s on the sibling tables. Each read
is wrapped in `pcall`: a table that does not exist (the resource never ran) shows as
`offline (sql_error)` and nothing else breaks.

| Table (owner) | Read for |
|---|---|
| `rp_identity_citizens` (rp_identity) | citizen id, name, birth/sex/origin of **offline** citizens; search by name / NCID |
| `rp_ncpd_warrants`, `rp_ncpd_records`, `rp_ncpd_fines` (rp_ncpd) | warrant / record of an offline citizen; **unpaid fines** for everybody (no export exists) |
| `rp_garage_vehicles` (rp_garage) | plate search; the vehicles of an offline citizen |
| `rp_shops_licences` (rp_shops) | the NCPD gun licence (no export exists) |
| `rp_trauma_contracts`, `rp_trauma_bills` (rp_trauma) | contract of an offline citizen; unpaid bills |

Writes always go through the owner's export: `rp_ncpd:setWanted`, `rp_ncpd:addRecord`,
`rp_garage:setWanted`. Those exports work on **connected** citizens only (session ids), which
is why the tablet refuses to set or lift a warrant, or to add a record entry, on an offline
citizen — file an MDT report instead.

## Log (grep-able)

```text
[rp_mdt] started: modes ncpd (5 tabs) / trauma (4 tabs), panel 900x600, dispatch keeps 20 alerts, db grace 15s
[rp_mdt] store=sql table=rp_mdt_reports
[rp_mdt] player 1 opened the ncpd tablet
[rp_mdt] player 1 set warrant L2 on player 2 (abcd123456): armed robbery
[rp_mdt] player 1 lifted the warrant on player 2 (abcd123456)
[rp_mdt] player 1 added a [warning] record entry on player 2
[rp_mdt] player 1 flagged plate NC-K7P2 wanted=true reason=hit and run
[rp_mdt] player 1 filed ncpd report #3: Market brawl
[rp_mdt] store=kvp reason=database_unavailable (reports in Open77.kvp, citizen directory limited to connected players)
```

## Test in 2 minutes (one player, freeroam spawn Kabuki Market `-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`)

Load `rp_jobs`, `rp_identity`, `rp_ncpd`, `rp_trauma`, `rp_garage`, `rp_logs`, `rp_shops`
(optional, for the licence) and `rp_mdt`. Start log: `[rp_mdt] started: …` then `store=sql …`.
Register your citizen record if the form pops (`rp_identity`).

1. `/mdt` without a job → `No badge, no tablet, choom…`. Console: `setjob 1 ncpd 3`. `/mdt`
   again → `Clock in first (/service)…`. `/service` → `/mdt` → chat `NCPD tablet online.
   Escape or /mdt fermer to put it away.` and the blue **NCPD // MOBILE DATA TERMINAL** panel
   opens with your RP name, grade and session id top right; the mouse is free.
2. **Citizens**: type your own name (or `1` — your session id) → **Search** → one row, `online`,
   with your NCID. Click it → your file: identity, `No open warrant`, `Nothing owed`, `Clean
   sheet`, your vehicles (if you bought one at the dealership: `/concession`), `No NCPD gun
   licence on file` (buy one at the gun shop, `/acheter licence`, and **Refresh**: `licensed`),
   `no contract`.
3. **Add to record**: kind `warning`, text `jaywalking on Noodle Row` → toast `Record entry
   [warning] added on <you>.` and the entry appears in the record with your name as officer.
   `/casier 1` in chat shows the same entry (it went through `rp_ncpd:addRecord`).
4. **Set warrant**: level `2`, reason `test warrant` → toast, `WANTED L2 test warrant` badge,
   chat line from rp_ncpd (`NCPD has a warrant on you (level 2)`), `/ncpd` lists it. **Lift
   warrant** → `No open warrant`.
5. **File report** from your file: title `Market check`, body anything → toast `Report #1
   filed`. **Reports** tab: the row (author = you, about = you); click → full text. **New
   report** with a free "About" name → a second row; search `Market` → one hit.
6. **Second citizen id**: search `Vince` or `#1` (the bot **Vince Kovac** is citizen #1 when
   the eval server's registry is seeded). If he is **connected**, his file offers Set / Lift
   warrant and Add to record exactly like yours; if he is **offline**, the file still shows
   identity, warrant, fines, record, vehicles and licence from SQL, and the two NCPD forms answer
   `Citizen offline: the NCPD registry only sets warrants on connected citizens.` — file an MDT
   report on him instead (it is attached to his NCID). If no second citizen exists, the search
   answers `No citizen matches "Vince"` and this step is skipped.
7. **Vehicles**: with a dealership car, type its plate (or `NC`) → the row with you as owner
   (`online`). **Flag stolen** with reason `hit and run` → toast, `WANTED hit and run`, chat APB
   from rp_garage, `/plaque` next to the car shows the flag. **Clear** → `clean`.
8. **Dispatch**: empty at first. In chat `/911 shots fired at the market` (rp_trauma raises
   `rp_ncpd:alert("911", …)`), back in the tablet **Refresh** → the row with `911`, your name,
   the position and `0 m`. Walk 30 m and refresh: the distance follows you.
9. **Net traces**: `Logs offline` if `rp_logs` is not loaded, else the recent `rp_netrunner`
   rows (empty until a netrunner does something). `/logs mdt` in chat (restricted) shows the
   tablet's own audit rows (`rp_mdt:lookup`, `rp_mdt:warrant`, …).
10. **Escape** → the panel closes, chat `Tablet put away.` is not printed (page close is silent);
    `/mdt fermer` → `Tablet put away.` / `Your tablet was not open.`. `/service` (clock out)
    while the tablet is open → it closes with `Off duty: tablet locked.`
11. **Trauma mode**: console `setjob 1 trauma 3`, `/service`, `/mdt` → the red **TRAUMA TEAM //
    MEDICAL DATA TERMINAL** with Citizens · Medical · Reports · Dispatch. **Medical**: `Nobody is
    down`, contract holders, `Everybody paid` (or your hospital bill after a `/suicide` +
    `/respawn`), last revives. Your citizen file now shows the bills instead of the criminal
    record; the police reports of step 5 are **not** listed (separate mode). Dispatch only lists
    the `911` calls.
12. Reconnect: `/mdt` → Reports still lists everything (SQL). Check the row:
    `SELECT id, mode, author_name, target_name, title, at FROM rp_mdt_reports;`.

## Honest limits

- **Offline citizens are read-only for the NCPD forms**: `rp_ncpd:setWanted` / `addRecord` and
  `rp_garage:vehiclesOf` take session ids. The tablet says so and offers the MDT report.
- The Dispatch list starts empty at every resource start (memory only, by design of the plan).
- The `at` columns of the sibling tables are passed through untouched: the page formats a
  number as a UTC date and prints a string (a `DATETIME`) as-is.
- The WebUI `menu` layer is used for the panel; `hud` is the layer the scaffolder uses for
  overlays. Both are documented as valid layers without a permission; if the panel ever paints
  under another surface, switch `layer` in `client/main.lua`.
- Escape reaches the page only while it holds the keyboard (it does: `setFocus(true, true)`).
  `/mdt fermer` is the fallback.
- Payloads travel in one network event each (48 KiB envelope): the caps in
  `Config.limits` (15 hits, 20 record entries, 30 reports, 30 log rows) exist for that reason.
