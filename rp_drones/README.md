# rp_drones

A drone light show. Two dozen lights hang in the night sky, ignite, and morph
between a ring, a heart and the **77** — and every player watching sees the
same shape in the same place at the same instant.

About 950 lines of server Lua and 430 of commentary, a generated table of points, and no client code
at all, which is the point of the example.

## Read this before you fly it

This resource has been flown in game twice, and both runs failed. They failed
in ways no amount of reading the API could have predicted, and almost
everything below is a consequence of one or the other:

**Run 1 — the whole show was invisible.** Forty-eight `kind = "light"` drones
spawned, projected and were logged by the client, 80 m out and 50 m up, and the
player saw an empty sky. Two independent causes, both since confirmed in the
platform's source:

- The light host entity is cloned from a loot crate and inherits that crate's
  authored **`autoHideDistance = 50`**. The asset build raises it to 200 on
  every *mesh* host and never touches the light host, so the renderer culls a
  light drone past fifty metres whatever `streamingRadius` says. That is an
  asset defect and this resource cannot patch it.
- Worse, and more fundamental: **a point light has no body.** It only
  illuminates other geometry inside `radius`, and `radius` was 10 m on a drone
  50 m up with nothing near it. With `scaleVolFog` and `useInFog` both zero on
  the host there is no airborne halo either. A `kind = "light"` drone in empty
  sky renders zero pixels at any distance.

**Run 2 — the show disconnected its audience.** Switched to the VFX style, the
client died eight seconds into the opening morph with
**`send_failed:LimitExceeded`**, and the server log carried no error at all,
because the ceiling is on the transport and is invisible from Lua.
GameNetworkingSockets clamps every connection to **256 KB/s** and the transport
turns the resulting `LimitExceeded` into a **disconnect**, not a dropped packet,
once 512 KB has queued behind the clamp. Forty-eight effect drones at 15 Hz is
415 KB/s. The link had about eight seconds to live, and that is exactly how long
it lasted.

So: the drone is now a **VFX**, the stage is **closer**, there are **24** of
them instead of 48, and the update rate is no longer configured at all — it is
*derived* from a byte budget, and a show that will not fit is refused before a
single drone is spawned.

## Why the server flies it

Every drone is a server-owned entity. The server owns its identity, its routing
bucket and **every position it ever holds**. A client is told where the swarm
is; it never decides.

The tempting shortcut is to hand each client the formation list and let it walk
its own timers. That works for a single effect fired once, and it falls apart
for a fifteen-second morph: each client's clock is its own, so two players
standing side by side end up watching two different pictures. A show is a shape
*and* a moment, and only one authority can own both.

## Using it

```
/droneshow                  the default show, in front of you
/droneshow rehearsal        the short one — fly this first, every time
/droneshow heart 180        a named show, thrown 180 degrees the other way
/droneshow stop             recall the swarm now
/droneshow probe            hang ONE drone where the picture will be
/droneshow probe next       try the next candidate effect
/droneshow probe off        take it down
/droneshow npcprobe         spawn ONE real drone NPC and measure the drift
/droneshow npcprobe next    try the next drone record
/droneshow npcprobe off     recall it
/droneshow npcmove          fly that one drone and measure whether it moved
/droneshow npcmove off      stop it
/droneshow playtest         PLAY TEST flies into OPEN 77, then the parade (effect style)
/droneshow choreo hybrid    npc style: lights fly, bodies hold
/droneshow choreo flipbook  npc style: redraw between figures
/droneshow stop <show>      take one show down; bare `stop` takes all
/droneshow status           what is flying, and the motion headroom
/droneshow lightbench       one photograph, every candidate light
/droneshow choreo cut       npc style: hold, blackout, cut
/droneshow frame <ms>       the sequence frame, for bisecting it
/droneshow sweepguard on    allow vanilla traffic so the sweep skips the drones
/droneshow style light      switch styles (and read the warning below)
```

The command is **restricted**: the platform checks `command.droneshow` against
the caller's ACL before the handler runs, so this resource contains no rights
logic of its own. Grant it to the roles that should have it.

From the dedicated console, which has no body and therefore no position:

```
droneshow rehearsal <x> <y> <z> [yaw] [bucket]
```

From another resource:

```lua
exports.rp_drones:playFor(playerId, "open77")
exports.rp_drones:play("heart", { x = -1426.0, y = 974.0, z = 23.6 }, 0, 180.0)
exports.rp_drones:stop()
```

Each answers `true`, or `false` and a reason in plain English — the reason is
written to be shown to a player.

## The probe, and why it exists

**Which VFX reads as a point of light at 45 m against a night sky is the one
question about this resource that cannot be answered by reading code.** Every
candidate is an asset authored for something else — a laser mine, a loot
beacon, a parade shell — and the two distance measurements that exist in this
platform's research disagree with each other: the AV landing pad pixel-letters
a sixty-dot sign out of `laser.mine` and it reads fine from a cockpit, while
`neon.loot_drop` was photographed as "unmistakable at 5 m" and "at most a faint
speck" at twenty.

So `/droneshow probe` hangs **one** drone at the exact centre of where the
picture will be and does not move it. One entity, no bandwidth, nothing that
can disconnect anybody. `probe next` walks the candidate list in
`drone.probes`; `probe <alias> <metres>` pins a specific one at a specific
distance, which is how you find where a candidate stops reading.

Pick the winner, put it in `drone.effect`, then fly the rehearsal.

## Real drone NPCs: cut to shape

2.31 ships nineteen flying `Character.*` drone records and `Open77.npcs.create`
takes one straight. Two things about them are now measured **on screen**, not
inferred from the canonical record, and between them they decide the whole
design of this style.

### The hold works — confirmed visually, 2026-09-20

