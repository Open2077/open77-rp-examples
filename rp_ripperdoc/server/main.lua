-- rp_ripperdoc server: the clinic. Server-authoritative from end to end.
--
--   patient  E on the chair  -> lies down (Open77.animations.playAt 'lie'), marked "on the chair"
--   ripper   ALT+click Operate / /operer <id> -> UI-kit context menu (catalogue, price, grade,
--            stock, duration) -> a QUOTE the patient accepts through open77_player_interactions
--            -> UI-kit progress on both -> Open77.cyberware.install / remove
--            -> onCyberwareOperationCompleted -> fee to the `ripper` society, box consumed,
--            SQL row, cyberpsychosis check.
--
-- Money, items, jobs and zones come from the other rp_* resources through pcall'd
-- exports; every one of them may be missing and the player is told so.
local RESOURCE = GetCurrentResourceName()
local cfg = RpRipperConfig
local TAG = "[rp_ripperdoc]"
local PURPLE = { 181, 123, 255 }

-- Slots the cyberware guide names on this build, in display order.
local SLOTS = { "arms", "legs", "operating_system", "self_ice", "purge" }

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function log(text) print(TAG .. " " .. text) end

local function say(pid, text)
    pid = tonumber(pid)
    if not pid then return end
    Open77.chat.send(pid, { author = "RIPPERDOC", text = text, color = PURPLE })
end

local function toast(pid, kind, title, message, durationMs)
    pid = tonumber(pid)
    if not pid then return end
    Open77.notifications.send(pid, {
        type = kind, title = title, message = message, icon = "RIP",
        durationMs = durationMs or 6000,
    })
end

local function money(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n):reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (s:gsub("^%s+", "")) .. " €$"
end

local function seconds(ms) return math.floor((tonumber(ms) or 0) / 1000 + 0.5) end

local function playerName(pid)
    pid = tonumber(pid)
    if not pid then return "someone" end
    local ok, full = pcall(function() return exports.rp_identity:fullName(pid) end)
    if ok and type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(pid) or ("player " .. tostring(pid))
end

local function isPlayer(pid)
    pid = tonumber(pid)
    return pid ~= nil and pid > 0 and Open77.players.name(pid) ~= nil
end

local function distanceBetween(a, b)
    local pa, pb = Open77.players.position(a), Open77.players.position(b)
    if not pa or not pb then return nil end
    if pa.bucket ~= pb.bucket then return nil, "wrong_bucket" end
    local dx, dy, dz = pa.x - pb.x, pa.y - pb.y, pa.z - pb.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function distanceToChair(pid)
    local p = Open77.players.position(pid)
    if not p then return nil end
    local c = cfg.chair.position
    local dx, dy, dz = p.x - c.x, p.y - c.y, p.z - c.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- UI-kit server twins: nil, reason when the widget never opened; a table otherwise.
local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

---------------------------------------------------------------------------
-- Other rp_* resources, through pcall'd synchronous exports
---------------------------------------------------------------------------
local function jobsAvailable()
    return pcall(function() return exports.rp_jobs:getJob(0) end)
end

local function hasRipperJob(pid)
    local ok, has = pcall(function() return exports.rp_jobs:hasJob(pid, cfg.job) end)
    return ok and has == true
end

local function isRipperOnDuty(pid)
    if not hasRipperJob(pid) then return false end
    local ok, duty = pcall(function() return exports.rp_jobs:onDuty(pid) end)
    return ok and duty == true
end

local function rippersOnDuty()
    local ok, list = pcall(function() return exports.rp_jobs:listOnDuty(cfg.job) end)
    if ok and type(list) == "table" then return list end
    return {}
end

local function gradeLabelOf(pid)
    local ok, grade = pcall(function() return exports.rp_jobs:getGrade(pid) end)
    if ok and type(grade) == "table" then return tostring(grade.label) end
    return "?"
end

local function inClinic(pid)
    if not cfg.clinicZone then return true end
    local ok, inside = pcall(function() return exports.rp_zones:isIn(pid, cfg.clinicZone) end)
    if not ok then return true end        -- rp_zones offline: the chair position is the clinic
    return inside == true
end

-- Boxed implants: the ripper's pockets first, then the patient's own.
local function boxHolder(ripper, patient, box)
    local okR, n = pcall(function() return exports.rp_inventory:count(ripper, box) end)
    if okR and (tonumber(n) or 0) > 0 then return ripper, tonumber(n) end
    local okP, m = pcall(function() return exports.rp_inventory:count(patient, box) end)
    if okP and (tonumber(m) or 0) > 0 then return patient, tonumber(m) end
    if not okR and not okP then return nil, "inventory_offline" end
    return nil, "no_stock"
end

local function takeBox(holder, box)
    local ok, removed, reason = pcall(function() return exports.rp_inventory:remove(holder, box, 1) end)
    if ok and removed then return true end
    return nil, ok and tostring(reason) or tostring(removed)
end

local function giveBox(holder, box, count)
    local ok, added, reason = pcall(function() return exports.rp_inventory:add(holder, box, count or 1) end)
    if ok and added then return true end
    return nil, ok and tostring(reason) or tostring(added)
end

-- Money. The fee goes to the society through rp_bank:charge (account -> society);
-- when the account is short the cash pays through rp_economy and the society is
-- credited by hand. Answers "account" | "cash" | "free" (no money system at all),
-- or nil, reason.
local function canAfford(patient, price)
    if price <= 0 then return true end
    local okB, account = pcall(function() return exports.rp_bank:getAccount(patient) end)
    local okE, cash = pcall(function() return exports.rp_economy:getBalance(patient) end)
    if not okB and not okE then return true end
    local acc = (okB and type(account) == "table") and (tonumber(account.balance) or 0) or 0
    local wallet = okE and (tonumber(cash) or 0) or 0
    return acc >= price or wallet >= price
end

local function takePayment(patient, price, note)
    if price <= 0 then return "free" end
    local okB, newBalance, bankReason = pcall(function()
        return exports.rp_bank:charge(patient, price, cfg.society, note)
    end)
    if okB and newBalance then return "account" end
    local okE, newCash, cashReason = pcall(function()
        return exports.rp_economy:remove(patient, price, note)
    end)
    if okE and newCash then
        pcall(function() return exports.rp_bank:societyAdd(cfg.society, price, note) end)
        return "cash"
    end
    if not okB and not okE then return "free" end
    return nil, (okE and tostring(cashReason)) or (okB and tostring(bankReason)) or "no_wallet"
end

