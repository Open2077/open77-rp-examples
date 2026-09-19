# rp_phone — the holophone

The phone of the Night City RP build (Open77 build `2.31.13+op77.76`): contacts, text messages
delivered even when the other side is offline, voice calls on a private channel, the city
services (NCPD, Trauma Team 911, Delamain, mechanic), location sharing and a paid ads board —
all behind a 360×640 WebUI panel opened with `/tel`.

**Server-authoritative.** The page never decides anything: every button becomes
`TriggerServerEvent("rp_phone:intent", kind, payload)`, the server validates and answers with a
throttled `rp_phone:state` push (at most one per player per 250 ms) that the page renders. The
server also owns the numbers, the voice channels, the animation the body plays and the money.

## Setup

1. Load list (`resources.load`): `open77_notifications` (declared dependency, ships a client half),
   `open77_animations`, then `rp_phone`. Reached through `pcall` and optional at runtime: `rp_inventory` (the `phone`
   item), `rp_identity` (names and citizen ids), `rp_ncpd`, `rp_trauma`, `rp_delamain`, `rp_jobs`,
   `rp_economy`, `rp_bank`. Each one missing degrades to a chat line, never to a broken resource.
2. **Numbers come from NCID.** A citizen registered in `rp_identity` (`/carte`) owns
   `555-` + their citizen id zero-padded to four digits (`rp_identity_citizens.id = 42` →
   `555-0042`). An unregistered player has **no SIM**: the phone opens, the Services tab works,
   everything else says so. Registering after login gives the number at once (`rp_identity:changed`).
3. **The item.** `/tel` needs one `phone` in the pockets (`rp_inventory`, `Config.requireItem`).
   Console: `giveitem <id> phone 1`. With `rp_inventory` not running the check is skipped and the
   log says so once per player.
4. Nothing to place in the world: every position the phone uses is the caller's own. The freeroam
   spawn is `-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`; `shared/config.lua` holds every tunable.

## The panel (`/tel`)

Bottom-right, dark, no external asset. `ESC` or the `X` closes it; focus (keyboard + cursor) is
held only while it is open, and a client watchdog releases a focus nothing owns any more. While
the panel is open the server prefers `phone_walk` (`call_walk` during a call), with
the platform's native phone and locomotion preserved. Combat, death and entering a
vehicle interrupt it. Older catalogues fall back to stationary phone workspots.
See [walking actions](../docs/walking-actions.md) for the first-person limitation.

| Tab | What it does |
|---|---|
| **Contacts** | Add by number + name, or **Scan nearby** (players within 8 m who own a number) and add them in one click. Per contact: Call, SMS, Share GPS, Remove. Stored in `rp_phone_contacts`. |
| **SMS** | Threads with an unread badge, the open thread as bubbles, reply box; a "new message" line by number. Messages are stored in `rp_phone_sms` and **delivered offline**: the recipient reads them at next login (chat line + toast "N unread"). Opening a thread marks it read. |
| **Calls** | Dial a number, recent calls (missed / declined / ended with duration). |
| **City** | One text field (what is going on) and four contacts, all sent with your rounded position: **NCPD** → `rp_ncpd:alert("phone", position, text, playerId)`; **Trauma Team** → `rp_ncpd:alert("911", …)` plus every on-duty `trauma` medic paged (`rp_jobs:listOnDuty`); **Delamain** → `exports.rp_delamain:call(playerId)`; **Mechanic** → every on-duty `mecano` paged with your position. |
| **GPS** | Pick a contact (or type a number): they get a `objective` pin on their map at your position for 120 s (client relay `rp_phone:blip`, the blip API is client-only on this build) plus a chat line. |
| **Ads** | The city board: post (50 €$, 60 min, 140 chars, 3 live ads per citizen), Call / SMS the author, remove yours. Stored in `rp_phone_ads`; expired ads leave the board within a minute. |

### Calls

1. Caller: Calls tab → number → **Call**, or `/tel appeler 555-0042`, or `/tel 555-0042`.
2. Callee reads `Incoming call from <name> (555-…). /tel accepter or /tel refuser`, gets a toast; a
   phone that is open shows the incoming-call screen (Accept / Decline). Unanswered after 30 s:
   "No answer" / "Missed call".
3. Accepted: the server creates **one private voice channel** (`Open77.voice.createChannel` mode
   `phone`, non-persistent, a narrow phone-band effect) and adds both players
   (`Open77.voice.addPlayer`, speak + listen). `/tel raccrocher`, the **Hang up** button, a
   disconnect or a resource stop removes the channel (`removeChannel`).
4. **No voice on the server** (`voice_unavailable`): the call is text-only — `/tel <text>` (or the
   line box on the call screen) writes `[CALL] <name>: <text>` to both parties. The tag works on
   voice calls too.

