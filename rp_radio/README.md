# rp_radio - handheld radio (voice + text)

A pocket radio for the Night City RP server. `/radio 95.5` tunes the handheld to a
frequency; everyone on the same frequency shares one Open77 **voice channel**
(`mode = "radio"`, radio-style filter and noise) and one text band (`/radio dire`).
Hold the radio key (**CAPSLOCK** by default, rebindable) to talk into the channel;
the platform's own push-to-talk (`N`, open77_voice) keeps driving proximity voice.

The server decides everything: who may tune (a `radio` item in the pockets; the
right job on duty for a reserved band), which channel exists (one per frequency in
use, created lazily, removed when the last listener leaves), who has signal (the
Badlands cut) and what a netrunner jam does to the band.

Build: `2.31.13+op77.76`. Server-only kits it talks to (through `pcall`, never as a
manifest dependency, because this resource ships a client script): `rp_inventory`
(`has`), `rp_jobs` (`hasJob`, `onDuty`, `listOnDuty`), `rp_zones` (`isIn` + the
`rp_zones:entered/left` events), `rp_netrunner` (`isJamming` + `rp_netrunner:jammed`),
`rp_config` (optional overrides).

## Commands

| Command | What it does |
|---|---|
| `/radio` | Status: the frequency you are on, its state (`voice + text`, `text only`, `NO SIGNAL (Badlands)`, `JAMMED`) and who is on the band with signal. Off the air it prints the dial range and the reserved bands. |
| `/radio <freq>` | Tunes `87.5`-`108.0` in `0.1` steps (`95.47` snaps to `95.5`). Needs a `radio` item (`rp_inventory`). Leaves the previous frequency, joins the voice channel of the new one (created on the spot when nobody was there), tells you how many others are on it. Reserved bands need the matching job **on duty**. |
| `/radio off` | Leaves the band; the channel is removed when you were the last one. |
| `/radio dire <text>` | Text fallback: `[RADIO 95.5] Name: text` (orange) to everyone tuned to your frequency with signal, you included. Garbled while a jam is live. |
| radio key (`CAPSLOCK`, hold) | Client push-to-talk into your radio channel only (`Open77.voice.setTransmitting(true, "channel:<id>")`). Not tuned, or no signal: a native toast says so and nothing is sent. Rebind it in Pause > Settings > KEY BINDINGS ("Radio push-to-talk"). |

Refusals are explained in chat: no radio in the pockets, out-of-band frequency,
reserved band (wrong job / off duty), inventory or job registry offline, no signal,
no text. From the server console the command answers with a `print` and does nothing.

### Reserved bands (`shared/config.lua`, `Config.reserved`)

| Frequency | Band | Who |
|---|---|---|
| `100.0` | NCPD dispatch | **Owned by `rp_ncpd`**, not by this resource (see below). |
| `101.0` | Trauma Team | `trauma`, on duty |
| `102.0` | Mechanics | `mecano`, on duty |
| `103.0` | Nomad convoy | `nomade`, on duty |

Going off duty (`rp_jobs:duty(..., false)`) or losing the job (`rp_jobs:changed`) while
tuned to a reserved band switches the radio off with a line. Losing the last `radio`
item (`rp_inventory:changed` with a negative delta) does the same.

**Why 100.0 is not a channel here.** `rp_ncpd` already runs its own "NCPD dispatch"
voice channel and puts its on-duty officers on it. Open77 voice channels belong to the
resource that created them (`Open77.voice.addPlayer` on another resource's channel is
refused; the API is not name-addressable across resources), so rp_radio cannot join
players to that channel and must not create a second one. `/radio 100.0` therefore
answers *"100.0 is NCPD dispatch: the precinct runs that channel itself (rp_ncpd),
officers are patched in while on duty"* and leaves your dial where it was. The only
thing rp_radio does on 100.0 is text: `exports.rp_radio:broadcast(100.0, text)` delivers
the `[RADIO 100.0]` line to `rp_jobs:listOnDuty("ncpd")`.

## Badlands cut

`rp_zones:entered(playerId, "badlands")` removes the player from their voice channel and
prints **No signal out here. Your radio only hisses.**; they stay tuned (the dial does not
move) but receive nothing, `/radio dire` is refused and the radio key toasts "no signal".
`rp_zones:left` puts them back on the channel (**Signal is back. 95.5 crackles to life.**).
Tuning while already inside the zone tunes without signal.

