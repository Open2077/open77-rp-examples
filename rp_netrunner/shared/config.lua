-- rp_netrunner: shared configuration (server and client read the same table).
-- Every position is world metres; the freeroam spawn is Kabuki Market Centre
-- -1191.30, 2006.88, 7.82 (Watson) and the access point sits in the Afterlife's back room.
Config = {}

-- The job (rp_jobs v2) and the duty requirement every contract checks.
Config.job = "netrunner"

-- Cooldown per contract kind, per netrunner (ms).
Config.cooldownMs = 30000

-- Probability that a contract leaves a trace: an rp_ncpd record on the netrunner
-- plus an rp_ncpd:alert at the position of the hack (0 = never, 1 = always).
Config.traceChance = 0.5

-- Quickhack items, declared through exports.rp_inventory:define (rp_inventory shape).
-- One unit is debited per contract; all of them are contraband for the NCPD.
Config.items = {
    qh_ping          = { label = "Quickhack: Ping",          weight = 0.05, usable = false, illegal = true },
    qh_short_circuit = { label = "Quickhack: Short Circuit", weight = 0.05, usable = false, illegal = true },
    qh_overheat      = { label = "Quickhack: Overheat",      weight = 0.05, usable = false, illegal = true },
    qh_jammer        = { label = "Quickhack: Jammer",        weight = 0.10, usable = false, illegal = true },
}

-- The netrunner's operating system: one cyberdeck definition (Open77.hacking.define +
-- Open77.cyberware.define, same id / version / grade ids, slot operating_system).
-- One grade = one hack kind; the deck holds ONE grade at a time, so a Short Circuit deck
-- must be reloaded with the Overheat grade before an Overheat (the resource does it for
-- you and asks you to run the command again once the implant is committed).
Config.deck = {
    id = "rp_netrunner.deck",
    version = 1,
    -- Price in cash (rp_economy) charged when the netrunner loads a grade; 0 = free.
    price = 0,
}

-- Player-targeted hacks: item consumed, range (metres, 1-80) and the grade fields the
-- platform documents (hacking guide: "Hack grade" / "What each kind does").
Config.hacks = {
    short_circuit = {
        item = "qh_short_circuit",
        label = "Short Circuit",
        range = 25,
        uploadMs = 2000,
        staminaCost = 20,
        damage = 25,
        statusMs = 750,        -- the disruption, 0-2000 ms (documented default 750)
        recoveryMs = 4000,     -- nobody can hack the victim again inside it
        nonlethal = true,
    },
    overheat = {
        item = "qh_overheat",
        label = "Overheat",
        range = 25,
        uploadMs = 2500,
        staminaCost = 20,
        damage = 10,
        statusMs = 750,
        recoveryMs = 4000,
        nonlethal = true,
        -- the burn ticked by the server (documented defaults: 40 dmg over 5 s, 500 ms ticks)
        burn = { totalDamage = 40, durationMs = 5000, tickMs = 500 },
    },
}

-- Ping: a tracking blip on the target for the netrunner only.
Config.ping = {
    item = "qh_ping",
    range = 50,            -- metres between the netrunner and the target when the ping is sent
    durationMs = 60000,    -- how long the blip follows the target
    refreshMs = 2000,      -- server relay period of the target's position
    sprite = "objective",  -- map-capable vanilla sprite (blips guide: stable aliases)
    warnTarget = false,    -- true = the target reads "Your optics flicker" when pinged
}

-- Jam NCPD radio: rp_netrunner:jammed(true/false) on the host bus for the whole window and
-- a static-noise line to every on-duty officer every noiseEveryMs.
Config.jam = {
    item = "qh_jammer",
    durationMs = 60000,
    noiseEveryMs = 15000,
    noise = {
        "kzzzt--- ...all units... ---tsszzk--- [CARRIER LOST]",
        "\226\150\147\226\150\146\226\150\145 ...10-4... ...repeat... \226\150\145\226\150\146\226\150\147 [SIGNAL DEGRADED]",
        "---bzzzt--- ...dispatch, do you--- ---kzzz--- [NO CARRIER]",
        "\226\150\145\226\150\146\226\150\147 ...code 3... ...unreadable... \226\150\147\226\150\146\226\150\145 [ICE ON THE LINE]",
    },
}

