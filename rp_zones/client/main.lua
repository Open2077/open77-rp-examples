-- rp_zones client: presentation only. One vanilla map pin per zone (Open77.blips) and, for
-- zones whose radius is <= Config.ringMaxRadius, a native ground ring through open77_worldui
-- (a marker with no label = no prompt). Membership, announcements and damage rules live on
-- the server; this file never decides anything.

local RESOURCE = GetCurrentResourceName()

local blips = {}   -- zone name -> blip id (decimal string)
local rings = {}   -- zone name -> worldui handle

local function anchorOf(zone, def)
    -- Circle/sphere/box carry their centre; a polygon takes its bounds centre and its height band.
    if zone.centre then return zone.centre end
    local bounds = Open77.zones.bounds(def)
    if not bounds then return nil end
    local z = bounds.z
    if not z then
        if zone.minZ and zone.maxZ then z = (zone.minZ + zone.maxZ) / 2
        else z = zone.minZ or zone.maxZ or 0 end
    end
    return { x = bounds.x, y = bounds.y, z = z }
end

local function createBlip(zone, kind, anchor)
    if zone.blip == false then return end
    local options = {
        position = { x = anchor.x, y = anchor.y, z = anchor.z },
        sprite = kind.sprite,
        title = zone.label or zone.name,
        description = kind.flavour ~= "" and kind.flavour or kind.title,
        active = true,
        visibleThroughWalls = false,
    }
    if (Config.blipRange or 0) > 0 then options.range = Config.blipRange end
    local id, reason = Open77.blips.create(options)
    if not id then
        print(("rp_zones: blip for %s refused: %s"):format(zone.name, tostring(reason)))
        return
    end
    blips[zone.name] = id
end

local function createRing(zone, kind, anchor, def)
    if zone.ring == false then return end
    local bounds = Open77.zones.bounds(def)
    local radius = zone.radius or (bounds and bounds.radius) or nil
    if not radius or radius > (Config.ringMaxRadius or 25.0) then return end
    -- No `label`: open77_worldui then creates the marker half only, no E prompt.
    local pending, callError = Open77.exports.call("open77_worldui", "create", {
        id = "rp_zones:" .. zone.name,
        position = { x = anchor.x, y = anchor.y, z = anchor.z },
        radius = radius,
        shape = "ring",
        style = kind.style,
        maxDistance = Config.ringMaxDistance or 120.0,
        groundOffset = 0.06,
    })
    if not pending then
        print(("rp_zones: ring for %s not dispatched: %s"):format(zone.name, tostring(callError)))
        return
    end
    local result, awaitError = pending:await()
    if not result or not result.ok then
        print(("rp_zones: ring for %s refused: %s"):format(zone.name,
            tostring(awaitError or (result and result.error) or "unknown")))
        return
    end
    rings[zone.name] = result.handle
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    CreateThread(function()
        local pins, loops = 0, 0
        for _, zone in ipairs(Config.zones or {}) do
            local def, adaptError = RpZonesShared.definition(zone)
            if not def then
                print(("rp_zones: zone %s skipped on the client: %s"):format(tostring(zone.name), tostring(adaptError)))
            else
                local kind = RpZonesShared.kindOf(zone)
                local anchor = anchorOf(zone, def)
                if anchor then
                    createBlip(zone, kind, anchor)
                    if blips[zone.name] then pins = pins + 1 end
                    createRing(zone, kind, anchor, def)
                    if rings[zone.name] then loops = loops + 1 end
                end
            end
        end
        print(("rp_zones: %d map pin(s), %d ground ring(s)"):format(pins, loops))
    end)
end)

-- Blips and worldui POIs are released by the platform when this resource stops or reloads;
-- the tables above only exist so a future `/zones` client view can read them.
