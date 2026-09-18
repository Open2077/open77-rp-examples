-- rp_ferrailleur (server): wrecks, loot, the crowbar's wear, the scrap dealer and its prices.
-- Server-authoritative: the client only draws rings and forwards the E prompt as an intent.

local Config = RpFerrailleurConfig
local RESOURCE = GetCurrentResourceName()
local CROWBAR = Config.crowbar.id

-- Items this resource declares in rp_inventory (re-declared whenever rp_inventory restarts).
local ITEMS = {
    [CROWBAR] = { label = Config.crowbar.label, weight = Config.crowbar.weight, usable = false, illegal = false },
}

-- State -------------------------------------------------------------------------------------

local points = {}          -- index -> { state = "ready"|"busy"|"depleted", readyAt = unix, busyBy = playerId|nil }
local prices = {}          -- itemId -> unit price today
local pricesRolledAt = 0   -- unix seconds
local tools = {}           -- identifier -> durability (write-through cache of rp_ferrailleur_tools)
local loadedTools = {}     -- playerId (number) -> identifier once the row was read
local searching = {}       -- playerId -> point index while the progress bar runs
local store = nil          -- "sql" | "kvp", decided once per boot
local dealerNpcId = nil

for i = 1, #Config.points do
    points[i] = { state = "ready", readyAt = 0, busyBy = nil }
end

-- Helpers -----------------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_ferrailleur] " .. fmt):format(...))
end

local function say(playerId, text)
    Open77.chat.send(playerId, { author = "Scrapyard", text = text, color = { 214, 190, 120 } })
end

local function toast(playerId, kind, title, message)
    Open77.notifications.send(playerId, {
        type = kind, title = title, message = message, durationMs = 6000, icon = "SCRAP",
    })
end

