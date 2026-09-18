-- rp_ambiance -- server half.
--
-- Five independent layers, each guarded by its Config block and each degrading on its own:
--   (1) day cycle + weighted weather table   Open77.environment.*   (world.environment)
--   (2) figurants: civilians per key zone    Open77.npcs.*          (world.npcs)
--   (3) rotating notices                     Open77.notifications.* (network.events)
--   (4) NCPD alert sirens                    Open77.effects.play    (world.effects)
--   (5) ambience loop per zone               Open77.sound.*         (network.events)
-- Nothing here is persisted: the cycle, the notices and the figurants are recomputed
-- from shared/config.lua at every start, so there is no SQL table.

local RESOURCE = GetCurrentResourceName()

local WEATHER_PRESETS = {
    sunny = true, lightclouds = true, cloudy = true, rain = true,
    heavyclouds = true, fog = true, pollution = true, sandstorm = true,
}

local TASK_FINISHED = { success = true, failure = true, cancelled = true, interrupted = true }

local state = {
    running = false,
    cycle = {
        environmentOk = false,   -- false until Open77.environment answers
        rate = nil,
        current = nil,           -- preset this resource applied last
        nextDrawAt = 0,
        retryAt = 0,
        draws = 0,
        previousWeatherFrozen = nil,
    },
    notices = { index = 0, nextAt = 0, sent = 0 },
    figurants = { slots = {}, byId = {}, nextSweepAt = 0 },
    music = { sessions = {}, warned = {} },  -- sessions[playerId] = { [zone] = soundId }
    alerts = { lastAt = {}, played = 0 },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_ambiance] " .. fmt):format(...))
end

local function now()
    return Open77.time.monotonic()
end