Whether your push-to-talk key reaches the call channel depends on the `open77_voice` transmit
intent (`proximity` only, or `all`); the devkit does not document the package's default. If a
voice call stays silent, `voice.transmit on all` in the dev console proves the channel exists.

## Commands

| Command | What it does |
|---|---|
| `/tel` | Opens the phone (needs the `phone` item); again closes it. |
| `/tel accepter` / `/tel refuser` / `/tel raccrocher` | Answer, decline or hang up the current call (`accept` / `decline` / `hangup` accepted too). |
| `/tel appeler <number>` or `/tel <number>` | Calls a number without opening the panel. |
| `/tel <text>` | While on a call: speaks on the line (`[CALL]` tag, both parties). |
| `/sms <number> <text>` | Sends a message (fallback for the panel). To yourself: refused. |
| `/contacts` | Lists your number and contacts (online ones flagged). `/contacts ajouter <number> <name>`, `/contacts supprimer <number>`. |
| `/annonce <text>` | Posts an ad (50 €$: cash first, then withdrawn from the bank account). `/annonce` alone lists the board. |

Numbers are accepted as `555-0042`, `5550042`, `0042` or `42`. Every refusal is explained in
chat: no SIM, not in service, offline, busy, no holophone, not enough eddies, and so on. From
the server console every command answers that it must be run from the game.

## Exports (server, synchronous — never yield)

```lua
exports.rp_phone:sms(fromPlayerId, toIdentifier, text)  -- true | nil, reason
--   reasons: player_not_found, invalid_identifier, not_in_service (identifier never owned a
--   number), no_sim, self, empty_text. The recipient may be offline: the row is stored.
exports.rp_phone:notify(playerId, sender, text)         -- true | nil, reason
--   a service pushes a message: it lands in the player's phone as a thread named <SENDER>
--   (e.g. "NCPD", "DELAMAIN"), with the toast and the chat line. Without a SIM the player
--   still gets the toast + chat line (true, "no_sim").
exports.rp_phone:contactsOf(playerId)                   -- { { number, name }, ... }
exports.rp_phone:numberOf(playerId)                     -- "555-0042" | nil  (bonus)
```

Call them inside `pcall` from another resource. This manifest ships a client script, so a
server-only caller may declare `dependency "rp_phone"`; a caller that also ships a client script
should rely on `pcall` alone.

## Events

| Event | Side | Payload | When |
|---|---|---|---|
| `rp_phone:sms` | host bus (`TriggerEvent`) | `(fromIdentifier, toIdentifier, text)` | every message (player or service; a service sender is `service:<SENDER>`) |

Consumed: `rp_identity:changed` (name refresh / late number), `onPlayerAnimationChanged`
(forget an ended playback). Raised for others: `rp_ncpd:alert` (kinds `phone` and `911`).

Internal net events (`rp_phone:intent`, `rp_phone:state`, `rp_phone:open`, `rp_phone:close`,
`rp_phone:blip`) are this resource's client/server transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS` (permission
`database.access`), keyed by `Open77.players.identifier` (never the session id):

| Table | Columns |
|---|---|
| `rp_phone_lines` | `number` (PK), `identifier`, `name`, `updated_at` — who owns which number, so an offline recipient can be resolved and `sms(…, toIdentifier, …)` needs no lookup |
| `rp_phone_contacts` | `identifier`, `number`, `name`, `created_at` (PK identifier + number) |
| `rp_phone_sms` | `id`, `from_identifier`, `to_identifier`, `from_number`, `to_number`, `text`, `sent_at`, `read_at` (NULL = unread) |
| `rp_phone_ads` | `id`, `identifier`, `number`, `author`, `text`, `posted_at`, `expires_at` |

The number itself is **read from `rp_identity_citizens.id`** (one `SELECT` per login, in
`pcall`); the boot log says whether that table is reachable. Everything is cached per session
and written through with the callback forms, so the exports never touch the database. Messages
of the last 300 rows per player are loaded at login; the page receives at most 20 thread
summaries and 25 messages of the open thread.

**No database** (`ready` answers `database_unavailable`, or nothing answers 15 s after start):
`Open77.kvp` is used (`lines`, `contacts:<identifier>`, `sms:<identifier>` capped at 100,
`ads`, `line:<identifier>`), numbers are handed out from `555-9001` upwards, and the log says
`falling back to Open77.kvp`.

## Honest limits

- `Open77.blips` is client-only on this build: the shared location is a client relay, so an
  offline contact cannot receive it (refused with "The line is dead").
- `Open77.animations.play` acceptance is not proof the body rendered the clip; a player seated
  in a vehicle or dead simply has no animation (`player_in_vehicle` is silent, others are logged).
