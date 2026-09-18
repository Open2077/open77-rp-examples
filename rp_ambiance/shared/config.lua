-- rp_ambiance configuration. Shared script: public, no secret and no ACL in here.
-- Every position is in world metres; the freeroam spawn is Kabuki Market Centre
-- -1191.30, 2006.88, 7.82 (Watson) and the figurant zones are real Night City places.
-- Runtime overrides: rp_config (when it runs) may override the scalar keys listed at the
-- bottom of this file (`Config.overrides`); `/ambiance reload` re-reads them.

Config = {}

-- ---------------------------------------------------------------------------
-- (1) Day cycle and weather
-- ---------------------------------------------------------------------------
Config.cycle = {
    -- Real hours for one 24-hour game day. 3 h -> 8 game seconds per real second, which is
    -- the engine's own rate: at 8 the projection never has to correct the clock. Any other
    -- value costs a world time-jump every drift correction (setTimeRate card, measured 25 Aug).
    realHoursPerDay = 3,

    -- nil keeps the clock where the server left it; a number (0..23) forces that hour on start
    -- and on /ambiance reload.
    startHour = nil,

    -- Real minutes one weather draw lasts before the next draw.
    weatherMinMinutes = 12,
    weatherMaxMinutes = 25,

    -- Seconds the sky takes to blend into the new preset (0..300).
    weatherTransitionSeconds = 45,

    -- Night City gets sandstorms too (the vanilla cycle blows them in from the Badlands):
    -- true keeps the row in the draw. Set false and the sandstorm row is dropped (its weight
    -- is simply not counted).
    badlands = true,

    -- Weighted table. `preset` is an open77_weather name (sunny, lightclouds, cloudy, rain,
    -- heavyclouds, fog, pollution, sandstorm). Weights need not sum to 100.
    weather = {
        { preset = "sunny",     weight = 50, label = "Clear skies",  toast = "Clear skies over Night City. Enjoy it while it lasts, choom." },
        { preset = "cloudy",    weight = 25, label = "Overcast",     toast = "Clouds rolling in from the west." },
        { preset = "rain",      weight = 15, label = "Rain",         toast = "Acid rain incoming. Keep your chrome dry." },
        { preset = "sandstorm", weight = 5,  label = "Sandstorm",    toast = "Sandstorm warning. Visibility dropping - stay off the roads.", badlandsOnly = true },
        { preset = "fog",       weight = 5,  label = "Fog",          toast = "Fog on the flats. Watch your step out there." },
    },

    -- Toast everyone on each draw (and on /ambiance weather).
    announceWeather = true,
    weatherToastMs = 8000,
}

