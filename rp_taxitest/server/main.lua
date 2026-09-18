-- rp_taxitest: console-driven experiments on the vehicle AI.
--
--   taxitest near <playerId>        driveTo a point 120 m ahead, z from groundZ (passenger observer)
--   taxitest wrongz <playerId>      same point, z + 30 (a point above the road)
--   taxitest mapz <playerId> x y z  driveTo the given point as is (a map waypoint's own z)
--   taxitest far <playerId> x y     driveTo x,y with z resolved the way eval_taxi does it
--   taxitest traffic <playerId>     joinTraffic: does the native driver move at all here?
--   taxitest legs <playerId> x y    drive in 200 m legs, each z resolved live (observer = player)
--   taxitest stop                   remove the test car
--
-- Every second the AI state is printed: [taxitest] t=12 state=running reason= pos=x,y,z moved=34.2

local car, npc, watching = nil, nil, false

local function log(fmt, ...) print(("[taxitest] " .. fmt):format(...)) end

local function stopCar()
    watching = false
    if car then
        -- Eject first and give the client time to unmount: removing a vehicle while a
        -- player sits in it leaves the puppet stuck in the seat (measured 2026-09-18).
        local v = Open77.vehicles.get(car)
        local seated = false
        if v and v.occupants then
            for _, o in ipairs(v.occupants) do
                pcall(function() Open77.vehicles.forcePlayerOutOfVehicle(tonumber(o.playerId)) end)
                seated = true
            end
        end
        if seated then Wait(6000) end
        pcall(function() Open77.vehicles.ai.stop(car) end)
        pcall(function() Open77.vehicles.ai.removeDriver(car) end)
        if npc then Open77.npcs.remove(npc); npc = nil end
        Open77.vehicles.remove(car)
        log("car %s removed", tostring(car))
        car = nil
    end
end

local function dist2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function groundAt(playerId, x, y, fallback)
    local z, d = Open77.world.groundZ({ x = x, y = y }, { radius = 300 })
    if z then return z, "observer" end
    local r1 = tostring(d)
    z, d = Open77.world.groundZ({ x = x, y = y }, { playerId = playerId })
    if z then return z, "passenger" end
    return fallback, "fallback(" .. r1 .. "/" .. tostring(d) .. ")"
end

local function watch(seconds)
    watching = true
    CreateThread(function()
        local start = Open77.vehicles.get(car)
        local origin = start and start.position
        local last = origin
        for t = 1, seconds do
            Wait(1000)
            if not watching or not car then return end
            local v = Open77.vehicles.get(car)
            local st = Open77.vehicles.ai.state(car)
            local pos = v and v.position
            local moved = (pos and origin) and dist2(pos, origin) or -1
            local step = (pos and last) and dist2(pos, last) or -1
            if t % 5 == 0 then
                local o = Open77.vehicles.owner(car)
                if o then log("t=%d owner=%s epoch=%s steward=%s aiDriven=%s reason=%s", t, tostring(o.authorityPlayerId), tostring(o.epoch), tostring(o.steward), tostring(o.aiDriven), tostring(o.reason)) end
            end
            log("t=%d state=%s reason=%s mode=%s pos=%s moved=%.1f step=%.1f", t,
                tostring(st and st.status), tostring(st and st.reason), tostring(st and st.mode),
                pos and ("%.1f,%.1f,%.1f"):format(pos.x, pos.y, pos.z) or "?", moved, step)
            last = pos
            if st and (st.status == "arrived" or st.status == "failed") then return end
        end
    end)
end

local function spawnNear(playerId, withDriver)
    stopCar()
    local me = Open77.players.get(playerId)
    if not me or not me.position then log("player %s has no position", tostring(playerId)); return nil end
    local yaw = me.heading or 0
    local rad = math.rad(yaw)
    local fx, fy = -math.sin(rad), math.cos(rad)   -- forward if yaw 0 = +y, ccw
    local id, reason = Open77.vehicles.create({
        record = "Vehicle.v_standard2_archer_hella_player",
        position = { x = me.position.x + fx * 6, y = me.position.y + fy * 6, z = me.position.z },
        yaw = yaw, bucket = me.bucket, ttlMs = 180000,
    })
    if not id then log("create refused: %s", tostring(reason)); return nil end
    car = id
    log("car %s created at %.1f,%.1f,%.1f yaw=%.0f", tostring(id), me.position.x + fx * 6, me.position.y + fy * 6, me.position.z, yaw)
    Wait(3000)
    if withDriver then
        npc = Open77.npcs.create({ record = "Character.NightlifeMaleDriver",
            position = { x = me.position.x + fx * 6 + 2, y = me.position.y + fy * 6, z = me.position.z },
            yaw = yaw, bucket = me.bucket, behavior = { combatEnabled = false, voiceEnabled = true },
            damagePolicy = 2 })
        if npc then
            local ok = Open77.npcs.whenReady(npc, 15000):await()
            log("npc %s ready=%s", tostring(npc), tostring(ok ~= nil))
        end
    end
    local st, r = Open77.vehicles.ai.attachDriver(id, npc and { npcId = npc } or nil)
    log("attachDriver -> %s %s", tostring(st and st.status or st), tostring(r))
    Wait(3000)
    return me, fx, fy
end

local function drive(playerId, target, why)
    local task, reason = Open77.vehicles.ai.driveTo(car, {
        position = target, speed = 15, arrivalRadius = 6, timeoutMilliseconds = 120000, behavior = "normal",
    })
    log("driveTo(%s) to %.1f,%.1f,%.1f -> %s %s", why, target.x, target.y, target.z,
        tostring(task and task.status or task), tostring(reason))
    if task then watch(60) end
end

-- eval_taxi's boarding: animated entry, seat confirmed, settle, lease held.
local function boardAnimated(playerId)
    local ok, why = Open77.vehicles.taskPlayerEnter(playerId, car, "frontPassenger", { moveBucket = true, exitLocked = false })
    log("taskPlayerEnter -> %s %s", tostring(ok), tostring(why))
    for _ = 1, 32 do
        Wait(250)
        local seat = Open77.vehicles.getPlayerSeat(playerId)
        if seat and seat.vehicleId == car and not seat.entering then log("seated %s", tostring(seat.seat)); break end
    end
    Wait(3000)
    for _ = 1, 40 do
        local o = Open77.vehicles.owner(car)
        if o and o.authorityPlayerId and o.authorityPlayerId ~= 0 then
            log("owner=%s epoch=%s steward=%s aiDriven=%s reason=%s", tostring(o.authorityPlayerId), tostring(o.epoch), tostring(o.steward), tostring(o.aiDriven), tostring(o.reason))
            break
        end
        Wait(250)
    end
end

-- groundz <playerId> <x> <y> [<x> <y> ...]: ground height of one or more map points, from the
-- console, to place zones and POIs on real ground instead of a guessed z.
RegisterCommand("groundz", function(source, args)
    local playerId = tonumber(args[1])
    if not playerId then log("usage: groundz <playerId> <x> <y> [<x> <y> ...]"); return end
    CreateThread(function()
        local i = 2
        while args[i] and args[i + 1] do
            local x, y = tonumber(args[i]), tonumber(args[i + 1])
            if x and y then
                local z, how = groundAt(playerId, x, y, nil)
                log("groundz %.2f %.2f -> %s (%s)", x, y, tostring(z), how)
            end
            i = i + 2
        end
    end)
end, true)

RegisterCommand("taxitest", function(source, args)
    local mode = args[1]
    local playerId = tonumber(args[2])
    if mode == "stop" then stopCar(); return end
    if not playerId then log("usage: taxitest <near|wrongz|mapz|far|traffic|legs|stop> <playerId> [x y [z]]"); return end
    CreateThread(function()
        if mode == "near" or mode == "wrongz" or mode == "nearride" then
            local me, fx, fy = spawnNear(playerId, true)
            if not me then return end
            if mode == "nearride" then
                -- The passenger's client is the simulator that actually drives.
                local ok, why = Open77.vehicles.warpPlayerIntoVehicle(playerId, car, "frontPassenger")
                log("warp passenger -> %s %s", tostring(ok), tostring(why))
                Wait(4000)
            end
            local tx, ty = me.position.x + fx * 120, me.position.y + fy * 120
            local z, how = groundAt(playerId, tx, ty, me.position.z)
            log("target z=%.1f (%s) map_player_z=%.1f", z, how, me.position.z)
            if mode == "wrongz" then z = z + 30 end
            drive(playerId, { x = tx, y = ty, z = z }, mode)
        elseif mode == "nearenter" then
            -- eval_taxi's exact boarding sequence: animated entry, seat confirmed,
            -- settle, lease held by a client, then the order.
            local me, fx, fy = spawnNear(playerId, true)
            if not me then return end
            local ok, why = Open77.vehicles.taskPlayerEnter(playerId, car, "frontPassenger", { moveBucket = true, exitLocked = false })
            log("taskPlayerEnter -> %s %s", tostring(ok), tostring(why))
            for _ = 1, 32 do
                Wait(250)
                local seat = Open77.vehicles.getPlayerSeat(playerId)
                if seat and seat.vehicleId == car and not seat.entering then log("seated %s", tostring(seat.seat)); break end
            end
            Wait(3000)
            for _ = 1, 40 do
                local o = Open77.vehicles.owner(car)
                if o and o.authorityPlayerId and o.authorityPlayerId ~= 0 then
                    log("owner=%s epoch=%s steward=%s aiDriven=%s reason=%s", tostring(o.authorityPlayerId), tostring(o.epoch), tostring(o.steward), tostring(o.aiDriven), tostring(o.reason))
                    break
                end
                Wait(250)
            end
            local tx, ty = me.position.x + fx * 120, me.position.y + fy * 120
            local z, how = groundAt(playerId, tx, ty, me.position.z)
            log("target z=%.1f (%s)", z, how)
            local task, reason = Open77.vehicles.ai.driveTo(car, { position = { x = tx, y = ty, z = z }, speed = 25, arrivalRadius = 8, timeoutMilliseconds = 120000, behavior = "normal" })
            log("driveTo(nearenter) to %.1f,%.1f,%.1f -> %s %s", tx, ty, z, tostring(task and task.status or task), tostring(reason))
            if task then watch(60) end
        elseif mode == "voice" or mode == "voicecar" then
            -- Does Open77.npcs.speak produce audible sound on this record, standing
            -- next to the player, then seated in a car? Chat echoes every bark.
            local record = args[3] or "Character.NightlifeMaleDriver"
            local me = Open77.players.get(playerId)
            if not me or not me.position then return end
            stopCar()
            if mode == "voicecar" then
                local id = Open77.vehicles.create({ record = "Vehicle.v_standard2_archer_hella_player",
                    position = { x = me.position.x + 4, y = me.position.y, z = me.position.z }, yaw = me.heading or 0, bucket = me.bucket, ttlMs = 120000 })
                car = id; Wait(3000)
            end
            npc = Open77.npcs.create({ record = record, position = { x = me.position.x + 2, y = me.position.y + 1, z = me.position.z },
                yaw = me.heading or 0, bucket = me.bucket, behavior = { combatEnabled = false, voiceEnabled = true }, damagePolicy = 2 })
            if not npc then log("npc create refused for %s", record); return end
            local ready = Open77.npcs.whenReady(npc, 15000):await()
            log("voice test npc=%s record=%s ready=%s", tostring(npc), record, tostring(ready ~= nil))
            if mode == "voicecar" and car then
                local st, r = Open77.vehicles.ai.attachDriver(car, { npcId = npc })
                log("attachDriver -> %s %s", tostring(st and st.status or st), tostring(r)); Wait(3000)
            end
            for _, v in ipairs({ "greeting", "bump", "hurry_up", "fear_run", "vehicle_bump", "pedestrian_hit", "stlh_curious", "combat_ended", "phone_start" }) do
                local ok, reason = Open77.npcs.speak(npc, v, { ignoreDistance = true })
                log("speak %s -> %s %s", v, tostring(ok), tostring(reason))
                Open77.chat.send(playerId, { author = "TEST", text = ("bark %s -> %s %s"):format(v, tostring(ok), tostring(reason or "")), color = { 200, 200, 200 } })
                Wait(3500)
            end
            log("voice test done; npc stays 60 s")
            Wait(60000)
            stopCar(); if npc then Open77.npcs.remove(npc); npc = nil end
        elseif mode == "mapz" then
            local x, y, z = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
            if not (x and y and z) then log("usage: taxitest mapz <playerId> <x> <y> <z>"); return end
            local me = spawnNear(playerId, true)
            if not me then return end
            drive(playerId, { x = x, y = y, z = z }, "mapz")
        elseif mode == "far" then
            local tx, ty = tonumber(args[3]), tonumber(args[4])
            if not (tx and ty) then log("usage: taxitest far <playerId> <x> <y>"); return end
            local me = spawnNear(playerId, true)
            if not me then return end
            local z, how = groundAt(playerId, tx, ty, me.position.z)
            log("far target z=%.1f (%s)", z, how)
            drive(playerId, { x = tx, y = ty, z = z }, "far")
        elseif mode == "traffic" or mode == "trafficride" then
            local me = spawnNear(playerId, true)
            if not me then return end
            if mode == "trafficride" then
                local ok, why = Open77.vehicles.warpPlayerIntoVehicle(playerId, car, "frontPassenger")
                log("warp passenger -> %s %s", tostring(ok), tostring(why))
                Wait(4000)
            end
            local task, reason = Open77.vehicles.ai.joinTraffic(car, { speed = 15 })
            log("joinTraffic -> %s %s", tostring(task and task.status or task), tostring(reason))
            if task then watch(45) end
        elseif mode == "legs" or mode == "legsride" then
            local tx, ty = tonumber(args[3]), tonumber(args[4])
            if not (tx and ty) then log("usage: taxitest %s <playerId> <x> <y>", mode); return end
            local me = spawnNear(playerId, true)
            if not me then return end
            if mode == "legsride" then boardAnimated(playerId) end
            local legLen = 200
            for leg = 1, 12 do
                local v = Open77.vehicles.get(car)
                if not v then return end
                local here = v.position
                local remaining = dist2(here, { x = tx, y = ty })
                local lx, ly
                if remaining <= legLen then lx, ly = tx, ty
                else
                    local k = legLen / remaining
                    lx, ly = here.x + (tx - here.x) * k, here.y + (ty - here.y) * k
                end
                local z, how = groundAt(playerId, lx, ly, here.z)
                log("leg %d remaining=%.0f target=%.1f,%.1f,%.1f (%s)", leg, remaining, lx, ly, z, how)
                local task, reason = Open77.vehicles.ai.driveTo(car, {
                    position = { x = lx, y = ly, z = z }, speed = 20, arrivalRadius = 12, timeoutMilliseconds = 90000, behavior = "aggressive",
                })
                if not task then log("leg %d refused: %s", leg, tostring(reason)); return end
                local waited = 0
                while waited < 90 do
                    Wait(1000); waited = waited + 1
                    local st = Open77.vehicles.ai.state(car)
                    local vv = Open77.vehicles.get(car)
                    if waited % 3 == 0 and vv then
                        log("leg %d t=%d state=%s reason=%s pos=%.1f,%.1f,%.1f", leg, waited, tostring(st and st.status), tostring(st and st.reason), vv.position.x, vv.position.y, vv.position.z)
                    end
                    if st and st.status == "arrived" then break end
                    if st and st.status == "failed" then log("leg %d failed: %s", leg, tostring(st.reason)); return end
                end
                if remaining <= legLen then log("legs: destination reached"); return end
            end
        end
    end)
end, true)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then stopCar() end
end)
