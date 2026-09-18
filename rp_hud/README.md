# rp_hud — the discreet RP panel

A small bottom-left WebUI panel for the Night City RP build (Open77 `2.31.13+op77.76`):
cash, bank account, job and grade with a duty dot, the three needs bars, the zone you stand
in, the server world clock, your session id and RP name. Dark glass, cyan accent, monospace
labels, 300 px wide.

The **server** assembles one snapshot per player from the other RP resources and pushes it
through one net event; the **client** owns the browser surface and only renders. Nothing is
decided or stored here — **no SQL table, no exports**.

## What to look at

```text
 VINCE ROCKER                          #3
 CASH €$ 1 250        ACCOUNT €$ 12 000
 JOB  NCPD 2/3 senior          ● ON DUTY
 HUNGER  ████████░░                  82%
 THIRST  ██░░░░░░░░                  23%   <- red and pulsing under 25 %
 FATIGUE ██████████                 100%
 ─────────────────────────────────────────
 Kabuki Market   SAFE        14:32 sunny
```

| Row | Source (server export, through `pcall`) | When it is missing |
|---|---|---|
| Name | `rp_identity:fullName` (falls back to the account name) | account name |
| `#id` | the session id (`/players`, `/id`) | — |
| Cash | `rp_economy:getBalance` | `--` |
| Account | `rp_bank:getAccount().balance` | `--` |
| Job, grade, duty dot | `rp_jobs:getJob` / `getGrade` / `onDuty` | `unemployed · no shift` |
| Hunger / Thirst / Fatigue | `rp_needs:get` | empty bars, `--` |
| Zone | `rp_zones:zoneOf` (label + kind) | `Open Night City` |
| Clock + weather | `open77_weather` client export `getState` (read on the client, ticks locally at the server's rate) | `--:--` |

The bars turn red and pulse under **25 %** (`RpHudConfig.needsWarnAt`). The clock turns amber
when the server froze the time. The duty dot is green while `/service` is on.

## Command

| Command | Where | Effect |
|---|---|---|
| `/interface` | client, answers locally | Toggles the panel. The choice is remembered for the session (until the resource or the game restarts). |
| `/interface on` / `/interface off` | client | Forces a state. |
| `/interface refresh` | client | Asks the server for a fresh snapshot right now. |

A native five-second toast confirms `RP INTERFACE: ON / OFF / REFRESHED`. `hud` is the
platform's command and is not touched.

## When the panel hides itself

Evaluated every 500 ms on the client (`RpHudConfig.visibilityPollMs`), in this order:

1. **Photo mode** (`Open77.photoMode.isActive`).
2. **The vanilla HUD is hidden**: every component in `RpHudConfig.hideWithComponents`
   (`minimap` and `health` by default) is hidden by some resource (`Open77.hud.state`). A
   gamemode that only hides the crosshair or the quest tracker keeps the panel.
3. **Cinematic mode**: `open77_uikit`'s `cinematicState().active` (freeroam `/cinematic`,
   `showCinematicBars`), asked once a second. The kit's letterbox also hides the whole vanilla
   HUD, so rule 2 catches it as well.
4. **`/interface off`**.

The browser surface is never destroyed or hidden for that: the page fades its own content
(`Open77.webui.create` warns that a `show()` racing the creation never paints, so the surface
is created visible and stays so). Native `Open77.hud.setCinematic` (op77.78+) is not used: it
does not exist on op77.76, and when a server runs a newer client it masks non-focused pages
by itself, panel included.

## Events

Consumed on the server (host bus, `AddEventHandler`): `rp_economy:changed`, `rp_bank:changed`
(ignored when `playerId` is nil: offline recipient or society), `rp_jobs:changed`,
`rp_jobs:duty`, `rp_needs:changed`, `rp_zones:entered`, `rp_zones:left`, `rp_identity:changed`.
Each one schedules a fresh snapshot for that player.

Also on the server: `onPlayerReady` (first snapshot, and a second one `joinRepushMs` = 6 s
later once the other resources have loaded their rows), `onResourceStart` of any resource in
`RpHudConfig.dependencies` (everyone is refreshed `dependencyRepushMs` = 4 s later), and a
keepalive every `refreshMs` = 30 s.

