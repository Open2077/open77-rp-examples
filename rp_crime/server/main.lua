-- rp_crime -- shop robberies, vehicle theft, street deals, contraband and a night fence.
-- Server-authoritative: every distance, item, eddie, cooldown and alert is decided here.
-- The player only sees chat lines, toasts, a UI-kit progress bar and, on the fence NPC,
-- one E prompt that the server declares through open77_interactions.
--
-- Every sibling export is called inside pcall: a missing resource degrades to a chat line.

local Config = RpCrimeConfig
local RESOURCE = GetCurrentResourceName()
local TAG = "[rp_crime]"

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------

local function log(fmt, ...)
    print(TAG .. " " .. fmt:format(...))
end

-- Optional rp_config override: rp_crime.<path>. Falls back to the shared config value.
local function tunable(path, default)
    local ok, value = pcall(function() return exports.rp_config:get(Config.configPrefix .. path, nil) end)
    if ok and value ~= nil and type(value) == type(default) then return value end
    return default
end

local function say(playerId, text, color)
    playerId = tonumber(playerId)
    if not playerId then return end
    local ok, reason = Open77.chat.send(playerId, {
        type = "system",
        author = Config.chat.author,
        text = text,
        color = color or Config.chat.color,
    })
    if not ok then log("chat refused for %s: %s", tostring(playerId), tostring(reason)) end
end

local function toast(playerId, kind, title, message)
    playerId = tonumber(playerId)
    if not playerId then return end
    Open77.notifications.send(playerId, {
        type = kind or "info",
        title = title,
        message = message,
        durationMs = 6000,
    })
end

local function nameOf(playerId)
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return Open77.players.name(playerId) or ("#" .. tostring(playerId))
end

local function identifierOf(playerId)
    return Open77.players.identifier(playerId) or ("session:" .. tostring(playerId))
end

local function positionOf(playerId)
    local pos = Open77.players.position(playerId)
    if not pos or type(pos.x) ~= "number" then return nil end
    return { x = pos.x, y = pos.y, z = pos.z or 0.0, bucket = pos.bucket }
end

local function planar(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function distance3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Reach test with a height tolerance: the configured z values are the walked floor height,
-- a body standing on a kerb must still count as "at the counter".
local function within(pos, target, reach)
    if not pos or not target then return false, 999 end
    local d = planar(pos, target)
    if math.abs((pos.z or 0.0) - (target.z or 0.0)) > 4.0 then return false, d end
    return d <= reach, d
end

local function copyPos(pos)
    return { x = pos.x, y = pos.y, z = pos.z or 0.0 }
end

-- A living body, on foot. Answers ok, reason.
local function canAct(playerId)
    local dead = Open77.players.isDead(playerId)
    if dead == nil then return false, "The server cannot see your body yet. Try again in a second." end
    if dead then return false, "You are in no state for that, choom." end
    if Open77.vehicles.getPlayerSeat(playerId) then return false, "Get out of the ride first." end
    return true
end

-- UI-kit progress bar (server twin). Returns true (ran to the end), false, "cancelled"
-- (the player pressed X / Escape) or nil, reason (the bar never showed).
local function progress(playerId, label, durationMs)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, {
        label = label,
        duration = durationMs,
        position = "bottom",
        style = "bar",
        color = "#FF6040",
        cancellable = true,
        cancelKey = "X",
        disable = { move = true, combat = true },
    })
    if not promise then return nil, reason end
    local answer, err = promise:await()
    if answer == nil then return nil, err end
    if not answer.ok then return false, answer.outcome or "cancelled" end
    return true
end