-- ---------------------------------------------------------------------------
-- (2) Figurants: 2-3 civilian NPCs per key zone
-- ---------------------------------------------------------------------------
Config.figurants = {
    enabled = true,

    -- Re-spawn sweep: a killed or missing figurant comes back at the next sweep.
    sweepSeconds = 300,

    -- Wander radius around the zone centre and the distance a player must be within to
    -- trigger a line.
    wanderRadius = 6.0,
    speakRadius = 8.0,

    -- A figurant speaks every 60-120 s while somebody is within speakRadius.
    speakMinSeconds = 60,
    speakMaxSeconds = 120,

    -- Numeric damage policy (2 = invulnerable) -- the create native wants the number.
    damagePolicy = 2,
    streamingRadius = 150,

    -- Audible barks paired with the text lines: voContext names from Open77.npcs.voices().
    -- A name a record's voiceset does not carry is silent (the engine drops it without a word).
    barks = { "greeting", "bump", "stlh_curious" },

    -- The bodies. Each entry is a `record` (Character.*) or a legacy `template` alias.
    -- These three have documentation provenance (npcs / npc-behavior guides); swap in vanilla
    -- crowd citizens from docs/generated/npc-records-2.31.csv once tested on your clients.
    bodies = {
        regular = { record = "Character.Judy" },
        nomad   = { template = "civilian_female_relaxed_01" },          -- Character.Panam, passive background body
        ganger  = { record = "Character.cpz_maelstrom_grunt1_ranged1_lexington_wa" },
    },

    -- Chat colour of a figurant line.
    chatColor = { 170, 170, 190 },

    -- Per zone (rp_zones names): the centre (the real place, mirrors rp_zones/shared/config.lua),
    -- the bodies (2-3), display names, and the six lines. `linesForJob` (optional) replaces
    -- the pool when the nearest player holds that rp_jobs job.
    zones = {
        kabuki_market = {
            -- The market itself, around the freeroam spawn (Market Centre, walked).
            centre = { x = -1191.30, y = 2006.88, z = 7.82 },
            bodies = { "regular", "regular", "nomad" },
            names  = { "Noodle Row regular", "Market vendor", "Tyger Claws lookout" },
            lines = {
                "Best synth-noodles in Watson, choom. Don't ask what the meat is.",
                "Tyger Claws run this market. Smile at the lookouts and keep walking.",
                "Lizzie's is ten minutes south if you want the Mox and real music.",
                "The ripper by the market? Skip him. Vik in Little China does honest work.",
                "Safe zone, they say. Tell that to the guy who lost his optics on the Lower Walkway.",
                "The Afterlife is for mercs with a rep. You, choom, have a tab.",
            },
            linesForJob = {
                ncpd = {
                    "A badge in Kabuki. The Claws will love that, officer.",
                    "Nothing to declare, officer. Just noodles.",
                },
            },
        },
        afterlife = {
            centre = { x = -1453.0, y = 1017.0, z = 16.5 },
            bodies = { "regular", "nomad", "regular" },
            names  = { "Afterlife regular", "Tired merc", "Bar fly" },
            lines = {
                "You buying, choom, or just breathing my air?",
                "Heard a merc from Kabuki got flatlined over a data shard. Eddies ain't worth it.",
                "Two Johnny Silverhands and a tab I'll never pay. That's the Afterlife.",
                "Don't stare at the ripper in the corner. He bites. Literally, since the mantis job.",
                "Trauma Team never comes past the ramp. Platinum or not, you walk in on your own.",
                "If a fixer offers you a milk run, it's never a milk run.",
            },
            linesForJob = {
                ncpd = {
                    "Relax, officer. Nobody in here has a warrant. Tonight.",
                    "NCPD in the Afterlife. Now I've seen everything.",
                },
            },
        },
        lizzies = {
            centre = { x = -1188.9, y = 1566.2, z = 22.9 },
            bodies = { "regular", "ganger" },
            names  = { "Mox bouncer", "Braindance junkie" },
            lines = {
                "Mox rules: hands where we can see them, eddies where we can count them.",
                "Judy's got a new BD in the back. Don't ask, don't scroll it twice.",
                "Tyger Claws tried the door last week. They left in a Trauma AV.",
                "You didn't see me, I didn't see you. That's the deal, choom.",
                "Need a lockpick? A crowbar? Or something that goes bang? Not here. Try the Lower Walkway.",
                "Best drinks in Kabuki, worst gossip. Or the other way around.",
            },
            linesForJob = {
                ncpd = {
                    "Nothing to see here, officer. Just... vitamins.",
                    "Badge or no badge, the Mox own this floor.",
                },
            },
        },
        junkyard = {
            centre = { x = 1374.9, y = -1674.9, z = 49.3 },
            bodies = { "ganger", "regular" },
            names  = { "Scav lookout", "Scrapper" },
            lines = {
                "Everything here was somebody's ride once. Mind the crusher.",
                "Scavs pay good eddies for chrome. Don't ask where they get it.",
                "NCPD doesn't drive out to Rancho Coronado. That's the good news and the bad news.",
                "Netrunner fried a whole convoy's brakes last week. Nomads are still pissed.",
                "Vik the Fence opens after dark. Bring what fell off the truck.",
                "Aldecaldos camp is north of here. Long drive, longer if the Raffen see you.",
            },
        },
    },
}

