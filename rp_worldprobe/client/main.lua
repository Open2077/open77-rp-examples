-- rp_worldprobe / client: answers the server's scan request with the engine's own list of
-- nearby objects, in pages of 40 rows so one net event never carries a huge table.

local PAGE = 40

RegisterNetEvent("rp_worldprobe:scan", function(radius, filter)
    radius = tonumber(radius) or 25
    local ok, hits, reason
    if filter ~= nil then ok, hits, reason = pcall(Open77.world.nearby, radius, filter)
    else ok, hits, reason = pcall(Open77.world.nearby, radius) end
    if not ok or type(hits) ~= "table" then
        print(("[worldprobe] nearby failed: ok=%s hits=%s reason=%s"):format(tostring(ok), tostring(hits), tostring(reason)))
        TriggerServerEvent("rp_worldprobe:rows", {}, 1, 1)
        return
    end
    local rows = {}
    for _, hit in ipairs(hits) do
        rows[#rows + 1] = {
            kind = hit.kind, family = hit.family, className = hit.className,
            engineEntity = tostring(hit.engineEntity),
            position = hit.position and { x = hit.position.x, y = hit.position.y, z = hit.position.z } or nil,
            distance = hit.distance,
            playerId = hit.playerId, vehicleId = hit.vehicleId, npcId = hit.npcId,
        }
    end
    local pages = math.max(1, math.ceil(#rows / PAGE))
    for page = 1, pages do
        local chunk = {}
        for i = (page - 1) * PAGE + 1, math.min(#rows, page * PAGE) do chunk[#chunk + 1] = rows[i] end
        TriggerServerEvent("rp_worldprobe:rows", chunk, page, pages)
        Wait(50)
    end
end)
