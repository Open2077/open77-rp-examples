-- rp_zones: shared configuration (loaded by both runtimes).
-- Every position is world space, metres. The owner moves zones by editing this file only.

Config = {}

-- Server detection tick, in milliseconds. The server is the source of truth for zoneOf.
Config.tickMs = 500

-- Metres of tolerance added to the EXIT test only (hysteresis): a player standing exactly on
-- the boundary does not flap between "entered" and "left" every tick. 0.05..10 is sensible.
Config.hysteresis = 1.0

-- Safe zones (kind "safe"): server-side damage suppression through Open77.combat.onDamage.
Config.safe = {
    blockDamage = true,          -- nobody standing in a safe zone can be damaged
    blockDamageFromInside = true -- and nobody standing in a safe zone can damage anyone outside
}

-- Notification look (open77_notifications definition fields).
Config.notify = {
    position = "top_right",
    durationMs = 5000,
    leaveDurationMs = 3500,
}

-- Client presentation.
Config.ringMaxRadius = 25.0   -- zones with a radius <= this get a ground ring (open77_worldui, no label)
Config.ringMaxDistance = 120.0
Config.blipRange = 0          -- 0 = the pin is always on the map; N = only within N metres

-- One entry per zone kind: flavour line (English, cyberpunk tone), toast type/icon,
-- vanilla blip sprite (Open77.blips sprite alias or exact variant name) and worldui ring style.
-- `chat` is an extra chat line sent on entry (only badlands uses it by contract).
Config.kinds = {
    safe = {
        title = "Safe zone",
        flavour = "No heat in here, choom. Iron stays cold and so do the grudges.",
        leave = "You're fair game again, choom. Watch your six.",
        type = "success", icon = "SAFE", sprite = "fast_travel", style = "spawn",
    },
    ncpd = {
        title = "NCPD",
        flavour = "NCPD precinct. Badges everywhere - keep your record clean and your hands visible.",
        type = "info", icon = "NCPD", sprite = "Zzz06_NCPDGigVariant", style = "objective",
    },
    hospital = {
        title = "Trauma Team",
        flavour = "Trauma Team coverage. Platinum members first, everyone else waits.",
        type = "info", icon = "TT", sprite = "meds", style = "objective",
    },
    badlands = {
        title = "Badlands",
        flavour = "You're past the city limits. Nobody's coming to save you out here.",
        chat = "Out of NCPD coverage",
        type = "warning", icon = "!", sprite = "OutpostVariant", style = "danger",
    },
    camp = {
        title = "Nomad camp",
        flavour = "Aldecaldos camp. Clan rules apply - respect the fire and the family.",
        type = "info", icon = "CAMP", sprite = "LifepathNomadVariant", style = "interaction",
    },
    industrial = {
        title = "Junkyard",
        flavour = "Junkyard. Everything here was somebody's ride once. Mind the crusher.",
        type = "info", icon = "SCRAP", sprite = "junk", style = "danger",
    },
    district = {
        title = "District",
        flavour = "Kabuki, Watson. Tyger Claws turf, noodle steam and neon. Mind your eddies.",
        type = "info", icon = "NC", sprite = "objective", style = "objective",
    },
    residential = {
        title = "Residential",
        flavour = "Megabuilding floor. Keep it down, choom - the neighbours have guns too.",
        type = "info", icon = "H10", sprite = "objective", style = "interaction",
    },
    clinic = {
        title = "Ripperdoc",
        flavour = "Vik's clinic. Chrome in, eddies out. Don't touch the chair unless you're paying.",
        type = "info", icon = "RIP", sprite = "meds", style = "objective",
    },
    bar = {
        title = "Bar",
        flavour = "The bar's open. Keep your iron holstered and your tab paid.",
        type = "info", icon = "BAR", sprite = "bar", style = "interaction",
    },
    dealership = {
        title = "Dealership",
        flavour = "Westbrook dealership. Every ride on the lot has a price and a warranty nobody honours.",
        type = "info", icon = "CAR", sprite = "tech", style = "interaction",
    },
}