-- Breach: the access point (a prop + a ring + an E prompt), the bar, the door search and
-- the data bounty paid when no networked door is within doorRadius.
Config.accessPoint = {
    -- The Afterlife's safe area (the back room, AMM -1419.9, 989.4, 16.5; ring z + 0.1), inside
    -- the rp_zones `afterlife` zone, 1.0 km south-west of the spawn. If the ring is invisible,
    -- stand on the spot, /pos, and paste the ground height here.
    position = { x = -1419.9, y = 989.4, z = 16.6 },
    label = "Access point - Afterlife back room",
    description = "Jack in and breach the local subnet.",
    radius = 1.2,
    promptDistance = 3.0,
    reach = 4.0,               -- the server re-checks the netrunner stands this close
    prop = {
        -- The breach terminal: a data terminal from the props catalogue (raw depot mesh);
        -- when the mesh is refused on this build the curated alias below is tried, then the
        -- ring alone marks the spot. Set model = false to spawn nothing.
        model = "electronics.server",
        fallbackModel = "electronics.server",
        yaw = 180.0,
        offset = { x = 0.0, y = 1.2, z = -0.1 }, -- the terminal stands just behind the ring, on the floor
    },
}

Config.breach = {
    item = "chip",              -- a data chip (rp_inventory built-in) is burned per breach; nil = no item
    durationMs = 10000,         -- the "Breaching..." progress bar
    doorRadius = 15.0,          -- nearest open77_doors door within this radius is opened
    doorHoldMs = 30000,         -- a door this resource had to claim is released after this delay
    bounty = 200,               -- cash paid to the netrunner when no door is there (data sale)
    societyBounty = 100,        -- the netrunner society's cut of the data sale (rp_bank)
}

-- Staging (2026-09-18 pass): the breach plays a pose, shows the deck and takes its time behind
-- the UI-kit bar, so the room sees the netrunner jack in. Same rules as rp_mecano / rp_nomade:
-- `pose.profiles` are open77_animations profiles tried in order through Open77.animations.get
-- (best FUTURE name first, then what today's 18-profile eval catalogue has); `loop = true` is
-- held for the bar and stopped by the server, `loop = false` is a one-shot of `durationMs`.
-- Props are curated aliases (see `prop.catalog`) tried in order (future alias first), attached
-- to the body root (`bone = ""`: +y facing, +x right, +z up, origin at the feet) or a rig slot.
-- The player-targeted hacks (Short Circuit / Overheat) are NOT staged: the platform's own
-- upload owns the body for those, a second workspot would answer animation_busy.
Config.Stage = {
    enabled = true,
    color = "#00E5FF",
    -- Breach: both hands on the deck (the `phone` tap is the closest typing pose today), the
    -- deck itself held in front of the chest at forearm height, screen towards the runner.
    breach = {
        durationMs = 10000,
        label = "Breaching...",
        pose = { profiles = { { profile = "laptop" }, { profile = "tablet2" }, { profile = "phone" } }, loop = true },
        prop = { models = { "electronics.laptop", "electronics.monitor" }, bone = "", offset = { x = 0.0, y = 0.5, z = 0.95 }, rotation = { x = 0.0, y = 0.0, z = 180.0 } },
    },
    -- Ping and the jammer: a quick tap on the deck (one-shot, no bar).
    ping = {
        durationMs = 3000,
        pose = { profiles = { { profile = "phonecheck" }, { profile = "phone" } }, loop = false },
    },
    jam = {
        durationMs = 4000,
        pose = { profiles = { { profile = "phonecheck" }, { profile = "phone" } }, loop = false },
    },
}

-- Chat colours (positional { r, g, b }).
Config.colors = {
    net = { 0, 229, 255 },
    warn = { 255, 120, 0 },
    static = { 130, 130, 130 },
}
