-- eval_taxi / server
-- Spawns a server-owned taxi next to the requesting player, puts a VISIBLE NPC driver at the
-- wheel, seats the player as front passenger and lets the networked vehicle AI drive to the
-- waypoint the client reported -- once the platform reports the driver body and a vehicle
-- simulator ready.
--
-- Why this shape (vehicle-ai guide, build 2.31.13+op77.76):
--  * "Local validation covers a Hella with a seated NPC and player passenger": the visible
--    driver form is the validated one, so the driver is a real NPC owned by this resource
--    ("Create an NPC using Open77.npcs.create, then call attachDriver(vehicleId, {npcId=npcId}).
--    This also requires world.npcs. The NPC must belong to this resource, be alive, in the
--    vehicle's bucket and have no active tasks.").
--  * "Choose drivable coordinates including the correct road elevation ... A point above a
--    road can fail native routing": the map waypoint's z is the map's, so the destination is
--    put on the road with Open77.world.groundZ before driveTo, and refined again once the cab
--    is close enough for the passenger's client to see the ground there.
--  * "Tasks wait for a streamed, compatible client to acknowledge native readiness" and
--    "Query state initially; events are not replayed": every state change is polled and
--    logged as `[eval_taxi] ai vehicle=... state=... reason=...`.

local TAXI_RECORD        = "Vehicle.v_standard2_archer_hella_player"  -- the validated record
-- The driver: a vanilla crowd "Driver" record (the body the game itself seats in
-- traffic), risk flags `candidate` only in the NPC catalogue -- no quest/scene
-- flag -- so it spawns as a plain civilian with a voiceset. Character.Delamain is a
-- quest entity (delamain.ent) and the Delamain cabs (Vehicle.q101_delamain_cab...)
-- are `class: other` quest vehicles, which the data-reference guide says not to
-- prefer over *_player records; swap DRIVER_RECORD / TAXI_RECORD to try them.
local DRIVER_RECORD      = "Character.NightlifeMaleDriver"
-- What the driver says, as the game's own voice-over barks (Open77.npcs.speak: a name
-- the record's voiceset lacks is silent, so each bark is doubled by a chat line).
local DRIVER_LINES       = {
    boarded = { voice = "greeting", text = "Evening, choom. Buckle up, we're rolling." },
    blocked = { voice = "vehicle_bump", text = "Tss... traffic. Gimme two seconds." },
    resumed = { voice = "hurry_up", text = "Alright, we're moving again." },
    arrived = { voice = "greeting", text = "End of the line. Have a good night, and thanks for riding Delamain." },
}
local TAXI_SEAT          = "frontPassenger"   -- driver seat is reserved by the AI controller
local SPAWN_OFFSET_M     = 6.0                -- metres from the player, as in the create() card
local DRIVER_OFFSET_M    = 9.5                -- the NPC body spawns beyond the car, then is mounted
local NPC_READY_MS       = 15000              -- whenReady timeout for the driver body
local SEAT_WAIT_MS       = 8000               -- how long we wait for the passenger mount
local SETTLE_MS          = 3000               -- spawn/mount settling before driveTo (guide)
local SIMULATOR_WAIT_MS  = 10000              -- wait for a physics owner before driveTo
local RIDE_SPEED_MPS     = 25                 -- 0.5..55 m/s; 25 = 90 km/h (12 = 43 km/h felt slow, 2026-09-18)
local ARRIVAL_RADIUS_M   = 5                  -- 1..20
local RIDE_TIMEOUT_MS    = 10 * 60 * 1000     -- 1000..3600000
local TAXI_TTL_MS        = 20 * 60 * 1000     -- safety net: the car goes away on its own
local LINGER_MS          = 10000              -- how long the cab stays after the ride ends
local COORD_LIMIT        = 16000              -- driveTo: coordinates must be finite, within +-16000
local GROUND_RADIUS_M    = 300                -- groundZ: widest observer radius the native allows
local REFINE_RADIUS_M    = 140                -- re-resolve a non-observed z once the cab is this close
local REFINE_MIN_DELTA_M = 1.5                -- re-issue driveTo only when z moved by more than this
local MAX_RETRIES        = 1                  -- driveTo re-issues after a failed task
local STALL_RETRY_MS     = 12000              -- blocked with no "resumed" for this long -> re-issue
local MAX_STALL_RETRIES  = 1                  -- then give up with a clear message
local NO_ROUTE_MS        = 12000              -- running but not a metre moved -> the native has no route
local POLL_MS            = 1000               -- ai.state polling period
local RESOURCE_NAME      = "eval_taxi"

-- ride = { vehicleId (integer), npcId (integer|nil), destination = {x,y,z}, zSource,
--          taskId (string|nil), retries, refined, replacing, blockedTold, phase, ending }
local rides          = {}   -- playerId -> ride
local ridesByVehicle = {}   -- tostring(vehicleId) -> playerId  (AI states carry string ids)

local function say(playerId, text)
    Open77.chat.send(playerId, {
        author = "Delamain",
        text   = text,
        color  = { 255, 200, 0 },   -- positional: a keyed {r,g,b} table is ignored by the chat UI
    })
end

-- The driver talks: one voice-over bark on the NPC (heard by every client that has
-- the body streamed) plus the same sentence in chat, so a silent voiceset still reads.
local function driverSays(ride, playerId, key)
    local line = DRIVER_LINES[key]
    if not line then return end
    if ride and ride.npcId then
        local ok, reason = Open77.npcs.speak(ride.npcId, line.voice)
        if not ok then
            print(("[eval_taxi] driver npc=%s bark %s not played: %s"):format(
                tostring(ride.npcId), line.voice, tostring(reason)))
        end
    end
    Open77.chat.send(playerId, {
        author = "Driver",
        text   = line.text,
        color  = { 200, 200, 200 },
    })
end

local function isBoundedNumber(v)
    return type(v) == "number" and v == v and v > -COORD_LIMIT and v < COORD_LIMIT
end

-- One grep-able line per AI state change: [eval_taxi] ai vehicle=... state=... reason=...
local function logAi(vehicleId, state, event)
    print(("[eval_taxi] ai vehicle=%s state=%s reason=%s mode=%s task=%s owner=%s epoch=%s npc=%s event=%s"):format(
        tostring(vehicleId),
        tostring(state and state.status),
        tostring(state and state.reason),
        tostring(state and state.mode),
        tostring(state and state.taskId),
        tostring(state and state.owner),
        tostring(state and state.epoch),
        tostring(state and state.npcId),
        tostring(event)))
end

local function rideOf(vehicleId)
    local playerId = ridesByVehicle[tostring(vehicleId)]
    if not playerId then return nil end
    return rides[playerId], playerId
end

-- groundZ, npcs.whenReady and vehicles.owner arrived with op77.73: on an older server they
-- are absent, and the ride must degrade (documented fallbacks) rather than crash the handler.
local function native(namespace, name)
    local ns = Open77[namespace]
    if type(ns) ~= "table" or type(ns[name]) ~= "function" then return nil end
    return ns[name]
end

-- Puts a map point on the road. groundZ is an observation by a client: first anybody within
-- 300 m of the point, then the passenger from wherever they stand (their ray only sees the
-- sectors streamed around their body, so a far destination often answers no_ground).
-- Never a default height from the platform; the fallback is ours and is logged as such.
local MAP_Z = nil
local function resolveRoadZ(playerId, x, y, fallbackZ)
    if not native("world", "groundZ") then
        return fallbackZ, "fallback", "groundZ_unavailable_on_this_build"
    end
    local z, detail = Open77.world.groundZ({ x = x, y = y }, { radius = GROUND_RADIUS_M })
    if z then
        return z, "observer", ("player=%s distance=%.0f"):format(tostring(detail and detail.playerId), (detail and detail.distance) or 0)
    end
    local firstReason = tostring(detail)
    z, detail = Open77.world.groundZ({ x = x, y = y }, { playerId = playerId })
    if z then
        return z, "passenger", ("player=%s distance=%.0f"):format(tostring(detail and detail.playerId), (detail and detail.distance) or 0)
    end
    -- Nobody can see the ground there. The map waypoint carries its own z, which
    -- is the terrain under the cursor when the player placed it on the map
    -- (measured: 41.2 for a road whose real z was ~41; 0.6 / 5.9 appear when the
    -- map had no terrain sample). The departure z can be 140 m off; prefer the
    -- map's when it looks like a real height.
    if MAP_Z and MAP_Z > 8.0 then
        return MAP_Z, "map", firstReason .. "/" .. tostring(detail)
    end
    return fallbackZ, "fallback", firstReason .. "/" .. tostring(detail)
end

-- Orders (or re-orders) the trip. A replacement driveTo may emit `cancelled` for the previous
-- task: `replacing` and the stored taskId keep that from ending the ride.
local function issueDrive(playerId, ride, why)
    local dest = ride.destination
    ride.replacing = true
    local task, reason = Open77.vehicles.ai.driveTo(ride.vehicleId, {
        position            = { x = dest.x, y = dest.y, z = dest.z },
        speed               = RIDE_SPEED_MPS,
        arrivalRadius       = ARRIVAL_RADIUS_M,
        timeoutMilliseconds = RIDE_TIMEOUT_MS,
        -- A stalled ride is re-issued with native clearTrafficOnPath (vehicle-ai:
        -- "aggressive enables native clearTrafficOnPath").
        behavior            = ride.aggressive and "aggressive" or "normal",
    })
    ride.replacing = false
    if not task then
        print(("[eval_taxi] ride vehicle=%s player=%d driveTo(%s) refused: %s"):format(
            tostring(ride.vehicleId), playerId, why, tostring(reason)))
        return nil, reason
    end
    ride.taskId = tostring(task.taskId)
    ride.blockedTold = false
    print(("[eval_taxi] ride vehicle=%s player=%d driveTo(%s) accepted: to %.1f,%.1f,%.1f z_source=%s task=%s"):format(
        tostring(ride.vehicleId), playerId, why, dest.x, dest.y, dest.z, tostring(ride.zSource), ride.taskId))
    logAi(ride.vehicleId, task, "driveTo:" .. why)
    return task
end

-- Ends a ride and disposes of driver and taxi. `ejectPlayer` is false when the player is gone.
local function finishRide(playerId, ejectPlayer, why)
    local ride = rides[playerId]
    if not ride then return end
    ride.ending = true
    rides[playerId] = nil
    ridesByVehicle[tostring(ride.vehicleId)] = nil
    print(("[eval_taxi] ride vehicle=%s player=%d ended reason=%s npc=%s"):format(
        tostring(ride.vehicleId), playerId, tostring(why), tostring(ride.npcId)))

    local vehicleId, npcId = ride.vehicleId, ride.npcId
    local function dispose()
        -- removeDriver releases the seat and unmounts the NPC but does not delete it (card).
        Open77.vehicles.ai.removeDriver(vehicleId)
        if npcId then Open77.npcs.remove(npcId) end
        Open77.vehicles.remove(vehicleId)
    end

    if ejectPlayer then
        Open77.vehicles.ai.stop(vehicleId)   -- idempotent; the driver stays seated while the cab lingers
        local seat = Open77.vehicles.getPlayerSeat(playerId)
        if seat and seat.vehicleId == vehicleId then
            local ok, reason = Open77.vehicles.forcePlayerOutOfVehicle(playerId, vehicleId)
            if not ok then
                print(("[eval_taxi] could not eject player %d: %s"):format(playerId, tostring(reason)))
            end
        end
        SetTimeout(LINGER_MS, dispose)
    else
        dispose()
    end
end

-- Polls the authoritative AI state ("Query state initially; events are not replayed"), logs
-- every change, and refines a guessed destination z once the passenger is close enough to see
-- the ground there.
local function pollRide(playerId, vehicleId)
    CreateThread(function()
        local last = ""
        while true do
            local ride = rides[playerId]
            if not ride or ride.vehicleId ~= vehicleId or ride.ending then return end

            local state = Open77.vehicles.ai.state(vehicleId)
            if state then
                local key = table.concat({
                    tostring(state.status), tostring(state.reason), tostring(state.mode),
                    tostring(state.taskId), tostring(state.owner), tostring(state.epoch),
                }, "|")
                if key ~= last then
                    last = key
                    logAi(vehicleId, state, "poll")
                end
            end

            if ride.phase == "riding" and ride.zSource ~= "observer" and not ride.refined
                and native("world", "groundZ") then
                local car = Open77.vehicles.get(vehicleId)
                local dest = ride.destination
                -- vehicles.get answers { position = { x, y, z } }, not top-level x/y.
                if car and car.position and car.position.x and car.position.y then
                    local dx, dy = car.position.x - dest.x, car.position.y - dest.y
                    if dx * dx + dy * dy <= REFINE_RADIUS_M * REFINE_RADIUS_M then
                        ride.refined = true
                        local z, detail = Open77.world.groundZ({ x = dest.x, y = dest.y }, { playerId = playerId })
                        if rides[playerId] ~= ride or ride.ending then return end
                        if z and math.abs(z - dest.z) > REFINE_MIN_DELTA_M then
                            print(("[eval_taxi] ride vehicle=%s player=%d destination z refined %.1f -> %.1f"):format(
                                tostring(vehicleId), playerId, dest.z, z))
                            dest.z = z
                            ride.zSource = "refined"
                            issueDrive(playerId, ride, "refine")
                        else
                            print(("[eval_taxi] ride vehicle=%s player=%d destination z kept (%s)"):format(
                                tostring(vehicleId), playerId, z and ("delta<=%.1f"):format(REFINE_MIN_DELTA_M) or tostring(detail)))
                        end
                    end
                end
            end

            Wait(POLL_MS)
        end
    end)
end

RegisterNetEvent("eval_taxi:request", function(request)
    local playerId = source   -- authenticated by Open77, never taken from the payload

    if type(request) ~= "table" then return end

    if request.reason == "no_waypoint" then
        return say(playerId, "Place a waypoint on your map first, then type /taxi.")
    elseif request.reason then
        return say(playerId, "Your map is not ready (" .. tostring(request.reason) .. "). Try again.")
    end

    local destination = request.position
    if type(destination) ~= "table"
        or not isBoundedNumber(destination.x)
        or not isBoundedNumber(destination.y)
        or not isBoundedNumber(destination.z) then
        return say(playerId, "That destination is not valid.")
    end

    if rides[playerId] then
        return say(playerId, "You already have a taxi. Finish that ride first (/taxi cancel).")
    end

    -- Never seat a player who is not alive.
    if Open77.players.isDead(playerId) then
        return say(playerId, "Delamain does not carry corpses.")
    end

    if Open77.vehicles.getPlayerSeat(playerId) then
        return say(playerId, "Get out of your current vehicle first.")
    end

    local me, readReason = Open77.players.get(playerId)
    if not me or not me.position then
        return say(playerId, "Can't locate you (" .. tostring(readReason or "no_position") .. ").")
    end

    local vehicleId, createReason = Open77.vehicles.create({
        record   = TAXI_RECORD,
        position = { x = me.position.x + SPAWN_OFFSET_M, y = me.position.y, z = me.position.z },
        yaw      = me.heading,
        bucket   = me.bucket,
        ttlMs    = TAXI_TTL_MS,
    })
    if not vehicleId then
        return say(playerId, "No taxi available: " .. tostring(createReason))
    end

    -- Register the ride now so a disconnect during the waits below still cleans up.
    local ride = {
        vehicleId   = vehicleId,
        destination = { x = destination.x, y = destination.y, z = destination.z },
        zSource     = "map",
        retries     = 0,
        refined     = false,
        replacing   = false,
        blockedTold = false,
        phase       = "boarding",
        ending      = false,
    }
    rides[playerId] = ride
    ridesByVehicle[tostring(vehicleId)] = playerId
    print(("[eval_taxi] ride vehicle=%s player=%d created bucket=%s at %.1f,%.1f,%.1f"):format(
        tostring(vehicleId), playerId, tostring(me.bucket), me.position.x + SPAWN_OFFSET_M, me.position.y, me.position.z))
    say(playerId, "Your Delamain is on its way, the driver is getting in...")

    -- Visible driver: an NPC of this resource, in the vehicle's bucket, no tasks.
    local npcId, npcReason = Open77.npcs.create({
        record                = DRIVER_RECORD,
        position              = { x = me.position.x + DRIVER_OFFSET_M, y = me.position.y, z = me.position.z },
        yaw                   = me.heading,
        bucket                = me.bucket,
        behavior              = { combatEnabled = false, voiceEnabled = true },
        -- CreateNpc wants the numeric policy (invulnerable = 2); the create card shows the
        -- string form, which the runtime refuses (measured 2026-09-18), and the enum table
        -- Open77.npcs.damage is not in the op77.76 catalogue (validator error), so the literal.
        damagePolicy          = 2,
        despawnWhenUnobserved = false,
        persistent            = false,
    })
    if npcId then
        ride.npcId = npcId
        print(("[eval_taxi] ride vehicle=%s player=%d driver npc=%s created, waiting for a body"):format(
            tostring(vehicleId), playerId, tostring(npcId)))
        -- "a freshly created NPC is not yet a body in the world": wait for a ready projection.
        local owner, readyReason
        if native("npcs", "whenReady") then
            local pending, waitReason = Open77.npcs.whenReady(npcId, NPC_READY_MS)
            if pending then
                owner, readyReason = pending:await()
            else
                readyReason = waitReason
            end
        else
            -- Older build: no readiness signal on the server, give the body the settle interval.
            Wait(SETTLE_MS)
            owner, readyReason = { readyClients = "unknown", authorityPlayerId = "unknown" }, nil
        end
        if rides[playerId] ~= ride or ride.ending then return end   -- gone meanwhile
        if owner then
            print(("[eval_taxi] ride vehicle=%s player=%d driver npc=%s ready readyClients=%s owner=%s"):format(
                tostring(vehicleId), playerId, tostring(npcId), tostring(owner.readyClients), tostring(owner.authorityPlayerId)))
        else
            print(("[eval_taxi] ride vehicle=%s player=%d driver npc=%s never got a body: %s"):format(
                tostring(vehicleId), playerId, tostring(npcId), tostring(readyReason)))
            Open77.npcs.remove(npcId)
            ride.npcId = nil
        end
    else
        print(("[eval_taxi] ride vehicle=%s player=%d driver npc create refused: %s"):format(
            tostring(vehicleId), playerId, tostring(npcReason)))
    end

    -- Attach the controller: visible driver first, driverless as the documented fallback.
    local aiState, aiReason
    if ride.npcId then
        aiState, aiReason = Open77.vehicles.ai.attachDriver(vehicleId, { npcId = ride.npcId })
        if not aiState then
            print(("[eval_taxi] ride vehicle=%s player=%d attachDriver(npc=%s) refused: %s"):format(
                tostring(vehicleId), playerId, tostring(ride.npcId), tostring(aiReason)))
            Open77.npcs.remove(ride.npcId)
            ride.npcId = nil
        end
    end
    if not aiState then
        aiState, aiReason = Open77.vehicles.ai.attachDriver(vehicleId)
        if aiState then
            say(playerId, "No driver available: this cab will run in autonomous mode.")
        end
    end
    if not aiState then
        say(playerId, "The taxi has no driver: " .. tostring(aiReason))
        return finishRide(playerId, false, "attach_refused:" .. tostring(aiReason))
    end
    logAi(vehicleId, aiState, "attachDriver")

    -- Animated entry with a guaranteed warp fallback; same refusals as warpPlayerIntoVehicle.
    local seated, seatReason = Open77.vehicles.taskPlayerEnter(playerId, vehicleId, TAXI_SEAT, {
        moveBucket = true,
        exitLocked = false,
    })
    if not seated then
        say(playerId, "Can't get into the taxi: " .. tostring(seatReason))
        return finishRide(playerId, false, "seat_refused:" .. tostring(seatReason))
    end
    say(playerId, "Hop in...")

    -- Wait for the passenger mount to be confirmed by the client (bounded).
    local seatConfirmed = false
    for _ = 1, SEAT_WAIT_MS // 250 do
        Wait(250)
        if rides[playerId] ~= ride or ride.ending then return end
        local seat = Open77.vehicles.getPlayerSeat(playerId)
        if seat and seat.vehicleId == vehicleId and not seat.entering then
            seatConfirmed = true
            print(("[eval_taxi] ride vehicle=%s player=%d seated seat=%s"):format(
                tostring(vehicleId), playerId, tostring(seat.seat)))
            break
        end
    end
    if not seatConfirmed then
        print(("[eval_taxi] ride vehicle=%s player=%d seat not confirmed after %d ms, continuing"):format(
            tostring(vehicleId), playerId, SEAT_WAIT_MS))
    end

    -- "Allow the spawn/mount to settle before issuing the destination."
    Wait(SETTLE_MS)
    if rides[playerId] ~= ride or ride.ending then return end

    -- "There is no headless server physics: without a nearby ready player, no AI moves."
    -- Wait (bounded) for some client to hold the vehicle lease before ordering the trip.
    local simulator = 0
    local ownerRead = native("vehicles", "owner")
    for _ = 1, SIMULATOR_WAIT_MS // 250 do
        if not ownerRead then break end
        local owner = ownerRead(vehicleId)
        if owner and owner.authorityPlayerId and owner.authorityPlayerId ~= 0 then
            simulator = owner.authorityPlayerId
            print(("[eval_taxi] ride vehicle=%s player=%d simulator owner=%s epoch=%s steward=%s aiDriven=%s reason=%s"):format(
                tostring(vehicleId), playerId, tostring(owner.authorityPlayerId), tostring(owner.epoch),
                tostring(owner.steward), tostring(owner.aiDriven), tostring(owner.reason)))
            break
        end
        Wait(250)
        if rides[playerId] ~= ride or ride.ending then return end
    end
    if simulator == 0 then
        print(("[eval_taxi] ride vehicle=%s player=%d no vehicle owner after %d ms, the task will wait for a simulator"):format(
            tostring(vehicleId), playerId, SIMULATOR_WAIT_MS))
    end

    -- Put the destination on the road (the map's z is not the road's).
    MAP_Z = destination.z
    ride.mapZ = destination.z
    local z, zSource, zDetail = resolveRoadZ(playerId, destination.x, destination.y, me.position.z)
    if rides[playerId] ~= ride or ride.ending then return end
    ride.destination.z = z
    ride.zSource = zSource
    print(("[eval_taxi] ride vehicle=%s player=%d destination map_z=%.1f road_z=%.1f z_source=%s (%s)"):format(
        tostring(vehicleId), playerId, destination.z, z, zSource, tostring(zDetail)))

    -- Measured 2026-09-18 (rp_taxitest, 9 runs): the native driver only moves toward a
    -- destination it can route to inside the streamed world; a far or off-road point
    -- leaves the task "running" with the car parked, and no event says so. Watch the
    -- odometer ourselves and tell the passenger instead of waiting for the timeout.
    ride.departure = { x = me.position.x, y = me.position.y }
    CreateThread(function()
        Wait(NO_ROUTE_MS)
        if rides[playerId] ~= ride or ride.ending then return end
        local v = Open77.vehicles.get(vehicleId)
        local st = Open77.vehicles.ai.state(vehicleId)
        if not v or not st or st.status ~= "running" then return end
        local dx, dy = v.position.x - ride.departure.x, v.position.y - ride.departure.y
        local moved = math.sqrt(dx * dx + dy * dy)
        print(("[eval_taxi] ride vehicle=%s player=%d odometer after %d ms: %.1f m"):format(
            tostring(vehicleId), playerId, NO_ROUTE_MS, moved))
        if moved < 3.0 then
            say(playerId, "The driver can't find a route to that point: put the waypoint on a nearby street (under 300 m) and run /taxi again.")
            finishRide(playerId, true, "no_route")
        end
    end)

    local task, driveReason = issueDrive(playerId, ride, "initial")
    if not task then
        say(playerId, "The taxi can't reach that destination: " .. tostring(driveReason))
        return finishRide(playerId, true, "drive_refused:" .. tostring(driveReason))
    end
    ride.phase = "riding"
    say(playerId, "Sit back, heading to your waypoint.")
    driverSays(ride, playerId, "boarded")
    pollRide(playerId, vehicleId)
end)

RegisterNetEvent("eval_taxi:cancel", function()
    local playerId = source
    if not rides[playerId] then
        return say(playerId, "You have no taxi ride in progress.")
    end
    say(playerId, "Ride cancelled.")
    finishRide(playerId, true, "cancel")
end)

-- Acceptance is not arrival: the trip ends on one of these events.
Open77.vehicles.ai.on("arrived", function(state)
    local ride, playerId = rideOf(state.vehicleId)
    if not ride then return end
    logAi(state.vehicleId, state, "arrived")
    driverSays(ride, playerId, "arrived")
    say(playerId, "You have arrived. Thank you for choosing Delamain.")
    finishRide(playerId, true, "arrived")
end)

Open77.vehicles.ai.on("failed", function(state)
    local ride, playerId = rideOf(state.vehicleId)
    if not ride then return end
    logAi(state.vehicleId, state, "failed")
    local reason = tostring(state.reason)
    local terminal = reason:find("timeout", 1, true) or reason:find("destroy", 1, true)
        or reason:find("driver", 1, true) or reason:find("bucket", 1, true)
    if ride.retries < MAX_RETRIES and not terminal then
        ride.retries = ride.retries + 1
        say(playerId, "Route lost (" .. reason .. "), the driver is trying again.")
        CreateThread(function()
            local dest = ride.destination
            MAP_Z = ride.mapZ
            local z, zSource, zDetail = resolveRoadZ(playerId, dest.x, dest.y, dest.z)
            if rides[playerId] ~= ride or ride.ending then return end
            dest.z = z
            ride.zSource = zSource
            print(("[eval_taxi] ride vehicle=%s player=%d retry %d/%d road_z=%.1f z_source=%s (%s)"):format(
                tostring(ride.vehicleId), playerId, ride.retries, MAX_RETRIES, z, zSource, tostring(zDetail)))
            local task, why = issueDrive(playerId, ride, "retry")
            if not task then
                say(playerId, "The taxi can't resume the ride: " .. tostring(why))
                finishRide(playerId, true, "retry_refused:" .. tostring(why))
            end
        end)
        return
    end
    say(playerId, "Ride interrupted (" .. reason .. ").")
    finishRide(playerId, true, "failed:" .. reason)
end)

Open77.vehicles.ai.on("cancelled", function(state)
    local ride, playerId = rideOf(state.vehicleId)
    if not ride then return end
    logAi(state.vehicleId, state, "cancelled")
    -- A replacement driveTo cancels the previous task: not the end of the ride.
    if ride.replacing or (ride.taskId and state.taskId and tostring(state.taskId) ~= ride.taskId) then
        print(("[eval_taxi] ride vehicle=%s player=%d previous task %s replaced, ride continues"):format(
            tostring(ride.vehicleId), playerId, tostring(state.taskId)))
        return
    end
    say(playerId, "The ride has been cancelled.")
    finishRide(playerId, true, "cancelled")
end)

Open77.vehicles.ai.on("blocked", function(state)
    local ride, playerId = rideOf(state.vehicleId)
    if not ride then return end
    logAi(state.vehicleId, state, "blocked")
    if not ride.blockedTold then
        ride.blockedTold = true
        driverSays(ride, playerId, "blocked")
    end
    -- "Blocked/no_progress means less than 2 m movement over 8 seconds ... It may
    -- be a traffic wait or invalid path": give traffic its chance, then treat it as
    -- an invalid path -- a fresh road z (the passenger is now a much closer
    -- observer than at departure) and a new task that clears the traffic ahead.
    local taskAtBlock = ride.taskId
    ride.stallSince = Open77.time.monotonic()
    CreateThread(function()
        Wait(STALL_RETRY_MS)
        if rides[playerId] ~= ride or ride.ending or ride.taskId ~= taskAtBlock then return end
        if ride.stallSince == nil then return end   -- resumed meanwhile
        ride.stallRetries = (ride.stallRetries or 0) + 1
        if ride.stallRetries > MAX_STALL_RETRIES then
            say(playerId, "The driver can't find a route to that point. Put a waypoint on a street and run /taxi again.")
            finishRide(playerId, true, "stalled")
            return
        end
        local dest = ride.destination
        MAP_Z = ride.mapZ
            local z, zSource, zDetail = resolveRoadZ(playerId, dest.x, dest.y, dest.z)
        if rides[playerId] ~= ride or ride.ending then return end
        dest.z = z
        ride.zSource = zSource
        ride.aggressive = true
        print(("[eval_taxi] ride vehicle=%s player=%d stall retry %d/%d road_z=%.1f z_source=%s (%s)"):format(
            tostring(ride.vehicleId), playerId, ride.stallRetries, MAX_STALL_RETRIES, z, zSource, tostring(zDetail)))
        say(playerId, "The driver is looking for another way through...")
        local task, why = issueDrive(playerId, ride, "stall")
        if not task then
            say(playerId, "The taxi can't resume the ride: " .. tostring(why))
            finishRide(playerId, true, "stall_refused:" .. tostring(why))
        end
    end)
end)

Open77.vehicles.ai.on("resumed", function(state)
    local ride, playerId = rideOf(state.vehicleId)
    if not ride then return end
    logAi(state.vehicleId, state, "resumed")
    ride.stallSince = nil
    driverSays(ride, playerId, "resumed")
end)

Open77.vehicles.ai.on("waypointReached", function(state)
    local ride = rideOf(state.vehicleId)
    if not ride then return end
    logAi(state.vehicleId, state, "waypointReached")
end)

-- Host events (every argument is a string).
AddEventHandler("onVehicleAuthorityChanged", function(id, owner, epoch, reason)
    if not ridesByVehicle[tostring(id)] then return end
    print(("[eval_taxi] authority vehicle=%s owner=%s epoch=%s reason=%s"):format(
        tostring(id), tostring(owner), tostring(epoch), tostring(reason)))
end)

AddEventHandler("onNpcAuthorityChanged", function(npcId, playerId, epoch, reason)
    for pid, ride in pairs(rides) do
        if ride.npcId and tostring(ride.npcId) == tostring(npcId) then
            print(("[eval_taxi] driver npc=%s vehicle=%s player=%d owner=%s epoch=%s reason=%s"):format(
                tostring(npcId), tostring(ride.vehicleId), pid, tostring(playerId), tostring(epoch), tostring(reason)))
            return
        end
    end
end)

AddEventHandler("onNpcRemoved", function(npcId, reason)
    for pid, ride in pairs(rides) do
        if ride.npcId and tostring(ride.npcId) == tostring(npcId) and not ride.ending then
            print(("[eval_taxi] driver npc=%s vehicle=%s player=%d removed reason=%s"):format(
                tostring(npcId), tostring(ride.vehicleId), pid, tostring(reason)))
            ride.npcId = nil   -- the controller reports the missing driver through `failed`
            return
        end
    end
end)

AddEventHandler("onVehicleRemoved", function(id, reason)
    local ride, playerId = rideOf(id)
    if not ride or ride.ending then return end
    print(("[eval_taxi] ride vehicle=%s player=%d vehicle removed reason=%s"):format(
        tostring(id), playerId, tostring(reason)))
    say(playerId, "Your taxi is gone (" .. tostring(reason) .. ").")
    finishRide(playerId, false, "vehicle_removed:" .. tostring(reason))
end)

-- A passenger who gets out mid-ride ends it; our own forced exit happens after the ride is
-- already unregistered, so it never comes through here.
AddEventHandler("onPlayerLeftVehicle", function(playerId, vehicleId)
    local pid = tonumber(playerId)
    local ride = pid and rides[pid]
    if not ride or ride.ending or ride.phase ~= "riding" then return end
    if tostring(ride.vehicleId) ~= tostring(vehicleId) then return end
    print(("[eval_taxi] ride vehicle=%s player=%d passenger left the taxi"):format(tostring(vehicleId), pid))
    say(pid, "You left the taxi: ride cancelled.")
    finishRide(pid, false, "passenger_left")
end)

-- A passenger who leaves the server takes their taxi with them.
AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = tonumber(playerId)
    if pid then finishRide(pid, false, "disconnect") end
end)

AddEventHandler("onResourceStart", function(resourceName)
    if resourceName ~= RESOURCE_NAME then return end
    print("[eval_taxi] started: /taxi drives you to your map waypoint, /taxi cancel ends the ride")
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= RESOURCE_NAME then return end
    for pid in pairs(rides) do
        finishRide(pid, false, "resource_stop")
    end
end)