local function planar(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function within(pos, spot, reach)
    return planar(pos, spot) <= reach and math.abs(pos.z - spot.z) <= Config.heightTolerance
end

local function eddies(n)
    return ("%d €$"):format(n)
end

local function minutesLeft(unixTarget)
    local left = math.max(0, unixTarget - Open77.time.unix())
    if left < 60 then return ("%d s"):format(math.ceil(left)) end
    return ("%d min"):format(math.ceil(left / 60))
end

-- Synchronous export of a sibling resource, inside pcall: a missing resource raises.
-- Returns the export's own values, or nil, "unavailable:<resource>" when the call never happened.
local function callExport(resource, name, ...)
    local args = table.pack(...)
    local ok, r1, r2 = pcall(function()
        local target = exports[resource]
        return target[name](target, table.unpack(args, 1, args.n))
    end)
    if not ok then
        return nil, "unavailable:" .. resource
    end
    return r1, r2
end

-- UI kit server twin: nil, reason when the widget never opened; { ok, outcome, value } otherwise.
local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Job -----------------------------------------------------------------------------------------

-- true, or nil + a reason token: jobs_offline | not_scrapper | off_duty
local function checkDuty(playerId)
    local has, reason = callExport("rp_jobs", "hasJob", playerId, Config.job)
    if has == nil and reason then return nil, "jobs_offline" end
    if not has then return nil, "not_scrapper" end
    local duty = callExport("rp_jobs", "onDuty", playerId)
    if not duty then return nil, "off_duty" end
    return true
end

local DUTY_TEXT = {
    jobs_offline = "The scrappers' guild (rp_jobs) is offline. Try again later.",
    not_scrapper = "You are no scrapper, choom. Sign up at the employment agency (/agence).",
    off_duty = "Clock in first: /service.",
}

-- Prices ------------------------------------------------------------------------------------

local function rollPrices()
    for _, id in ipairs(Config.sellOrder) do
        local base = Config.basePrices[id]
        local swing = (math.random() * 2 - 1) * Config.priceVariation
        prices[id] = math.max(1, math.floor(base * (1 + swing) + 0.5))
    end
    pricesRolledAt = Open77.time.unix()
    log("prices scrap=%d component=%d chip=%d (next roll in %d min)",
        prices.scrap, prices.component, prices.chip, Config.priceIntervalMs // 60000)
end

local function priceLine()
    local parts = {}
    for _, id in ipairs(Config.sellOrder) do
        local base = Config.basePrices[id]
        local trend = prices[id] > base and "up" or (prices[id] < base and "down" or "flat")
        parts[#parts + 1] = ("%s %d €$ (%s)"):format(id, prices[id], trend)
    end
    local nextRoll = pricesRolledAt + Config.priceIntervalMs / 1000
    return ("Prices today: %s - next change in %s."):format(table.concat(parts, ", "), minutesLeft(nextRoll))
end

-- Crowbar durability (SQL first, kvp fallback) ---------------------------------------------

local function saveTool(identifier, durability)
    if store == "sql" then
        Open77.database.update(
            "INSERT INTO rp_ferrailleur_tools (identifier, durability, updated_at) VALUES (?, ?, ?) " ..
            "ON DUPLICATE KEY UPDATE durability = VALUES(durability), updated_at = VALUES(updated_at)",
            { identifier, durability, math.floor(Open77.time.unix()) },
            function() end)
    else
        local ok, reason = Open77.kvp.set("tool:" .. identifier, durability)
        if not ok then log("kvp write failed for %s: %s", identifier, tostring(reason)) end
    end
end

-- Waits (up to the grace period) for the store decision, then reads the player's row.
local function loadTool(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    local waited = 0
    while store == nil and waited < Config.databaseGraceMs do
        Wait(500)
        waited = waited + 500
    end
    if store == nil then
        store = "kvp"
        log("store=kvp reason=database_not_ready_after_%dms", Config.databaseGraceMs)
    end
    if store == "sql" then
        Open77.database.single("SELECT durability FROM rp_ferrailleur_tools WHERE identifier = ?", { identifier },
            function(row)
                tools[identifier] = row and tonumber(row.durability) or nil
                loadedTools[playerId] = identifier
                log("player %d tool loaded durability=%s (sql)", playerId, tostring(tools[identifier]))
            end)
    else
        local value = Open77.kvp.get("tool:" .. identifier, nil)
        tools[identifier] = tonumber(value)
        loadedTools[playerId] = identifier
        log("player %d tool loaded durability=%s (kvp)", playerId, tostring(tools[identifier]))
    end
end

local function crowbarCount(playerId)
    local count = callExport("rp_inventory", "count", playerId, CROWBAR)
    return type(count) == "number" and count or 0
end

-- The durability of the crowbar the player holds. A crowbar with no recorded wear (bought
-- elsewhere, handed over by an admin, or picked up after the last one broke) is a fresh one.
local function currentDurability(playerId, identifier)
    local d = tools[identifier]
    if (d == nil or d <= 0) and crowbarCount(playerId) > 0 then
        d = Config.crowbar.durability
        tools[identifier] = d
        saveTool(identifier, d)
    end
    return d or 0
end

local function wearCrowbar(playerId, identifier)
    local d = currentDurability(playerId, identifier) - 1
    if d <= 0 then
        local removed, reason = callExport("rp_inventory", "remove", playerId, CROWBAR, 1)
        if not removed then log("player %d crowbar removal refused: %s", playerId, tostring(reason)) end
        if crowbarCount(playerId) > 0 then
            d = Config.crowbar.durability
            say(playerId, "Your crowbar snapped in half! Lucky you carry a spare.")
        else
            d = 0
            say(playerId, ("Your crowbar snapped in half. The dealer sells a new one for %s."):format(eddies(Config.crowbar.price)))
        end
        toast(playerId, "warning", "Crowbar broken", "It gave everything it had.")
    elseif d <= 3 then
        say(playerId, ("Your crowbar is bending: %d searches left."):format(d))
    end
    tools[identifier] = d
    saveTool(identifier, d)
    return d
end

-- Points --------------------------------------------------------------------------------------

local function stateOf(i)
    local p = points[i]
    return { index = i, state = p.state, readyAt = p.readyAt }
end

local function broadcastPoint(i, target)
    TriggerClientEvent("rp_ferrailleur:pointState", target or -1, i, points[i].state, points[i].readyAt)
end

local function allStates()
    local list = {}
    for i = 1, #points do list[#list + 1] = stateOf(i) end
    return list
end

local function regeneratingCount()
    local n, soonest = 0, nil
    for _, p in ipairs(points) do
        if p.state == "depleted" then
            n = n + 1
            if soonest == nil or p.readyAt < soonest then soonest = p.readyAt end
        end
    end
    return n, soonest
end

local function depletePoint(i)
    local p = points[i]
    p.state = "depleted"
    p.busyBy = nil
    p.readyAt = Open77.time.unix() + Config.regenMs / 1000
    broadcastPoint(i)
    local expected = p.readyAt
    SetTimeout(Config.regenMs, function()
        if p.state == "depleted" and p.readyAt == expected then
            p.state = "ready"
            p.readyAt = 0
            broadcastPoint(i)
            log("wreck %d regenerated", i)
        end
    end)
end

local function releasePoint(i)
    local p = points[i]
    if p.state == "busy" then
        p.state = "ready"
        p.busyBy = nil
        broadcastPoint(i)
    end
end

local function rollLoot()
    local total = 0
    for _, entry in ipairs(Config.loot) do total = total + entry.weight end
    local r = math.random() * total
    for _, entry in ipairs(Config.loot) do
        r = r - entry.weight
        if r <= 0 then
            return entry.item, math.random(entry.min, entry.max)
        end
    end
    local last = Config.loot[#Config.loot]
    return last.item, math.random(last.min, last.max)
end

-- The whole search, run as the net-event handler's own managed task (it may Wait).
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

local STAGE = RpFerrailleurConfig.Stage or {}
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

local function searchWreck(playerId, index)
    local point = Config.points[index]
    local pos = Open77.players.position(playerId)
    if not pos then
        say(playerId, "The yard cannot place you. Move a little and try again.")
        return
    end
    if not within(pos, point, Config.searchReach) then
        say(playerId, ("Get closer to the wreck (%.0f m)."):format(planar(pos, point)))
        return
    end
    -- rp_zones' own verdict when it runs (a moved point outside the yard is refused here).
    local inZone = callExport("rp_zones", "isIn", playerId, Config.zone)
    if inZone == false then
        say(playerId, "You are outside the junkyard. The wrecks are inside the yard's ring.")
        return
    end
    local ok, why = checkDuty(playerId)
    if not ok then
        say(playerId, DUTY_TEXT[why] or why)
        return
    end
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    if loadedTools[playerId] ~= identifier then
        say(playerId, "Your tool file is still loading. Try again in a moment.")
        return
    end
    if crowbarCount(playerId) <= 0 then
        local has, reason = callExport("rp_inventory", "has", playerId, CROWBAR, 1)
        if has == nil and reason then
            say(playerId, "The pockets system (rp_inventory) is offline.")
        else
            say(playerId, ("You need a crowbar to pry a wreck open. %s sells one for %s."):format(Config.dealer.name, eddies(Config.crowbar.price)))
        end
        return
    end
    if searching[playerId] then
        say(playerId, "You are already working a wreck.")
        return
    end
    local p = points[index]
    if p.state == "busy" then
        say(playerId, "Someone is already working this wreck.")
        return
    end
    if p.state == "depleted" then
        say(playerId, ("This wreck has been picked clean. Back in %s."):format(minutesLeft(p.readyAt)))
        return
    end

    -- Claim the wreck, kneel, and run the bar.
    p.state = "busy"
    p.busyBy = playerId
    broadcastPoint(index)
    searching[playerId] = index

    -- Staged: the kneel, the crowbar in the hand and the bar, all for Config.searchMs.
    local answer, reason = stage(playerId, "search", { label = "Searching the wreck", durationMs = Config.searchMs })

    searching[playerId] = nil

    if answer == nil then
        releasePoint(index)
        say(playerId, ("The search never started (%s)."):format(tostring(reason)))
        return
    end
    if not answer.ok then
        releasePoint(index)
        say(playerId, "You stop searching.")
        return
    end

    -- Eight seconds is long enough to be somewhere else, or to have lost the tool.
    pos = Open77.players.position(playerId)
    if not pos or not within(pos, point, Config.searchReach + 1.5) then
        releasePoint(index)
        say(playerId, "You walked away from the wreck. Nothing found.")
        return
    end
    if crowbarCount(playerId) <= 0 then
        releasePoint(index)
        say(playerId, "Your crowbar is gone. Nothing found.")
        return
    end

    -- The wreck is spent and the tool worn whatever the pockets say.
    local item, count = rollLoot()
    depletePoint(index)
    local durability = wearCrowbar(playerId, identifier)

    local added, addReason = callExport("rp_inventory", "add", playerId, item, count)
    if not added then
        if addReason == "too_heavy" then
            say(playerId, ("You dig out %d x %s but your pockets are too heavy. It stays in the dirt."):format(count, item))
        else
            say(playerId, ("You dig out %d x %s but cannot pocket it (%s)."):format(count, item, tostring(addReason)))
        end
        log("player %d wreck %d loot %s x%d refused: %s", playerId, index, item, count, tostring(addReason))
        return
    end
    log("player %d wreck %d +%d %s durability=%d", playerId, index, count, item, durability)
    gesture(playerId, "loot")
    say(playerId, ("Pried open %s: +%d x %s. Crowbar %d/%d."):format(
        point.label or ("wreck " .. index), count, item, durability, Config.crowbar.durability))
    toast(playerId, "success", "Wreck searched", ("+%d x %s"):format(count, item))
    TriggerEvent("rp_ferrailleur:searched", playerId, index, item, count)
end

-- Dealer ------------------------------------------------------------------------------------

local function spawnDealer()
    local base = {
        position = Config.dealer.position,
        yaw = Config.dealer.yaw,
        damagePolicy = Config.dealer.damagePolicy,
        behavior = { combatEnabled = false, voiceEnabled = false },
        persistent = false,
    }
    if Config.dealer.record then
        local def = {}
        for k, v in pairs(base) do def[k] = v end
        def.record = Config.dealer.record
        local id, reason = Open77.npcs.create(def)
        if id then
            dealerNpcId = id
            log("dealer spawned record=%s id=%s", Config.dealer.record, tostring(id))
            return
        end
        log("dealer record %s refused (%s), falling back to alias %s",
            Config.dealer.record, tostring(reason), Config.dealer.template)
    end
    base.template = Config.dealer.template
    local id, reason = Open77.npcs.create(base)
    if not id then
        log("dealer alias %s refused: %s - the prompt and /vendre still work at the spot", Config.dealer.template, tostring(reason))
        return
    end
    dealerNpcId = id
    log("dealer spawned template=%s id=%s at %.1f %.1f %.1f",
        Config.dealer.template, tostring(id), Config.dealer.position.x, Config.dealer.position.y, Config.dealer.position.z)
end

local function nearDealer(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then return false, nil end
    return within(pos, Config.dealer.position, Config.dealer.reach), planar(pos, Config.dealer.position)
end

-- Sells every scrap/component/chip in the pockets. Cash to the scrapper, the society's share to rp_bank.
local function sellAll(playerId)
    local sold, total = {}, 0
    for _, id in ipairs(Config.sellOrder) do
        local count, countReason = callExport("rp_inventory", "count", playerId, id)
        if count == nil and countReason then
            say(playerId, "The pockets system (rp_inventory) is offline. No sale.")
            return
        end
        if type(count) == "number" and count > 0 then
            local removed = callExport("rp_inventory", "remove", playerId, id, count)
            if removed then
                sold[#sold + 1] = { id = id, count = count, price = prices[id] }
                total = total + count * prices[id]
            end
        end
    end
    if total <= 0 then
        say(playerId, ("%s: \"Nothing to sell, choom. Bring me scrap, components or chips.\""):format(Config.dealer.name))
        return
    end
    local cut = math.floor(total * Config.societyShare + 0.5)
    if cut >= total then cut = total - 1 end
    local payout = total - cut

    -- Staged: the scrap held out to Rusty behind a short bar; the goods are already out of
    -- the pockets, so a cancel puts them back.
    local weighed = stage(playerId, "sell", { label = "Weighing the scrap" })
    if not weighed or not weighed.ok then
        for _, s in ipairs(sold) do callExport("rp_inventory", "add", playerId, s.id, s.count) end
        say(playerId, "You keep the scrap. Rusty shrugs.")
        return
    end

    local newBalance, reason = callExport("rp_economy", "add", playerId, payout, "scrap_sale")
    if not newBalance then
        for _, s in ipairs(sold) do
            callExport("rp_inventory", "add", playerId, s.id, s.count)
        end
        say(playerId, ("The dealer's wallet is offline (%s). Your goods are back in your pockets."):format(tostring(reason)))
        return
    end
    if cut > 0 then
        local societyBalance, bankReason = callExport("rp_bank", "societyAdd", Config.society, cut, "scrap_sale:" .. playerId)
        if not societyBalance then
            log("society %s +%d refused: %s", Config.society, cut, tostring(bankReason))
        end
    end

    local parts = {}
    for _, s in ipairs(sold) do
        parts[#parts + 1] = ("%d x %s @ %d"):format(s.count, s.id, s.price)
    end
    log("player %d sold %s total=%d payout=%d society=%d cash=%d",
        playerId, table.concat(parts, ", "), total, payout, cut, newBalance)
    say(playerId, ("Sold %s for %s. You pocket %s, the guild takes %s. Cash: %s."):format(
        table.concat(parts, ", "), eddies(total), eddies(payout), eddies(cut), eddies(newBalance)))
    toast(playerId, "success", "Scrap sold", ("+%s cash"):format(eddies(payout)))
    TriggerEvent("rp_ferrailleur:sold", playerId, total, payout, cut)
end

local function buyCrowbar(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    if loadedTools[playerId] ~= identifier then
        say(playerId, "Your tool file is still loading. Try again in a moment.")
        return
    end
    if crowbarCount(playerId) > 0 then
        say(playerId, ("%s: \"You already carry a crowbar. Wear it out first.\""):format(Config.dealer.name))
        return
    end
    local price = Config.crowbar.price
    local newBalance, reason = callExport("rp_economy", "remove", playerId, price, "crowbar")
    if not newBalance then
        if reason == "insufficient_funds" then
            say(playerId, ("A crowbar is %s cash. Come back with the eddies."):format(eddies(price)))
        else
            say(playerId, ("The dealer's wallet is offline (%s)."):format(tostring(reason)))
        end
        return
    end
    local added, addReason = callExport("rp_inventory", "add", playerId, CROWBAR, 1)
    if not added then
        callExport("rp_economy", "add", playerId, price, "crowbar_refund")
        if addReason == "too_heavy" then
            say(playerId, ("Your pockets are too heavy for a crowbar (%.1f kg). Refunded."):format(Config.crowbar.weight))
        else
            say(playerId, ("The dealer cannot hand you the crowbar (%s). Refunded."):format(tostring(addReason)))
        end
        return
    end
    tools[identifier] = Config.crowbar.durability
    saveTool(identifier, Config.crowbar.durability)
    local societyBalance, bankReason = callExport("rp_bank", "societyAdd", Config.society, price, "crowbar_sale:" .. playerId)
    if not societyBalance then
        log("society %s +%d (crowbar) refused: %s", Config.society, price, tostring(bankReason))
    end
    log("player %d bought a crowbar for %d cash=%d", playerId, price, newBalance)
    gesture(playerId, "buy")
    say(playerId, ("Bought a crowbar for %s. Good for %d searches. Cash: %s."):format(
        eddies(price), Config.crowbar.durability, eddies(newBalance)))
end

local function openDealer(playerId)
    local near, distance = nearDealer(playerId)
    if not near then
        if distance then
            say(playerId, ("%s is not within %.0f m (you are %.0f m away)."):format(Config.dealer.name, Config.dealer.reach, distance))
        else
            say(playerId, "The yard cannot place you. Move a little and try again.")
        end
        return
    end
    local metadata = {}
    for _, id in ipairs(Config.sellOrder) do
        local count = callExport("rp_inventory", "count", playerId, id)
        metadata[#metadata + 1] = {
            label = id,
            value = ("%d €$ (you: %d)"):format(prices[id], type(count) == "number" and count or 0),
        }
    end
    local answer, reason = uikit("context", playerId, {
        id = "rp_ferrailleur_dealer",
        title = ("%s, scrap dealer"):format(Config.dealer.name),
        description = "Eddies for junk, no questions asked.",
        options = {
            { id = "sell", label = "Sell scrap", icon = "€$",
              description = "Everything sellable in your pockets, at today's prices.", metadata = metadata },
            { id = "buy", label = "Buy a crowbar", icon = "T",
              description = ("Good for %d searches."):format(Config.crowbar.durability),
              metadata = { { label = "Price", value = eddies(Config.crowbar.price) } } },
            { id = "prices", label = "Prices today", icon = "?",
              description = "What the yard pays right now." },
            { id = "leave", label = "Leave", tone = "danger" },
        },
    }, { timeoutMs = 30000 })
    if answer == nil then
        say(playerId, ("The dealer's menu never opened (%s)."):format(tostring(reason)))
        return
    end
    if not answer.ok or not answer.value then return end
    local choice = answer.value.id
    if choice == "sell" then
        local stillNear = nearDealer(playerId)
        if not stillNear then say(playerId, "Come back to the dealer to sell.") return end
        sellAll(playerId)
    elseif choice == "buy" then
        local stillNear = nearDealer(playerId)
        if not stillNear then say(playerId, "Come back to the dealer to buy.") return end
        buyCrowbar(playerId)
    elseif choice == "prices" then
        say(playerId, priceLine())
    end
end

-- Chat suggestions --------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/ferraille", help = "Scrapper status: crowbar wear, today's prices, wrecks regenerating" },
    { command = "/vendre", help = "Sell every scrap, component and chip to the dealer (within 5 m)" },
}

-- Lifecycle ---------------------------------------------------------------------------------

local function defineItems()
    local ok, registered, rejected = pcall(function()
        return exports.rp_inventory:define(ITEMS)
    end)
    if not ok then
        log("rp_inventory:define unavailable (%s) - the crowbar cannot be pocketed until it runs", tostring(registered))
        return
    end
    log("items defined in rp_inventory: registered=%s rejected=%s", tostring(registered), tostring(rejected))
end

-- Decoration: the props of Config.props, created at start and removed at stop.
-- A refused prop only logs: the yard works without it.
local propIds = {}

local function spawnProps()
    for i, def in ipairs(Config.props or {}) do
        local id, reason = Open77.props.create({
            model = def.model,
            position = { x = def.position.x, y = def.position.y, z = def.position.z },
            yaw = def.yaw or 0.0,
            bucket = 0,
        })
        if id then
            propIds[#propIds + 1] = id
        else
            log("prop %d (%s) not spawned: %s", i, tostring(def.model), tostring(reason))
        end
    end
    if #propIds > 0 then log("props spawned: %d", #propIds) end
end

local function removeProps()
    for _, id in ipairs(propIds) do Open77.props.remove(id) end
    propIds = {}
end

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and name ~= RESOURCE then
        defineItems()
        return
    end
    if name ~= RESOURCE then return end

    defineItems()
    rollPrices()
    spawnDealer()
    spawnProps()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)

    -- Database: create the table once the connection answers; decide the store once.
    local queued, reason = Open77.database.ready(function()
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_ferrailleur_tools (
                identifier VARCHAR(64) PRIMARY KEY,
                durability INT NOT NULL DEFAULT 0,
                updated_at BIGINT NOT NULL DEFAULT 0
            )
        ]])
        if store == nil then
            store = "sql"
            log("store=sql table=rp_ferrailleur_tools")
        else
            log("database answered late; store already %s for this boot", store)
        end
    end)
    if not queued then
        store = "kvp"
        log("store=kvp reason=%s", tostring(reason))
    end

    -- Price roll every 10 min.
    CreateThread(function()
        while true do
            Wait(Config.priceIntervalMs)
            rollPrices()
        end
    end)

    -- Players already connected on a hot start.
    for _, playerId in ipairs(Open77.players.all()) do
        CreateThread(function() loadTool(playerId) end)
    end

    log("started: %d wrecks, dealer at %.1f %.1f %.1f, regen %d min, crowbar %d searches / %d €$",
        #Config.points, Config.dealer.position.x, Config.dealer.position.y, Config.dealer.position.z,
        Config.regenMs // 60000, Config.crowbar.durability, Config.crowbar.price)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    if dealerNpcId then
        Open77.npcs.remove(dealerNpcId)
        dealerNpcId = nil
    end
    removeProps()
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then
        Open77.chat.addSuggestions(source, SUGGESTIONS)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    loadTool(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    local index = searching[playerId]
    if index then
        searching[playerId] = nil
        releasePoint(index)
    end
    stageClear(playerId)
    for i, p in ipairs(points) do
        if p.state == "busy" and p.busyBy == playerId then releasePoint(i) end
    end
    loadedTools[playerId] = nil
end)

-- Net events from the client half --------------------------------------------------------

RegisterNetEvent("rp_ferrailleur:clientReady", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    TriggerClientEvent("rp_ferrailleur:allState", playerId, allStates())
end)

RegisterNetEvent("rp_ferrailleur:search", function(index)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    index = tonumber(index)
    if not index or index ~= math.floor(index) or not Config.points[index] then return end
    searchWreck(playerId, index)
end)

RegisterNetEvent("rp_ferrailleur:dealer", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    openDealer(playerId)
end)

-- Commands ------------------------------------------------------------------------------------

RegisterCommand("ferraille", function(source)
    if source == 0 then return print("ferraille: run it from the game, choom") end
    local identifier = Open77.players.identifier(source)
    if not identifier then return end

    local duty, why = checkDuty(source)
    local jobLine
    if duty then
        jobLine = "Scrapper on duty."
    elseif why == "off_duty" then
        jobLine = "Scrapper, off duty (/service to clock in)."
    elseif why == "not_scrapper" then
        jobLine = "Not a scrapper (/agence to sign up)."
    else
        jobLine = "The scrappers' guild is offline."
    end

    local count = crowbarCount(source)
    local toolLine
    if loadedTools[source] ~= identifier then
        toolLine = "Crowbar: tool file still loading."
    elseif count > 0 then
        local d = currentDurability(source, identifier)
        toolLine = ("Crowbar: %d/%d searches left%s."):format(
            d, Config.crowbar.durability, count > 1 and (" (+%d spare)"):format(count - 1) or "")
    else
        toolLine = ("No crowbar. %s sells one for %s."):format(Config.dealer.name, eddies(Config.crowbar.price))
    end

    local n, soonest = regeneratingCount()
    local wreckLine
    if n == 0 then
        wreckLine = ("All %d wrecks are ready to be searched."):format(#points)
    else
        wreckLine = ("%d of %d wrecks picked clean, next one back in %s."):format(n, #points, minutesLeft(soonest))
    end

    say(source, jobLine .. " " .. toolLine)
    Wait(0)
    say(source, priceLine())
    Wait(0)
    say(source, wreckLine .. (" Yard: %.0f, %.0f."):format(Config.dealer.position.x, Config.dealer.position.y))
end, false)

RegisterCommand("vendre", function(source)
    if source == 0 then return print("vendre: run it from the game, choom") end
    local near, distance = nearDealer(source)
    if not near then
        if distance then
            say(source, ("%s is not within %.0f m (you are %.0f m away). The yard is at %.0f, %.0f."):format(
                Config.dealer.name, Config.dealer.reach, distance, Config.dealer.position.x, Config.dealer.position.y))
        else
            say(source, "The yard cannot place you. Move a little and try again.")
        end
        return
    end
    sellAll(source)
end, false)

-- Exports (read-only, never yield) ---------------------------------------------------------

exports("prices", function()
    local copy = {}
    for _, id in ipairs(Config.sellOrder) do copy[id] = prices[id] end
    return copy
end)

exports("durability", function(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId <= 0 or playerId % 1 ~= 0 then return nil, "invalid_player_id" end
    playerId = math.tointeger(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return nil, "player_not_found" end
    if loadedTools[playerId] ~= identifier then return nil, "not_loaded" end
    if crowbarCount(playerId) <= 0 then return 0 end
    return currentDurability(playerId, identifier)
end)

exports("pointStates", function()
    return allStates()
end)
