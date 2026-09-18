-- rp_mecano configuration. Shared with the client (nothing secret in here).
-- Every world position lives in this file so the owner can move it.
Config = {
    -- rp_jobs job name and rp_bank society name of the garage.
    job = "mecano",
    society = "mecano",

    -- The freeroam spawn: Kabuki Market Centre (Watson), walked point.
    spawn = { x = -1191.30, y = 2006.88, z = 7.82 },

    -- The workshop: the real street outside The Afterlife's ramp (Little China, Watson),
    -- probed 2026-09-18, has a crosswalk, a car fits. A bare ring (open77_worldui,
    -- nothing to press: every command works wherever the car is) and the props below.
    workshop = {
        position = { x = -1396.0, y = 966.0, z = 23.5 },
        radius = 3.0,
        label = "Afterlife street garage",
    },

    -- The CHOOH2 pump: 6 m along the same street. Ring only; /plein works
    -- anywhere with a can, the pump is where a mechanic would park to do it.
    pump = {
        position = { x = -1390.0, y = 972.0, z = 23.5 },
        radius = 1.5,
        label = "CHOOH2 pump",
    },

    -- Decoration spawned by the server at start (Open77.props.create, permission
    -- `world.props`) and removed at stop: the garage sign and two tyre blockers on the
    -- pavement side of the workshop ring (x -1394..-1392), the pump itself by the pump ring.
    -- Raw depot `.mesh` paths from the props catalogue; a refused prop is logged, never fatal.
    props = {
        { model = "sign.street",
          position = { x = -1392.4, y = 966.0, z = 26.0 }, yaw = 90.0 },
        { model = "barrier.tire_blocker",
          position = { x = -1393.2, y = 963.0, z = 23.5 }, yaw = 0.0 },
        { model = "barrier.tire_blocker",
          position = { x = -1393.2, y = 969.0, z = 23.5 }, yaw = 0.0 },
        { model = "industrial.gas_pump",
          position = { x = -1392.0, y = 973.0, z = 23.5 }, yaw = 90.0 },
    },

    -- /reparer
    repair = {
        reach = 4.0,            -- metres from the mechanic to the vehicle (or seated in it)
        durationMs = 15000,     -- progress bar length
        components = 2,         -- rp_inventory `component` units consumed
        requireToolkit = true,  -- a `toolkit` must be in the pockets (not consumed)
        scope = "full",         -- Open77.vehicles.repair scope
    },

    -- /remorquer
    tow = {
        reach = 8.0,            -- metres from the mechanic's truck to the vehicle to hook
        tickMs = 2000,          -- the towed vehicle is moved every tick
        distance = 6.0,         -- metres behind the truck
        minMove = 0.3,          -- skip the tick when the truck moved less than this
        -- Forward vector from the yaw: x = yawSign * sin(yaw), y = cos(yaw). Yaw 0 faces +y
        -- on this engine; the rotation sign is calibrated at runtime against the truck's
        -- velocity, this is only the starting guess.
        yawSign = -1,
    },

    -- /peindre
    paint = {
        reach = 6.0,
        price = 250,            -- eddies billed to the driver through the invoice flow
        colours = {
            black = "#0B0B0D", white = "#F2F2F2", grey = "#7A7F86", silver = "#C0C6CC",
            chrome = "#D9DDE2", red = "#C8102E", crimson = "#7D0A1E", orange = "#FF6A00",
            yellow = "#F5D000", gold = "#C9A227", green = "#1F7A3A", lime = "#7CFC00",
            teal = "#00A99D", cyan = "#00D8FF", blue = "#1F5FBF", navy = "#0F2A5A",
            purple = "#6A0DAD", pink = "#FF4FA3", magenta = "#E0119D", brown = "#5A3A1E",
            sand = "#D2B48C", arasaka = "#A00000", militech = "#2F4F2F", samurai = "#FF2B2B",
        },
    },

    -- /facture and the `bill` export
    bill = {
        reach = 10.0,           -- metres between mechanic and customer for a slash-command bill
        timeoutMs = 60000,      -- the customer has this long to answer
        max = 50000,            -- eddies, per invoice
        mechanicShare = 0.7,    -- 70 % to the mechanic, the rest to the society
    },

    -- /fourriere: the impound / tow yard is the Rancho Coronado junkyard (Badlands edge).
    impound = {
        zone = "junkyard",      -- rp_zones name; the owner moves the zone in rp_zones/shared/config.lua
        reach = 8.0,            -- metres to the vehicle to impound
        fee = 100,              -- eddies credited to the society per impound
        -- Used only when rp_zones is not running: the junkyard circle (AMM point, zone r 90).
        fallbackCenter = { x = 1370.0, y = -1680.0, z = 49.3 },
        fallbackRadius = 90.0,
        -- Config.impoundAnywhereForTesting: /fourriere also works within `testingReach`
        -- metres of one of these spots (the Kabuki Market spawn and the workshop).
        testingReach = 6.0,
        testingSpots = {
            { label = "Kabuki Market Centre", x = -1191.30, y = 2006.88, z = 7.82 },
            { label = "Afterlife street garage", x = -1396.0, y = 966.0, z = 23.5 },
        },
    },
    impoundAnywhereForTesting = false,

    -- /plein
    fuel = {
        reach = 4.0,
        litresPerCan = false,   -- false = fill the tank; a number = litres added per CHOOH2 can
        durationMs = 6000,      -- the "Filling the tank" bar (staged, see Stage.refuel)
    },

    -- Staging (2026-09-18 pass, owner's verdict "no anim, nothing in the hands"): every action
    -- that manipulates something plays a pose, shows a prop and takes its time behind a UI-kit
    -- bar, so the other players see the mechanic work. Pattern of rp_nomade's carry pose.
    --
    -- `pose.profiles` are open77_animations profiles tried in order through
    -- Open77.animations.get: the best FUTURE name first (a base PR is adding carry / repair /
    -- lockpick / medical profiles), then what today's 18-profile eval catalogue has (give,
    -- examine, wounded, smoke, cigar, drink, phone, dance, handsup, meditate, sit, clap, cry,
    -- think, stretch, chair, lean, lie). `clip` must belong to the profile. `loop = true` holds
    -- the pose for the whole bar and the server stops it; `loop = false` is a one-shot of
    -- `durationMs`. No upper-body mask exists and the platform cancels a workspot when the
    -- player moves > 0.5 m: stationary actions use looping poses behind a bar that disables
    -- movement (client side, never a server freeze).
    --
    -- `prop` / `place` are curated props (see `prop.catalog`; a raw .mesh renders as a white
    -- slab) created next to the player and attached (Open77.props.attach, wiki/attachments.md):
    -- `bone` is a named rig slot ("RightHand", "LeftHand", "Chest") or "" for the body root
    -- (+y facing, +x right, +z up, origin at the feet); `offset` metres in that slot's frame,
    -- `rotation` degrees (x roll, y pitch, z yaw). Hand-slot axes are not measured on 2.31:
    -- start from zero and move one axis at a time if the tool sits wrong. `models` are tried
    -- in order (future alias first). Set `enabled = false` for bars only.
    Stage = {
        enabled = true,
        color = "#F2B33D",
        -- /reparer: kneeling at the wheel, a welder in the right hand, the toolbox open at the
        -- mechanic's feet (root frame, 0.6 m to the right).
        repair = {
            durationMs = 15000,
            label = "Fixing the ride",
            pose = { profiles = { { profile = "repair" }, { profile = "mechanic" }, { profile = "examine" } }, loop = true },
            prop = { models = { "tool.welder" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
            place = { models = { "container.toolbox" }, bone = "", offset = { x = 0.6, y = 0.2, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 90.0 } },
        },
        -- /peindre: the paint goes on after the bar (or after the customer pays). The `drink`
        -- profile's own can, held without drinking (`shuffle` clip), is the spray can: no
        -- extra prop. Future name `spray`.
        paint = {
            durationMs = 8000,
            label = "Spraying the panels",
            pose = { profiles = { { profile = "drink", clip = "stand__rh_can__01__shuffle__01" } }, loop = true },
        },
        -- /plein: crouched at the tank with the CHOOH2 can in the right hand. Future name `refuel`.
        refuel = {
            durationMs = 6000,
            label = "Filling the tank",
            pose = { profiles = { { profile = "mechanic" }, { profile = "examine" } }, loop = true },
            prop = { models = { "container.gas_can" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- /facture and the ALT+click invoice: the mechanic types the bill on the holo (one-shot
        -- gesture, no bar; the customer's consent prompt is the wait).
        invoice = {
            durationMs = 3000,
            pose = { profiles = { { profile = "phone" } }, loop = false },
        },
        -- /fourriere: the mechanic calls the yard on the holo before the car goes.
        impound = {
            durationMs = 4000,
            label = "Calling the impound yard",
            pose = { profiles = { { profile = "phone" } }, loop = true },
        },
    },
}