local function fmtDuration(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    if seconds >= 3600 then
        return ("%dh%02dm"):format(seconds // 3600, (seconds % 3600) // 60)
    end
    return ("%dm%02ds"):format(seconds // 60, seconds % 60)
end

-- One line to the console (source 0) or to a player, in the resource colour. Two chat sends
-- in the same tick land in reverse order, so a Wait(0) separates consecutive lines.
local function reply(source, text)
    if source == 0 then
        print(text)
        return
    end
    Open77.chat.send(source, { author = Config.command.chatAuthor, text = text, color = Config.command.chatColor })
    Wait(0)
end

local function randomBetween(minValue, maxValue)
    if maxValue <= minValue then return minValue end
    return minValue + math.random() * (maxValue - minValue)
end

local function toPosition(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z, bucket = tonumber(value.bucket) }
end

local function sortedKeys(t)
    local keys = {}
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- rp_config overrides: optional, read through pcall, silently absent when rp_config is down.
local function applyOverrides()
    local applied = 0
    for _, entry in ipairs(Config.overrides or {}) do
        local ok, value = pcall(function() return exports.rp_config:get(entry.key, nil) end)
        -- Same type as the shipped value only: a string "false" would otherwise read as true.
        if ok and value ~= nil and Config[entry.section] and type(value) == type(Config[entry.section][entry.field]) then
            Config[entry.section][entry.field] = value
            applied = applied + 1
        end
    end
    if applied > 0 then log("%d rp_config override(s) applied", applied) end
    return applied
end

-- ---------------------------------------------------------------------------
-- (1) Day cycle and weather
-- ---------------------------------------------------------------------------

local function weatherRows()
    local rows, total = {}, 0
    for _, row in ipairs(Config.cycle.weather or {}) do
        local weight = tonumber(row.weight) or 0
        local allowed = not (row.badlandsOnly and not Config.cycle.badlands)
        if allowed and weight > 0 and type(row.preset) == "string" then
            rows[#rows + 1] = row
            total = total + weight
        end
    end
    return rows, total
end

local function drawWeather(exclude)
    local rows, total = weatherRows()
    local pool, sum = {}, 0
    for _, row in ipairs(rows) do
        if row.preset ~= exclude then
            pool[#pool + 1] = row
            sum = sum + row.weight
        end
    end
    if #pool == 0 then pool, sum = rows, total end
    if #pool == 0 then return nil end
    local r = math.random() * sum
    for _, row in ipairs(pool) do
        r = r - row.weight
        if r <= 0 then return row end
    end
    return pool[#pool]
end

local function weatherRowFor(preset)
    for _, row in ipairs(Config.cycle.weather or {}) do
        if row.preset == preset then return row end
    end
    return { preset = preset, label = preset, toast = ("Weather shifting to %s."):format(preset) }
end

local function announceWeather(row)
    if not Config.cycle.announceWeather then return end
    Open77.notifications.broadcast({
        type = (row.preset == "sandstorm" or row.preset == "rain") and "warning" or "info",
        title = "Weather - " .. (row.label or row.preset),
        message = row.toast or ("The sky turns to %s."):format(row.preset),
        icon = "SKY",
        position = "top_right",
        durationMs = Config.cycle.weatherToastMs or 8000,
    })
end

local function applyWeather(row, cause)
    local transition = tonumber(Config.cycle.weatherTransitionSeconds) or 45
    transition = math.floor(math.max(0, math.min(300, transition)))
    local st, reason = Open77.environment.setWeather(row.preset, transition)
    if not st then
        log("weather %s refused (%s): %s", row.preset, cause, tostring(reason))
        if reason == "environment_unavailable" then state.cycle.environmentOk = false end
        return nil, reason
    end
    state.cycle.current = row.preset
    state.cycle.draws = state.cycle.draws + 1
    log("weather -> %s over %ds (%s)", row.preset, transition, cause)
    announceWeather(row)
    return st
end

local function scheduleNextDraw()
    local minS = math.max(1, tonumber(Config.cycle.weatherMinMinutes) or 12) * 60
    local maxS = math.max(minS, (tonumber(Config.cycle.weatherMaxMinutes) or 25) * 60)
    state.cycle.nextDrawAt = now() + randomBetween(minS, maxS)
end

-- Applies the rate, the optional start hour, pins the platform's own random scheduler and
-- makes the first draw. Answers false when open77_weather is not running (retried later).
local function applyCycle(cause)
    local hours = tonumber(Config.cycle.realHoursPerDay) or 3
    if hours <= 0 then hours = 3 end
    local rate = math.min(120, 24 / hours)

    local st, reason = Open77.environment.setTimeRate(rate)
    if not st then
        state.cycle.environmentOk = false
        state.cycle.retryAt = now() + 30
        log("environment unavailable (%s): day cycle and weather table paused, retry in 30 s", tostring(reason))
        return false
    end
    state.cycle.environmentOk = true
    state.cycle.rate = rate
    if math.abs(rate - 8.0) > 0.001 then
        log("warning: %.1f real hours per day means rate %.2f; the engine's own rate is 8.0 (3 h per day) and any other value costs a world time-jump at every drift correction", hours, rate)
    end

    local startHour = tonumber(Config.cycle.startHour)
    if startHour then
        local ok, why = Open77.environment.setTime(math.floor(startHour) % 24, 0, 0)
        if not ok then log("start hour refused: %s", tostring(why)) end
    end

    if state.cycle.previousWeatherFrozen == nil then
        state.cycle.previousWeatherFrozen = st.weatherFrozen == true
    end
    local pinned, pinReason = Open77.environment.setWeatherFrozen(true)
    if not pinned then log("could not pin the platform weather scheduler: %s", tostring(pinReason)) end

    local row = drawWeather(nil)
    if row then applyWeather(row, cause) else log("weather table is empty: nothing to draw") end
    scheduleNextDraw()
    log("cycle: %.1f real h per game day (rate %.1f), %d weather rows, next draw in %s",
        hours, rate, #(weatherRows()), fmtDuration(state.cycle.nextDrawAt - now()))
    return true
end

local function cycleThread()
    while state.running do
        Wait(5000)
        if not state.running then return end
        if not state.cycle.environmentOk then
            if now() >= state.cycle.retryAt then applyCycle("retry") end
        elseif now() >= state.cycle.nextDrawAt then
            local row = drawWeather(state.cycle.current)
            if row then applyWeather(row, "draw") end
            scheduleNextDraw()
        end
    end
end

-- ---------------------------------------------------------------------------
-- (3) Rotating notices
-- ---------------------------------------------------------------------------

local function noticeInterval()
    return math.max(1, tonumber(Config.notices.intervalMinutes) or 15) * 60
end

local function sendNotice()
    local lines = Config.notices.lines or {}
    if #lines == 0 then return nil, "no_lines" end
    state.notices.index = (state.notices.index % #lines) + 1
    local text = lines[state.notices.index]
    local id, reason = Open77.notifications.broadcast({
        type = Config.notices.type or "info",
        title = Config.notices.title,
        message = text,
        icon = Config.notices.icon,
        position = Config.notices.position or "top_right",
        durationMs = Config.notices.durationMs or 10000,
        color = Config.notices.color,
    })
    if not id then
        log("notice #%d refused: %s", state.notices.index, reason)
        return nil, reason
    end
    if Config.notices.chatEcho then
        Open77.chat.send(-1, { author = Config.notices.chatAuthor or "Night City", text = text, color = Config.notices.chatColor })
    end
    state.notices.sent = state.notices.sent + 1
    return state.notices.index
end

local function noticesThread()
    while state.running do
        Wait(1000)
        if not state.running then return end
        if Config.notices.enabled and now() >= state.notices.nextAt then
            sendNotice()
            state.notices.nextAt = now() + noticeInterval()
        end
    end
end

-- ---------------------------------------------------------------------------
-- (2) Figurants
-- ---------------------------------------------------------------------------

local function slotSpawnPosition(zone, index, count)
    local angle = (index - 1) * (2 * math.pi / math.max(1, count))
    local distance = 2.5
    return {
        x = zone.centre.x + math.cos(angle) * distance,
        y = zone.centre.y + math.sin(angle) * distance,
        z = zone.centre.z,
    }
end

local function issueWander(slot)
    if not slot.id then return end
    local taskId, reason = Open77.npcs.tasks.wander(slot.id, {
        x = slot.zone.centre.x, y = slot.zone.centre.y, z = slot.zone.centre.z,
        radius = tonumber(Config.figurants.wanderRadius) or 6.0,
        speed = "walk",
        timeoutMs = 0,
    })
    if not taskId then
        log("figurant %s#%d: wander refused: %s", slot.zoneName, slot.index, tostring(reason))
        return
    end
    slot.wanderTask = taskId
end

local function spawnSlot(slot)
    local body = Config.figurants.bodies[slot.bodyKey]
    if not body then
        log("figurant %s#%d: unknown body '%s' (Config.figurants.bodies)", slot.zoneName, slot.index, tostring(slot.bodyKey))
        return false
    end
    local definition = {
        position = slot.spawn,
        yaw = math.random(0, 359) + 0.0,
        damagePolicy = Config.figurants.damagePolicy or 2,
        streamingRadius = Config.figurants.streamingRadius or 150,
        behavior = { combatEnabled = false },
        persistent = false,
    }
    if body.record then definition.record = body.record else definition.template = body.template end
    local id, reason = Open77.npcs.create(definition)
    if not id then
        log("figurant %s#%d (%s) could not spawn: %s", slot.zoneName, slot.index, body.record or body.template, tostring(reason))
        return false
    end
    slot.id = id
    slot.dead = false
    slot.spawnedAt = now()
    slot.nextSpeakAt = now() + 5
    slot.wanderFailures = 0
    state.figurants.byId[tostring(id)] = slot
    issueWander(slot)
    return true
end

local function removeSlot(slot)
    if not slot.id then return end
    state.figurants.byId[tostring(slot.id)] = nil
    Open77.npcs.remove(slot.id)
    slot.id = nil
    slot.wanderTask = nil
end

local function removeAllFigurants()
    for _, slot in ipairs(state.figurants.slots) do removeSlot(slot) end
    state.figurants.slots = {}
    state.figurants.byId = {}
end

-- Warns when a configured zone is unknown to rp_zones (informative: the centres live here).
local function checkZonesKnown()
    local ok, list = pcall(function() return exports.rp_zones:list() end)
    if not ok or type(list) ~= "table" then
        log("rp_zones list unavailable: zone names not checked")
        return
    end
    local known = {}
    for _, zone in ipairs(list) do known[zone.name] = true end
    for _, zoneName in ipairs(sortedKeys(Config.figurants.zones or {})) do
        if not known[zoneName] then log("figurant zone '%s' is not an rp_zones zone (figurants still spawn at its configured centre)", zoneName) end
    end
end

local function buildFigurants()
    removeAllFigurants()
    if not Config.figurants.enabled then
        log("figurants disabled")
        return
    end
    local spawned, wanted = 0, 0
    for _, zoneName in ipairs(sortedKeys(Config.figurants.zones or {})) do
        local zone = Config.figurants.zones[zoneName]
        local centre = toPosition(zone.centre)
        local bodies = zone.bodies or {}
        if not centre or #bodies == 0 then
            log("figurant zone '%s' skipped: needs a centre and at least one body", zoneName)
        else
            zone.centre = centre
            for index = 1, #bodies do
                local slot = {
                    zoneName = zoneName,
                    zone = zone,
                    index = index,
                    bodyKey = bodies[index],
                    name = (zone.names and zone.names[index]) or "Passer-by",
                    spawn = slotSpawnPosition(zone, index, #bodies),
                    lastLine = 0,
                    nextSpeakAt = 0,
                }
                state.figurants.slots[#state.figurants.slots + 1] = slot
                wanted = wanted + 1
                if spawnSlot(slot) then spawned = spawned + 1 end
            end
        end
    end
    state.figurants.nextSweepAt = now() + (tonumber(Config.figurants.sweepSeconds) or 300)
    log("figurants: %d/%d spawned in %d zone(s)", spawned, wanted, #sortedKeys(Config.figurants.zones or {}))
end

local function figurantCounts()
    local alive, wanted, perZone = 0, 0, {}
    for _, slot in ipairs(state.figurants.slots) do
        wanted = wanted + 1
        perZone[slot.zoneName] = perZone[slot.zoneName] or { alive = 0, wanted = 0 }
        perZone[slot.zoneName].wanted = perZone[slot.zoneName].wanted + 1
        if slot.id and not slot.dead then
            alive = alive + 1
            perZone[slot.zoneName].alive = perZone[slot.zoneName].alive + 1
        end
    end
    return alive, wanted, perZone
end

local function hasLiveWander(slot)
    if not slot.id then return false end
    for _, task in ipairs(Open77.npcs.tasks.all(slot.id) or {}) do
        if task.type == "wander" and not TASK_FINISHED[task.status] then return true end
    end
    return false
end

-- Every sweep: bring back a killed or missing figurant, and re-issue a wander that ended.
local function sweepFigurants()
    local respawned = 0
    for _, slot in ipairs(state.figurants.slots) do
        local snapshot = slot.id and Open77.npcs.get(slot.id) or nil
        if not snapshot or slot.dead or (tonumber(snapshot.health) or 1) <= 0 then
            removeSlot(slot)
            if spawnSlot(slot) then respawned = respawned + 1 end
        elseif not hasLiveWander(slot) then
            issueWander(slot)
        end
    end
    if respawned > 0 then log("sweep: %d figurant(s) respawned", respawned) end
end

local function pickLine(slot, nearest)
    local zone = slot.zone
    local pool = zone.lines or {}
    -- Job flavour through rp_jobs (optional): the nearest player's job selects another pool.
    if zone.linesForJob and nearest and nearest.playerId then
        local ok, job = pcall(function() return exports.rp_jobs:getJob(nearest.playerId) end)
        if ok and type(job) == "string" and zone.linesForJob[job] and #zone.linesForJob[job] > 0 and math.random() < 0.5 then
            pool = zone.linesForJob[job]
        end
    end
    if #pool == 0 then return nil end
    local index = math.random(#pool)
    if #pool > 1 and index == slot.lastLine then index = (index % #pool) + 1 end
    slot.lastLine = index
    return pool[index]
end

local function speakLine(slot, nearby)
    local line = pickLine(slot, nearby[1])
    if not line then return end
    local barks = Config.figurants.barks or {}
    if #barks > 0 then
        local ok, reason = Open77.npcs.speak(slot.id, barks[math.random(#barks)])
        if not ok and reason ~= "npc_voice_busy" and reason ~= "npc_not_streamed" then
            log("figurant %s#%d bark refused: %s", slot.zoneName, slot.index, tostring(reason))
        end
    end
    for _, entry in ipairs(nearby) do
        local playerId = tonumber(entry.playerId)
        if playerId then
            Open77.chat.send(playerId, { author = slot.name, text = line, color = Config.figurants.chatColor })
        end
    end
end

local function speechThread()
    while state.running do
        Wait(5000)
        if not state.running then return end
        local speakRadius = tonumber(Config.figurants.speakRadius) or 8.0
        local minS = tonumber(Config.figurants.speakMinSeconds) or 60
        local maxS = math.max(minS, tonumber(Config.figurants.speakMaxSeconds) or 120)
        for _, slot in ipairs(state.figurants.slots) do
            if slot.id and not slot.dead and now() >= slot.nextSpeakAt then
                local snapshot = Open77.npcs.get(slot.id)
                if snapshot then
                    local nearby = Open77.players.nearby(
                        { x = snapshot.x, y = snapshot.y, z = snapshot.z }, speakRadius,
                        { bucket = tonumber(snapshot.bucket) or 0 })
                    if nearby and #nearby > 0 then
                        speakLine(slot, nearby)
                        slot.nextSpeakAt = now() + randomBetween(minS, maxS)
                    else
                        slot.nextSpeakAt = now() + 8
                    end
                end
            end
        end
        if now() >= state.figurants.nextSweepAt then
            state.figurants.nextSweepAt = now() + (tonumber(Config.figurants.sweepSeconds) or 300)
            if Config.figurants.enabled then sweepFigurants() end
        end
    end
end

AddEventHandler("onNpcDied", function(npcId)
    local slot = state.figurants.byId[tostring(npcId)]
    if not slot then return end
    slot.dead = true
    log("figurant %s#%d died; back at the next sweep (%s)", slot.zoneName, slot.index,
        fmtDuration(state.figurants.nextSweepAt - now()))
end)

AddEventHandler("onNpcRemoved", function(npcId, reason, resource)
    local slot = state.figurants.byId[tostring(npcId)]
    if not slot or not slot.id then return end   -- our own removeSlot clears slot.id first
    state.figurants.byId[tostring(npcId)] = nil
    slot.id = nil
    slot.wanderTask = nil
    log("figurant %s#%d removed (%s); back at the next sweep", slot.zoneName, slot.index, tostring(reason))
end)

-- A wander that ended (success, timeout, interruption by an authority change...) is issued
-- again; repeated failures back off up to a minute so a body the navmesh refuses does not
-- spin the task queue.
AddEventHandler("onNpcTaskState", function(npcId, taskId, status)
    local slot = state.figurants.byId[tostring(npcId)]
    if not slot or not slot.wanderTask then return end
    if tostring(taskId) ~= tostring(slot.wanderTask) or not TASK_FINISHED[status] then return end
    slot.wanderTask = nil
    if status == "failure" then
        slot.wanderFailures = (slot.wanderFailures or 0) + 1
    else
        slot.wanderFailures = 0
    end
    Wait(math.min(60000, 2000 + 5000 * (slot.wanderFailures or 0)))
    if state.running and slot.id and not slot.dead and not slot.wanderTask then issueWander(slot) end
end)

-- ---------------------------------------------------------------------------
-- (4) NCPD alert sirens
-- ---------------------------------------------------------------------------

local function playSiren(position, cause)
    local flashes = math.max(1, math.floor(tonumber(Config.alerts.flashes) or 3))
    local interval = math.max(100, math.floor(tonumber(Config.alerts.flashIntervalMs) or 1200))
    local range = math.max(1, math.min(500, tonumber(Config.alerts.range) or 60))
    for i = 1, flashes do
        local options = {
            position = { x = position.x, y = position.y, z = position.z + 1.0 },
            bucket = position.bucket or 0,
            range = range,
        }
        if i == 1 and type(Config.alerts.sound) == "string" and Config.alerts.sound ~= "" then
            options.sound = Config.alerts.sound
        end
        local ok, reason = Open77.effects.play(Config.alerts.effect, options)
        if not ok then
            log("siren (%s) refused: %s", cause, tostring(reason))
            return false, reason
        end
        if i < flashes then Wait(interval) end
    end
    state.alerts.played = state.alerts.played + 1
    return true
end

AddEventHandler("rp_ncpd:alert", function(kind, position, text, byPlayerId)
    if not state.running or not Config.alerts.enabled then return end
    local pos = toPosition(position)
    if not pos then
        -- Open77.players.position throws for id <= 0 (console alerts carry 0) or a non-integer.
        local by = tonumber(byPlayerId)
        if by and by >= 1 and by % 1 == 0 then pos = Open77.players.position(math.floor(by)) end
    end
    if not pos then
        log("alert '%s' carried no usable position: no siren", tostring(kind))
        return
    end
    local key = ("%d:%d"):format(math.floor(pos.x / 5), math.floor(pos.y / 5))
    local cooldown = tonumber(Config.alerts.cooldownSeconds) or 8
    if state.alerts.lastAt[key] and now() - state.alerts.lastAt[key] < cooldown then return end
    state.alerts.lastAt[key] = now()
    playSiren(pos, "alert:" .. tostring(kind))
end)

-- ---------------------------------------------------------------------------
-- (5) Ambience loop per zone
-- ---------------------------------------------------------------------------

local function warnOnce(key, fmt, ...)
    if state.music.warned[key] then return end
    state.music.warned[key] = true
    log(fmt, ...)
end

-- The loop for a zone, or nil plus why (no loop configured, or a resource already covers it).
local function musicFor(zoneName)
    local entry = Config.music.zones and Config.music.zones[zoneName]
    if not entry or type(entry.file) ~= "string" then return nil end
    local blocker = Config.music.skipWhenResourceRuns and Config.music.skipWhenResourceRuns[zoneName]
    if blocker and Open77.resource.state(blocker) == "running" then
        return nil, "covered_by_" .. blocker
    end
    return entry
end

local function startMusic(playerId, zoneName)
    if not Config.music.enabled then return end
    local entry, why = musicFor(zoneName)
    if not entry then
        if why then warnOnce("skip:" .. zoneName, "ambience for %s skipped: %s already plays there", zoneName, why:sub(12)) end
        return
    end
    if Open77.resource.state("open77_sound") ~= "running" then
        warnOnce("nosound", "open77_sound is not running: zone ambience disabled")
        return
    end
    local soundId = "zone:" .. zoneName
    local id, reason = Open77.sound.play(playerId, entry.file, {
        id = soundId,
        loop = true,
        volume = math.max(0, math.min(1, tonumber(Config.music.volume) or 0.35)),
    })
    if not id then
        log("ambience %s for player %d refused: %s", zoneName, playerId, tostring(reason))
        return
    end
    state.music.sessions[playerId] = state.music.sessions[playerId] or {}
    state.music.sessions[playerId][zoneName] = soundId
end

local function stopMusic(playerId, zoneName)
    local sessions = state.music.sessions[playerId]
    if not sessions or not sessions[zoneName] then return end
    Open77.sound.stop(playerId, sessions[zoneName])   -- a departed player simply answers no_audience
    sessions[zoneName] = nil
    if next(sessions) == nil then state.music.sessions[playerId] = nil end
end

local function musicListeners()
    local count = 0
    for _, sessions in pairs(state.music.sessions) do
        if next(sessions) ~= nil then count = count + 1 end
    end
    return count
end

AddEventHandler("rp_zones:entered", function(playerId, zoneName)
    if not state.running then return end
    local id = tonumber(playerId)
    if id and id > 0 and type(zoneName) == "string" then startMusic(id, zoneName) end
end)

AddEventHandler("rp_zones:left", function(playerId, zoneName)
    local id = tonumber(playerId)
    if id and type(zoneName) == "string" then stopMusic(id, zoneName) end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if id then state.music.sessions[id] = nil end
end)

-- Players already standing in a music zone when this resource (re)starts get no `entered`.
local function musicHotStart()
    if not Config.music.enabled then return end
    for _, playerId in ipairs(Open77.players.all()) do
        for zoneName in pairs(Config.music.zones or {}) do
            local ok, inside = pcall(function() return exports.rp_zones:isIn(playerId, zoneName) end)
            if ok and inside == true then startMusic(playerId, zoneName) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- /ambiance (restricted: ACL command.ambiance, or the console)
-- ---------------------------------------------------------------------------

local function statusLines()
    local lines = {}
    local env = state.cycle.environmentOk and Open77.environment.getState() or nil
    if env then
        local dayPercent = (tonumber(env.secondsOfDay) or 0) / 864
        lines[#lines + 1] = ("Cycle: %02d:%02d game time (%.0f%% of the day), rate %.1f game s per real s (%.1f real h per day)%s"):format(
            math.floor(tonumber(env.hour) or 0), math.floor(tonumber(env.minute) or 0), dayPercent, tonumber(env.rate) or 0,
            tonumber(Config.cycle.realHoursPerDay) or 3, env.frozen and " - CLOCK FROZEN" or "")
        local rows = {}
        for _, row in ipairs((weatherRows())) do rows[#rows + 1] = ("%s %s"):format(row.preset, tostring(row.weight)) end
        lines[#lines + 1] = ("Weather: %s now (%d draw(s) so far), next draw in %s; table: %s"):format(
            tostring(env.weather), state.cycle.draws, fmtDuration(state.cycle.nextDrawAt - now()), table.concat(rows, ", "))
    else
        lines[#lines + 1] = "Cycle: open77_weather is not answering (environment_unavailable) - retrying every 30 s."
    end
    local alive, wanted, perZone = figurantCounts()
    local zoneParts = {}
    for _, zoneName in ipairs(sortedKeys(perZone)) do
        zoneParts[#zoneParts + 1] = ("%s %d/%d"):format(zoneName, perZone[zoneName].alive, perZone[zoneName].wanted)
    end
    lines[#lines + 1] = ("Figurants: %d/%d alive (%s), next sweep in %s"):format(
        alive, wanted, #zoneParts > 0 and table.concat(zoneParts, ", ") or "none", fmtDuration(state.figurants.nextSweepAt - now()))
    lines[#lines + 1] = ("Notices: %d line(s) every %s min, %d sent, next in %s%s"):format(
        #(Config.notices.lines or {}), tonumber(Config.notices.intervalMinutes) or 15, state.notices.sent,
        fmtDuration(state.notices.nextAt - now()), Config.notices.enabled and "" or " (disabled)")
    local musicParts = {}
    for _, zoneName in ipairs(sortedKeys(Config.music.zones or {})) do
        local entry, why = musicFor(zoneName)
        musicParts[#musicParts + 1] = entry and zoneName or ("%s skipped (%s)"):format(zoneName, why or "off")
    end
    lines[#lines + 1] = ("Music: %s; %d player(s) listening. Sirens: %s + %s within %.0f m, %d played"):format(
        #musicParts > 0 and table.concat(musicParts, ", ") or "none", musicListeners(),
        tostring(Config.alerts.effect), tostring(Config.alerts.sound), tonumber(Config.alerts.range) or 60, state.alerts.played)
    return lines
end

local function reloadAll()
    local overrides = applyOverrides()
    state.cycle.environmentOk = false
    applyCycle("reload")
    state.notices.nextAt = now() + noticeInterval()
    buildFigurants()
    musicHotStart()
    return overrides
end

local function usage(source)
    reply(source, "/ambiance status | reload | weather <preset> | time <hour[:minute]> | notice | siren")
    reply(source, "Presets: sunny, lightclouds, cloudy, rain, heavyclouds, fog, pollution, sandstorm.")
end

RegisterCommand(Config.command.name, function(source, args)
    local action = (args[1] or "status"):lower()
    if action == "status" then
        for _, line in ipairs(statusLines()) do reply(source, line) end
    elseif action == "reload" then
        local overrides = reloadAll()
        reply(source, ("Ambiance reloaded: cycle re-applied, figurants respawned, %d rp_config override(s)."):format(overrides))
    elseif action == "weather" then
        local preset = args[2] and args[2]:lower() or nil
        if not preset then return usage(source) end
        if not WEATHER_PRESETS[preset] and preset:sub(1, 12) ~= "24h_weather_" then
            return reply(source, ("Unknown preset '%s'. Presets: sunny, lightclouds, cloudy, rain, heavyclouds, fog, pollution, sandstorm."):format(preset))
        end
        if not state.cycle.environmentOk then
            return reply(source, "open77_weather is not answering: no weather authority on this server.")
        end
        local st, reason = applyWeather(weatherRowFor(preset), "command")
        if not st then return reply(source, ("Weather refused: %s"):format(tostring(reason))) end
        scheduleNextDraw()
        reply(source, ("Weather set to %s; the next random draw is in %s."):format(preset, fmtDuration(state.cycle.nextDrawAt - now())))
    elseif action == "time" then
        local value = args[2]
        if not value then return usage(source) end
        local hour, minute = value:match("^(%d+):(%d+)$")
        if not hour then hour, minute = value:match("^(%d+)$"), "0" end
        hour, minute = tonumber(hour), tonumber(minute)
        if not hour or hour < 0 or hour > 23 or not minute or minute < 0 or minute > 59 then
            return reply(source, "Usage: /ambiance time <0-23>[:<0-59>]")
        end
        if not state.cycle.environmentOk then
            return reply(source, "open77_weather is not answering: no clock authority on this server.")
        end
        local st, reason = Open77.environment.setTime(hour, minute, 0)
        if not st then return reply(source, ("Time refused: %s"):format(tostring(reason))) end
        log("time -> %02d:%02d (command)", hour, minute)
        reply(source, ("Clock set to %02d:%02d for everyone."):format(hour, minute))
    elseif action == "notice" then
        local index, reason = sendNotice()
        if not index then return reply(source, ("No notice sent: %s"):format(tostring(reason))) end
        state.notices.nextAt = now() + noticeInterval()
        reply(source, ("Notice #%d sent to everyone; the rotation continues in %s min."):format(index, tostring(tonumber(Config.notices.intervalMinutes) or 15)))
    elseif action == "siren" then
        if source == 0 then return reply(source, "siren: run it from the game, the console has no position.") end
        local pos = Open77.players.position(source)
        if not pos then return reply(source, "Your position is unknown right now; try again in a second.") end
        local ok, reason = playSiren(pos, "command")
        if not ok then return reply(source, ("Siren refused: %s"):format(tostring(reason))) end
        reply(source, ("Siren played at your position for everyone within %.0f m."):format(tonumber(Config.alerts.range) or 60))
    else
        usage(source)
    end
end, true)

local function publishSuggestion(target)
    Open77.chat.addSuggestion(target, "/" .. Config.command.name,
        "Admin: city ambiance (status, reload, weather, time, notice, siren)", {
            { name = "action", help = "status | reload | weather | time | notice | siren" },
            { name = "value", help = "weather preset, or hour[:minute]" },
        })
end

RegisterNetEvent("chat:ready", function()
    if source and source > 0 then publishSuggestion(source) end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    state.running = true
    pcall(math.randomseed, math.floor(Open77.time.unix() * 1000) % 2147483647)
    applyOverrides()
    applyCycle("start")
    state.notices.nextAt = now() + noticeInterval()
    checkZonesKnown()
    buildFigurants()
    musicHotStart()
    publishSuggestion(-1)
    CreateThread(cycleThread)
    CreateThread(noticesThread)
    CreateThread(speechThread)
    log("started: %d notice(s) every %s min, sirens %s, music %s (%d zone loop(s))",
        #(Config.notices.lines or {}), tonumber(Config.notices.intervalMinutes) or 15,
        Config.alerts.enabled and "on" or "off", Config.music.enabled and "on" or "off",
        #sortedKeys(Config.music.zones or {}))
end)

-- rp_zones coming back replaces its VM: players already inside a music zone get no new
-- `entered`, so the loops are re-seeded from its exports.
AddEventHandler("onResourceStart", function(name)
    if name ~= "rp_zones" or not state.running then return end
    Wait(1000)
    musicHotStart()
end)

AddEventHandler("onResourceStop", function(name, reason)
    if name ~= RESOURCE then return end
    state.running = false
    removeAllFigurants()
    if state.cycle.environmentOk and state.cycle.previousWeatherFrozen ~= nil then
        Open77.environment.setWeatherFrozen(state.cycle.previousWeatherFrozen)
    end
    Open77.sound.stopAll()   -- also sent by the host; explicit so the loops die with the resource
    state.music.sessions = {}
    log("stopped (%s): figurants removed, weather scheduler restored", tostring(reason))
end)
