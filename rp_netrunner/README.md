# rp_netrunner — hacking contracts

The netrunner job of the Night City RP build (Open77 build `2.31.13+op77.76`): a tracking
**ping**, **Short Circuit** and **Overheat** uploads through the platform's hacking kit, a
**jammer** that turns the NCPD radio into static, and an **access point** to breach for a door or
a data bounty. Every contract needs the job `netrunner` (rp_jobs v2) **on duty**, burns one
quickhack item (rp_inventory) and has a 30 s cooldown per kind; with a 50 % chance it leaves a
**trace** — an entry in the netrunner's NCPD record and a dispatch alert at the spot.

**Server-authoritative.** The client only draws the ping blip where the server says, shows the
ALT+click entries while the server says the player is an on-duty netrunner, and forwards the
access-point prompt as an intent. Job, duty, items, cooldown, distance, target life and the deck
are checked on the server for every command and every ALT+click request.

## Setup

1. Load list (`resources.load`): `open77_contextmenu`, `open77_uikit`, `open77_worldui`
   (declared dependencies, all ship a client half), **`open77_hacking`** (the platform's hacking
   presentation package, auto-start system resource: without it the victim cannot be warned and
   every upload fails closed), `open77_cyberware` + `open77_appearance` (the implant framework
   and the character adapter that binds a player to a durable record), a configured database,
   `rp_jobs` v2, `rp_inventory`, `rp_ncpd`, `rp_economy`, `rp_bank`, optionally `rp_identity`
   and `open77_doors` (all reached through exports inside `pcall` / `Open77.exports.call`, each
   degrades to a chat line when missing).
2. Job: `setjob <id> netrunner 3` from the console, then `/service` in game.
3. Quickhacks: `giveitem <id> qh_ping 1`, `giveitem <id> qh_short_circuit 1`,
   `giveitem <id> qh_overheat 1`, `giveitem <id> qh_jammer 1`, `giveitem <id> chip 1` (the data
   chip the breach burns). The four `qh_*` items are declared through
   `exports.rp_inventory:define` at start and again whenever `rp_inventory` restarts; they are
   contraband (`illegal = true`), so an NCPD search finds them.
4. The deck: `/netrun deck short_circuit` installs the netrunner operating system
   (`rp_netrunner.deck`, slot `operating_system`, profile `cyberdeck`) on the on-duty netrunner —
   free by default (`Config.deck.price`). The two hack commands do it for you when the wrong
   grade is loaded and ask you to run the command again once the implant is committed.
5. Positions live in `shared/config.lua`: the access point sits in **the Afterlife's back room**
   (the safe area, `-1419.9, 989.4, 16.6`; inside the rp_zones `afterlife` zone), 1.0 km
   south-west of the freeroam spawn (Kabuki Market Centre `-1191.30, 2006.88, 7.82`), with a
   data-terminal prop 1.2 m behind the ring. **If the ring is invisible**, stand on the spot,
   `/pos`, and paste the ground height into `Config.accessPoint.position.z`.

## Commands (all need job `netrunner` + on duty, except `/netrun` alone)

| Command | What it does |
|---|---|
| `/netrun` | Status: job/duty, the implant check (no OS / netrunner deck loaded with `<grade>` / a foreign implant in the OS slot / framework unavailable and why), quickhacks and chips in the pockets, cooldowns left, the platform's own gates on you (suspended cyberware, blind...), contracts done (SQL count, by kind), and whether the NCPD radio is jammed. |
| `/netrun deck <short_circuit\|overheat>` | Loads that grade into your operating system (a cyberware install; `Deck ready: ...` when committed). |
| `/ping <playerId>` | Burns a `qh_ping`: a `Ping: <name>` map pin follows the target for 60 s on **your** map (position relayed by the server every 2 s). Target within 50 m. ALT+click a player > **Ping** does the same. |
| `/court_circuit <playerId>` | Burns a `qh_short_circuit` and starts the platform's **Short Circuit** upload (`Open77.hacking.start`): 2 s upload, 25 dmg electrical hit, 750 ms disruption, 4 s recovery, nonlethal, 25 m and line of sight (the kit's shared-evidence trace). ALT+click > **Short Circuit**. |
| `/surchauffe <playerId>` | Burns a `qh_overheat` and starts the **Overheat** upload: 2.5 s upload, 10 dmg hit then a 40 dmg burn over 5 s (500 ms ticks), 25 m, line of sight. ALT+click > **Overheat**. |
| `/brouiller` | Burns a `qh_jammer`: for 60 s `rp_netrunner:jammed(true)` is raised and every on-duty NCPD officer reads a `[NCPD RADIO]` static line every 15 s; `rp_netrunner:jammed(false)` at the end. The trace (if any) surfaces when the static clears. One jammer at a time server-wide. |
| `/breach` | At the access point (within 4 m; or look at the ring and press **E**): a 10 s **Breaching...** bar (movement and fire blocked, **X** aborts), then one `chip` is burned and the nearest `open77_doors` door within 15 m is unlocked and opened; with no door the node's data is sold instead: **+200 €$** cash (`rp_economy`) and **+100 €$** to the `netrunner` society (`rp_bank`). |

