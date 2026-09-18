-- rp_delamain / server
-- Server-authoritative player taxi. Everything that decides something lives here: who is a
-- driver (rp_jobs), who rides with whom, how far the cab went, what it costs, who gets paid.
-- The client half only draws pins, moves the driver's GPS and reports the caller's waypoint.
--
-- Ride phases: waiting -> accepted -> riding -> ended, or cancelled from any of the first three.
-- Every transition raises the host-wide event rp_delamain:ride (rideId, phase, driverId, clientId).

local Config        = RpDelamainConfig
local RESOURCE_NAME = "rp_delamain"

-- ride = { id, clientId, driverId, phase, destination = {x,y,z}|nil, calledAt, acceptedAt,
--          startedAt, endedAt, metres, vehicleId, lastPos, seated, boarded, lastWaypoint,
--          fare, paid, rating, rowId, askedWaypoint }
local rides        = {}   -- rideId -> ride (active only: waiting / accepted / riding)
local rideOfPlayer = {}   -- playerId -> rideId (client or driver of an active ride)
local lastRideOf   = {}   -- clientId -> ended ride (rating window)
local driverStats  = {}   -- identifier -> { rides, ratingSum, ratingCount, loaded }
local nextRideId   = 1

-- Persistence: "sql" once the database answered, "kvp" when it never will; nil while undecided.
local store        = nil
local pendingRows  = {}   -- rows written before the store was decided

local SUGGESTIONS = {
    { command = "/delamain", help = "Call a Delamain driver (your map waypoint, or a preset: afterlife, afterlife_lot, dealer, lizzies)",
      parameters = { { name = "annuler", help = "optional: drop your current call / ride" } } },
    { command = "/accepter", help = "Delamain driver: take a call",
      parameters = { { name = "rideId", help = "the ride number from the dispatch line" } } },
    { command = "/course",   help = "Your current Delamain ride, either side" },
    { command = "/fin",      help = "Delamain driver: end the ride once the passenger got out" },
    { command = "/note",     help = "Rate your last Delamain ride",
      parameters = { { name = "1-5", help = "stars" } } },
}

---------------------------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[%s] " .. fmt):format(RESOURCE_NAME, ...))
end

local function say(playerId, text)
    playerId = tonumber(playerId)
    if not playerId then return end
    local ok, reason = Open77.chat.send(playerId, {
        author = Config.ChatAuthor,
        text   = text,
        color  = Config.ChatColor,
    })
    if not ok then log("chat.send to %d failed: %s", playerId, tostring(reason)) end
end

local toastFailureLogged = false
local function toast(playerId, kind, title, message)
    playerId = tonumber(playerId)
    if not playerId then return end
    -- Optional channel: without open77_notifications the toast is simply not shown, chat carries it.
    local id, reason = Open77.notifications.send(playerId, {
        type = kind, title = title, message = message, icon = "E$", durationMs = 7000,
    })
    if not id and not toastFailureLogged then
        toastFailureLogged = true
        log("notifications unavailable (%s); chat carries every message", tostring(reason))
    end
end

local function isConnected(playerId)
    return type(playerId) == "number" and playerId >= 1 and playerId % 1 == 0
        and Open77.players.name(playerId) ~= nil
end

local function isFinite(n)
    return type(n) == "number" and n == n and n > -1e300 and n < 1e300
end

local function validPoint(p)
    if type(p) ~= "table" then return nil end
    local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
    if not (isFinite(x) and isFinite(y) and isFinite(z)) then return nil end
    if math.abs(x) > 16000 or math.abs(y) > 16000 or math.abs(z) > 16000 then return nil end
    return { x = x, y = y, z = z }
end

