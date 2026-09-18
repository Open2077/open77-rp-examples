-- rp_housing configuration. Shared by the client (rings, prompts, pins) and the
-- server (distances, prices, rent). Every position is world metres; the owner
-- moves them by editing this file. The five homes are real Night City flats
-- (AMM interior points, 2026-09-18): `interior` is where spawn-at-home puts
-- you and the anchor of the stash ring; the door is the flat's own front door,
-- found at runtime through open77_doors (see Config.autoDoor) and drawn as two
-- pass-through rings, one on each side, with a static fallback on the interior
-- point and 3 m from it along +x.
Config = {}

-- Money. Rent is charged from the bank account (rp_bank:charge into the
-- "housing" society, a sink nobody can withdraw from); when the account is
-- short the cash wallet (rp_economy) is tried; when both are short the rent is
-- unpaid. evictAfter consecutive unpaid rents = evicted, keys revoked.
Config.society = "housing"        -- rp_bank society that receives rents and purchases
Config.rent = 500                 -- default rent per payday, per home (a home may override it)
Config.rentIntervalSec = 600      -- one payday = 10 minutes, same rhythm as rp_economy
Config.rentTickSec = 60           -- how often the server looks for due rents
Config.evictAfter = 2             -- unpaid rents (in a row) before eviction
Config.sellBackRatio = 0.70       -- /maison vendre pays back this share of the price, in cash

-- Distances (metres). The E prompt is only pressable within promptDistance
-- while looking at the ring; the server re-checks with a little tolerance
-- because its position snapshot can lag a running player by a tick.
Config.promptDistance = 3.0       -- open77_worldui prompt range for every ring
Config.serverTolerance = 2.5      -- added to promptDistance on the server side
Config.agencyRadius = 4.0         -- /agence_immo and the agency prompt: how close to the desk
Config.keyDistance = 3.0          -- /maison cles and ALT+click "Give a key": how close to the receiver
Config.interiorRadius = 8.0       -- further than this from the interior spot = no longer "inside"

-- Screen fade around the teleport in and out (ms, 0..10000). Applied through
-- Open77.players.teleport's own fade option (fadeOutMs / fadeInMs).
Config.enterFade = 400