-- rp_bank has no society -> account move, so a refund lands in cash.
local function refund(patient, price, paidVia, note)
    if price <= 0 or paidVia == "free" or paidVia == nil then return end
    pcall(function() return exports.rp_bank:societyRemove(cfg.society, price, note) end)
    local ok, v, reason = pcall(function() return exports.rp_economy:add(patient, price, note) end)
    if not (ok and v) then
        log(("refund of %d to player %s failed: %s"):format(price, tostring(patient), tostring(ok and reason or v)))
    end
end

---------------------------------------------------------------------------
-- Catalogue helpers
---------------------------------------------------------------------------
local defined = {}        -- entry.key -> true when both definitions are registered
local defineReason = {}   -- entry.key -> why not

local function entryByKey(key)
    for _, entry in ipairs(cfg.catalogue) do
        if entry.key == key or entry.box == key then return entry end
    end
    return nil
end

local function entryBySlot(slot)
    for _, entry in ipairs(cfg.catalogue) do
        if entry.slot == slot then return entry end
    end
    return nil
end

local function entryByDefinition(definitionId)
    for _, entry in ipairs(cfg.catalogue) do
        if entry.definitionId == definitionId then return entry end
    end
    return nil
end

local function gradeOf(entry, gradeId)
    for _, grade in ipairs(entry.grades) do
        if grade.id == gradeId then return grade end
    end
    return nil
end

-- The grade snapshot of an installed implant may be a table ({ id = ... }) or an id.
local function installedGradeId(implant)
    if type(implant) ~= "table" then return nil end
    if type(implant.grade) == "table" then return implant.grade.id end
    return implant.grade
end

local function describeImplant(implant)
    if type(implant) ~= "table" then return nil end
    local entry = entryByDefinition(implant.definition)
    local gradeId = installedGradeId(implant)
    local grade = entry and gradeOf(entry, gradeId)
    local label = entry and entry.label or tostring(implant.definition)
    local gradeLabel = grade and grade.label or tostring(gradeId or "?")
    return ("%s [%s]"):format(label, gradeLabel), entry, grade
end

