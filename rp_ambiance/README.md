# rp_ambiance — the living-city layer

Day cycle and weather, civilian figurants in the key zones, rotating server notices, NCPD
alert sirens and an ambience loop per zone, for the Night City RP build on Open77
**2.31.13+op77.76**. No exports, no SQL table, one admin command.

Dependencies: `open77_notifications`, `rp_zones` (both ship a client half). Reached at runtime
only, never required: `rp_jobs` (job-flavoured lines), `rp_bar` (skips the Afterlife loop),
`rp_config` (overrides), `open77_sound` (the loops), `open77_weather` (the clock and sky).
Permissions: `network.events`, `world.environment`, `world.npcs`, `world.effects`.

## The five layers

Every layer has its own `Config.<block>` in `shared/config.lua` and degrades on its own: a
missing platform resource logs one line and the other four keep running.

### 1. Day cycle and weather (`Config.cycle`)

- **One game day = 3 real hours.** `Open77.environment.setTimeRate(24 / realHoursPerDay)` =
  `8` game seconds per real second, which is the engine's own rate: at 8 the client projection
  never has to correct the clock. Any other value costs a world time-jump at every drift
  correction (the `setTimeRate` card measured it), so a different `realHoursPerDay` is applied
  but logged as a warning.
- **Weighted weather table**, drawn every 12–25 real minutes (`weatherMinMinutes` /
  `weatherMaxMinutes`), excluding the current preset, applied with
  `Open77.environment.setWeather(preset, 45)`. Shipped weights: clear (`sunny`) 50, `cloudy` 25,
  `rain` 15, `sandstorm` 5, `fog` 5. The sandstorm row is `badlandsOnly`: it is counted while
  `Config.cycle.badlands = true` (shipped on: Night City's vanilla cycle blows sandstorms in
  from the Badlands) and dropped otherwise. Weather is one sky per routing bucket, so
  "Badlands-only" is a map flag, not a per-zone sky.
- The platform's own random scheduler is **pinned** with `setWeatherFrozen(true)` at start so
  the two never compete, and restored to what it was when the resource stops.
- Each draw is toasted to everyone (`announceWeather`). `startHour = nil` keeps the clock where
  the server left it; a number forces that hour at start and on `/ambiance reload`.
- `environment_unavailable` (open77_weather not in `resources.load`) pauses this layer and
  retries every 30 s; the other layers run.

### 2. Figurants (`Config.figurants`)

2–3 civilian NPCs per key zone — `kabuki_market` (3, around the spawn at Market Centre
`-1191.30, 2006.88, 7.82`), `afterlife` (3, the bar floor `-1453, 1017, 16.5`), `lizzies` (2,
`-1188.9, 1566.2, 22.9`), `junkyard` (2, Rancho Coronado `1374.9, -1674.9, 49.3`) — spawned
on start around the zone centre (the centres mirror `rp_zones/shared/config.lua`;
`exports.rp_zones:list()` carries no coordinates), invulnerable (`damagePolicy = 2`), combat
disabled, `wander` within 6 m of the centre, removed on stop.

- **Lines.** While a player is within 8 m, a figurant says one of its zone's six English lines
  every 60–120 s: the text goes to every player in that radius as a chat line signed with the
  figurant's name (`Noodle Row regular`, `Afterlife regular`, `Mox bouncer`, `Scav lookout`...), and
  an audible bark (`Open77.npcs.speak` with a `voContext` from `Config.figurants.barks`:
  `greeting`, `bump`, `stlh_curious`) is queued on the body. `speak` takes engine voice contexts,
  not free text, which is why the line is chat + bark. A bark the record's voiceset lacks is
  silent and unreportable — test by ear on the records you ship.