-- Every NCPD officer on duty right now (rp_ncpd:isOnDuty = job ncpd AND rp_jobs onDuty).
local function officersOnDuty()
    local list = {}
    for _, pid in ipairs(Open77.players.all()) do
        local ok, onDuty = pcall(function() return exports.rp_ncpd:isOnDuty(pid) end)
        if ok and onDuty == true then list[#list + 1] = pid end
    end
    return list
end

-- Page the police: rp_ncpd consumes this on the host bus (chat line + toast + map pin).
local function pageNcpd(kind, position, text, byPlayerId)
    local ok, reason = TriggerEvent("rp_ncpd:alert", kind, copyPos(position), text, byPlayerId)
    if not ok then log("rp_ncpd:alert refused: %s", tostring(reason)) end
end

-- The contract event of this resource: rp_crime:robbery (kind, position, byPlayerId).
local function announceCrime(kind, position, byPlayerId)
    local ok, reason = TriggerEvent("rp_crime:robbery", kind, copyPos(position), byPlayerId)
    if not ok then log("rp_crime:robbery refused: %s", tostring(reason)) end
end

-- A readable vehicle label from a record, with the catalogue's help when it knows it.
local function vehicleLabel(record, fallback)
    if fallback and fallback ~= "" then return fallback end
    if type(record) ~= "string" then return "a ride" end
    local info = Open77.data.vehicle(record)
    if type(info) == "table" then
        local label = info.displayName or info.label or info.name
        if type(label) == "string" and label ~= "" then return label end
    end
    local short = record:gsub("^Vehicle%.v_", ""):gsub("_player$", "")
    short = short:gsub("^[a-z]+%d*_", "")
    return (short:gsub("_", " "))
end

-- One crime at a time per player (a bar is running).
local busy = {}

-- ---------------------------------------------------------------------------------------------
-- Persistence: rp_crime_log in SQL, kvp when the server has no database
-- ---------------------------------------------------------------------------------------------

local store = { mode = nil, reason = nil }
local pendingRows = {}

local function writeRow(row)
    if store.mode == "sql" then
        Open77.database.insert(
            "INSERT INTO " .. Config.database.table ..
            " (identifier, player_name, kind, target, amount, `at`) VALUES (?, ?, ?, ?, ?, ?)",
            { row.identifier, row.name, row.kind, row.target, row.amount, row.at },
            function(id)
                if not id then log("sql insert refused for kind=%s identifier=%s", row.kind, row.identifier) end
            end)
    elseif store.mode == "kvp" then
        local seq = (tonumber(Open77.kvp.get("log:seq", 0)) or 0) + 1
        Open77.kvp.set("log:seq", seq)
        Open77.kvp.set(("log:%08d"):format(seq), json.encode(row) or "{}")
        local old = seq - Config.database.kvpKeep
        if old > 0 then Open77.kvp.delete(("log:%08d"):format(old)) end
    else
        pendingRows[#pendingRows + 1] = row
    end
end

local function flushPending()
    local rows = pendingRows
    pendingRows = {}
    for _, row in ipairs(rows) do writeRow(row) end
end

-- Every crime is one row and one grep-able log line.
local function logCrime(playerId, kind, target, amount)
    local identifier = identifierOf(playerId)
    local row = {
        identifier = identifier,
        name = nameOf(playerId),
        kind = kind,
        target = tostring(target or ""),
        amount = math.floor(tonumber(amount) or 0),
        at = math.floor(Open77.time.unix()),
    }
    log("%s player %s (%s) target=%s amount=%d", kind, tostring(playerId), identifier, row.target, row.amount)
    writeRow(row)
end

local function chooseStore()
    local ok, reason = Open77.database.ready(function()
        local created = Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS ]] .. Config.database.table .. [[ (
                id          INT AUTO_INCREMENT PRIMARY KEY,
                identifier  VARCHAR(64)  NOT NULL,
                player_name VARCHAR(80)  NOT NULL DEFAULT '',
                kind        VARCHAR(24)  NOT NULL,
                target      VARCHAR(64)  NOT NULL DEFAULT '',
                amount      INT          NOT NULL DEFAULT 0,
                `at`        BIGINT       NOT NULL,
                INDEX idx_rp_crime_identifier (identifier),
                INDEX idx_rp_crime_kind (kind)
            )
        ]])
        if created == nil then
            log("CREATE TABLE %s answered nothing; the rows will be tried anyway", Config.database.table)
        end
        if store.mode == "kvp" then
            log("database answered late: new rows go to SQL, the kvp rows stay where they are")
        end
        store.mode = "sql"
        log("store=sql table=%s", Config.database.table)
        flushPending()
    end)
    if not ok then
        store.mode = "kvp"
        store.reason = reason
        log("store=kvp reason=%s (no database: crimes are kept in the resource kvp store)", tostring(reason))
        flushPending()
        return
    end
    SetTimeout(Config.database.graceMs, function()
        if store.mode == nil then
            store.mode = "kvp"
            store.reason = "database_not_answering"
            log("store=kvp reason=database_not_answering after %d ms", Config.database.graceMs)
            flushPending()
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Items (stolen_parts) declared in rp_inventory
-- ---------------------------------------------------------------------------------------------

local function defineItems()
    local ok, registered, rejected = pcall(function() return exports.rp_inventory:define(Config.items) end)
    if not ok then
        log("rp_inventory:define refused: %s", tostring(registered))
        return
    end
    local function count(v)
        if type(v) == "table" then return #v end
        return tonumber(v) or 0
    end
    log("items defined in rp_inventory: registered=%d rejected=%d", count(registered), count(rejected))
end

-- ---------------------------------------------------------------------------------------------
-- Wanted vehicles (export + NCPD spotting tick)
-- ---------------------------------------------------------------------------------------------

-- vehicleId (number) -> { plate = "NC-XXXX" | nil, label, record, since, by }
local wanted = {}

local function registerWanted(vehicleId, plate, record, label, byPlayerId)
    wanted[vehicleId] = {
        plate = plate,
        record = record,
        label = vehicleLabel(record, label),
        since = Open77.time.unix(),
        by = byPlayerId,
    }
end

local function forgetWantedPlate(plate)
    if type(plate) ~= "string" then return end
    for vehicleId, info in pairs(wanted) do
        if info.plate == plate then wanted[vehicleId] = nil end
    end
end

-- rp_garage persists the flag on its own rows: rebuild the in-world half from what it knows.
local function importWanted(playerId)
    local ok, list = pcall(function() return exports.rp_garage:vehiclesOf(playerId) end)
    if not ok or type(list) ~= "table" then return end
    for _, v in ipairs(list) do
        if type(v) == "table" and v.wanted and v.vehicleId and (v.state == nil or v.state == "out") then
            local id = tonumber(v.vehicleId)
            if id and not wanted[id] then
                registerWanted(id, v.plate, v.record, v.label, nil)
            end
        end
    end
end

exports("wantedVehicles", function()
    local list = {}
    for vehicleId, info in pairs(wanted) do
        list[#list + 1] = info.plate or ("vehicle#" .. tostring(vehicleId))
    end
    table.sort(list)
    return list
end)

AddEventHandler("rp_garage:changed", function(identifier, plate, action)
    if action == "unwanted" or action == "stored" or action == "impounded" or action == "lost" then
        forgetWantedPlate(plate)
    end
end)

AddEventHandler("onVehicleRemoved", function(id)
    local vehicleId = tonumber(id)
    if vehicleId then wanted[vehicleId] = nil end
end)

-- Every spotTickMs: an on-duty officer within spotDistance of a wanted vehicle reads an APB.
CreateThread(function()
    while true do
        Wait(tunable("theft.spotTickMs", Config.theft.spotTickMs))
        if next(wanted) ~= nil then
            local officers = officersOnDuty()
            if #officers > 0 then
                local reach = tunable("theft.spotDistance", Config.theft.spotDistance)
                for vehicleId, info in pairs(wanted) do
                    local vpos = Open77.vehicles.getPosition(vehicleId)
                    if not vpos then
                        wanted[vehicleId] = nil
                    else
                        for _, officer in ipairs(officers) do
                            local opos = positionOf(officer)
                            if opos then
                                local d = distance3(opos, vpos)
                                if d <= reach then
                                    local plateText = info.plate and ("plate " .. info.plate) or "no plate on file"
                                    say(officer, ("[APB] Wanted vehicle in sight: %s, %s, %d m away."):format(
                                        info.label, plateText, math.floor(d + 0.5)), Config.chat.ncpdColor)
                                    toast(officer, "warning", "Wanted vehicle", ("%s (%s), %d m"):format(info.label, plateText, math.floor(d + 0.5)))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- /braquer -- hold up a shop vendor
-- ---------------------------------------------------------------------------------------------

local shopCooldown = {}   -- shopId -> monotonic seconds when the shop can be hit again

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

local STAGE = RpCrimeConfig.stage or {}
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

-- The old progress() contract on top of stage(): true | false, outcome | nil, reason.
local function stageOutcome(answer, err)
    if answer == nil then return nil, err end
    if not answer.ok then return false, answer.outcome or "cancelled" end
    return true
end

local function nearestShop(pos)
    local best, bestD
    for id, shop in pairs(Config.robbery.shops) do
        local d = planar(pos, shop.position)
        if math.abs(pos.z - shop.position.z) <= 4.0 and (not bestD or d < bestD) then
            best, bestD = id, d
        end
    end
    return best, bestD
end

local ROB_REASONS = {
    cooldown = "That register was emptied not long ago. Come back later.",
    too_far = "You are too far from the counter.",
    position_stale = "The server lost track of you. Try again.",
    player_not_found = "The server lost track of you. Try again.",
    register_empty = "The register is empty: the owners are broke.",
    economy_offline = "The eddies system is offline. No loot.",
    unknown_shop = "That shop is not on the map any more.",
    invalid_player = "The shop does not know you.",
}

RegisterCommand("braquer", function(source)
    if source == 0 then return print(TAG .. " braquer: run it from the game") end
    if busy[source] then return say(source, "Finish what you started first.") end
    local ok, why = canAct(source)
    if not ok then return say(source, why) end
    local pos = positionOf(source)
    if not pos then return say(source, "The server cannot place you. Try again in a second.") end

    local reach = tunable("robbery.reach", Config.robbery.reach)
    local shopId, d = nearestShop(pos)
    if not shopId or d > reach then
        return say(source, ("No vendor within %d m%s. Get up to the counter, choom."):format(
            reach, shopId and (" (nearest: %s, %d m)"):format(Config.robbery.shops[shopId].label, math.floor(d + 0.5)) or ""))
    end
    local shop = Config.robbery.shops[shopId]

    if tunable("robbery.requireWeaponDrawn", Config.robbery.requireWeaponDrawn) then
        local weapons = Open77.weapons.get(source)
        if not weapons or weapons.drawn ~= true then
            return say(source, ("%s laughs at your empty hands. Draw a weapon first."):format(shop.vendor))
        end
    end

    local now = Open77.time.monotonic()
    if shopCooldown[shopId] and shopCooldown[shopId] > now then
        return say(source, ("%s was hit not long ago and NCPD is still around: %d min to go."):format(
            shop.label, math.ceil((shopCooldown[shopId] - now) / 60)))
    end

    busy[source] = "robbery"
    shopCooldown[shopId] = now + tunable("robbery.cooldownMs", Config.robbery.cooldownMs) / 1000
    local officers = officersOnDuty()
    pageNcpd("robbery", shop.position, Config.robbery.alertText:format(shop.label), source)
    log("robbery started shop=%s by player %d officers_on_duty=%d", shopId, source, #officers)
    say(source, ("You point your iron at %s. Keep it up while the till empties -- X bails out."):format(shop.vendor))

    -- Staged bar without a pose: the weapon stays in the hands (Config.stage.robbery).
    local answer, barWhy = stage(source, "robbery", { label = "Emptying the till...", durationMs = tunable("robbery.durationMs", Config.robbery.durationMs) })
    local ran, outcome = stageOutcome(answer, barWhy)
    busy[source] = nil
    if ran == nil then
        log("robbery bar refused for player %d: %s", source, tostring(outcome))
        return say(source, "The heist fell apart (" .. tostring(outcome) .. "). NCPD is still on the way.")
    end
    if ran == false then
        logCrime(source, "robbery_aborted", shopId, 0)
        return say(source, "You bailed. NCPD is still on the way.")
    end

    ok, why = canAct(source)
    if not ok then return say(source, why) end
    local pos2 = positionOf(source)
    local near, d2 = within(pos2, shop.position, Config.robbery.finishReach)
    if not near then
        logCrime(source, "robbery_aborted", shopId, 0)
        return say(source, ("You walked away from the counter (%d m). No eddies for you."):format(math.floor(d2 + 0.5)))
    end

    local okRob, loot, reason = pcall(function() return exports.rp_shops:rob(shopId, source) end)
    if not okRob then
        log("rp_shops:rob raised: %s", tostring(loot))
        return say(source, "The shops are offline: nobody to rob.")
    end
    if not loot then
        return say(source, ROB_REASONS[reason] or ("Nothing to take (" .. tostring(reason) .. ")."))
    end
    local amount = type(loot) == "table" and (tonumber(loot.amount) or tonumber(loot.cash) or 0) or (tonumber(loot) or 0)

    say(source, ("%s empties the register: %d eddies in your pocket. Now run."):format(shop.vendor, amount))
    toast(source, "success", "Robbery", ("+%d eddies from %s"):format(amount, shop.label))
    gesture(source, "loot")

    if #officers > 0 then
        local okR, added, rr = pcall(function()
            return exports.rp_ncpd:addRecord(source, "robbery", Config.robbery.recordText:format(shop.label, amount), officers[1])
        end)
        if not okR or not added then
            log("rp_ncpd:addRecord refused: %s", tostring(okR and rr or added))
        else
            say(source, "An officer was on duty: the robbery lands on your criminal record.")
        end
    end

    logCrime(source, "robbery", shopId, amount)
    announceCrime("robbery", shop.position, source)
end, false)

-- ---------------------------------------------------------------------------------------------
-- /crocheter -- pick the lock of a vehicle you hold no key for
-- ---------------------------------------------------------------------------------------------

RegisterCommand("crocheter", function(source)
    if source == 0 then return print(TAG .. " crocheter: run it from the game") end
    if busy[source] then return say(source, "Finish what you started first.") end
    local ok, why = canAct(source)
    if not ok then return say(source, why) end
    local pos = positionOf(source)
    if not pos then return say(source, "The server cannot place you. Try again in a second.") end

    local reach = tunable("theft.reach", Config.theft.reach)
    local list = Open77.vehicles.nearby(source, reach, { limit = 3 })
    if not list or #list == 0 then
        return say(source, ("No ride within %d m. Vanilla traffic does not count: only a server vehicle has a lock to pick."):format(reach))
    end
    local entry = list[1]
    local vehicleId = entry.id
    local label = vehicleLabel(entry.record)

    local lockedForMe = Open77.vehicles.isLockedForPlayer(vehicleId, source)
    if lockedForMe == nil then return say(source, "That ride vanished.") end
    local okK, hasKey = pcall(function() return exports.rp_garage:hasKey(source, vehicleId) end)
    if okK and hasKey == true then
        return say(source, ("You hold a key to that %s. Open it the honest way: /verrouiller."):format(label))
    end
    if not lockedForMe then
        return say(source, ("That %s is not locked. Just open the door."):format(label))
    end

    local item = Config.theft.lockpickItem
    local okI, has = pcall(function() return exports.rp_inventory:has(source, item, 1) end)
    if not okI then return say(source, "Your pockets are offline: no lockpick to check.") end
    if not has then return say(source, "No lockpick in your pockets. Dex sells them at the black market after dark.") end

    busy[source] = "theft"
    say(source, ("You slide the pick into the %s's lock. Keep still -- X gives up."):format(label))
    -- Staged: crouched at the lock for the whole bar (Config.stage.lockpick).
    local answer, barWhy = stage(source, "lockpick", { label = "Jimmying the lock...", durationMs = tunable("theft.durationMs", Config.theft.durationMs) })
    local ran, outcome = stageOutcome(answer, barWhy)
    busy[source] = nil
    if ran == nil then
        log("theft bar refused for player %d: %s", source, tostring(outcome))
        return say(source, "The pick slipped (" .. tostring(outcome) .. ").")
    end
    if ran == false then return say(source, "You gave up. The lock holds.") end

    ok, why = canAct(source)
    if not ok then return say(source, why) end
    local vpos = Open77.vehicles.getPosition(vehicleId)
    if not vpos then return say(source, "The ride is gone.") end
    local pos2 = positionOf(source)
    if not pos2 or distance3(pos2, vpos) > reach + 1.5 then
        return say(source, "You walked away from the door. The lock holds.")
    end
    if Open77.vehicles.isLockedForPlayer(vehicleId, source) == false then
        return say(source, "Somebody unlocked it while you worked. Lucky you.")
    end

    local okL, reasonL = Open77.vehicles.setLocked(vehicleId, false)
    if not okL then return say(source, "The lock would not give (" .. tostring(reasonL) .. ").") end
    local hornMs = Config.theft.hornMs
    if hornMs and hornMs > 0 then Open77.vehicles.triggerHorn(vehicleId, hornMs) end

    local snapped = math.random() < tunable("theft.lockpickBreakChance", Config.theft.lockpickBreakChance)
    if snapped then
        local okRm, removed = pcall(function() return exports.rp_inventory:remove(source, item, 1) end)
        if not okRm or not removed then snapped = false end
    end

    local okP, plate = pcall(function() return exports.rp_garage:plateOf(vehicleId) end)
    if not okP or type(plate) ~= "string" then plate = nil end
    registerWanted(vehicleId, plate, entry.record, nil, source)
    if plate then
        local okW, flagged, rw = pcall(function() return exports.rp_garage:setWanted(plate, true, Config.theft.wantedReason) end)
        if not okW or not flagged then log("rp_garage:setWanted(%s) refused: %s", plate, tostring(okW and rw or flagged)) end
    end

    -- The owner, when online and a person (a society fleet has no single owner to page).
    local okO, owner = pcall(function() return exports.rp_garage:ownerOf(vehicleId) end)
    if okO and type(owner) == "string" and not owner:find("^society:") then
        for _, pid in ipairs(Open77.players.all()) do
            if pid ~= source and Open77.players.identifier(pid) == owner then
                say(pid, ("Somebody just jimmied the lock of your %s%s. Call the NCPD."):format(label, plate and (" (plate " .. plate .. ")") or ""))
                toast(pid, "warning", "Your ride", ("%s is being stolen"):format(label))
            end
        end
    end

    pageNcpd("vehicle_theft", vpos, ("%s being stolen (%s)"):format(label, plate and ("plate " .. plate) or "no plate on file"), source)
    say(source, ("The lock gives. The %s is yours for the night%s. Every badge in town will be looking for %s."):format(
        label, snapped and " -- your lockpick snapped" or "", plate and ("plate " .. plate) or "that ride"))
    toast(source, "success", "Hot ride", label .. (plate and (" - " .. plate) or ""))
    logCrime(source, "vehicle_theft", plate or ("vehicle#" .. tostring(vehicleId)), 0)
    announceCrime("vehicle_theft", vpos, source)
end, false)

-- ---------------------------------------------------------------------------------------------
-- /dealer <playerId> -- sell a drug pack, the buyer consents through the interaction service
-- ---------------------------------------------------------------------------------------------

local pendingDeals = {}   -- interactionId -> { dealer, buyer, price }

local DEAL_REASONS = {
    player_in_vehicle = "Both of you must be on foot.",
    player_not_alive = "Dead people do not buy.",
    too_far = "Get within 3 m of the buyer.",
    player_reserved = "One of you is busy with something else.",
    wrong_bucket = "You are not in the same instance.",
    player_not_ready = "The buyer is not in the world yet.",
    position_unavailable = "The server cannot place one of you.",
    invalid_participants = "That is not a valid buyer.",
    interactions_unavailable = "The interaction service is offline.",
}

RegisterCommand("dealer", function(source, args)
    if source == 0 then return print(TAG .. " dealer: run it from the game") end
    local target = tonumber(args[1])
    -- Open77.players.name throws (and kills the VM) for id <= 0 or a non-integer: validate first.
    if not target or target < 1 or target % 1 ~= 0 then return say(source, "Usage: /dealer <playerId> -- sells one drug pack for " .. Config.deal.price .. " eddies.") end
    target = math.floor(target)
    if target == source then return say(source, "Selling to yourself? Use it instead.") end
    if busy[source] then return say(source, "Finish what you started first.") end
    if not Open77.players.name(target) then return say(source, "No such player.") end
    local ok, why = canAct(source)
    if not ok then return say(source, why) end

    local reach = tunable("deal.reach", Config.deal.reach)
    local d, dr = Open77.players.distance(source, target)
    if not d then return say(source, "The server cannot place the buyer (" .. tostring(dr) .. ").") end
    if d > reach then return say(source, ("Too far (%d m). Get within %d m of %s."):format(math.floor(d + 0.5), reach, nameOf(target))) end

    local item = Config.deal.item
    local okH, has = pcall(function() return exports.rp_inventory:has(source, item, 1) end)
    if not okH then return say(source, "Your pockets are offline.") end
    if not has then return say(source, "Nothing to sell. Get a drug pack first.") end

    local price = tunable("deal.price", Config.deal.price)
    local okB, balance = pcall(function() return exports.rp_economy:getBalance(target) end)
    if not okB then return say(source, "The eddies system is offline: no deal.") end
    if (tonumber(balance) or 0) < price then
        return say(source, ("%s cannot cover %d eddies in cash. No deal."):format(nameOf(target), price))
    end

    if Open77.playerInteractions.current(source) then return say(source, "Finish what you are doing first.") end
    if Open77.playerInteractions.current(target) then return say(source, nameOf(target) .. " is busy right now.") end

    local state, reason = Open77.playerInteractions.request(source, target, "give", {
        durationMs = Config.deal.durationMs,
        startDistance = reach,
        breakDistance = reach + 2.0,
        inviteTimeoutMs = Config.deal.inviteTimeoutMs,
        consent = true,
    })
    if not state then
        return say(source, DEAL_REASONS[reason] or ("No deal (" .. tostring(reason) .. ")."))
    end
    pendingDeals[state.id] = { dealer = source, buyer = target, price = price, hold = stageHold(source, "deal") }
    log("deal offered dealer=%d buyer=%d price=%d interaction=%s", source, target, price, tostring(state.id))
    say(source, ("Offer made to %s: one drug pack for %d eddies. They have %d s to accept."):format(
        nameOf(target), price, math.floor(Config.deal.inviteTimeoutMs / 1000)))
    say(target, ("%s offers you a drug pack for %d eddies (cash). /interaction accept to buy, /interaction decline to walk away."):format(
        nameOf(source), price))
    toast(target, "info", "Street deal", ("Drug pack for %d eddies: /interaction accept"):format(price))
end, false)

AddEventHandler("onPlayerInteractionCompleted", function(state)
    if type(state) ~= "table" or not state.id then return end
    local deal = pendingDeals[state.id]
    if not deal then return end
    pendingDeals[state.id] = nil
    if deal.hold then stageRelease(deal.dealer, deal.hold); deal.hold = nil end
    local dealer = tonumber(state.actor) or deal.dealer
    local buyer = tonumber(state.target) or deal.buyer
    local item, price = Config.deal.item, deal.price

    -- Re-validate: the consent proves the handshake, not the pockets or the wallet.
    local okH, has = pcall(function() return exports.rp_inventory:has(dealer, item, 1) end)
    if not okH or not has then
        say(dealer, "The pack is gone from your pockets. No deal.")
        say(buyer, "The dealer has nothing left. No deal.")
        return
    end
    local okPay, newBuyerBalance, whyPay = pcall(function() return exports.rp_economy:remove(buyer, price, "deal:drugs") end)
    if not okPay or not newBuyerBalance then
        say(dealer, ("%s cannot pay (%s). No deal."):format(nameOf(buyer), tostring(okPay and whyPay or "wallet offline")))
        say(buyer, "You cannot cover the price. No deal.")
        return
    end
    local okRm, removed = pcall(function() return exports.rp_inventory:remove(dealer, item, 1) end)
    if not okRm or not removed then
        pcall(function() return exports.rp_economy:add(buyer, price, "deal:refund") end)
        say(dealer, "The pack slipped through your fingers. Deal refunded.")
        say(buyer, "The deal fell through. Your eddies are back.")
        return
    end
    local okAdd, added, whyAdd = pcall(function() return exports.rp_inventory:add(buyer, item, 1) end)
    if not okAdd or not added then
        pcall(function() return exports.rp_inventory:add(dealer, item, 1) end)
        pcall(function() return exports.rp_economy:add(buyer, price, "deal:refund") end)
        local text = (okAdd and whyAdd == "too_heavy") and "Their pockets are too heavy for the pack." or ("Their pockets refused the pack (" .. tostring(okAdd and whyAdd or added) .. ").")
        say(dealer, text .. " Deal refunded.")
        say(buyer, "Your pockets could not take the pack. Your eddies are back.")
        return
    end
    local okEarn, newDealerBalance = pcall(function() return exports.rp_economy:add(dealer, price, "deal:drugs") end)
    if not okEarn or not newDealerBalance then log("dealer payout refused for player %d", dealer) end

    say(dealer, ("Deal done: %s took the pack for %d eddies. Cash: %s."):format(nameOf(buyer), price, tostring(newDealerBalance or "?")))
    say(buyer, ("Deal done: one drug pack in your pockets for %d eddies. Cash: %d."):format(price, newBuyerBalance))
    toast(dealer, "success", "Street deal", ("+%d eddies"):format(price))
    toast(buyer, "success", "Street deal", "Drug pack x1")

    -- Influence for the dealer's gang, in the zone where the deal happened.
    local okG, gang = pcall(function() return exports.rp_gangs:gangOf(dealer) end)
    local okZ, zone = pcall(function() return exports.rp_zones:zoneOf(dealer) end)
    if not okZ or type(zone) ~= "table" then zone = nil end
    if okG and type(gang) == "string" and zone and zone.name then
        local okInf, points, whyInf = pcall(function()
            return exports.rp_gangs:addInfluence(zone.name, gang, Config.deal.influence, "deal")
        end)
        if okInf and points then
            say(dealer, ("%s influence in %s: %s."):format(gang, zone.label or zone.name, tostring(points)))
        elseif okInf and whyInf ~= "unknown_zone" then
            log("rp_gangs:addInfluence refused: %s", tostring(whyInf))
        end
    end

    local pos = positionOf(dealer) or positionOf(buyer)
    if pos and math.random() < tunable("deal.alertChance", Config.deal.alertChance) then
        local where = zone and (zone.label or zone.name) or "the street"
        pageNcpd("drugs", pos, Config.deal.alertText:format(where), dealer)
        announceCrime("drugs", pos, dealer)
        say(dealer, "Somebody saw that. Badges are on their way.")
    end
    logCrime(dealer, "deal", identifierOf(buyer), price)
end)

AddEventHandler("onPlayerInteractionCancelled", function(state)
    if type(state) ~= "table" or not state.id then return end
    local deal = pendingDeals[state.id]
    if not deal then return end
    pendingDeals[state.id] = nil
    if deal.hold then stageRelease(deal.dealer, deal.hold); deal.hold = nil end
    local reason = tostring(state.reason or "cancelled")
    local text = ({
        declined = "declined",
        rejected = "declined",
        timeout = "no answer",
        invite_timeout = "no answer",
    })[reason] or reason
    say(deal.dealer, ("Deal off with %s (%s)."):format(nameOf(deal.buyer), text))
    say(deal.buyer, ("Deal off (%s)."):format(text))
    log("deal cancelled dealer=%d buyer=%d reason=%s", deal.dealer, deal.buyer, reason)
end)

-- ---------------------------------------------------------------------------------------------
-- /voler -- gut a nomad crate that is not yours
-- ---------------------------------------------------------------------------------------------

local guttedCrates = {}   -- propId (string) -> true

local function propPosition(p)
    if type(p.position) == "table" and type(p.position.x) == "number" then
        return { x = p.position.x, y = p.position.y, z = p.position.z or 0.0 }
    end
    if type(p.x) == "number" then return { x = p.x, y = p.y, z = p.z or 0.0 } end
    return nil
end

-- The binding is documented in two shapes ({ kind, id } and { parentType, parentId }).
local function attachmentOf(p)
    local a = p.attachment
    if type(a) ~= "table" then return nil end
    return { kind = a.kind or a.parentType, id = tonumber(a.id or a.parentId) }
end

local function nearestCrate(pos, reach)
    local all = Open77.props.all(pos.bucket)
    if type(all) ~= "table" then return nil end
    local best, bestD
    for _, p in ipairs(all) do
        if p.resource == Config.contraband.ownerResource and (p.kind == nil or p.kind == "prop") then
            local ppos = propPosition(p)
            if ppos then
                local d = distance3(pos, ppos)
                if d <= reach and (not bestD or d < bestD) then best, bestD = p, d end
            end
        end
    end
    return best, bestD
end

local function contractHolders()
    local holders = {}
    for _, pid in ipairs(Open77.players.all()) do
        local ok, contract = pcall(function() return exports.rp_nomade:activeContract(pid) end)
        if ok and type(contract) == "table" and (contract.status == nil or contract.status == "active") then
            holders[#holders + 1] = pid
        end
    end
    return holders
end

RegisterCommand("voler", function(source)
    if source == 0 then return print(TAG .. " voler: run it from the game") end
    if busy[source] then return say(source, "Finish what you started first.") end
    local ok, why = canAct(source)
    if not ok then return say(source, why) end
    local pos = positionOf(source)
    if not pos then return say(source, "The server cannot place you. Try again in a second.") end

    local reach = tunable("contraband.reach", Config.contraband.reach)
    local crate = nearestCrate(pos, reach)
    if not crate then
        return say(source, ("No nomad crate within %d m. They sit at the Aldecaldos camp's loading bay while a convoy loads."):format(reach))
    end
    local propId = tostring(crate.id)
    if guttedCrates[propId] then return say(source, "That crate is already gutted. Nothing left but the box.") end
    local att = attachmentOf(crate)
    if att and att.kind == "player" then
        if att.id == source then return say(source, "That is the crate on your own shoulder, choom.") end
        return say(source, "It is in somebody's hands. Wait until it touches the ground.")
    end

    local holders = contractHolders()
    local mine = false
    for _, h in ipairs(holders) do if h == source then mine = true end end
    if mine and #holders == 1 then
        return say(source, "Steal your own cargo? Load it in the truck instead (/convoi).")
    end

    busy[source] = "crate"
    say(source, "You wedge a blade under the lid. Keep at it -- X drops it.")
    -- Staged: crouched at the crate for the whole bar (Config.stage.pry).
    local answer, barWhy = stage(source, "pry", { label = "Prying the crate open...", durationMs = tunable("contraband.durationMs", Config.contraband.durationMs) })
    local ran, outcome = stageOutcome(answer, barWhy)
    busy[source] = nil
    if ran == nil then
        log("crate bar refused for player %d: %s", source, tostring(outcome))
        return say(source, "The lid would not budge (" .. tostring(outcome) .. ").")
    end
    if ran == false then return say(source, "You left the crate alone.") end

    ok, why = canAct(source)
    if not ok then return say(source, why) end
    local again = Open77.props.get(propId)
    if not again then return say(source, "The crate is gone.") end
    local att2 = attachmentOf(again)
    if att2 and att2.kind == "player" then return say(source, "Somebody picked it up under your nose.") end
    local cpos = propPosition(again)
    local pos2 = positionOf(source)
    if not pos2 or not cpos or distance3(pos2, cpos) > reach + 1.5 then
        return say(source, "You walked away from the crate.")
    end
    if guttedCrates[propId] then return say(source, "Somebody gutted it first.") end

    local item, count = Config.contraband.item, Config.contraband.count
    local okA, added, reasonA = pcall(function() return exports.rp_inventory:add(source, item, count) end)
    if not okA then return say(source, "Your pockets are offline: nothing to take.") end
    if not added then
        if reasonA == "too_heavy" then return say(source, "Your pockets are too heavy for 2 kg of parts. Drop something first.") end
        return say(source, "Could not pocket the parts (" .. tostring(reasonA) .. ").")
    end
    guttedCrates[propId] = true
    gesture(source, "parts")

    say(source, ("You gut the crate: Stolen parts x%d in your pockets. Vik at the junkyard pays for those after dark (/receler)."):format(count))
    toast(source, "success", "Contraband", ("Stolen parts x%d"):format(count))
    for _, h in ipairs(holders) do
        if h ~= source then
            say(h, "Somebody is gutting one of your crates at the loading bay!")
            toast(h, "warning", "Convoy", "A crate is being gutted")
        end
    end
    logCrime(source, "crate_theft", "prop#" .. propId, 0)
    announceCrime("crate_theft", cpos, source)
end, false)

AddEventHandler("onPropRemoved", function(id)
    guttedCrates[tostring(id)] = nil
end)

-- ---------------------------------------------------------------------------------------------
-- The fence: an NPC at the junkyard, /receler and an E prompt, 22:00-06:00
-- ---------------------------------------------------------------------------------------------

local fence = { npcId = nil, record = nil, promptDefined = false, clockWarned = false }
local stopping = false

local function fenceOpen()
    local state, reason = Open77.environment.getState()
    if not state then
        if not fence.clockWarned then
            fence.clockWarned = true
            log("no clock authority (%s): the fence %s", tostring(reason),
                Config.fence.openWithoutClock and "never closes" or "never opens")
        end
        return Config.fence.openWithoutClock, nil, nil
    end
    local hour = tonumber(state.hour) or 0
    local openHour, closeHour = tunable("fence.openHour", Config.fence.openHour), tunable("fence.closeHour", Config.fence.closeHour)
    local open
    if openHour > closeHour then
        open = hour >= openHour or hour < closeHour
    else
        open = hour >= openHour and hour < closeHour
    end
    return open, hour, tonumber(state.minute) or 0
end

local function fenceSpeak(voice)
    if not fence.npcId or not voice then return end
    local ok, reason = Open77.npcs.speak(fence.npcId, voice)
    if not ok and reason ~= "npc_not_streamed" and reason ~= "npc_voice_busy" then
        log("fence stayed silent (%s): %s", voice, tostring(reason))
    end
end

local function fencePrice(itemId)
    if itemId == Config.contraband.item then
        return tunable("fence.stolenPartsPrice", Config.fence.stolenPartsPrice)
    end
    if type(itemId) == "string" and itemId:find("^implant_box") then
        local prices = Config.fence.implantPrices
        local base = tonumber(prices[itemId]) or tonumber(prices.default) or 0
        return math.floor(base * tunable("fence.implantRatio", Config.fence.implantRatio))
    end
    return nil
end

local function sellToFence(playerId, via)
    local ok, why = canAct(playerId)
    if not ok then return say(playerId, why) end
    local pos = positionOf(playerId)
    if not pos then return say(playerId, "The server cannot place you. Try again in a second.") end
    local near, d = within(pos, Config.fence.position, tunable("fence.reach", Config.fence.reach))
    if not near then
        return say(playerId, ("%s is not within %d m (you are %d m away). The junkyard is at %d, %d."):format(
            Config.fence.name, Config.fence.reach, math.floor(d + 0.5), Config.fence.position.x, Config.fence.position.y))
    end

    local open, hour, minute = fenceOpen()
    if not open then
        fenceSpeak(Config.fence.closedVoice)
        return say(playerId, ("%s does not trade in daylight. Come back between %02d:00 and %02d:00 (it is %02d:%02d)."):format(
            Config.fence.name, Config.fence.openHour, Config.fence.closeHour, hour or 0, minute or 0))
    end

    local okL, entries = pcall(function() return exports.rp_inventory:list(playerId) end)
    if not okL or type(entries) ~= "table" then return say(playerId, "Your pockets are offline. Come back later.") end

    local sales = {}
    for _, e in ipairs(entries) do
        if type(e) == "table" and type(e.id) == "string" then
            local unit = fencePrice(e.id)
            local count = math.floor(tonumber(e.count) or 0)
            if unit and unit > 0 and count > 0 then
                sales[#sales + 1] = { id = e.id, label = e.label or e.id, count = count, unit = unit, total = unit * count }
            end
        end
    end
    if #sales == 0 then
        fenceSpeak(Config.fence.greetingVoice)
        return say(playerId, ("%s looks you over: \"Nothing I want on you, choom. Bring parts, or a boxed implant.\""):format(Config.fence.name))
    end

    -- Staged: the goods held out to Vik for the bar's length (Config.stage.fence).
    local shown = stage(playerId, "fence", { label = "Showing the goods" })
    if not shown or not shown.ok then return say(playerId, "You keep the goods. Vik shrugs.") end
    if not canAct(playerId) then return end

    local paid, lines = 0, {}
    for _, s in ipairs(sales) do
        local okR, removed = pcall(function() return exports.rp_inventory:remove(playerId, s.id, s.count) end)
        if okR and removed then
            local okA, newBalance, whyA = pcall(function() return exports.rp_economy:add(playerId, s.total, "fence:" .. s.id) end)
            if okA and newBalance then
                paid = paid + s.total
                lines[#lines + 1] = ("%d x %s @ %d"):format(s.count, s.label, s.unit)
                logCrime(playerId, "fence", s.id, s.total)
            else
                pcall(function() return exports.rp_inventory:add(playerId, s.id, s.count) end)
                log("fence payout refused for %s: %s", s.id, tostring(okA and whyA or newBalance))
            end
        end
    end
    if paid == 0 then
        return say(playerId, "The deal fell through: the wallet is offline. Your goods are still on you.")
    end
    fenceSpeak(Config.fence.greetingVoice)
    say(playerId, ("%s counts out %d eddies for %s. \"Never saw you.\""):format(Config.fence.name, paid, table.concat(lines, ", ")))
    toast(playerId, "success", "Fence", ("+%d eddies"):format(paid))
    log("fence sale player %d paid=%d via=%s", playerId, paid, via or "command")
end

local function resolveFenceCandidates()
    local byName = {}
    local okT, templates = pcall(Open77.npcs.templates)
    if okT and type(templates) == "table" then
        for _, t in ipairs(templates) do
            if type(t) == "table" and t.name then byName[t.name] = t.record end
        end
    end
    local list = {}
    for _, alias in ipairs(Config.fence.aliases) do
        list[#list + 1] = { template = alias, record = byName[alias] }
    end
    for _, record in ipairs(Config.fence.records) do
        list[#list + 1] = { record = record }
    end
    return list
end

local function defineFencePrompt()
    if fence.promptDefined or not fence.npcId then return end
    -- A world target makes open77_interactions call Open77.world.nearby every 250 ms on every
    -- client; on 2.31 that query is unproven and correlates with heap-corruption crashes near
    -- lootable decor (18 Sept, 4 crashes). Off by default until base PR #37 lands; /receler works.
    if Config.fence.nativePrompt ~= true then return end
    if not fence.record then
        log("fence record unknown: no E prompt (it would show on every NPC); /receler still works")
        return
    end
    local ok, result, reason = pcall(function()
        return exports.open77_interactions:define({
            {
                id = "rp_crime_fence",
                kind = "globalNpc",
                distance = Config.fence.promptDistance,
                markerDistance = 15.0,
                marker = "shop",
                label = Config.fence.promptLabel,
                description = Config.fence.promptDescription,
                key = Config.fence.promptKey,
                icon = "FENCE",
                color = "#FF6040",
                event = "rp_crime:fencePrompt",
                canInteract = { record = { fence.record } },
            },
        })
    end)
    if ok and result then
        fence.promptDefined = true
        log("fence prompt declared (%s) on record %s", Config.fence.promptLabel, fence.record)
    else
        log("fence prompt refused: %s", tostring(ok and reason or result))
    end
end

local function spawnFence()
    if stopping or fence.npcId then return end
    for _, candidate in ipairs(resolveFenceCandidates()) do
        local def = {
            position = { x = Config.fence.position.x, y = Config.fence.position.y, z = Config.fence.position.z },
            yaw = Config.fence.yaw,
            aiMode = 0,                              -- tasks
            damagePolicy = Config.fence.damagePolicy, -- numeric, 2 = invulnerable
            behavior = { combatEnabled = false },
            persistent = false,
        }
        if candidate.record then def.record = candidate.record else def.template = candidate.template end
        local id, reason = Open77.npcs.create(def)
        if id then
            fence.npcId = id
            local snap = Open77.npcs.get(id)
            fence.record = candidate.record or (type(snap) == "table" and (snap.record or snap.template)) or nil
            if type(fence.record) == "string" and not fence.record:find("^Character%.") then fence.record = nil end
            log("fence %s spawned template=%s record=%s id=%s at %.1f %.1f %.1f", Config.fence.name,
                tostring(candidate.template or "-"), tostring(fence.record), tostring(id),
                Config.fence.position.x, Config.fence.position.y, Config.fence.position.z)
            break
        end
        log("fence template %s / record %s refused: %s", tostring(candidate.template), tostring(candidate.record), tostring(reason))
    end
    if not fence.npcId then
        log("fence NPC could not be spawned; /receler still works at %.1f %.1f", Config.fence.position.x, Config.fence.position.y)
        return
    end
    defineFencePrompt()
end

-- The fence's crates (Config.fence.props): decoration beside Vik, owned here, removed on
-- stop. A refusal only logs; the NPC and the prompt do not depend on them.
local fenceProps = {}

local function spawnFenceProps()
    for index, at in ipairs(Config.fence.props or {}) do
        if not fenceProps[index] and at.model then
            local id, reason = Open77.props.create({
                model = at.model,
                position = { x = at.x, y = at.y, z = at.z },
                yaw = at.yaw or 0.0,
                bucket = 0,
                streamingRadius = 120.0,
            })
            if id then
                fenceProps[index] = id
            else
                log("fence crate %d not spawned (%s)", index, tostring(reason))
            end
        end
    end
end

local function removeFenceProps()
    for index, propId in pairs(fenceProps) do
        Open77.props.remove(propId)
        fenceProps[index] = nil
    end
end

local function removeFence()
    removeFenceProps()
    if fence.npcId then
        Open77.npcs.remove(fence.npcId)
        fence.npcId = nil
    end
    if fence.promptDefined then
        pcall(function() return exports.open77_interactions:undefine("rp_crime_fence") end)
        fence.promptDefined = false
    end
end

RegisterCommand("receler", function(source)
    if source == 0 then return print(TAG .. " receler: run it from the game") end
    if busy[source] then return say(source, "Finish what you started first.") end
    sellToFence(source, "command")
end, false)

AddEventHandler("onNpcInteracted", function(npcId, playerId, interactionId, choiceId, distance)
    if not fence.npcId or tostring(npcId) ~= tostring(fence.npcId) then return end
    playerId = tonumber(playerId)
    if not playerId then return end
    if (tonumber(distance) or 99) > Config.fence.reach then
        return say(playerId, ("Get closer to %s."):format(Config.fence.name))
    end
    if busy[playerId] then return say(playerId, "Finish what you started first.") end
    sellToFence(playerId, "prompt")
end)

AddEventHandler("onNpcRemoved", function(id, reason)
    if fence.npcId and tostring(id) == tostring(fence.npcId) then
        fence.npcId = nil
        fence.promptDefined = false
        if stopping then return end
        log("fence removed (%s): respawning in 5 s", tostring(reason))
        SetTimeout(5000, spawnFence)
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/braquer", help = "Hold up the shop vendor in front of you (weapon drawn, 20 s, pages the NCPD)" },
    { command = "/crocheter", help = "Pick the lock of the locked vehicle next to you (needs a lockpick)" },
    { command = "/dealer", help = "Sell a drug pack to a player within 3 m for 120 eddies",
      parameters = { { name = "playerId", help = "the buyer's id" } } },
    { command = "/voler", help = "Gut a nomad crate that is not yours (within 3 m)" },
    { command = "/receler", help = "Sell stolen parts and boxed implants to the fence at the junkyard (22:00-06:00)" },
}

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then log("addSuggestions refused: %s", tostring(reason)) end
end

RegisterNetEvent("chat:ready", function()
    publishSuggestions(source)
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and name ~= RESOURCE then
        defineItems()
        return
    end
    if name ~= RESOURCE then return end
    stopping = false
    local shopCount = 0
    for _ in pairs(Config.robbery.shops) do shopCount = shopCount + 1 end
    log("started: %d shops to rob (cooldown %d min), lockpick theft %d s, deal %d eddies, fence %s at %.1f %.1f %.1f open %02d:00-%02d:00",
        shopCount,
        math.floor(Config.robbery.cooldownMs / 60000), math.floor(Config.theft.durationMs / 1000), Config.deal.price,
        Config.fence.name, Config.fence.position.x, Config.fence.position.y, Config.fence.position.z,
        Config.fence.openHour, Config.fence.closeHour)
    defineItems()
    chooseStore()
    spawnFence()
    local crates, err = pcall(spawnFenceProps)
    if not crates then log("fence crates failed: %s", tostring(err)) end
    publishSuggestions(-1)
    for _, pid in ipairs(Open77.players.all()) do importWanted(pid) end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    stopping = true
    removeFence()
    for id, deal in pairs(pendingDeals) do
        Open77.playerInteractions.cancel(id, "resource_stopping")
        pendingDeals[id] = nil
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if playerId then importWanted(playerId) end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if playerId then busy[playerId] = nil; stageClear(playerId) end
end)