Refusals are explained in chat: not a netrunner, off duty, flatlined, cooldown with the time left,
no quickhack in the pockets, out of range with the distance, unknown player, hacking yourself,
deck not loaded / loading / foreign implant, framework offline, the kit's own refusal token
(`Short Circuit refused: <reason>`), no access point here (with the nearest one), bar never opened,
breach aborted. From the server console every command answers `run it from the game`.

The hack outcome comes back from the platform's ledger (`onHackingTransition`): `Short Circuit
landed on <name>.`, or `Short Circuit blocked (<reason>).` / `interrupted (<reason>)` — Self-ICE,
lost line of sight, the victim hurting you, a safe area. The quickhack is burned when the upload
starts, not when it lands.

### The deck, honestly

`Open77.hacking.start` requires the actor to **own the matching installed implant grade**, and an
implant holds **one grade** in the `operating_system` slot; a grade has **one** `kind`. So the
netrunner deck is one definition with two grades (`short_circuit`, `overheat`) and only one of
them is loaded at a time. `/court_circuit` with the Overheat grade loaded stages the reload
(`Loading Short Circuit into your deck... run the hack again when it says 'Deck ready'.`), which
is a real cyberware transaction (the owner's client equips the item, then the record is
committed). Reading the installed implant is the server-side `Open77.cyberware.current(player)`;
the guide documents only the `arms` / `legs` fields of the record, so the resource looks for
`record.operating_system` first and otherwise for any implant table whose `slot ==
"operating_system"`. When `current` answers `nil` (no database, no character adapter) the
resource says so and the two kit hacks are refused — ping, jam and breach keep working on the job
gate alone.

## ALT+click (open77_contextmenu)

Hold **ALT**, click a player: **Ping** (50 m), **Short Circuit**, **Overheat** (25 m). Shown only
while the server says you are an on-duty netrunner (`rp_netrunner:self`, pushed on connect and on
every `rp_jobs:duty` / `rp_jobs:changed`); the server checks everything again on
`rp_netrunner:action`.

## Exports (server, synchronous — never yield)

```lua
exports.rp_netrunner:isJamming()        -- boolean: the NCPD radio is jammed right now
exports.rp_netrunner:trace(playerId)    -- { entries = { { kind, target, at }, ... } } newest first, last 50
```

`trace` reads the in-memory cache of the connected netrunner's `rp_netrunner_log` rows (`kind` is
`ping` / `short_circuit` / `overheat` / `jam` / `breach`, `target` the victim's durable identifier,
`door:<id>`, `bounty` or empty, `at` unix seconds). Call them inside `pcall`; a resource **with** a
client script must not declare `dependency "rp_netrunner"` (this manifest is delivered to clients).

## Events (host bus)

```lua
-- raised here:
AddEventHandler("rp_netrunner:jammed", function(active) end)   -- true at the start of a jam, false at its end
-- (rp_ncpd may consume it to replace its own [NCPD RADIO] lines and mute its dispatch voice
--  channel while active; it does not yet. This resource cannot intercept rp_ncpd's chat, so it
--  sends the static lines itself to rp_jobs:listOnDuty("ncpd").)

-- raised towards rp_ncpd when a contract leaves a trace (Config.traceChance):
--   exports.rp_ncpd:addRecord(netrunner, "netrunner", "<kind> at <x>, <y>", 0)
--   TriggerEvent("rp_ncpd:alert", "netrunner", { x, y, z }, "Netrunning activity detected", 0)
```

Internal net events (`rp_netrunner:action`, `rp_netrunner:breach`, `rp_netrunner:clientReady`,
`rp_netrunner:self`, `rp_netrunner:ping`, `rp_netrunner:pingUpdate`, `rp_netrunner:pingEnd`,
`rp_netrunner:requestDoor`, `rp_netrunner:doorResult`) are this resource's client/server
transport, not an API.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS` (permission
`database.access`), keyed by `Open77.players.identifier` (never the session id):

```sql
rp_netrunner_log (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    netrunner VARCHAR(64) NOT NULL,      -- the netrunner's durable identifier
    kind      VARCHAR(32) NOT NULL,      -- ping | short_circuit | overheat | jam | breach
    target    VARCHAR(64) NOT NULL DEFAULT '',   -- victim identifier, door:<id>, bounty, or ''
    `at`      BIGINT      NOT NULL DEFAULT 0,    -- unix seconds
    INDEX rp_netrunner_log_netrunner (netrunner, `at`)
)
```

