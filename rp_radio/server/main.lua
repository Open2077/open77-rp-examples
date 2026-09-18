-- rp_radio: handheld radio for a Night City RP server.
--
-- One Open77 voice channel (mode "radio") per frequency in use, created lazily
-- and removed when its last listener leaves. Free frequencies are open to anyone
-- holding a `radio` item (rp_inventory); reserved ones (Config.reserved) need the
-- matching rp_jobs job on duty. The Badlands (rp_zones) cut the signal, a
-- netrunner jam (rp_netrunner:jammed) floods every channel with static.
--
-- Exports: channelOf(playerId) -> frequency|nil, signal ; broadcast(frequency, text)
-- Event:   rp_radio:tuned (playerId, frequency|nil)

local RESOURCE = GetCurrentResourceName()

-- [playerId] = { key = "95.5", signal = boolean }
local tuned = {}
-- [key] = { id = <voice channel id>, members = { [playerId] = true }, count = n }
local channels = {}
-- Jam state; `token` invalidates a static loop that outlived its jam.
local jam = { active = false, token = 0 }
-- nil = not probed yet, true = channels can be created, false = voice off (text only).
local voiceAvailable = nil
local dbReady = false
local kvpWarned = false

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[%s] %s"):format(RESOURCE, fmt:format(...)))
end

local function chat(playerId, text, color)
    if type(playerId) ~= "number" then playerId = tonumber(playerId) end
    if not playerId then return end
    if playerId == 0 then print(text) return end
    Open77.chat.send(playerId, { text = text, color = color or Config.colors.info })
end

local function playerName(playerId)
    return Open77.players.name(playerId) or ("#" .. tostring(playerId))
end

-- Optional override through rp_config (never declared: reached in pcall).
local function cfg(key, default)
    local ok, value = pcall(function() return exports.rp_config:get("rp_radio." .. key, default) end)
    if ok and value ~= nil then return value end
    return default
end

-- Snap a user string/number to the band, one decimal, as the canonical key "95.5".
local function parseFrequency(input)
    local n = tonumber(input)
    if not n then return nil, "not_a_number" end
    local snapped = math.floor(n * 10 + 0.5) / 10
    if snapped < Config.band.min - 1e-6 or snapped > Config.band.max + 1e-6 then
        return nil, "out_of_band"
    end
    return ("%.1f"):format(snapped)
end

local function frequencyNumber(key)
    return tonumber(key)
end

local function currentEffect()
    if jam.active then
        local patched = {}
        for k, v in pairs(Config.effect) do patched[k] = v end
        for k, v in pairs(Config.jam.effect) do patched[k] = v end
        return patched
    end
    return Config.effect
end