Net events (this resource's own transport, not an API):

| Event | Direction | Payload |
|---|---|---|
| `rp_hud:state` | server → client | `{ id, at, name, rpName?, cash?, account?, job? = { name, label, grade, gradeLabel, onDuty }, needs? = { hunger, thirst, fatigue }, zone? = { name, label, kind } }` — a field is absent when its resource is not running |
| `rp_hud:request` | client → server | none; `source` is the player. Sent when the page is ready and on `/interface refresh` |

**Throttle**: at most one `rp_hud:state` per `minPushIntervalMs` = 250 ms per player (4 per
second). A burst of events inside the window is coalesced into one snapshot sent when the
window closes, so a payday, a duty change and a zone crossing in the same instant cost one
packet.

Page bridge (local, not network): the client sends `config`, `state`, `visible`, `clock` to
the page with `page:send`; the page raises `ready` with `Open77.emit`.

## Files

| File | Runtime | Role |
|---|---|---|
| `open77.lua` | manifest | permissions `network.events`, `ui.vanilla.hud`; `web_files { "html/**" }`; no dependency line (see below) |
| `shared/config.lua` | both | `RpHudConfig`: cadences, visibility policy, threshold, job labels |
| `server/main.lua` | server | snapshot, throttle, consumed events, lifecycle |
| `client/main.lua` | client | the surface, `/interface`, visibility policy, clock poll |
| `html/index.html` | WebUI | the panel: inline CSS and JS, no external asset, no library |

**Why no `dependency` line.** This resource ships a client script, so its manifest is delivered
to clients — and a manifest delivered to clients may not depend on a server-only resource
(`missing_dependency` ends the session). `rp_economy`, `rp_bank`, `rp_jobs`, `rp_needs`,
`rp_zones` and `rp_identity` are therefore reached through `pcall`; a resource that is not
running simply leaves its row at `--`. `open77_weather` and `open77_uikit` are reached
through `Open77.exports.call`, which answers `nil, reason` when they are absent (the clock
retries every 15 s, the cinematic probe every 30 s).

## Configuration (`shared/config.lua`)

| Key | Default | Meaning |
|---|---|---|
| `minPushIntervalMs` | 250 | server: throttle window per player |
| `refreshMs` | 30000 | server: keepalive snapshot (0 = off) |
| `joinRepushMs` | 6000 | server: second snapshot after join |
| `dependencyRepushMs` | 4000 | server: refresh delay after a dependency restart |
| `dependencies` | the six `rp_*` names | server: which restarts trigger a refresh |
| `visibilityPollMs` / `cinematicPollMs` / `clockPollMs` / `clockRetryMs` | 500 / 1000 / 2000 / 15000 | client cadences |
| `hideWithComponents` | `{ "minimap", "health" }` | client: hide with these vanilla widgets |
| `needsWarnAt` | 25 | page: red threshold (percent) |
| `panelWidthPx` | 300 | page: width, clamped to 200..320 |
| `jobLabels` | twelve jobs + aliases | server: display label per `rp_jobs` name |

## Log lines (grep-able)

```text
[rp_hud] started: 2 player(s) online, one snapshot per 250 ms per player, keepalive every 30000 ms
[rp_hud] rp_jobs restarted, refreshing 2 panel(s)
[rp_hud] client started, page created
[rp_hud] world clock unavailable: export_resource_unavailable
```

## Test in 2 minutes

At the freeroam spawn Kabuki Market `-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`, with `rp_economy`, `rp_bank`, `rp_jobs`,
`rp_needs`, `rp_zones`, `rp_identity`, `open77_weather` and `open77_uikit` in the load list.

1. Start the server: log `[rp_hud] started: 0 player(s) online, ...`. Connect: the panel
   fades in bottom-left within a second of the world loading. Client log:
   `[rp_hud] client started, page created`.
2. Read it: your RP name (or account name) and `#<id>`, `CASH €$ 500` for a new wallet,
   `ACCOUNT €$ 0`, `unemployed · no shift`, three full cyan bars, `Kabuki Market SAFE`
   (the zone label as rp_zones gives it, the kind in small caps; you spawn inside `kabuki_market`, the 70 m safe zone around Kabuki Market Centre), the clock ticking (12:00 at boot, at open77_weather's
   `timeScale` — 4 game seconds per real second by default, so a minute passes every 15 s).
3. `/interface` → the panel fades out, toast `RP INTERFACE: OFF`. `/interface` again → back.
4. Server console: `givemoney <id> 1000` → `CASH` reads `€$ 1 500` within 250 ms.
   `setneeds <id> 80 20 60` → the thirst bar turns red and pulses at `20%`.
   `setjob <id> ncpd 2` → `NCPD 2/3 senior`, grey dot. `/service` → green dot, `ON DUTY`.
5. Walk 70 m out of the market (the South Gate alley at `-1218, 1950` is 63 m from the
   centre, a few more metres down the street does it) → the zone row reads `Kabuki DISTRICT`
   (the 420 m `kabuki` zone around the market); go down to the Lower Walkway dealer
   (`-1201.07, 2035.60, 5.60`, 30 m north, under the market — an rp_shops stall, not a zone,
   still inside `kabuki_market`) → `Kabuki Market SAFE`; walk back up → `Kabuki Market SAFE`.
6. `/cinematic` (freeroam) → the panel is gone with the HUD; `/cinematic off` → back.
   Open photo mode (if a resource exposes it) → gone; close it → back.
7. Server console: `weather.time.set 23:58` → the clock jumps to `23:58` within 2 s and
   rolls over to `00:00` two game minutes later; `weather.time.freeze` → the clock turns
   amber and stops; `weather.time.resume` → it runs again.
8. Reload `rp_needs` (Warden's reload, or `ensure rp_needs` at the console after an edit):
   4 s later the server log reads `[rp_hud] rp_needs restarted, refreshing 1 panel(s)` and
   the bars show the reloaded values. With a resource that is not in the load list at all,
   its row stays at `--` (bars empty, `unemployed`, `Open Night City`) and nothing errors.
9. Two clients: each panel shows its own id and name; a `/pay` between them updates both
   `CASH` rows.