The last 50 rows and the row count of a player are read on `onPlayerReady` (and for everyone
connected on a hot start); every contract is written through with the callback form of
`Open77.database.insert`, so the exports never touch the database. **No database** (`ready`
answers `database_unavailable`, or nothing answers 15 s after the first player is ready):
`Open77.kvp` (`log:<identifier>`, last 50 entries as JSON), the log says `store=kvp reason=...`,
and the choice is kept for the whole boot. Cooldowns, pings and the jam are in memory only.

## What the door service needs

`open77_doors` (system resource, `open77_elevators` with it, client and server `op77.58`+) keeps
an in-memory registry of the doors the clients **discovered** within 80 m, per routing bucket.
The breach calls its server exports: `near(position, bucket, 15)` for the nearest non-lift door,
then `setLocked(id, bucket, false)` + `setOpen(id, bucket, true)`; when the service answers
`not_owner` the resource claims the door (`register`) and releases it 30 s later (`remove`), and
if it still refuses, the client queues the player's own `requestOpen(id, true)` and reports
`open77:doors:requestResult`. So a door must have been **discovered by a client standing near it**
(or registered by another resource) before a breach can find it. The access point is in the
Afterlife's back room, so whether a door is found depends on what the clients have **discovered**
around it (the bar's own doors are within reach only once someone has walked past them) and on
`open77_doors` being loaded: otherwise the log says `no door within 15 m` (or `door service
unavailable (<reason>)`), and the data bounty is paid instead — that is the expected outcome then.

## Honest limits

- **Line of sight is the kit's** shared-evidence model (both clients trace the segment); the
  resource only checks distance. A blocked upload is reported, the quickhack stays burned.
- The access-point terminal is `Open77.props.create` with the curated prop alias
  `electronics.server` (see `prop.catalog`; a raw `.mesh` path renders as a white slab); an
  `invalid_model` falls back to `Config.accessPoint.prop.fallbackModel` (the same alias), and a
  second refusal leaves the ring alone to mark the spot (logged). Set `Config.accessPoint.prop.model = false` to spawn nothing.
- The jammer does not touch rp_ncpd's dispatch **voice** channel: voice channels are owned by the
  resource that created them (`Open77.voice.*` is resource-scoped) — `rp_netrunner:jammed` is the
  hook for rp_ncpd to mute it.
- `Open77.hacking.state` shows the gates on the netrunner in `/netrun`; there is no server read of
  "quickhacks a deck can run" beyond the grade installed.
- The ping blip is positional (the server relays the target's position every 2 s), not attached
  to the target's entity: it works even when the target is not streamed on the netrunner's client.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``Config.Stage` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/breach`, E on the access point | `phone` two-hand tap, looped (`laptop` / `tablet2` once they exist -- `laptop` ships its own laptop, drop the `prop` line then) | `electronics.monitor` held in front of the chest, screen towards the runner (`electronics.laptop` once it exists) | 10 s bar (`breach.durationMs`) |
| `/ping` | `phone` one-shot (`phonecheck`) | the profile's holo | 3 s |
| `/brouiller` | `phone` one-shot (`phonecheck`) | the profile's holo | 4 s |
| `/court_circuit`, `/surchauffe` | none of ours: the platform's own upload owns the body (`Open77.hacking.start`) | -- | the grade's `uploadMs` |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_netrunner] player 3 stage breach: pose=phone/stand__2h_phone__03__tap_phone__01 prop=electronics.monitor@root place=none 10000 ms -> ok
[rp_netrunner] player 3 gesture ping: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 3000 ms
[rp_netrunner] player 3 gesture jam: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 4000 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Log (grep-able)

```text
[rp_netrunner] started: job netrunner, cooldown 30 s, trace chance 50%, access point -1419.9 989.4 16.6
[rp_netrunner] store=sql table=rp_netrunner_log
[rp_netrunner] deck rp_netrunner.deck v1 defined: short_circuit, overheat
[rp_netrunner] quickhacks registered=4 rejected=0
[rp_netrunner] access-point terminal prop 123456 at -1419.9 990.6 16.5
[rp_netrunner] player 1 deck grade=short_circuit installed
[rp_netrunner] player 1 ping target=<identifier>
[rp_netrunner] trace player 1 ping at -1191, 2007
[rp_netrunner] player 1 short_circuit target=<identifier>
[rp_netrunner] jam started by player 1 for 60000 ms
[rp_netrunner] jam ended
[rp_netrunner] breach by player 1: no door within 15 m, paying the data bounty
[rp_netrunner] player 1 breach target=bounty
```

## Manifest

Permissions: `network.events`, `database.access`, `players.hacking.define` / `.read` /
`.activate`, `players.cyberware.define` / `.read` / `.manage`, `players.life.read`, `world.props`
(server); `ui.vanilla.map` (client). Dependencies: `open77_uikit` (the bar, server twin
`progress`), `open77_worldui` (the access point), `open77_contextmenu` (ALT+click) — all ship a
client half. `rp_jobs`, `rp_inventory`, `rp_ncpd`, `rp_economy`, `rp_bank`, `rp_identity` and
`open77_doors` are reached through exports and never declared.

## Test in 2 minutes

One client at the freeroam spawn (Kabuki Market Centre `-1191.30, 2006.88, 7.82`), id `1`; `rp_jobs`, `rp_inventory`,
`rp_economy`, `rp_bank`, `rp_ncpd` running. Log on start: `[rp_netrunner] started: ...`,
`store=sql table=rp_netrunner_log`, `deck rp_netrunner.deck v1 defined: short_circuit, overheat`,
`quickhacks registered=4 rejected=0`.

**Alone (breach + jam + /netrun):**

1. `/netrun` → `NETRUN - not a netrunner.`, then the implant line, `Pockets: ... x0`, `Cooldowns:
   all clear`, `Contracts done: 0 (store: sql)`.
2. Console: `setjob 1 netrunner 3`, `giveitem 1 qh_jammer 1`, `giveitem 1 chip 1`. Player 1:
   `/service` (rp_jobs). `/breach` from the spawn → `No access point here (1047 m). The nearest
   one is at -1420, 989.`
3. Drive 1.0 km south-west to the Afterlife, down the ramp, through the bar to the back room
   (map pin `Access point — Afterlife back room`, a server prop behind the ring when the alias
   resolves). Look at the ring, press **E** (or `/breach` within 4 m) → `Jacking in... hold
   still (X aborts).`, a 10 s **Breaching...** bar at the bottom, you cannot walk. Press **X** →
   `Breach aborted. The ICE never saw you.`; the chip is still in `/inv`. Again, let it finish →
   either a bar door within 15 m is unlocked and opened (when a client has discovered one), or
   `No networked door on this subnet. You siphon the node's data instead: +200 eddies (data
   bounty).` `/money` went up by 200, `/societe` for a netrunner shows `+100`, the chip is gone,
   and one time in two `TRACE WARNING: NCPD ICE logged your signature.` (log `trace player 1
   breach at -1420, 989`). `/breach` again → `Breach is cooling down: 29 s left.`
4. `/brouiller` → `Jammer live: NCPD radio is static for 60 s.` (`qh_jammer` gone). With an
   on-duty officer connected they read a grey `[NCPD RADIO] kzzzt--- ...all units...` line every
   15 s; `exports.rp_netrunner:isJamming()` from another resource is `true`; the log shows
   `jam started by player 1`. After a minute: `Jammer burned out. NCPD radio is clear again.` and
   `rp_netrunner:jammed(false)` on the bus.
5. `/netrun deck short_circuit` → `Loading Short Circuit into your deck...` then `Deck ready:
   Short Circuit loaded.` (needs the database + `open77_appearance`; otherwise `Your implant
   record is not ready ...`). `/netrun` now reads `Implant: netrunner deck loaded with Short
   Circuit.`, `Contracts done: 2 - jam 1, breach 1`.
6. Reconnect: `/netrun` still counts 2 contracts (SQL); `exports.rp_netrunner:trace(1)` lists
   both entries newest first.

**With a second player (id `2`, within 25 m, in view):**

7. Console: `giveitem 1 qh_ping 1`, `giveitem 1 qh_short_circuit 1`, `giveitem 1 qh_overheat 1`.
   Player 1: `/ping 2` (or hold **ALT**, click player 2, **Ping**) → `Ping on <name>: tracked on
   your map for 60 s.`; open the map: a `Ping: <name>` pin on player 2 that follows them for a
   minute, then `Ping on <name> faded.`
8. `/court_circuit 2` (or **Short Circuit**) → `Short Circuit uploading on <name> (8 m). Keep
   line of sight: the kit warns them.` Player 2 sees the native `INCOMING SHORT CIRCUIT` bar and
   the chat warning; two seconds later player 1 reads `Short Circuit landed on <name>.` and
   player 2 takes the electrical hit. Step behind a wall during the upload → `Short Circuit
   interrupted (...)`.
9. `/surchauffe 2` → `Loading Overheat into your deck... run the hack again when it says 'Deck
   ready'.`, then `Deck ready: Overheat loaded.`, `/surchauffe 2` again → the upload, then
   `Overheat landed on <name>.` and player 2 burns for 5 s. `/surchauffe 2` at once →
   `Overheat is cooling down: 27 s left.`
10. Player 2 as an on-duty officer: `/casier 1` shows the `[NETRUNNER] <kind> at <x>, <y>` entries
    the traces left, and they saw `[NCPD DISPATCH] NETRUNNER: Netrunning activity detected` with a
    pin for each trace.
