-- rp_worldprobe / server: `wprobe <playerId> [radius] [filter]` from the console asks that
-- player's client for Open77.world.nearby(radius, filter) and prints every row in the
-- server log (nearest first): family/kind, engine class, engine entity id, position.
-- Filter names: device, puppet, player, sensor, other (default: everything).

local function log(fmt, ...)
    print(("[worldprobe] " .. fmt):format(...))
end

RegisterNetEvent("rp_worldprobe:rows", function(rows, page, pages)
    local source = source
    if type(rows) ~= "table" then return end
    log("player %s page %s/%s: %d row(s)", tostring(source), tostring(page), tostring(pages), #rows)
    for _, r in ipairs(rows) do
        local p = r.position or {}
        log("  %-16s %-34s id=%-22s at %8.2f %8.2f %7.2f  %5.1f m%s",
            tostring(r.kind or r.family or "?"), tostring(r.className or "?"), tostring(r.engineEntity or "?"),
            tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0, tonumber(r.distance) or 0,
            r.playerId and (" player=" .. tostring(r.playerId)) or r.vehicleId and (" vehicle=" .. tostring(r.vehicleId))
                or r.npcId and (" npc=" .. tostring(r.npcId)) or "")
    end
end)

RegisterCommand("wprobe", function(source, args)
    local playerId = tonumber(args[1])
    if not playerId or playerId < 1 then
        log("usage: wprobe <playerId> [radius=25] [filter: device|puppet|player|sensor|other|all]")
        return
    end
    local radius = tonumber(args[2]) or 25
    local filter = args[3]
    if filter == "all" then filter = nil end
    log("asking player %d for objects within %.0f m (filter %s)", playerId, radius, tostring(filter or "all"))
    TriggerClientEvent("rp_worldprobe:scan", playerId, radius, filter)
end, true)

-- `vwarp <vehicleId> <x> <y> <z> [yaw]` from the console: moves a server vehicle (lab helper,
-- Open77.vehicles.setTransform revokes any physics lease so the driver's client re-syncs).
RegisterCommand("vwarp", function(source, args)
    local id = tonumber(args[1])
    local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if source ~= 0 or not id or not x or not y or not z then
        return log("usage (console): vwarp <vehicleId> <x> <y> <z> [yaw]")
    end
    local ok, why = Open77.vehicles.setTransform(id, { x = x, y = y, z = z, yaw = tonumber(args[5]) or 0.0 })
    log("vwarp %d -> %.1f %.1f %.1f: %s", id, x, y, z, ok and "ok" or ("refused: " .. tostring(why)))
end)