local function dist(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function fmtDist(m)
    if not m then return "? m" end
    if m >= 1000 then return ("%.1f km"):format(m / 1000) end
    return ("%d m"):format(math.floor(m + 0.5))
end

local function fmtMoney(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", "")) .. " €$"
end

-- RP name from rp_identity when it runs, else the account name.
local function nameOf(playerId)
    -- Open77.players.name raises for nil / id <= 0 (a ride with no driver yet, a console caller).
    if type(playerId) ~= "number" or playerId < 1 or playerId % 1 ~= 0 then return "#" .. tostring(playerId) end
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and #name > 0 then return name end
    return Open77.players.name(playerId) or ("#" .. tostring(playerId))
end

local function fareFor(metres)
    return math.floor(Config.BaseFare + Config.PerHundredMetres * metres / 100 + 0.5)
end

local function isDriverSeat(seat)
    return seat == "seat_front_left" or seat == "driver" or seat == -1
end

local function emit(ride, phase)
    local ok, reason = TriggerEvent("rp_delamain:ride", ride.id, phase, ride.driverId, ride.clientId)
    if not ok then log("event rp_delamain:ride failed: %s", tostring(reason)) end
end

---------------------------------------------------------------------------------------------
-- Cross-resource calls (all optional, all through pcall: the manifest cannot depend on them)
---------------------------------------------------------------------------------------------

local function onDutyDrivers()
    local ok, list = pcall(function() return exports.rp_jobs:listOnDuty(Config.Job) end)
    if not ok or type(list) ~= "table" then return nil, "jobs_offline" end
    return list
end

local function isOnDutyDriver(playerId)
    local ok, has = pcall(function() return exports.rp_jobs:hasJob(playerId, Config.Job) end)
    if not ok or not has then return false, "not_a_driver" end
    local ok2, duty = pcall(function() return exports.rp_jobs:onDuty(playerId) end)
    if not ok2 or not duty then return false, "off_duty" end
    return true
end

local function takeCash(playerId, amount, reason)
    local ok, balance, why = pcall(function() return exports.rp_economy:remove(playerId, amount, reason) end)
    if not ok then return nil, "economy_offline" end
    if balance == nil then return nil, why or "refused" end
    return balance
end

local function giveCash(playerId, amount, reason)
    local ok, balance, why = pcall(function() return exports.rp_economy:add(playerId, amount, reason) end)
    if not ok then return nil, "economy_offline" end
    if balance == nil then return nil, why or "refused" end
    return balance
end

local function societyAdd(amount, reason)
    local ok, balance, why = pcall(function() return exports.rp_bank:societyAdd(Config.Society, amount, reason) end)
    if not ok then return nil, "bank_offline" end
    if balance == nil then return nil, why or "refused" end
    return balance
end

---------------------------------------------------------------------------------------------
-- Persistence: SQL first, kvp only when the database never answers
---------------------------------------------------------------------------------------------

local function statsKey(identifier) return "stats:" .. identifier end

local function statsFor(identifier)
    local s = driverStats[identifier]
    if not s then
        s = { rides = 0, ratingSum = 0, ratingCount = 0, loaded = false }
        driverStats[identifier] = s
    end
    return s
end

-- Loads a driver's totals once; `done(stats)` runs on this resource's scheduler.
local function loadDriverStats(identifier, done)
    local s = statsFor(identifier)
    if s.loaded or not store then
        if done then done(s) end
        return
    end
    if store == "kvp" then
        local raw = Open77.kvp.get(statsKey(identifier), "")
        local rides, sum, count = tostring(raw):match("^(%d+)|(%d+)|(%d+)$")
        s.rides, s.ratingSum, s.ratingCount = tonumber(rides) or 0, tonumber(sum) or 0, tonumber(count) or 0
        s.loaded = true
        if done then done(s) end
        return
    end
    Open77.database.single([[
        SELECT COUNT(*) AS rides,
               COALESCE(SUM(CASE WHEN rating > 0 THEN rating ELSE 0 END), 0) AS rating_sum,
               COALESCE(SUM(CASE WHEN rating > 0 THEN 1 ELSE 0 END), 0) AS rating_count
          FROM rp_delamain_rides
         WHERE driver = ? AND status = 'ended'
    ]], { identifier }, function(row)
        if row then
            s.rides, s.ratingSum, s.ratingCount =
                tonumber(row.rides) or 0, tonumber(row.rating_sum) or 0, tonumber(row.rating_count) or 0
        end
        s.loaded = true
        if done then done(s) end
    end)
end

local function saveStatsKvp(identifier)
    local s = statsFor(identifier)
    local ok, reason = Open77.kvp.set(statsKey(identifier), ("%d|%d|%d"):format(s.rides, s.ratingSum, s.ratingCount))
    if not ok then log("kvp stats write failed: %s", tostring(reason)) end
end

-- One row per finished or cancelled ride. `ride.rowId` is filled once the insert answered.
local function persistRide(ride, status)
    local row = {
        client   = ride.clientIdentifier or "",
        driver   = ride.driverIdentifier or "",
        metres   = math.floor(ride.metres + 0.5),
        fare     = ride.fare or 0,
        paid     = ride.paid or 0,
        rating   = ride.rating or 0,
        status   = status,
        calledAt = math.floor(ride.calledAt), acceptedAt = math.floor(ride.acceptedAt or 0),
        startedAt = math.floor(ride.startedAt or 0), endedAt = math.floor(ride.endedAt or 0),
        ride = ride,
    }
    if store == nil then
        pendingRows[#pendingRows + 1] = row
        return
    end
    if store == "kvp" then
        local n = (Open77.kvp.get("rides:count", 0) or 0) + 1
        Open77.kvp.set("rides:count", n)
        Open77.kvp.set("ride:" .. n, ("%s|%s|%d|%d|%d|%d|%s|%d|%d|%d|%d"):format(
            row.client, row.driver, row.metres, row.fare, row.paid, row.rating, row.status,
            row.calledAt, row.acceptedAt, row.startedAt, row.endedAt))
        ride.rowId = n
        return
    end
    Open77.database.insert([[
        INSERT INTO rp_delamain_rides
            (client, driver, metres, fare, paid, rating, status, called_at, accepted_at, started_at, ended_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], { row.client, row.driver, row.metres, row.fare, row.paid, row.rating, row.status,
          row.calledAt, row.acceptedAt, row.startedAt, row.endedAt }, function(insertId)
        if type(insertId) == "table" then insertId = insertId.insertId end
        ride.rowId = tonumber(insertId)
        -- A rating given before the insert answered is written now.
        if ride.rating and ride.rating > 0 and ride.rowId then
            Open77.database.update("UPDATE rp_delamain_rides SET rating = ? WHERE id = ?", { ride.rating, ride.rowId })
        end
    end)
end

local function persistRating(ride)
    if store == "kvp" then
        if ride.rowId then
            local raw = Open77.kvp.get("ride:" .. ride.rowId, "")
            local parts = {}
            for part in (tostring(raw) .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = part end
            if #parts == 11 then
                parts[6] = tostring(ride.rating)
                Open77.kvp.set("ride:" .. ride.rowId, table.concat(parts, "|"))
            end
        end
        if ride.driverIdentifier then saveStatsKvp(ride.driverIdentifier) end
        return
    end
    if store == "sql" and ride.rowId then
        Open77.database.update("UPDATE rp_delamain_rides SET rating = ? WHERE id = ?", { ride.rating, ride.rowId })
    end
    -- store == nil or the insert has not answered yet: persistRide's callback writes the rating.
end

local function decideStore(kind, reason)
    if store then return end
    store = kind
    log("store=%s%s", kind, reason and (" reason=" .. tostring(reason)) or (" table=rp_delamain_rides"))
    local queued = pendingRows
    pendingRows = {}
    for _, row in ipairs(queued) do persistRide(row.ride, row.status) end
end

local function setupDatabase()
    local ok, reason = Open77.database.ready(function()
        Open77.database.update([[
            CREATE TABLE IF NOT EXISTS rp_delamain_rides (
                id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
                client      VARCHAR(64)  NOT NULL,
                driver      VARCHAR(64)  NOT NULL,
                metres      INT          NOT NULL DEFAULT 0,
                fare        INT          NOT NULL DEFAULT 0,
                paid        INT          NOT NULL DEFAULT 0,
                rating      TINYINT      NOT NULL DEFAULT 0,
                status      VARCHAR(16)  NOT NULL DEFAULT 'ended',
                called_at   BIGINT       NOT NULL DEFAULT 0,
                accepted_at BIGINT       NOT NULL DEFAULT 0,
                started_at  BIGINT       NOT NULL DEFAULT 0,
                ended_at    BIGINT       NOT NULL DEFAULT 0,
                INDEX idx_driver (driver),
                INDEX idx_client (client)
            )
        ]], {}, function()
            decideStore("sql")
        end)
    end)
    if not ok then
        decideStore("kvp", reason or "database_unavailable")
        return
    end
    -- Configured but silent: give it 15 s after the first player is in, then fall back.
    AddEventHandler("onPlayerReady", function()
        if store then return end
        SetTimeout(15000, function()
            if store then return end
            local ready, why = Open77.database.isReady()
            if not ready then decideStore("kvp", why or "database_not_answering") end
        end)
    end)
end

---------------------------------------------------------------------------------------------
-- Client relay (pins and GPS live on the client; the server only tells it what to draw)
---------------------------------------------------------------------------------------------

local function clientBlip(playerId, ride, position)
    TriggerClientEvent("rp_delamain:blip", playerId, ride.id, position, ("Delamain call #%d"):format(ride.id))
end

local function clientBlipRemove(playerId, rideId)
    TriggerClientEvent("rp_delamain:blipRemove", playerId, rideId)
end

local function clientWaypoint(playerId, position)
    TriggerClientEvent("rp_delamain:setWaypoint", playerId, position)
end

local function clientClearWaypoint(playerId)
    TriggerClientEvent("rp_delamain:clearWaypoint", playerId)
end

---------------------------------------------------------------------------------------------
-- Ride lifecycle
---------------------------------------------------------------------------------------------

local function activeRideOf(playerId)
    local id = rideOfPlayer[playerId]
    return id and rides[id] or nil
end

-- Pages every on-duty driver except the client (and `skipId`, a driver who just bailed).
-- Returns how many were paged, or nil, reason.
local function dispatch(ride, skipId)
    local drivers, reason = onDutyDrivers()
    if not drivers then return nil, reason end
    local clientPos = Open77.players.position(ride.clientId)
    local clientName = nameOf(ride.clientId)
    local paged = 0
    ride.paged = {}
    for _, driverId in ipairs(drivers) do
        driverId = tonumber(driverId)
        if driverId and driverId ~= ride.clientId and driverId ~= skipId and isConnected(driverId) and not activeRideOf(driverId) then
            local d = dist(clientPos, Open77.players.position(driverId))
            local where = ride.destination and (", destination " .. fmtDist(dist(clientPos, ride.destination)) .. " away") or ""
            say(driverId, ("Ride #%d: %s is calling a cab %s from you%s. /accepter %d to take it."):format(
                ride.id, clientName, fmtDist(d), where, ride.id))
            toast(driverId, "info", "Delamain dispatch",
                ("Ride #%d - %s away - /accepter %d"):format(ride.id, fmtDist(d), ride.id))
            if clientPos then clientBlip(driverId, ride, clientPos) end
            ride.paged[driverId] = true
            paged = paged + 1
        end
    end
    return paged
end

local function unpageOthers(ride, keepId)
    for driverId in pairs(ride.paged or {}) do
        if driverId ~= keepId and isConnected(driverId) then clientBlipRemove(driverId, ride.id) end
    end
    ride.paged = {}
end

local function closeRide(ride)
    rides[ride.id] = nil
    if rideOfPlayer[ride.clientId] == ride.id then rideOfPlayer[ride.clientId] = nil end
    if ride.driverId and rideOfPlayer[ride.driverId] == ride.id then rideOfPlayer[ride.driverId] = nil end
end

-- Creates a waiting ride for `clientId`. Never yields: callable from the export.
-- ---------------------------------------------------------------------------
-- Staging: a pose, a prop in the hand (or at the feet) and a progress bar for
-- every action that manipulates something, so nothing completes instantly and
-- everybody around sees it. Pattern of rp_nomade's carry pose: profiles tried
-- in order through Open77.animations.get, every native call inside pcall, a
-- refusal logged once and never fatal. RP animations are workspots: the
-- platform cancels one when the player moves more than 0.5 m, so the UI-kit bar
-- keeps the player still (disable.move, client side); the server never freezes
-- anyone. Everything comes from Config.Stage (shared/config.lua).
-- ---------------------------------------------------------------------------

local STAGE = RpDelamainConfig.Stage or {}
local STAGE_TAG = "[" .. GetCurrentResourceName() .. "]"
local stageWarned = {}          -- "<what>" -> true once logged
local stageResolved = {}        -- key -> { profile, clip } | false
local stageActive = {}          -- playerId -> { key, playbackId, props = { ids } } while staged

local function stageLog(fmt, ...)
    print((STAGE_TAG .. " " .. fmt):format(...))
end

local function stageWarnOnce(what, fmt, ...)
    if stageWarned[what] then return end
    stageWarned[what] = true
    stageLog(fmt, ...)
end

local function stageAnimationsApi()
    return type(Open77.animations) == "table" and type(Open77.animations.play) == "function"
end

local function stagePropsApi()
    return type(Open77.props) == "table" and type(Open77.props.attach) == "function"
end

-- First profile of `pose.profiles` the server's catalogue knows (memoised per key).
local function stageResolvePose(key, pose)
    if stageResolved[key] ~= nil then return stageResolved[key] or nil end
    local found = false
    if type(pose) == "table" and stageAnimationsApi() then
        for _, candidate in ipairs(pose.profiles or {}) do
            local ok, profile = pcall(Open77.animations.get, candidate.profile)
            if ok and type(profile) == "table" then
                local clip = candidate.clip
                if clip then
                    local known = false
                    for _, name in ipairs(profile.clips or {}) do
                        if name == clip then known = true break end
                    end
                    if not known then
                        stageLog("stage %s: clip %s is not in profile %s, using %s", key, clip, candidate.profile, tostring(profile.clip))
                        clip = nil
                    end
                end
                found = { profile = candidate.profile, clip = clip or profile.clip }
                break
            end
        end
    end
    stageResolved[key] = found
    if not found then
        local names = {}
        for _, candidate in ipairs(type(pose) == "table" and pose.profiles or {}) do names[#names + 1] = tostring(candidate.profile) end
        stageWarnOnce("pose:" .. key, "stage %s: no known profile among [%s], the action runs without a pose", key, table.concat(names, ", "))
    end
    return found or nil
end

local function stagePoseWord(key)
    local r = stageResolved[key]
    if not r then return "none" end
    return r.profile .. "/" .. tostring(r.clip)
end

-- Start a pose on a player. A `loop` pose runs until stagePoseStop; a one-shot uses
-- `durationMs` (the platform accepts 1 000..600 000 ms). Returns the playback id or nil.
local function stagePoseStart(playerId, key, pose, durationMs)
    if type(pose) ~= "table" then return nil end
    local resolved = stageResolvePose(key, pose)
    if not resolved then return nil end
    local options = {}
    if pose.loop == false then
        options.loop = false
        options.durationMs = math.floor(math.max(1000, math.min(600000, tonumber(durationMs) or tonumber(pose.durationMs) or 5000)))
    else
        options.loop = true
    end
    if resolved.clip then options.clip = resolved.clip end
    local ok, playback, reason = pcall(Open77.animations.play, playerId, resolved.profile, options)
    if ok and type(playback) == "table" and playback.playbackId then
        return playback.playbackId
    end
    if not ok then reason = playback end
    stageWarnOnce("play:" .. key .. ":" .. tostring(reason), "stage %s: pose %s refused for player %d: %s (the action runs without it)",
        key, resolved.profile, playerId, tostring(reason))
    return nil
end

local function stagePoseStop(playerId, playbackId)
    if not playbackId or not stageAnimationsApi() then return end
    local ok, stopped, why = pcall(Open77.animations.stop, playerId, playbackId)
    if ok and not stopped and why ~= "stale_playback" then
        stageLog("stage: pose stop refused for player %d: %s", playerId, tostring(why))
    end
end

-- Spawn a curated prop and make it follow the player (a hand slot, or the root frame:
-- +y where the player faces, +x their right, +z up, origin at the feet). Returns the
-- prop id and the model, or nil.
local function stagePropHold(playerId, key, prop)
    if type(prop) ~= "table" or not stagePropsApi() then return nil end
    local ok0, pos = pcall(Open77.players.position, playerId)
    if not ok0 or type(pos) ~= "table" or type(pos.x) ~= "number" then return nil end
    for _, model in ipairs(prop.models or {}) do
        local okC, id, reason = pcall(Open77.props.create, {
            model = model,
            position = { x = pos.x, y = pos.y, z = pos.z or 0.0 },
            yaw = 0.0,
            bucket = pos.bucket or 0,
        })
        if not okC then id, reason = nil, id end
        if id then
            local okA, attached, why = pcall(Open77.props.attach, id, {
                parentType = "player",
                parentId = playerId,
                bone = prop.bone or "",
                offset = prop.offset or { x = 0.0, y = 0.0, z = 0.0 },
                rotation = prop.rotation or { x = 0.0, y = 0.0, z = 0.0 },
            })
            if okA and attached then return id, model end
            if not okA then why = attached end
            pcall(Open77.props.remove, id)
            stageWarnOnce("attach:" .. key .. ":" .. model, "stage %s: attach of %s to player %d refused: %s (no prop shown)",
                key, model, playerId, tostring(why))
            return nil
        end
        stageWarnOnce("prop:" .. key .. ":" .. model, "stage %s: prop %s refused: %s", key, model, tostring(reason))
    end
    return nil
end

local function stagePropDrop(propId)
    if propId and stagePropsApi() then pcall(Open77.props.remove, propId) end
end

local function stageSlotWord(prop)
    if type(prop) ~= "table" then return "root" end
    return (prop.bone and prop.bone ~= "") and prop.bone or "root"
end

-- Everything a staged action put on a player is taken back.
local function stageFinish(playerId, entry)
    if not entry then return end
    if stageActive[playerId] == entry then stageActive[playerId] = nil end
    stagePoseStop(playerId, entry.playbackId)
    entry.playbackId = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
    entry.props = {}
end

-- Pose + props of `def` on a player, returned as an entry for stageFinish.
local function stageBegin(playerId, key, def, durationMs)
    local entry = { key = key, props = {}, words = {} }
    stageActive[playerId] = entry
    if STAGE.enabled == false or type(def) ~= "table" then return entry end
    entry.playbackId = stagePoseStart(playerId, key, def.pose, durationMs)
    if def.prop then
        local id, model = stagePropHold(playerId, key .. ".prop", def.prop)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.prop = model .. "@" .. stageSlotWord(def.prop)
        end
    end
    if def.place then
        local id, model = stagePropHold(playerId, key .. ".place", def.place)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.place = model
        end
    end
    return entry
end

-- The UI-kit bar (server twin). A plain wait keeps the beat when the kit is missing.
local function stageBar(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, definition)
    if not promise then
        if reason == "progress_active" or reason == "dialog_active" then return nil, reason end
        stageWarnOnce("uikit:" .. tostring(reason), "stage: uikit progress unavailable (%s), plain wait instead", tostring(reason))
        Wait(definition.duration)
        return { ok = true, outcome = "ok", fallback = true }
    end
    local answer, err = promise:await()
    if not answer then return nil, err end
    return answer
end

-- Run a staged action on `playerId`: pose + props + bar, then everything is cleaned up.
-- `key` names a Config.Stage entry; opts.label / opts.durationMs / opts.cancellable override
-- it. Returns the bar's answer ({ ok, outcome }) or nil, reason when the bar never showed.
-- Yields: capture `source` before calling.
local function stage(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 5000)
    local entry = stageBegin(playerId, key, def, durationMs)
    local answer, err = stageBar(playerId, {
        label = opts.label or def.label or key,
        duration = durationMs,
        position = "bottom",
        style = "bar",
        color = def.color or STAGE.color,
        cancellable = opts.cancellable ~= false,
        cancelKey = "X",
        disable = { move = true, combat = true },
    })
    stageFinish(playerId, entry)
    stageLog("player %d stage %s: pose=%s prop=%s place=%s %d ms -> %s", playerId, key, stagePoseWord(key),
        entry.words.prop or "none", entry.words.place or "none", durationMs,
        answer and (answer.ok and "ok" or tostring(answer.outcome or "cancelled")) or ("failed:" .. tostring(err)))
    return answer, err
end

-- A gesture without a bar (a hand-over, a wave, a sip): pose + props for `durationMs`,
-- taken back by a timer. Never yields. Returns the entry.
local function gesture(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 3000)
    local entry = stageBegin(playerId, key, def, durationMs)
    SetTimeout(durationMs, function() stageFinish(playerId, entry) end)
    stageLog("player %d gesture %s: pose=%s prop=%s %d ms", playerId, key, stagePoseWord(key), entry.words.prop or "none", durationMs)
    return entry
end

-- A pose held until stageRelease (a cuffed suspect, a patient on the ground). Never yields.
local function stageHold(playerId, key)
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local entry = stageBegin(playerId, key, def, nil)
    stageLog("player %d hold %s: pose=%s prop=%s", playerId, key, stagePoseWord(key), entry.words.prop or "none")
    return entry
end

local function stageRelease(playerId, entry)
    stageFinish(playerId, entry or stageActive[playerId])
end

-- Disconnect: the pose died with the player, the props must not survive them.
local function stageClear(playerId)
    local entry = stageActive[playerId]
    if not entry then return end
    stageActive[playerId] = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
end

local function createRide(clientId, destination)
    if not isConnected(clientId) then return nil, "player_not_found" end
    local current = activeRideOf(clientId)
    if current then return nil, "already_in_ride" end
    if destination ~= nil then
        destination = validPoint(destination)
        if not destination then return nil, "invalid_destination" end
    end
    local drivers, why = onDutyDrivers()
    if not drivers then return nil, why end
    local available = 0
    for _, driverId in ipairs(drivers) do
        driverId = tonumber(driverId)
        if driverId and driverId ~= clientId and isConnected(driverId) and not activeRideOf(driverId) then
            available = available + 1
        end
    end
    if available == 0 then return nil, "no_driver" end

    local ride = {
        id = nextRideId, clientId = clientId, driverId = nil, phase = "waiting",
        destination = destination, calledAt = Open77.time.unix(), metres = 0,
        seated = false, boarded = false, paged = {},
        clientIdentifier = Open77.players.identifier(clientId) or "",
    }
    nextRideId = nextRideId + 1
    rides[ride.id] = ride
    rideOfPlayer[clientId] = ride.id
    local paged = dispatch(ride) or 0
    gesture(clientId, "call")
    log("ride %d called by player %d (%s) drivers_paged=%d destination=%s", ride.id, clientId,
        ride.clientIdentifier, paged, destination and ("%.0f,%.0f,%.0f"):format(destination.x, destination.y, destination.z) or "none")
    emit(ride, "waiting")
    return ride.id
end

local function cancelRide(ride, byWhom, textClient, textDriver)
    ride.lastPhase = ride.phase
    ride.phase = "cancelled"
    ride.endedAt = Open77.time.unix()
    unpageOthers(ride, nil)
    if ride.driverId and isConnected(ride.driverId) then
        clientClearWaypoint(ride.driverId)
        clientBlipRemove(ride.driverId, ride.id)
        if textDriver then say(ride.driverId, textDriver) end
    end
    if isConnected(ride.clientId) and textClient then say(ride.clientId, textClient) end
    if ride.boarded or ride.metres > 0 then
        ride.fare = fareFor(ride.metres)
        ride.paid = 0
        persistRide(ride, "cancelled")
    end
    log("ride %d cancelled by %s phase_was=%s metres=%d", ride.id, byWhom, ride.lastPhase, math.floor(ride.metres))
    closeRide(ride)
    emit(ride, "cancelled")
end

-- The ride goes back to the dispatch board (driver bailed or vanished before the pickup).
-- A driver who bailed on purpose is not paged again for this call.
local function redispatch(ride, why)
    local oldDriver = ride.driverId
    if oldDriver and rideOfPlayer[oldDriver] == ride.id then rideOfPlayer[oldDriver] = nil end
    if oldDriver and isConnected(oldDriver) then clientClearWaypoint(oldDriver) end
    ride.driverId, ride.driverIdentifier, ride.acceptedAt = nil, nil, nil
    ride.phase = "waiting"
    ride.calledAt = Open77.time.unix()
    local paged = dispatch(ride, (why == "driver_cancelled" or why == "driver_off_duty") and oldDriver or nil) or 0
    log("ride %d back on the board (%s) drivers_paged=%d", ride.id, why, paged)
    if paged == 0 then
        cancelRide(ride, why, "Your driver is gone and no other Delamain driver is on duty. Type /taxi for the automated cab (short trips only).", nil)
        return
    end
    say(ride.clientId, ("Your driver bailed. Delamain dispatch: looking for another driver... (%d paged)"):format(paged))
    emit(ride, "waiting")
end

local function acceptRide(ride, driverId)
    ride.driverId = driverId
    ride.driverIdentifier = Open77.players.identifier(driverId) or ""
    ride.acceptedAt = Open77.time.unix()
    ride.phase = "accepted"
    rideOfPlayer[driverId] = ride.id
    unpageOthers(ride, driverId)
    clientBlipRemove(driverId, ride.id)
    loadDriverStats(ride.driverIdentifier)

    local clientPos = Open77.players.position(ride.clientId)
    local driverPos = Open77.players.position(driverId)
    local d = dist(clientPos, driverPos)
    local driverName, clientName = nameOf(driverId), nameOf(ride.clientId)

    say(ride.clientId, ("Driver %s took your call, %s away. Wait for the cab; /course for the status."):format(driverName, fmtDist(d)))
    toast(ride.clientId, "success", "Delamain", ("%s is on the way (%s)"):format(driverName, fmtDist(d)))

    local destText = "No destination pinned: ask your passenger where to."
    if ride.destination then
        destText = ("Destination pinned %s from the pickup."):format(fmtDist(dist(clientPos, ride.destination)))
    end
    say(driverId, ("You took ride #%d. GPS set to %s (%s). %s Let them in, drive, and /fin once they got out."):format(
        ride.id, clientName, fmtDist(d), destText))
    if clientPos then
        clientWaypoint(driverId, clientPos)
        ride.lastWaypoint = clientPos
    end
    log("ride %d accepted by player %d (%s) distance=%s", ride.id, driverId, ride.driverIdentifier, fmtDist(d))
    gesture(driverId, "accept")
    emit(ride, "accepted")
end

local function startRiding(ride, vehicleId)
    ride.phase = "riding"
    ride.startedAt = Open77.time.unix()
    ride.vehicleId = vehicleId
    ride.boarded = true
    ride.seated = true
    ride.lastPos = Open77.vehicles.getPosition(vehicleId) or Open77.players.position(ride.clientId)
    local meterText = ("Meter running: %s base + %s per 100 m."):format(fmtMoney(Config.BaseFare), fmtMoney(Config.PerHundredMetres))
    say(ride.clientId, meterText .. " Get out at your destination and the ride settles itself.")
    if ride.destination then
        clientWaypoint(ride.driverId, ride.destination)
        say(ride.driverId, ("Passenger on board. GPS set to their destination (%s). %s"):format(
            fmtDist(dist(ride.lastPos, ride.destination)), meterText))
    else
        clientClearWaypoint(ride.driverId)
        say(ride.driverId, "Passenger on board, no destination pinned: ask them where to. " .. meterText)
    end
    log("ride %d riding vehicle=%s", ride.id, tostring(vehicleId))
    emit(ride, "riding")
end

local function settleRide(ride, how)
    ride.phase = "ended"
    ride.endedAt = Open77.time.unix()
    local metres = math.floor(ride.metres + 0.5)
    local fare = fareFor(ride.metres)
    ride.fare = fare
    ride.paid = 0
    local driverName, clientName = nameOf(ride.driverId), nameOf(ride.clientId)

    local balance, why = takeCash(ride.clientId, fare, ("delamain:ride:%d"):format(ride.id))
    if balance then
        ride.paid = fare
        local driverShare = math.floor(fare * Config.DriverShare)
        local commission = fare - driverShare
        local got, why2 = giveCash(ride.driverId, driverShare, ("delamain:fare:%d"):format(ride.id))
        if not got then
            -- The client paid, the driver cannot be credited: refund the client rather than lose the eddies.
            log("ride %d driver credit failed (%s): refunding client", ride.id, tostring(why2))
            giveCash(ride.clientId, fare, ("delamain:refund:%d"):format(ride.id))
            ride.paid = 0
            say(ride.driverId, ("Ride #%d done (%s) but the wallet service refused your cut: %s. The fare was refunded."):format(ride.id, fmtDist(metres), tostring(why2)))
            say(ride.clientId, ("Ride #%d over: %s. Payment failed on Delamain's side, nothing charged."):format(ride.id, fmtDist(metres)))
        else
            local soc, why3 = societyAdd(commission, ("ride:%d"):format(ride.id))
            if not soc then log("ride %d society commission %d not banked: %s", ride.id, commission, tostring(why3)) end
            say(ride.clientId, ("Ride #%d over: %s, %s paid. Cash left: %s. Rate %s with /note <1-5>."):format(
                ride.id, fmtDist(metres), fmtMoney(fare), fmtMoney(balance), driverName))
            toast(ride.clientId, "success", "Delamain", ("Ride #%d: %s - %s"):format(ride.id, fmtDist(metres), fmtMoney(fare)))
            say(ride.driverId, ("Ride #%d done: %s, fare %s, your cut %s (Delamain keeps %s). Cash: %s."):format(
                ride.id, fmtDist(metres), fmtMoney(fare), fmtMoney(driverShare), fmtMoney(commission), fmtMoney(got)))
            toast(ride.driverId, "success", "Delamain", ("Ride #%d: +%s"):format(ride.id, fmtMoney(driverShare)))
        end
    else
        say(ride.clientId, ("Ride #%d over: %s for %s - and you're short on eddies. Delamain logged the debt, choom."):format(
            ride.id, fmtDist(metres), fmtMoney(fare)))
        local whyText = (why == "insufficient_funds") and "not enough cash" or ("wallet: " .. tostring(why))
        say(ride.driverId, ("Ride #%d done: %s, fare %s, but %s couldn't pay (%s). Ride logged unpaid, no cut this time."):format(
            ride.id, fmtDist(metres), fmtMoney(fare), clientName, whyText))
        toast(ride.driverId, "warning", "Delamain", ("Ride #%d unpaid (%s)"):format(ride.id, fmtMoney(fare)))
    end

    local s = statsFor(ride.driverIdentifier)
    s.rides = s.rides + 1
    if store == "kvp" then saveStatsKvp(ride.driverIdentifier) end
    persistRide(ride, "ended")
    clientClearWaypoint(ride.driverId)
    lastRideOf[ride.clientId] = ride
    log("ride %d ended (%s) metres=%d fare=%d paid=%d driver=%s client=%s", ride.id, how, metres, fare, ride.paid,
        ride.driverIdentifier, ride.clientIdentifier)
    closeRide(ride)
    emit(ride, "ended")
end

---------------------------------------------------------------------------------------------
-- The meter: one thread, one sample every Config.SampleMs for every active ride
---------------------------------------------------------------------------------------------

local function seatedTogether(ride)
    local clientSeat = Open77.vehicles.getPlayerSeat(ride.clientId)
    if not clientSeat then return false end
    local driverSeat = Open77.vehicles.getPlayerSeat(ride.driverId)
    if not driverSeat or not isDriverSeat(driverSeat.seat) then return false end
    if tostring(clientSeat.vehicleId) ~= tostring(driverSeat.vehicleId) then return false end
    return true, driverSeat.vehicleId
end

local function tick(ride, now)
    if ride.phase == "waiting" then
        if now - ride.calledAt > Config.WaitTimeoutSec then
            cancelRide(ride, "timeout",
                "No driver picked up your call. Try /delamain again later, or /taxi for the automated cab.", nil)
        end
        return
    end

    if not isConnected(ride.driverId) then
        if ride.phase == "riding" then
            cancelRide(ride, "driver_lost", "Your driver dropped off the Net. Ride cancelled, nothing charged.", nil)
        else
            redispatch(ride, "driver_lost")
        end
        return
    end
    if not isConnected(ride.clientId) then
        cancelRide(ride, "client_lost", nil,
            ("Your passenger dropped off the Net after %s. Ride logged, nothing paid."):format(fmtDist(ride.metres)))
        return
    end

    if ride.phase == "accepted" then
        local together, vehicleId = seatedTogether(ride)
        if together then
            startRiding(ride, vehicleId)
            return
        end
        -- The GPS follows the waiting client when they wander off.
        local clientPos = Open77.players.position(ride.clientId)
        if clientPos and (not ride.lastWaypoint or (dist(clientPos, ride.lastWaypoint) or 0) >= Config.WaypointRefreshM) then
            clientWaypoint(ride.driverId, clientPos)
            ride.lastWaypoint = clientPos
        end
        if now - ride.acceptedAt > Config.PickupTimeoutSec then
            cancelRide(ride, "pickup_timeout",
                "The pickup timed out. Call again with /delamain.",
                ("Ride #%d timed out: the passenger never got in."):format(ride.id))
        end
        return
    end

    if ride.phase == "riding" then
        local together, vehicleId = seatedTogether(ride)
        if together then
            ride.vehicleId = vehicleId
            local pos = Open77.vehicles.getPosition(ride.vehicleId) or Open77.players.position(ride.clientId)
            if ride.seated and pos and ride.lastPos then
                local step = dist(pos, ride.lastPos) or 0
                -- A teleport or a bad sample is not a fare: cap one sample at 120 m (216 km/h over 2 s).
                if step <= 120 then ride.metres = ride.metres + step end
            end
            ride.lastPos = pos
            ride.seated = true
        else
            if ride.seated then
                ride.seated = false
                log("ride %d passenger out of the cab at %d m", ride.id, math.floor(ride.metres))
            end
            if ride.metres >= Config.AutoEndMetres then
                settleRide(ride, "auto")
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.SampleMs)
        local now = Open77.time.unix()
        for _, ride in pairs(rides) do
            local ok, err = pcall(tick, ride, now)
            if not ok then log("tick error on ride %d: %s", ride.id, tostring(err)) end
        end
    end
end)

-- Immediate reaction when the passenger steps out (the 2 s poll is the safety net). A seat
-- switch raises `left` too, so the ledger is re-read after a short pause before settling.
AddEventHandler("onPlayerLeftVehicle", function(playerId)
    playerId = tonumber(playerId)
    local ride = activeRideOf(playerId)
    if not ride or ride.phase ~= "riding" or playerId ~= ride.clientId then return end
    local rideId = ride.id
    Wait(750)
    ride = rides[rideId]
    if not ride or ride.phase ~= "riding" or seatedTogether(ride) then return end
    ride.seated = false
    if ride.metres >= Config.AutoEndMetres then
        settleRide(ride, "auto")
    end
end)

---------------------------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------------------------

local function requireGame(source)
    if source == 0 then
        print(("[%s] run this from the game, not the console"):format(RESOURCE_NAME))
        return false
    end
    return true
end

local REASON_TEXT = {
    no_driver           = "No Delamain driver on duty. Type /taxi for the automated cab (short trips only).",
    jobs_offline        = "Delamain dispatch is offline (rp_jobs is not running). Type /taxi for the automated cab.",
    already_in_ride     = "You already have a Delamain ride. /course to see it, /delamain annuler to drop it.",
    player_not_found    = "Unknown player.",
    invalid_destination = "That destination is off the map.",
}

RegisterCommand("delamain", function(source, args)
    if not requireGame(source) then return end
    local sub = (args[1] or ""):lower()

    if sub == "annuler" or sub == "cancel" then
        local ride = activeRideOf(source)
        if not ride then return say(source, "No Delamain ride to cancel.") end
        if source == ride.clientId then
            if ride.phase == "riding" then
                return say(source, "You're already rolling. Get out of the cab to end the ride.")
            end
            cancelRide(ride, "client", "Call cancelled.",
                ("Ride #%d: %s cancelled the call."):format(ride.id, nameOf(source)))
        else
            if ride.phase == "riding" then
                return say(source, "Your passenger is on board. Let them out and /fin to end the ride.")
            end
            say(source, ("You dropped ride #%d."):format(ride.id))
            redispatch(ride, "driver_cancelled")
        end
        return
    end

    -- `/delamain <preset>`: a configured drop-off (Config.Presets) instead of the map waypoint.
    local preset
    if sub ~= "" then
        for _, p in ipairs(Config.Presets or {}) do
            if p.id == sub then preset = p break end
        end
        if not preset then
            local ids = {}
            for _, p in ipairs(Config.Presets or {}) do ids[#ids + 1] = p.id end
            return say(source, ("Usage: /delamain (call a driver, your map waypoint is the destination), /delamain <%s> or /delamain annuler."):format(
                table.concat(ids, "|")))
        end
    end

    local existing = activeRideOf(source)
    if existing then return say(source, REASON_TEXT.already_in_ride) end

    local rideId, reason = createRide(source, preset and preset.position or nil)
    if not rideId then
        return say(source, REASON_TEXT[reason] or ("Delamain could not take your call: " .. tostring(reason)))
    end
    local ride = rides[rideId]
    local paged = 0
    for _ in pairs(ride.paged) do paged = paged + 1 end
    say(source, ("Delamain dispatch: looking for a driver... (ride #%d, %d driver%s paged). /delamain annuler to cancel."):format(
        rideId, paged, paged == 1 and "" or "s"))
    if preset then
        say(source, ("Destination: %s."):format(preset.label))
        return
    end
    -- The caller's map waypoint becomes the destination when the client answers.
    ride.askedWaypoint = true
    TriggerClientEvent("rp_delamain:askWaypoint", source, rideId)
end, false)

RegisterCommand("accepter", function(source, args)
    if not requireGame(source) then return end
    local okDriver, why = isOnDutyDriver(source)
    if not okDriver then
        if why == "off_duty" then return say(source, "Clock in first: /service.") end
        return say(source, "You don't drive for Delamain, choom. /agence to sign up.")
    end
    if activeRideOf(source) then
        return say(source, "You already have a ride. /course to see it, /fin or /delamain annuler to close it.")
    end
    local rideId = tonumber(args[1])
    if args[1] ~= nil and (not rideId or rideId % 1 ~= 0 or rideId < 1) then
        return say(source, "Usage: /accepter <rideId> (the number from the dispatch line).")
    end
    if rideId then rideId = math.floor(rideId) end
    if not rideId then
        -- No id: take the oldest waiting call.
        local oldest
        for _, ride in pairs(rides) do
            if ride.phase == "waiting" and ride.clientId ~= source and (not oldest or ride.calledAt < oldest.calledAt) then
                oldest = ride
            end
        end
        if not oldest then return say(source, "No call waiting. Usage: /accepter <rideId>.") end
        rideId = oldest.id
    end
    local ride = rides[rideId]
    if not ride then return say(source, ("Ride #%d is gone (taken, cancelled or unknown)."):format(rideId)) end
    if ride.phase ~= "waiting" then return say(source, ("Ride #%d was already taken by %s."):format(rideId, nameOf(ride.driverId))) end
    if ride.clientId == source then return say(source, "You can't drive yourself, choom.") end
    acceptRide(ride, source)
end, false)

RegisterCommand("course", function(source)
    if not requireGame(source) then return end
    local ride = activeRideOf(source)
    local isDriver = isOnDutyDriver(source)

    local function driverStatsLine()
        local identifier = Open77.players.identifier(source) or ""
        loadDriverStats(identifier, function(s)
            local avg = s.ratingCount > 0 and ("%.1f/5 over %d rating%s"):format(s.ratingSum / s.ratingCount, s.ratingCount, s.ratingCount == 1 and "" or "s") or "no rating yet"
            say(source, ("Your Delamain record: %d ride%s, %s."):format(s.rides, s.rides == 1 and "" or "s", avg))
        end)
    end

    if not ride then
        if isDriver then
            local waiting = 0
            for _, r in pairs(rides) do if r.phase == "waiting" then waiting = waiting + 1 end end
            say(source, ("No ride in progress. %d call%s waiting on the board."):format(waiting, waiting == 1 and "" or "s"))
            driverStatsLine()
        else
            say(source, "No Delamain ride in progress. /delamain to call one.")
        end
        return
    end

    local me, other = source, (source == ride.clientId) and ride.driverId or ride.clientId
    local d = other and dist(Open77.players.position(me), Open77.players.position(other)) or nil
    local sofar = ("%s so far, fare %s"):format(fmtDist(ride.metres), fmtMoney(fareFor(ride.metres)))
    if source == ride.clientId then
        if ride.phase == "waiting" then
            say(source, ("Ride #%d: waiting for a driver. /delamain annuler to cancel."):format(ride.id))
        elseif ride.phase == "accepted" then
            say(source, ("Ride #%d: %s is on the way, %s away."):format(ride.id, nameOf(other), fmtDist(d)))
        else
            say(source, ("Ride #%d: rolling with %s, %s. Get out at your destination to settle."):format(ride.id, nameOf(other), sofar))
        end
    else
        if ride.phase == "accepted" then
            say(source, ("Ride #%d: pick up %s, %s away. /fin is only for after the ride."):format(ride.id, nameOf(other), fmtDist(d)))
        else
            say(source, ("Ride #%d: %s on board, %s%s. /fin once they got out."):format(ride.id, nameOf(other), sofar,
                ride.seated and "" or " (passenger currently out of the cab)"))
        end
        driverStatsLine()
    end
end, false)

RegisterCommand("fin", function(source)
    if not requireGame(source) then return end
    local ride = activeRideOf(source)
    if not ride or ride.driverId ~= source then
        return say(source, "You're not driving a Delamain ride. /course for your status.")
    end
    if ride.phase == "accepted" then
        return say(source, "Your passenger never got in. /delamain annuler to drop the call instead.")
    end
    local together = seatedTogether(ride)
    if together then
        return say(source, "Your passenger is still in the cab. Let them out first, then /fin.")
    end
    settleRide(ride, "driver")
end, false)

RegisterCommand("note", function(source, args)
    if not requireGame(source) then return end
    local stars = tonumber(args[1])
    if not stars or stars % 1 ~= 0 or stars < 1 or stars > 5 then
        return say(source, "Usage: /note <1-5>")
    end
    local ride = lastRideOf[source]
    if not ride then return say(source, "No Delamain ride to rate.") end
    if Open77.time.unix() - ride.endedAt > Config.RatingWindowSec then
        lastRideOf[source] = nil
        return say(source, "Too late to rate that ride.")
    end
    if ride.rating and ride.rating > 0 then return say(source, "You already rated that ride.") end
    ride.rating = stars
    local s = statsFor(ride.driverIdentifier)
    s.ratingSum = s.ratingSum + stars
    s.ratingCount = s.ratingCount + 1
    persistRating(ride)
    say(source, ("Thanks, choom: %d/5 for %s."):format(stars, nameOf(ride.driverId)))
    if isConnected(ride.driverId) then
        say(ride.driverId, ("%s rated ride #%d %d/5."):format(nameOf(source), ride.id, stars))
    end
    log("ride %d rated %d by %s", ride.id, stars, ride.clientIdentifier)
end, false)

---------------------------------------------------------------------------------------------
-- Net events from the client half
---------------------------------------------------------------------------------------------

-- The caller's client answers the waypoint question: `position` is a table or false.
RegisterNetEvent("rp_delamain:waypoint", function(rideId, position)
    local playerId = source
    if type(playerId) ~= "number" then return end
    local ride = rides[tonumber(rideId) or -1]
    if not ride or ride.clientId ~= playerId or not ride.askedWaypoint then return end
    ride.askedWaypoint = false
    if position == false or position == nil then
        say(playerId, "No waypoint on your map: the driver will ask where to. (Pin one before calling next time.)")
        return
    end
    local point = validPoint(position)
    if not point then return say(playerId, "Your map waypoint could not be read. The driver will ask where to.") end
    ride.destination = point
    local from = Open77.players.position(playerId)
    say(playerId, ("Destination taken from your map waypoint (%s away)."):format(fmtDist(dist(from, point))))
    if ride.phase == "accepted" and isConnected(ride.driverId) then
        say(ride.driverId, ("Ride #%d: destination pinned, %s from the pickup."):format(ride.id, fmtDist(dist(from, point))))
    elseif ride.phase == "waiting" then
        for driverId in pairs(ride.paged or {}) do
            if isConnected(driverId) then
                say(driverId, ("Ride #%d: destination is %s from the pickup."):format(ride.id, fmtDist(dist(from, point))))
            end
        end
    end
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then
        local ok, reason = Open77.chat.addSuggestions(source, SUGGESTIONS)
        if not ok then log("chat suggestions for %d not published: %s", source, tostring(reason)) end
    end
end)

---------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log("started: base fare %d, %d per 100 m, driver share %d%%, auto-end at %d m, sample every %d ms",
        Config.BaseFare, Config.PerHundredMetres, math.floor(Config.DriverShare * 100 + 0.5), Config.AutoEndMetres, Config.SampleMs)
    setupDatabase()
    local ok, reason = Open77.chat.addSuggestions(-1, SUGGESTIONS)
    if not ok then log("chat suggestions not published: %s", tostring(reason)) end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    lastRideOf[playerId] = nil
    local ride = activeRideOf(playerId)
    if not ride then return end
    if playerId == ride.clientId then
        cancelRide(ride, "client_disconnected", nil,
            ("Ride #%d: your passenger dropped off the Net after %s. Ride logged, nothing paid."):format(ride.id, fmtDist(ride.metres)))
    elseif ride.phase == "riding" then
        cancelRide(ride, "driver_disconnected", "Your driver dropped off the Net. Ride cancelled, nothing charged.", nil)
    else
        redispatch(ride, "driver_disconnected")
    end
end)

-- A driver clocking out (or losing the job) mid-call hands the call back to the board.
AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    playerId = tonumber(playerId)
    if not playerId or onDuty then return end
    local ride = activeRideOf(playerId)
    if not ride or ride.driverId ~= playerId then return end
    if ride.phase == "riding" then
        say(playerId, ("You clocked out mid-ride: ride #%d settles now."):format(ride.id))
        settleRide(ride, "driver_off_duty")
    else
        say(playerId, ("You clocked out: ride #%d goes back to the board."):format(ride.id))
        redispatch(ride, "driver_off_duty")
    end
end)

---------------------------------------------------------------------------------------------
-- Exports (synchronous, never yield)
---------------------------------------------------------------------------------------------

-- call(playerId, destination|nil) -> rideId | nil, reason
-- reasons: invalid_player_id, player_not_found, already_in_ride, no_driver, jobs_offline, invalid_destination
exports("call", function(playerId, destination)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 or playerId % 1 ~= 0 then return nil, "invalid_player_id" end
    local rideId, reason = createRide(playerId, destination)
    if not rideId then return nil, reason end
    local ride = rides[rideId]
    local paged = 0
    for _ in pairs(ride.paged) do paged = paged + 1 end
    say(playerId, ("Delamain dispatch: looking for a driver... (ride #%d, %d driver%s paged)."):format(rideId, paged, paged == 1 and "" or "s"))
    return rideId
end)

-- activeRide(playerId) -> { id, phase, clientId, driverId, metres, fare, destination, calledAt, acceptedAt, startedAt } | nil
exports("activeRide", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return nil end
    local ride = activeRideOf(playerId)
    if not ride then return nil end
    return {
        id = ride.id, phase = ride.phase, clientId = ride.clientId, driverId = ride.driverId,
        metres = math.floor(ride.metres + 0.5), fare = fareFor(ride.metres),
        destination = ride.destination and { x = ride.destination.x, y = ride.destination.y, z = ride.destination.z } or nil,
        calledAt = ride.calledAt, acceptedAt = ride.acceptedAt, startedAt = ride.startedAt,
        seated = ride.seated,
    }
end)