A drone spawned at 10 m, with `stage.facing` set to the player's own yaw so it
landed in his line of sight, was captured on his screen: a real drone body, dark
hull, lit eye, hanging in the air over a Kabuki overpass with nothing under it.
A 30 m run reported `drift 0.00 m` over thirty seconds with a client projecting
it.

**The engine does not navmesh-project these.** The 74.7 m projection in the
platform's research is real and it is about *humanoid puppets with an AI agent*;
every drone record resolves to an `av_*.ent` **vehicle** template instead, and a
frozen one hangs exactly where it is put.

### The morph does not — refuted visually, 2026-09-20, in both AI modes

`npcmove` at 1 Hz over 30 m: **58 writes sent, 58 accepted**, steps up to
7.79 m, the canonical position changing on 9 reads out of 10 — and across four
screen captures with the camera unmoved, building edges aligning pixel for
pixel, **the drone did not move**. Not by 30 m, not by a metre. Re-run with a
simulation lease (`tasks`, steps up to 13.79 m) and captured twice more: the
same pixel.

So it is not the 2 m placement deadband, and it is not the lease. **A server
transform write reaches an NPC's canonical record and never reaches the rendered
body.** There is no morph for this style on this build.

That is also the lesson about the measurement itself: `Open77.npcs.get` returns
the *canonical* record, so with `authority 0` its "error" is an echo of what
this resource just wrote. Every probe and sweep report prints the authority and
labels itself `INERT` when there is none — but only a camera settled it.

### Which leaves the cut

Spawn the swarm already in formation, hold it, despawn it, respawn it in the
next formation. Real drone displays cut through blackout between figures too, so
this is a look rather than a consolation — and it costs **nothing per tick**,
only a spawn and a despawn per drone per figure.

That is what puts the drone count back where the 94-byte NPC state said it could
be, instead of where the 256 KB/s clamp forced the particle version:

| | `effect` (morph) | `npc` (cut) |
|---|---|---|
| Cost | 555 B per drone per **update** | 300 B per drone per **figure** |
| At 8 drones | 35 KB/s continuous | 2.4 KB per figure, nothing between |
| Budget gate | a sustained rate against a 64 KB/s slice | a burst against the 512 KB send queue |
| Ceiling | ~39 drones | ~400 by bandwidth; the real limit is elsewhere |

`bytesPerFigure` is measured from the encoders, not estimated: `NpcCreate` is
94 + the record string (28 for a `Character.*` drone), `NpcState` is 70 and
`NpcRemove` is 17, each under a 24-byte header — 146 + 94 + 41 = 281, rounded to
300.

**The npc style reads the same show list differently.** It ignores `morph`
entirely and cuts instead, so every shipped show works under either style and
reads as a different thing in each. A step may name its own `blackout`;
otherwise `drone.npc.blackoutMs` applies, 1.2 s by default — about one slow
breath, and under 600 ms it starts to look like a glitch rather than a cut.

**What is still unknown: how ragged the cut looks.** A spawn is asynchronous and
per client, so a figure fades in at each client's own projection latency rather
than on one frame. The engine waits for every drone to report a ready body
before it starts the hold, which bounds it, but it cannot make the appearance
simultaneous. That is the one thing to watch for on the first flight.

`play` still refuses an npc show until `drone.npc.allowShow` is set, because the
cut is built and not yet watched. `/droneshow style npc` is accepted, so the
instruments are reachable; it is `play` that refuses, and its message says why.

### The blink — still open, and one hypothesis is dead

Reported in game 2026-09-20: the drones of a held figure **flicker in and out**,
while the server writes nothing at all and nothing is simulating them.

**The leading hypothesis was tested and it did not fire.** The candidate was a
race in Open77's vanilla-identity sweep: a drone record resolves to an
`av_*.ent`, so its body is a `vehicleBaseObject`, and the sweep removes vehicles
it cannot find in `EntityService` — while a server-owned NPC only lands there at
the *end* of its spawn. The sibling sweep, `WorldSanitizer`, closes exactly that
window with a second check and a 500 ms grace; this one has neither, and the
asymmetry looks unintentional.

A full `cut` show was then run with the guard **off** while the client log was
watched across it: `rejected vanilla vehicle without network identity` appears
**zero times**. Not one rejection. So the race is either unreachable in this
bucket on this build, or it is not what the owner saw.

`/droneshow sweepguard on` ships anyway — it is cheap, reversible, restores the
bucket's policy on every ending, and the sweep asymmetry is worth reporting
upstream on its own merits. **Do not build on it and do not call it the fix.**

What is still known: the blink was seen only at **45 m** of standoff, and the
geometry moved to 24 m immediately afterwards, so it has not been observed since.
`/droneshow npcprobe <record> <distance>` parks one drone at a stated distance
and is how to bisect it the next time somebody sees it.

### Choreography: the flip-book

A drone cannot be moved — a server transform reaches the canonical record and
never the rendered body, measured on camera — but a **figure** costs only 300
bytes a drone. So motion is not written, it is **redrawn**: interpolate between
two formations, cut each intermediate pose, hold it just long enough for the
next to replace it.

**Measured 2026-09-20**, 8 drones at 24 m, from the driver's own readiness
counter, three movements per run:

| Frame | Result |
|---|---|
| 250 ms | **abandoned** after 4 frames, nothing ready |
| 400 ms | 10 frames per movement, **8 of 8 ready on every one** |
| 600 ms | 7 frames per movement, 8 of 8 |

**400 ms holds.** Two and a half poses a second, and that is motion.

#### The retracted measurement, and why it is in this file