-- Zones. Fields:
--   name (unique, ^[a-z0-9_]+$), label, kind (one of Config.kinds)
--   shape = "circle"  : centre { x, y, z }, radius (m), optional maxHeight (m either side of z, default 6)
--   shape = "sphere"  : centre, radius (true 3-D ball)
--   shape = "box"     : centre, size { x, y, z } (FULL extents), optional rotation (degrees)
--   shape = "polygon" : points { {x, y}, ... } (3..512, concave allowed), optional minZ / maxZ
--   optional announce : custom entry text (replaces the kind flavour line)
--   optional flags    : free table handed back by zoneOf (e.g. { noWeapons = true })
--   optional blip = false / ring = false to hide the map pin / ground ring for that zone
--
-- Layout (real Night City, measured 2026-09-18 - walked points and AMM interiors). The hub is
-- Watson: the freeroam spawn is Kabuki Market Centre (-1191.30, 2006.88, 7.82), a flat walked
-- market with The Afterlife, Lizzie's, Viktor's clinic and Megabuilding H10 a few hundred
-- metres south. The Badlands (east of the city) keep the Aldecaldos camp and the junkyard,
-- Westbrook keeps the dealership, and the NCPD sits in its city-centre building (cops drive).
-- Small zones (radius <= 25 m) draw a ground ring at `centre` (interior z + 0.1 so the ring is
-- not swallowed by the floor); the big ones are pins only.
Config.zones = {
    {
        -- The safe hub: the whole walked market (Noodle Row, The Stalls, Vendor Lane, East Row,
        -- the Lower Walkway 2 m under it and The Gallery 4 m above it - hence maxHeight 15).
        name = "kabuki_market", label = "Kabuki Market", kind = "safe",
        shape = "circle", centre = { x = -1191.30, y = 2006.88, z = 7.82 }, radius = 70.0, maxHeight = 15.0,
        flags = { noWeapons = true },
    },
    {
        -- The district around the market (Kabuki, Watson): pin only, no ring.
        name = "kabuki", label = "Kabuki", kind = "district",
        shape = "circle", centre = { x = -1200.00, y = 1900.00, z = 10.00 }, radius = 420.0, maxHeight = 200.0,
        ring = false,
    },
    {
        -- The Afterlife: bar floor 16.5, counter level 17.8, meeting room and back room inside r 25.
        name = "afterlife", label = "The Afterlife", kind = "bar",
        shape = "circle", centre = { x = -1453.00, y = 1017.00, z = 16.60 }, radius = 50.0, maxHeight = 15.0,
    },
    {
        name = "lizzies", label = "Lizzie's Bar", kind = "bar",
        shape = "circle", centre = { x = -1188.90, y = 1566.20, z = 23.00 }, radius = 18.0, maxHeight = 15.0,
    },
    {
        -- V's apartment floor of Megabuilding H10 (the gym at -1420.9, 1320.4 is inside r 45).
        name = "h10", label = "Megabuilding H10", kind = "residential",
        shape = "circle", centre = { x = -1391.90, y = 1271.70, z = 123.10 }, radius = 45.0, maxHeight = 15.0,
    },
    {
        name = "viktor_clinic", label = "Vik's Clinic", kind = "clinic",
        shape = "circle", centre = { x = -1548.00, y = 1230.00, z = 11.60 }, radius = 12.0, maxHeight = 15.0,
    },
    {
        -- The real NCPD building, city centre: conference room, cell 6 m east, desk 4 m north.
        name = "ncpd_hq", label = "NCPD Headquarters", kind = "ncpd",
        shape = "circle", centre = { x = -1761.50, y = -1010.80, z = 94.30 }, radius = 30.0, maxHeight = 15.0,
    },
    {
        name = "junkyard", label = "Rancho Coronado Junkyard", kind = "industrial",
        shape = "circle", centre = { x = 1374.90, y = -1674.90, z = 49.30 }, radius = 90.0, maxHeight = 30.0,
    },
    {
        name = "nomad_camp", label = "Aldecaldos Camp", kind = "camp",
        shape = "circle", centre = { x = 1792.90, y = 2248.90, z = 180.20 }, radius = 120.0, maxHeight = 30.0,
    },
    {
        name = "westbrook_dealer", label = "Westbrook Dealership", kind = "dealership",
        shape = "circle", centre = { x = -1442.20, y = 127.40, z = 18.00 }, radius = 40.0, maxHeight = 15.0,
    },
    {
        -- Everything east of the city: no NCPD coverage. Tall height band so the hills do not
        -- drop you out. No ring, pin only. The junkyard centre is 1 344 m from this centre;
        -- the Aldecaldos camp centre is 2 649 m from it (49 m past the edge: the camp's own
        -- 120 m ring overlaps the badlands circle, its centre point does not).
        name = "badlands", label = "Badlands", kind = "badlands",
        -- A circle cannot cover it: the platform caps a radius at 2 000 m (open77_zones.lua
        -- MAX_RADIUS, "invalid_radius" at start, measured 18 Sept). The polygon is everything
        -- east of x 900: the Aldecaldos camp (1793, 2249), the junkyard (1375, -1675), the
        -- oil fields and the road out of the city; the city itself stays out.
        shape = "polygon", minZ = -200.0, maxZ = 1200.0,
        points = { { x = 900, y = -4000 }, { x = 5000, y = -4000 }, { x = 5000, y = 4000 }, { x = 900, y = 4000 } },
        ring = false,
    },
    -- Polygon example (disabled): a concave turf with a height range, north of the market.
    -- {
    --     name = "turf_example", label = "Example Turf", kind = "camp",
    --     shape = "polygon", minZ = 0.0, maxZ = 30.0,
    --     points = { { x = -1240, y = 2090 }, { x = -1200, y = 2090 }, { x = -1200, y = 2110 }, { x = -1220, y = 2110 },
    --                { x = -1220, y = 2130 }, { x = -1240, y = 2130 } },
    -- },
}

-- Shared helpers (both runtimes).
RpZonesShared = {}

-- Translates one config entry into the definition Open77.zones.* understands.
-- Returns the definition, or nil, reason.
function RpZonesShared.definition(zone)
    if type(zone) ~= "table" then return nil, "invalid_zone" end
    local shape = zone.shape or "circle"
    if shape == "circle" then
        return { shape = "cylinder", position = zone.centre, radius = zone.radius, maxHeight = zone.maxHeight }
    elseif shape == "sphere" then
        return { shape = "sphere", position = zone.centre, radius = zone.radius }
    elseif shape == "box" then
        return { shape = "box", position = zone.centre, size = zone.size, rotation = zone.rotation or 0 }
    elseif shape == "polygon" or shape == "poly" then
        return { shape = "poly", points = zone.points, minZ = zone.minZ, maxZ = zone.maxZ }
    end
    return nil, "unknown_shape"
end

-- The kind entry of a zone, with the zone's own overrides (announce, sprite, style) applied.
function RpZonesShared.kindOf(zone)
    local kind = Config.kinds[zone.kind] or {}
    return {
        title = kind.title or zone.kind or "Zone",
        flavour = zone.announce or kind.flavour or "",
        leave = kind.leave,
        chat = kind.chat,
        type = kind.type or "info",
        icon = kind.icon,
        sprite = zone.sprite or kind.sprite or "objective",
        style = zone.style or kind.style or "objective",
    }
end
