-- rp_crime configuration. Every position, price, delay and chance lives here so the
-- owner can move things without touching server/main.lua. Coordinates are world metres,
-- real Night City (measured 2026-09-18): the freeroam spawn is Kabuki Market Centre
-- -1191.30, 2006.88, 7.82 (Watson), the shops are the Kabuki market stalls, the fence
-- works the Rancho Coronado junkyard out in the Badlands.
RpCrimeConfig = {
    -- Chat presentation.
    chat = {
        author = "CRIME",
        color = { 255, 96, 64 },        -- the robber's lines
        ncpdColor = { 0, 229, 255 },    -- the APB line an officer reads
    },

    -- rp_config overrides: every key below may be overridden through
    -- pcall(exports.rp_config:get, "rp_crime.<path>") when rp_config runs (optional).
    configPrefix = "rp_crime.",

    -- Shop robbery (/braquer). The vendors are the rp_shops v2 vendors; rp_shops exposes no
    -- export for their positions, so they are repeated here (keep them in sync with
    -- rp_shops/shared/config.lua). The five real Kabuki Market stalls (walked points); the
    -- keys are rp_shops' shop ids (`blackmarket` is the Lower Walkway stall's id, not a zone).
    robbery = {
        reach = 3.0,                      -- metres from the vendor to start
        finishReach = 5.0,                -- re-checked after the bar (rp_shops:rob applies 5 m too)
        durationMs = 20000,               -- "Emptying the till..." progress bar
        cooldownMs = 20 * 60 * 1000,      -- per shop, on top of rp_shops' own 20 min cooldown
        requireWeaponDrawn = true,        -- Open77.weapons.get(id).drawn must be true
        alertText = "%s is being robbed",
        recordText = "Armed robbery of %s (%d eddies)",
        shops = {
            supermarket = { label = "Noodle Row market",        vendor = "Rosa",     position = { x = -1178.66, y = 2028.45, z = 7.95 } },
            pharmacy    = { label = "The Stalls pharmacy",      vendor = "Dr. Osei", position = { x = -1223.91, y = 1989.45, z = 7.98 } },
            gunshop     = { label = "East Row gun stall",       vendor = "Wilson",   position = { x = -1160.50, y = 2019.06, z = 7.76 } },
            clothes     = { label = "Vendor Lane threads",      vendor = "Kimiko",   position = { x = -1212.26, y = 1978.53, z = 7.98 } },
            blackmarket = { label = "Lower Walkway dealer",     vendor = "Dex",      position = { x = -1201.07, y = 2035.60, z = 5.60 } },
        },
    },

    -- Vehicle theft (/crocheter).
    theft = {
        reach = 4.0,                      -- metres from the vehicle
        durationMs = 12000,               -- "Jimmying the lock..." progress bar
        lockpickItem = "lockpick",        -- rp_inventory built-in item
        lockpickBreakChance = 0.5,        -- consumed 50 % of the time, on success only
        wantedReason = "stolen",          -- rp_garage:setWanted(plate, true, reason)
        hornMs = 300,                     -- a short horn when the lock gives (0 = silent)
        -- On-duty officers within this distance of a wanted vehicle read an APB line every tick.
        spotDistance = 20.0,
        spotTickMs = 30000,
    },

    -- Street deal (/dealer <playerId>).
    deal = {
        item = "drug_pack",               -- declared by rp_gangs in rp_inventory
        price = 120,                      -- eddies, cash, buyer -> dealer
        reach = 3.0,                      -- metres between dealer and buyer
        durationMs = 3000,                -- the synchronized `give` animation
        inviteTimeoutMs = 30000,          -- the buyer has 30 s to /interaction accept
        influence = 1,                    -- rp_gangs:addInfluence(zone, gang, influence, "deal")
        alertChance = 0.20,               -- rp_ncpd:alert("drugs", ...) 20 % of the time
        alertText = "Street deal spotted near %s",
    },

    -- Contraband (/voler): gut a nomad crate that is not yours.
    contraband = {
        reach = 3.0,                      -- metres from the crate prop
        durationMs = 8000,                -- "Prying the crate open..." progress bar
        ownerResource = "rp_nomade",      -- props whose snapshot.resource is this are crates
        item = "stolen_parts",            -- what lands in the pockets
        count = 1,
    },

    -- The fence (/receler and the E prompt on the NPC): the Rancho Coronado junkyard
    -- (Badlands edge), night only.
    fence = {
        name = "Vik the Fence",
        -- nativePrompt: the E prompt on the NPC goes through open77_interactions (a 250 ms world
        -- query on the client). Kept switchable: it was turned off on 2026-09-18 to isolate the
        -- Northside flat crash, which reproduced without it (platform loot bug, not this).
        nativePrompt = false,
        -- Inside the rp_zones `junkyard` zone (centre 1374.9, -1674.9, 49.3 r 90, AMM point):
        -- Vik stands between the wrecks, 9 m north-east of the centre.
        position = { x = 1381.0, y = -1668.0, z = 49.4 },
        yaw = 225.0,
        -- The fence's stash: two cargo crates beside Vik (Open77.props.create on the server,
        -- removed on stop; a refusal only logs). Raw depot meshes of the props catalogue.
        props = {
            { model = "crate.cargo",
              x = 1382.4, y = -1667.0, z = 49.3, yaw = 30.0 },
            { model = "crate.cargo",
              x = 1379.6, y = -1666.9, z = 49.3, yaw = 100.0 },
        },
        reach = 5.0,                      -- metres for /receler and the prompt (server re-check)
        openHour = 22,                    -- [openHour, closeHour) in server world time
        closeHour = 6,
        openWithoutClock = true,          -- no open77_weather = never closed (logged once)
        promptLabel = "Sell stolen goods",
        promptDescription = "Cash for anything that fell off a truck",
        promptKey = "E",
        promptDistance = 2.5,
        -- NPC look: legacy aliases tried in order (Open77.npcs.templates()), then the raw records.
        -- Only these four aliases are validated on this build; a Character.* record from the
        -- catalogue may be put first in `records` once proven on your clients.
        aliases = { "gang_tygerclaws_ranged_01", "gang_valentinos_ranged_01", "civilian_female_relaxed_01" },
        records = { "Character.Judy" },
        damagePolicy = 2,                 -- numeric: 2 = invulnerable
        stolenPartsPrice = 300,           -- eddies per stolen_parts
        implantRatio = 0.40,              -- share of the ripper's price paid for an implant_box_* item
        -- The ripper's prices per boxed implant id (rp_ripperdoc). Unknown ids use `default`.
        implantPrices = {
            default = 1000,
        },
        greetingVoice = "greeting",       -- Open77.npcs.speak voContext names
        closedVoice = "rep_ask_to_leave",
    },

    -- Items declared in rp_inventory through exports.rp_inventory:define.
    items = {
        stolen_parts = { label = "Stolen parts", weight = 2.0, usable = false, illegal = true },
    },

    -- Staging (2026-09-18 pass): every crime that manipulates something plays a pose, shows
    -- a prop and takes its time behind the UI-kit bar, so witnesses see it. Same rules as
    -- rp_mecano / rp_nomade: `pose.profiles` are open77_animations profiles tried in order
    -- through Open77.animations.get (best FUTURE name first -- a base PR is adding a lockpick
    -- profile -- then what today's 18-profile eval catalogue has); `loop = true` is held for
    -- the bar and stopped by the server, `loop = false` is a one-shot of `durationMs`. Props
    -- are curated aliases (see `prop.catalog`) tried in order (future alias first), attached
    -- to a rig slot ("RightHand", "LeftHand") or to the body root (`bone = ""`); hand-slot
    -- axes are not measured on 2.31, start from zero and move one axis at a time. A workspot
    -- is cancelled when the player moves > 0.5 m; the bar keeps them still (client side).
    stage = {
        enabled = true,
        color = "#FF6040",
        -- /braquer: the robber keeps the iron on the vendor, so NO pose (a workspot would
        -- take the weapon out of the hands); the loot bag appears in the left hand once the
        -- till is empty (one-shot, no bar).
        robbery = {
            durationMs = 20000,
            label = "Emptying the till...",
        },
        loot = {
            durationMs = 4000,
            prop = { models = { "container.duffel", "garbage.bag" }, bone = "LeftHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- /crocheter: crouched at the door lock for the whole bar (future `lockpick`; the pick
        -- itself is too small for a prop until a `tool.lockpick` alias exists).
        lockpick = {
            durationMs = 12000,
            label = "Jimmying the lock...",
            pose = { profiles = { { profile = "lockpick" }, { profile = "examine" } }, loop = true },
        },
        -- /dealer: the platform's `give` interaction animates both players; this only puts the
        -- pack in the dealer's hand from the offer to the hand-over (prop only).
        deal = {
            prop = { models = { "crime.drug_pack", "crate.ammo_box" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- /voler: crouched at the crate, blade under the lid, for the whole bar; then the parts
        -- held up for a moment.
        pry = {
            durationMs = 8000,
            label = "Prying the crate open...",
            pose = { profiles = { { profile = "lockpick" }, { profile = "examine" } }, loop = true },
        },
        parts = {
            durationMs = 2500,
            pose = { profiles = { { profile = "give" } }, loop = false },
            prop = { models = { "debris.scrap", "crate.ammo_box" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- /receler: the goods held out to Vik behind a short bar.
        fence = {
            durationMs = 3000,
            label = "Showing the goods",
            pose = { profiles = { { profile = "carry_putdown" }, { profile = "give" } }, loop = true },
            prop = { models = { "debris.scrap", "crate.ammo_box" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
    },

    -- Persistence.
    database = {
        table = "rp_crime_log",
        graceMs = 15000,                  -- wait this long for the database before falling back to kvp
        kvpKeep = 200,                    -- rows kept in the kvp fallback
    },
}