An earlier run of the same counter read **0 of 8 at 300 ms and stayed there for
fifty frames**, and that number was wrong. It was an artefact of a defect in
*this resource*, not a property of the platform: frames were being issued faster
than a spawn could land, so roughly four spawns per drone were in flight at once
and the counter was reading a queue the driver had flooded. On the strength of
that number the technique was renamed a "pose sequence" and written up as a
slideshow. It was neither.

`abortAfterEmptyFrames` is the fix, and it is what made the clean bisection
possible an hour later. The lesson is not about drones: **a self-measuring
driver can measure its own bug and report it as physics.** `sequence` is still
accepted as a synonym for `flipbook` so nothing typed during that afternoon
breaks.

#### Where the ~400 ms goes

Decomposed from the platform's source. Most of it does not scale with hardware:

| | |
|---|---|
| 33 ms | one server tick before the create is even *sent* — `Create` fires into an empty viewer set, so the packet leaves on the next interest reconcile |
| 17 ms | a client frame to drain it |
| 17 ms | at least one more: the entity stub is created off the game thread and parked for the next frame |
| **250 ms** | **the readiness settle** — a fixed wait between the body attaching and the client reporting it ready. Not a tick, not tunable, paid on every machine |
| 33 ms | one more server tick for this resource's own poll |
| 4 ms | two 2 ms network-worker polls |
| **~350 ms** | fixed, plus round trip, plus the engine streaming the vehicle entity — which has **no deadline in the code at all**, only a per-frame "is it there yet" |

**Two consequences for a real server, pointing opposite ways.** The 250 ms
settle and the two 30 Hz server ticks are constants, so a faster machine will
not beat 400 ms. But the round trip is *not* a constant: this was measured on
**loopback**, and a server with 60 ms of ping to its players needs that much
again. Budget **400 ms + your RTT**, and re-bisect on the machine that matters.
The streaming term also grows with the swarm — eight vehicle entities at once is
not sixty-four.

#### Using it

```
/droneshow choreo flipbook      redraw between figures
/droneshow choreo cut           hold, blackout, cut
/droneshow frame 400            set the frame; refuses under 300 ms
```

**The driver abandons a movement that finds nothing ready** — four empty frames
and it stops with the number in the log. That is not tidiness. A spawn already
in flight is **not cancelled** when the next frame despawns it: the cancel sets
a flag and the engine still fully streams, instantiates and then destroys the
body. Eight drones at 300 ms was about **twenty-seven complete vehicle
spawn-and-destroy cycles a second**, for nothing visible. The floor and the
abandon guard exist to make that unreachable by typing a number.

The shipped `parade` show is four poses and three movements. It is **not** called
`choreo`: that is a subcommand, and a show with the same name was silently
swallowed by it. The resource now **refuses to arm** if any show name collides
with a subcommand.

### The hybrid: lights fly, bodies hold

The parade flew and the verdict was *"ca fonctionne mais pour les mouvements
c'est saccade... ca bouge frame par frame"*. That is right, and no amount of
tuning fixes it: 2.5 redraws a second will never read as flight.

But look at what the two styles are. **The npc style has a body and cannot
move. The effect style can move and has no body.** Each is exactly what the
other is missing, so the hybrid gives each half the job it can do:

```
bodies at A  ->  lights up at A  ->  bodies down  ->  lights fly A to B
             ->  bodies up at B  ->  lights down  ->  hold
```

A movement becomes a smooth stream of effect drones; the figure is held by real
drone bodies. One crossfade at each end, overlapping by `hybrid.overlapMs`
(500 ms) so the sky is never briefly empty while a body streams in.

```
/droneshow choreo hybrid
```

**The mechanism is confirmed, the look is not.** `Open77.effects.update` keeps
the same `FxInstance` and calls `gameFxInstance::UpdateTransform` on it — it
**repositions a live particle graph in place**, trails and all, rather than
restarting it. So a streamed effect genuinely travels.

What is *not* confirmed is whether it reads as a glide. There is no client-side
interpolation here either, so smoothness is still update rate × step size — at
8 Hz and a 0.6 m step cap, eight discrete 0.6 m hops a second. That may read as
flight or as a fast strobe, and **nobody has watched a steady source do it**:
the only effect-style flight anybody ever saw used `race.firework.burst`, which
re-bursts on every update, so motion and re-triggering were indistinguishable.

The movement instrument now works on **whichever style is active**, so that is
one command away:

```
/droneshow style effect
/droneshow npcmove 8 12
```

One effect drone, swept back and forth. If it glides, the hybrid is the show. If
it strobes, then this build cannot do smooth motion at all — and that is the
honest answer to give the owner, rather than a smoother-sounding name.

### Several shows at once

The one-show limit is gone. Shows are keyed by name, each with its own drone
set, its own liveness flag and its own teardown:

```
/droneshow parade
/droneshow sign            both in the air at once
/droneshow stop sign       take one down
/droneshow stop            take everything down
```

**The limit is the budget, not a count.** Every live show spends from the same
per-viewer slice, so the gate asks "would this, on top of what is already
flying, exceed it?" and the refusal names what is up:

```
24 effect drones need 72 KB/s to fly at 3.0 Hz and only 29 KB/s is free
(parade (24 npc drones, 36 KB/s) flying) -- at most 9 drones fit
```

Two further gates, because bandwidth is not the only shared thing:

- **A swarm ceiling across all shows** (`maxDrones`, 120). The server allows 512
  NPCs and the bytes usually bite first, but the ceiling that bites *silently*
  is the client's ~1,024 dynamic-entity slots — shared with everything else, and
  with **no diagnostics at all** when it fills. Spawns simply stop arriving,
  forever, with a clean log. Two lit npc shows are four entities per drone.
- **The cut burst is shared too** — other shows' figures land in the same send
  queue, so the burst that matters is everything that could arrive together.