- The PTT routing question above; the server side (channel + members) is what the resource owns.
- Calls exist in memory only: a resource reload ends every call (both parties are told).
- `rp_delamain:call` refuses with `no_driver` when nobody drives: the phone answers with the
  `/taxi` line of the automated cab, as `rp_delamain` does.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``RpPhoneConfig.anim` (`shared/config.lua`): two lists resolved through `Open77.animations.get`` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/tel` open | `phone` looped while the panel is open (`phonecheck` once it exists) | the profile's holo | until the panel closes |
| a call | `phone` looped while the call is active (`call` once it exists -- the old single name `call` was unknown to the 18-profile catalogue, so calls had no pose) | the profile's holo | until hang-up |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_phone] no known profile among [phonecheck,phone]: the phone is held without a pose
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.
The platform cancels the pose when the player walks; the next state push replays it, so the holo is back in the hand as soon as they stop.

## Log (grep-able)

```
[rp_phone] started: item=phone anim=phone/call ring=30s ad=50 eddies/60 min
[rp_phone] schema ready: rp_phone_lines, rp_phone_contacts, rp_phone_sms, rp_phone_ads
[rp_phone] NCID registry reachable: 12 citizen record(s) -> numbers are 555-<citizen id>
[rp_phone] store=sql lines=12 ads=1
[rp_phone] player 1 ready: number=555-0007 contacts=2 messages=14 unread=1 store=sql
[rp_phone] sms 555-0007 -> 555-0012 (23 chars)
[rp_phone] call 1: player 1 -> player 2 ringing
[rp_phone] call 1: voice channel 4 created
[rp_phone] call 1 ended: ended
[rp_phone] player 1 called NCPD from 381, -2402, 182: shots fired (dispatched=true)
[rp_phone] player 1 delamain by phone refused: no_driver
[rp_phone] player 1 posted an ad (cash, 50 eddies): Selling a Quadra
[rp_phone] database not ready (database_unavailable): falling back to Open77.kvp for phone data
```

## Test in 2 minutes (one player, freeroam spawn Kabuki Market `-1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson)`)

Player id `1`, registered at NCID (`/carte` shows `NCID #<n>`), `rp_inventory`, `rp_identity`,
`rp_economy` running. Console: `giveitem 1 phone 1`.

1. `/tel` without the item first (skip the giveitem): `No holophone in your pockets, choom.`
   With it: the panel opens bottom-right, header shows `555-<n zero-padded>` and your RP name;
   the body raises a phone. Log: `player 1 ready: number=555-0007 …`. `ESC` closes it, the body
   drops the pose. `/tel` opens it again.
2. **Contacts**: type `12` and `Rogue`, **Add** → chat `Contact added.`, the card `Rogue 555-0012`
   appears. `/contacts` lists `Your number: 555-0007. Contacts (1): 555-0012 Rogue`.
   `/contacts supprimer 12` → `Contact removed.`; `/contacts ajouter 12 Rogue` puts it back.
3. **SMS to yourself is refused**: `/sms <your own number> hello` → `Calling yourself? Even in
   Night City that is sad.` `/sms 9999 hi` → `This number is not in service.` (no citizen #9999).
   From the console (or another resource) prove delivery: `exports.rp_phone:notify(1, "NCPD",
   "Report to the precinct.")` → toast + chat `[SMS] NCPD: …`, the SMS tab shows a thread
   `NCPD` with a `1` badge; opening it clears the badge.
4. **City → Delamain** with no driver on duty → `No Delamain driver on duty. Type /taxi for the
   automated cab (short trips only).` and the log line `delamain by phone refused: no_driver`
   (`delamain_offline` when `rp_delamain` is not loaded). **City → NCPD** with `test` →
   `NCPD dispatch has your call and your position. Stay put.` — an on-duty officer (if any)
   reads `[NCPD DISPATCH] PHONE: <you> (555-…): test (… m)` from `rp_ncpd`.
5. **Ads**: type `Selling a Quadra, low mileage` → **Post** → `Ad posted for 60 min (50 €$ from
   your cash).`, the board shows it with `YOURS`, `/money` is 50 lower. With less than 50 €$ cash
   and an empty account: `Not enough eddies: an ad costs 50 €$ (cash or account).` `/annonce`
   lists the board in chat; **Remove** takes it down.
6. **Calls**, one player: dial your own number → `Calling yourself? …`; dial `12` while citizen
   #12 is offline → `The line is dead: nobody answers on that number right now.` (or `not in
   service` if #12 never connected). `/tel raccrocher` → `No call in progress.`
7. Reconnect: contacts and messages come back (`messages=… unread=…` in the log), the ad is
   still on the board.

With a second player (id `2`, registered, with a phone): `/tel 2`'s number → they read the
incoming line, `/tel accepter` → both read `Voice line open.` (or the text-only line), the log
shows `voice channel … created`; `/tel yo` → `[CALL] <name>: yo` on both; `/tel raccrocher` →
`Call ended.` on both and the Calls tab lists it with its duration. **Scan nearby** on the
Contacts tab lists player 2 within 8 m; **Share GPS** puts a pin on their map for two minutes.
