-- rp_ncpd - the NCPD for a Night City RP server (build 2.31.13+op77.76).
-- Server-authoritative: every police action is checked here (job `ncpd` AND on duty through
-- rp_jobs); the client only shows ALT+click actions and renders blips / input blocks.
--
-- Holds (cuff / escort) are the platform's open77_rp_basics, never reimplemented.
-- Money goes through rp_bank (society `ncpd`) and rp_economy (cash); items through rp_inventory.
-- Persistence: SQL first (rp_ncpd_records, rp_ncpd_warrants, rp_ncpd_fines, rp_ncpd_sentences),
-- Open77.kvp only when the server has no database (said in the log). Exports never yield.

local RES = "rp_ncpd"
local DB = Open77.database

local C = Config

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------

local store = { mode = nil, reason = nil }        -- "sql" | "kvp"
local records = {}       -- identifier -> { loaded = bool, entries = { { kind, text, officerName, at }, ... } }
local warrants = {}      -- identifier -> { level, reason, kind ("manual"|"fine"), officerName, at, name }
local fines = {}         -- identifier -> { { id, amount, remaining, reason, officerName, at }, ... } unpaid only
local sentences = {}     -- identifier -> { playerId|nil, remaining, total, officerName, startedAt, sinceNotify, sincePersist }
local pendingFines = {}  -- interactionId -> { officer, citizen, amount, reason, consented, settled }
local grantedRights = {} -- playerId -> true while this resource granted rp.* to the player
local voiceChannel = nil
local voiceWarned = false
local kvpFineSeq = 0

local function log(fmt, ...)
    print(("[%s] " .. fmt):format(RES, ...))
end

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------

local function say(playerId, text, color)
    if type(playerId) ~= "number" then return end
    Open77.chat.send(playerId, { type = "system", author = "NCPD", text = text, color = color or C.colors.ncpd })
end

local function notify(playerId, kind, title, message, durationMs)
    if type(playerId) ~= "number" then return end
    Open77.notifications.send(playerId, {
        type = kind or "info", title = title, message = message, icon = "NCPD",
        durationMs = durationMs or 6000,
    })
end

local function identifierOf(playerId)
    -- Open77.players.identifier raises for id <= 0 or a non-integer (console actors and the
    -- "system" officer 0 reach this through addRecordFor / setWarrantFor).
    if type(playerId) ~= "number" or playerId < 1 or playerId % 1 ~= 0 then return nil end
    return Open77.players.identifier(playerId)
end

local function nameOf(playerId)
    if type(playerId) ~= "number" then return "Night City" end
    if playerId < 1 or playerId % 1 ~= 0 then return "Dispatch" end
    local ok, full = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(playerId) or ("citizen #" .. playerId)
end

local function shortIdent(identifier)
    if type(identifier) ~= "string" then return "?" end
    if #identifier <= 12 then return identifier end
    return identifier:sub(1, 8) .. ".."
end

local function playerByIdentifier(identifier)
    for _, id in ipairs(Open77.players.all()) do
        if Open77.players.identifier(id) == identifier then return id end
    end
    return nil
end

-- UTC date from unix seconds; the sandbox has no os.date (Howard Hinnant's civil_from_days).
local function formatDate(unix)
    unix = math.floor(tonumber(unix) or 0)
    local days = unix // 86400
    local secs = unix - days * 86400
    local z = days + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return ("%04d-%02d-%02d %02d:%02d"):format(y, m, d, secs // 3600, (secs % 3600) // 60)
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local m, s = seconds // 60, seconds % 60
    if m >= 1 then return ("%d min %02d s"):format(m, s) end
    return ("%d s"):format(s)
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clean(text, max)
    text = trim(text):gsub("[%c]", "")
    if #text > max then text = text:sub(1, max) end
    return text
end

local function copyEntries(list)
    local out = {}
    for i, e in ipairs(list or {}) do
        out[i] = { kind = e.kind, text = e.text, officer = e.officerName, at = e.at, date = formatDate(e.at) }
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Cross-resource reads (every rp_* export is reached through pcall: they raise when missing)
-- ---------------------------------------------------------------------------------------------

local function hasNcpdJob(playerId)
    local ok, has = pcall(function() return exports.rp_jobs:hasJob(playerId, "ncpd") end)
    return ok and has == true
end

local function onDuty(playerId)
    local ok, duty = pcall(function() return exports.rp_jobs:onDuty(playerId) end)
    return ok and duty == true
end

local function isOfficer(playerId)
    return type(playerId) == "number" and playerId > 0 and hasNcpdJob(playerId) and onDuty(playerId)
end

local function officersOnDuty()
    local ok, list = pcall(function() return exports.rp_jobs:listOnDuty("ncpd") end)
    if not ok or type(list) ~= "table" then return {} end
    local out = {}
    for _, id in ipairs(list) do
        id = tonumber(id)
        if id then out[#out + 1] = id end
    end
    return out
end

local function isMedic(playerId)
    local ok, has = pcall(function() return exports.rp_jobs:hasJob(playerId, "trauma") end)
    return ok and has == true
end

-- The RP kit's standing hold on a player, or nil (shape is the kit's; only "is held" is relied on).
local function kitHold(targetId)
    local ok, hold = pcall(function() return exports.open77_rp_basics:state(targetId) end)
    if ok and type(hold) == "table" then return hold end
    return nil
end

local function kitVerb(hold)
    if type(hold) ~= "table" then return nil end
    return hold.verb or hold.kind or hold.action or "held"
end

-- One closure per verb: the export proxy drops the `self` a colon inserts, so the verbs are
-- spelled out rather than indexed by name.
local KIT = {
    cuff = function(officerId, targetId) return exports.open77_rp_basics:cuff(officerId, targetId) end,
    escort = function(officerId, targetId) return exports.open77_rp_basics:escort(officerId, targetId) end,
    release = function(targetId, byPlayerId, reason) return exports.open77_rp_basics:release(targetId, byPlayerId, reason) end,
}

local function kitCall(verb, ...)
    local ok, res, reason = pcall(KIT[verb], ...)
    if not ok then return nil, "rp_kit_offline" end
    if res == nil or res == false then return nil, reason or "refused" end
    return res
end

local KIT_REASONS = {
    rp_kit_offline = "The RP kit (open77_rp_basics) is not running on this server.",
    not_authorised = "Your badge is not on the ACL (rp.cuff / rp.escort / rp.search). Clock in again or ask the operator.",
    too_far = "Get closer, choom.",
    target_not_alive = "They are in no state for that.",
    target_dead = "They are in no state for that.",
    officer_not_alive = "You are in no state for that.",
    already_held = "They are already held.",
    not_held = "They are not held by anyone.",
    not_holder = "Somebody else holds them.",
    wrong_bucket = "Not in your world.",
    player_not_ready = "They are not in the world yet.",
    position_stale = "Cannot read their position right now. Try again.",
}

local function kitWhy(reason)
    return KIT_REASONS[reason] or ("The RP kit refused: " .. tostring(reason))
end

-- Hands up = the `handsup` RP profile is the running step of the player's authoritative playback.
local function handsUp(playerId)
    local state = Open77.animations.current(playerId)
    if type(state) ~= "table" or state.active == false then return false end
    local steps = state.steps
    if type(steps) ~= "table" then return false end
    local step = steps[(tonumber(state.step) or 0) + 1]
    if type(step) == "table" and step.profile == "handsup" then return true end
    for _, s in ipairs(steps) do
        if type(s) == "table" and s.profile == "handsup" then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Storage: SQL first, kvp only when the database never comes
-- ---------------------------------------------------------------------------------------------

local Store = {}

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS rp_ncpd_records (
        id INT AUTO_INCREMENT PRIMARY KEY,
        identifier VARCHAR(64) NOT NULL,
        kind VARCHAR(32) NOT NULL,
        text VARCHAR(255) NOT NULL DEFAULT '',
        officer VARCHAR(64) NOT NULL DEFAULT '',
        officer_name VARCHAR(80) NOT NULL DEFAULT '',
        created_at BIGINT NOT NULL DEFAULT 0,
        INDEX rp_ncpd_records_identifier (identifier)
    )]],
    [[CREATE TABLE IF NOT EXISTS rp_ncpd_warrants (
        identifier VARCHAR(64) PRIMARY KEY,
        level TINYINT NOT NULL DEFAULT 1,
        reason VARCHAR(255) NOT NULL DEFAULT '',
        kind VARCHAR(16) NOT NULL DEFAULT 'manual',
        officer VARCHAR(64) NOT NULL DEFAULT '',
        officer_name VARCHAR(80) NOT NULL DEFAULT '',
        citizen_name VARCHAR(80) NOT NULL DEFAULT '',
        created_at BIGINT NOT NULL DEFAULT 0
    )]],
    [[CREATE TABLE IF NOT EXISTS rp_ncpd_fines (
        id INT AUTO_INCREMENT PRIMARY KEY,
        identifier VARCHAR(64) NOT NULL,
        amount INT NOT NULL,
        remaining INT NOT NULL,
        reason VARCHAR(255) NOT NULL DEFAULT '',
        officer VARCHAR(64) NOT NULL DEFAULT '',
        officer_name VARCHAR(80) NOT NULL DEFAULT '',
        created_at BIGINT NOT NULL DEFAULT 0,
        paid_at BIGINT NOT NULL DEFAULT 0,
        INDEX rp_ncpd_fines_identifier (identifier)
    )]],
    [[CREATE TABLE IF NOT EXISTS rp_ncpd_sentences (
        identifier VARCHAR(64) PRIMARY KEY,
        remaining INT NOT NULL,
        total_minutes INT NOT NULL,
        officer VARCHAR(64) NOT NULL DEFAULT '',
        officer_name VARCHAR(80) NOT NULL DEFAULT '',
        started_at BIGINT NOT NULL DEFAULT 0
    )]],
}

