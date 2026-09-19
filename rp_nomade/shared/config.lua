-- rp_nomade configuration. Loaded on both runtimes (shared_script): the client reads the
-- positions to draw rings and prompts, the server checks every distance against the same numbers.
-- Every position is in world metres, a real Night City / Badlands place (AMM and walked points,
-- 2026-09-18). The freeroam spawn is Kabuki Market Centre (-1191.3, 2006.9, 7.8).
RpNomadeConfig = {}

-- The nomad camp: the Aldecaldos camp in the north-eastern Badlands, around V's nomad tent
-- (AMM 1792.9, 2248.9, 180.2, yaw 58.6) -- the `nomad_camp` zone of rp_zones (same centre,
-- radius 120). Rings use the AMM ground + 0.1; the camp is not flat, so if a ring is invisible
-- in game, stand on the spot, `/pos`, and paste the ground height.
RpNomadeConfig.Camp = {
    zone = "nomad_camp",                                   -- rp_zones name used for the truck return
    position = { x = 1792.9, y = 2248.9, z = 180.2 },      -- camp centre (V's tent), what /camp reports
    -- The contracts board: a ring, a map pin and an E prompt (open77_worldui).
    board = {
        position = { x = 1790.0, y = 2252.0, z = 180.3 },
        radius = 1.0,
        promptDistance = 3.0,
        reach = 5.0,                                       -- server-side distance check when the prompt fires
        label = "Aldecaldos contracts board",
        description = "Convoys and crate runs for the clan.",
    },
    -- The truck bay: where the rented truck appears, 12 m south-east of the board. The yaw is
    -- the tent's own heading (AMM 58.6); the road's heading was not measured -- `/pos` in the
    -- truck facing the road and paste the yaw here.
    truckSpawn = { x = 1800.0, y = 2240.0, z = 180.2, yaw = 58.6 },
    -- Loading points: one crate per point, in order, 4-6 m north of the board. Templates never
    -- ask for more crates than points.
    loadingPoints = {
        { x = 1786.0, y = 2256.0, z = 180.3 },
        { x = 1788.0, y = 2258.0, z = 180.3 },
        { x = 1790.0, y = 2258.5, z = 180.3 },
        { x = 1792.0, y = 2257.0, z = 180.3 },
    },
    -- Decoration spawned by the server at start (Open77.props.create, permission `world.props`)
    -- and removed at stop: two cargo crates 1.2 m off the board ring. Raw depot `.mesh` paths
    -- from the props catalogue; a refused prop is logged, never fatal.
    props = {
        { model = "crate.cargo",
          position = { x = 1788.2, y = 2253.6, z = 180.2 }, yaw = 58.6 },
        { model = "crate.cargo",
          position = { x = 1791.8, y = 2253.8, z = 180.2 }, yaw = 40.0 },
    },
}

-- Delivery destinations, keyed by rp_zones name. The server asks rp_zones:isIn(driver, name);
-- the ring is drawn at `position` (radius `radius`, capped at 50 m by the client) and the
-- distance fallback (rp_zones missing) uses `radius`. A destination rp_zones does not know
-- carries `zone = false`: it is then a planar-distance check against `radius` only.
RpNomadeConfig.Destinations = {
    junkyard = {
        label = "Rancho Coronado junkyard",
        position = { x = 1374.9, y = -1674.9, z = 49.4 },
        radius = 30.0,
    },
    afterlife_street = {
        label = "Watson, the Afterlife street",
        -- The street outside the Afterlife ramp, 20 m up from the garage lot: with the
        -- point ON the lot ring the "Afterlife street lot" prompt beat the truck's Unload
        -- prompt (bot run 19 Sept); here the truck's own card wins. Kabuki's lanes are
        -- pedestrian, no truck fits there. Not an rp_zones zone: planar check.
        position = { x = -1426.0, y = 974.0, z = 23.6 },
        radius = 25.0,
        zone = false,
    },
    drive_in = {
        label = "Badlands Drive-In Theater",
        position = { x = -81.2, y = 1963.3, z = 100.8 },
        radius = 40.0,
        zone = false,                                          -- no rp_zones zone: distance only
    },
}

-- Contract templates offered on the board. `crates` 2..4, `destination` a key of Destinations.
RpNomadeConfig.Templates = {
    {
        id = "scav_parts",
        label = "Scav parts run",
        description = "Three crates of stripped parts for the Rancho Coronado junkyard. No questions.",
        crates = 3,
        destination = "junkyard",
    },
    {
        id = "chooh2_barrels",
        label = "CHOOH2 barrels",
        description = "Two crates of fuel cans for the garage on the Afterlife street, Watson. Do not smoke on the way.",
        crates = 2,
        destination = "afterlife_street",
    },
    {
        id = "militech_salvage",
        label = "Militech salvage",
        description = "Four crates nobody should ask about, dropped at the old Drive-In. Heavy, and the Wraiths know.",
        crates = 4,
        destination = "drive_in",
    },
}

RpNomadeConfig.Contract = {
    payPerCrate = 150,          -- eddies, cash, paid to the driver per delivered crate
    convoyBonus = 0.25,         -- share of the gross pay, split between the convoy members
    convoyRadius = 30.0,        -- nomads on duty within this distance of the truck at delivery form the convoy
    convoyMinimum = 2,          -- driver included: two or more nomads = a convoy
    societyShare = 0.15,        -- share of the gross pay credited to the `nomade` society (on top of the pay)
    society = "nomade",         -- rp_bank society name (lower-case job name)
    timeLimitMs = 20 * 60 * 1000,
    unloadMs = 6000,            -- progress bar per crate at the warehouse
    historyRows = 10,           -- /convois: last N contracts
}

RpNomadeConfig.Truck = {
    -- Player-spawnable records (they end in _player) tried in order until one spawns.
    -- Thorton Mackinaw: the nomad pickup. Legatus: a heavy Chevalier truck.
    records = {
        "Vehicle.v_standard3_thorton_mackinaw_player",
        "Vehicle.v_standard3_thorton_mackinaw_02_player",
        "Vehicle.v_utility4_chevalier_legatus_player",
    },
    rental = 100,               -- eddies, cash, refunded when the truck is returned inside the camp zone
    reach = 4.0,                -- load / unload / return: the player must be within this distance of the truck
    ttlMs = 40 * 60 * 1000,     -- safety net: the vehicle registry removes a forgotten truck after this
    -- nativePrompts: Load / Unload / Return as E prompts on the truck through open77_interactions.
    -- Switchable: turned off 2026-09-18 to isolate the Northside flat crash (reproduced without it).
    nativePrompts = true,
    -- The bed: a loaded crate is attached to the truck (Open77.props.attach, parentType "vehicle",
    -- root binding) so everybody sees the cargo. Offsets are metres in the VEHICLE frame: +x right,
    -- +y forward (the cab), -y behind the cab, +z up; `yaw` degrees around z. The Mackinaw's bed
    -- sits behind the cab, roughly x in [-0.6, 0.6], y in [-2.6, -1.0], z ~0.9: these are starting
    -- guesses, not measurements. Tune them with a loaded truck in front of you: raise `z` if a crate
    -- sinks into the bed floor, move `y` towards -1.0 if it hangs off the tailgate. Crate n takes
    -- slot ((n - 1) % #slots) + 1; when there are more crates than slots the next layer stacks
    -- `stackHeight` metres higher on the same slots.
    bed = {
        slots = {
            { x = -0.55, y = -1.5, z = 0.9, yaw = 0.0 },
            { x =  0.55, y = -1.5, z = 0.9, yaw = 0.0 },
            { x = -0.55, y = -2.4, z = 0.9, yaw = 0.0 },
            { x =  0.55, y = -2.4, z = 0.9, yaw = 0.0 },
        },
        stackHeight = 0.55,
    },
}

RpNomadeConfig.Crate = {
    -- Curated prop aliases tried in order. Attachment to a hand needs an alias (a raw .mesh path
    -- spawns a standing crate but cannot be attached, the carry then hides the prop instead).
    models = { "crate.small" },
    pickupDistance = 3.5,       -- server-side check when the crate prompt fires (prompt itself: 3.0 m)
    promptDistance = 3.0,
    ringRadius = 0.6,
    label = "Pick up the crate",
    description = "Heavy. Get it to the truck.",
}

-- How a carried crate is shown. "attach": the crate prop rides the carrier (Open77.props.attach,
-- everyone sees it). "held": the prop is hidden and an item record is put in the right hand through
-- Open77.heldItems.hold (needs the bundled open77_helditems client).
--
-- The binding is the one of wiki/attachments.md: `bone` is a named slot of the player rig
-- ("RightHand", "LeftHand", "Chest", "Head") or "" for the body root; `offset` is metres in that
-- slot's OWN frame and `rotation` degrees (x roll, y pitch, z yaw). The root frame is the only one
-- whose axes are known for sure: +y is where the player faces, +x their right, +z up, origin at the
-- feet. A hand slot follows the arm swing, so the crate would swing with it; the root keeps the box
-- level in front of the torso whatever the arms do, which is what a two-hand carry looks like.
-- Numbers below are measured guesses for `crate.small`: the crate's pivot is ~0.45 m in front of
-- the spine, its bottom ~0.85 m off the ground (forearm height). For `crate.cargo` (~0.9 m cube)
-- try y = 0.6, z = 0.7. If the box sits in the body, raise `y`; if it floats, lower `z`.
-- A slot the rig does not expose hides the crate (`bone_unavailable` on the client); "" always exists.
RpNomadeConfig.Carry = {
    mode = "attach",
    bone = "Chest",   -- base PR #39 measured: hands midpoint of the carry pose in the Chest slot frame
    offset = { x = -0.135, y = -0.60, z = 0.008 },   -- tuned in game 2026-09-19 (crate.small, carry pose)
    rotation = { x = 0.0, y = 90.0, z = 0.0 },       -- the crate mesh lies on its side in the Chest slot frame
    -- What the carrier's OWN client draws while its camera is first-person (`firstPerson` of
    -- Open77.props.attach, wiki/attachments.md). The numbers above are for the third-person rig
    -- (F7 body, other players' proxies); on V's own rig the Chest slot sits under the camera and
    -- the same offset puts the crate's lid over the whole screen (seen 2026-09-19). In the Chest
    -- frame +x is up and -y forward, so this is the third-person spot 0.35 m lower and 0.15 m
    -- further out: crate low in the view, top edge under the crosshair. A measured guess -- tune
    -- with `carrytune <player> fpp x y z [rx ry rz]` from the console -- or `"hide"` to draw no
    -- crate at all in first person.
    firstPerson = { offset = { x = -0.485, y = -0.75, z = 0.008 }, rotation = { x = 0.0, y = 90.0, z = 0.0 } },
    heldItem = { record = "Items.GenericCraftingMaterial1", slot = "WeaponRight" },
    -- The carry pose: a synchronized RP animation (Open77.animations.play, permission
    -- players.animations.control) looped for as long as the crate is held and stopped on load /
    -- drop / cancel / disconnect / death. Profiles are tried in order at start; the first one the
    -- server's open77_animations catalogue knows is used. No catalogue on 2.31 ships a box-carry
    -- clip: `tablet2` (76-profile catalogue, two hands holding a tablet at chest height) and
    -- `phone` (18-profile catalogue, `stand__2h_phone__03__shuffle__01`: both hands in front of
    -- the chest, no tapping) are the closest two-hand holds. `clip` must belong to the profile.
    -- RP animations are workspots: the platform cancels them as soon as the player walks more
    -- than 0.5 m (or gets in a vehicle, or dies); locomotion is never frozen. `resume` replays the
    -- pose once the carrier has stood still for `resumeAfterMs` (moved less than `stillDistance`
    -- between two server ticks), so the box is held again at the truck. Set `enabled = false` to
    -- carry with the crate only.
    animation = {
        enabled = true,
        profiles = {
            { profile = "carry" },      -- base PR #39: upper-body body-carry layer, locomotion kept
            { profile = "tablet2" },
            { profile = "phone", clip = "stand__2h_phone__03__shuffle__01" },
        },
        resume = true,
        resumeAfterMs = 1500,
        stillDistance = 0.15,
    },
    -- One-shot clips around every crate move, all server-driven so everybody sees them. Each step
    -- plays a profile (tried in order, first known one wins; `clip` optional) for `ms`, and the
    -- prop move (attach / detach / place) happens WHEN THE TIMER ENDS, never instantly. No
    -- catalogue exposes clip lengths (Open77.animations: durationMs is a scheduling duration),
    -- so `ms` is the visible length of the step: tune it to the clip. No shipped profile is a real
    -- "lift a box" / "put a box down": the kneel-to-the-ground profiles (`scavenge`, 76-profile;
    -- `examine`, 18-profile) stand in for bending to pick up and to put down, `give` (arms
    -- extend to hand an item over) stands in for lifting into / taking out of the bed.
    steps = {
        pickup  = { profiles = { { profile = "carry_pickup" }, { profile = "scavenge" }, { profile = "examine" } }, ms = 1400 },
        load    = { profiles = { { profile = "give" } }, ms = 2000 },
        take    = { profiles = { { profile = "give" } }, ms = 2000 },   -- out of the bed, at delivery
        carryMs = 1500,                                                -- carry loop between take and put-down
        putdown = { profiles = { { profile = "carry_putdown" }, { profile = "scavenge" }, { profile = "examine" } }, ms = 2400 },
        -- Delivered crates stay on the ground beside the truck (a row starting `groundGap` m away
        -- from the truck on the player's side) for `groundTtlMs`, or until the run ends.
        groundTtlMs = 30000,
        groundGap = 1.2,
        groundSpacing = 0.9,
    },
}

-- Navigation: a map pin (Open77.blips, client, permission ui.vanilla.map) on the destination from
-- acceptance, the vanilla GPS route (Open77.blips.setWaypoint) once every crate is in the truck
-- (`gpsFrom = "accepted"` to route from acceptance), then a pin + route on the camp for the
-- return leg after the delivery. Everything is removed on unload / cancel / return / disconnect.
RpNomadeConfig.Navigation = {
    enabled = true,
    gpsFrom = "loaded",         -- "loaded" | "accepted"
    destinationSprite = "objective",
    campSprite = "quest",
}

-- The ambush: the FIRST time a loaded truck is inside this circle (and at least minTravel metres
-- from where it was rented), hostile NPCs spawn around it. The circle sits on the road between
-- the camp and the junkyard, ~1600, 600: the check is planar (z is not used), and the exact
-- road point was not measured -- at replay time, drive the road and use `groundz <playerId>
-- 1600 600` (rp_taxitest console) or `/pos` on the road to refine the centre. The radius is
-- wide enough to catch the road wherever it passes near that point.
RpNomadeConfig.Ambush = {
    enabled = true,
    center = { x = 1600.0, y = 600.0, z = 100.0 },
    radius = 60.0,
    minTravel = 10.0,
    count = 3,
    spawnDistance = 15.0,
    spreadDegrees = 35.0,
    lifetimeMs = 3 * 60 * 1000,
    -- Character.* records tried in order. The Maelstrom grunt is the platform's validated ranged
    -- combatant (legacy alias hostile_female_ranged_lab); swap in a Wraith record from the
    -- npc-catalogue once it is proven on your build.
    records = { "Character.cpz_maelstrom_grunt1_ranged1_lexington_wa" },
    damagePolicy = 0,           -- numeric: 0 = mortal (normal), 2 = invulnerable
    group = "rp_nomade_ambush", -- combat group: the ambushers never shoot each other
    announce = "Wraiths on the road! Raffen shivs closing on the convoy.",
}

-- Item declared in rp_inventory (exports.rp_inventory:define) so the crates exist as inventory items too.
RpNomadeConfig.Items = {
    nomad_crate = { label = "Nomad cargo crate", weight = 25.0, usable = false, illegal = false },
}

RpNomadeConfig.Ui = {
    tickMs = 1000,              -- server tick: deadline, ambush zone, truck watch
    color = "#F2B33D",          -- sand: the nomad colour on rings and prompts
    prefix = "[Convoys] ",
}