**The spawn is in Watson** (Kabuki Market Centre `-1191.30, 2006.88, 7.82`, inside the
`kabuki_market` safe zone) and the `badlands` zone of rp_zones is the polygon east of x 900
(the Aldecaldos camp, the junkyard, the oil fields), so `badlandsCut` only matters east of
x 900 — nobody at the spawn is ever cut. The cut still ships **off by default**
(`Config.badlandsCut = false`); set it to `true` (or the `rp_config` key
`rp_radio.badlandsCut`) to silence radios past the city limits. `Config.cutZone` names the
zone.

## Jam (`rp_netrunner:jammed`)

While a netrunner jammer is live (`/brouiller`, 60 s):

- every player tuned with signal reads a grey static line (`[RADIO 95.5] kzzzt--- ...`)
  every `Config.jam.staticIntervalMs` (15 s), the first one immediately;
- every live channel's effect is patched server-side (`Open77.voice.updateChannel`: gain
  0.6, distortion 0.35, radioNoise 0.6), and channels created during the jam are born
  with it;
- every tuned client lowers its local channel gain to `Config.jam.localGain` (0.5) with
  `Open77.voice.setChannelVolume` - a **client-only** native, so the server asks each
  client through the `rp_radio:client` net event;
- `/radio dire` lines are garbled (`Config.jam.garbleText`, ASCII bytes only).

`rp_netrunner:jammed(false)` restores the effect and the local gain and prints
`carrier is back. Band is clear.` on every channel. `exports.rp_netrunner:isJamming()` is
read once at start so a restart during a jam starts jammed.

## Exports (server, synchronous, never yield)

```lua
exports.rp_radio:channelOf(playerId)         -- 95.5 | nil   (second value: signal boolean)
exports.rp_radio:broadcast(95.5, "All units") -- delivered count | nil, reason
```

`channelOf` answers the frequency as a number (`95.5`, `101`) and whether the player
currently has signal (`false` inside the Badlands cut or when voice is offline for
them). `broadcast(frequency, text)` prints `[RADIO <freq>] text` (no author) to everyone
tuned with signal; on the external `100.0` slot it goes to the on-duty NCPD roster.
Reasons: `invalid_text`, `invalid_frequency:not_a_number`, `invalid_frequency:out_of_band`,
`roster_unavailable` (rp_jobs down, 100.0 only). Call them inside `pcall` from another
resource.

## Events

```lua
-- raised here (host-wide bus, TriggerEvent):
AddEventHandler("rp_radio:tuned", function(playerId, frequency) end) -- frequency is nil on /radio off, disconnect, forced drop

-- consumed here:
--   rp_zones:entered / rp_zones:left (playerId, name, kind)   -> the Badlands cut
--   rp_netrunner:jammed (boolean)                             -> static + lowered channel
--   rp_jobs:duty (playerId, job, onDuty) / rp_jobs:changed    -> reserved bands follow the job
--   rp_inventory:changed (playerId, itemId, delta)            -> no radio, no band
```

`rp_radio:client` (server -> client, `kind, key|false, channelId|false, jammed`) is this
resource's own transport for the key and the local gain, not an API.

## Persistence

Table `rp_radio_tuning` (created in `Open77.database.ready`, `CREATE TABLE IF NOT EXISTS`):

| Column | Type | Meaning |
|---|---|---|
| `identifier` | `VARCHAR(64)` PK | `Open77.players.identifier(playerId)` (durable, never the session id) |
| `frequency` | `VARCHAR(8)` NULL | last dial position, e.g. `95.5`; `NULL` after `/radio off` |
| `updated_at` | `BIGINT` | unix seconds |

Writes are write-through with the callback form (`Open77.database.update`, upsert);
the export never touches SQL. On `onPlayerReady` the row is read (`single.await` in the
handler), the resource waits `Config.rememberDelayMs` (4 s) for `rp_inventory` to load the
pockets, then re-tunes silently if the player still holds a radio and may use the band:
**Radio back on 95.5 (hold CAPSLOCK to talk).** Set `Config.rememberFrequency = false` to
start every session off the air.

