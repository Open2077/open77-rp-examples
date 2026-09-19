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

-- Lab: `aplay <playerId> <profile> [once]` / `astop <playerId>` from the console play or stop an
-- animation profile on a player through the platform service, and every animation state change
-- is printed, so a bot session can prove a layer profile survives walking without a human.
RegisterCommand("aplay", function(source, args)
    if source ~= 0 then return end
    local playerId, profile = tonumber(args[1]), args[2]
    if not playerId or not profile then return log("usage (console): aplay <playerId> <profile> [once]") end
    local def = Open77.animations.get(profile)
    if not def then return log("aplay: profile %s unknown to this server", tostring(profile)) end
    local playback, why = Open77.animations.play(playerId, profile, { loop = args[3] ~= "once" })
    log("aplay %d %s kind=%s locomotion=%s -> %s", playerId, profile, tostring(def.kind), tostring(def.locomotion),
        playback and ("playbackId=" .. tostring(playback.playbackId)) or ("refused: " .. tostring(why)))
end)

RegisterCommand("astop", function(source, args)
    if source ~= 0 then return end
    local playerId = tonumber(args[1])
    if not playerId then return log("usage (console): astop <playerId>") end
    local ok, why = Open77.animations.stop(playerId)
    log("astop %d -> %s", playerId, ok and "ok" or ("refused: " .. tostring(why)))
end)

AddEventHandler("onPlayerAnimationChanged", function(playerId, state)
    if type(state) == "string" then
        local ok, decoded = pcall(json.decode, state)
        if ok then state = decoded end
    end
    if type(state) ~= "table" then return log("anim %s: %s", tostring(playerId), tostring(state)) end
    log("anim %s: profile=%s active=%s reason=%s playbackId=%s", tostring(playerId), tostring(state.profile),
        tostring(state.active), tostring(state.reason), tostring(state.playbackId))
end)