The cooldown became per show, so two *different* shows no longer block each
other. The sweep guard is now released only when the **last** show ends.

One thing worth knowing: **every formation has exactly `droneCount` points**, so
all shows in the air use the same swarm size. Two 88-drone shows will be refused
long before they fly; two 24-drone ones are comfortable.

### OPEN//77 in the sky

A stroke font, not a dot matrix — so a word renders at whatever count you have,
and more drones simply means a denser line. `tools/make-formations.py` grows
`sign_open77` and `sign_open77_stacked`.

**It needs 88 drones**, and that is not a round number chosen for comfort. A
sign is a length of stroke, and drones have to sit along it about **2 m** apart
to read as a line rather than as dots, given a rig roughly 2.5 m across. At a
2 m mean gap:

| Drones | Stacked (`OPEN` / `//77`) | One line |
|---|---|---|
| 48 | 22 × 17 m | 42 × 7 m |
| 64 | 26 × 19 m | 47 × 8 m |
| **88** | **32 × 24 m** | 60 × 10 m |
| 120 | 44 × 33 m | 81 × 14 m |

**88 on two lines is the one that works** — a 32 × 24 m sign fits the frame at
40 m and the letters are a third of its height. The one-line layout ships but is
not recommended: at the same legibility it is 60 m wide and 10 m tall, needing
65 m of standoff, and at 65 m a 2.5 m drone is a speck again. 48 and 120 also
put two drones within a metre of each other at a stroke junction where 88 keeps
them a metre apart.

The fallback, if 88 is too many, is the `seventy_seven` formation that already
ships and reads at any count.

**A sign needs its own stage**, so a show may now carry one:

```lua
sign = {
    stage = { standoff = 40.0, altitude = 26.0, width = 32.0, height = 24.0 },
    { formation = "sign_open77_stacked", place = "stage", morph = 0, hold = 14000, color = "cyan" },
},
```

Cost: 26 KB per figure per viewer, 88 of the server's 512 NPCs, 176 of the
client's ~1,024 entity slots with the landing lights counted. The untested part
is **eighty-eight vehicle entities streaming at once** — watch the readiness
line.

Two generator notes, both paid for once. The `O` of OPEN closes on its own start
point, which an open arc-length walk turns into two drones in one place; strokes
that end where they began are now treated as closed. And the `E`'s crossbar used
to start exactly on its stem, where the stem's own walk could land a point on
top of it — it is inset by a third of a unit now, and **the generator refuses
outright if any two points land closer than a hair**, so the next glyph cannot
stack drones silently.

### `playtest`: PLAY TEST flies into OPEN 77, then the parade

The owner's words: *"displaying play test, open77 — animated if possible like
we see the drone moving from one text to another, then the parade"*.

`/droneshow style effect` then `/droneshow playtest`. Six figures, ~95 s:
`PLAY / TEST` draws itself in over six seconds, holds, then **flies** into
`OPEN / 77`, holds, then the ring, heart and 77 of the parade at the same 88
drones.