-- Staging (2026-09-18 pass): the stash is opened, not summoned. Same rules as rp_mecano /
-- rp_nomade: `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first, then what today's 18-profile eval catalogue
-- has); `loop = true` is held for the bar and stopped by the server. A workspot is cancelled
-- when the player moves > 0.5 m; the bar keeps them still (client side, never a server freeze).
-- The doors are teleports: no pose there (a fade already covers the move).
Config.Stage = {
    enabled = true,
    color = "#22D8E2",
    stash = {
        durationMs = 2000,
        label = "Opening the stash",
        pose = { profiles = { { profile = "carry_pickup" }, { profile = "examine" } }, loop = true },
    },
}

-- How long the server waits for a freshly connected player to be alive before
-- moving them home (/maison spawn). The freeroam gamemode spawns everybody at
-- Kabuki Market first; the host has no "spawn point" API, so the move happens
-- once the body is standing (see README, "Respawn at home").
Config.spawnWaitSec = 30

-- The flat's own front door ("auto door"). At start, and every `retrySec`
-- until it works, the server asks open77_doors for the doors discovered within
-- `radius` metres of each interior point and takes the nearest one as the
-- home's `doorId`: the door is then claimed and locked to the owner and the
-- key holders, and the rings are derived from it along the interior -> door
-- axis ("outside" = beyond the door, seen from the interior point). The door
-- is a two-sided pass-through: ring A stands `ring` metres on the interior
-- side of the door, ring B `ring` metres beyond it, both "Apartment door";
-- E on either side teleports the player to the other side, `land` metres
-- from the door (a little past the far ring so the next press goes back). The
-- stash ring stands `stashInside` metres beyond the interior point, further
-- from the door. Which side is the flat proper is not knowable from the door
-- snapshot (Northside, 2026-09-18: the AMM interior point is the corridor in
-- front of the unit door), so "inside" toggles on every pass-through. A door
-- is only discovered once a client has streamed it (walked past the flat), so
-- until then the static fallback is what the rings, the E prompts and the
-- teleports use: side A = the interior point itself, side B = interior +
-- `fallback` m along x, stash = interior + 1.5 m along x. Per home,
-- `autoDoor = false` keeps the static rings for good; a hand-set `doorId`
-- skips the search (the rings are still derived from that door).
Config.autoDoor = {
    radius = 6.0,
    ring = 2.0,
    land = 2.5,
    stashInside = 1.2,
    fallback = 3.0,
    retrySec = 60, floorTolerance = 1.5, -- metres of height a discovered door may differ from the flat floor (the unit below is 4 m down)
}

-- The real-estate agency: a ring + E prompt + map pin at Kabuki Market, The
-- Crossing (walked), 32 m west of the market centre, with a listings terminal
-- prop 1.1 m off the ring (Open77.props.create on the server, removed on stop;
-- `models` are depot meshes tried in order).
Config.agency = {
    label = "Night City Real Estate",
    description = "Buy or sell a place to crash. Kabuki Market, The Crossing.",
    position = { x = -1218.65, y = 2022.93, z = 7.82 },
    radius = 1.5,
    props = {
        { models = {
              "electronics.monitor.device",
              "electronics.monitor.device",
          },
          position = { x = -1216.05, y = 2022.93, z = 7.82 }, yaw = 90.0 },
    },
}

-- Homes. Fields:
--   id        stable identifier (letters, digits, underscore), also the map/stash key
--             and the rp_config key: kept across the move to the real map so deeds,
--             stashes and overrides survive (the label is what players read)
--   label     what players read
--   district  flavour text for the agency menu
--   zone      optional rp_zones zone name; its label replaces `district` when rp_zones runs
--   price     purchase price in eddies; sold back at Config.sellBackRatio
--   rent      optional per-home rent (defaults to Config.rent)
--   interior  where entering puts you: the flat's floor (AMM point)
--   heading   body yaw applied on arrival (degrees, AMM)
--   sideA     the "Apartment door" ring on the interior side of the door, and
--             where a pass-through from side B lands (landA). Left empty: the auto
--             door fills it (the interior point itself until the door is discovered,
--             then door - 2 m along the axis; landing door - 2.5 m)
--   sideB     the same ring beyond the door (default: interior + 3 m along x until the
--             door is discovered, then door + 2 m along the axis; landing door + 2.5 m)
--   stash     where the "Stash" ring stands (default: interior + 1.5 m along x until the
--             front door is found, then interior + 1.2 m further from the door)
--   doorId    optional open77_doors engine id ("0x..." string). Empty: found by the
--             auto door. When set, the server claims the door and locks it to the
--             owner and the key holders (defaultAccess = false).
--   autoDoor  false = never search for the front door (static rings)
Config.homes = {
    {
        -- Was the Northside Apartment (-1503.8, 2224.9, 22.2): entering that DLC flat kills the
        -- client 15 s after its lootable decor streams in (reproduced three times 18 Sept,
        -- engine pool free-list corruption, base investigation open). The No-Tell Motel room
        -- (Kabuki, AMM "No-Tell Motel - Venus") was walked 45 s without harm.
        id = "northside_container",
        label = "No-Tell Motel - room Venus",
        district = "Kabuki, Watson",
        zone = nil,
        price = 9000,
        interior = { x = -1202.2, y = 1333.2, z = 20.0 },
    },
    {
        id = "badlands_hideout",
        label = "Glen Apartment",
        district = "The Glen, Heywood",
        zone = nil,
        price = 15000,
        interior = { x = -1524.0, y = -992.6, z = 9.1 },
    },
    {
        id = "h10_studio",
        label = "Megabuilding H10 - V's Apartment",
        district = "Little China, Watson",
        zone = "h10",
        price = 25000,
        interior = { x = -1391.9, y = 1271.7, z = 123.1 },
        heading = -99.3,
    },
    {
        id = "kabuki_flat",
        label = "Judy's Apartment",
        district = "Kabuki, Watson",
        zone = nil,
        price = 30000,
        interior = { x = -906.3, y = 1868.7, z = 42.4 },
    },
    {
        id = "japantown_loft",
        label = "Japantown Apartment",
        district = "Japantown, Westbrook",
        zone = nil,
        price = 40000,
        interior = { x = -785.3, y = 992.6, z = 12.0 },
    },
}

-- Prompt copy (English, on purpose: it is what every player reads).
Config.text = {
    door = "Apartment door",
    doorDescription = "Unit door - pass through (keys required)",
    stash = "Stash",
    stashDescription = "Your private stash, 200 kg.",
}

-- Stash capacity handed to rp_inventory:openStash, in kg.
Config.stashCapacity = 200

-- Derived helpers shared by both runtimes. Fill the optional positions.
for _, home in ipairs(Config.homes) do
    home.rent = home.rent or Config.rent
    -- Static fallback (no door yet): side A on the interior point, side B 3 m
    -- along +x; a pass-through lands on the far ring itself.
    home.sideA = home.sideA or { x = home.interior.x, y = home.interior.y, z = home.interior.z }
    home.sideB = home.sideB or { x = home.interior.x + Config.autoDoor.fallback, y = home.interior.y, z = home.interior.z }
    home.landA = home.landA or { x = home.sideA.x, y = home.sideA.y, z = home.sideA.z }
    home.landB = home.landB or { x = home.sideB.x, y = home.sideB.y, z = home.sideB.z }
    home.stash = home.stash or { x = home.interior.x + 1.5, y = home.interior.y, z = home.interior.z }
    home.doorId = home.doorId or ""
    if home.autoDoor == nil then home.autoDoor = (home.doorId == "") end
end

function Config.home(id)
    for _, home in ipairs(Config.homes) do
        if home.id == id then return home end
    end
    return nil
end