-- Garble ASCII bytes only, so a multi-byte character is never cut in half.
local GARBLE = { "#", "-", "~", "k", "z", "s" }
local function garble(text)
    local out = {}
    for i = 1, #text do
        local c = text:sub(i, i)
        local b = c:byte()
        if b < 128 and c ~= " " and math.random() < Config.jam.garbleRatio then
            c = GARBLE[math.random(#GARBLE)]
        end
        out[#out + 1] = c
    end
    return table.concat(out)
end

---------------------------------------------------------------------------
-- Dependencies, all optional at runtime (pcall'd synchronous exports)
---------------------------------------------------------------------------

-- true / false, or nil when rp_inventory is not running.
local function holdsRadio(playerId)
    if not cfg("requireItem", Config.requireItem) then return true end
    local ok, has = pcall(function() return exports.rp_inventory:has(playerId, Config.itemId, 1) end)
    if not ok then return nil end
    return has == true
end

-- true when the player holds `job` and is on duty; false, reason otherwise; nil when rp_jobs is down.
local function onDutyAs(playerId, job)
    local ok, has = pcall(function() return exports.rp_jobs:hasJob(playerId, job) end)
    if not ok then return nil end
    if has ~= true then return false, "wrong_job" end
    local ok2, duty = pcall(function() return exports.rp_jobs:onDuty(playerId) end)
    if not ok2 then return nil end
    if duty ~= true then return false, "off_duty" end
    return true
end

local function inCutZone(playerId)
    if not cfg("badlandsCut", Config.badlandsCut) then return false end
    local ok, inside = pcall(function() return exports.rp_zones:isIn(playerId, Config.cutZone) end)
    return ok and inside == true
end

---------------------------------------------------------------------------
-- Persistence: SQL first (rp_radio_tuning), kvp only while the database is down
---------------------------------------------------------------------------

local function persist(playerId, key)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    local now = math.floor(Open77.time.unix())
    if dbReady then
        Open77.database.update(
            "INSERT INTO rp_radio_tuning (identifier, frequency, updated_at) VALUES (?, ?, ?) "
                .. "ON DUPLICATE KEY UPDATE frequency = VALUES(frequency), updated_at = VALUES(updated_at)",
            { identifier, key or "", now },   -- "" = off the air; a nil here would be a params hole
            function() end)
        return
    end
    if not kvpWarned then
        kvpWarned = true
        log("database not ready: remembering frequencies in the resource kvp store instead")
    end
    Open77.kvp.set("tuning:" .. identifier, key or "")
end

-- Runs inside a managed task (onPlayerReady handler): may await.
local function loadSaved(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return nil end
    if dbReady then
        local row = Open77.database.single.await(
            "SELECT frequency FROM rp_radio_tuning WHERE identifier = ?", { identifier })
        if row and row.frequency and row.frequency ~= "" then return row.frequency end
        return nil
    end
    local saved = Open77.kvp.get("tuning:" .. identifier, "")
    if saved and saved ~= "" then return saved end
    return nil
end

Open77.database.ready(function()
    Open77.database.update.await([[
        CREATE TABLE IF NOT EXISTS rp_radio_tuning (
            identifier VARCHAR(64) NOT NULL PRIMARY KEY,
            frequency  VARCHAR(8)  NULL,
            updated_at BIGINT      NOT NULL DEFAULT 0
        )
    ]])
    dbReady = true
    log("table rp_radio_tuning ready")
end)

---------------------------------------------------------------------------
-- Voice channels
---------------------------------------------------------------------------

-- No nil holes on the wire: absent values travel as false.
local function notifyClient(playerId, kind, key, channelId)
    Open77.net.emitClient("rp_radio:client", playerId, kind, key or false, channelId or false, jam.active)
end

local function ensureChannel(key)
    local ch = channels[key]
    if ch then return ch end
    if voiceAvailable == false then return nil, "voice_unavailable" end
    local created, reason = Open77.voice.createChannel({
        name = "Radio " .. key,
        mode = "radio",
        persistent = false,
        effect = currentEffect(),
    })
    if not created then
        if reason == "voice_unavailable" then voiceAvailable = false end
        log("createChannel %s refused: %s", key, tostring(reason))
        return nil, reason or "channel_refused"
    end
    voiceAvailable = true
    ch = { id = created.id, members = {}, count = 0 }
    channels[key] = ch
    log("channel %s created (%s)", key, tostring(created.id))
    return ch
end

local function dropChannelIfEmpty(key)
    local ch = channels[key]
    if not ch or ch.count > 0 then return end
    channels[key] = nil
    local ok, reason = Open77.voice.removeChannel(ch.id)
    if not ok then log("removeChannel %s: %s", key, tostring(reason)) end
    log("channel %s removed (empty)", key)
end

-- Put a tuned player with signal into the voice channel. true, or false, reason.
local function joinVoice(playerId, key)
    local ch, reason = ensureChannel(key)
    if not ch then return false, reason end
    if ch.members[playerId] then return true end
    local ok, why = Open77.voice.addPlayer(ch.id, playerId, { canSpeak = true, canListen = true })
    if not ok then
        dropChannelIfEmpty(key)
        return false, why or "add_refused"
    end
    ch.members[playerId] = true
    ch.count = ch.count + 1
    notifyClient(playerId, "tuned", key, ch.id)
    return true
end

local function leaveVoice(playerId)
    for key, ch in pairs(channels) do
        if ch.members[playerId] then
            ch.members[playerId] = nil
            ch.count = ch.count - 1
            local ok, reason = Open77.voice.removePlayer(ch.id, playerId)
            if not ok then log("removePlayer %s from %s: %s", tostring(playerId), key, tostring(reason)) end
            dropChannelIfEmpty(key)
        end
    end
end

-- Everyone tuned to `key` who has signal (voice member or text-only), ascending.
local function listeners(key)
    local out = {}
    for playerId, state in pairs(tuned) do
        if state.key == key and state.signal then out[#out + 1] = playerId end
    end
    table.sort(out)
    return out
end

local function sendLine(key, text, color)
    for _, playerId in ipairs(listeners(key)) do
        chat(playerId, text, color)
    end
end

---------------------------------------------------------------------------
-- Tune / untune
---------------------------------------------------------------------------

local function untune(playerId, why)
    local state = tuned[playerId]
    if not state then return false end
    leaveVoice(playerId)
    tuned[playerId] = nil
    notifyClient(playerId, "off", nil, nil)
    TriggerEvent("rp_radio:tuned", playerId, nil)
    if why then chat(playerId, why, Config.colors.info) end
    return true
end

-- Reserved-slot gate. true, or false, message.
local function mayTune(playerId, key)
    local reserved = Config.reserved[key]
    if not reserved then return true end
    if reserved.external then
        return false, ("%s is %s: the precinct runs that channel itself (%s), officers are patched in while on duty."):format(
            key, reserved.label, reserved.external)
    end
    local ok, reason = onDutyAs(playerId, reserved.job)
    if ok == nil then
        return false, ("%s is reserved for %s and the job registry is offline. Try again later."):format(key, reserved.label)
    end
    if not ok then
        if reason == "off_duty" then
            return false, ("%s is %s only. Clock in first (/service)."):format(key, reserved.label)
        end
        return false, ("%s is %s only. Not your band, choom."):format(key, reserved.label)
    end
    return true
end

-- Full tune flow; `quiet` skips the "Tuned to" line (used by the remembered dial).
local function tune(playerId, key, quiet)
    local allowed, message = mayTune(playerId, key)
    if not allowed then
        chat(playerId, message, Config.colors.warn)
        return false, "reserved"
    end
    local holds = holdsRadio(playerId)
    if holds == nil then
        chat(playerId, "Inventory system offline: no way to check your pockets for a radio.", Config.colors.warn)
        return false, "inventory_offline"
    end
    if not holds then
        chat(playerId, "No radio in your pockets. Find one before you tune the band.", Config.colors.warn)
        return false, "no_radio"
    end

    local previous = tuned[playerId]
    if previous and previous.key == key then
        chat(playerId, ("Already on %s."):format(key), Config.colors.info)
        return true
    end
    if previous then leaveVoice(playerId) end

    local state = { key = key, signal = not inCutZone(playerId) }
    tuned[playerId] = state
    persist(playerId, key)
    TriggerEvent("rp_radio:tuned", playerId, frequencyNumber(key))

    local label = Config.reserved[key] and (" (" .. Config.reserved[key].label .. ")") or ""
    if not state.signal then
        notifyClient(playerId, "tuned", key, nil)
        chat(playerId, ("Tuned to %s%s. No signal out here in the Badlands."):format(key, label), Config.colors.warn)
        return true
    end

    local joined, reason = joinVoice(playerId, key)
    if not joined then
        -- Text still works: the player stays tuned without a voice route.
        notifyClient(playerId, "tuned", key, nil)
        if not quiet then
            chat(playerId, ("Tuned to %s%s. Voice is offline (%s): text only, /radio dire <text>."):format(
                key, label, tostring(reason)), Config.colors.warn)
        end
        return true
    end
    if not quiet then
        local others = #listeners(key) - 1
        local who = others > 0 and ("%d other%s on the band"):format(others, others > 1 and "s" or "") or "nobody else on the band yet"
        chat(playerId, ("Tuned to %s%s. Hold %s to talk, %s."):format(key, label, Config.ptt.key, who), Config.colors.radio)
        if jam.active then
            chat(playerId, ("[RADIO %s] kzzzt--- the band is jammed ---kzzt"):format(key), Config.colors.static)
        end
    end
    return true
end

-- Signal lost / regained (Badlands cut).
local function setSignal(playerId, hasSignal)
    local state = tuned[playerId]
    if not state or state.signal == hasSignal then return end
    state.signal = hasSignal
    if hasSignal then
        if holdsRadio(playerId) == false then
            untune(playerId, "Your radio is gone. The band stays silent.")
            return
        end
        local joined, reason = joinVoice(playerId, state.key)
        if joined then
            chat(playerId, ("Signal is back. %s crackles to life."):format(state.key), Config.colors.radio)
        else
            notifyClient(playerId, "tuned", state.key, nil)
            chat(playerId, ("Signal is back on %s, voice offline (%s): text only."):format(state.key, tostring(reason)), Config.colors.warn)
        end
    else
        leaveVoice(playerId)
        notifyClient(playerId, "tuned", state.key, nil)
        chat(playerId, "No signal out here. Your radio only hisses.", Config.colors.warn)
    end
end

---------------------------------------------------------------------------
-- Jam (rp_netrunner:jammed)
---------------------------------------------------------------------------

local function applyJamToChannels()
    local effect = currentEffect()
    for key, ch in pairs(channels) do
        local patched, reason = Open77.voice.updateChannel(ch.id, { effect = effect })
        if not patched then log("updateChannel %s: %s", key, tostring(reason)) end
        for playerId in pairs(ch.members) do
            notifyClient(playerId, "jam", key, ch.id)
        end
    end
end

local function setJam(active)
    if jam.active == active then return end
    jam.active = active
    jam.token = jam.token + 1
    applyJamToChannels()
    if not active then
        for key in pairs(channels) do
            sendLine(key, ("[RADIO %s] ---kzzt... carrier is back. Band is clear."):format(key), Config.colors.static)
        end
        log("jam over")
        return
    end
    log("jam started: static on every channel")
    local token = jam.token
    CreateThread(function()
        while jam.active and jam.token == token do
            for playerId, state in pairs(tuned) do
                if state.signal then
                    chat(playerId, ("[RADIO %s] %s"):format(state.key, Config.staticLines[math.random(#Config.staticLines)]), Config.colors.static)
                end
            end
            Wait(Config.jam.staticIntervalMs)
        end
    end)
end

---------------------------------------------------------------------------
-- Text on the band
---------------------------------------------------------------------------

-- Deliver one `[RADIO key]` line to everyone tuned with signal. Returns the count.
local function broadcastText(key, text, author)
    local line = author and ("%s: %s"):format(author, text) or text
    if jam.active and Config.jam.garbleText then line = garble(line) end
    local reserved = Config.reserved[key]
    if reserved and reserved.external then
        -- rp_ncpd owns the dispatch voice channel; the text goes to its on-duty roster.
        local ok, roster = pcall(function() return exports.rp_jobs:listOnDuty(reserved.job) end)
        if not ok or type(roster) ~= "table" then return nil, "roster_unavailable" end
        for _, playerId in ipairs(roster) do
            chat(playerId, ("[RADIO %s] %s"):format(key, line), Config.colors.radio)
        end
        return #roster
    end
    local targets = listeners(key)
    for _, playerId in ipairs(targets) do
        chat(playerId, ("[RADIO %s] %s"):format(key, line), Config.colors.radio)
    end
    return #targets
end

---------------------------------------------------------------------------
-- Command: /radio
---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/radio", help = "Handheld radio: /radio <87.5-108.0> tunes, /radio off, /radio dire <text>, /radio alone shows the band",
      parameters = { { name = "freq | off | dire", help = "frequency (e.g. 95.5), off, or dire <text>" } } },
}

RegisterCommand("radio", function(source, args)
    if source == 0 then
        print("radio: run this from the game, not the console")
        return
    end
    local first = args[1] and args[1]:lower() or nil

    -- /radio : status
    if not first then
        local state = tuned[source]
        if not state then
            chat(source, ("Radio: off. /radio <%.1f-%.1f> to tune, then hold %s to talk or /radio dire <text>."):format(
                Config.band.min, Config.band.max, Config.ptt.key), Config.colors.info)
            Wait(0)
            local parts = {}
            for key, r in pairs(Config.reserved) do parts[#parts + 1] = key .. " " .. r.label end
            table.sort(parts)
            chat(source, "Reserved: " .. table.concat(parts, ", ") .. " (matching job, on duty).", Config.colors.info)
            return
        end
        local key = state.key
        local label = Config.reserved[key] and (" " .. Config.reserved[key].label) or ""
        local names = {}
        for _, playerId in ipairs(listeners(key)) do names[#names + 1] = playerName(playerId) end
        local status
        if not state.signal then
            status = "NO SIGNAL (Badlands)"
        elseif jam.active then
            status = "JAMMED"
        else
            local ch = channels[key]
            status = (ch and ch.members[source]) and "voice + text" or "text only (voice offline)"
        end
        chat(source, ("Radio: %s%s - %s."):format(key, label, status), Config.colors.radio)
        Wait(0)
        if #names > 0 then
            chat(source, ("On the band (%d): %s"):format(#names, table.concat(names, ", ")), Config.colors.info)
        else
            chat(source, "On the band: nobody with signal.", Config.colors.info)
        end
        return
    end

    -- /radio off
    if first == "off" then
        if not untune(source, "Radio off.") then
            chat(source, "Your radio is already off.", Config.colors.info)
            return
        end
        persist(source, nil)   -- forget the dial: the next session must not re-tune it
        return
    end

    -- /radio dire <text>
    if first == "dire" then
        local state = tuned[source]
        if not state then
            chat(source, "Tune a frequency first: /radio <freq>.", Config.colors.warn)
            return
        end
        if not state.signal then
            chat(source, "No signal out here. Nothing gets through.", Config.colors.warn)
            return
        end
        local words = {}
        for i = 2, (args.n or #args) do words[#words + 1] = args[i] end
        local text = table.concat(words, " ")
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
            chat(source, "Usage: /radio dire <text>", Config.colors.warn)
            return
        end
        if #text > Config.maxTextLength then text = text:sub(1, Config.maxTextLength) end
        local delivered, reason = broadcastText(state.key, text, playerName(source))
        if not delivered then
            chat(source, "Nobody picked that up: " .. tostring(reason), Config.colors.warn)
        end
        return
    end

    -- /radio <freq>
    local key, reason = parseFrequency(args[1])
    if not key then
        if reason == "out_of_band" then
            chat(source, ("Out of band. The dial goes from %.1f to %.1f in %.1f steps."):format(
                Config.band.min, Config.band.max, Config.band.step), Config.colors.warn)
        else
            chat(source, "Usage: /radio <frequency> | off | dire <text>. Example: /radio 95.5", Config.colors.warn)
        end
        return
    end
    tune(source, key, false)
end, false)

---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
---------------------------------------------------------------------------

exports("channelOf", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return nil end
    local state = tuned[playerId]
    if not state then return nil end
    return frequencyNumber(state.key), state.signal
end)

exports("broadcast", function(frequency, text)
    if type(text) ~= "string" or text == "" then return nil, "invalid_text" end
    local key, reason = parseFrequency(frequency)
    if not key then return nil, "invalid_frequency:" .. tostring(reason) end
    if #text > Config.maxTextLength then text = text:sub(1, Config.maxTextLength) end
    return broadcastText(key, text, nil)
end)

---------------------------------------------------------------------------
-- Lifecycle and bus events
---------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    local status, reason = Open77.voice.status()
    if not status then
        voiceAvailable = false
        log("voice unavailable (%s): radio channels run in text-only mode", tostring(reason))
    elseif status.enabled == false then
        voiceAvailable = false
        log("voice disabled in server.jsonc: radio channels run in text-only mode")
    else
        log("voice ready (quality %s)", tostring(status.quality))
    end
    local okJam, jamming = pcall(function() return exports.rp_netrunner:isJamming() end)
    if okJam and jamming == true then setJam(true) end
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    log("started: %s-%s MHz, cut zone %s (%s), PTT %s", ("%.1f"):format(Config.band.min),
        ("%.1f"):format(Config.band.max), Config.cutZone, Config.badlandsCut and "on" or "off", Config.ptt.key)
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then
        Open77.chat.addSuggestions(source, SUGGESTIONS)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId or not cfg("rememberFrequency", Config.rememberFrequency) then return end
    local key = loadSaved(playerId)
    if not key or not parseFrequency(key) then return end
    -- Let rp_inventory finish loading the pockets before the item check.
    Wait(Config.rememberDelayMs)
    if tuned[playerId] then return end
    if Open77.players.name(playerId) == nil then return end
    if holdsRadio(playerId) ~= true then return end
    local allowed = mayTune(playerId, key)
    if not allowed then return end
    if tune(playerId, key, true) then
        chat(playerId, ("Radio back on %s (hold %s to talk)."):format(key, Config.ptt.key), Config.colors.radio)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId or not tuned[playerId] then return end
    leaveVoice(playerId)
    tuned[playerId] = nil
    TriggerEvent("rp_radio:tuned", playerId, nil)
end)

-- Badlands cut.
AddEventHandler("rp_zones:entered", function(playerId, name)
    if name ~= Config.cutZone or not cfg("badlandsCut", Config.badlandsCut) then return end
    playerId = tonumber(playerId)
    if playerId then setSignal(playerId, false) end
end)

AddEventHandler("rp_zones:left", function(playerId, name)
    if name ~= Config.cutZone or not cfg("badlandsCut", Config.badlandsCut) then return end
    playerId = tonumber(playerId)
    if playerId and tuned[playerId] then setSignal(playerId, true) end
end)

-- Netrunner jam.
AddEventHandler("rp_netrunner:jammed", function(active)
    setJam(active == true)
end)

-- Reserved slots follow the job and the duty flag.
local function enforceReserved(playerId, why)
    playerId = tonumber(playerId)
    local state = playerId and tuned[playerId]
    if not state or not Config.reserved[state.key] then return end
    local allowed = mayTune(playerId, state.key)
    if not allowed then untune(playerId, why) end
end

AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    if onDuty == true then return end
    enforceReserved(playerId, "Off duty: the reserved channel dropped you. Radio off.")
end)

AddEventHandler("rp_jobs:changed", function(playerId)
    enforceReserved(playerId, "That band belongs to your old job. Radio off.")
end)

-- Losing the handheld switches it off.
AddEventHandler("rp_inventory:changed", function(playerId, itemId, delta)
    if itemId ~= Config.itemId then return end
    if type(delta) == "number" and delta >= 0 then return end
    playerId = tonumber(playerId)
    if not playerId or not tuned[playerId] then return end
    if holdsRadio(playerId) == false then
        untune(playerId, "Your radio is gone. The band goes silent.")
    end
end)
