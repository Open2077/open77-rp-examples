-- rp_ncpd configuration. Shared by the server and the client (both read Config.*).
-- Every world position lives here so the owner can move the precinct without touching code.
Config = {
    -- The rp_zones zone the precinct lives in (informative: the cell and entrance below are
    -- absolute positions inside it, the server never asks rp_zones where to teleport).
    -- The real NCPD building, city centre: the conference room is the AMM point
    -- -1761.5, -1010.8, 94.3 (yaw 90.7), the rp_zones `ncpd_hq` centre (radius 30).
    zone = "ncpd_hq",

    -- Holding cell: 6 m east of the conference room point.
    -- If a prisoner lands in the ground, stand on the spot, /pos, and paste the height.
    cell = { x = -1755.5, y = -1010.8, z = 94.3, heading = 270.0, radius = 6.0 },

    -- Where a released prisoner is put: the desk, 4 m north of the conference room point.
    entrance = { x = -1761.5, y = -1006.8, z = 94.3, heading = 90.7 },

    -- The Kabuki-side patrol outpost: a ring and a floating label on the real street outside
    -- the Afterlife ramp (probed crosswalk -1408.0, 960.0, 23.5; ring z + 0.1). Radio / status
    -- point for patrols only: nothing to press, no teleport. `props` are spawned by the server
    -- (Open77.props.create, removed on stop; a refusal only logs) - raw depot meshes.
    outpost = {
        x = -1416.0, y = 957.0, z = 23.6, radius = 3.0,
        label = "NCPD - Afterlife street outpost",
        description = "Patrol radio and status point. Badges only.",
        color = "#408CFF",
        maxDistance = 120.0,
        labelDistance = 40.0,
        props = {
            { model = "sign.rect.keep_out",
              x = -1409.4, y = 960.8, z = 23.5, yaw = 90.0 },
            { model = "barrier.road",
              x = -1406.6, y = 961.2, z = 23.5, yaw = 0.0 },
        },
    },

    -- Officer-to-suspect distance for cuff / search / seize / fine / jail (metres).
    -- open77_rp_basics applies its own 3 m rule on top for cuff and escort.
    actionDistance = 3.0,
    -- Camera-ray distance the ALT+click actions accept (metres).
    menuDistance = 3.5,

    vehicle = {
        range = 5.0,        -- the officer must be within this of a server vehicle (or seated in it)
        lockExit = true,    -- a seated suspect cannot open the door until taken out
        preferRear = true,  -- back seats first, like a real cruiser
    },

    prison = {
        minMinutes = 1,
        maxMinutes = 120,
        notifyEverySeconds = 60,    -- "x minutes left" toast cadence
        leashCheckMs = 5000,        -- how often a prisoner's distance to the cell is checked
        persistEverySeconds = 60,   -- remaining time written to SQL this often (and on disconnect)
    },

    fine = {
        min = 1,
        max = 100000,
        inviteTimeoutMs = 30000,    -- the citizen has this long to /interaction accept
        autoWarrantLevel = 1,       -- warrant level for a declined or unpaid fine
    },

    warrant = {
        -- Mirror the warrant level into the native NCPD heat of the wanted player's own game
        -- (Open77.players.setWanted). Off by default: native police are local AI that shoot
        -- the player on their own client, which an RP server with real officers rarely wants.
        nativeHeat = false,
    },

    alert = {
        blipMs = 60000,             -- how long the temporary map pin of an alert lives
        sprite = "danger",          -- Open77.blips alias
    },

    voice = {
        enabled = true,
        channelName = "NCPD dispatch",
        effect = { highPassHz = 220.0, lowPassHz = 4800.0, distortion = 0.08, radioNoise = 0.04, spatialBlend = 0.0 },
    },

    -- Hand the RP kit's rights (rp.cuff, rp.escort, rp.search) to an officer while on duty and
    -- take them back off duty, through Open77.acl.grant / revoke. Needs the scoped manifest
    -- permission "acl.grant:rp.*" (see open77.lua), which the devkit validator rejects as of
    -- 0.1.x although the ACL guide documents it - so it ships OFF: the operator grants rp.cuff,
    -- rp.escort and rp.search to the police accounts in acl.jsonc once (README, "Setup").
    grantKitRights = false,
    kitRights = { "rp.cuff", "rp.escort", "rp.search" },

    record = { maxLines = 20 },

    -- Staging (2026-09-18 pass): every police action that touches a suspect plays a pose,
    -- takes its time behind a UI-kit bar, and the suspect wears the matching pose, so the
    -- street sees it. Same rules as rp_mecano / rp_nomade: `pose.profiles` are
    -- open77_animations profiles tried in order through Open77.animations.get (best FUTURE
    -- name first, then what today's 18-profile eval catalogue has); `loop = true` is held
    -- for the bar (or until released) and stopped by the server, `loop = false` is a
    -- one-shot of `durationMs`. A workspot is cancelled by the platform when the player
    -- moves > 0.5 m: the bar keeps the officer still (client side, never a server freeze),
    -- and an escorted suspect naturally drops the cuffed pose while walking. The holds
    -- themselves stay the RP kit's (open77_rp_basics): if the kit already poses the
    -- suspect, the `cuffed` pose answers animation_owned and is logged once.
    Stage = {
        enabled = true,
        color = "#408CFF",
        -- Cuffing: the officer reaches for the wrists behind a short bar.
        cuff = {
            durationMs = 3000,
            label = "Cuffing the suspect",
            pose = { profiles = { { profile = "give" } }, loop = true },
        },
        -- The cuffed suspect: hands up until released (future `cuffed` = hands behind the back).
        cuffed = {
            pose = { profiles = { { profile = "handsback" }, { profile = "handsup" } }, loop = true },
        },
        -- Searching the pockets: the officer bends over the suspect (future `frisk`).
        search = {
            durationMs = 4000,
            label = "Searching the pockets",
            pose = { profiles = { { profile = "frisk" }, { profile = "examine" } }, loop = true },
        },
        seize = {
            durationMs = 3000,
            label = "Seizing the contraband",
            pose = { profiles = { { profile = "frisk" }, { profile = "examine" } }, loop = true },
        },
        -- A fine: the officer writes the ticket on the holo (one-shot, no bar; the consent
        -- prompt is the wait).
        fine = {
            durationMs = 3000,
            pose = { profiles = { { profile = "phone" } }, loop = false },
        },
        -- Booking (/prison): the officer files it on the holo before the transfer.
        book = {
            durationMs = 4000,
            label = "Booking the suspect",
            pose = { profiles = { { profile = "phone" } }, loop = true },
        },
    },

    colors = {
        ncpd = { 64, 140, 255 },
        radio = { 90, 180, 255 },
        alert = { 255, 120, 0 },
        warn = { 255, 80, 80 },
    },
}
