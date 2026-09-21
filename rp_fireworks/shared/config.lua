-- rp_fireworks -- configuration.
--
-- Everything a server owner would want to change lives here: what is fired,
-- where it lands, how it is paced, and who may fire it.

RpFireworksConfig = {
    -- Who may type the command. The platform checks `command.<name>` against
    -- the caller's ACL before the handler runs, so this resource contains no
    -- rights logic of its own -- grant `command.fireworks` to the roles that
    -- should have it.
    command = "fireworks",
    -- One show at a time, and not more often than this. A show is a wall of
    -- particles for everyone in range; two of them at once is a frame-rate
    -- problem, not a spectacle.
    -- 0 = none. It was 20 s, on the reasoning that two shows at once is a
    -- frame-rate problem. That reasoning was about two SHOWS; it also blocked
    -- an operator from firing an accent volley on a beat, and the owner's
    -- verdict on the first recorded take was the cost: "les feux d'artifice
    -- s'arretent beaucoup trop vite... pendant 30 sec y'a aucun feu".
    --
    -- The right answer to a long show is a long SCORE, not repeated calls, and
    -- `open77sync` below is that. The cooldown is gone so an accent is still
    -- possible, and `play` now restarts rather than refusing.
    cooldownMs = 0,

    -- THE SHELLS. Cyberpunk cooks four firework effects for the q112 parade.
    -- `Open77.effects.play` takes a cooked depot path exactly like a curated
    -- alias, which is how the three without an alias are reachable at all.
    shells = {
        "race.firework.burst",
        "base\\fx\\quest\\q112\\q112_firework_02.effect",
        "base\\fx\\quest\\q112\\q112_firework_03.effect",
        "base\\fx\\quest\\q112\\q112_firework_04.effect",
    },
    -- Named effects the presets use by key, so a cue reads as `confetti`
    -- instead of repeating a forty-character path.
    effects = {
        confetti = "base\\fx\\quest\\q112\\e_debris_confetti_q112.effect",
        petals   = "base\\fx\\quest\\q112\\q112_holo_petals.effect",
        flare    = "race.flare.smoke",
        sparks   = "sparks.burst.large",
    },

    -- WHERE IT LANDS, relative to the point the show is fired at.
    --
    -- These three numbers are the difference between fireworks and a bonfire,
    -- and they were measured in game rather than guessed: at 8 m of spread and
    -- 3 to 8 m of altitude the shells are at head height and read as a
    -- campfire; from 55 m up they are distant sparks. This window is where a
    -- burst is big in frame and unmistakably in the sky.
    radius = 40.0,
    minHeight = 25.0,
    maxHeight = 45.0,
    -- Two shells closer than this read as one smeared burst, so a point is
    -- redrawn until it clears the previous one. Independent random points
    -- clump on their own -- that is what randomness does.
    minSeparation = 26.0,
    -- Broadcast radius, metres, 1..500. The 150 default is tuned for ground
    -- effects; a shell thirty metres up is meant to be seen from far away.
    range = 500.0,
    -- The vanilla launch boom, played once per group rather than once per
    -- shell: three overlapping copies sound like clipping, not like a volley.
    sound = "sq024_race_start_fireworks",

    -- THE SHOWS. A show is a list of CUES, and a cue is one beat:
    --   at          milliseconds from the start of the show
    --   effect      a key of `effects` above, an alias, a path -- or nil,
    --               which takes a random shell
    --   count       how many copies, spaced `spreadMs` apart
    --   radius / minHeight / maxHeight   where they land, defaulting to the
    --               block above, so a cue states only what it changes
    --   ttlMs       present only on effects that do NOT play themselves out:
    --               a flare burns until something retires it, so fired as a
    --               one-shot it is still there after the show. With a ttl the
    --               cue goes through the looping registry instead, which owns
    --               the lifetime.
    --
    -- Absolute offsets rather than sleeps make a preset readable as a score:
    -- the confetti visibly lands a beat before the first volley.
    shows = {
        -- Short and loud. A race finish, a heist that landed, midnight.
        burst = {
            { at = 0,    count = 5, spreadMs = 320, sound = "sq024_race_start_fireworks" },
            { at = 2200, count = 6, spreadMs = 280 },
            { at = 4600, count = 8, spreadMs = 240, sound = "sq024_race_start_fireworks" },
            { at = 7400, effect = "confetti", count = 4, radius = 10.0, minHeight = 9.0, maxHeight = 15.0, spreadMs = 160 },
            { at = 8000, count = 14, spreadMs = 120, sound = "sq024_race_start_fireworks" },
        },

        -- The opener: the ground lights first, then the sky.
        opening = {
            { at = 0,     effect = "flare",    count = 2, radius = 8.0, minHeight = 0.0, maxHeight = 0.5, ttlMs = 12000 },
            { at = 900,   effect = "sparks",   count = 3, radius = 7.0, minHeight = 1.0, maxHeight = 2.5, spreadMs = 140 },
            { at = 1800,  effect = "confetti", count = 3, radius = 9.0, minHeight = 9.0, maxHeight = 14.0, spreadMs = 180 },
            { at = 3000,  count = 6,  spreadMs = 300, sound = "sq024_race_start_fireworks" },
            { at = 6000,  effect = "petals",   count = 3, radius = 8.0, minHeight = 10.0, maxHeight = 15.0, spreadMs = 220 },
            { at = 6800,  count = 8,  spreadMs = 260, sound = "sq024_race_start_fireworks" },
            { at = 10400, count = 10, spreadMs = 200, sound = "sq024_race_start_fireworks" },
            { at = 14000, effect = "confetti", count = 4, radius = 11.0, minHeight = 9.0, maxHeight = 15.0, spreadMs = 150 },
            { at = 14600, count = 16, spreadMs = 110, sound = "sq024_race_start_fireworks" },
        },

        -- Indoor-safe: nothing explodes, nothing burns, and it stays at the
        -- height of the people it falls on. A wedding, a promotion, a funeral.
        celebration = {
            { at = 0,    effect = "confetti", count = 3, radius = 5.0, minHeight = 6.0, maxHeight = 9.0,  spreadMs = 200 },
            { at = 1400, effect = "petals",   count = 2, radius = 4.0, minHeight = 7.0, maxHeight = 10.0, spreadMs = 250 },
            { at = 3000, effect = "confetti", count = 4, radius = 6.0, minHeight = 6.0, maxHeight = 10.0, spreadMs = 180 },
            { at = 4800, effect = "petals",   count = 4, radius = 5.0, minHeight = 7.0, maxHeight = 12.0, spreadMs = 200 },
            { at = 6600, effect = "confetti", count = 5, radius = 7.0, minHeight = 6.0, maxHeight = 11.0, spreadMs = 150 },
        },

        -- THE SCORE FOR A DRONE SHOW, and the reason a long show needs one.
        --
        -- The owner's verdict on the first recorded take: "les feux d'artifice
        -- s'arretent beaucoup trop vite... pendant 30 sec y'a aucun feu... faut
        -- que drone et feu soient synchro correctement". Firing `opening` and
        -- `burst` by hand every half minute could not answer that: each preset
        -- plays out in 9 to 15 seconds and the rest is silence.
        --
        -- A ninety-second show wants a ninety-second SCORE. Absolute offsets
        -- make that legible -- you can read the crescendo down the column -- and
        -- these ones are not arbitrary: they are the beats of `rp_drones`'
        -- `open77` under the cut driver, measured from its own step durations.
        --
        --    0.0 s  the ring lights                 15.7 s  the heart appears
        --    8.5 s  the ring turns green            25.7 s  the heart turns red
        --   35.9 s  the 77 appears                  46.9 s  the 77 turns white
        --   54.9 s  the 77 turns green              64.1 s  the ring returns
        --   72.1 s  the ring turns magenta          79.1 s  the drones go dark
        --
        -- Every one of those gets an accent volley, the gaps between them get a
        -- pulse every two to three seconds so the sky is never empty, and the
        -- finale opens up as the drones fade: wider radius, tighter spacing,
        -- more shells, out to 95 m from the centre -- which, fired from a point
        -- 40 m in front of the audience, means shells behind them as well as
        -- beyond the drones. That is what "dans tous les sens" costs.
        --
        -- The shells are ONE-SHOTS, so they do not hold a slot in the client's
        -- looping-effect quota -- which matters, because the drone show is
        -- already holding 88 of them. The finale is paced to keep about thirty
        -- shells in the air at once and no more.
        -- THE SCORE FOR A DRONE SHOW, AND THE GEOMETRY THAT KEEPS IT IN SHOT.
        --
        -- Two owner verdicts shaped this, and the second undid the first's
        -- easy answer. "Pendant 30 sec y'a aucun feu... faut que drone et feu
        -- soient synchro" -- so the score below is written against the beats of
        -- `rp_drones`' `open77` under the cut driver, with a pulse every two to
        -- three seconds so the sky is never empty:
        --
        --    0.0 s  the ring lights                 15.7 s  the heart appears
        --    8.5 s  the ring turns green            25.7 s  the heart turns red
        --   35.9 s  the 77 appears                  46.9 s  the 77 turns white
        --   54.9 s  the 77 turns green              64.1 s  the ring returns
        --   72.1 s  the ring turns magenta          79.1 s  the drones go dark
        --
        -- Then: "les feux sont pas completement dans l'image, ils sont un peu
        -- au-dessus... ou alors ils sont coupes en deux". That is geometry, not
        -- timing. A shell's ELEVATION from the camera is `height / distance`,
        -- and a fixed camera crops at roughly 25 degrees above its axis. The
        -- default block -- 40 m radius, 25 to 45 m up -- put shells at 48
        -- degrees when fired from a centre 40 m out. Half of every burst was
        -- above the frame.
        --
        -- So every cue states its own geometry, and all of it obeys one rule:
        --
        --      height <= 0.45 x distance from the camera
        --
        -- Fired from a centre about 105 m out, a 50 m radius puts shells
        -- between 55 and 155 m away; at 14 to 26 m up that is 5 to 25 degrees
        -- of elevation -- the whole burst inside the frame, and behind the
        -- drone figure, which hangs at 58 m and 15 m up.
        --
        -- The finale spreads SIDEWAYS rather than closer, because closer is the
        -- one direction that cannot stay in shot: 60 m of lateral spread at
        -- 105 m is over 30 degrees across a frame that has the width for it.
        --
        -- The shells are ONE-SHOTS, so they hold no slot in the client's
        -- looping-effect quota -- which matters with 88 drone lights already
        -- holding theirs. The finale is paced for about thirty shells at once.
        -- THE SCORE FOR A DRONE SHOW: timing, geometry, and a budget.
        --
        -- Three owner verdicts built this, and each one killed the previous
        -- easy answer.
        --
        -- 1. "Pendant 30 sec y'a aucun feu... faut que drone et feu soient
        --    synchro." Firing presets by hand cannot do it: each plays out in
        --    9 to 15 seconds. So this is one score, written against the beats
        --    of `rp_drones`' `open77` under the cut driver:
        --
        --      0.0 s  the ring lights            15.7 s  the heart appears
        --      8.5 s  the ring turns green       25.7 s  the heart turns red
        --     35.9 s  the 77 appears             46.9 s  the 77 turns white
        --     54.9 s  the 77 turns green         64.1 s  the ring returns
        --     72.1 s  the ring turns magenta     79.1 s  the drones go dark
        --
        -- 2. "Les feux sont pas completement dans l'image... ou coupes en
        --    deux." Geometry. A shell's elevation from a fixed camera is
        --    `height / distance`, and the frame crops near 25 degrees, so every
        --    cue obeys `height <= 0.45 x distance`. Fired from a centre about
        --    105 m out, these land 55 to 155 m away at 12 to 30 m up -- 5 to 25
        --    degrees, whole bursts inside the frame and behind a drone figure
        --    that hangs at 58 m and 15 m up. The finale widens SIDEWAYS, never
        --    closer: closer is the one direction that cannot stay in shot.
        --
        -- 3. And then the sky emptied anyway, with 113 `quota_exceeded`
        --    refusals in the client log. THE COUNTS BELOW ARE A BUDGET, and
        --    this is the note worth keeping: a one-shot shell is NOT free. It
        --    holds a slot in the client's per-owner effect quota (192,
        --    `kPerOwnerLimit`) for as long as it burns, and every server-driven
        --    effect shares the one owner -- including the 88 landing lights of
        --    the drone show it is scored against. Half the ceiling is gone
        --    before the first shell leaves the ground.
        --
        --    So the pulse is 2 to 4 shells and the finale 6 to 10, spaced 300
        --    to 420 ms, which keeps roughly 12 to 20 in the air at any moment.
        --    A denser sky is not a tuning question on this client; it needs the
        --    per-owner limit raised, and that is a native change.
        -- THE SCORE FOR A DRONE SHOW: timing, geometry, and a budget.
        --
        -- Four owner verdicts built this, and each one killed the previous
        -- easy answer. They are worth keeping in order, because together they
        -- are the whole design of a long firework show on this platform.
        --
        -- 1. "Pendant 30 sec y'a aucun feu... faut que drone et feu soient
        --    synchro." Firing presets by hand cannot do it -- each plays out in
        --    9 to 15 seconds. So this is ONE score, written against the beats
        --    of `rp_drones`' `open77` under the cut driver, and fired in the
        --    same breath as it (measured 67 ms apart):
        --
        --      0.0 s  the ring lights            15.7 s  the heart appears
        --      8.5 s  the ring turns green       25.7 s  the heart turns red
        --     35.9 s  the 77 appears             46.9 s  the 77 turns white
        --     54.9 s  the 77 turns green         64.1 s  the ring returns
        --     72.1 s  the ring turns magenta     79.1 s  the drones go dark
        --
        -- 2. "Les feux sont pas completement dans l'image... coupes en deux."
        --    A shell's elevation from a fixed camera is `height / distance`,
        --    and the frame crops near 25 degrees, so every cue obeys
        --    `height <= 0.45 x distance`. Fired from a centre about 105 m out,
        --    these land 60 to 150 m away at 13 to 28 m up -- inside the frame,
        --    and behind a drone figure hanging at 58 m and 15 m up.
        --
        -- 3. The sky emptied anyway: 113 `quota_exceeded` in the client log.
        --    A one-shot shell is NOT free -- it holds a slot in the client's
        --    per-owner effect quota (192, `kPerOwnerLimit`) while it burns, and
        --    every server-driven effect shares one owner, including the 88
        --    landing lights of the drone show. Half the ceiling is spent before
        --    the first shell. Measured ceiling during a show: about 1.1 shells
        --    a second sustained, which cost 7 refusals against 113.
        --
        -- 4. And at that rate, in clumps, there were still moments of empty
        --    sky. So the pulse is REGULAR rather than bunched: two shells every
        --    1.8 s, which is the same average the budget allows but leaves no
        --    gap between one burst fading and the next opening. Accents on the
        --    drone beats are four, and the radius stays tight -- a shell that
        --    lands outside the shot is spent for nothing.
        --
        -- The finale opens at 79.6 s, when the drones go dark and hand back
        -- their 88 slots. That is the only reason it can be dense, and it is
        -- exactly why it starts there.
        -- THE SCORE FOR A DRONE SHOW: timing, geometry, and a budget.
        --
        -- Every number here was paid for by a failed take, so they are worth
        -- keeping in the order they were learned.
        --
        -- 1. TIMING. "Pendant 30 sec y'a aucun feu... faut que drone et feu
        --    soient synchro." Firing presets by hand cannot do it -- each plays
        --    out in 9 to 15 seconds. So this is ONE score, written against the
        --    beats of `rp_drones`' `open77` under the cut driver and fired in
        --    the same breath as it (measured 67 ms apart):
        --
        --      0.0 s  the ring lights            15.7 s  the heart appears
        --      8.5 s  the ring turns green       25.7 s  the heart turns red
        --     35.9 s  the 77 appears             46.9 s  the 77 turns white
        --     54.9 s  the 77 turns green         64.1 s  the ring returns
        --     72.1 s  the ring turns magenta     79.1 s  the drones go dark
        --
        -- 2. GEOMETRY. "Les feux sont pas completement dans l'image... coupes
        --    en deux." A shell's elevation from a fixed camera is
        --    `height / distance`, and the frame crops near 25 degrees, so every
        --    cue obeys `height <= 0.45 x distance`. From a centre about 105 m
        --    out these land 60 to 150 m away at 13 to 28 m up: inside the
        --    frame, behind a drone figure hanging at 58 m and 15 m up. The
        --    radius stays tight -- a shell outside the shot is spent for
        --    nothing -- and the finale widens sideways, never closer, because
        --    closer is the one direction that cannot stay in frame.
        --
        -- 3. RHYTHM. Even at a rate the quota allowed, bunched volleys three
        --    seconds apart still left the sky empty between them: a shell fades
        --    in about two. So the pulse is REGULAR -- a small volley every
        --    1.6 s -- rather than clumped.
        --
        -- 4. AND THE BUDGET, which is the one that was misread twice. A
        --    one-shot shell holds a slot in the client's per-owner effect quota
        --    (192, `kPerOwnerLimit`) while it burns, and every server-driven
        --    effect shares one owner -- including the 88 landing lights of the
        --    drone show. That much was true. What was NOT true is the rate the
        --    quota allows: `effects.list` on a live client showed 162 entries,
        --    nearly all spent shells from minutes earlier, because a world
        --    one-shot was created with no duration and the native read that as
        --    no expiry. The quota was full of garbage, not of fireworks. With
        --    one-shots given a finite lifetime, a shell costs its slot for
        --    about ten seconds and no longer, so roughly 88 + 30 slots are in
        --    use at the peak of the show and the finale -- which starts at
        --    79.6 s, when the drones go dark and hand back their 88 -- can be
        --    three times denser than the detuned version this replaces.
        -- THE SCORE FOR A DRONE SHOW: timing, geometry, rhythm and a budget.
        --
        -- Four owner verdicts built this, each one killing the previous easy
        -- answer, and they are worth keeping in order.
        --
        -- 1. TIMING. Firing presets by hand cannot cover a long show -- each
        --    plays out in 9 to 15 seconds and the rest is silence. So this is
        --    ONE score, fired in the same breath as `rp_drones`' `open77`
        --    (measured 67 ms apart) and written against its beats under the cut
        --    driver, recomputed from its step durations:
        --
        --      0.0 s  OPEN//77 lights up      21.4 s  the ring
        --     12.2 s  the sign turns green    28.4 s  the ring turns green
        --     35.6 s  the heart               45.6 s  the heart turns red
        --     55.8 s  the 77                  66.8 s  the 77 turns white
        --     74.8 s  the 77 turns green      84.0 s  the ring returns
        --     92.0 s  the ring turns magenta  99.0 s  the drones go dark
        --
        -- 2. GEOMETRY. A shell's elevation from a fixed camera is
        --    `height / distance`, and a frame crops near 25 degrees, so every
        --    cue obeys `height <= 0.45 x distance`. From a centre about 105 m
        --    out these land 60 to 150 m away at 12 to 30 m up: whole bursts
        --    inside the frame, and behind a drone figure hanging at 58 m and
        --    15 m up. The finale widens SIDEWAYS, never closer -- closer is the
        --    one direction that cannot stay in shot.
        --
        -- 3. RHYTHM. Even at a rate the quota allowed, volleys three seconds
        --    apart still left the sky empty between them: a shell fades in
        --    about two. The pulse is regular -- a small volley every 1.6 s --
        --    rather than bunched.
        --
        -- 4. BUDGET. A one-shot shell holds a slot in the client's per-owner
        --    effect quota while it burns, and every server-driven effect shares
        --    one owner, including the 88 landing lights of the drone show.
        --    Measured across takes: 113 refusals, then 38, then 0. The finale
        --    opens at 99.6 s, when the drones go dark and hand back their 88
        --    slots -- that is the only reason it can be this dense, and exactly
        --    why it starts there and not earlier.
        open77sync = {
            { at = 0, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 1200, count = 8, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 3200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 4800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 6400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 8000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 9600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 11200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 12200, count = 7, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 14400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 16000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 17600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 19200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 21400, count = 8, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 22400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 24000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 25600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 27200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 28400, count = 7, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 30400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 32000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 33600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 35600, count = 9, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 36800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 38400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 40000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 41600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 43200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 44800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 46400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 48000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 49600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 51200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 52800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 54400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 55800, count = 9, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 57600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 59200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 60800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 62400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 64000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 65600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 66800, count = 8, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 68800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 70400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 72000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 73600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 74800, count = 8, spreadMs = 190, radius = 46.0, minHeight = 13.0, maxHeight = 26.0, sound = "sq024_race_start_fireworks" },
            { at = 76800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 78400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 80000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 81600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 83200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 84800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 86400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 88000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 89600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 91200, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 92800, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 94400, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 96000, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },
            { at = 97600, count = 4, spreadMs = 260, radius = 38.0, minHeight = 13.0, maxHeight = 26.0 },

            -- THE FINALE: the drones are gone, their 88 slots are free.
            { at = 99600, count = 12, spreadMs = 170, radius = 50.0, minHeight = 13.0, maxHeight = 27.0, sound = "sq024_race_start_fireworks" },
            { at = 102400, count = 13, spreadMs = 165, radius = 54.0, minHeight = 13.0, maxHeight = 27.0, sound = "sq024_race_start_fireworks" },
            { at = 105200, count = 14, spreadMs = 160, radius = 56.0, minHeight = 13.0, maxHeight = 28.0, sound = "sq024_race_start_fireworks" },
            { at = 108200, count = 15, spreadMs = 155, radius = 58.0, minHeight = 12.0, maxHeight = 28.0, sound = "sq024_race_start_fireworks" },
            { at = 111200, count = 16, spreadMs = 150, radius = 60.0, minHeight = 12.0, maxHeight = 29.0, sound = "sq024_race_start_fireworks" },
            { at = 114400, count = 18, spreadMs = 145, radius = 62.0, minHeight = 12.0, maxHeight = 29.0, sound = "sq024_race_start_fireworks" },
            { at = 117800, count = 18, spreadMs = 140, radius = 64.0, minHeight = 12.0, maxHeight = 30.0, sound = "sq024_race_start_fireworks" },
            { at = 121200, count = 18, spreadMs = 140, radius = 60.0, minHeight = 12.0, maxHeight = 29.0, sound = "sq024_race_start_fireworks" },
            { at = 124600, effect = "confetti", count = 6, spreadMs = 260, radius = 18.0, minHeight = 9.0, maxHeight = 15.0 },
            { at = 125600, effect = "petals", count = 5, spreadMs = 280, radius = 16.0, minHeight = 10.0, maxHeight = 16.0 },
            { at = 126800, count = 14, spreadMs = 150, radius = 56.0, minHeight = 13.0, maxHeight = 28.0, sound = "sq024_race_start_fireworks" },
        },
    },

    defaultShow = "burst",
}