-- Every installed implant of a record: the known slots first, then any other
-- table field that looks like an implant (the record shape for the hacking slots
-- is not documented on this build).
local function installedList(record)
    local list, seen = {}, {}
    for _, slot in ipairs(SLOTS) do
        local implant = record[slot]
        if type(implant) == "table" and implant.definition then
            list[#list + 1] = { slot = slot, implant = implant }
            seen[slot] = true
        end
    end
    for key, value in pairs(record) do
        if not seen[key] and type(value) == "table" and value.definition and value.slot then
            list[#list + 1] = { slot = tostring(value.slot), implant = value }
        end
    end
    return list
end

local function installedInSlot(record, slot)
    for _, item in ipairs(installedList(record)) do
        if item.slot == slot then return item.implant end
    end
    return nil
end

local function removalPrice(entry, implant)
    local _, _, grade = describeImplant(implant)
    local base = grade and grade.price or (entry.grades[1] and entry.grades[1].price) or 0
    return math.floor(base * (cfg.removalPriceFactor or 0.5))
end

local function platformGrade(grade)
    local g = {}
    for k, v in pairs(grade) do
        if k ~= "label" and k ~= "price" and k ~= "durationMs" and k ~= "hacking" then g[k] = v end
    end
    return g
end

local function defineCatalogue()
    for _, entry in ipairs(cfg.catalogue) do
        local ok, reason = true, nil
        if entry.hacking then
            local fn = type(Open77.hacking) == "table" and ({
                hack = Open77.hacking.define,
                ice = Open77.hacking.defineIce,
                purge = Open77.hacking.definePurge,
            })[entry.hacking] or nil
            if not fn then
                ok, reason = false, "hacking_unavailable"
            else
                local grades = {}
                for _, grade in ipairs(entry.grades) do
                    local hg = { id = grade.id }
                    for k, v in pairs(grade.hacking or {}) do hg[k] = v end
                    grades[#grades + 1] = hg
                end
                local called, result, why = pcall(fn, { id = entry.definitionId, version = entry.version, grades = grades })
                if not called then ok, reason = false, tostring(result)
                elseif not result then ok, reason = false, tostring(why) end
            end
        end
        if ok then
            local grades = {}
            for _, grade in ipairs(entry.grades) do grades[#grades + 1] = platformGrade(grade) end
            local called, result, why = pcall(Open77.cyberware.define, {
                id = entry.definitionId, version = entry.version,
                slot = entry.slot, profile = entry.profile, grades = grades,
            })
            if not called then ok, reason = false, tostring(result)
            elseif not result then ok, reason = false, tostring(why) end
        end
        defined[entry.key] = ok or nil
        defineReason[entry.key] = (not ok) and reason or nil
        if ok then
            log(("catalogue %s defined (%s/%s, %d grade(s))"):format(entry.key, entry.slot, entry.profile, #entry.grades))
        else
            log(("catalogue %s NOT defined: %s"):format(entry.key, tostring(reason)))
        end
    end
end

local function defineItems()
    local ok, registered, rejected = pcall(function() return exports.rp_inventory:define(cfg.items) end)
    if not ok then
        log("rp_inventory offline, boxed implants not registered: " .. tostring(registered))
        return
    end
    local r = type(registered) == "table" and #registered or tonumber(registered) or 0
    local j = type(rejected) == "table" and #rejected or tonumber(rejected) or 0
    log(("boxed implants registered in rp_inventory: %s registered, %s rejected"):format(tostring(r), tostring(j)))
end

---------------------------------------------------------------------------
-- Persistence: SQL first, kvp when the server has no database
---------------------------------------------------------------------------
local store = "pending"       -- "pending" | "sql" | "kvp"
local pendingRows = {}        -- rows logged before the store was decided
local memoryLog = {}          -- newest first, capped, used by /ripper when SQL is off

local function pushMemory(row)
    table.insert(memoryLog, 1, row)
    if #memoryLog > 100 then table.remove(memoryLog) end
end

local function writeKvp()
    local encoded = json.encode(memoryLog)
    if not encoded then return end
    local ok, reason = Open77.kvp.set("operations", encoded)
    if not ok then log("kvp write failed: " .. tostring(reason)) end
end

local function insertRow(row)
    Open77.database.insert(
        "INSERT INTO rp_ripperdoc_operations (ripper, ripper_name, patient, patient_name, implant, grade, action, price, paid_via, `at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        { row.ripper, row.ripperName, row.patient, row.patientName, row.implant, row.grade, row.action, row.price, row.paidVia, row.at },
        function(id)
            if not id then log("SQL insert failed for " .. row.action .. " " .. row.implant) end
        end)
end

local function persistRow(row)
    pushMemory(row)
    if store == "sql" then insertRow(row)
    elseif store == "kvp" then writeKvp()
    else pendingRows[#pendingRows + 1] = row end
end

local function decideStore(choice, reason)
    if store ~= "pending" then return end
    store = choice
    if choice == "kvp" then
        log("store=kvp reason=" .. tostring(reason))
        local saved = Open77.kvp.get("operations")
        if type(saved) == "string" then
            local rows = json.decode(saved)
            if type(rows) == "table" then
                for i = #rows, 1, -1 do pushMemory(rows[i]) end
            end
        end
        if #pendingRows > 0 then writeKvp() end
    else
        log("store=sql table=rp_ripperdoc_operations")
        for _, row in ipairs(pendingRows) do insertRow(row) end
    end
    pendingRows = {}
end

local function setupStore()
    local queued, reason = Open77.database.ready(function()
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_ripperdoc_operations (
                id           INT AUTO_INCREMENT PRIMARY KEY,
                ripper       VARCHAR(64)  NOT NULL,
                ripper_name  VARCHAR(64)  NOT NULL DEFAULT '',
                patient      VARCHAR(64)  NOT NULL,
                patient_name VARCHAR(64)  NOT NULL DEFAULT '',
                implant      VARCHAR(96)  NOT NULL,
                grade        VARCHAR(32)  NOT NULL DEFAULT '',
                action       VARCHAR(16)  NOT NULL,
                price        INT          NOT NULL DEFAULT 0,
                paid_via     VARCHAR(16)  NOT NULL DEFAULT '',
                `at`         BIGINT       NOT NULL,
                INDEX idx_ripper_at (ripper, `at`)
            )
        ]])
        decideStore("sql")
    end)
    if not queued then
        decideStore("kvp", reason)
        return
    end
    SetTimeout(15000, function()
        if store == "pending" then
            local _, why = Open77.database.isReady()
            decideStore("kvp", why or "database_not_answering")
        end
    end)
end

---------------------------------------------------------------------------
-- The chair
---------------------------------------------------------------------------
local onChair = {}        -- patientId -> { playbackId, since }
local ops = {}            -- interactionId -> op
local opByPlayer = {}     -- playerId -> op (ripper and patient)
local tickets = {}        -- cyberware ticket -> op

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

local STAGE = RpRipperConfig.Stage or {}
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

local function lieDown(pid)
    local playback, reason = Open77.animations.playAt(pid, cfg.animations.chair,
        cfg.chair.position, cfg.chair.yaw, { loop = true })
    if not playback then return nil, reason end
    onChair[pid] = { playbackId = playback.playbackId, since = Open77.time.monotonic() }
    return true
end

local function standUp(pid)
    local seat = onChair[pid]
    onChair[pid] = nil
    if seat and seat.playbackId then
        local ok, reason = Open77.animations.stopAt(seat.playbackId)
        if not ok then log(("stopAt refused for player %s: %s"):format(tostring(pid), tostring(reason))) end
    end
end

local ANIMATION_REASONS = {
    animation_owned = "Finish your current animation first.",
    player_in_vehicle = "Get out of the vehicle first.",
    player_not_alive = "You need to be alive for that, choom.",
    anchor_too_far = "Get closer to the chair.",
    anchor_move_refused = "You cannot be placed on the chair right now.",
    unknown_profile = "The chair posture is missing on this server (RP archive).",
}

RegisterNetEvent("rp_ripperdoc:chair", function()
    local pid = source
    if type(pid) ~= "number" or pid <= 0 then return end
    if opByPlayer[pid] then
        say(pid, "Stay still, the ripper is working on you.")
        return
    end
    if onChair[pid] then
        standUp(pid)
        say(pid, "You get off the ripperdoc chair.")
        return
    end
    local d = distanceToChair(pid)
    if not d or d > cfg.chair.reach then
        say(pid, ("The chair is %s m away. Get next to it."):format(d and ("%.1f"):format(d) or "?"))
        return
    end
    local ok, reason = lieDown(pid)
    if not ok then
        say(pid, ANIMATION_REASONS[reason] or ("Cannot lie down: " .. tostring(reason)))
        return
    end
    local rippers = rippersOnDuty()
    if #rippers == 0 then
        say(pid, "You lie down on the ripperdoc chair. No ripper is on duty right now - nobody can give you a quote. Press E again to get up.")
    else
        say(pid, ("You lie down on the ripperdoc chair. %d ripper(s) on duty can operate. Press E again to get up."):format(#rippers))
        for _, ripperId in ipairs(rippers) do
            if tonumber(ripperId) ~= pid then
                say(ripperId, ("%s is lying on the chair. ALT+click them > Operate, or /operer %d."):format(playerName(pid), pid))
            end
        end
    end
end)

AddEventHandler("onPlayerAnimationChanged", function(playerId, stateJson)
    local pid = tonumber(playerId)
    local seat = pid and onChair[pid]
    if not seat then return end
    local state = type(stateJson) == "string" and json.decode(stateJson) or stateJson
    if type(state) ~= "table" then return end
    if state.playbackId ~= seat.playbackId then return end
    if state.active == false then
        onChair[pid] = nil
        say(pid, "You left the ripperdoc chair.")
    end
end)

-- Put the patient back on the chair after an operation ended, if they are still there.
local function reLie(patient)
    SetTimeout(1500, function()
        if opByPlayer[patient] or onChair[patient] or not isPlayer(patient) then return end
        local d = distanceToChair(patient)
        if not d or d > cfg.chair.reach + 1.0 then return end
        if lieDown(patient) then
            say(patient, "You stay on the chair. Press E to get up.")
        else
            say(patient, "Press E on the chair to lie down again.")
        end
    end)
end

---------------------------------------------------------------------------
-- Operations
---------------------------------------------------------------------------
local function cleanup(op)
    if op.id then ops[op.id] = nil end
    if op.toolHold then stageRelease(op.ripper, op.toolHold); op.toolHold = nil end
    if op.ticket then tickets[op.ticket] = nil end
    if opByPlayer[op.ripper] == op then opByPlayer[op.ripper] = nil end
    if opByPlayer[op.patient] == op then opByPlayer[op.patient] = nil end
    -- Any progress bar still on either screen belongs to this server resource.
    for _, pid in ipairs({ op.ripper, op.patient }) do
        if isPlayer(pid) then
            CreateThread(function() uikit("close", pid) end)
        end
    end
end

local function rollback(op)
    if op.boxTaken then
        local ok, reason = giveBox(op.boxHolder, op.entry.box, 1)
        if not ok then log(("box %s could not be returned to player %s: %s"):format(op.entry.box, tostring(op.boxHolder), tostring(reason))) end
        op.boxTaken = false
    end
    if op.paidVia then
        refund(op.patient, op.price, op.paidVia, "ripper refund:" .. op.entry.key)
        op.paidVia = nil
    end
end

local function abort(op, text)
    rollback(op)
    op.phase = "aborted"
    say(op.ripper, "Procedure aborted: " .. text)
    say(op.patient, "Procedure aborted: " .. text)
    log(("op %s aborted (%s -> %s, %s %s): %s"):format(tostring(op.id), tostring(op.ripper), tostring(op.patient), op.action, op.entry.key, text))
    cleanup(op)
    reLie(op.patient)
end

local function countImplants(patient, fallback)
    local record = Open77.cyberware.current(patient)
    if type(record) == "table" then return #installedList(record) end
    return fallback
end

local function cyberpsychosisCheck(op)
    local count = countImplants(op.patient, (op.countBefore or 0) + 1)
    local threshold = tonumber(cfg.cyberpsychosisThreshold) or 4
    if count <= threshold then return end
    local fx = cfg.cyberpsychosis
    local ok, reason = Open77.effects.screen(op.patient, fx.effect, { strength = fx.strength, duration = fx.durationSeconds })
    if not ok then log("cyberpsychosis overlay refused: " .. tostring(reason)) end
    say(op.patient, ("WARNING - %d implants: your chrome is fighting your brain. Cyberpsychosis symptoms for %d s. Take it easy, choom."):format(count, fx.durationSeconds))
    toast(op.patient, "error", "Cyberpsychosis", ("Too much chrome (%d implants). Symptoms for %d s."):format(count, fx.durationSeconds), 8000)
    say(op.ripper, ("Heads up: %s now carries %d implants, past the %d threshold. Cyberpsychosis symptoms."):format(playerName(op.patient), count, threshold))
    log(("cyberpsychosis on player %s (%d implants > %d)"):format(tostring(op.patient), count, threshold))
end

local function complete(op, result)
    if op.ticket then tickets[op.ticket] = nil end
    if not (type(result) == "table" and result.ok == true) then
        local why = type(result) == "table" and tostring(result.error) or "unknown"
        rollback(op)
        op.phase = "failed"
        say(op.ripper, ("The procedure failed (%s). %s got their eddies back."):format(why, playerName(op.patient)))
        say(op.patient, ("The procedure failed (%s). Your eddies are back in cash."):format(why))
        log(("op %s failed: %s"):format(tostring(op.id), why))
        cleanup(op)
        reLie(op.patient)
        return
    end
    op.phase = "done"
    local row = {
        ripper = Open77.players.identifier(op.ripper) or ("session:" .. tostring(op.ripper)),
        ripperName = playerName(op.ripper),
        patient = Open77.players.identifier(op.patient) or ("session:" .. tostring(op.patient)),
        patientName = playerName(op.patient),
        implant = op.entry.definitionId,
        grade = op.grade and op.grade.id or "",
        action = op.action,
        price = op.price,
        paidVia = op.paidVia or "free",
        at = math.floor(Open77.time.unix()),
    }
    persistRow(row)
    local what = op.action == "install"
        and ("%s [%s] installed"):format(op.entry.label, op.grade.label)
        or ("%s removed"):format(op.entry.label)
    say(op.ripper, ("Done: %s on %s. %s to the %s society."):format(what, playerName(op.patient), money(op.price), cfg.society))
    say(op.patient, ("Done: %s. You paid %s (%s). /implants to check your chrome."):format(what, money(op.price), op.paidVia == "cash" and "cash" or op.paidVia == "account" and "account" or "on the house"))
    toast(op.patient, "success", "Ripperdoc", what .. ".", 6000)
    log(("op %s done: %s %s on player %s by player %s, %d eddies via %s"):format(tostring(op.id), op.action, op.entry.key, tostring(op.patient), tostring(op.ripper), op.price, tostring(op.paidVia)))
    TriggerEvent("rp_ripperdoc:operation", op.ripper, op.patient, op.action, op.entry.key, op.grade and op.grade.id or "", op.price)
    cleanup(op)
    if op.action == "install" then cyberpsychosisCheck(op) end
    reLie(op.patient)
end

-- The consent came in and the surgery time elapsed: take the box and the money,
-- then stage the platform operation. Failure at any step gives everything back.
local function finalize(op)
    op.phase = "committing"
    if not isRipperOnDuty(op.ripper) then return abort(op, "the ripper is off duty.") end
    local record, reason = Open77.cyberware.current(op.patient)
    if not record then return abort(op, ("the patient's implant record is not ready (%s)."):format(tostring(reason))) end
    local installed = installedInSlot(record, op.entry.slot)
    if op.action == "install" and installed then return abort(op, "that slot is already taken.") end
    if op.action == "remove" and not installed then return abort(op, "nothing left to remove in that slot.") end
    op.countBefore = #installedList(record)

    if op.action == "install" then
        local holder, why = boxHolder(op.ripper, op.patient, op.entry.box)
        if not holder then
            return abort(op, why == "inventory_offline" and "the stock system (rp_inventory) is offline." or ("no boxed %s left."):format(op.entry.label))
        end
        local ok, err = takeBox(holder, op.entry.box)
        if not ok then return abort(op, ("the box could not be taken from the pockets (%s)."):format(tostring(err))) end
        op.boxHolder, op.boxTaken = holder, true
    end

    local paidVia, why = takePayment(op.patient, op.price, "implant:" .. op.entry.key)
    if not paidVia then return abort(op, ("the patient cannot pay %s (%s)."):format(money(op.price), tostring(why))) end
    op.paidVia = paidVia

    local operationId, err = Open77.cyberware.newOperationId()
    if not operationId then return abort(op, ("no operation id (%s)."):format(tostring(err))) end
    op.operationId = operationId
    local options = { expectedRevision = record.revision, operationId = operationId }
    local result
    if op.action == "install" then
        result, err = Open77.cyberware.install(op.patient, op.entry.definitionId, op.grade.id, options)
    else
        options.slot = op.entry.slot
        result, err = Open77.cyberware.remove(op.patient, options)
    end
    if not result then return abort(op, ("the clinic refused the procedure (%s)."):format(tostring(err))) end
    if result.ticket then
        op.ticket = result.ticket
        tickets[result.ticket] = op
        op.phase = "pending"
        say(op.ripper, "Closing up. Waiting for the chrome to settle...")
    else
        complete(op, { ok = true })
    end
end

AddEventHandler("onCyberwareOperationCompleted", function(playerId, ticket, encoded)
    local op = tickets[ticket]
    if not op then return end
    local result = type(encoded) == "string" and json.decode(encoded) or encoded
    if type(result) ~= "table" then result = { ok = false, error = "invalid_result" } end
    complete(op, result)
end)

local function runProgress(op, pid, role)
    CreateThread(function()
        local answer, reason = uikit("progress", pid, {
            label = op.progressLabel,
            duration = op.durationMs,
            position = "bottom",
            style = "bar",
            color = "#B57BFF",
            cancellable = true,
            cancelKey = "X",
            disable = { move = true, combat = true },
        })
        if answer == nil then
            log(("progress bar not shown to player %s: %s"):format(tostring(pid), tostring(reason)))
            return
        end
        if answer.outcome == "cancelled" and op.phase == "surgery" and ops[op.id] == op then
            Open77.playerInteractions.cancel(op.id, "aborted_by_" .. role)
        end
    end)
end

local function eventState(state)
    if type(state) == "string" then state = json.decode(state) end
    return type(state) == "table" and state or nil
end

AddEventHandler("onPlayerInteractionStarted", function(state)
    state = eventState(state)
    local op = state and ops[state.id]
    if not op then return end
    op.phase = "surgery"
    -- The injector in the ripper's hand for the whole operation (Stage.surgery, prop only).
    op.toolHold = stageHold(op.ripper, "surgery")
    say(op.patient, ("%s accepted. Under the knife for %d s - press X to abort."):format("Quote", seconds(op.durationMs)))
    say(op.ripper, ("%s accepted the quote. Operating for %d s - press X to abort."):format(playerName(op.patient), seconds(op.durationMs)))
    runProgress(op, op.ripper, "ripper")
    runProgress(op, op.patient, "patient")
end)

AddEventHandler("onPlayerInteractionCompleted", function(state)
    state = eventState(state)
    local op = state and ops[state.id]
    if not op then return end
    finalize(op)
end)

local function cancelText(reason)
    reason = tostring(reason or "")
    if reason:find("aborted_by_ripper") then return "the ripper stopped." end
    if reason:find("aborted_by_patient") then return "the patient stopped." end
    if reason:find("ripper_off_duty") then return "the ripper clocked out." end
    if reason:find("declin") or reason:find("reject") then return "the patient declined the quote." end
    if reason:find("timeout") or reason:find("expired") then return "the quote expired unanswered." end
    if reason:find("far") or reason:find("moved") or reason:find("distance") then return "somebody walked away." end
    if reason:find("dead") or reason:find("death") or reason:find("alive") then return "somebody flatlined." end
    if reason:find("disconnect") then return "somebody left the server." end
    if reason:find("vehicle") then return "somebody got into a vehicle." end
    return ("cancelled (%s)."):format(reason ~= "" and reason or "unknown")
end

AddEventHandler("onPlayerInteractionCancelled", function(state)
    state = eventState(state)
    local op = state and ops[state.id]
    if not op then return end
    if op.phase == "committing" or op.phase == "pending" or op.phase == "done" then return end
    local text = cancelText(state.reason)
    op.phase = "cancelled"
    say(op.ripper, "No procedure: " .. text)
    say(op.patient, "No procedure: " .. text)
    log(("op %s cancelled: %s"):format(tostring(op.id), tostring(state.reason)))
    cleanup(op)
    reLie(op.patient)
end)

---------------------------------------------------------------------------
-- The catalogue menu and the quote
---------------------------------------------------------------------------
local function catalogueOptions(ripper, patient, record)
    local options = {}
    for _, entry in ipairs(cfg.catalogue) do
        local installed = installedInSlot(record, entry.slot)
        if installed then
            local text = describeImplant(installed)
            options[#options + 1] = {
                id = "remove_" .. entry.key,
                label = "Remove " .. entry.label,
                description = ("Installed: %s. %d s under the knife."):format(text, seconds(entry.grades[1].durationMs)),
                tone = "danger",
                metadata = { { label = "Price", value = money(removalPrice(entry, installed)) } },
            }
        else
            local holder, n = boxHolder(ripper, patient, entry.box)
            local stock = holder == ripper and ("yours x" .. tostring(n))
                or holder == patient and ("patient's x" .. tostring(n))
                or (n == "inventory_offline" and "inventory offline" or "none")
            local offline = not defined[entry.key]
            for _, grade in ipairs(entry.grades) do
                options[#options + 1] = {
                    id = ("install_%s_%s"):format(entry.key, grade.id),
                    label = ("%s - %s"):format(entry.label, grade.label),
                    description = offline
                        and ("Provider offline: %s"):format(tostring(defineReason[entry.key]))
                        or ("Install, %d s under the knife. Box: %s."):format(seconds(grade.durationMs), stock),
                    disabled = offline or holder == nil,
                    metadata = {
                        { label = "Price", value = money(grade.price) },
                        { label = "Grade", value = grade.label },
                        { label = "Stock", value = stock },
                        { label = "Time", value = seconds(grade.durationMs) .. " s" },
                    },
                }
            end
        end
    end
    options[#options + 1] = { id = "close", label = "Close the catalogue" }
    return options
end

-- Option ids are "remove_<key>" and "install_<key>_<gradeId>"; keys are matched
-- against the catalogue (longest first) so a key may itself carry an underscore.
local function parseChoice(id)
    if type(id) ~= "string" then return nil end
    local action, rest = id:match("^(%a+)_(.+)$")
    if action ~= "install" and action ~= "remove" then return nil end
    local best, bestGrade
    for _, entry in ipairs(cfg.catalogue) do
        local key = entry.key
        if action == "remove" and rest == key then
            best = entry
        elseif action == "install" and rest:sub(1, #key + 1) == key .. "_" then
            if not best or #key > #best.key then
                best, bestGrade = entry, rest:sub(#key + 2)
            end
        end
    end
    if not best then return nil end
    return action, best.key, bestGrade
end

local INTERACTION_REASONS = {
    animation_busy = "the patient is in another animation - ask them to press E on the chair again.",
    player_reserved = "one of you is already in an interaction.",
    too_far = "get within 4 m of the patient.",
    wrong_bucket = "you are not in the same world as the patient.",
    player_in_vehicle = "nobody operates inside a vehicle.",
    player_not_alive = "one of you is not alive enough for this.",
    player_not_ready = "the patient is not ready yet.",
    unknown_animation = "an RP animation profile is missing on this server (RP archive).",
}

-- The whole ripper-side flow: checks, catalogue, quote. Runs in a handler task.
local function startOperate(ripper, patient)
    if not jobsAvailable() then say(ripper, "The jobs service (rp_jobs) is offline: nobody can operate.") return end
    if not hasRipperJob(ripper) then say(ripper, "You are no ripperdoc. Only a ripper on duty can operate.") return end
    if not isRipperOnDuty(ripper) then say(ripper, "Clock in first: /service.") return end
    if not isPlayer(patient) then say(ripper, "No such patient. /players for the ids.") return end
    if patient == ripper then say(ripper, "Operating on yourself? Not even in Night City.") return end
    if opByPlayer[ripper] then say(ripper, "You are already in the middle of a procedure.") return end
    if opByPlayer[patient] then say(ripper, "That patient is already being operated on.") return end
    if not onChair[patient] then
        say(ripper, ("%s must lie on the ripperdoc chair first (E on the chair)."):format(playerName(patient)))
        return
    end
    local d, why = distanceBetween(ripper, patient)
    if not d then say(ripper, why == "wrong_bucket" and "You are not in the same world as the patient." or "Positions unknown, try again.") return end
    if d > cfg.operateDistance then say(ripper, ("Get within %d m of the patient (%.1f m)."):format(cfg.operateDistance, d)) return end
    if not inClinic(ripper) then say(ripper, ("Operate inside the clinic (%s zone)."):format(cfg.clinicZone)) return end
    local busy = Open77.playerInteractions.current(patient)
    if busy then say(ripper, "The patient is busy with another interaction.") return end

    local record, reason = Open77.cyberware.current(patient)
    if not record then
        say(ripper, ("%s's implant record is not ready (%s). Give it a second."):format(playerName(patient), tostring(reason)))
        return
    end

    local answer, err = uikit("context", ripper, {
        id = "rp_ripperdoc_catalogue",
        title = ("Ripperdoc - %s"):format(playerName(patient)),
        description = ("%d implant(s) installed. Pick a procedure; the patient gets a quote."):format(#installedList(record)),
        options = catalogueOptions(ripper, patient, record),
    })
    if answer == nil then say(ripper, "The catalogue could not open: " .. tostring(err)) return end
    if not answer.ok then return end
    local action, key, gradeId = parseChoice(answer.value and answer.value.id)
    if action ~= "install" and action ~= "remove" then return end
    local entry = entryByKey(key)
    if not entry then return end

    -- Re-check after the menu: a menu is a long time in Night City.
    if opByPlayer[ripper] or opByPlayer[patient] then say(ripper, "Somebody started a procedure in the meantime.") return end
    if not onChair[patient] then say(ripper, ("%s got off the chair."):format(playerName(patient))) return end
    if not isRipperOnDuty(ripper) then say(ripper, "You clocked out.") return end
    record = Open77.cyberware.current(patient)
    if not record then say(ripper, "The patient's implant record went away. Try again.") return end

    local op = { ripper = ripper, patient = patient, entry = entry, action = action, phase = "quote" }
    local installed = installedInSlot(record, entry.slot)
    if action == "install" then
        if installed then say(ripper, ("%s already has something in the %s slot. Remove it first."):format(playerName(patient), entry.slot)) return end
        op.grade = gradeOf(entry, gradeId)
        if not op.grade then return end
        if not defined[entry.key] then say(ripper, ("%s is not available on this server (%s)."):format(entry.label, tostring(defineReason[entry.key]))) return end
        local holder, stockWhy = boxHolder(ripper, patient, entry.box)
        if not holder then
            say(ripper, stockWhy == "inventory_offline" and "The stock system (rp_inventory) is offline." or ("No boxed %s in your pockets nor in the patient's. /ripper restock %s."):format(entry.label, entry.key))
            return
        end
        op.price = op.grade.price
        op.durationMs = op.grade.durationMs
        op.progressLabel = ("Installing %s"):format(entry.label)
        op.quote = ("install %s [%s] for %s"):format(entry.label, op.grade.label, money(op.price))
    else
        if not installed then say(ripper, ("Nothing to remove in %s's %s slot."):format(playerName(patient), entry.slot)) return end
        local text = describeImplant(installed)
        op.price = removalPrice(entry, installed)
        op.durationMs = entry.grades[1].durationMs
        op.progressLabel = ("Removing %s"):format(entry.label)
        op.quote = ("remove %s for %s"):format(text, money(op.price))
    end
    if not canAfford(patient, op.price) then
        say(ripper, ("%s cannot afford %s (account or cash). No quote sent."):format(playerName(patient), money(op.price)))
        return
    end

    -- The chair posture would answer animation_busy to the coordinator: stop it,
    -- the quote interaction plays the surgery postures itself.
    standUp(patient)
    local threshold = tonumber(cfg.cyberpsychosisThreshold) or 4
    local count = #installedList(record)
    local state, reqErr = Open77.playerInteractions.request(ripper, patient, "custom", {
        durationMs = op.durationMs + 1500,
        startDistance = cfg.operateDistance,
        breakDistance = math.min(cfg.operateDistance + 2.0, 20.0),
        inviteTimeoutMs = cfg.quoteTimeoutMs,
        consent = true,
        actorAnimation = cfg.animations.surgeryRipper,
        targetAnimation = cfg.animations.surgeryPatient,
    })
    if not state then
        say(ripper, "No quote sent: " .. (INTERACTION_REASONS[reqErr] or tostring(reqErr)))
        reLie(patient)
        return
    end
    op.id = state.id
    op.phase = "offered"
    ops[op.id] = op
    opByPlayer[ripper] = op
    opByPlayer[patient] = op

    local risk = action == "install"
        and ((count + 1 > threshold) and ("cyberpsychosis: this would be implant %d, past the %d threshold"):format(count + 1, threshold)
             or ("cyberpsychosis past %d implants (you carry %d)"):format(threshold, count))
        or "none, the slot goes back to stock parts"
    say(patient, ("QUOTE from %s: %s. %d s under the knife. Risk: %s. Answer on screen, or /interaction accept | /interaction decline (%d s)."):format(
        playerName(ripper), op.quote, seconds(op.durationMs), risk, seconds(cfg.quoteTimeoutMs)))
    toast(patient, "warning", "Ripperdoc quote", ("%s - %s. Accept or decline."):format(playerName(ripper), op.quote), cfg.quoteTimeoutMs)
    say(ripper, ("Quote sent to %s: %s. Waiting for consent (%d s)."):format(playerName(patient), op.quote, seconds(cfg.quoteTimeoutMs)))
    log(("op %s offered: %s %s, %d eddies, player %d -> player %d"):format(op.id, action, entry.key, op.price, ripper, patient))
end

RegisterNetEvent("rp_ripperdoc:operate", function(target)
    local ripper = source
    if type(ripper) ~= "number" or ripper <= 0 then return end
    -- A positive integer only: Open77.players.* raise on anything else (math.floor keeps a float).
    local patient = math.tointeger(tonumber(target))
    if not patient or patient < 1 then say(ripper, "No patient selected.") return end
    startOperate(ripper, patient)
end)

---------------------------------------------------------------------------
-- Duty push to the client (the ALT+click predicate)
---------------------------------------------------------------------------
local function pushDuty(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then return end
    TriggerClientEvent("rp_ripperdoc:duty", pid, isRipperOnDuty(pid))
end

RegisterNetEvent("rp_ripperdoc:clientReady", function()
    local pid = source
    if type(pid) ~= "number" or pid <= 0 then return end
    pushDuty(pid)
end)

AddEventHandler("rp_jobs:duty", function(playerId, jobName, flag)
    local pid = tonumber(playerId)
    if not pid then return end
    pushDuty(pid)
    local op = opByPlayer[pid]
    if op and op.ripper == pid and not isRipperOnDuty(pid) and (op.phase == "offered" or op.phase == "surgery") then
        Open77.playerInteractions.cancel(op.id, "ripper_off_duty")
    end
end)

AddEventHandler("rp_jobs:changed", function(playerId)
    pushDuty(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = tonumber(playerId)
    if not pid then return end
    onChair[pid] = nil        -- the server cancels the animation itself
    stageClear(pid)
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local function implantLines(pid)
    local record, reason = Open77.cyberware.current(pid)
    if not record then
        return { ("Your implant record is not ready (%s). Try again in a moment."):format(tostring(reason)) }
    end
    local list = installedList(record)
    local lines = { ("Implants: %d installed (cyberpsychosis past %d)."):format(#list, tonumber(cfg.cyberpsychosisThreshold) or 4) }
    for _, slot in ipairs(SLOTS) do
        local implant = installedInSlot(record, slot)
        local entry = entryBySlot(slot)
        local slotLabel = entry and entry.label or slot
        if implant then
            lines[#lines + 1] = ("  %s: %s"):format(slot, describeImplant(implant))
        else
            lines[#lines + 1] = ("  %s: - (%s)"):format(slot, slotLabel)
        end
    end
    for _, item in ipairs(list) do
        local known = false
        for _, slot in ipairs(SLOTS) do if slot == item.slot then known = true end end
        if not known then lines[#lines + 1] = ("  %s: %s"):format(item.slot, describeImplant(item.implant)) end
    end
    return lines
end

local function sendLines(pid, lines)
    for i, line in ipairs(lines) do
        say(pid, line)
        if i < #lines then Wait(0) end   -- two sends in one tick arrive in the opposite order
    end
end

RegisterCommand("implants", function(source)
    if source == 0 then print(TAG .. " run it from the game") return end
    sendLines(source, implantLines(source))
end, false)

local function restock(ripper, key, countArg)
    local entry = key and entryByKey(key)
    if not entry then
        local keys = {}
        for _, e in ipairs(cfg.catalogue) do keys[#keys + 1] = e.key end
        say(ripper, "Usage: /ripper restock <" .. table.concat(keys, "|") .. "> [count]")
        return
    end
    local count = math.floor(tonumber(countArg) or 1)
    local maxCount = cfg.restockMaxCount or 5
    if count < 1 or count > maxCount then say(ripper, ("Count must be 1 to %d."):format(maxCount)) return end
    local unit = math.floor((entry.grades[1].price or 0) * (cfg.restockPriceFactor or 0.6))
    local total = unit * count
    local note = "restock:" .. entry.key
    local paid
    local okS, newSociety, sReason = pcall(function() return exports.rp_bank:societyRemove(cfg.society, total, note) end)
    if okS and newSociety then
        paid = "society"
    else
        local okC, newCash, cReason = pcall(function() return exports.rp_economy:remove(ripper, total, note) end)
        if okC and newCash then
            paid = "cash"
        elseif not okS and not okC then
            paid = "free"
        else
            say(ripper, ("Cannot pay %s for %d box(es): the %s society says %s, your cash says %s."):format(
                money(total), count, cfg.society, tostring(okS and sReason or "offline"), tostring(okC and cReason or "offline")))
            return
        end
    end
    local ok, reason = giveBox(ripper, entry.box, count)
    if not ok then
        if paid == "society" then pcall(function() return exports.rp_bank:societyAdd(cfg.society, total, "restock refund") end) end
        if paid == "cash" then pcall(function() return exports.rp_economy:add(ripper, total, "restock refund") end) end
        say(ripper, ("The boxes did not fit in your pockets (%s). Nothing charged."):format(tostring(reason)))
        return
    end
    say(ripper, ("Restocked %d x %s for %s (%s)."):format(count, cfg.items[entry.box].label, money(total),
        paid == "society" and ("paid by the " .. cfg.society .. " society") or paid == "cash" and "paid from your cash" or "on the house: no money system"))
    log(("player %d restocked %d x %s for %d (%s)"):format(ripper, count, entry.box, total, paid))
    gesture(ripper, "restock")
end

local function ripperOverview(pid)
    local lines = {}
    lines[#lines + 1] = ("RIPPERDOC %s - grade %s - %s."):format(playerName(pid), gradeLabelOf(pid), isRipperOnDuty(pid) and "ON DUTY" or "off duty (/service to clock in)")
    -- Patients on the chair.
    local patients = {}
    for patientId in pairs(onChair) do
        if isPlayer(patientId) then
            local d = distanceBetween(pid, patientId)
            patients[#patients + 1] = ("%s (id %d, %s)"):format(playerName(patientId), patientId, d and ("%.1f m"):format(d) or "elsewhere")
        end
    end
    lines[#lines + 1] = "On the chair: " .. (#patients > 0 and table.concat(patients, ", ") or "nobody.")
    local current = opByPlayer[pid]
    if current then lines[#lines + 1] = ("In progress: %s on %s (%s)."):format(current.quote or current.action, playerName(current.patient), current.phase) end
    -- Stock.
    local stock = {}
    for _, entry in ipairs(cfg.catalogue) do
        local ok, n = pcall(function() return exports.rp_inventory:count(pid, entry.box) end)
        if ok and (tonumber(n) or 0) > 0 then stock[#stock + 1] = ("%s x%d"):format(entry.label, tonumber(n)) end
    end
    lines[#lines + 1] = "Boxes in your pockets: " .. (#stock > 0 and table.concat(stock, ", ") or "none. /ripper restock <arms|legs|deck|ice|purge> [count].")
    -- Catalogue state.
    local cat = {}
    for _, entry in ipairs(cfg.catalogue) do
        cat[#cat + 1] = ("%s %s"):format(entry.key, defined[entry.key] and money(entry.grades[1].price) or ("OFFLINE " .. tostring(defineReason[entry.key])))
    end
    lines[#lines + 1] = "Catalogue: " .. table.concat(cat, ", ") .. "."
    local okSoc, society = pcall(function() return exports.rp_bank:society(cfg.society) end)
    if okSoc and type(society) == "table" then
        lines[#lines + 1] = ("Society %s: %s."):format(cfg.society, money(society.balance))
    end
    -- Today's log.
    local identifier = Open77.players.identifier(pid) or ("session:" .. tostring(pid))
    local since = math.floor(Open77.time.unix()) - 86400
    local rows = {}
    if store == "sql" then
        -- `.await` raises on a failed read; /ripper must still answer with the rest of the board.
        local okRows, fetched = pcall(Open77.database.query.await,
            "SELECT patient_name, implant, grade, action, price, `at` FROM rp_ripperdoc_operations WHERE ripper = ? AND `at` >= ? ORDER BY `at` DESC LIMIT 5",
            { identifier, since })
        local okTotal, total = pcall(Open77.database.scalar.await,
            "SELECT COUNT(*) FROM rp_ripperdoc_operations WHERE ripper = ? AND `at` >= ?", { identifier, since })
        if not okRows then log("operations log read failed: " .. tostring(fetched)) end
        rows = (okRows and type(fetched) == "table") and fetched or {}
        lines[#lines + 1] = ("Last 24 h: %s operation(s)."):format(tostring((okTotal and total) or #rows))
    else
        local total = 0
        for _, row in ipairs(memoryLog) do
            if row.ripper == identifier and (tonumber(row.at) or 0) >= since then
                total = total + 1
                if #rows < 5 then rows[#rows + 1] = { patient_name = row.patientName, implant = row.implant, grade = row.grade, action = row.action, price = row.price, at = row.at } end
            end
        end
        lines[#lines + 1] = ("Last 24 h: %d operation(s) (%s log)."):format(total, store == "kvp" and "kvp" or "memory")
    end
    for _, row in ipairs(rows) do
        local entry = entryByDefinition(row.implant)
        local ago = math.floor((Open77.time.unix() - (tonumber(row.at) or 0)) / 60)
        lines[#lines + 1] = ("  %s %s%s on %s - %s, %d min ago"):format(row.action, entry and entry.label or tostring(row.implant),
            (row.grade and row.grade ~= "") and (" [" .. row.grade .. "]") or "", tostring(row.patient_name), money(row.price), ago)
    end
    return lines
end

RegisterCommand("ripper", function(source, args)
    if source == 0 then print(TAG .. " run it from the game") return end
    local sub = args[1] and tostring(args[1]):lower() or nil
    if hasRipperJob(source) then
        if sub == "restock" then
            restock(source, args[2] and tostring(args[2]):lower() or nil, args[3])
            return
        end
        sendLines(source, ripperOverview(source))
        return
    end
    -- Patient view.
    local lines = implantLines(source)
    local rippers = rippersOnDuty()
    if #rippers == 0 then
        lines[#lines + 1] = "Rippers on duty: none. Nobody can give you a quote right now - come back later, choom."
    else
        local names = {}
        for _, id in ipairs(rippers) do names[#names + 1] = playerName(id) end
        lines[#lines + 1] = ("Rippers on duty: %s. Lie on the chair (E) at the black market and ask for a quote."):format(table.concat(names, ", "))
    end
    if onChair[source] then lines[#lines + 1] = "You are on the ripperdoc chair." end
    sendLines(source, lines)
end, false)

RegisterCommand("operer", function(source, args)
    if source == 0 then print(TAG .. " run it from the game") return end
    local patient = math.tointeger(tonumber(args[1]))
    if not patient or patient < 1 then say(source, "Usage: /operer <playerId> - the patient must lie on the chair.") return end
    startOperate(source, patient)
end, false)

---------------------------------------------------------------------------
-- Exports (server, synchronous, never yield): read-only views for other resources
---------------------------------------------------------------------------
exports("isOnChair", function(playerId)
    local pid = tonumber(playerId)
    return pid ~= nil and onChair[pid] ~= nil
end)

exports("implantCount", function(playerId)
    local pid = tonumber(playerId)
    if not pid or pid <= 0 then return nil, "invalid_player_id" end
    local record, reason = Open77.cyberware.current(pid)
    if not record then return nil, reason or "record_not_ready" end
    return #installedList(record)
end)

exports("catalogue", function()
    local list = {}
    for _, entry in ipairs(cfg.catalogue) do
        local grades = {}
        for _, grade in ipairs(entry.grades) do
            grades[#grades + 1] = { id = grade.id, label = grade.label, price = grade.price, durationMs = grade.durationMs }
        end
        list[#list + 1] = {
            key = entry.key, label = entry.label, slot = entry.slot, profile = entry.profile,
            definitionId = entry.definitionId, box = entry.box,
            available = defined[entry.key] == true, reason = defineReason[entry.key],
            grades = grades,
        }
    end
    return list
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local SUGGESTIONS = {
    { command = "ripper", help = "Ripperdoc: patients on the chair, stock, today's log - patients: your implants",
      parameters = { { name = "restock <implant> [count]", help = "ripper only: buy boxes for the clinic" } } },
    { command = "operer", help = "Ripperdoc on duty: operate on the patient lying on the chair",
      parameters = { { name = "playerId", help = "the patient" } } },
    { command = "implants", help = "Your installed implants, as the platform reports them", parameters = {} },
}

RegisterNetEvent("chat:ready", function()
    local pid = source
    if type(pid) ~= "number" or pid <= 0 then return end
    Open77.chat.addSuggestions(pid, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name == RESOURCE then
        defineCatalogue()
        defineItems()
        setupStore()
        Open77.chat.addSuggestions(-1, SUGGESTIONS)
        for _, pid in ipairs(Open77.players.all()) do pushDuty(pid) end
        log(("started: %d implants in the catalogue, chair at %.1f %.1f %.1f (zone %s), threshold %d implants"):format(
            #cfg.catalogue, cfg.chair.position.x, cfg.chair.position.y, cfg.chair.position.z,
            tostring(cfg.clinicZone), tonumber(cfg.cyberpsychosisThreshold) or 4))
    elseif name == "rp_inventory" then
        defineItems()
    elseif name == "open77_cyberware" or name == "open77_hacking" then
        defineCatalogue()
    elseif name == "rp_jobs" then
        for _, pid in ipairs(Open77.players.all()) do pushDuty(pid) end
    end
end)
