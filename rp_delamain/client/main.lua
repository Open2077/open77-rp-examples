-- rp_delamain / client
-- Presentation only. The server tells this client what to draw and asks it one question:
--   rp_delamain:blip          (rideId, position, title)  a temporary map pin on a caller (drivers)
--   rp_delamain:blipRemove    (rideId)                    that pin goes away
--   rp_delamain:setWaypoint   (position)                  the driver's GPS (vanilla route)
--   rp_delamain:clearWaypoint ()                          the driver's GPS is released
--   rp_delamain:askWaypoint   (rideId)                    "where is your map waypoint?" -> rp_delamain:waypoint
-- Nothing here decides anything: a forged answer is re-validated on the server.

local Config = RpDelamainConfig
local blips  = {}   -- rideId -> { id = blipId, expiresAt = monotonic seconds }

local function removeBlip(rideId)
    local entry = blips[rideId]
    if not entry then return end
    blips[rideId] = nil
    local ok, reason = Open77.blips.remove(entry.id)
    if not ok then print(("[rp_delamain] blip remove failed: %s"):format(tostring(reason))) end
end

RegisterNetEvent("rp_delamain:blip", function(rideId, position, title)
    if type(position) ~= "table" then return end
    removeBlip(rideId)
    local id, reason = Open77.blips.create({
        position = { x = position.x, y = position.y, z = position.z },
        sprite = Config.BlipSprite,
        title = title or "Delamain call",
        description = "A client is waiting for a Delamain cab. /accepter to take the ride.",
        active = true,
        visibleThroughWalls = false,
    })
    if not id then
        print(("[rp_delamain] blip create failed: %s"):format(tostring(reason)))
        return
    end
    blips[rideId] = { id = id, expiresAt = Open77.time.monotonic() + Config.BlipTtlSec }
end)

RegisterNetEvent("rp_delamain:blipRemove", function(rideId)
    removeBlip(rideId)
end)

RegisterNetEvent("rp_delamain:setWaypoint", function(position)
    if type(position) ~= "table" then return end
    local ok, reason = Open77.blips.setWaypoint({ x = position.x, y = position.y, z = position.z })
    if not ok then print(("[rp_delamain] setWaypoint failed: %s"):format(tostring(reason))) end
end)

RegisterNetEvent("rp_delamain:clearWaypoint", function()
    -- `true, wasSet` on success, `false, reason` on failure.
    local ok, second = Open77.blips.clearWaypoint()
    if not ok then print(("[rp_delamain] clearWaypoint failed: %s"):format(tostring(second))) end
end)

-- The server asks where the caller's map waypoint is. `nil` alone means "no waypoint";
-- `nil, reason` means the question could not be asked - both are reported as `false`.
RegisterNetEvent("rp_delamain:askWaypoint", function(rideId)
    local point, reason = Open77.blips.waypoint()
    if not point then
        if reason then print(("[rp_delamain] waypoint read failed: %s"):format(tostring(reason))) end
        TriggerServerEvent("rp_delamain:waypoint", rideId, false)
        return
    end
    TriggerServerEvent("rp_delamain:waypoint", rideId, { x = point.x, y = point.y, z = point.z })
end)

-- Stale call pins remove themselves (a driver who never answered keeps a clean map).
CreateThread(function()
    while true do
        Wait(5000)
        local now = Open77.time.monotonic()
        for rideId, entry in pairs(blips) do
            if now >= entry.expiresAt then removeBlip(rideId) end
        end
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    print("[rp_delamain] client ready")
end)