While the database is not ready the dial is kept in the resource's `Open77.kvp` store
(`tuning:<identifier>`) and the log says so once.

## Configuration (`shared/config.lua`)

`band` (min/max/step), `requireItem` + `itemId`, `reserved`, `effect` (channel DSP),
`jam` (effect patch, `localGain`, `staticIntervalMs`, `garbleText`, `garbleRatio`),
`badlandsCut` + `cutZone`, `rememberFrequency` + `rememberDelayMs`, `maxTextLength`,
`ptt` (`id`, `name`, `key`), `colors`, `staticLines`. `requireItem`, `badlandsCut` and
`rememberFrequency` may be overridden live through `rp_config` (`rp_radio.<key>`).

## Voice notes

- Needs `voice.enabled` in `server.jsonc`. If `Open77.voice.status()` or
  `createChannel` answers `voice_unavailable`, tuning still works in **text-only** mode
  and says so (`Voice is offline (...): text only`).
- The radio key sends the `channel:<id>` intent, so a player who is also on rp_ncpd's
  dispatch channel does not spill the radio into dispatch. Releasing the radio key calls
  `setTransmitting(false)`, which also ends a proximity talkspurt held at the same moment
  (the native has one transmit state); the next `N` press restores it.
- Membership is `canSpeak = true, canListen = true` for everyone on the band; there is no
  listen-only tuning.

## Test in 2 minutes (one player, freeroam spawn Kabuki Market `-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`)

1. Connect. Note your id (`/id`). Give yourself the handheld: `/giveitem <id> radio 1`
   (rp_inventory). Console log: `[rp_radio] voice ready (quality standard)` and
   `[rp_radio] started: 87.5-108.0 MHz, cut zone badlands (off), PTT CAPSLOCK`.
2. `/radio` -> `Radio: off. /radio <87.5-108.0> to tune, then hold CAPSLOCK to talk or
   /radio dire <text>.` and `Reserved: 100.0 NCPD dispatch, 101.0 Trauma Team, ...`.
3. Press **CAPSLOCK** -> native toast *No radio tuned. Type /radio <frequency>.*
4. `/radio 95.5` -> orange `Tuned to 95.5. Hold CAPSLOCK to talk, nobody else on the band
   yet.` Log: `[rp_radio] channel 95.5 created (<id>)`.
5. `/radio` -> `Radio: 95.5 - voice + text.` then `On the band (1): <your name>`.
6. `/radio dire hello` -> `[RADIO 95.5] <your name>: hello` (orange) in your own chat.
7. Hold **CAPSLOCK** and speak: the open77_voice HUD shows `TRANSMITTING` (a second
   player on `/radio 95.5` hears you with the radio filter; alone you only see the state).
8. `/radio 101.0` -> red `101.0 is Trauma Team only. Not your band, choom.` (still on 95.5).
   `/radio 100.0` -> the rp_ncpd explanation, dial unchanged. `/radio 120` -> `Out of band...`.
9. `/radio 88.1` -> `Tuned to 88.1...`; log `channel 95.5 removed (empty)` then
   `channel 88.1 created`.
10. `/radio off` -> `Radio off.`; log `channel 88.1 removed (empty)`.
11. Memory: `/radio 95.5`, disconnect, reconnect -> about 4 s after spawn: `Radio back on
    95.5 (hold CAPSLOCK to talk).` (needs the database; otherwise the kvp fallback line
    in the log).
12. Jam (needs an on-duty netrunner with a `qh_jammer`, or a second session): `/brouiller`
    -> every tuned player reads a grey `[RADIO 95.5] kzzzt--- ...` line every 15 s,
    `/radio` says `JAMMED`, `/radio dire hello` arrives garbled; after 60 s
    `[RADIO 95.5] ---kzzt... carrier is back. Band is clear.`
13. Badlands cut: set `Config.badlandsCut = true`, reload; drive east past x 900 (the
    junkyard at `1375, -1675` or the Aldecaldos camp at `1793, 2249`): crossing the zone edge
    prints `No signal out here...` and drops you from the channel, driving back west
    `Signal is back...`. Nothing changes at the Kabuki spawn, which is far outside the zone
    (see above).
