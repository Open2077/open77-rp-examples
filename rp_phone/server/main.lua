-- rp_phone: server. The server owns every decision: who has a phone, who owns which
-- number, what a message says, who is in a call and on which voice channel, what a
-- service call does and what an ad costs. The page and the client only send intents
-- (rp_phone:intent) and render the state pushed back (rp_phone:state).
--
-- Storage: SQL first (rp_phone_sms, rp_phone_contacts, rp_phone_ads, rp_phone_lines)
-- through Open77.database, memory cache per session written through with the
-- callback forms so the exports never yield; Open77.kvp when no database answers.

local Config = RpPhoneConfig
local RESOURCE = "rp_phone"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_phone] " .. fmt):format(...))
end

local function now()
    return math.floor(Open77.time.unix())
end

local function mono()
    return Open77.time.monotonic()
end

-- Chat line to one player (numbers only: host-event ids are strings).
local function say(playerId, text, color)
    playerId = tonumber(playerId)
    if not playerId then return end
    if playerId == 0 then print("[rp_phone] " .. text) return end
    Open77.chat.send(playerId, { type = "system", author = "PHONE", text = text, color = color or Config.color.phone })
end

local function toast(playerId, title, message, kind, ms)
    playerId = tonumber(playerId)
    if not playerId or playerId == 0 then return end
    Open77.notifications.send(playerId, {
        type = kind or "info",
        title = title,
        message = message,
        icon = "TEL",
        durationMs = ms or 6000,
    })
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cuts a string on a byte budget without splitting a UTF-8 sequence.
local function utf8Cut(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end -- next byte starts a character
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- Strip control characters and bound the length (UTF-8 safe).
local function clean(s, maxLen)
    s = trim(s):gsub("[%c]", " ")
    return utf8Cut(s, maxLen)
end

local function round(v)
    return math.floor((tonumber(v) or 0) + 0.5)
end

-- "555-0012", "5550012", "0012", "12" -> "555-0012"; nil when unparseable.
local function parseNumber(raw)
    if type(raw) ~= "string" and type(raw) ~= "number" then return nil end
    local digits = tostring(raw):gsub("%D", "")
    if digits == "" or #digits > 7 then return nil end
    if #digits == 7 then
        if digits:sub(1, 3) ~= "555" then return nil end
        digits = digits:sub(4)
    end
    if #digits > 4 then return nil end
    return ("%s%04d"):format(Config.numberPrefix, tonumber(digits))
end

local function formatNumber(citizenId)
    return ("%s%04d"):format(Config.numberPrefix, citizenId)
end

local function safePcall(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil, "unavailable" end
    return a, b
end

-- Cross-resource exports, all optional at runtime.
local function rpName(playerId)
    local name = safePcall(function() return exports.rp_identity:fullName(playerId) end)
    if type(name) == "string" and name ~= "" then return name end
    return Open77.players.name(playerId) or ("citizen #" .. tostring(playerId))
end

local function hasPhoneItem(playerId)
    if not Config.requireItem then return true end
    local ok, has = pcall(function() return exports.rp_inventory:has(playerId, Config.item, 1) end)
    if not ok then return true, "inventory_offline" end -- no pockets to check: degrade, do not brick
    return has == true
end

---------------------------------------------------------------------------
-- Store: SQL first, kvp when no database answers
---------------------------------------------------------------------------

local store = { mode = nil, ready = false, reason = nil }
local waitingForStore = {} -- playerIds that connected before the store decided

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS rp_phone_lines (
        number VARCHAR(12) NOT NULL PRIMARY KEY,
        identifier VARCHAR(64) NOT NULL,
        name VARCHAR(64) NOT NULL DEFAULT '',
        updated_at INT NOT NULL DEFAULT 0,
        INDEX idx_rp_phone_lines_identifier (identifier)
    )]],
    [[CREATE TABLE IF NOT EXISTS rp_phone_contacts (
        identifier VARCHAR(64) NOT NULL,
        number VARCHAR(12) NOT NULL,
        name VARCHAR(32) NOT NULL DEFAULT '',
        created_at INT NOT NULL DEFAULT 0,
        PRIMARY KEY (identifier, number)
    )]],
    [[CREATE TABLE IF NOT EXISTS rp_phone_sms (
        id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        from_identifier VARCHAR(64) NOT NULL,
        to_identifier VARCHAR(64) NOT NULL,
        from_number VARCHAR(24) NOT NULL,
        to_number VARCHAR(24) NOT NULL,
        text VARCHAR(255) NOT NULL,
        sent_at INT NOT NULL DEFAULT 0,
        read_at INT NULL,
        INDEX idx_rp_phone_sms_to (to_identifier, read_at),
        INDEX idx_rp_phone_sms_from (from_identifier)
    )]],
    [[CREATE TABLE IF NOT EXISTS rp_phone_ads (
        id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        identifier VARCHAR(64) NOT NULL,
        number VARCHAR(12) NOT NULL,
        author VARCHAR(64) NOT NULL DEFAULT '',
        text VARCHAR(160) NOT NULL,
        posted_at INT NOT NULL DEFAULT 0,
        expires_at INT NOT NULL DEFAULT 0,
        INDEX idx_rp_phone_ads_expires (expires_at)
    )]],
}

-- kvp helpers (JSON blobs, bounded)
local function kvGet(key, default)
    local raw = Open77.kvp.get(key)
    if type(raw) ~= "string" or raw == "" then return default end
    local ok, value = pcall(json.decode, raw)
    if ok and value ~= nil then return value end
    return default
end

local function kvSet(key, value)
    local ok, encoded = pcall(json.encode, value)
    if not ok or not encoded then return false end
    return Open77.kvp.set(key, encoded)
end

---------------------------------------------------------------------------
-- In-memory state
---------------------------------------------------------------------------

-- sessions[playerId] = {
--   id, identifier, name, number (or nil), loaded,
--   contacts = { { number, name } ... },
--   messages = { { id, from, to, fromName, text, at, read, mine } ... } newest last,
--   threads = { [peerNumber] = { peer, name, unread, last, at, count } },
--   openThread = peerNumber|nil, open = bool, animId, callLog = {...},
--   nearby = list|nil, dirty = bool, lastIntent = { t, n }
-- }
local sessions = {}
local byNumber = {}          -- number -> online playerId
local lines = {}             -- number -> { identifier, name }
local linesByIdentifier = {} -- identifier -> number
local ads = {}               -- array of { id, identifier, number, author, text, postedAt, expiresAt }
local nextLocalId = 1        -- kvp ids for sms / ads
local calls = {}             -- callId -> call
local callByPlayer = {}      -- playerId -> callId
local nextCallId = 1

local function session(playerId)
    return sessions[tonumber(playerId)]
end

local function contactName(s, number)
    for _, c in ipairs(s.contacts) do
        if c.number == number then return c.name end
    end
    return nil
end

local function displayNameFor(s, number, fallback)
    return contactName(s, number) or fallback or number
end

---------------------------------------------------------------------------
-- Persistence primitives (never yield: callback forms only)
---------------------------------------------------------------------------

local function persistLine(number, identifier, name)
    name = utf8Cut(tostring(name or ""), 64)
    lines[number] = { identifier = identifier, name = name }
    linesByIdentifier[identifier] = number
    if store.mode == "sql" then
        Open77.database.update(
            "INSERT INTO rp_phone_lines (number, identifier, name, updated_at) VALUES (?, ?, ?, ?) " ..
            "ON DUPLICATE KEY UPDATE identifier = VALUES(identifier), name = VALUES(name), updated_at = VALUES(updated_at)",
            { number, identifier, name, now() }, function() end)
    elseif store.mode == "kvp" then
        local all = kvGet("lines", {})
        all[number] = { identifier = identifier, name = name }
        kvSet("lines", all)
    end