- When `rp_jobs` runs and the nearest player holds a job listed in the zone's `linesForJob`
  (NCPD at Kabuki Market, the Afterlife and Lizzie's), that pool is used half of the time.
- **Sweep every 5 min** (`sweepSeconds`): a figurant that died, was removed or whose wander
  ended is respawned or re-tasked. `onNpcDied` / `onNpcRemoved` mark the slot immediately; a
  wander that ends is re-issued after 2 s (failures back off up to 60 s).
- **Bodies** (`Config.figurants.bodies`): `Character.Judy`, the `civilian_female_relaxed_01`
  alias (`Character.Panam`, the documented passive background body) and
  `Character.cpz_maelstrom_grunt1_ranged1_lexington_wa` with combat off. These are the three
  records with documentation provenance; swap in vanilla crowd citizens from
  `docs/generated/npc-records-2.31.csv` once tested on your clients.

### 3. Rotating notices (`Config.notices`)

Every 15 minutes (`intervalMinutes`) the next line of `Config.notices.lines` goes to everyone
through `Open77.notifications.broadcast` (top-right toast, 10 s, gold) and, with `chatEcho`,
as a chat line signed `Night City`. Eight lines ship: rules, `/carte`, `/agence`, `/zones`,
`/bank`, `/911` and `/ncpd`, the safe zone, `/report`. The first notice goes out 15 minutes
after start (`/ambiance notice` pushes one now).

### 4. NCPD alert sirens (`Config.alerts`)

On `rp_ncpd:alert (kind, position, text, byPlayerId)` the resource plays
`Open77.effects.play("sparks.burst.small", { position, range = 60, sound =
"amb_g_city_el_signals_police_siren_short_01" })` at the alert position: a server one-shot,
seen and heard **only by the players within 60 m** in that bucket, flashed 3 times 1.2 s apart
(the siren Wwise event rides the first flash). Falls back to the alerting player's position
when the event carries none; one siren per 5 m cell per 8 s. Both names are configurable — the
VFX alias is the one the platform documents for a server one-shot and the siren event is a
2.31 catalogue seed entry that still awaits runtime validation.

### 5. Ambience loop per zone (`Config.music`)

On `rp_zones:entered` of `afterlife` or `lizzies`, `Open77.sound.play(playerId,
"sfx/<file>.wav", { id = "zone:<zone>", loop = true, volume = 0.35 })` starts that zone's loop
for that player only; `rp_zones:left` stops it (`Open77.sound.stop`), the resource stopping
stops everything (`stopAll`, also sent by the host). Players already inside a zone when the
resource or `rp_zones` (re)starts are picked up through `exports.rp_zones:isIn`.

- **rp_bar is never doubled**: while `Open77.resource.state("rp_bar") == "running"` the
  Afterlife loop is skipped (`skipWhenResourceRuns`), logged once.
- **The files are the resource's own** (`files { "sfx/*.wav" }`): a resource can only play a
  file it ships, and the file is read from the client image, which is why `client/main.lua`
  exists. The two shipped WAVs (16 kHz mono, 12 s, 384 KB, seamless) are synthesised loops —
  `sfx/afterlife.wav`, a dark pad with a muffled beat and crowd murmur for the Afterlife, and
  `sfx/blackmarket.wav`, a mains hum with crackle and a scanner beep, which plays inside
  Lizzie's (the file name is an asset name, not a zone name). Replace them with real assets of
  at most 1 MiB (`mp3`, `ogg`, `wav`...), same paths.
- Not in the game's mix: it ignores the in-game volume sliders (sound guide), hence the low
  default gain.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/ambiance` or `/ambiance status` | admin (ACL `command.ambiance`) or the console | Cycle position (game time, % of the day, rate, real hours per day), the current weather, the number of draws and the time to the next one with the active table; figurants alive per zone and the next sweep; notices sent and the next one; music zones (and which one is skipped for rp_bar), listeners, siren settings. |
| `/ambiance reload` | admin / console | Re-reads the `rp_config` overrides, re-applies the cycle (rate, start hour, pin, a fresh draw), restarts the notice timer, removes and respawns every figurant, re-seeds the loops. The config file itself is read at resource start (a `restart rp_ambiance` after editing it). |
| `/ambiance weather <preset>` | admin / console | Applies a preset now (`sunny lightclouds cloudy rain heavyclouds fog pollution sandstorm`, or a `24h_weather_*` engine name) with the configured transition, toasts it, and reschedules the next random draw. |
| `/ambiance time <hour[:minute]>` | admin / console | Sets the authoritative clock for everyone (`/ambiance time 22`, `/ambiance time 6:30`). |
| `/ambiance notice` | admin / console | Sends the next notice now and restarts the 15-minute timer (test helper). |
| `/ambiance siren` | admin, in game | Plays the alert siren at your own position (test helper for layer 4; the console has no position). |

`ambiance` is registered `restricted = true`: a player needs the ACL entry `command.ambiance`;
the console always may. Every refusal is explained (unknown preset, bad hour, no weather
authority). Answers go to chat for a player and to the console for source `0`.

## Exports and events

No exports. Events consumed (host bus): `rp_zones:entered` / `rp_zones:left` (playerId, name,
kind), `rp_ncpd:alert` (kind, position, text, byPlayerId), `onNpcDied`, `onNpcRemoved`,
`onNpcTaskState`, `onPlayerDisconnected`, `onResourceStart` (own, and `rp_zones` coming back),
`onResourceStop`, `chat:ready` (net). Nothing is raised: every effect of this resource is a
platform call (environment, NPCs, notifications, effects, sound).

Optional cross-resource calls, all in `pcall`: `exports.rp_zones:list()` / `isIn`,
`exports.rp_jobs:getJob`, `exports.rp_config:get`.

## SQL tables

None. The cycle, the notices and the figurants are recomputed from `shared/config.lua` at
every start; nothing about them is durable, so there is nothing to persist.

## Configuration and overrides

Everything is in `shared/config.lua`. When `rp_config` runs, these keys override the file at
start and on `/ambiance reload`: `rp_ambiance.realHoursPerDay`, `.weatherMinMinutes`,
`.weatherMaxMinutes`, `.badlands`, `.noticeIntervalMinutes`, `.figurantsEnabled`,
`.musicVolume`, `.alertsEnabled` (`Config.overrides` maps them).

## Log (grep `[rp_ambiance]`)

```text
[rp_ambiance] weather -> cloudy over 45s (start)
[rp_ambiance] cycle: 3.0 real h per game day (rate 8.0), 5 weather rows, next draw in 17m40s
[rp_ambiance] figurants: 10/10 spawned in 4 zone(s)
[rp_ambiance] started: 8 notice(s) every 15 min, sirens on, music on (2 zone loop(s))
[rp_ambiance] ambience for afterlife skipped: rp_bar already plays there
[rp_ambiance] figurant lizzies#1 died; back at the next sweep (3m10s)
[rp_ambiance] sweep: 1 figurant(s) respawned
[rp_ambiance] environment unavailable (environment_unavailable): day cycle and weather table paused, retry in 30 s
[rp_ambiance] stopped (manual): figurants removed, weather scheduler restored
```

## Test in 2 minutes (one player)

Freeroam spawn = Kabuki Market Centre `-1191.30, 2006.88, 7.82` (Watson). The market
figurants are at your feet; Lizzie's is 440 m south, the Afterlife 1.0 km south-west (drive),
the junkyard 4.5 km south-east in the Badlands. Have `rp_zones`, `open77_notifications`,
`open77_sound`, `open77_weather` and `open77_effects` running; give yourself
`command.ambiance` (or use the console).

1. Start: the log shows `weather -> <preset>` then `cycle: 3.0 real h ... (rate 8.0)`,
   `figurants: 10/10 spawned in 4 zone(s)`, `started: 8 notice(s) ...`. Everyone gets a
   **Weather** toast top-right.
2. `/ambiance` (or `ambiance` in the console): four lines — cycle `HH:MM ... rate 8.0 ...`,
   `Weather: <preset> now (1 draw(s) so far), next draw in NNmNNs; table: sunny 50, cloudy 25,
   rain 15, sandstorm 5, fog 5`, `Figurants: 10/10 alive (afterlife 3/3, junkyard 2/2,
   kabuki_market 3/3, lizzies 2/2), next sweep in ...`, `Notices: 8 line(s) every 15 min ...`,
   `Music: afterlife, lizzies; 0 player(s) listening. Sirens: sparks.burst.small + ...`.
   With `rp_bar` running the music line reads `afterlife skipped (covered_by_rp_bar)`.
3. `/ambiance weather rain` → toast **Weather - Rain / Acid rain incoming...**, the sky blends
   over 45 s, chat `Weather set to rain; the next random draw is in ...`. `/ambiance time 22`
   → night for everyone, `Clock set to 22:00 for everyone.` (`/ambiance weather foo` →
   `Unknown preset 'foo'...`).
4. At the spawn, three market figurants stroll within 6 m of Market Centre; within a few
   seconds one of them writes in chat, e.g. `Noodle Row regular: Best synth-noodles in Watson,
   choom...`, then another line every 60–120 s while you stay. Drive 1.0 km south-west to the
   Afterlife (`-1453, 1017`, down the ramp): the **The Afterlife** entry toast from rp_zones,
   then the bar loop starts (with `rp_bar` running: no loop from this resource, rp_bar's own
   ambience instead). Three more figurants at the bar (`Afterlife regular: You buying, choom,
   or just breathing my air?`). Walk out of the 50 m `afterlife` zone: the loop stops.
5. Drive back north to Lizzie's (`-1188.9, 1566.2`, 440 m south of the market): the hum-crackle
   loop starts, the bouncer and the junkie wander and talk (`Mox bouncer: Mox rules: hands
   where we can see them...`). With an NCPD job (`setjob <you> ncpd` in the console) half of
   the lines become `Nothing to see here, officer. Just... vitamins.`
6. `/ambiance siren` anywhere: three spark flashes 1.2 s apart at your feet and the short police
   siren, `Siren played at your position for everyone within 60 m.` A real page — any resource
   raising `rp_ncpd:alert` — does the same at the alert position.
7. `/ambiance notice`: a gold **Night City** toast top-right (`Rules: no RDM, no VDM...`) and
   the same line in chat; `Notices: ... 1 sent, next in 15m00s` afterwards. Left alone, the
   next one arrives 15 minutes later.
8. The figurants are invulnerable (`damagePolicy = 2`), so a weapon cannot kill them. To
   exercise the sweep, remove or kill one with the platform's NPC admin tooling (the `npc.*`
   commands of `open77_npcs`, when your build ships them) — the log reads `figurant
   <zone>#n died; back at the next sweep (...)` or `... removed (...)`, then within 5 minutes
   `sweep: 1 figurant(s) respawned` and `/ambiance` shows the zone back at full count.
   Without such a tool, `/ambiance reload` (step 9) shows the same respawn path.
9. `/ambiance reload`: `Ambiance reloaded: cycle re-applied, figurants respawned, 0 rp_config
   override(s).` — the bodies blink and come back at their spawn points; the weather toasts
   again.
10. `stop rp_ambiance`: every figurant disappears, the loop stops for anyone inside a zone,
    the log reads `stopped (manual): figurants removed, weather scheduler restored`, and the
    platform's random weather resumes as it was before the start.

## Honest limits

- Weather is per bucket, not per zone: the sandstorm rule is a map flag (`badlands`).
- A 3-hour day is the only free day length; anything else is applied but costs time-jumps.
- `speak` plays engine voice contexts; the six lines are chat text. Whether a bark is heard on
  a given record cannot be reported by the platform.
- The siren Wwise event is a catalogue seed entry (`seed_requires_2.31_runtime_validation`);
  if it is silent, pick another from `open77_data catalogue=sfx query=siren`.
- The two WAVs are synthesised placeholders; the loop is a browser audio path outside the
  game's mix (no occlusion, no in-game volume slider).
- `/ambiance reload` re-applies the config loaded at start plus `rp_config` overrides; it does
  not re-read the file (the sandbox has no `load`), so edits need `restart rp_ambiance`.