-- ---------------------------------------------------------------------------
-- (3) Rotating server notices
-- ---------------------------------------------------------------------------
Config.notices = {
    enabled = true,
    intervalMinutes = 15,
    -- Toast look (open77_notifications definition fields).
    type = "info",
    title = "Night City",
    icon = "NC",
    position = "top_right",
    durationMs = 10000,
    color = "#F5C400",
    -- Also write the notice in chat, in this colour.
    chatEcho = true,
    chatAuthor = "Night City",
    chatColor = { 245, 196, 0 },
    lines = {
        "Rules: no RDM, no VDM, stay in character. /ooc for out-of-character talk.",
        "New in town? /carte shows your ID card, /civil registers one.",
        "Looking for work? Walk up to the employment agency on the Kabuki Gallery, or type /agence.",
        "Kabuki Market is home. The Afterlife, Lizzie's and Vik's clinic are a short drive south; the nomads and the junkyard are out in the Badlands. /zones lists them.",
        "Cash runs out. /bank at any ATM (Kabuki Market, the Afterlife, Vik's) for an account, /solde for the balance, /payday every 10 minutes.",
        "Hurt? /911 pages Trauma Team. Robbed? /ncpd pages the badges. Both cost eddies.",
        "Kabuki Market is a safe zone. Step outside the ring and you are fair game, choom.",
        "Report griefers with /report. Admins read the tickets.",
    },
}

-- ---------------------------------------------------------------------------
-- (4) NCPD alert sirens
-- ---------------------------------------------------------------------------
Config.alerts = {
    enabled = true,
    -- The one-shot world effect flashed at the alert position and the Wwise event played
    -- spatialised there (Open77.effects.play `sound`). Both names come from the platform's
    -- catalogues; the siren event is a 2.31 seed entry that still awaits runtime validation.
    effect = "sparks.burst.small",
    sound = "amb_g_city_el_signals_police_siren_short_01",
    -- Players within this many metres of the alert see and hear it.
    range = 60.0,
    -- The flash is repeated to read as a strobe; the siren plays once, with the first flash.
    flashes = 3,
    flashIntervalMs = 1200,
    -- One siren per position per this many seconds (rp_ncpd can raise several alerts at once).
    cooldownSeconds = 8,
}

-- ---------------------------------------------------------------------------
-- (5) Ambience loop per zone
-- ---------------------------------------------------------------------------
Config.music = {
    enabled = true,
    -- 0..1 gain of the loop, and the sound id prefix (one loop per player per zone).
    volume = 0.35,
    -- rp_bar already plays its own ambience at the counter: when it runs, the Afterlife loop is
    -- skipped so the two never stack.
    skipWhenResourceRuns = { afterlife = "rp_bar" },
    -- Files must be declared in the manifest `files` entry. The shipped WAVs are synthesised
    -- loops (12 s, seamless); replace them with real assets of at most 1 MiB. The file names
    -- are asset names, not zone names: the hum-and-crackle loop plays inside Lizzie's.
    zones = {
        afterlife = { file = "sfx/afterlife.wav" },
        lizzies   = { file = "sfx/blackmarket.wav" },
    },
}

-- ---------------------------------------------------------------------------
-- Command and log
-- ---------------------------------------------------------------------------
Config.command = {
    name = "ambiance",
    chatAuthor = "Ambiance",
    chatColor = { 0, 229, 255 },
}

-- Keys rp_config may override (`rp_ambiance.<key>` -> Config.<section>.<field>).
-- Read with pcall(exports.rp_config:get, key) at start and on /ambiance reload; the
-- resource keeps working untouched when rp_config does not run.
Config.overrides = {
    { key = "rp_ambiance.realHoursPerDay",        section = "cycle",     field = "realHoursPerDay" },
    { key = "rp_ambiance.weatherMinMinutes",      section = "cycle",     field = "weatherMinMinutes" },
    { key = "rp_ambiance.weatherMaxMinutes",      section = "cycle",     field = "weatherMaxMinutes" },
    { key = "rp_ambiance.badlands",               section = "cycle",     field = "badlands" },
    { key = "rp_ambiance.noticeIntervalMinutes",  section = "notices",   field = "intervalMinutes" },
    { key = "rp_ambiance.figurantsEnabled",       section = "figurants", field = "enabled" },
    { key = "rp_ambiance.musicVolume",            section = "music",     field = "volume" },
    { key = "rp_ambiance.alertsEnabled",          section = "alerts",    field = "enabled" },
}