end

local function persistContact(s, number, name, remove)
    if store.mode == "sql" then
        if remove then
            Open77.database.update("DELETE FROM rp_phone_contacts WHERE identifier = ? AND number = ?",
                { s.identifier, number }, function() end)
        else
            Open77.database.update(
                "INSERT INTO rp_phone_contacts (identifier, number, name, created_at) VALUES (?, ?, ?, ?) " ..
                "ON DUPLICATE KEY UPDATE name = VALUES(name)",
                { s.identifier, number, name, now() }, function() end)
        end
    elseif store.mode == "kvp" then
        local list = {}
        for _, c in ipairs(s.contacts) do list[#list + 1] = { number = c.number, name = c.name } end
        kvSet("contacts:" .. s.identifier, list)
    end
end

-- Inserts a message row; `done(id)` runs with the id once it is stored.
local function persistSms(row, done)
    if store.mode == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_phone_sms (from_identifier, to_identifier, from_number, to_number, text, sent_at, read_at) " ..
            "VALUES (?, ?, ?, ?, ?, ?, NULL)",
            { row.fromIdentifier, row.toIdentifier, row.from, row.to, row.text, row.at },
            function(id) done(tonumber(id) or 0) end)
    elseif store.mode == "kvp" then
        local id = nextLocalId
        nextLocalId = nextLocalId + 1
        Open77.kvp.set("next_id", nextLocalId)
        for _, who in ipairs({ row.fromIdentifier, row.toIdentifier }) do
            if who ~= "" and who:sub(1, 8) ~= "service:" then
                local box = kvGet("sms:" .. who, {})
                box[#box + 1] = { id = id, fi = row.fromIdentifier, ti = row.toIdentifier, f = row.from,
                    t = row.to, x = row.text, a = row.at, r = false }
                while #box > 100 do table.remove(box, 1) end
                kvSet("sms:" .. who, box)
            end
        end
        done(id)
    else
        done(0)
    end
end

local function persistRead(identifier, peerNumber)
    if store.mode == "sql" then
        Open77.database.update(
            "UPDATE rp_phone_sms SET read_at = ? WHERE to_identifier = ? AND from_number = ? AND read_at IS NULL",
            { now(), identifier, peerNumber }, function() end)
    elseif store.mode == "kvp" then
        local box = kvGet("sms:" .. identifier, {})
        for _, m in ipairs(box) do
            if m.ti == identifier and m.f == peerNumber then m.r = true end
        end
        kvSet("sms:" .. identifier, box)
    end
end