local function kvpGet(key, default)
    local raw = Open77.kvp.get(key)
    if type(raw) ~= "string" or raw == "" then return default end
    local value = json.decode(raw)
    if value == nil then return default end
    return value
end

local function kvpSet(key, value)
    local ok, reason = Open77.kvp.set(key, json.encode(value))
    if not ok then log("kvp write failed for %s: %s", key, tostring(reason)) end
end

-- Records ---------------------------------------------------------------------------------------

function Store.loadRecords(identifier, cb)
    if store.mode == "sql" then
        DB.query("SELECT kind, text, officer_name, created_at FROM rp_ncpd_records WHERE identifier = ? ORDER BY id DESC LIMIT 200",
            { identifier }, function(rows)
                if type(rows) ~= "table" then cb(nil, "sql_error") return end
                local list = {}
                for _, r in ipairs(rows) do
                    list[#list + 1] = { kind = r.kind, text = r.text, officerName = r.officer_name, at = tonumber(r.created_at) or 0 }
                end
                cb(list)
            end)
    else
        cb(kvpGet("rec:" .. identifier, {}))
    end
end

function Store.addRecord(identifier, entry, officerIdent)
    if store.mode == "sql" then
        DB.insert("INSERT INTO rp_ncpd_records (identifier, kind, text, officer, officer_name, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            { identifier, entry.kind, entry.text, officerIdent or "", entry.officerName or "", entry.at }, function() end)
    else
        local list = kvpGet("rec:" .. identifier, {})
        table.insert(list, 1, entry)
        while #list > 200 do table.remove(list) end
        kvpSet("rec:" .. identifier, list)
    end
end

-- Warrants (all open warrants are cached at boot) ---------------------------------------------

function Store.loadWarrants(cb)
    if store.mode == "sql" then
        DB.query("SELECT identifier, level, reason, kind, officer_name, citizen_name, created_at FROM rp_ncpd_warrants", {}, function(rows)
            local map = {}
            for _, r in ipairs(rows or {}) do
                map[r.identifier] = { level = tonumber(r.level) or 1, reason = r.reason, kind = r.kind,
                    officerName = r.officer_name, name = r.citizen_name, at = tonumber(r.created_at) or 0 }
            end
            cb(map)
        end)
    else
        cb(kvpGet("warrants", {}))
    end
end

function Store.setWarrant(identifier, w, officerIdent)
    if store.mode == "sql" then
        if w then
            DB.update("REPLACE INTO rp_ncpd_warrants (identifier, level, reason, kind, officer, officer_name, citizen_name, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                { identifier, w.level, w.reason, w.kind, officerIdent or "", w.officerName or "", w.name or "", w.at }, function() end)
        else
            DB.update("DELETE FROM rp_ncpd_warrants WHERE identifier = ?", { identifier }, function() end)
        end
    else
        kvpSet("warrants", warrants)
    end
end

-- Fines (unpaid rows are cached per online player) ---------------------------------------------

function Store.loadFines(identifier, cb)
    if store.mode == "sql" then
        DB.query("SELECT id, amount, remaining, reason, officer_name, created_at FROM rp_ncpd_fines WHERE identifier = ? AND remaining > 0 ORDER BY id ASC",
            { identifier }, function(rows)
                if type(rows) ~= "table" then cb(nil, "sql_error") return end
                local list = {}
                for _, r in ipairs(rows) do
                    list[#list + 1] = { id = tonumber(r.id), amount = tonumber(r.amount) or 0, remaining = tonumber(r.remaining) or 0,
                        reason = r.reason, officerName = r.officer_name, at = tonumber(r.created_at) or 0 }
                end
                cb(list)
            end)
    else
        cb(kvpGet("fines:" .. identifier, {}))
    end
end

function Store.addFine(identifier, fine, officerIdent)
    if store.mode == "sql" then
        DB.insert("INSERT INTO rp_ncpd_fines (identifier, amount, remaining, reason, officer, officer_name, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            { identifier, fine.amount, fine.remaining, fine.reason, officerIdent or "", fine.officerName or "", fine.at }, function(id)
                fine.id = tonumber(id) or fine.id
            end)
    else
        kvpFineSeq = kvpFineSeq + 1
        fine.id = fine.id or ("kvp" .. kvpFineSeq)
        kvpSet("fines:" .. identifier, fines[identifier] or {})
    end
end

function Store.updateFine(identifier, fine)
    if store.mode == "sql" then
        if fine.id then
            DB.update("UPDATE rp_ncpd_fines SET remaining = ?, paid_at = ? WHERE id = ?",
                { fine.remaining, fine.remaining <= 0 and math.floor(Open77.time.unix()) or 0, fine.id }, function() end)
        end
    else
        kvpSet("fines:" .. identifier, fines[identifier] or {})
    end
end

-- Sentences --------------------------------------------------------------------------------------

function Store.loadSentence(identifier, cb)
    if store.mode == "sql" then
        DB.single("SELECT remaining, total_minutes, officer_name, started_at FROM rp_ncpd_sentences WHERE identifier = ?", { identifier }, function(row)
            if type(row) ~= "table" then cb(nil) return end
            cb({ remaining = tonumber(row.remaining) or 0, total = tonumber(row.total_minutes) or 0,
                officerName = row.officer_name, startedAt = tonumber(row.started_at) or 0 })
        end)
    else
        cb(kvpGet("sentence:" .. identifier))
    end
end

function Store.setSentence(identifier, s, officerIdent)
    if store.mode == "sql" then
        if s then
            DB.update("REPLACE INTO rp_ncpd_sentences (identifier, remaining, total_minutes, officer, officer_name, started_at) VALUES (?, ?, ?, ?, ?, ?)",
                { identifier, math.max(0, math.floor(s.remaining)), s.total, officerIdent or "", s.officerName or "", s.startedAt }, function() end)
        else
            DB.update("DELETE FROM rp_ncpd_sentences WHERE identifier = ?", { identifier }, function() end)
        end
    else
        if s then
            kvpSet("sentence:" .. identifier, { remaining = math.max(0, math.floor(s.remaining)), total = s.total,
                officerName = s.officerName, startedAt = s.startedAt })
        else
            Open77.kvp.set("sentence:" .. identifier, "")
        end
    end
end

-- Boot -------------------------------------------------------------------------------------------

local function useKvp(reason)
    if store.mode then return end
    store.mode, store.reason = "kvp", reason
    log("store=kvp reason=%s (nothing reaches SQL until the server gets a database)", tostring(reason))
    warrants = kvpGet("warrants", {})
end

local function bootStore()
    local ok, reason = DB.ready(function()
        if store.mode == "kvp" then
            log("database came up after the kvp fallback was chosen; keeping kvp for this boot")
            return
        end
        for _, ddl in ipairs(SCHEMA) do
            DB.update.await(ddl, {})
        end
        store.mode = "sql"
        log("store=sql tables=rp_ncpd_records,rp_ncpd_warrants,rp_ncpd_fines,rp_ncpd_sentences")
        Store.loadWarrants(function(map)
            warrants = map or {}
            local n = 0
            for _ in pairs(warrants) do n = n + 1 end
            log("%d open warrant(s) loaded", n)
        end)
    end)
    if not ok then useKvp(reason) end
end

-- Wait for the store decision (bounded), for handlers that need a loaded player file.
local function waitForStore()
    local waited = 0
    while not store.mode and waited < 15000 do
        Wait(250)
        waited = waited + 250
    end
    if not store.mode then useKvp("database_not_answering") end
end

-- ---------------------------------------------------------------------------------------------
-- Records / warrants / fines (in-memory cache, written through)
-- ---------------------------------------------------------------------------------------------

local function ensureRecordCache(identifier)
    local r = records[identifier]
    if not r then
        r = { loaded = false, entries = {} }
        records[identifier] = r
    end
    return r
end

local function addRecordFor(identifier, kind, text, officerId)
    if type(identifier) ~= "string" or identifier == "" then return nil, "invalid_identifier" end
    kind = clean(kind, 32):lower()
    if not kind:match("^[a-z_]+$") then return nil, "invalid_kind" end
    text = clean(text, 255)
    local entry = { kind = kind, text = text, officerName = nameOf(officerId), at = math.floor(Open77.time.unix()) }
    local cache = ensureRecordCache(identifier)
    table.insert(cache.entries, 1, entry)
    Store.addRecord(identifier, entry, identifierOf(officerId))
    log("record %s %s: %s (by %s)", shortIdent(identifier), kind, text, entry.officerName)
    return true
end

local function setWarrantFor(playerId, identifier, level, reason, officerId, kind)
    level = math.floor(tonumber(level) or 0)
    if level < 0 or level > 5 then return nil, "invalid_level" end
    reason = clean(reason or "", 255)
    if level == 0 then
        if not warrants[identifier] then return nil, "no_warrant" end
        warrants[identifier] = nil
        Store.setWarrant(identifier, nil)
        addRecordFor(identifier, "warrant_lifted", reason ~= "" and reason or "warrant lifted", officerId)
        if playerId then
            say(playerId, "Your NCPD warrant has been lifted. Stay clean, choom.")
            if C.warrant.nativeHeat then Open77.players.setWanted(playerId, 0) end
        end
        return true
    end
    local existing = warrants[identifier]
    local w = { level = level, reason = reason, kind = kind or "manual", officerName = nameOf(officerId),
        name = playerId and nameOf(playerId) or (existing and existing.name) or "", at = math.floor(Open77.time.unix()) }
    warrants[identifier] = w
    Store.setWarrant(identifier, w, identifierOf(officerId))
    addRecordFor(identifier, "warrant", ("level %d - %s"):format(level, reason), officerId)
    if playerId then
        say(playerId, ("NCPD has a warrant on you (level %d): %s"):format(level, reason), C.colors.warn)
        notify(playerId, "warning", "NCPD warrant", ("Level %d - %s"):format(level, reason))
        if C.warrant.nativeHeat then
            local res, why = Open77.players.setWanted(playerId, level)
            if not res then log("native heat refused for %d: %s", playerId, tostring(why)) end
        end
    end
    return true
end

local function ensureFineCache(identifier)
    fines[identifier] = fines[identifier] or {}
    return fines[identifier]
end

local function totalUnpaid(identifier)
    local total = 0
    for _, f in ipairs(fines[identifier] or {}) do total = total + f.remaining end
    return total
end

-- ---------------------------------------------------------------------------------------------
-- Player file (records, fines, sentence) lifecycle
-- ---------------------------------------------------------------------------------------------

local jailResume -- forward

local function loadPlayer(playerId)
    local identifier = identifierOf(playerId)
    if not identifier then return end
    waitForStore()
    Store.loadRecords(identifier, function(list, reason)
        if not list then
            log("player %d records read failed: %s", playerId, tostring(reason))
            return
        end
        local cache = ensureRecordCache(identifier)
        cache.entries, cache.loaded = list, true
    end)
    Store.loadFines(identifier, function(list, reason)
        if not list then
            log("player %d fines read failed: %s", playerId, tostring(reason))
            return
        end
        fines[identifier] = list
        local due = totalUnpaid(identifier)
        if due > 0 then
            say(playerId, ("You owe NCPD %d €$ in unpaid fines. /amende payer settles them."):format(due), C.colors.warn)
        end
    end)
    Store.loadSentence(identifier, function(s)
        if not s or (tonumber(s.remaining) or 0) <= 0 then return end
        sentences[identifier] = { playerId = playerId, remaining = s.remaining, total = s.total, officerName = s.officerName,
            startedAt = s.startedAt, sinceNotify = 0, sincePersist = 0 }
        log("player %d resumes a sentence: %s left", playerId, formatDuration(s.remaining))
        jailResume(playerId, identifier)
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Duty: kit rights, voice channel, client flag
-- ---------------------------------------------------------------------------------------------

local function pushSelf(playerId)
    TriggerClientEvent("rp_ncpd:self", playerId, isOfficer(playerId))
end

local function ensureVoiceChannel()
    if voiceChannel or not C.voice.enabled then return voiceChannel end
    local channel, reason = Open77.voice.createChannel({ name = C.voice.channelName, mode = "radio", persistent = false, effect = C.voice.effect })
    if not channel then
        if not voiceWarned then
            voiceWarned = true
            log("voice channel not created: %s (radio stays text-only)", tostring(reason))
        end
        return nil
    end
    voiceChannel = channel
    log("voice channel %s created (%s)", tostring(channel.id), C.voice.channelName)
    return channel
end

local function grantRights(playerId)
    if not C.grantKitRights then return end
    local identity = Open77.players.identity(playerId)
    if not identity or not identity.userId then return end
    local granted = 0
    for _, right in ipairs(C.kitRights) do
        local ok, reason = Open77.acl.grant(identity.userId, right)
        if ok then granted = granted + 1 else log("acl grant %s for %d refused: %s", right, playerId, tostring(reason)) end
    end
    if granted > 0 then grantedRights[playerId] = true end
end

local function revokeRights(playerId)
    if not grantedRights[playerId] then return end
    grantedRights[playerId] = nil
    local identity = Open77.players.identity(playerId)
    if not identity or not identity.userId then return end
    for _, right in ipairs(C.kitRights) do
        local ok, reason = Open77.acl.revoke(identity.userId, right)
        if not ok and reason ~= "not_granted" then log("acl revoke %s for %d refused: %s", right, playerId, tostring(reason)) end
    end
end

local function applyDuty(playerId, duty)
    if duty then
        grantRights(playerId)
        local channel = ensureVoiceChannel()
        if channel then
            local ok, reason = Open77.voice.addPlayer(channel.id, playerId, { canSpeak = true, canListen = true })
            if not ok then log("voice add %d refused: %s", playerId, tostring(reason)) end
        end
    else
        revokeRights(playerId)
        if voiceChannel then Open77.voice.removePlayer(voiceChannel.id, playerId) end
    end
    pushSelf(playerId)
end

AddEventHandler("rp_jobs:duty", function(playerId, job, duty)
    playerId = tonumber(playerId)
    if not playerId then return end
    if job == "ncpd" or job == "police" then
        applyDuty(playerId, duty == true)
        if duty == true then
            say(playerId, "Badge on. ALT+click a citizen for the NCPD actions; /ncpd for the precinct status.")
        end
    else
        pushSelf(playerId)
    end
end)

AddEventHandler("rp_jobs:changed", function(playerId)
    playerId = tonumber(playerId)
    if playerId then
        if not isOfficer(playerId) then applyDuty(playerId, false) end
        pushSelf(playerId)
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Guards shared by the commands and the ALT+click actions
-- ---------------------------------------------------------------------------------------------

local function requireOfficer(source)
    if source == 0 then
        print("[rp_ncpd] run this from the game as an on-duty NCPD officer")
        return false
    end
    if not hasNcpdJob(source) then
        say(source, "You are not NCPD. No badge, no business.")
        return false
    end
    if not onDuty(source) then
        say(source, "You are off duty. /service to clock in first.")
        return false
    end
    if Open77.players.isDead(source) then
        say(source, "You are in no state for police work.")
        return false
    end
    return true
end

local function resolveTarget(source, raw, opts)
    opts = opts or {}
    local target = tonumber(raw)
    if not target or target < 1 or target % 1 ~= 0 then
        say(source, "Give a player id (see /players).")
        return nil
    end
    target = math.tointeger(target)  -- the natives refuse an integral float (2.0) as an id
    if target == source then
        say(source, "Not on yourself, officer.")
        return nil
    end
    local read = Open77.players.get(target)
    if not read then
        say(source, ("No player with id %d."):format(target))
        return nil
    end
    if not read.ready then
        say(source, "They are not in the world yet.")
        return nil
    end
    if Open77.players.isDead(target) then
        say(source, "They are down. Call Trauma Team, not the cuffs.")
        return nil
    end
    if opts.maxDistance then
        local metres = Open77.players.distance(source, target)
        if not metres then
            say(source, "Cannot read their position right now.")
            return nil
        end
        if metres > opts.maxDistance then
            say(source, ("Too far (%.0f m). Get within %.0f m."):format(metres, opts.maxDistance))
            return nil
        end
    end
    return target
end

-- ---------------------------------------------------------------------------------------------
-- Cuff / uncuff / escort (open77_rp_basics)
-- ---------------------------------------------------------------------------------------------

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

local STAGE = Config.Stage or {}
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

-- The cuffed pose held on a suspect (Config.Stage.cuffed), released with the hold.
local cuffedPose = {}   -- target -> stage entry

local function releaseCuffedPose(target)
    if cuffedPose[target] then stageRelease(target, cuffedPose[target]); cuffedPose[target] = nil end
end

local function doCuff(source, target)
    local hold = kitHold(target)
    if hold and kitVerb(hold) == "cuff" then
        say(source, "They are already cuffed.")
        return
    end
    -- Staged: the officer reaches for the wrists for the bar's length, then the kit holds.
    say(target, ("Officer %s is cuffing you. Hold still."):format(nameOf(source)), C.colors.warn)
    local done = stage(source, "cuff", { label = "Cuffing " .. nameOf(target) })
    if not done or not done.ok then
        say(source, "You let go of the cuffs.")
        return
    end
    local ok, reason = kitCall("cuff", source, target)
    if not ok then
        say(source, "Cannot cuff: " .. kitWhy(reason))
        return
    end
    releaseCuffedPose(target)
    cuffedPose[target] = stageHold(target, "cuffed")
    say(source, ("You cuffed %s."):format(nameOf(target)))
    say(target, ("Officer %s cuffed you. Hands where they can see them."):format(nameOf(source)), C.colors.warn)
    notify(target, "warning", "Cuffed", ("By officer %s"):format(nameOf(source)))
    log("player %d cuffed player %d", source, target)
end

local function doUncuff(source, target)
    local hold = kitHold(target)
    if not hold then
        say(source, "They are not held by anyone.")
        return
    end
    local ok, reason = kitCall("release", target, source, "released")
    if not ok then
        say(source, "Cannot release: " .. kitWhy(reason))
        return
    end
    releaseCuffedPose(target)
    say(source, ("You released %s."):format(nameOf(target)))
    say(target, ("Officer %s released you."):format(nameOf(source)))
    log("player %d released player %d", source, target)
end

local function doEscort(source, target)
    local hold = kitHold(target)
    if hold and kitVerb(hold) == "escort" then
        local ok, reason = kitCall("release", target, source, "released")
        if not ok then
            say(source, "Cannot stop escorting: " .. kitWhy(reason))
            return
        end
        releaseCuffedPose(target)
        say(source, ("You stopped escorting %s."):format(nameOf(target)))
        say(target, ("Officer %s let you go."):format(nameOf(source)))
        log("player %d stopped escorting player %d", source, target)
        return
    end
    local ok, reason = kitCall("escort", source, target)
    if not ok then
        say(source, "Cannot escort: " .. kitWhy(reason))
        return
    end
    say(source, ("You are escorting %s. Same action again to let them go."):format(nameOf(target)))
    say(target, ("Officer %s is escorting you. Walk."):format(nameOf(source)), C.colors.warn)
    log("player %d escorts player %d", source, target)
end

-- ---------------------------------------------------------------------------------------------
-- Search / seize (rp_inventory)
-- ---------------------------------------------------------------------------------------------

local function suspectCompliant(source, target)
    if kitHold(target) then return true end
    if handsUp(target) then return true end
    say(source, "They are neither cuffed nor surrendering. Cuff them, or wait for the hands up.")
    return false
end

local function contrabandOf(target)
    local ok, entries, weight, capacity = pcall(function() return exports.rp_inventory:list(target) end)
    if not ok or type(entries) ~= "table" then return nil, "inventory_offline" end
    local medic = isMedic(target)
    local illegal = {}
    for _, e in ipairs(entries) do
        local isIllegal = e.illegal == true
        if e.id == "implant_box" and medic then isIllegal = false end
        if isIllegal then illegal[#illegal + 1] = e end
    end
    return entries, illegal, weight, capacity
end

local function doSearch(source, target)
    if not suspectCompliant(source, target) then return end
    say(target, ("Officer %s is searching your pockets."):format(nameOf(source)), C.colors.warn)
    -- Staged: the officer bends over the suspect for the bar's length, then reads the pockets.
    local done = stage(source, "search", { label = "Searching " .. nameOf(target) })
    if not done or not done.ok then
        say(source, "You stop the search.")
        return
    end
    if not suspectCompliant(source, target) then return end
    local entries, illegal = contrabandOf(target)
    if not entries then
        say(source, "The pockets cannot be read: rp_inventory is not running.")
        return
    end
    local lines = {}
    if #entries == 0 then
        lines[#lines + 1] = ("%s's pockets are empty."):format(nameOf(target))
    else
        local flagged = {}
        for _, e in ipairs(illegal) do flagged[e.id] = true end
        local parts = {}
        for _, e in ipairs(entries) do
            parts[#parts + 1] = ("%s x%d%s"):format(e.label or e.id, e.count or 0, flagged[e.id] and " [ILLEGAL]" or "")
        end
        lines[#lines + 1] = ("%s carries: %s"):format(nameOf(target), table.concat(parts, ", "))
    end
    if #illegal > 0 then
        local names = {}
        for _, e in ipairs(illegal) do names[#names + 1] = ("%s x%d"):format(e.label or e.id, e.count or 0) end
        lines[#lines + 1] = ("Contraband: %s. Seize it with /fouille %d saisir (or ALT+click > Seize contraband)."):format(table.concat(names, ", "), target)
    else
        lines[#lines + 1] = "Nothing illegal on them."
    end
    for _, line in ipairs(lines) do
        say(source, line)
        Wait(0)
    end
    log("player %d searched player %d: %d item(s), %d illegal", source, target, #entries, #illegal)
end

-- Moves every illegal item into the officer's pockets (toOfficer) or destroys it (booking).
local function seizeContraband(source, target, toOfficer)
    local entries, illegal = contrabandOf(target)
    if not entries then return nil, "inventory_offline" end
    if #illegal == 0 then return {} end
    local moved = {}
    for _, e in ipairs(illegal) do
        local count = e.count or 0
        if count > 0 then
            local okRm, removed, whyRm = pcall(function() return exports.rp_inventory:remove(target, e.id, count) end)
            if okRm and removed then
                local where = "destroyed at booking"
                if toOfficer then
                    local okAdd, added, whyAdd = pcall(function() return exports.rp_inventory:add(source, e.id, count) end)
                    if okAdd and added then
                        where = "in your pockets"
                    else
                        where = ("dropped from the record (%s: your pockets refused it)"):format(tostring(whyAdd or "refused"))
                    end
                end
                moved[#moved + 1] = { id = e.id, label = e.label or e.id, count = count, where = where }
            else
                log("seize %s x%d from %d refused: %s", e.id, count, target, tostring(whyRm or "refused"))
            end
        end
    end
    return moved
end

local function doSeize(source, target)
    if not suspectCompliant(source, target) then return end
    local done = stage(source, "seize", { label = "Seizing from " .. nameOf(target) })
    if not done or not done.ok then
        say(source, "You leave their pockets alone.")
        return
    end
    if not suspectCompliant(source, target) then return end
    local moved, reason = seizeContraband(source, target, true)
    if not moved then
        say(source, "The pockets cannot be read: rp_inventory is not running.")
        return
    end
    if #moved == 0 then
        say(source, "Nothing illegal to seize.")
        return
    end
    local names = {}
    for _, m in ipairs(moved) do names[#names + 1] = ("%s x%d (%s)"):format(m.label, m.count, m.where) end
    local text = table.concat(names, ", ")
    say(source, ("Seized from %s: %s"):format(nameOf(target), text))
    say(target, ("Officer %s seized: %s"):format(nameOf(source), text), C.colors.warn)
    local identifier = identifierOf(target)
    if identifier then addRecordFor(identifier, "seizure", text, source) end
    log("player %d seized from player %d: %s", source, target, text)
end

-- ---------------------------------------------------------------------------------------------
-- Fines (open77_player_interactions consent, rp_bank charge, rp_economy cash, unpaid rows)
-- ---------------------------------------------------------------------------------------------

local function creditSociety(amount, reasonTag)
    pcall(function() exports.rp_bank:societyAdd("ncpd", amount, reasonTag) end)
end

local function settleFine(p, outcome)
    if p.settled then return end
    p.settled = true
    local officer, citizen, amount = p.officer, p.citizen, p.amount
    local identifier = identifierOf(citizen)
    local reasonTag = "fine:" .. p.reason
    local citizenName, officerName = nameOf(citizen), nameOf(officer)

    if outcome ~= "accepted" then
        say(citizen, ("You refused the %d €$ fine (%s). NCPD now has a warrant on you."):format(amount, p.reason), C.colors.warn)
        say(officer, ("%s refused the fine (%s). Warrant issued."):format(citizenName, outcome))
        if identifier then
            addRecordFor(identifier, "fine_refused", ("%d €$ - %s"):format(amount, p.reason), officer)
            local existing = warrants[identifier]
            local level = math.max(C.fine.autoWarrantLevel, existing and existing.level or 0)
            setWarrantFor(citizen, identifier, level, ("refused a %d €$ fine: %s"):format(amount, p.reason), officer, "fine")
        end
        return
    end

    local okCall, newBalance, why = pcall(function() return exports.rp_bank:charge(citizen, amount, "ncpd", reasonTag) end)
    if okCall and newBalance then
        say(citizen, ("Fine paid from your account: %d €$ (%s). Account: %d €$."):format(amount, p.reason, newBalance))
        say(officer, ("%s paid the %d €$ fine from their account."):format(citizenName, amount))
        if identifier then addRecordFor(identifier, "fine", ("%d €$ - %s (paid, account)"):format(amount, p.reason), officer) end
        log("fine %d paid by player %d (account) reason=%s officer=%d", amount, citizen, p.reason, officer)
        return
    end
    local reason = okCall and (why or "refused") or "bank_offline"
    local paid = 0
    if reason == "insufficient_funds" or reason == "bank_offline" or reason == "bank_not_ready" or reason == "player_not_found" then
        local okCash, cash = pcall(function() return exports.rp_economy:getBalance(citizen) end)
        cash = okCash and tonumber(cash) or 0
        local take = math.min(math.floor(cash), amount)
        if take > 0 then
            local okRm, nb = pcall(function() return exports.rp_economy:remove(citizen, take, reasonTag) end)
            if okRm and nb then
                paid = take
                creditSociety(take, reasonTag)
            end
        end
    else
        say(officer, ("The bank refused the charge (%s)."):format(reason))
    end
    local remaining = amount - paid
    if paid > 0 then
        say(citizen, ("Fine: %d €$ taken from your cash (%s)."):format(paid, p.reason))
    end
    if remaining > 0 then
        local fine = { amount = amount, remaining = remaining, reason = p.reason, officerName = officerName, at = math.floor(Open77.time.unix()) }
        if identifier then
            table.insert(ensureFineCache(identifier), fine)
            Store.addFine(identifier, fine, identifierOf(officer))
            addRecordFor(identifier, "fine", ("%d €$ - %s (unpaid: %d €$)"):format(amount, p.reason, remaining), officer)
            local existing = warrants[identifier]
            local level = math.max(C.fine.autoWarrantLevel, existing and existing.level or 0)
            setWarrantFor(citizen, identifier, level, ("unpaid fine: %d €$ - %s"):format(remaining, p.reason), officer, "fine")
        end
        say(citizen, ("You still owe %d €$. /amende payer once you have the eddies, and the warrant goes."):format(remaining), C.colors.warn)
        say(officer, ("%s could only pay %d €$; %d €$ stay unpaid, warrant issued."):format(citizenName, paid, remaining))
    else
        if identifier then addRecordFor(identifier, "fine", ("%d €$ - %s (paid, cash)"):format(amount, p.reason), officer) end
        say(officer, ("%s paid the %d €$ fine in cash."):format(citizenName, amount))
    end
    log("fine %d for player %d: paid=%d unpaid=%d reason=%s officer=%d", amount, citizen, paid, remaining, p.reason, officer)
end

local function startFine(source, target, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount < C.fine.min or amount > C.fine.max then
        say(source, ("Amount must be between %d and %d €$."):format(C.fine.min, C.fine.max))
        return
    end
    reason = clean(reason, 120)
    if reason == "" then
        say(source, "Give a reason for the fine.")
        return
    end
    local busy = Open77.playerInteractions.current(target)
    if busy then
        say(source, "They are busy with another interaction. Try again in a moment.")
        return
    end
    local options = {
        durationMs = 1000, consent = true, inviteTimeoutMs = C.fine.inviteTimeoutMs,
        startDistance = C.actionDistance, breakDistance = math.max(C.actionDistance + 3.0, 6.0),
    }
    -- The ticket written on the holo (one-shot gesture; the consent prompt is the wait).
    gesture(source, "fine")
    -- `custom` without profiles is the plain consent flow; should this build insist on a
    -- profile, the `give` kind (the ticket handover) carries the same invitation.
    local state, why = Open77.playerInteractions.request(source, target, "custom", options)
    if not state and (why == "invalid_kind" or why == "invalid_options" or why == "unknown_animation" or why == "invalid_request") then
        state, why = Open77.playerInteractions.request(source, target, "give", options)
    end
    if not state then
        say(source, ("Cannot offer the fine: %s."):format(tostring(why)))
        return
    end
    pendingFines[state.id] = { officer = source, citizen = target, amount = amount, reason = reason, consented = false, settled = false }
    say(source, ("Fine of %d €$ (%s) offered to %s. Waiting for their answer..."):format(amount, reason, nameOf(target)))
    say(target, ("Officer %s fines you %d €$ for: %s. Type /interaction accept to pay, /interaction decline to refuse (a refusal means a warrant)."):format(nameOf(source), amount, reason), C.colors.warn)
    notify(target, "warning", "NCPD fine", ("%d €$ - %s. /interaction accept or decline."):format(amount, reason), 15000)
    log("fine %d offered to player %d by %d (%s) interaction=%s", amount, target, source, reason, tostring(state.id))
end

local function isPending(state)
    return type(state) == "table" and state.id and pendingFines[state.id]
end

AddEventHandler("onPlayerInteractionChanged", function(state)
    local p = isPending(state)
    if not p then return end
    local phase = state.phase
    if phase == "preparing" or phase == "scheduled" or phase == "active" or phase == "completed" then
        p.consented = true
    end
end)

AddEventHandler("onPlayerInteractionStarted", function(state)
    local p = isPending(state)
    if not p then return end
    p.consented = true
    settleFine(p, "accepted")
end)

AddEventHandler("onPlayerInteractionCompleted", function(state)
    local p = isPending(state)
    if not p then return end
    pendingFines[state.id] = nil
    p.consented = true
    settleFine(p, "accepted")
end)

AddEventHandler("onPlayerInteractionCancelled", function(state)
    local p = isPending(state)
    if not p then return end
    pendingFines[state.id] = nil
    if p.consented then
        settleFine(p, "accepted")
    else
        settleFine(p, tostring(state.reason or "declined"))
    end
end)

-- /amende payer: cash first, then the account, oldest fine first.
local function payFines(source)
    local identifier = identifierOf(source)
    local list = identifier and fines[identifier] or nil
    if not list or #list == 0 then
        say(source, "You owe NCPD nothing. Clean slate, choom.")
        return
    end
    local paidTotal = 0
    for _, fine in ipairs(list) do
        if fine.remaining > 0 then
            local okCash, cash = pcall(function() return exports.rp_economy:getBalance(source) end)
            cash = okCash and math.floor(tonumber(cash) or 0) or 0
            local take = math.min(cash, fine.remaining)
            if take > 0 then
                local okRm, nb = pcall(function() return exports.rp_economy:remove(source, take, "fine:" .. fine.reason) end)
                if okRm and nb then
                    fine.remaining = fine.remaining - take
                    paidTotal = paidTotal + take
                    creditSociety(take, "fine:" .. fine.reason)
                end
            end
            if fine.remaining > 0 then
                local okAcc, account = pcall(function() return exports.rp_bank:getAccount(source) end)
                local balance = okAcc and type(account) == "table" and math.floor(tonumber(account.balance) or 0) or 0
                local charge = math.min(balance, fine.remaining)
                if charge > 0 then
                    local okCh, nb = pcall(function() return exports.rp_bank:charge(source, charge, "ncpd", "fine:" .. fine.reason) end)
                    if okCh and nb then
                        fine.remaining = fine.remaining - charge
                        paidTotal = paidTotal + charge
                    end
                end
            end
            Store.updateFine(identifier, fine)
        end
    end
    -- drop settled rows from the cache
    local left = {}
    for _, fine in ipairs(list) do
        if fine.remaining > 0 then left[#left + 1] = fine end
    end
    fines[identifier] = left
    local due = totalUnpaid(identifier)
    if paidTotal > 0 then
        addRecordFor(identifier, "fine_paid", ("%d €$ settled%s"):format(paidTotal, due > 0 and (", " .. due .. " €$ still due") or ""), 0)
    end
    if due == 0 then
        say(source, ("Paid %d €$. Your fines are settled."):format(paidTotal))
        local w = warrants[identifier]
        if w and w.kind == "fine" then
            setWarrantFor(source, identifier, 0, "fines settled", 0)
        end
    else
        say(source, ("Paid %d €$. You still owe %d €$ - not enough eddies on you or in the bank."):format(paidTotal, due), C.colors.warn)
    end
    log("player %d paid %d in fines, %d still due", source, paidTotal, due)
end

-- ---------------------------------------------------------------------------------------------
-- Vehicle: put in / take out (Open77.vehicles server seats)
-- ---------------------------------------------------------------------------------------------

local function officerVehicle(source)
    local seat = Open77.vehicles.getPlayerSeat(source)
    if seat and seat.vehicleId then return seat.vehicleId, 0 end
    local nearest = Open77.vehicles.closest(source, { radius = C.vehicle.range })
    if nearest then return nearest.id, nearest.distance or 0 end
    return nil
end

local function pickSeat(vehicleId)
    local free, reason = Open77.vehicles.freeSeats(vehicleId)
    if not free then return nil, reason end
    if C.vehicle.preferRear then
        for _, s in ipairs(free) do
            if tostring(s):find("rear") or tostring(s):find("back") then return s end
        end
    end
    if free[1] then return free[1] end
    return nil, "vehicle_full"
end

local function doPutInVehicle(source, target)
    local vehicleId = officerVehicle(source)
    if not vehicleId then
        say(source, ("No server vehicle within %.0f m. Bring your cruiser (/car) next to the suspect."):format(C.vehicle.range))
        return
    end
    local seated = Open77.vehicles.getPlayerSeat(target)
    if seated then
        say(source, "They are already in a vehicle. Take them out first.")
        return
    end
    local seat, reason = pickSeat(vehicleId)
    if not seat then
        say(source, ("No free seat: %s."):format(tostring(reason)))
        return
    end
    -- a cuffed body cannot mount: drop the hold, the door lock replaces it
    if kitHold(target) then kitCall("release", target, source, "released") end
    local ok, why = Open77.vehicles.warpPlayerIntoVehicle(target, vehicleId, seat, { moveBucket = true, exitLocked = C.vehicle.lockExit })
    if not ok then
        say(source, ("Cannot seat them: %s."):format(tostring(why)))
        return
    end
    say(source, ("%s is in the vehicle (%s)%s."):format(nameOf(target), tostring(seat), C.vehicle.lockExit and ", door locked" or ""))
    say(target, ("Officer %s put you in the vehicle."):format(nameOf(source)), C.colors.warn)
    log("player %d seated player %d in vehicle %s seat %s", source, target, tostring(vehicleId), tostring(seat))
end

local function doTakeOutOfVehicle(source, target)
    local seat = Open77.vehicles.getPlayerSeat(target)
    if not seat then
        say(source, "They are not in a vehicle.")
        return
    end
    local vehicle = Open77.vehicles.get(seat.vehicleId)
    if vehicle and vehicle.position then
        local metres = Open77.players.distance(source, vehicle.position)
        if metres and metres > C.vehicle.range then
            say(source, ("Too far from the vehicle (%.0f m)."):format(metres))
            return
        end
    end
    local ok, why = Open77.vehicles.forcePlayerOutOfVehicle(target, seat.vehicleId)
    if not ok then
        say(source, ("Cannot take them out: %s."):format(tostring(why)))
        return
    end
    Open77.vehicles.setPlayerExitLocked(target, false, seat.vehicleId)
    say(source, ("You took %s out of the vehicle."):format(nameOf(target)))
    say(target, ("Officer %s took you out of the vehicle."):format(nameOf(source)))
    log("player %d took player %d out of vehicle %s", source, target, tostring(seat.vehicleId))
end

-- ---------------------------------------------------------------------------------------------
-- Jail (teleport to the cell, leash, timer, persistence, release)
-- ---------------------------------------------------------------------------------------------

local function teleportTo(playerId, spot, attempts)
    attempts = attempts or 1
    for i = 1, attempts do
        local pending, reason = Open77.players.teleport(playerId, { x = spot.x, y = spot.y, z = spot.z }, { heading = spot.heading, dismount = true, timeoutMs = 12000 })
        if pending then
            local landed, err = pending:await()
            if landed then return true end
            reason = err
        end
        if reason ~= "player_not_ready" and reason ~= "settle_timeout" then return nil, reason end
        if i < attempts then Wait(2000) end
    end
    return nil, "teleport_failed"
end

local function releasePrisoner(identifier, why, byPlayerId)
    local s = sentences[identifier]
    if not s then return nil, "not_jailed" end
    sentences[identifier] = nil
    Store.setSentence(identifier, nil)
    local playerId = s.playerId
    if playerId and Open77.players.get(playerId) then
        TriggerClientEvent("rp_ncpd:jailed", playerId, false)
        say(playerId, why == "served" and "Time served. Walk out and stay out of trouble, choom." or ("Released early by officer %s."):format(nameOf(byPlayerId)))
        notify(playerId, "success", "Released", why == "served" and "Sentence served." or "Released by an officer.")
        local ok, reason = teleportTo(playerId, C.entrance, 2)
        if not ok then log("release teleport for %d refused: %s", playerId, tostring(reason)) end
    end
    addRecordFor(identifier, "release", why == "served" and ("served %d min"):format(s.total or 0) or "released early", byPlayerId or 0)
    log("prisoner %s released (%s)", shortIdent(identifier), why)
    return true
end

jailResume = function(playerId, identifier)
    CreateThread(function()
        Wait(1500)
        local s = sentences[identifier]
        if not s or s.playerId ~= playerId then return end
        TriggerClientEvent("rp_ncpd:jailed", playerId, true)
        say(playerId, ("Back in the NCPD cell: %s left on your sentence."):format(formatDuration(s.remaining)), C.colors.warn)
        local ok, reason = teleportTo(playerId, C.cell, 5)
        if not ok then log("resume teleport for %d refused: %s", playerId, tostring(reason)) end
    end)
end

local function doJail(source, target, minutes)
    minutes = math.floor(tonumber(minutes) or 0)
    if minutes < C.prison.minMinutes or minutes > C.prison.maxMinutes then
        say(source, ("Minutes must be between %d and %d."):format(C.prison.minMinutes, C.prison.maxMinutes))
        return
    end
    local identifier = identifierOf(target)
    if not identifier then
        say(source, "Cannot identify them.")
        return
    end
    if sentences[identifier] then
        say(source, "They are already doing time.")
        return
    end
    -- Staged: the booking filed on the holo before the transfer (Config.Stage.book).
    local booked = stage(source, "book", { label = "Booking " .. nameOf(target) })
    if not booked or not booked.ok then
        say(source, "Booking cancelled. They stay where they are.")
        return
    end
    if not Open77.players.name(target) or sentences[identifier] then return end
    releaseCuffedPose(target)
    -- booking: contraband is destroyed, the kit's hold is dropped (the cell holds them now)
    local moved = seizeContraband(source, target, false) or {}
    if #moved > 0 then
        local names = {}
        for _, m in ipairs(moved) do names[#names + 1] = ("%s x%d"):format(m.label, m.count) end
        local text = table.concat(names, ", ")
        addRecordFor(identifier, "seizure", text .. " (booking)", source)
        say(source, ("Contraband removed at booking: %s."):format(text))
        say(target, ("Contraband confiscated at booking: %s."):format(text), C.colors.warn)
    end
    if kitHold(target) then kitCall("release", target, source, "released") end
    -- Open77.players.teleport refuses a seated player (player_in_vehicle): take them out first.
    local seatedIn = Open77.vehicles.getPlayerSeat(target)
    if seatedIn and seatedIn.vehicleId then Open77.vehicles.forcePlayerOutOfVehicle(target, seatedIn.vehicleId) end
    local now = math.floor(Open77.time.unix())
    local s = { playerId = target, remaining = minutes * 60, total = minutes, officerName = nameOf(source), startedAt = now, sinceNotify = 0, sincePersist = 0 }
    sentences[identifier] = s
    Store.setSentence(identifier, s, identifierOf(source))
    addRecordFor(identifier, "arrest", ("%d min"):format(minutes), source)
    TriggerClientEvent("rp_ncpd:jailed", target, true)
    say(target, ("Officer %s booked you: %d minutes in the NCPD cell. Weapons and wheels are off the table."):format(nameOf(source), minutes), C.colors.warn)
    notify(target, "error", "Jailed", ("%d minutes. A toast every minute tells you what is left."):format(minutes), 8000)
    say(source, ("%s is in the cell for %d minutes."):format(nameOf(target), minutes))
    TriggerEvent("rp_ncpd:arrest", target, source, minutes)
    log("player %d jailed player %d for %d min", source, target, minutes)
    local ok, reason = teleportTo(target, C.cell, 3)
    if not ok then
        say(source, ("Warning: the teleport to the cell was refused (%s). The leash will retry."):format(tostring(reason)))
        log("jail teleport for %d refused: %s", target, tostring(reason))
    end
end

local function doRelease(source, target)
    local identifier = identifierOf(target)
    if not identifier or not sentences[identifier] then
        say(source, "They are not in the cell.")
        return
    end
    releasePrisoner(identifier, "released", source)
    say(source, ("You released %s."):format(nameOf(target)))
end

-- Sentence clock: once a second for every online prisoner. Releases are collected first and
-- run after the traversal, because a release yields (teleport) and the table may change meanwhile.
CreateThread(function()
    while true do
        Wait(1000)
        local served = {}
        for identifier, s in pairs(sentences) do
            local playerId = s.playerId
            if playerId then
                if not Open77.players.get(playerId) then
                    s.playerId = nil
                    Store.setSentence(identifier, s)
                else
                    s.remaining = s.remaining - 1
                    s.sinceNotify = s.sinceNotify + 1
                    s.sincePersist = s.sincePersist + 1
                    if s.remaining <= 0 then
                        served[#served + 1] = identifier
                    else
                        if s.sinceNotify >= C.prison.notifyEverySeconds then
                            s.sinceNotify = 0
                            notify(playerId, "info", "NCPD cell", ("%s left."):format(formatDuration(s.remaining)), 5000)
                        end
                        if s.sincePersist >= C.prison.persistEverySeconds then
                            s.sincePersist = 0
                            Store.setSentence(identifier, s)
                        end
                    end
                end
            end
        end
        for _, identifier in ipairs(served) do
            releasePrisoner(identifier, "served")
        end
    end
end)

-- Leash: a prisoner who wanders out of the cell radius is put back.
CreateThread(function()
    while true do
        Wait(C.prison.leashCheckMs)
        for _, s in pairs(sentences) do
            local playerId = s.playerId
            if playerId and not s.pulling then
                local metres = Open77.players.distance(playerId, C.cell)
                if metres and metres > C.cell.radius and not Open77.players.isDead(playerId) then
                    s.pulling = true
                    CreateThread(function()
                        local ok, reason = teleportTo(playerId, C.cell, 1)
                        if ok then
                            say(playerId, "Nice try. Back in the cell.", C.colors.warn)
                        else
                            log("leash teleport for %d refused: %s", playerId, tostring(reason))
                        end
                        s.pulling = nil
                    end)
                end
            end
        end
    end
end)

-- A jailed player who gets into a vehicle is pulled out (EnterVehicle is not blockable on 2.31).
AddEventHandler("onPlayerEnteredVehicle", function(playerId, vehicleId)
    playerId = tonumber(playerId)
    if not playerId then return end
    local identifier = identifierOf(playerId)
    if not identifier or not sentences[identifier] then return end
    local ok, reason = Open77.vehicles.forcePlayerOutOfVehicle(playerId, tonumber(vehicleId))
    if not ok then log("prisoner %d vehicle eject refused: %s", playerId, tostring(reason)) end
    say(playerId, "No wheels in the cell.", C.colors.warn)
end)

-- ---------------------------------------------------------------------------------------------
-- Alerts (raised by other resources) and radio
-- ---------------------------------------------------------------------------------------------

AddEventHandler("rp_ncpd:alert", function(kind, position, text, byPlayerId)
    kind = clean(kind or "alert", 32)
    text = clean(text or "", 200)
    local pos = nil
    if type(position) == "table" and tonumber(position.x) and tonumber(position.y) and tonumber(position.z) then
        pos = { x = tonumber(position.x), y = tonumber(position.y), z = tonumber(position.z) }
    end
    byPlayerId = tonumber(byPlayerId)
    local by = (byPlayerId and byPlayerId >= 1) and (" - " .. nameOf(byPlayerId)) or ""
    local officers = officersOnDuty()
    for _, officerId in ipairs(officers) do
        local dist = pos and Open77.players.distance(officerId, pos) or nil
        local where = dist and (" (%.0f m)"):format(dist) or ""
        Open77.chat.send(officerId, { type = "system", author = "[NCPD DISPATCH]", text = ("%s: %s%s%s"):format(kind:upper(), text, by, where), color = C.colors.alert })
        notify(officerId, "warning", "Dispatch: " .. kind, text ~= "" and text or "Officer needed.", 8000)
        if pos then
            TriggerClientEvent("rp_ncpd:alertBlip", officerId, pos, ("NCPD: %s"):format(kind), C.alert.blipMs)
        end
    end
    log("alert %s to %d officer(s): %s", kind, #officers, text)
end)

local function radio(source, text)
    local officers = officersOnDuty()
    local line = { type = "system", author = ("[NCPD RADIO] %s"):format(nameOf(source)), text = text, color = C.colors.radio }
    for _, officerId in ipairs(officers) do
        Open77.chat.send(officerId, line)
    end
    log("radio from %d to %d officer(s): %s", source, #officers, text)
end

local function status(source)
    local lines = {}
    local officers = officersOnDuty()
    local names = {}
    for _, id in ipairs(officers) do names[#names + 1] = ("%s (#%d)"):format(nameOf(id), id) end
    lines[#lines + 1] = ("Officers on duty (%d): %s"):format(#officers, #names > 0 and table.concat(names, ", ") or "nobody")
    local open = {}
    for identifier, w in pairs(warrants) do
        local online = playerByIdentifier(identifier)
        local who = (w.name and w.name ~= "") and w.name or shortIdent(identifier)
        open[#open + 1] = ("%s%s L%d - %s"):format(who, online and (" (#" .. online .. ")") or "", w.level, w.reason)
    end
    table.sort(open)
    lines[#lines + 1] = ("Open warrants (%d): %s"):format(#open, #open > 0 and table.concat(open, "; ") or "none")
    local prisoners = {}
    for identifier, s in pairs(sentences) do
        if s.playerId then
            prisoners[#prisoners + 1] = ("%s (#%d) %s left"):format(nameOf(s.playerId), s.playerId, formatDuration(s.remaining))
        else
            prisoners[#prisoners + 1] = ("%s (offline) %s left"):format(shortIdent(identifier), formatDuration(s.remaining))
        end
    end
    lines[#lines + 1] = ("Prisoners (%d): %s"):format(#prisoners, #prisoners > 0 and table.concat(prisoners, "; ") or "cell is empty")
    lines[#lines + 1] = ("Dispatch voice: %s. Radio: /ncpd <text>."):format(voiceChannel and "on" or "text only")
    for _, line in ipairs(lines) do
        if source == 0 then print("[rp_ncpd] " .. line) else say(source, line) end
        Wait(0)
    end
end

local function casier(source, target)
    local identifier = identifierOf(target)
    if not identifier then
        say(source, "Cannot identify them.")
        return
    end
    local cache = records[identifier]
    local lines = { ("Criminal record of %s (#%d):"):format(nameOf(target), target) }
    local w = warrants[identifier]
    if w then lines[#lines + 1] = ("  WARRANT level %d - %s (%s, officer %s)"):format(w.level, w.reason, formatDate(w.at), w.officerName) end
    local due = totalUnpaid(identifier)
    if due > 0 then lines[#lines + 1] = ("  Unpaid fines: %d €$"):format(due) end
    local s = sentences[identifier]
    if s then lines[#lines + 1] = ("  In the cell: %s left"):format(formatDuration(s.remaining)) end
    local entries = cache and cache.entries or {}
    if #entries == 0 then
        lines[#lines + 1] = cache and cache.loaded and "  Clean record." or "  (record still loading, try again)"
    else
        for i = 1, math.min(#entries, C.record.maxLines) do
            local e = entries[i]
            lines[#lines + 1] = ("  %s [%s] %s - officer %s"):format(formatDate(e.at), tostring(e.kind):upper(), e.text, e.officerName or "?")
        end
        if #entries > C.record.maxLines then lines[#lines + 1] = ("  ... %d more"):format(#entries - C.record.maxLines) end
    end
    for _, line in ipairs(lines) do
        say(source, line)
        Wait(0)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

RegisterCommand("menotter", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1], { maxDistance = C.actionDistance })
    if target then doCuff(source, target) end
end, false)

RegisterCommand("demenotter", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1])
    if target then doUncuff(source, target) end
end, false)

RegisterCommand("escorter", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1])
    if target then doEscort(source, target) end
end, false)

RegisterCommand("fouille", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1], { maxDistance = C.actionDistance })
    if not target then return end
    local mode = tostring(args[2] or ""):lower()
    if mode == "saisir" or mode == "seize" then doSeize(source, target) else doSearch(source, target) end
end, false)

RegisterCommand("amende", function(source, args)
    if source == 0 then print("[rp_ncpd] run this from the game") return end
    if tostring(args[1] or ""):lower() == "payer" then
        payFines(source)
        return
    end
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1], { maxDistance = C.actionDistance })
    if not target then return end
    local amount = tonumber(args[2])
    local reason = table.concat({ table.unpack(args, 3, args.n or #args) }, " ")
    if not amount or reason == "" then
        say(source, "Usage: /amende <playerId> <amount> <reason>  -  /amende payer to settle your own fines.")
        return
    end
    startFine(source, target, amount, reason)
end, false)

RegisterCommand("embarquer", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1], { maxDistance = C.vehicle.range })
    if not target then return end
    if Open77.vehicles.getPlayerSeat(target) then doTakeOutOfVehicle(source, target) else doPutInVehicle(source, target) end
end, false)

RegisterCommand("prison", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1], { maxDistance = C.actionDistance })
    if not target then return end
    if not args[2] then
        say(source, ("Usage: /prison <playerId> <minutes> (%d-%d)."):format(C.prison.minMinutes, C.prison.maxMinutes))
        return
    end
    doJail(source, target, args[2])
end, false)

RegisterCommand("liberer", function(source, args)
    if not requireOfficer(source) then return end
    local target = resolveTarget(source, args[1])
    if target then doRelease(source, target) end
end, false)

RegisterCommand("casier", function(source, args)
    if not requireOfficer(source) then return end
    local target = tonumber(args[1])
    if not target or not Open77.players.get(target) then
        say(source, "Give a connected player id.")
        return
    end
    casier(source, target)
end, false)

RegisterCommand("mandat", function(source, args)
    if not requireOfficer(source) then return end
    local first = tostring(args[1] or ""):lower()
    if first == "lever" or first == "lift" then
        local target = tonumber(args[2])
        if not target or not Open77.players.get(target) then
            say(source, "Usage: /mandat lever <playerId>.")
            return
        end
        local identifier = identifierOf(target)
        local ok, reason = setWarrantFor(target, identifier, 0, "lifted by " .. nameOf(source), source)
        if not ok then say(source, reason == "no_warrant" and "They have no warrant." or ("Cannot lift: " .. tostring(reason))) return end
        say(source, ("Warrant on %s lifted."):format(nameOf(target)))
        return
    end
    local target = tonumber(args[1])
    if not target or target == source or not Open77.players.get(target) then
        say(source, "Usage: /mandat <playerId> [level 1-5] <reason>  -  /mandat lever <playerId>.")
        return
    end
    local level, from = 1, 2
    local maybe = tonumber(args[2])
    if maybe and maybe >= 1 and maybe <= 5 and maybe % 1 == 0 then level, from = maybe, 3 end
    local reason = table.concat({ table.unpack(args, from, args.n or #args) }, " ")
    if trim(reason) == "" then
        say(source, "Give a reason for the warrant.")
        return
    end
    local ok, why = setWarrantFor(target, identifierOf(target), level, reason, source, "manual")
    if not ok then say(source, "Cannot issue the warrant: " .. tostring(why)) return end
    say(source, ("Warrant issued on %s: level %d - %s."):format(nameOf(target), level, reason))
    log("warrant L%d on player %d by %d: %s", level, target, source, reason)
end, false)

RegisterCommand("ncpd", function(source, args)
    local n = args.n or #args
    if n == 0 then
        if source ~= 0 and not hasNcpdJob(source) then
            say(source, "NCPD internal. Move along, citizen.")
            return
        end
        status(source)
        return
    end
    if not requireOfficer(source) then return end
    local text = clean(table.concat({ table.unpack(args, 1, n) }, " "), 300)
    if text == "" then return end
    radio(source, text)
end, false)

-- ---------------------------------------------------------------------------------------------
-- ALT+click actions (the client only names the target; everything is re-checked here)
-- ---------------------------------------------------------------------------------------------

local function askInput(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "input", playerId, definition)
    if not promise then return nil, reason end
    local answer, why = promise:await()
    if not answer then return nil, why end
    if not answer.ok then return nil, answer.outcome or "cancelled" end
    return answer.value
end

local function askConfirm(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "alert", playerId, definition)
    if not promise then return nil, reason end
    local answer, why = promise:await()
    if not answer then return nil, why end
    return answer.ok == true
end

local MENU_ACTIONS = {
    cuff = function(src, target) doCuff(src, target) end,
    uncuff = function(src, target) doUncuff(src, target) end,
    escort = function(src, target) doEscort(src, target) end,
    search = function(src, target) doSearch(src, target) end,
    seize = function(src, target)
        local yes, reason = askConfirm(src, {
            title = "Seize the contraband?", message = ("Every illegal item on %s goes into your pockets."):format(nameOf(target)),
            confirm = "Seize", cancel = "Leave it", tone = "warning", timeoutMs = 30000,
        })
        if yes == nil then
            say(src, ("Dialog unavailable (%s): use /fouille %d saisir."):format(tostring(reason), target))
            return
        end
        if yes then doSeize(src, target) end
    end,
    fine = function(src, target)
        local value, reason = askInput(src, {
            title = ("Fine %s"):format(nameOf(target)),
            description = "The citizen accepts or refuses. A refusal is a warrant.",
            fields = {
                { id = "amount", type = "number", label = "Amount (€$)", min = C.fine.min, max = C.fine.max, required = true, default = 500 },
                { id = "reason", type = "text", label = "Reason", max = 120, required = true },
            },
            confirm = "Fine", cancel = "Cancel", timeoutMs = 60000,
        })
        if not value then
            if reason ~= "cancelled" then say(src, ("Dialog unavailable (%s): use /amende %d <amount> <reason>."):format(tostring(reason), target)) end
            return
        end
        startFine(src, target, value.amount, value.reason)
    end,
    vehicle = function(src, target)
        if Open77.vehicles.getPlayerSeat(target) then doTakeOutOfVehicle(src, target) else doPutInVehicle(src, target) end
    end,
    jail = function(src, target)
        local value, reason = askInput(src, {
            title = ("Jail %s"):format(nameOf(target)),
            description = "Contraband is destroyed at booking. Time persists through a disconnect.",
            fields = {
                { id = "minutes", type = "number", label = "Minutes", min = C.prison.minMinutes, max = C.prison.maxMinutes, required = true, default = 10 },
            },
            confirm = "Book them", cancel = "Cancel", timeoutMs = 60000,
        })
        if not value then
            if reason ~= "cancelled" then say(src, ("Dialog unavailable (%s): use /prison %d <minutes>."):format(tostring(reason), target)) end
            return
        end
        doJail(src, target, value.minutes)
    end,
    release = function(src, target) doRelease(src, target) end,
    record = function(src, target) casier(src, target) end,
}

local MENU_DISTANCE = {
    cuff = C.actionDistance, search = C.actionDistance, seize = C.actionDistance, fine = C.actionDistance, jail = C.actionDistance,
    vehicle = C.vehicle.range,
}

RegisterNetEvent("rp_ncpd:action", function(action, targetId)
    local src = source
    if type(src) ~= "number" or src < 1 then return end
    local handler = MENU_ACTIONS[action]
    if not handler then return end
    if not requireOfficer(src) then return end
    local target = resolveTarget(src, targetId, { maxDistance = MENU_DISTANCE[action] })
    if not target then return end
    handler(src, target)
end)

RegisterNetEvent("rp_ncpd:clientReady", function()
    local src = source
    if type(src) ~= "number" or src < 1 then return end
    pushSelf(src)
    local identifier = identifierOf(src)
    TriggerClientEvent("rp_ncpd:jailed", src, identifier ~= nil and sentences[identifier] ~= nil and sentences[identifier].playerId == src)
end)

-- ---------------------------------------------------------------------------------------------
-- Exports (never yield: cache only)
-- ---------------------------------------------------------------------------------------------

exports("isOnDuty", function(playerId)
    return isOfficer(tonumber(playerId))
end)

exports("wanted", function(playerId)
    local identifier = identifierOf(tonumber(playerId))
    local w = identifier and warrants[identifier] or nil
    if not w then return nil end
    return { level = w.level, reason = w.reason }
end)

exports("setWanted", function(playerId, level, reason)
    playerId = tonumber(playerId)
    if not playerId or not Open77.players.get(playerId) then return nil, "player_not_found" end
    local identifier = identifierOf(playerId)
    if not identifier then return nil, "player_not_found" end
    return setWarrantFor(playerId, identifier, level, reason or "", 0, "manual")
end)

exports("record", function(playerId)
    local identifier = identifierOf(tonumber(playerId))
    local cache = identifier and records[identifier] or nil
    return { entries = copyEntries(cache and cache.entries or {}) }
end)

exports("addRecord", function(playerId, kind, text, byPlayerId)
    playerId = tonumber(playerId)
    if not playerId or not Open77.players.get(playerId) then return nil, "player_not_found" end
    local identifier = identifierOf(playerId)
    if not identifier then return nil, "player_not_found" end
    return addRecordFor(identifier, kind, text, tonumber(byPlayerId) or 0)
end)

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/menotter", help = "NCPD: cuff a player", parameters = { { name = "playerId", help = "who" } } },
    { command = "/demenotter", help = "NCPD: release a cuffed / escorted player", parameters = { { name = "playerId", help = "who" } } },
    { command = "/escorter", help = "NCPD: escort a player (again to stop)", parameters = { { name = "playerId", help = "who" } } },
    { command = "/fouille", help = "NCPD: search a cuffed / hands-up player; 'saisir' seizes the contraband", parameters = { { name = "playerId", help = "who" }, { name = "saisir", help = "optional" } } },
    { command = "/amende", help = "NCPD: fine a player (they accept or refuse); /amende payer settles your own fines", parameters = { { name = "playerId|payer", help = "who" }, { name = "amount", help = "eddies" }, { name = "reason", help = "why" } } },
    { command = "/embarquer", help = "NCPD: put a player in your vehicle, or take them out", parameters = { { name = "playerId", help = "who" } } },
    { command = "/prison", help = "NCPD: jail a player for 1-120 minutes", parameters = { { name = "playerId", help = "who" }, { name = "minutes", help = "1-120" } } },
    { command = "/liberer", help = "NCPD: release a prisoner early", parameters = { { name = "playerId", help = "who" } } },
    { command = "/casier", help = "NCPD: criminal record of a player", parameters = { { name = "playerId", help = "who" } } },
    { command = "/mandat", help = "NCPD: warrant on a player (level 1-5); /mandat lever <id> lifts it", parameters = { { name = "playerId|lever", help = "who" }, { name = "level", help = "optional 1-5" }, { name = "reason", help = "why" } } },
    { command = "/ncpd", help = "NCPD: precinct status, or a radio line to every officer on duty", parameters = { { name = "text", help = "optional radio message" } } },
}

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then Open77.chat.addSuggestions(source, SUGGESTIONS) end
end)

-- The outpost's props (Config.outpost.props): the NCPD sign and a barrier on the Afterlife
-- street, owned here, removed on stop. A refusal only logs; the ring is the client's.
local outpostProps = {}

local function spawnOutpostProps()
    local o = C.outpost
    if not o or type(o.props) ~= "table" then return end
    for index, at in ipairs(o.props) do
        if not outpostProps[index] and at.model then
            local id, reason = Open77.props.create({
                model = at.model,
                position = { x = at.x, y = at.y, z = at.z },
                yaw = at.yaw or 0.0,
                bucket = 0,
                streamingRadius = 120.0,
            })
            if id then
                outpostProps[index] = id
            else
                log("outpost prop %d not spawned (%s)", index, tostring(reason))
            end
        end
    end
end

local function removeOutpostProps()
    for index, propId in pairs(outpostProps) do
        Open77.props.remove(propId)
        outpostProps[index] = nil
    end
end

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log("started: cell %.1f %.1f %.1f, entrance %.1f %.1f %.1f, jail %d-%d min, fines %d-%d eddies",
        C.cell.x, C.cell.y, C.cell.z, C.entrance.x, C.entrance.y, C.entrance.z, C.prison.minMinutes, C.prison.maxMinutes, C.fine.min, C.fine.max)
    local props, err = pcall(spawnOutpostProps)
    if not props then log("outpost props failed: %s", tostring(err)) end
    bootStore()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    ensureVoiceChannel()
    for _, playerId in ipairs(Open77.players.all()) do
        CreateThread(function() loadPlayer(playerId) end)
        if isOfficer(playerId) then applyDuty(playerId, true) else pushSelf(playerId) end
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    loadPlayer(playerId)
    pushSelf(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    revokeRights(playerId)
    cuffedPose[playerId] = nil
    stageClear(playerId)
    if voiceChannel then Open77.voice.removePlayer(voiceChannel.id, playerId) end
    for identifier, s in pairs(sentences) do
        if s.playerId == playerId then
            s.playerId = nil
            Store.setSentence(identifier, s)
            log("prisoner %d left with %s to serve; the clock resumes on reconnect", playerId, formatDuration(s.remaining))
        end
    end
    for id, p in pairs(pendingFines) do
        if p.officer == playerId or p.citizen == playerId then pendingFines[id] = nil end
    end
    -- the record / fine caches are keyed by identifier and cheap; they are dropped to stay bounded
    local identifier = identifierOf(playerId)
    if identifier then
        records[identifier] = nil
        fines[identifier] = nil
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    removeOutpostProps()
    for identifier, s in pairs(sentences) do Store.setSentence(identifier, s) end
    for playerId in pairs(grantedRights) do revokeRights(playerId) end
    for _, playerId in ipairs(Open77.players.all()) do TriggerClientEvent("rp_ncpd:jailed", playerId, false) end
end)
