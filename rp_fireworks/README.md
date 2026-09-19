# rp_fireworks

Synchronized fireworks and celebration shows, fired by the server so that
everybody on the street sees the same thing at the same moment.

About 200 lines of server Lua and no client code at all — which is the point of
the example.

## Why the server fires it

Every shell goes out through `Open77.effects.play`, which broadcasts it to the
players in range. One clock, one authority: same shell, same world point, same
moment, for everyone watching.

The tempting shortcut is to tell each client "play the show" and let it run its
own timers. That works for a single effect fired once, and it drifts for a
sequence: each client walks its own clock, so ten seconds in, two players
standing side by side are watching different volleys.

## Using it

```
/fireworks                  the default show, over you
/fireworks opening          a named show
/fireworks stop             end the running one
```

The command is **restricted**: the platform checks `command.fireworks` against
the caller's ACL before the handler runs, so this resource contains no rights
logic of its own. Grant it to the roles that should have it.

From another resource — rp_jobs when a convoy lands, rp_race at a finish line,
a wedding script at the kiss:

```lua
exports.rp_fireworks:playFor(playerId, "celebration")
exports.rp_fireworks:play("burst", { x = -1426.0, y = 974.0, z = 23.6 }, 0)
exports.rp_fireworks:stop()
```

Each answers `true`, or `false` and a reason in plain English — the reason is
written to be shown to a player.

## The shows

A show is a list of **cues**, and a cue is one beat:

| Field | Meaning |
|---|---|
| `at` | milliseconds from the start of the show |
| `effect` | a key of `Config.effects`, a curated alias, a depot path — or nothing, which takes a random shell |
| `count` | how many copies, spaced `spreadMs` apart |
| `radius`, `minHeight`, `maxHeight` | where they land, each falling back to the block above so a cue states only what it changes |
| `ttlMs` | only for effects that do not play themselves out (see below) |
| `sound` | a Wwise event on the first copy |

Writing the timing as absolute offsets rather than as a pile of sleeps makes a
preset readable as a score: you can see that the confetti lands a beat before
the first volley, and two cues can share a beat.

Three ship — `burst` (short and loud: a race finish, midnight), `opening` (the
ground lights first, then fifteen seconds of sky) and `celebration` (confetti
and petals only, nothing that explodes or burns, for indoors).

## Four things measured in game, so you do not have to

**The shells are in the sky, and that is a narrow window.** At 8 m of spread and
3 to 8 m of altitude they go off at head height and read as a campfire; from
55 m up they are distant sparks. 40 m of spread at 25 to 45 m is where a burst
is big in frame and still unmistakably in the sky.

**Spacing is what makes it read as fireworks, not the count.** Shells fired
150 ms apart on one patch of sky land as a single smear. A group is a few
shells 300 ms or more apart, and a point is redrawn until it clears the previous
one by `minSeparation` — because independent random points clump on their own,
that being what randomness does.

**A cue with a `ttlMs` is a loop, not a one-shot.** A burst plays out and
vanishes, but a flare burns and a smoke column pours until something retires
them: fired as one-shots they are still in the world after the show, which is
how a celebration leaves a smoking crater behind it. Those cues go through
`Open77.effects.create`, where the registry owns the lifetime — a looping VFX
has no duration of its own.

**Four firework shells exist.** Cyberpunk cooks `q112_firework_01..04` for the
parade; only the first has a curated alias (`race.firework.burst`).
`Open77.effects.play` takes a cooked depot path exactly like an alias, which is
how the other three are reachable at all. The shell is drawn at random minus the
one just used: a strict rotation is picked out by eye within two volleys.

## Permissions

`world.effects` for every shell, `network.events` for the one line of chat the
command answers with. Nothing else, and no database.
