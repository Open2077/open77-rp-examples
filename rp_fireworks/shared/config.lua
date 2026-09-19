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
    cooldownMs = 20000,

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
    },
    defaultShow = "burst",
}