local function persistAd(ad, done)
    if store.mode == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_phone_ads (identifier, number, author, text, posted_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
            { ad.identifier, ad.number, ad.author, ad.text, ad.postedAt, ad.expiresAt },
            function(id) done(tonumber(id) or 0) end)
    elseif store.mode == "kvp" then
        local id = nextLocalId
        nextLocalId = nextLocalId + 1
        Open77.kvp.set("next_id", nextLocalId)
        ad.id = id
        local list = {}
        for _, a in ipairs(ads) do list[#list + 1] = a end
        list[#list + 1] = ad
        kvSet("ads", list)
        done(id)
    else
        done(0)
    end
end

local function persistAdRemoval(adId)
    if store.mode == "sql" then
        Open77.database.update("DELETE FROM rp_phone_ads WHERE id = ?", { adId }, function() end)
    elseif store.mode == "kvp" then
        kvSet("ads", ads)
    end
end

---------------------------------------------------------------------------
-- Threads / state / push
---------------------------------------------------------------------------

local pushQueue = {}

local function markDirty(playerId)
    local s = session(playerId)
    if s then pushQueue[s.id] = true end
end

local function rebuildThreads(s)
    local threads = {}
    for _, m in ipairs(s.messages) do
        local peer = m.mine and m.to or m.from
        local t = threads[peer]
        if not t then
            t = { peer = peer, name = displayNameFor(s, peer, m.mine and nil or m.fromName), unread = 0, count = 0 }
            threads[peer] = t
        end
        t.count = t.count + 1
        t.last = m.text
        t.at = m.at
        if not m.mine and not m.read then t.unread = t.unread + 1 end
        if not m.mine and m.fromName and not contactName(s, peer) then t.name = m.fromName end
    end
    s.threads = threads
end

local function unreadTotal(s)
    local n = 0
    for _, t in pairs(s.threads) do n = n + t.unread end
    return n
end

local function callView(s)
    local callId = callByPlayer[s.id]
    local call = callId and calls[callId]
    if not call then return nil end
    local peerId = call.callerId == s.id and call.calleeId or call.callerId
    local peer = session(peerId)
    local peerNumber = peer and peer.number or "?"
    return {
        id = call.id,
        state = call.state,               -- ringing | active
        direction = call.callerId == s.id and "out" or "in",
        peer = peerNumber,
        name = displayNameFor(s, peerNumber, peer and peer.name or "Unknown"),
        voice = call.channelId ~= nil,
        since = call.startedAt and (now() - call.startedAt) or 0,
    }
end

local function buildState(s)
    local threadList = {}
    for _, t in pairs(s.threads) do threadList[#threadList + 1] = t end
    table.sort(threadList, function(a, b) return (a.at or 0) > (b.at or 0) end)
    while #threadList > Config.sms.threadsInState do table.remove(threadList) end

    local open = nil
    if s.openThread then
        local list = {}
        for i = #s.messages, 1, -1 do
            local m = s.messages[i]
            local peer = m.mine and m.to or m.from
            if peer == s.openThread then
                table.insert(list, 1, { text = m.text, at = m.at, mine = m.mine })
                if #list >= Config.sms.messagesInState then break end
            end
        end
        open = { peer = s.openThread, name = displayNameFor(s, s.openThread, s.threads[s.openThread] and s.threads[s.openThread].name), messages = list }
    end

    local adList = {}
    for i = #ads, 1, -1 do
        local a = ads[i]
        adList[#adList + 1] = { id = a.id, number = a.number, author = a.author, text = a.text,
            minutesLeft = math.max(0, math.floor((a.expiresAt - now()) / 60)), mine = a.identifier == s.identifier }
        if #adList >= Config.ads.maxListed then break end
    end

    return {
        me = { number = s.number, name = s.name, sim = s.number ~= nil },
        contacts = s.contacts,
        threads = threadList,
        thread = open,
        unread = unreadTotal(s),
        call = callView(s),
        callLog = s.callLog,
        ads = adList,
        adPrice = Config.ads.price,
        nearby = s.nearby,
        open = s.open,
        t = now(),
    }
end

local function pushNow(s, eventName)
    TriggerClientEvent(eventName or "rp_phone:state", s.id, buildState(s))
    s.nearby = nil -- a nearby list is delivered once, on request
end

-- Throttle: at most one state push per player per window.
CreateThread(function()
    while true do
        Wait(Config.pushThrottleMs)
        for playerId in pairs(pushQueue) do
            pushQueue[playerId] = nil
            local s = sessions[playerId]
            if s and s.open then pushNow(s) end
        end
    end
end)

---------------------------------------------------------------------------
-- Animation (server-owned RP profile while the phone is open / on a call)
---------------------------------------------------------------------------

local function stopAnim(s)
    if not s.animId then return end
    local ok = Open77.animations.stop(s.id, s.animId)
    s.animId = nil
    return ok
end

-- Config.anim entries are lists of profiles tried in order through Open77.animations.get
-- (walkable profile first, then stationary fallbacks); the first known one is kept.
local resolvedAnim = {}
local function resolveProfile(list)
    if type(list) ~= "table" then return list end
    local key = table.concat(list, ",")
    if resolvedAnim[key] ~= nil then return resolvedAnim[key] or nil end
    for _, id in ipairs(list) do
        local ok, profile = pcall(Open77.animations.get, id)
        if ok and type(profile) == "table" then resolvedAnim[key] = id; return id end
    end
    resolvedAnim[key] = false
    log("no known profile among [%s]: the phone is held without a pose", key)
    return nil
end

local function playAnim(s, profile)
    profile = resolveProfile(profile)
    if not profile then return end
    if s.animProfile == profile and s.animId then return end
    stopAnim(s)
    local playback, err = Open77.animations.play(s.id, profile, { loop = true })
    if not playback then
        -- player_not_alive, player_in_vehicle, animations_unavailable...: the phone
        -- still works, the body simply does not hold it.
        s.animId, s.animProfile = nil, nil
        if err and err ~= "player_in_vehicle" then log("player %d anim %s refused: %s", s.id, profile, tostring(err)) end
        return
    end
    s.animId, s.animProfile = playback.playbackId, profile
end

local function refreshAnim(s)
    local callId = callByPlayer[s.id]
    local call = callId and calls[callId]
    if call and call.state == "active" then
        playAnim(s, Config.anim.call)
    elseif s.open then
        playAnim(s, Config.anim.open)
    else
        stopAnim(s)
        s.animProfile = nil
    end
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

local function closePhone(s, silent)
    if not s.open then return end
    s.open = false
    s.nearby = nil
    TriggerClientEvent("rp_phone:close", s.id)
    refreshAnim(s)
    if not silent then log("player %d closed the phone", s.id) end
end

local function openPhone(s)
    if not s.loaded then
        say(s.id, "Your holophone is still booting. Try again in a second.")
        return false
    end
    local has, why = hasPhoneItem(s.id)
    if not has then
        say(s.id, "No holophone in your pockets, choom. Find one (item 'phone').")
        return false
    end
    if why == "inventory_offline" and not s.warnedInventory then
        s.warnedInventory = true
        log("rp_inventory not reachable: player %d opens the phone without the item check", s.id)
    end
    s.open = true
    TriggerClientEvent("rp_phone:open", s.id, buildState(s))
    refreshAnim(s)
    if not s.number then
        say(s.id, "No SIM: register at NCID first (/carte) to get a number. Emergency services still work.")
    end
    return true
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

local function appendMessage(s, m)
    s.messages[#s.messages + 1] = m
    while #s.messages > Config.sms.keepPerPlayer do table.remove(s.messages, 1) end
    rebuildThreads(s)
end

-- Core send: from a live session to a number. Returns true | nil, reason.
local function deliverSms(fromS, toNumber, text, fromLabel)
    text = clean(text, Config.sms.maxLength)
    if text == "" then return nil, "empty_text" end
    if not toNumber then return nil, "invalid_number" end
    local fromNumber = fromLabel or fromS.number
    if not fromNumber then return nil, "no_sim" end
    if not fromLabel and toNumber == fromS.number then return nil, "self" end

    local line = lines[toNumber]
    local toId = byNumber[toNumber]
    local toS = toId and sessions[toId]
    local toIdentifier = toS and toS.identifier or (line and line.identifier)
    if not toIdentifier then return nil, "not_in_service" end

    local row = {
        fromIdentifier = fromLabel and ("service:" .. fromLabel) or fromS.identifier,
        toIdentifier = toIdentifier,
        from = fromNumber, to = toNumber,
        text = text, at = now(),
    }
    persistSms(row, function(id)
        if not fromLabel and sessions[fromS.id] == fromS then
            appendMessage(fromS, { id = id, from = row.from, to = row.to, text = text, at = row.at, read = true, mine = true })
            markDirty(fromS.id)
        end
        local receiver = byNumber[toNumber] and sessions[byNumber[toNumber]]
        if receiver and receiver.identifier == toIdentifier then
            appendMessage(receiver, { id = id, from = row.from, to = row.to, fromName = fromLabel or fromS.name,
                text = text, at = row.at, read = false, mine = false })
            if receiver.open and receiver.openThread == fromNumber then
                -- the thread is on screen: read on arrival
                for _, m in ipairs(receiver.messages) do
                    if not m.mine and m.from == fromNumber then m.read = true end
                end
                rebuildThreads(receiver)
                persistRead(receiver.identifier, fromNumber)
            end
            markDirty(receiver.id)
            local who = fromLabel or displayNameFor(receiver, fromNumber, fromS.name)
            toast(receiver.id, "New message from " .. who, text, "info", 7000)
            say(receiver.id, ("[SMS] %s: %s"):format(who, text), Config.color.sms)
        end
    end)
    TriggerEvent("rp_phone:sms", row.fromIdentifier, toIdentifier, text)
    log("sms %s -> %s (%d chars)", fromNumber, toNumber, #text)
    return true
end

local function markThreadRead(s, peer)
    local changed = false
    for _, m in ipairs(s.messages) do
        if not m.mine and m.from == peer and not m.read then m.read = true; changed = true end
    end
    if changed then
        rebuildThreads(s)
        persistRead(s.identifier, peer)
    end
end

---------------------------------------------------------------------------
-- Calls
---------------------------------------------------------------------------

local function callPeer(call, playerId)
    return call.callerId == playerId and call.calleeId or call.callerId
end

local function addCallLog(s, entry)
    table.insert(s.callLog, 1, entry)
    while #s.callLog > 10 do table.remove(s.callLog) end
end

local function endCall(call, reason)
    if not calls[call.id] then return end
    calls[call.id] = nil
    if call.channelId then
        local removed, why = Open77.voice.removeChannel(call.channelId)
        if not removed then log("call %d: removeChannel refused: %s", call.id, tostring(why)) end
    end
    for _, pid in ipairs({ call.callerId, call.calleeId }) do
        if callByPlayer[pid] == call.id then callByPlayer[pid] = nil end
        local s = sessions[pid]
        if s then
            local peer = sessions[callPeer(call, pid)]
            local peerNumber = peer and peer.number or "?"
            addCallLog(s, { kind = reason, direction = call.callerId == pid and "out" or "in", peer = peerNumber,
                name = displayNameFor(s, peerNumber, peer and peer.name), at = now(),
                seconds = call.startedAt and (now() - call.startedAt) or 0 })
            refreshAnim(s)
            markDirty(pid)
        end
    end
    log("call %d ended: %s", call.id, reason)
end

local function hangup(s, reason)
    local callId = callByPlayer[s.id]
    local call = callId and calls[callId]
    if not call then return nil, "no_call" end
    local peerId = callPeer(call, s.id)
    local peerS = sessions[peerId]
    if call.state == "ringing" then
        if call.callerId == s.id then
            if peerS then say(peerS.id, ("%s hung up before you answered."):format(s.name), Config.color.call) end
            say(s.id, "Call cancelled.", Config.color.call)
            endCall(call, "cancelled")
        else
            if peerS then say(peerS.id, ("%s declined your call."):format(s.name), Config.color.call) end
            say(s.id, "Call declined.", Config.color.call)
            endCall(call, "declined")
        end
    else
        if peerS then say(peerS.id, ("%s hung up."):format(s.name), Config.color.call) end
        say(s.id, "Call ended.", Config.color.call)
        endCall(call, reason or "ended")
    end
    return true
end

local function startCall(s, toNumber)
    if not s.number then return nil, "no_sim" end
    if not toNumber then return nil, "invalid_number" end
    if toNumber == s.number then return nil, "self" end
    if callByPlayer[s.id] then return nil, "busy" end
    local toId = byNumber[toNumber]
    local toS = toId and sessions[toId]
    if not toS then
        if lines[toNumber] then return nil, "offline" end
        return nil, "not_in_service"
    end
    if callByPlayer[toS.id] then return nil, "peer_busy" end
    if toS.loaded and not select(1, hasPhoneItem(toS.id)) then return nil, "peer_no_phone" end

    local call = { id = nextCallId, callerId = s.id, calleeId = toS.id, state = "ringing", ringSince = mono() }
    nextCallId = nextCallId + 1
    calls[call.id] = call
    callByPlayer[s.id] = call.id
    callByPlayer[toS.id] = call.id

    local callerLabel = displayNameFor(toS, s.number, s.name)
    say(toS.id, ("Incoming call from %s (%s). /tel accepter or /tel refuser"):format(callerLabel, s.number), Config.color.call)
    toast(toS.id, "Incoming call", ("%s is calling. /tel accepter - /tel refuser"):format(callerLabel), "warning", 10000)
    say(s.id, ("Calling %s..."):format(displayNameFor(s, toNumber, toS.name)), Config.color.call)
    markDirty(s.id)
    markDirty(toS.id) -- a closed phone shows the call as soon as it is opened
    log("call %d: player %d -> player %d ringing", call.id, s.id, toS.id)

    local callId = call.id
    SetTimeout(Config.call.ringSeconds * 1000, function()
        local c = calls[callId]
        if c and c.state == "ringing" then
            local caller, callee = sessions[c.callerId], sessions[c.calleeId]
            if caller then say(caller.id, "No answer.", Config.color.call) end
            if callee then
                say(callee.id, ("Missed call from %s."):format(caller and caller.name or "unknown"), Config.color.call)
                toast(callee.id, "Missed call", caller and caller.name or "unknown", "info")
            end
            endCall(c, "missed")
        end
    end)
    return true
end

local function acceptCall(s)
    local callId = callByPlayer[s.id]
    local call = callId and calls[callId]
    if not call then return nil, "no_call" end
    if call.state ~= "ringing" or call.calleeId ~= s.id then return nil, "not_ringing" end
    local caller = sessions[call.callerId]
    if not caller then endCall(call, "cancelled") return nil, "caller_gone" end

    call.state = "active"
    call.startedAt = now()

    -- One private voice channel per call, removed on hang-up.
    local channel, why = nil, "voice_api_missing"
    if Open77.voice and Open77.voice.createChannel then
        channel, why = Open77.voice.createChannel({
            name = ("Call #%d"):format(call.id),
            mode = Config.call.voiceMode,
            persistent = false,
            effect = Config.call.effect,
        })
    end
    if channel and channel.id then
        call.channelId = channel.id
        for _, pid in ipairs({ call.callerId, call.calleeId }) do
            local added, reason = Open77.voice.addPlayer(channel.id, pid, { canSpeak = true, canListen = true })
            if not added then log("call %d: addPlayer(%d) refused: %s", call.id, pid, tostring(reason)) end
        end
        log("call %d: voice channel %s created", call.id, tostring(channel.id))
    else
        call.channelId = nil
        log("call %d: voice unavailable (%s): text-only call", call.id, tostring(why))
    end

    local mode = call.channelId and "Voice line open." or ("No voice on this server: talk with /tel <text> (" .. Config.call.chatTag .. ").")
    say(caller.id, ("%s picked up. %s /tel raccrocher to hang up."):format(s.name, mode), Config.color.call)
    say(s.id, ("Connected with %s. %s /tel raccrocher to hang up."):format(caller.name, mode), Config.color.call)
    refreshAnim(caller)
    refreshAnim(s)
    markDirty(caller.id)
    markDirty(s.id)
    return true
end

local function callText(s, text)
    local callId = callByPlayer[s.id]
    local call = callId and calls[callId]
    if not call or call.state ~= "active" then return nil, "no_call" end
    text = clean(text, Config.sms.maxLength)
    if text == "" then return nil, "empty_text" end
    local line = ("%s %s: %s"):format(Config.call.chatTag, s.name, text)
    say(s.id, line, Config.color.call)
    local peer = sessions[callPeer(call, s.id)]
    if peer then say(peer.id, line, Config.color.call) end
    return true
end

---------------------------------------------------------------------------
-- Services
---------------------------------------------------------------------------

local function positionOf(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then return nil end
    return { x = round(pos.x), y = round(pos.y), z = round(pos.z) }
end

local function pageJob(job, title, text, color)
    local ok, list = pcall(function() return exports.rp_jobs:listOnDuty(job) end)
    if not ok or type(list) ~= "table" then return nil, "jobs_offline" end
    for _, pid in ipairs(list) do
        say(pid, text, color)
        toast(pid, title, text, "warning", 8000)
    end
    return #list
end

local function serviceCall(s, name, text)
    local pos = positionOf(s.id)
    if not pos then return nil, "position_unknown" end
    text = clean(text or "", Config.sms.maxLength)
    if text == "" then text = "(no details)" end
    local where = ("%d, %d, %d"):format(pos.x, pos.y, pos.z)
    local caller = s.name .. (s.number and (" (" .. s.number .. ")") or "")

    if name == "ncpd" then
        local sent = TriggerEvent("rp_ncpd:alert", Config.services.ncpdAlertKind, pos, ("%s: %s"):format(caller, text), s.id)
        say(s.id, sent and "NCPD dispatch has your call and your position. Stay put." or "NCPD line busy. Try again.", Config.color.service)
        log("player %d called NCPD from %s: %s (dispatched=%s)", s.id, where, text, tostring(sent == true))
        return true
    elseif name == "trauma" then
        TriggerEvent("rp_ncpd:alert", Config.services.traumaAlertKind, pos, ("%s: %s"):format(caller, text), s.id)
        local n = pageJob(Config.services.traumaJob, "911 call",
            ("[911] %s at %s: %s"):format(caller, where, text), Config.color.service)
        if n and n > 0 then
            say(s.id, ("Trauma Team dispatched (%d medic%s paged). Hold on, choom."):format(n, n > 1 and "s" or ""), Config.color.service)
        else
            say(s.id, "911 logged. No Trauma Team medic on duty right now; NCPD has your position.", Config.color.service)
        end
        log("player %d called 911 from %s: %s", s.id, where, text)
        return true
    elseif name == "delamain" then
        local ok, rideId, reason = pcall(function() return exports.rp_delamain:call(s.id, nil) end)
        if ok and rideId then
            say(s.id, ("Delamain: ride #%s booked. A driver is on the way."):format(tostring(rideId)), Config.color.service)
            log("player %d booked delamain ride %s by phone", s.id, tostring(rideId))
            return true
        end
        local why = ok and tostring(reason) or "delamain_offline"
        if why == "already_in_ride" then
            say(s.id, "Delamain: you already have a ride in progress.", Config.color.service)
        else
            say(s.id, "No Delamain driver on duty. Type /taxi for the automated cab (short trips only).", Config.color.service)
        end
        log("player %d delamain by phone refused: %s", s.id, why)
        return true
    elseif name == "mecano" then
        local n = pageJob(Config.services.mecanoJob, "Mechanic call",
            ("[GARAGE] %s needs a mechanic at %s: %s"):format(caller, where, text), Config.color.service)
        if not n then
            say(s.id, "The garage line is dead (jobs offline).", Config.color.service)
        elseif n == 0 then
            say(s.id, "No mechanic on duty. Try again later or /remorquer when one clocks in.", Config.color.service)
        else
            say(s.id, ("Mechanic paged (%d on duty). Stay with the car."):format(n), Config.color.service)
        end
        log("player %d called a mechanic from %s: %s", s.id, where, text)
        return true
    end
    return nil, "unknown_service"
end

---------------------------------------------------------------------------
-- Location sharing
---------------------------------------------------------------------------

local function shareLocation(s, toNumber)
    if not s.number then return nil, "no_sim" end
    if not toNumber then return nil, "invalid_number" end
    local toId = byNumber[toNumber]
    local toS = toId and sessions[toId]
    if not toS then return nil, lines[toNumber] and "offline" or "not_in_service" end
    if toS.id == s.id then return nil, "self" end
    local pos = Open77.players.position(s.id)
    if not pos then return nil, "position_unknown" end
    local label = ("%s's location"):format(displayNameFor(toS, s.number, s.name))
    TriggerClientEvent("rp_phone:blip", toS.id, { x = pos.x, y = pos.y, z = pos.z }, label, Config.location.blipSeconds)
    say(toS.id, ("%s shared their location: %d, %d (pin on your map for %d s)."):format(
        displayNameFor(toS, s.number, s.name), round(pos.x), round(pos.y), Config.location.blipSeconds), Config.color.phone)
    toast(toS.id, "Location shared", label, "info")
    log("player %d shared location with player %d", s.id, toS.id)
    return true
end

---------------------------------------------------------------------------
-- Ads
---------------------------------------------------------------------------

local function chargeAd(s)
    local price = Config.ads.price
    if price <= 0 then return true end
    local ok, balance, reason = pcall(function() return exports.rp_economy:remove(s.id, price, "phone_ad") end)
    if not ok then return nil, "economy_offline" end
    if balance then return true, "cash" end
    if reason == "insufficient_funds" then
        -- take it from the bank account: withdraw to cash, then debit the cash
        local bok, nb, breason = pcall(function() return exports.rp_bank:withdraw(s.id, price) end)
        if bok and nb then
            local ok2, balance2 = pcall(function() return exports.rp_economy:remove(s.id, price, "phone_ad") end)
            if ok2 and balance2 then return true, "bank" end
        end
        return nil, "insufficient_funds"
    end
    return nil, tostring(reason)
end

local function liveAdsOf(identifier)
    local n = 0
    for _, a in ipairs(ads) do if a.identifier == identifier then n = n + 1 end end
    return n
end

local function postAd(s, text)
    if not s.number then return nil, "no_sim" end
    text = clean(text, Config.ads.maxLength)
    if #text < 3 then return nil, "empty_text" end
    if liveAdsOf(s.identifier) >= Config.ads.maxPerPlayer then return nil, "too_many_ads" end
    local paid, how = chargeAd(s)
    if not paid then return nil, how end
    local ad = { identifier = s.identifier, number = s.number, author = utf8Cut(s.name, 64), text = text,
        postedAt = now(), expiresAt = now() + Config.ads.minutes * 60 }
    persistAd(ad, function(id)
        ad.id = id
        ads[#ads + 1] = ad
        for pid, other in pairs(sessions) do if other.open then markDirty(pid) end end
    end)
    log("player %d posted an ad (%s, %d eddies): %s", s.id, tostring(how), Config.ads.price, text)
    return true, how
end

local function removeAd(s, adId)
    for i, a in ipairs(ads) do
        if a.id == adId then
            if a.identifier ~= s.identifier then return nil, "not_yours" end
            table.remove(ads, i)
            persistAdRemoval(adId)
            for pid, other in pairs(sessions) do if other.open then markDirty(pid) end end
            return true
        end
    end
    return nil, "unknown_ad"
end

-- Expired ads leave the board once a minute.
CreateThread(function()
    while true do
        Wait(60000)
        local t = now()
        local changed = false
        for i = #ads, 1, -1 do
            if ads[i].expiresAt <= t then
                if store.mode == "sql" then
                    Open77.database.update("DELETE FROM rp_phone_ads WHERE id = ?", { ads[i].id }, function() end)
                end
                table.remove(ads, i)
                changed = true
            end
        end
        if changed then
            if store.mode == "kvp" then kvSet("ads", ads) end
            for pid, other in pairs(sessions) do if other.open then markDirty(pid) end end
        end
    end
end)

---------------------------------------------------------------------------
-- Contacts
---------------------------------------------------------------------------

local function addContact(s, number, name)
    if not number then return nil, "invalid_number" end
    if number == s.number then return nil, "self" end
    name = clean(name or "", Config.contacts.nameMaxLength)
    if name == "" then
        local line = lines[number]
        name = line and line.name or number
    end
    for _, c in ipairs(s.contacts) do
        if c.number == number then
            c.name = name
            persistContact(s, number, name, false)
            rebuildThreads(s)
            return true, "updated"
        end
    end
    if #s.contacts >= Config.contacts.max then return nil, "too_many_contacts" end
    s.contacts[#s.contacts + 1] = { number = number, name = name }
    table.sort(s.contacts, function(a, b) return a.name:lower() < b.name:lower() end)
    persistContact(s, number, name, false)
    rebuildThreads(s)
    return true, "added"
end

local function removeContact(s, number)
    for i, c in ipairs(s.contacts) do
        if c.number == number then
            table.remove(s.contacts, i)
            persistContact(s, number, nil, true)
            rebuildThreads(s)
            return true
        end
    end
    return nil, "unknown_contact"
end

local function nearbyPlayers(s)
    local list, why = Open77.players.nearby(s.id, Config.contacts.nearbyRadius, { limit = 10 })
    if not list then return nil, why end
    local out = {}
    for _, e in ipairs(list) do
        local other = sessions[e.playerId]
        if other and other.number then
            out[#out + 1] = { playerId = e.playerId, number = other.number, name = other.name, distance = round(e.distance) }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Reasons in plain English
---------------------------------------------------------------------------

local REASONS = {
    no_sim = "No SIM in this holophone: register at NCID (/carte) to get a number.",
    invalid_number = "That is not a number. Format: 555-0042 (or just 42).",
    self = "Calling yourself? Even in Night City that is sad.",
    not_in_service = "This number is not in service.",
    offline = "The line is dead: nobody answers on that number right now.",
    busy = "You are already on the line. /tel raccrocher first.",
    peer_busy = "Busy tone: they are already on a call.",
    peer_no_phone = "It rings out: they lost their holophone.",
    no_call = "No call in progress.",
    not_ringing = "Nothing to answer.",
    caller_gone = "The caller is gone.",
    empty_text = "Say something first.",
    too_many_contacts = "Your contact list is full.",
    unknown_contact = "No such contact.",
    too_many_ads = ("You already run %d ads. Wait for one to expire."):format(Config.ads.maxPerPlayer),
    insufficient_funds = ("Not enough eddies: an ad costs %d €$ (cash or account)."):format(Config.ads.price),
    economy_offline = "The city network refuses payments right now (economy offline).",
    unknown_ad = "That ad is gone.",
    not_yours = "Not your ad.",
    position_unknown = "The network cannot locate you. Move a little and retry.",
    jobs_offline = "Nobody answers: the dispatch board is offline.",
    unknown_service = "Unknown service.",
    unavailable = "Service unavailable.",
}

local function explain(reason)
    return REASONS[reason] or ("Refused: " .. tostring(reason))
end

---------------------------------------------------------------------------
-- Intents (page -> client -> server)
---------------------------------------------------------------------------

local function throttled(s)
    local t = mono()
    if not s.lastIntent or t - s.lastIntent.t >= 1.0 then
        s.lastIntent = { t = t, n = 0 }
    end
    s.lastIntent.n = s.lastIntent.n + 1
    return s.lastIntent.n > Config.intentsPerSecond
end

local function handleIntent(s, kind, p)
    p = type(p) == "table" and p or {}
    if kind == "close" then
        closePhone(s, true)
        return
    elseif kind == "refresh" then
        markDirty(s.id)
        return
    elseif kind == "contacts.add" then
        local ok, why = addContact(s, parseNumber(p.number), p.name)
        say(s.id, ok and ("Contact %s."):format(why) or explain(why))
    elseif kind == "contacts.remove" then
        local ok, why = removeContact(s, parseNumber(p.number))
        if not ok then say(s.id, explain(why)) end
    elseif kind == "contacts.nearby" then
        local list, why = nearbyPlayers(s)
        s.nearby = list or {}
        if not list then say(s.id, explain(why)) end
    elseif kind == "sms.open" then
        local peer = type(p.peer) == "string" and p.peer or nil
        s.openThread = peer
        if peer then markThreadRead(s, peer) end
    elseif kind == "sms.send" then
        local ok, why = deliverSms(s, parseNumber(p.to), p.text)
        if not ok then say(s.id, explain(why)) end
    elseif kind == "call.start" then
        local ok, why = startCall(s, parseNumber(p.number))
        if not ok then say(s.id, explain(why), Config.color.call) end
    elseif kind == "call.accept" then
        local ok, why = acceptCall(s)
        if not ok then say(s.id, explain(why), Config.color.call) end
    elseif kind == "call.decline" or kind == "call.hangup" then
        local ok, why = hangup(s)
        if not ok then say(s.id, explain(why), Config.color.call) end
    elseif kind == "call.text" then
        local ok, why = callText(s, p.text)
        if not ok then say(s.id, explain(why), Config.color.call) end
    elseif kind == "service" then
        local ok, why = serviceCall(s, p.name, p.text)
        if not ok then say(s.id, explain(why), Config.color.service) end
    elseif kind == "location.send" then
        local ok, why = shareLocation(s, parseNumber(p.number))
        say(s.id, ok and "Location sent." or explain(why))
    elseif kind == "ads.post" then
        local ok, why = postAd(s, p.text)
        say(s.id, ok and ("Ad posted for %d min (%d €$ from your %s)."):format(Config.ads.minutes, Config.ads.price, why == "bank" and "account" or "cash") or explain(why))
    elseif kind == "ads.remove" then
        local ok, why = removeAd(s, tonumber(p.id))
        say(s.id, ok and "Ad removed." or explain(why))
    else
        return
    end
    markDirty(s.id)
end

RegisterNetEvent("rp_phone:intent", function(kind, payload)
    local s = session(source)
    if not s or type(kind) ~= "string" then return end
    if throttled(s) then return end
    if not s.open and kind ~= "close" and kind ~= "call.accept" and kind ~= "call.decline" and kind ~= "call.hangup" then
        return -- the page is only listened to while the server thinks the phone is open
    end
    handleIntent(s, kind, payload)
end)

---------------------------------------------------------------------------
-- Session loading
---------------------------------------------------------------------------

local function resolveNumber(s)
    -- SQL: the NCID citizen id (rp_identity_citizens.id) is the number.
    if store.mode == "sql" then
        local ok, row = pcall(function()
            return Open77.database.single.await("SELECT id FROM rp_identity_citizens WHERE identifier = ? LIMIT 1", { s.identifier })
        end)
        if ok and row and tonumber(row.id) then
            return formatNumber(tonumber(row.id))
        end
        if not ok then log("rp_identity_citizens not readable (%s): player %d gets no number", tostring(row), s.id) end
        return nil
    end
    -- kvp: a number from the fallback range, stable per identifier.
    local existing = Open77.kvp.get("line:" .. s.identifier)
    if type(existing) == "string" and existing ~= "" then return existing end
    local ok, registered = pcall(function() return exports.rp_identity:isRegistered(s.id) end)
    if ok and registered == false then return nil end
    local n = Open77.kvp.get("line_counter", Config.fallbackFirstNumber)
    Open77.kvp.set("line_counter", n + 1)
    local number = formatNumber(n)
    Open77.kvp.set("line:" .. s.identifier, number)
    return number
end

local function loadMessages(s)
    local out = {}
    if store.mode == "sql" then
        local rows = Open77.database.query.await(
            "SELECT id, from_identifier, to_identifier, from_number, to_number, text, sent_at, read_at " ..
            "FROM rp_phone_sms WHERE from_identifier = ? OR to_identifier = ? ORDER BY id DESC LIMIT ?",
            { s.identifier, s.identifier, Config.sms.keepPerPlayer }) or {}
        for i = #rows, 1, -1 do
            local r = rows[i]
            local mine = r.from_identifier == s.identifier
            local fromName = nil
            if not mine then
                local line = lines[r.from_number]
                fromName = (r.from_identifier:sub(1, 8) == "service:" and r.from_number) or (line and line.name) or nil
            end
            local readAt = tonumber(r.read_at)
            out[#out + 1] = { id = tonumber(r.id), from = r.from_number, to = r.to_number, fromName = fromName,
                text = r.text, at = tonumber(r.sent_at) or 0, read = mine or (readAt ~= nil and readAt > 0), mine = mine }
        end
    elseif store.mode == "kvp" then
        for _, m in ipairs(kvGet("sms:" .. s.identifier, {})) do
            local mine = m.fi == s.identifier
            local line = lines[m.f]
            out[#out + 1] = { id = m.id, from = m.f, to = m.t, fromName = (not mine) and ((m.fi:sub(1, 8) == "service:" and m.f) or (line and line.name)) or nil,
                text = m.x, at = m.a, read = mine or m.r == true, mine = mine }
        end
    end
    return out
end

local function loadContacts(s)
    local out = {}
    if store.mode == "sql" then
        local rows = Open77.database.query.await(
            "SELECT number, name FROM rp_phone_contacts WHERE identifier = ? ORDER BY name ASC LIMIT ?",
            { s.identifier, Config.contacts.max }) or {}
        for _, r in ipairs(rows) do out[#out + 1] = { number = r.number, name = r.name } end
    elseif store.mode == "kvp" then
        for _, c in ipairs(kvGet("contacts:" .. s.identifier, {})) do out[#out + 1] = { number = c.number, name = c.name } end
    end
    return out
end

local function loadSession(playerId)
    local s = sessions[playerId]
    if not s or s.loaded then return end
    s.number = resolveNumber(s)
    if sessions[playerId] ~= s then return end -- left while the number was being looked up
    if s.number then
        -- another session already on this number (same identity twice) is replaced
        local previous = byNumber[s.number]
        if previous and previous ~= playerId and sessions[previous] then
            byNumber[s.number] = nil
        end
        byNumber[s.number] = playerId
        persistLine(s.number, s.identifier, s.name)
    end
    s.contacts = loadContacts(s)
    s.messages = loadMessages(s)
    if sessions[playerId] ~= s then return end -- left while loading
    rebuildThreads(s)
    s.loaded = true
    local unread = unreadTotal(s)
    log("player %d ready: number=%s contacts=%d messages=%d unread=%d store=%s", playerId,
        tostring(s.number), #s.contacts, #s.messages, unread, store.mode)
    if unread > 0 then
        say(playerId, ("Your holophone buzzes: %d unread message%s. /tel to read them."):format(unread, unread > 1 and "s" or ""), Config.color.sms)
        toast(playerId, "Unread messages", ("%d waiting on your holophone"):format(unread), "info")
    end
end

local function ensureSession(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId <= 0 then return nil end
    local s = sessions[playerId]
    if s then return s end
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return nil end
    s = { id = playerId, identifier = identifier, name = rpName(playerId), number = nil, loaded = false,
        contacts = {}, messages = {}, threads = {}, callLog = {}, open = false }
    sessions[playerId] = s
    if store.ready then
        loadSession(playerId)
    else
        waitingForStore[#waitingForStore + 1] = playerId
    end
    return s
end

local function dropSession(playerId)
    playerId = tonumber(playerId)
    local s = sessions[playerId]
    if not s then return end
    local callId = callByPlayer[playerId]
    if callId and calls[callId] then
        local call = calls[callId]
        local peer = sessions[callPeer(call, playerId)]
        if peer then say(peer.id, ("%s dropped off the network."):format(s.name), Config.color.call) end
        endCall(call, "dropped")
    end
    if s.animId then stopAnim(s) end
    if s.number and byNumber[s.number] == playerId then byNumber[s.number] = nil end
    sessions[playerId] = nil
    pushQueue[playerId] = nil
end

---------------------------------------------------------------------------
-- Store boot
---------------------------------------------------------------------------

local function loadGlobal()
    if store.mode == "sql" then
        for _, r in ipairs(Open77.database.query.await("SELECT number, identifier, name FROM rp_phone_lines") or {}) do
            lines[r.number] = { identifier = r.identifier, name = r.name }
            linesByIdentifier[r.identifier] = r.number
        end
        ads = {}
        for _, r in ipairs(Open77.database.query.await(
            "SELECT id, identifier, number, author, text, posted_at, expires_at FROM rp_phone_ads WHERE expires_at > ? ORDER BY id ASC",
            { now() }) or {}) do
            ads[#ads + 1] = { id = tonumber(r.id), identifier = r.identifier, number = r.number, author = r.author,
                text = r.text, postedAt = tonumber(r.posted_at) or 0, expiresAt = tonumber(r.expires_at) or 0 }
        end
    else
        for number, line in pairs(kvGet("lines", {})) do
            lines[number] = { identifier = line.identifier, name = line.name }
            linesByIdentifier[line.identifier] = number
        end
        ads = {}
        for _, a in ipairs(kvGet("ads", {})) do
            if (a.expiresAt or 0) > now() then ads[#ads + 1] = a end
        end
        nextLocalId = Open77.kvp.get("next_id", 1)
    end
end

local function finishBoot()
    store.ready = true
    loadGlobal()
    if store.mode == "sql" then
        local ok, count = pcall(function()
            return Open77.database.scalar.await("SELECT COUNT(*) FROM rp_identity_citizens")
        end)
        if ok and count ~= nil then
            log("NCID registry reachable: %s citizen record(s) -> numbers are 555-<citizen id>", tostring(count))
        else
            log("WARNING: rp_identity_citizens not readable (%s): nobody gets a number until rp_identity has created it", tostring(count))
        end
    end
    log("store=%s lines=%d ads=%d%s", store.mode, (function() local n = 0 for _ in pairs(lines) do n = n + 1 end return n end)(), #ads,
        store.reason and (" reason=" .. store.reason) or "")
    local pending = waitingForStore
    waitingForStore = {}
    for _, pid in ipairs(pending) do
        if sessions[pid] then loadSession(pid) end
    end
end

local function useKvp(reason)
    if store.mode then return end
    store.mode, store.reason = "kvp", reason
    log("database not ready (%s): falling back to Open77.kvp for phone data", tostring(reason))
    finishBoot()
end

local function bootStore()
    local accepted, reason = Open77.database.ready(function()
        if store.mode then return end
        store.mode = "sql"
        for _, sql in ipairs(SCHEMA) do Open77.database.update.await(sql) end
        log("schema ready: rp_phone_lines, rp_phone_contacts, rp_phone_sms, rp_phone_ads")
        finishBoot()
    end)
    if not accepted then
        useKvp(reason)
        return
    end
    -- A database that is configured but never answers must not hold the phone hostage.
    SetTimeout(15000, function()
        if not store.mode then
            local ready, why = Open77.database.isReady()
            if not ready then useKvp(why or "database_timeout") end
        end
    end)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/tel", help = "Open your holophone; /tel accepter | refuser | raccrocher; /tel <text> talks on an active call",
        parameters = { { name = "action", help = "accepter | refuser | raccrocher | text" } } },
    { command = "/sms", help = "Send a text message", parameters = { { name = "number", help = "555-0042" }, { name = "text", help = "the message" } } },
    { command = "/contacts", help = "List your contacts; /contacts ajouter <number> <name>; /contacts supprimer <number>" },
    { command = "/annonce", help = ("Post an ad on the city board (%d €$, %d min); /annonce alone lists them"):format(Config.ads.price, Config.ads.minutes),
        parameters = { { name = "text", help = "the ad" } } },
}

local function fromGame(source)
    if source == 0 then print("[rp_phone] this command is for players in the game") return false end
    local s = ensureSession(source)
    if not s then print("[rp_phone] unknown player " .. tostring(source)) return false end
    if not s.loaded then
        say(source, "Your holophone is still booting. Try again in a second.")
        return false
    end
    return s
end

RegisterCommand("tel", function(source, args)
    local s = fromGame(source)
    if not s then return end
    local action = (args[1] or ""):lower()
    if action == "" then
        if s.open then closePhone(s) else openPhone(s) end
        return
    end
    if action == "accepter" or action == "accept" then
        if not hasPhoneItem(s.id) then return say(s.id, "No holophone in your pockets, choom.") end
        local ok, why = acceptCall(s)
        if not ok then say(s.id, explain(why), Config.color.call) end
        markDirty(s.id)
    elseif action == "refuser" or action == "raccrocher" or action == "decline" or action == "hangup" then
        local ok, why = hangup(s)
        if not ok then say(s.id, explain(why), Config.color.call) end
        markDirty(s.id)
    elseif action == "appeler" or action == "call" or (parseNumber(action) and not callByPlayer[s.id]) then
        if not hasPhoneItem(s.id) then return say(s.id, "No holophone in your pockets, choom.") end
        local target = (action == "appeler" or action == "call") and args[2] or action
        local ok, why = startCall(s, parseNumber(target))
        if not ok then say(s.id, explain(why), Config.color.call) end
    else
        -- anything else while on a call is spoken on the line ([CALL] tag)
        local text = table.concat(args, " ", 1, args.n or #args)
        local ok, why = callText(s, text)
        if not ok then
            if why == "no_call" then
                say(s.id, "Usage: /tel (open) | /tel accepter | /tel refuser | /tel raccrocher | /tel appeler <number> | /tel <text> while on a call")
            else
                say(s.id, explain(why), Config.color.call)
            end
        end
    end
end, false)

RegisterCommand("sms", function(source, args)
    local s = fromGame(source)
    if not s then return end
    local number = parseNumber(args[1])
    local text = table.concat(args, " ", 2, args.n or #args)
    if not number or text == "" then
        return say(s.id, "Usage: /sms <number> <text>")
    end
    if not hasPhoneItem(s.id) then return say(s.id, "No holophone in your pockets, choom.") end
    local ok, why = deliverSms(s, number, text)
    if ok then
        say(s.id, ("[SMS] to %s: %s"):format(displayNameFor(s, number), clean(text, Config.sms.maxLength)), Config.color.sms)
    else
        say(s.id, explain(why))
    end
    markDirty(s.id)
end, false)

RegisterCommand("contacts", function(source, args)
    local s = fromGame(source)
    if not s then return end
    local sub = (args[1] or ""):lower()
    if sub == "ajouter" or sub == "add" then
        local number = parseNumber(args[2])
        local name = table.concat(args, " ", 3, args.n or #args)
        local ok, why = addContact(s, number, name)
        if ok then
            say(s.id, ("Contact %s: %s (%s)."):format(why, contactName(s, number) or number, number))
        else
            say(s.id, explain(why))
        end
        markDirty(s.id)
        return
    elseif sub == "supprimer" or sub == "remove" then
        local ok, why = removeContact(s, parseNumber(args[2]))
        say(s.id, ok and "Contact removed." or explain(why))
        markDirty(s.id)
        return
    end
    say(s.id, ("Your number: %s. Contacts (%d):"):format(s.number or "no SIM", #s.contacts))
    for _, c in ipairs(s.contacts) do
        Wait(0)
        say(s.id, ("  %s  %s%s"):format(c.number, c.name, byNumber[c.number] and " [online]" or ""))
    end
    if #s.contacts == 0 then say(s.id, "  none. /contacts ajouter <number> <name>, or /tel > Contacts.") end
end, false)

RegisterCommand("annonce", function(source, args)
    local s = fromGame(source)
    if not s then return end
    local text = table.concat(args, " ", 1, args.n or #args)
    if trim(text) == "" then
        say(s.id, ("City board (%d ads):"):format(#ads))
        for i = #ads, math.max(1, #ads - Config.ads.maxListed + 1), -1 do
            local a = ads[i]
            if a then
                Wait(0)
                say(s.id, ("  #%d %s (%s): %s [%d min]"):format(a.id or 0, a.author, a.number, a.text, math.max(0, math.floor((a.expiresAt - now()) / 60))))
            end
        end
        if #ads == 0 then say(s.id, "  nothing posted. /annonce <text> puts yours up.") end
        return
    end
    if not hasPhoneItem(s.id) then return say(s.id, "No holophone in your pockets, choom.") end
    local ok, why = postAd(s, text)
    say(s.id, ok and ("Ad posted for %d min (%d €$ from your %s)."):format(Config.ads.minutes, Config.ads.price, why == "bank" and "account" or "cash") or explain(why))
    markDirty(s.id)
end, false)

---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
---------------------------------------------------------------------------

-- sms(fromPlayerId, toIdentifier, text) -> true | nil, reason
exports("sms", function(fromPlayerId, toIdentifier, text)
    local s = session(fromPlayerId)
    if not s or not s.loaded then return nil, "player_not_found" end
    if type(toIdentifier) ~= "string" or toIdentifier == "" then return nil, "invalid_identifier" end
    local toNumber = linesByIdentifier[toIdentifier]
    if not toNumber then
        for pid, other in pairs(sessions) do
            if other.identifier == toIdentifier and other.number then toNumber = other.number break end
        end
    end
    if not toNumber then return nil, "not_in_service" end
    return deliverSms(s, toNumber, tostring(text or ""))
end)

-- notify(playerId, sender, text): a service pushes a message into the player's phone.
exports("notify", function(playerId, sender, text)
    local s = session(playerId)
    if not s or not s.loaded then return nil, "player_not_found" end
    sender = clean(tostring(sender or "CITY"), 16):upper()
    if sender == "" then sender = "CITY" end
    text = clean(tostring(text or ""), Config.sms.maxLength)
    if text == "" then return nil, "empty_text" end
    if not s.number then
        -- no SIM: the message still reaches the player as a chat line + toast
        say(s.id, ("[%s] %s"):format(sender, text), Config.color.sms)
        toast(s.id, sender, text, "info")
        return true, "no_sim"
    end
    local pseudo = { id = -1, identifier = "service:" .. sender, name = sender, number = sender }
    return deliverSms(pseudo, s.number, text, sender)
end)

-- contactsOf(playerId) -> { { number, name } ... }
exports("contactsOf", function(playerId)
    local s = session(playerId)
    if not s then return {} end
    local out = {}
    for _, c in ipairs(s.contacts) do out[#out + 1] = { number = c.number, name = c.name } end
    return out
end)

-- numberOf(playerId) -> "555-0042" | nil (bonus, for HUDs and MDTs)
exports("numberOf", function(playerId)
    local s = session(playerId)
    return s and s.number or nil
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log("started: item=%s anim=%s/%s ring=%ds ad=%d eddies/%d min", tostring(Config.item),
        tostring(Config.anim.open), tostring(Config.anim.call), Config.call.ringSeconds, Config.ads.price, Config.ads.minutes)
    bootStore()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    for _, pid in ipairs(Open77.players.all()) do ensureSession(pid) end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for callId, call in pairs(calls) do endCall(call, "resource_stop") end
    for pid, s in pairs(sessions) do
        if s.open then closePhone(s, true) end
    end
end)

RegisterNetEvent("chat:ready", function()
    if source and source > 0 then Open77.chat.addSuggestions(source, SUGGESTIONS) end
end)

AddEventHandler("onPlayerReady", function(playerId)
    ensureSession(tonumber(playerId))
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    dropSession(tonumber(playerId))
end)

-- A player who dies, gets in a car or walks away loses the animation (the service
-- cancels it itself). The phone stays open; only the playback handle is forgotten so
-- the next refresh can start the profile again instead of stopping a stale id.
AddEventHandler("onPlayerAnimationChanged", function(playerId, stateJson)
    local s = session(playerId)
    if not s or not s.animId then return end
    local state = stateJson
    if type(state) == "string" then
        local ok, decoded = pcall(json.decode, state)
        state = ok and decoded or nil
    end
    if type(state) ~= "table" then return end
    if state.playbackId == s.animId and state.active == false then
        s.animId, s.animProfile = nil, nil
    end
end)

-- rp_identity registration or edit after connect: the RP name follows, and a
-- citizen registered after login gets their number without a reconnect.
AddEventHandler("rp_identity:changed", function(playerId)
    local s = session(playerId)
    if not s or not s.loaded or not store.ready then return end
    s.name = rpName(s.id)
    if s.number then
        persistLine(s.number, s.identifier, s.name)
        markDirty(s.id)
        return
    end
    CreateThread(function()
        local number = resolveNumber(s)
        if number and sessions[s.id] == s and not s.number then
            s.number = number
            byNumber[number] = s.id
            persistLine(number, s.identifier, s.name)
            say(s.id, ("Your holophone is now in service: %s."):format(number))
            markDirty(s.id)
        end
    end)
end)