**Effect style, because it travels.** Base `main` now interpolates a moved
world VFX on the client (PR #58): a drone the server nudges 3–8 times a second
is drawn gliding at frame rate. So the effect style is the path for anything
that moves, and npc bodies remain the path for anything that holds. Under
`style npc` this show still runs — it cuts between the texts instead.

Two per-step fields make the text-to-text flight read as one word becoming the
next:

- **`mapping = "index"`** — drone *i* flies to point *i*. Both texts are four
  glyphs over four in the same reading order, so P flows into O, L into P, A
  into E, Y into N, and TEST into 77. Greedy nearest would scatter the swarm
  across the sign.
- **`stagger = 0.3`** — each drone spends 30% of the morph in flight, starting
  in stroke order, so a wave runs through the letters instead of the whole
  swarm lurching. That is also the **moving-front budget made concrete**: only
  ~27 of the 88 are in flight at any instant, and the engine derives the rate
  for that front — about 4.4 Hz, which the interpolating client draws smooth —
  where the whole swarm at once would be 1.3 Hz. **The gate prices the front,
  not the swarm**: without that, 88 effect drones would be refused at 1.3 Hz
  before the stagger ever ran.

#### The speed brake changed when the client did

`maxStepMetres.effect` was 0.6 m: how far a drone may jump between two updates,
derived for a client that *teleported* a moved effect, where the step was
exactly what the eye saw. With PR #58 the client interpolates, so the step is
no longer a visible jump — it is how far behind the server the picture runs and
how much a corner gets rounded. It is now **2.0 m**, a first value under the new
client and not a measurement: lower it if the wave cuts corners, raise it if the
morphs feel slow, and go back to 0.6 on a client without the interpolation.

Why it had to move: with a 15% stagger window, each drone's own flight was so
short that the old brake stretched every morph in `playtest` four to seven
times. The offline replay caught it before anybody flew it. The shipped morph
durations (15, 11, 12, 19, 17 s) are the minimums for a 30% window at 2.0 m;
shorten one and the engine stretches it back and says so.

#### The count, and the end of the count lottery

**88 drones**, the same as the sign, so all three text shows share one config.
Both texts read at 88: about 1.9 m (PLAY TEST) and 1.7 m (OPEN 77) between
neighbours on the 32 m stage. The parade figures that follow are denser than
the 8-drone rehearsal and a better picture for it.

Picking that number used to be luck. Arc-length spreading is exact along one
stroke, but a glyph is several, and whether the walker lands two drones on top
of a junction depended on the count — 88 stacked a PLAY TEST junction and
cleared every OPEN 77 one; 96 did the reverse. **The generator now relaxes
junctions apart** after normalising: any pair closer than ~19 cm at the sign's
scale is nudged apart along the line between them, a few centimetres, for a few
passes. Every count from 64 to 120 now clears the stacking guard for every
formation, and the guard's threshold finally means something.

One thing paid for once: the first version of that pass ran *before*
normalising, in glyph-space units against a threshold in normalised units — it
nudged by nothing, and the tightened guard then correctly refused the very
counts it was meant to rescue. Order is load-bearing, and the docstring says so.

The font grew `A L Y T S`; every crossbar and stem that meets another stroke is
inset by a third of a unit, for the same reason as the E.

### The show faces the viewer

`/droneshow <show>` from chat used to face north (`stage.facing = 0`); the admin
menu passed the camera yaw, chat did not. It now faces **the direction the
player is looking**, and no client half was needed.

A note in the platform's own `open77_playerstate` resource says there is no
live heading server-side. **That note is older than the rich read.**
`Open77.players.get` (since op77.67) reports `heading` from the player's last
snapshot transform — the snapshot header carries a yaw on the wire
(`MessageContracts.cs:164`; `LuaResourceRuntime.PlayerReads.cs:347-348`) — and
it goes stale rather than silent, so the reading comes with an age. Older than
five seconds and the show falls back to `stage.facing`.

It is the **body's** heading, not the camera's; in third person the two differ
by however far the camera has been turned without moving. For "in front of
where I am looking" that is close enough, and an explicit yaw from chat still
overrides it. The console form, which has no body, keeps its explicit yaw. The
probes face the viewer the same way.

### Live motion: bound the concurrency, not the swarm

The owner asked for drones that advance, retreat and flip, and for the sign to
**draw itself** rather than appear whole — and named the constraint himself:
*"faut plus de frame pour que ca soit LIVE"*.

He is right, and the way out is not more bandwidth. It is to stop assuming the
whole swarm moves at once. **An effect drone that is not moving costs nothing**
— nothing is written for it — so the bill is `drones in flight × rate × bytes`,
and the swarm size never enters it.

Against the measured 555 B per effect update and the 64 KB/s slice:

| If **every** drone moves | 8 | 24 | 48 | 88 |
|---|---|---|---|---|
| max rate | 14.8 Hz | 4.9 Hz | 2.5 Hz | **1.3 Hz** |

| Staggered — drones **in flight at once**, any swarm size | | | |
|---|---|---|---|
| 4 Hz → **29** | 8 Hz → **14** | 12 Hz → **9** | 20 Hz → **5** |

So the 88-drone sign cannot be animated as a swarm at any useful rate, and
**can** be drawn stroke by stroke at 8 Hz with a front of 14, for 61 KB/s.
Bounding concurrency does not merely make live motion affordable — it makes it
*cheaper* than the whole-figure redraw it replaces. `moverBudget` computes the
cap from the same slice as everything else, and `/droneshow status` reports it.

#### What is built: the reveal

```lua
{ formation = "sign_open77_stacked", …, reveal = 8000 }
```

Drones appear **one at a time along the stroke** — the formation's point order
*is* stroke order, because the generator walks each stroke end to end — at a
clock-driven rate. 88 drones over 8 s is 11 creates a second, about 6 KB/s
against the 26 KB burst the same figure costs appearing all at once. **Drawing
the sign is cheaper than showing it.** `/droneshow signdraw`.

It works **whether or not a streamed effect glides**, because nothing moves:
each drone is placed once, where it belongs.

#### What is not built, and why

Advance / retreat / flip, and drones that *fly* into the stroke rather than
appearing on it, all rest on one unverified assumption: **that a streamed
effect reads as a glide rather than a strobe.** Nobody has watched a steady
source move. The only effect flight anyone ever saw used
`race.firework.burst`, which re-bursts on every update, so motion and
re-triggering were indistinguishable.

One command answers it:

```
/droneshow style effect
/droneshow npcmove 8 12
```

**If it strobes, this whole direction collapses into "cut shows only"** — which
is a legitimate answer, and one worth having early rather than after building
on it.

On rotation specifically: `Open77.effects.update` **does** carry an
`orientation`, and `UpdateWorldVfx` passes it to `gameFxInstance::UpdateTransform`,
so a spin is transmitted. Whether a *camera-facing* particle shows it is a
separate question that only the bench can answer — many VFX will not.

### Lights are a named set

Whatever wins, **the blue stays**. Lights are a palette, not a default:

```lua
lights.set = { blue = {…}, holosphere = {…}, glowstick = {…},
               lamp = {…}, candle = {…}, laser_red = {…}, laser_green = {…} }
```

Each carries **its own `offset`**, because a vehicle entity's origin is not its
visual centre and every candidate is a different size — one global number could
never sit right for all of them. A step names a `light` directly, or a `color`
that maps to one.

That is half the fix for the owner's complaint that the glow *"sits below and
beside the hull — two objects, not a lit aircraft"*. The other half is which
effect, and that is what the bench is for.

### The light bench: one photograph, every candidate

```
/droneshow lightbench          a row of drones, one per candidate
/droneshow lightbench off
```

A row at a comfortable distance, evenly spaced, with the order printed to the
log so a **single screenshot identifies all of them**.

This exists because of what one photograph already did. Four rounds of logs
said the sign worked; the owner's picture of it said the blue glow sat below
the hull and read as two objects. The picture settled in one pass what the
numbers could not settle at all. **The right instrument for a question about
appearance is one that produces a comparable picture, not more numbers.**

### Looping shows

A show with `loop = true` walks its steps as a circular list until stopped. The
light-cycling case is the cheap one, and deliberately so: when consecutive steps
share a formation and place and only the light differs, the engine **relights
without respawning** — the bodies never blink, never restream, and a cycle costs
one entity round trip per drone instead of two.

Bounded by the same things everything else is: the run's own liveness flag,
which `stop <show>` and the resource teardown both clear, and the audience check
inside every hold. `/droneshow status` lists what is flying, with cycle counts,
so a loop left running is not invisible.

### Landing lights

Measured 2026-09-20, the owner watching a cut show: *"ils font pas trop de
lumiere donc pas tres impressionant dans le ciel"*. He is right — a drone rig's
own emissives are a couple of small lamps meant to be seen from a few metres,
and the hull is dark.

The fix costs nothing, for one specific reason: **the drones do not move**. A
looping effect co-located with a body that never moves needs no updates at all
— it is spawned with the figure and retired with it, so a light is just a
second entity on the same per-figure bill.

`Open77.effects.attach` would bind the effect to the body instead, and is the
right answer the day these can move. It is not used: it buys *following*, and
nothing follows.

**Colour comes from the asset**, because a VFX is whatever it was authored as.
So a palette name maps to whichever cooked effect is nearest it — red and green
3 m laser columns from the family the platform's own AV landing pad uses, the
blue loot beacon, a candle for amber, and a deliberately blinding lamp for
white. `magenta` has no match and borrows red; that is stated in the config
rather than hidden.

### Thirty-five dark drones, and why the server log showed nothing

Measured 2026-09-21, from a photograph the owner sent of the sign: *"pourquoi
certain sont pas allume"*. The left third of `OPEN//77` was dark hulls; the
rest was lit. The server log was clean — `88 bodies and 88 lights spawned`,
every call answered an id.

The truth was in the **client** log, and it names itself:

```
[open77_effects] effect 4225 rejected: quota_exceeded      (448 of these)
Open77 script execution budget exceeded
        open77_effects/client/main.lua:247: in upvalue 'projectLooping'   (19 of these)
```

The chain, and every link was measured:

1. A figure creates 88 looping effects in one server tick, so they reach the
   client as **one registry snapshot**.
2. `open77_effects` projects a snapshot inside a **single frame**. Eighty-eight
   new records plus the retiring figure's eighty-eight overran that frame's
   script budget, and the projection loop was cut off part way through.
3. An aborted pass loses work at *both* ends: the lights it had not reached are
   never spawned, **and** the retired figure's lights are never stopped.
4. Those dead entries keep their slot in the client's per-owner effect quota —
   `kPerOwnerLimit = 192` in `client/src/api/Effects.cpp` — until it starts
   answering `quota_exceeded` to everything.
5. From there the failure is self-feeding: every show leaves more dead entries
   behind than the one before.

The fix is to stop handing the projector a whole figure at once. Lights are
spawned in **slices** — `lights.sliceSize` of them, then a `lights.sliceMs`
pause — and a colour change is sliced the same way, because a relight is 88
stops and 88 starts. Twelve at a time, 60 ms apart, lights eighty-eight drones
in about 400 ms.

It costs nothing to look at. A swarm that ignites over a third of a second is
what a drone show does anyway, and a full show — three figures and two colour
changes, 440 light operations — now runs with **zero** rejections and **zero**
budget aborts where the same sequence produced 448 and 19.

Two smaller things were wrong in the same place. `despawnAll` walked
`#run.lightIds`, and one refused light leaves a hole that `#` may stop at,
which would strand every light after it burning in an empty sky; it walks the
bodies now. And a slice-spawned ignition can outlive the figure it belongs to,
so it carries a token and takes its own lights back down when the figure has
moved on.

### Which side of the drone the audience sees

Measured 2026-09-21, the same evening: *"met les dans le sens inverse les
drones comme ca on verra leur lumiere violette, la on les vois a l'envers"*.

Every body was spawned at `yaw = 0` — due north — because the *picture* already
faces the viewer and nothing had made the individual aircraft matter. It does:
a Bombus rig carries its emissives on the sensor head, so a swarm pointing north
shows eighty-eight dark tails to an audience standing anywhere else.

The stage basis already knows the answer. Its normal runs from the stage centre
back to the anchor, so a body whose forward *is* that normal is nose-on to the
person the show was fired for; inverting `forward(yaw) = (-sin yaw, cos yaw)`
gives the yaw, and every drone of every figure takes it.

`drone.yawOffset` adds to it. It exists because which end of a rig glows is a
property of the **art**, not of the maths — four of the nine Bombus appearances
put a lamp on the sensor head and the rest do not — so turning the swarm around
is one number in the config rather than a rewrite.

### Where the picture hangs, and why it kept moving closer

It started at 80 m out and 50 m up, on the strength of a firework measurement:
25–45 m *"big in frame and clearly in the sky"*, 55–95 m *"distant sparks"*.
**That note does not transfer.** A firework shell is a burst tens of metres
across; a drone rig is about 2.5 m of dark hull. The owner's verdict on the
first npc show was the whole lesson in one line: *"faut les afficher bien plus
proche de nous parce qu'ils sont petit"*.

**24 m out, 16 m up, 22 m across** is a drone show's real geometry: watched from
underneath, filling the view rather than sitting in the distance. The figure
spans about 49°, and the drones sit 24–36 m from the viewer — where a 2.5 m body
is something you can see rather than something you can find. The 25–45 m band is
still right *for fireworks*; it was in this file because it was the only
measurement anyone had, and it is not a rule about drones.

### The style survives a reload

`state.style` was in-memory, so a `reload` silently reverted it and a whole run
went out as effect drones with nobody noticing until the log was read
afterwards. The style and the choreography are now persisted through
`Open77.kvp` — which needs no permission and survives the generation swap — and
restored before anything reads them. The start banner says which, and where it
came from:

```
[rp_drones] === STYLE: NPC (persisted), sequence driver, sweep guard off, flip-book at 400 ms ===
[rp_drones] ready -- 8 drones, shows: choreo, cut, heart, open77, rehearsal, salute
```

### The instruments

```
/droneshow npcprobe [record]            one drone, next to you, measured
/droneshow npcmove [rate] [metres] [axis] [mode]
```

`npcprobe` is what proved the hold. `npcmove` is what refuted the morph, and it
stays for two reasons: one axis is still unrun — the console path shifted its
arguments by one and silently ran *horizontal* when *vertical* was asked for,
which is the worst kind of defect in an instrument, because the log looked
plausible and the experiment never happened — and because it is the thing that
would notice if a future build changed its mind. Arguments are now matched by
**kind** rather than position: `horizontal`/`vertical` and `frozen`/`tasks` are
recognised wherever they appear, and numbers are taken in the order written.

**A passive drone is fully achievable**, and the probe already is one:
`damagePolicy = invulnerable`, `combatEnabled = false`,
`perceptionEnabled = false`, `voiceEnabled = false`, and a `friendly` attitude
with no target row — which is also what suppresses the player's lock-on and
health bar. The records are chosen from the non-combat family:
`q307_zetatech_drone` and `mq001_nomad_drone_bombus` ship tagged `Invulnerable`
in the catalogue, so they start harmless rather than being made harmless. The
Wyvern, Griffin and Octant are `Mechanical_Aggressive` gunships *and* Phantom
Liberty assets, so naming one makes the expansion a server requirement; they are
last in the probe list to be looked at once and ruled out.

## What a drone is

**A looping world VFX** (`Open77.effects.create`, moved with
`Open77.effects.update`). The client updates the live particle graph in place —
the handle and its trails survive a move — and a mesh-free effect has none of
the light host's problems.

The `light` style is still here, honestly labelled. It is **not a drone**: with
its radius opened up to reach the ground it is a formation of moving coloured
pools on the terrain below, which is a real effect and a good one, and a
different show. The engine measures the farthest drone of whatever show you ask
for and **refuses** a light show that would be culled, naming the distance, so
that failure can never be silent again.

| | `effect` | `light` | `npc` |
|---|---|---|---|
| Holds a point in the air | yes | yes | **yes — seen at 10 m and 30 m** |
| Can be moved | yes | yes | **no — refuted on camera** |
| Gets between figures by | morphing | morphing | **cutting through blackout** |
| Visible past 50 m | yes | **no — host culled at 50 m** | yes |
| Visible at all in empty air | yes | **no — illuminates geometry only** | yes |
| Colour | fixed by the asset | the palette | the rig's own lights |
| Cost | 555 B per update | 490 B per update | 300 B per **figure** |
| Server quota | 512 per resource | 2,048 per resource | 512 per resource |
| Client quota | 192 VFX under `open77_effects` | 256 projected props, server-wide | ~1,024 shared entity requests |

## The shape of a show

A show is a list of **steps**, and a step is one pose plus the flight into it:

| Field | Meaning |
|---|---|
| `formation` | a key of `RpDronesFormations.shapes` |
| `place` | `stage` (the picture standing in the sky) or `pad` (a lattice on the ground) |
| `morph` | milliseconds of flight from the previous pose; `0` means "stay put" |
| `hold` | milliseconds standing still once it arrives — and this costs nothing |
| `color` | a key of `palette`, applied on arrival |
| `lit` | `false` hangs the drones dark. Default true. |

**The reveal is an ignition, not a launch.** The swarm is spawned already in the
first formation, dark, held for two seconds so it has streamed in everywhere,
and then lit — one message per drone. The first build launched it from a
lattice on the ground instead, which looked better and cost two 75 m flights
for every drone at once: about 60% of the show's entire bandwidth, spent before
the first figure. The `pad` machinery is kept for a server on a fat link.

`grid` is still generated, and is the only formation that does not go through
the arc-length walker — running a lattice through a path walker treats it as
one long zig-zag and returns a diagonal smear, which is precisely what the
first version of the generator did.

### Which way the picture faces

The picture is a flat plane standing in the sky, and **it always faces the
anchor**. `facing` chooses which compass direction the show is *from* you; the
plane's normal is then taken from the anchor back to the stage centre. That is
insurance, not elegance: if the yaw convention here is a quarter-turn out, the
show appears somewhere unexpected and still reads correctly.

For how far away it hangs and why that number kept shrinking, see
[Where the picture hangs](#where-the-picture-hangs-and-why-it-kept-moving-closer)
above.

### The formations are generated, not typed

`shared/formations.lua` is written by `tools/make-formations.py` and is
overwritten without warning. `shared/config.lua` beside it is the file you edit.

```
python tools/make-formations.py --count 8
```

Then set `droneCount = 8`. The resource refuses to arm if the two disagree, and
says which command to run.

Each shape is defined once as strokes in a normalised square and walked at
**equal arc length**, not equal parameter — equal parameter crowds drones where
a curve is tight, which on the heart puts two dense knots at the top.

## The bandwidth budget

**The ceiling is 256 KB/s per connection, and it is shared with everything else
the server sends that player** — position snapshots for every peer, vehicles,
NPCs, chat. A drone show is decoration, so it gets a slice, not the link.

The rate is therefore not configured. It is derived:

```
rate per drone = min(clock.updateHz, budget / (bytesPerUpdate x droneCount))
speed limit    = clock.maxStepMetres x that rate
```

and every morph is stretched to obey the speed limit, because there is no
client-side interpolation — a prop teleports from one update to the next, so
the step is what the eye sees. The shipped morph durations are already at their
minimums for 24 drones; shorten one and the engine stretches it back and logs
that it did.

| Drones | Rate | Traffic while moving | Share of the clamp |
|---|---|---|---|
| 8 | 8.0 Hz (wish-capped) | 35 KB/s | 14% |
| 16 | 7.4 Hz | 64 KB/s | 25% |
| 24 | 4.9 Hz | 64 KB/s | 25% |
| 40+ | — | — | **refused**: below the 3 Hz floor |

`bytesPerUpdate` is **measured**, not estimated: the exact record the server
sends (`ServerApplication.ToNetwork`) serialised with this resource's own field
values, plus 24 bytes of packet header, 12 of net-event framing and the event
name. A position change carries the model, scale, physics, streaming distances
and the whole light table with it; none of that is something this resource can
trim. If the platform's serialiser changes, re-measure — an understated figure
there is how the show gets back over the clamp.

Two things this resource does do about it:

- **Coordinates are rounded to 1 cm before they are sent.** A full round-trip
  double is up to 19 characters and three ride in every update; two decimals
  takes 7% off every message and is invisible at any distance this is watched
  from.
- **A held formation sends nothing at all.** The server has no equality check —
  writing the same position still costs a full packet — so the dead band is
  applied here, against the last position *sent*. The whole cost of a show is
  its morphs.

`maxBytesPerSecondPerViewer` is the one number to raise on a small or private
server. Past ~200,000 it will drop clients; past 262,144 it is guaranteed to. A
server that genuinely needs more can raise the clamp itself with the
transport's `OP77_GNS_SEND_RATE_BYTES` / `OP77_GNS_SEND_BUFFER_BYTES`
overrides, which this resource cannot see and does not assume.

Every show logs its own budget on the way up:

```
[rp_drones] budget: 4.9 Hz per drone, 118 updates/s, 64 KB/s per viewer, step at most 0.60 m
```

If a client is ever dropped again, that line is the first evidence and it is
already in the log.

## The sky must end empty

Five things can end a show, and all five land in one function:

| | |
|---|---|
| `/droneshow stop`, or the `stop` export | bump the epoch, remove the swarm |
| the last player disconnecting | checked on every morph tick and every hold slice |
| a world that went away | `clock.failureBudget` refused writes in a row, then give up |
| the resource stopping or reloading | `onResourceStop` still runs in the outgoing VM |
| the show simply finishing | the same path as all of the above |

A thread cannot be killed from outside, so the stop mechanism is an epoch
integer the loop reads before every beat and before every hold slice. Whoever
bumps the epoch owns the removal.

On top of all five, **every drone is spawned with a TTL** of twice the show's
declared length plus a minute, and the probe with ten minutes. That is the
dead-man switch: even a Lua runtime error that kills the walking thread outright
leaves a sky that clears itself.

## Permissions

`world.effects` for the effect style, `world.props` for the light style.
Nothing else, and no database.

Notably **not** `network.events`: `Open77.chat.send` grants nothing, because the
facade publishes on the host bus and never reaches a client itself.
`Open77.players.all`, `Open77.players.position` and `Open77.time.monotonic` need
no grant either.

## Still unproven

Everything above about the code and the transport was read or measured. Nothing
below has been seen.

- **Which effect reads as a drone at 45 m.** This is what `/droneshow probe` is
  for, and it is the next thing to find out. `race.firework.burst` is the
  default because it is the one curated alias authored to be seen against the
  sky, and the only one with a measured altitude note — but it *bursts* rather
  than glows, so as a continuous loop it may read as a twinkle, or as far too
  much. `neon.loot_drop` is in the candidate list as a control: it was measured
  as a faint speck at 20 m, so if it reads at 45 m the stage is too close.
- **Whether 4.9 Hz is smooth enough.** 60 cm of jump at three quarters of a
  degree is the arithmetic; how it looks is not.
- **Whether a looping VFX loops cleanly.** Every shipped use of
  `race.firework.burst` is a one-shot. As a `duration = 0` registry entry it
  should restart forever; it has not been watched doing so.
- **Whether `visible = false` then `true` is a clean ignition for a VFX.** The
  client stops the effect and plays it fresh, which should read as a flash.
- **Why the drones blink.** See above — open, with a bisection instrument.
- **Whether the text-to-text wave reads as one word becoming the next.** The
  index mapping and the 15% stagger are reasoned, not watched; if the wave
  reads as scatter, try `stagger = 0.3`, and if the letters lose each other,
  drop `mapping` and let greedy nearest take over.
- **Why the drones blinked at 45 m.** One hypothesis is dead; it has not been
  seen since the geometry moved to 24 m. The probe takes a distance when it is.
- **Whether the landing lights read at 24 m.** Every alias in the colour map
  is from the cooked inventory and unvalidated until one is in the sky.
- **Whether the light style is worth keeping at all.** With `radius = 120` it
  should paint moving pools of colour on the ground — and at 24 m out the
  whole figure is now inside its 45 m cull for the first time, so it is at
  least reachable. Nobody has looked.
- **Whether `facing = 0` puts the show where you expect.** The picture faces
  you either way, by construction.
- **`luac -p` cannot see a forward reference, and it has bitten twice.**
  `local function helper()` binds at the line it appears on; a call written
  above it compiles as a *global* lookup, is nil at run time, and passes every
  syntax check. The second time, it killed an 88-drone sign outright in front of
  an audience. `python tools/check-forward-refs.py` finds them and exits
  non-zero; it caught a third one in this very round, before it shipped. Run it
  with `luac -p`, not instead of it — and **read back every function a scripted
  edit touched**, because that is how the other class of silent damage gets
  caught.
- **`open77.lua` cannot be syntax-checked.** The manifest is a DSL, not Lua
  (`auto_start true` is not valid Lua) — `rp_fireworks/open77.lua` fails the
  same check for the same reason. The three real `.lua` files pass.
