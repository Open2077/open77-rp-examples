-- rp_fixer server: the fixer's gig board.
--
-- Everything that matters is decided here: which gigs are open, who holds one, the
-- phase they are in, the clock, the pay, the fixer's cut, the reputation and the
-- NPCs (guards, escorts, targets). The client only draws rings, pins and prompts and
-- tells the server which prompt was pressed; the server measures the distance itself.
--
-- Storage: SQL first (rp_fixer_gigs, rp_fixer_reputation) through Open77.database,
-- Open77.kvp only when the server has no database. Reputation lives in an in-memory
-- cache written through with the callback forms, so the exports never yield.

local RESOURCE = "rp_fixer"

local CHAT_COLOR = { 0, 229, 255 }
local CHAT_AUTHOR = "FIXER"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local store = nil          -- "sql" | "kvp" | nil while undecided
local storeReason = nil

local rep = {}             -- identifier -> { score, completed, failed }
local repByPlayer = {}     -- playerId -> identifier (loaded players only)

local openGigs = {}        -- gigId -> gig (published, waiting for a merc)
local activeGigs = {}      -- playerId -> gig (accepted, running)
local nextGigId = 1
local republishAt = {}     -- templateId -> monotonic time of the next automatic instance

local stats = { published = 0, accepted = 0, success = 0, failed = 0, dropped = 0, commission = 0 }

local KIND_LABEL = { delivery = "Delivery", retrieval = "Retrieval", escort = "Escort", extraction = "Extraction" }
local KIND_ICON  = { delivery = "D", retrieval = "R", escort = "E", extraction = "X" }

local SUGGESTIONS = {
    { command = "/gigs", help = "Open the fixer's board (at the office)" },
    { command = "/gig", help = "Your current gig: phase, objective and time left",
      parameters = { { name = "abandonner", help = "walk away from the gig (reputation -1)" } } },
    { command = "/fixer", help = "Fixer only: board stats, or publier <template> to post a gig",
      parameters = { { name = "publier", help = "post a new instance of a template" },
                     { name = "template", help = "template id, see /fixer" } } },
}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[%s] "):format(RESOURCE) .. fmt:format(...))
end

-- One chat line to one player (or everyone with -1). Delivery is asynchronous; two
-- lines sent in the same tick may swap, so callers that care put a Wait(0) between.
local function say(playerId, text)
    if type(playerId) ~= "number" then return end
    Open77.chat.send(playerId, { type = "system", author = CHAT_AUTHOR, text = text, color = CHAT_COLOR })
end

local function fmtMoney(amount)
    local s = tostring(math.floor(amount))
    local grouped = (s:reverse():gsub("(%d%d%d)", "%1 "):reverse())
    grouped = (grouped:gsub("^%s+", ""))
    return grouped .. " €$"
end

local function fmtTime(seconds)
    seconds = math.max(0, math.floor(seconds))
    if seconds >= 60 then
        return ("%d min %02d s"):format(seconds // 60, seconds % 60)
    end
    return ("%d s"):format(seconds)
end

local function dist2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function pointOf(name)
    return Config.points[name]
end

local function playerName(playerId)
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and #name > 0 then return name end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

local function isConnected(playerId)
    return Open77.players.name(playerId) ~= nil
end

local function countTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Reputation tiers.
local function tierOf(score)
    local idx, tier = 1, Config.tiers[1]
    for i, t in ipairs(Config.tiers) do
        if score >= t.min then idx, tier = i, t end
    end
    return idx, tier
end

local function tierByName(name)
    for i, t in ipairs(Config.tiers) do
        if t.name == name then return i, t end
    end
    return 1, Config.tiers[1]
end

local function reputationOf(playerId)
    local identifier = repByPlayer[playerId]
    local entry = identifier and rep[identifier]
    return entry and entry.score or 0
end

-- rp_jobs, reached through pcall (server-only resource, never a dependency here).
local function hasFixerJob(playerId)
    local ok, has = pcall(function() return exports.rp_jobs:hasJob(playerId, "fixer") end)
    return ok and has == true
end

local function fixerOnDuty(playerId)
    if not hasFixerJob(playerId) then return false end
    local ok, duty = pcall(function() return exports.rp_jobs:onDuty(playerId) end)
    return ok and duty == true
end

local function fixersOnDuty()
    local ok, list = pcall(function() return exports.rp_jobs:listOnDuty("fixer") end)
    if ok and type(list) == "table" then return list end
    return {}
end

local function canOpenBoard(playerId)
    if Config.openBoardWithoutFixer then return true end
    if fixerOnDuty(playerId) then return true end
    if #fixersOnDuty() > 0 then return true end
    return false, "No fixer on duty: the board is dark, choom. Come back when one clocks in."
end

-- rp_inventory, reached through pcall.
local function inventoryAdd(playerId, itemId, count)
    local ok, result, reason = pcall(function() return exports.rp_inventory:add(playerId, itemId, count) end)
    if not ok then return nil, "inventory_offline" end
    if not result then return nil, reason or "refused" end
    return true
end

local function inventoryRemove(playerId, itemId, count)
    local ok, result, reason = pcall(function() return exports.rp_inventory:remove(playerId, itemId, count) end)
    if not ok then return nil, "inventory_offline" end
    if not result then return nil, reason or "refused" end
    return true
end

local function inventoryCount(playerId, itemId)
    local ok, n = pcall(function() return exports.rp_inventory:count(playerId, itemId) end)
    if ok and type(n) == "number" then return n end
    return 0
end

local function explainInventory(reason, label)
    if reason == "too_heavy" then return ("Your pockets are full: drop something to carry the %s."):format(label) end
    if reason == "not_enough" then return ("You do not have the %s any more. Find it, then come back."):format(label) end
    if reason == "inventory_offline" then return "Your pockets are offline (rp_inventory is not running). Tell an admin." end
    if reason == "unknown_item" then return ("The %s is not a known item yet (rp_inventory did not register it). Tell an admin."):format(label) end
    if reason == "not_loaded" then return "Your pockets are still loading. Try again in a second." end
    return ("Refused: %s."):format(tostring(reason))
end

local function itemLabel(itemId)
    local def = Config.items[itemId]
    return (def and def.label or itemId):lower()
end

-- ---------------------------------------------------------------------------
-- Storage: SQL first, kvp when there is no database
-- ---------------------------------------------------------------------------

local function createTables()
    return pcall(function()
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_fixer_reputation (
                identifier VARCHAR(64) PRIMARY KEY,
                score      INT    NOT NULL DEFAULT 0,
                completed  INT    NOT NULL DEFAULT 0,
                failed     INT    NOT NULL DEFAULT 0,
                updated_at BIGINT NOT NULL DEFAULT 0
            )
        ]])
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_fixer_gigs (
                id          INT AUTO_INCREMENT PRIMARY KEY,
                gig_id      INT          NOT NULL,
                identifier  VARCHAR(64)  NOT NULL,
                player_name VARCHAR(80)  NOT NULL DEFAULT '',
                template    VARCHAR(32)  NOT NULL,
                kind        VARCHAR(16)  NOT NULL,
                outcome     VARCHAR(16)  NOT NULL,
                pay         INT          NOT NULL DEFAULT 0,
                commission  INT          NOT NULL DEFAULT 0,
                publisher   VARCHAR(80)  NOT NULL DEFAULT 'board',
                accepted_at BIGINT       NOT NULL DEFAULT 0,
                ended_at    BIGINT       NOT NULL DEFAULT 0,
                INDEX (identifier)
            )
        ]])
    end)
end

-- Waits for the store decision (at most 15 s), then falls back to kvp and says so.
local function waitForStore()
    local waited = 0
    while store == nil and waited < 15000 do
        Wait(500)
        waited = waited + 500
    end
    if store == nil then
        store, storeReason = "kvp", "database_timeout"
        log("store=kvp reason=%s (the database did not answer in 15 s)", storeReason)
    end
end

local function saveReputation(identifier)
    local entry = rep[identifier]
    if not entry then return end
    local now = math.floor(Open77.time.unix())
    if store == "sql" then
        Open77.database.update(
            "INSERT INTO rp_fixer_reputation (identifier, score, completed, failed, updated_at) VALUES (?, ?, ?, ?, ?) "
            .. "ON DUPLICATE KEY UPDATE score = ?, completed = ?, failed = ?, updated_at = ?",
            { identifier, entry.score, entry.completed, entry.failed, now, entry.score, entry.completed, entry.failed, now },
            function(result)
                if result == nil then log("reputation write failed for %s", identifier) end
            end)
    else
        Open77.kvp.set("rep:" .. identifier, entry.score)
        Open77.kvp.set("repc:" .. identifier, entry.completed)
        Open77.kvp.set("repf:" .. identifier, entry.failed)
    end
end

local function recordGig(gig, outcome, paid, commission)
    local now = math.floor(Open77.time.unix())
    local publisher = gig.publisher and gig.publisher.identifier or "board"
    if store == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_fixer_gigs (gig_id, identifier, player_name, template, kind, outcome, pay, commission, publisher, accepted_at, ended_at) "
            .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            { gig.id, gig.identifier, gig.playerName or "", gig.templateId, gig.kind, outcome, paid, commission, publisher,
              math.floor(gig.acceptedAt or now), now },
            function(id)
                if id == nil then log("gig row write failed for gig %d", gig.id) end
            end)
    else
        local n = (Open77.kvp.get("gigs:count", 0) or 0) + 1
        Open77.kvp.set("gigs:count", n)
        Open77.kvp.set("gig:" .. n, table.concat({ gig.identifier, gig.templateId, outcome, tostring(paid),
            tostring(commission), publisher, tostring(math.floor(gig.acceptedAt or now)), tostring(now) }, "|"))
    end
end

-- Runs as a managed task (handler or thread): may Wait / await.
local function loadReputation(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    waitForStore()
    if not isConnected(playerId) then return end
    if rep[identifier] then
        repByPlayer[playerId] = identifier
        return
    end
    local entry = { score = 0, completed = 0, failed = 0 }
    if store == "sql" then
        local ok, row = pcall(function()
            return Open77.database.single.await(
                "SELECT score, completed, failed FROM rp_fixer_reputation WHERE identifier = ?", { identifier })
        end)
        if not ok then
            -- Never treat a failed read as "no reputation": a later write would erase the real row.
            log("player %d reputation read failed: %s", playerId, tostring(row))
            say(playerId, "The fixer's ledger is unreadable right now. Reconnect before taking a gig.")
            return
        end
        if row then
            entry.score = math.floor(tonumber(row.score) or 0)
            entry.completed = math.floor(tonumber(row.completed) or 0)
            entry.failed = math.floor(tonumber(row.failed) or 0)
        end
    else
        entry.score = math.floor(tonumber(Open77.kvp.get("rep:" .. identifier, 0)) or 0)
        entry.completed = math.floor(tonumber(Open77.kvp.get("repc:" .. identifier, 0)) or 0)
        entry.failed = math.floor(tonumber(Open77.kvp.get("repf:" .. identifier, 0)) or 0)
    end
    rep[identifier] = entry
    repByPlayer[playerId] = identifier
    local _, tier = tierOf(entry.score)
    log("player %d reputation loaded score=%d tier=%s (%s)", playerId, entry.score, tier.name, store)
end

local function decideStore()
    local ok, reason = Open77.database.ready(function()
        local created, err = createTables()
        if not created then
            store, storeReason = "kvp", "table_creation_failed"
            log("store=kvp reason=%s (%s)", storeReason, tostring(err))
            return
        end
        store = "sql"
        log("store=sql tables=rp_fixer_gigs,rp_fixer_reputation")
    end)
    if not ok then
        store, storeReason = "kvp", tostring(reason)
        log("store=kvp reason=%s", storeReason)
    end
end

-- ---------------------------------------------------------------------------
-- Gigs: publishing
-- ---------------------------------------------------------------------------

local function hasOpenInstance(templateId)
    for _, gig in pairs(openGigs) do
        if gig.templateId == templateId then return true end
    end
    return false
end

local function sortedOpenGigs()
    local list = {}
    for _, gig in pairs(openGigs) do list[#list + 1] = gig end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- publisher: { identifier, name, playerId } for a fixer on duty, nil for the board.
-- Never yields: it is the body of the postGig export.
local function publishGig(templateId, publisher)
    local template = Config.templates[templateId]
    if not template then return nil, "unknown_template" end
    if countTable(openGigs) >= Config.maxOpenGigs then return nil, "board_full" end
    local commission = math.floor(template.pay * Config.commissionRate + 0.5)
    local gig = {
        id = nextGigId,
        templateId = templateId,
        template = template,
        kind = template.kind,
        title = template.title,
        pay = template.pay,
        commission = commission,
        net = template.pay - commission,
        publisher = publisher,
        publishedAt = Open77.time.unix(),
    }
    nextGigId = nextGigId + 1
    openGigs[gig.id] = gig
    republishAt[templateId] = nil
    stats.published = stats.published + 1
    TriggerEvent("rp_fixer:gig", gig.id, "published", publisher and publisher.playerId or 0)
    log("gig %d published template=%s pay=%d net=%d cut=%d by=%s", gig.id, templateId, gig.pay, gig.net, commission,
        publisher and publisher.name or "board")
    return gig.id
end

local function scheduleRepublish(templateId)
    local template = Config.templates[templateId]
    if Config.autoPublish and template and template.auto then
        republishAt[templateId] = Open77.time.monotonic() + Config.republishDelaySec
    end
end

-- ---------------------------------------------------------------------------
-- Gigs: phases, objectives and NPCs
-- ---------------------------------------------------------------------------

local function buildPhases(gig)
    local t = gig.template
    if t.kind == "delivery" then
        local label = itemLabel(t.item)
        return {
            { key = "pickup", point = pointOf(t.from), label = "Pick up the " .. label, prompt = "Grab the " .. label },
            { key = "dropoff", point = pointOf(t.to), label = "Deliver the " .. label, prompt = "Hand over the " .. label },
        }
    elseif t.kind == "retrieval" then
        local label = itemLabel(t.item)
        return {
            { key = "retrieve", point = pointOf(t.at), label = "Grab the " .. label, prompt = "Take the " .. label,
              guards = true, style = "danger" },
            { key = "return", point = Config.office, label = "Bring the " .. label .. " to the fixer",
              prompt = "Hand over the " .. label },
        }
    elseif t.kind == "escort" then
        return {
            { key = "meet", point = pointOf(t.from), label = "Meet " .. t.npcName,
              prompt = "Tell " .. t.npcName .. " to follow you", npc = true },
            { key = "walk", point = pointOf(t.to), label = "Walk " .. t.npcName .. " to the drop", arrival = true },
        }
    elseif t.kind == "extraction" then
        return {
            { key = "grab", point = pointOf(t.at), label = "Reach " .. t.npcName,
              prompt = "Get " .. t.npcName .. " moving", npc = true, guards = true, style = "danger" },
            { key = "walk", point = Config.office, label = "Bring " .. t.npcName .. " to the fixer", arrival = true },
        }
    end
    return {}
end

local function currentPhase(gig)
    return gig.phases and gig.phases[gig.phaseIndex] or nil
end

local function timeLeft(gig)
    return math.max(0, math.floor((gig.deadline or 0) - Open77.time.monotonic()))
end

-- The client relay: ring + E prompt + map pin + GPS waypoint for the current objective.
local function sendObjective(gig)
    if not isConnected(gig.playerId) then return end
    local phase = currentPhase(gig)
    if not phase then
        TriggerClientEvent("rp_fixer:objective", gig.playerId, false)
        return
    end
    TriggerClientEvent("rp_fixer:objective", gig.playerId, {
        key = phase.key,
        position = { x = phase.point.x, y = phase.point.y, z = phase.point.z },
        label = phase.label,
        prompt = phase.prompt or false,
        style = phase.style or "objective",
        title = gig.title .. ": " .. phase.label,
    })
end

local function removeNpcs(gig)
    for _, npcId in ipairs(gig.npcs or {}) do
        Open77.npcs.remove(npcId)
    end
    gig.npcs = {}
    gig.escortNpc = nil
    gig.guards = {}
end

-- Two Maelstrom guards at the point, hostile to the merc only, leashed to their post.
local function spawnGuards(gig, phase)
    gig.npcs = gig.npcs or {}
    gig.guards = gig.guards or {}
    local p = phase.point
    local cfg = Config.guards
    for i = 1, cfg.count do
        local angle = math.pi / 4 + (i - 1) * (2 * math.pi / cfg.count)
        local post = { x = p.x + math.cos(angle) * cfg.postRadius, y = p.y + math.sin(angle) * cfg.postRadius, z = p.z }
        local yaw = (math.deg(angle) + 180) % 360
        local npcId, reason = Open77.npcs.create({
            record = cfg.record,
            position = post,
            yaw = yaw,
            health = cfg.health,
            maxHealth = cfg.health,
            damagePolicy = cfg.damagePolicy,
            streamingRadius = 180,
            despawnWhenUnobserved = false,
            persistent = false,
        })
        if not npcId then
            log("gig %d guard %d refused: %s", gig.id, i, tostring(reason))
            say(gig.playerId, ("A guard did not show up (%s). Easy money, choom."):format(tostring(reason)))
        else
            gig.npcs[#gig.npcs + 1] = npcId
            gig.guards[#gig.guards + 1] = npcId
            local okGroup, whyGroup = Open77.npcs.setGroup(npcId, cfg.group)
            if not okGroup then log("gig %d guard group refused: %s", gig.id, tostring(whyGroup)) end
            -- The card's example passes the player id straight; the guide also documents
            -- { playerId = n }. Try the card's form first, then the guide's.
            local okAtt, whyAtt = Open77.npcs.setAttitude(npcId, "hostile", { towards = gig.playerId })
            if not okAtt then
                okAtt, whyAtt = Open77.npcs.setAttitude(npcId, "hostile", { towards = { playerId = gig.playerId } })
            end
            if not okAtt then log("gig %d guard attitude refused: %s", gig.id, tostring(whyAtt)) end
            if gig.escortNpc then
                Open77.npcs.setAttitude(npcId, "neutral", { towards = { npcId = gig.escortNpc } })
            end
            local taskId, whyTask = Open77.npcs.tasks.guard(npcId, post, cfg.guardRadius, { speed = "run" })
            if not taskId then log("gig %d guard task refused: %s", gig.id, tostring(whyTask)) end
        end
    end
    gig.guardPoint = p
    gig.engaged = false
end

-- The escorted NPC / extraction target, standing at the point until the merc arrives.
local function spawnEscort(gig, phase)
    gig.npcs = gig.npcs or {}
    local p = phase.point
    local npcId, reason = Open77.npcs.create({
        template = Config.escort.template,
        position = { x = p.x + 1.2, y = p.y - 1.2, z = p.z },
        yaw = 180.0,
        damagePolicy = Config.escort.damagePolicy,
        behavior = { combatEnabled = false, voiceEnabled = false },
        streamingRadius = 180,
        despawnWhenUnobserved = false,
        persistent = false,
    })
    if not npcId then
        log("gig %d escort refused: %s", gig.id, tostring(reason))
        return nil, reason
    end
    gig.npcs[#gig.npcs + 1] = npcId
    gig.escortNpc = npcId
    local holdId, whyHold = Open77.npcs.tasks.hold(npcId)
    if not holdId then log("gig %d escort hold refused: %s", gig.id, tostring(whyHold)) end
    return npcId
end

local function startFollow(gig)
    local npcId = gig.escortNpc
    if not npcId then return nil, "no_escort" end
    Open77.npcs.tasks.clear(npcId)
    local taskId, reason = Open77.npcs.tasks.follow(npcId, gig.playerId, {
        distance = Config.escort.followDistance,
        speed = Config.escort.followSpeed,
        onTargetLost = "wait",
    })
    if not taskId then
        log("gig %d follow refused: %s", gig.id, tostring(reason))
        return nil, reason
    end
    return taskId
end

local function engageGuards(gig)
    if gig.engaged then return end
    gig.engaged = true
    for _, npcId in ipairs(gig.guards or {}) do
        local taskId, reason = Open77.npcs.tasks.attack(npcId, gig.playerId, { reacquireMs = 4000 })
        if not taskId then log("gig %d attack refused: %s", gig.id, tostring(reason)) end
    end
    say(gig.playerId, "Maelstrom made you. Guns out, choom.")
end

-- Delivery / retrieval items go back to the fixer when a gig does not end in success.
local function takeBackItems(gig)
    local item = gig.template.item
    if not item or not isConnected(gig.playerId) then return end
    local n = inventoryCount(gig.playerId, item)
    if n > 0 then
        local ok = inventoryRemove(gig.playerId, item, n)
        if ok then say(gig.playerId, ("The fixer's %s was taken back."):format(itemLabel(item))) end
    end
end

local function notifyFixers(text, exceptPlayerId)
    for _, fixerId in ipairs(fixersOnDuty()) do
        if fixerId ~= exceptPlayerId then say(fixerId, text) end
    end
end

-- outcome: success | timeout | abandoned | dropped
local function endGig(gig, outcome)
    activeGigs[gig.playerId] = nil
    removeNpcs(gig)
    if isConnected(gig.playerId) then
        TriggerClientEvent("rp_fixer:objective", gig.playerId, false)
    end

    local paid, commission = 0, 0
    local entry = gig.identifier and rep[gig.identifier]
    local before = entry and entry.score or 0

    if outcome == "success" then
        stats.success = stats.success + 1
        local okPay, balance, whyPay = pcall(function()
            return exports.rp_economy:add(gig.playerId, gig.net, "gig:" .. gig.templateId)
        end)
        if okPay and balance then
            paid = gig.net
        else
            local reason = okPay and tostring(whyPay) or "rp_economy offline"
            log("gig %d pay refused: %s", gig.id, reason)
            say(gig.playerId, ("The eddies did not come through (%s). Tell the fixer."):format(reason))
        end
        local okCut, societyBalance, whyCut = pcall(function()
            return exports.rp_bank:societyAdd(Config.society, gig.commission, "gig:" .. gig.templateId)
        end)
        if okCut and societyBalance then
            commission = gig.commission
            stats.commission = stats.commission + commission
        else
            log("gig %d commission refused: %s", gig.id, okCut and tostring(whyCut) or "rp_bank offline")
        end
        if entry then
            entry.score = entry.score + Config.reputation.success
            entry.completed = entry.completed + 1
        end
    elseif outcome == "abandoned" or outcome == "timeout" then
        stats.failed = stats.failed + 1
        if entry then
            entry.score = math.max(Config.reputation.floor, entry.score + (Config.reputation[outcome] or 0))
            entry.failed = entry.failed + 1
        end
        takeBackItems(gig)
    else
        stats.dropped = stats.dropped + 1
        takeBackItems(gig)
    end

    if entry then saveReputation(gig.identifier) end
    recordGig(gig, outcome, paid, commission)

    -- Tell the merc.
    if isConnected(gig.playerId) then
        if outcome == "success" then
            local _, tier = tierOf(entry and entry.score or 0)
            say(gig.playerId, ("Gig done: %s. %s in cash (fixer's cut %s). Reputation %d (%s)."):format(
                gig.title, fmtMoney(paid), fmtMoney(gig.commission), entry and entry.score or 0, tier.name))
            if entry then
                local beforeIdx = tierOf(before)
                local afterIdx = tierOf(entry.score)
                if afterIdx > beforeIdx then
                    Wait(0)
                    say(gig.playerId, ("Word gets around: you are now %s. Better-paid gigs are on the board."):format(tier.name))
                end
            end
        elseif outcome == "timeout" then
            say(gig.playerId, ("Too slow: %s is off. The fixer is not happy. Reputation %d."):format(gig.title, entry and entry.score or 0))
        elseif outcome == "abandoned" then
            say(gig.playerId, ("You walked away from %s. Reputation %d."):format(gig.title, entry and entry.score or 0))
        end
    end

    -- Tell the fixers on duty; the publisher gets the credit under their name.
    local who = gig.playerName or ("player " .. tostring(gig.playerId))
    if outcome == "success" then
        local credit = gig.publisher and (" Posted by " .. gig.publisher.name .. ".") or ""
        notifyFixers(("%s completed %s: +%s to the %s society.%s"):format(who, gig.title, fmtMoney(commission), Config.society, credit), gig.playerId)
    else
        notifyFixers(("%s failed %s (%s)."):format(who, gig.title, outcome), gig.playerId)
    end

    TriggerEvent("rp_fixer:gig", gig.id, outcome, gig.playerId)
    scheduleRepublish(gig.templateId)
    log("gig %d %s player=%d template=%s paid=%d commission=%d rep=%d publisher=%s", gig.id, outcome, gig.playerId,
        gig.templateId, paid, commission, entry and entry.score or 0, gig.publisher and gig.publisher.name or "board")
end

local function advance(gig)
    gig.phaseIndex = gig.phaseIndex + 1
    local phase = currentPhase(gig)
    if not phase then
        endGig(gig, "success")
        return
    end
    if phase.npc and not gig.escortNpc then spawnEscort(gig, phase) end
    if phase.guards then spawnGuards(gig, phase) end
    sendObjective(gig)
    say(gig.playerId, ("Next: %s. %s left."):format(phase.label, fmtTime(timeLeft(gig))))
    TriggerEvent("rp_fixer:gig", gig.id, phase.key, gig.playerId)
    log("gig %d phase=%s player=%d", gig.id, phase.key, gig.playerId)
end

-- Managed task. Re-validates everything: the gig may have gone while the dialog was open.
local function acceptGig(playerId, gigId)
    local gig = openGigs[gigId]
    if not gig then
        say(playerId, "Someone grabbed that gig while you were reading.")
        return
    end
    if activeGigs[playerId] then
        say(playerId, "Finish your current gig first. /gig for the status, /gig abandonner to drop it.")
        return
    end
    local identifier = repByPlayer[playerId]
    if not identifier or not rep[identifier] then
        say(playerId, "The fixer does not know you yet (ledger not loaded). Reconnect and try again.")
        return
    end
    local tierIdx = tierOf(rep[identifier].score)
    local needIdx, needTier = tierByName(gig.template.minTier)
    if tierIdx < needIdx then
        say(playerId, ("Not for you yet: %s wants a %s merc (reputation %d+). Yours is %d."):format(
            gig.title, needTier.name, needTier.min, rep[identifier].score))
        return
    end

    openGigs[gigId] = nil
    gig.playerId = playerId
    gig.identifier = identifier
    gig.playerName = playerName(playerId)
    gig.acceptedAt = Open77.time.unix()
    gig.deadline = Open77.time.monotonic() + gig.template.timeLimitSec
    gig.phases = buildPhases(gig)
    gig.phaseIndex = 1
    gig.npcs = {}
    gig.guards = {}
    gig.warned = false

    local first = currentPhase(gig)
    if not first then
        openGigs[gigId] = gig
        say(playerId, "That template is broken (no phases). Tell an admin.")
        return
    end
    if first.npc then
        local npcId, reason = spawnEscort(gig, first)
        if not npcId then
            removeNpcs(gig)
            openGigs[gigId] = gig
            say(playerId, ("The fixer's contact never showed (%s). Gig back on the board, no penalty."):format(tostring(reason)))
            return
        end
    end
    if first.guards then spawnGuards(gig, first) end

    activeGigs[playerId] = gig
    stats.accepted = stats.accepted + 1
    sendObjective(gig)
    say(playerId, ("Gig accepted: %s. %s. You have %s. Pay %s in cash on success."):format(
        gig.title, first.label, fmtTime(gig.template.timeLimitSec), fmtMoney(gig.net)))
    TriggerEvent("rp_fixer:gig", gig.id, "accepted", playerId)
    log("gig %d accepted player=%d (%s) template=%s deadline=%ds", gig.id, playerId, gig.playerName, gig.templateId,
        gig.template.timeLimitSec)
end

-- ---------------------------------------------------------------------------
-- The board (UI kit context menu driven from the server)
-- ---------------------------------------------------------------------------

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

local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Managed task.
local function openBoard(playerId)
    local allowed, why = canOpenBoard(playerId)
    if not allowed then
        say(playerId, why)
        return
    end
    if Config.boardReach > 0 then
        local d, reason = Open77.players.distance(playerId, Config.office)
        if not d then
            say(playerId, ("The fixer cannot see where you are (%s). Move a bit."):format(tostring(reason)))
            return
        end
        if d > Config.boardReach then
            say(playerId, ("The board is at the fixer's office, %.0f m from you. Walk."):format(d))
            return
        end
    end

    local score = reputationOf(playerId)
    local tierIdx, tier = tierOf(score)
    local options = {}
    local list = sortedOpenGigs()
    for _, gig in ipairs(list) do
        local needIdx, needTier = tierByName(gig.template.minTier)
        local eligible = tierIdx >= needIdx
        local route
        if gig.kind == "delivery" or gig.kind == "escort" then
            route = ("%s -> %s"):format(gig.template.from, gig.template.to)
        else
            route = ("%s -> office"):format(gig.template.at)
        end
        options[#options + 1] = {
            id = "gig_" .. gig.id,
            label = gig.title,
            description = ("%s: %s"):format(KIND_LABEL[gig.kind] or gig.kind, route),
            icon = KIND_ICON[gig.kind] or "G",
            disabled = not eligible,
            metadata = {
                { label = "Pay", value = fmtMoney(gig.net) .. " (cut " .. fmtMoney(gig.commission) .. ")" },
                { label = "Time limit", value = fmtTime(gig.template.timeLimitSec) },
                { label = "Rep needed", value = ("%s (%d+)"):format(needTier.name, needTier.min) },
                { label = "Posted by", value = gig.publisher and gig.publisher.name or "the board" },
            },
        }
    end
    if #options == 0 then
        options[1] = { id = "none", label = "Nothing on the board. Come back later.", disabled = true }
    end

    local answer, reason = uikit("context", playerId, {
        id = "rp_fixer_board",
        title = Config.text.boardLabel,
        description = ("Your rep: %d (%s). %d gig(s) open."):format(score, tier.name, #list),
        options = options,
    }, { timeoutMs = 60000 })
    if answer == nil then
        say(playerId, ("The board is dark (%s)."):format(tostring(reason)))
        return
    end
    if not answer.ok or type(answer.value) ~= "table" then return end
    local gigId = tonumber(tostring(answer.value.id):match("^gig_(%d+)$"))
    if not gigId then return end
    local gig = openGigs[gigId]
    if not gig then
        say(playerId, "Someone grabbed that gig while you were reading.")
        return
    end

    local confirm, whyConfirm = uikit("alert", playerId, {
        title = gig.title,
        message = ("%s Pay: %s in cash (the fixer keeps %s). Clock: %s from the moment you accept."):format(
            gig.template.description, fmtMoney(gig.net), fmtMoney(gig.commission), fmtTime(gig.template.timeLimitSec)),
        confirm = "Accept the gig",
        cancel = "Not now",
        tone = "info",
        timeoutMs = 30000,
    })
    if confirm == nil then
        say(playerId, ("The fixer did not hear you (%s)."):format(tostring(whyConfirm)))
        return
    end
    if not confirm.ok then return end
    acceptGig(playerId, gigId)
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

RegisterCommand("gigs", function(source)
    if source == 0 then return print("gigs: run it from the game") end
    openBoard(source)
end, false)

RegisterCommand("gig", function(source, args)
    if source == 0 then return print("gig: run it from the game") end
    local gig = activeGigs[source]
    local sub = (args[1] or ""):lower()
    if sub == "abandonner" or sub == "abandon" then
        if not gig then return say(source, "No gig to walk away from.") end
        endGig(gig, "abandoned")
        return
    end
    if not gig then
        return say(source, ("No gig running. Reputation %d. The board is at the fixer's office (/gigs)."):format(reputationOf(source)))
    end
    local phase = currentPhase(gig)
    local d = phase and Open77.players.distance(source, phase.point)
    local where = d and (("%.0f m away"):format(d)) or "somewhere"
    say(source, ("Gig: %s (%s). Now: %s, %s. Time left: %s. Pay %s."):format(
        gig.title, KIND_LABEL[gig.kind] or gig.kind, phase and phase.label or "?", where, fmtTime(timeLeft(gig)), fmtMoney(gig.net)))
end, false)

local function fixerStats(reply)
    local open = sortedOpenGigs()
    reply(("Board: %d open gig(s), %d template(s). Session: %d published, %d accepted, %d done, %d failed, %d dropped, %s commission."):format(
        #open, countTable(Config.templates), stats.published, stats.accepted, stats.success, stats.failed, stats.dropped,
        fmtMoney(stats.commission)))
    local okSoc, society = pcall(function() return exports.rp_bank:society(Config.society) end)
    if okSoc and type(society) == "table" then
        reply(("Society %s: %s."):format(Config.society, fmtMoney(society.balance or 0)))
    else
        reply(("Society %s: bank offline."):format(Config.society))
    end
    for _, gig in ipairs(open) do
        reply(("  open #%d %s [%s] %s net, %s, %s+, by %s"):format(gig.id, gig.title, gig.templateId, fmtMoney(gig.net),
            fmtTime(gig.template.timeLimitSec), gig.template.minTier, gig.publisher and gig.publisher.name or "board"))
    end
    for playerId, gig in pairs(activeGigs) do
        local phase = currentPhase(gig)
        reply(("  running #%d %s by %s (id %d): %s, %s left"):format(gig.id, gig.title, gig.playerName or "?", playerId,
            phase and phase.label or "?", fmtTime(timeLeft(gig))))
    end
    local ids = {}
    for id in pairs(Config.templates) do ids[#ids + 1] = id end
    table.sort(ids)
    reply("Templates: " .. table.concat(ids, ", ") .. ". /fixer publier <template> posts one.")
end

RegisterCommand("fixer", function(source, args)
    local sub = (args[1] or ""):lower()
    local reply
    if source == 0 then
        reply = print
    else
        if not hasFixerJob(source) then
            return say(source, "You are not the fixer here, choom. The board is /gigs.")
        end
        reply = function(text) say(source, text); Wait(0) end
    end

    if sub == "publier" or sub == "publish" then
        local templateId = args[2]
        if not templateId or not Config.templates[templateId] then
            local ids = {}
            for id in pairs(Config.templates) do ids[#ids + 1] = id end
            table.sort(ids)
            return reply("Usage: /fixer publier <template>. Templates: " .. table.concat(ids, ", "))
        end
        local publisher = nil
        if source ~= 0 then
            if not fixerOnDuty(source) then
                return reply("Clock in first (/service): only a fixer on duty posts gigs under their name.")
            end
            publisher = { identifier = Open77.players.identifier(source), name = playerName(source), playerId = source }
        end
        local gigId, reason = publishGig(templateId, publisher)
        if not gigId then
            if reason == "board_full" then return reply("The board is full. Let the mercs clear it first.") end
            return reply("Could not post it: " .. tostring(reason))
        end
        local gig = openGigs[gigId]
        reply(("Posted #%d %s: %s net to the merc, %s to the %s society%s."):format(gigId, gig.title, fmtMoney(gig.net),
            fmtMoney(gig.commission), Config.society, publisher and " under your name" or ""))
        Open77.chat.send(-1, { type = "system", author = CHAT_AUTHOR, color = CHAT_COLOR,
            text = ("New gig on the board: %s (%s). Ask at the fixer's office."):format(gig.title, fmtMoney(gig.net)) })
        return
    end

    fixerStats(reply)
end, false)

-- ---------------------------------------------------------------------------
-- Client requests
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_fixer:board", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    gesture(playerId, "board")
    openBoard(playerId)
end)

RegisterNetEvent("rp_fixer:interact", function(key)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local gig = activeGigs[playerId]
    if not gig then return say(playerId, "No gig running. The board is at the fixer's office (/gigs).") end
    local phase = currentPhase(gig)
    if not phase or not phase.prompt then return end
    if key ~= phase.key then return end -- a stale prompt from a previous phase

    local d, reason = Open77.players.distance(playerId, phase.point)
    if not d then
        return say(playerId, ("The fixer cannot see where you are (%s). Move a bit."):format(tostring(reason)))
    end
    if d > Config.interactReach then
        return say(playerId, ("Get closer to the objective (%.0f m)."):format(d))
    end

    if gig.kind == "delivery" or gig.kind == "retrieval" then
        local item = gig.template.item
        local label = itemLabel(item)
        -- Staged: the case in the hand for the bar's length, then the pockets move (Config.Stage).
        local key = gig.phaseIndex == 1 and "pickup" or "handover"
        local done = stage(playerId, key, { label = (gig.phaseIndex == 1 and "Picking up the " or "Handing over the ") .. label })
        if not done or not done.ok then return say(playerId, "You leave it where it is.") end
        if activeGigs[playerId] ~= gig or currentPhase(gig) ~= phase then return end
        local again = Open77.players.distance(playerId, phase.point)
        if not again or again > Config.interactReach + 1.5 then return say(playerId, "You walked away from the objective.") end
        if gig.phaseIndex == 1 then
            local ok, why = inventoryAdd(playerId, item, 1)
            if not ok then return say(playerId, explainInventory(why, label)) end
            say(playerId, ("You pocket the %s. Now move."):format(label))
        else
            local ok, why = inventoryRemove(playerId, item, 1)
            if not ok then return say(playerId, explainInventory(why, label)) end
            say(playerId, ("Handed over the %s."):format(label))
        end
    elseif phase.npc then
        local ok, why = startFollow(gig)
        if not ok then
            return say(playerId, ("%s will not move (%s). Try again in a second."):format(gig.template.npcName, tostring(why)))
        end
        say(playerId, ("%s falls in behind you. Keep them close and walk."):format(gig.template.npcName))
    end
    Wait(0)
    advance(gig)
end)

-- ---------------------------------------------------------------------------
-- Exports (synchronous, never yield: they read the caches only)
-- ---------------------------------------------------------------------------

exports("reputation", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return 0 end
    return reputationOf(playerId)
end)

exports("postGig", function(templateId, byPlayerId)
    if type(templateId) ~= "string" then return nil, "invalid_template" end
    local publisher = nil
    if byPlayerId ~= nil then
        local id = tonumber(byPlayerId)
        if not id or id < 1 or id % 1 ~= 0 then return nil, "invalid_player_id" end
        if not isConnected(id) then return nil, "player_not_found" end
        publisher = { identifier = Open77.players.identifier(id), name = playerName(id), playerId = id }
    end
    return publishGig(templateId, publisher)
end)

exports("activeGig", function(playerId)
    playerId = tonumber(playerId)
    local gig = playerId and activeGigs[playerId]
    if not gig then return nil end
    local phase = currentPhase(gig)
    return {
        id = gig.id,
        templateId = gig.templateId,
        kind = gig.kind,
        title = gig.title,
        phase = phase and phase.key or nil,
        phaseLabel = phase and phase.label or nil,
        timeLeft = timeLeft(gig),
        pay = gig.net,
        commission = gig.commission,
        publisher = gig.publisher and gig.publisher.name or nil,
    }
end)

-- ---------------------------------------------------------------------------
-- Ticker: deadlines, arrivals, guard engagement, automatic republishing
-- ---------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(1000)
        local now = Open77.time.monotonic()

        local running = {}
        for _, gig in pairs(activeGigs) do running[#running + 1] = gig end
        for _, gig in ipairs(running) do
            if activeGigs[gig.playerId] == gig then
                local left = timeLeft(gig)
                if left <= 0 then
                    endGig(gig, "timeout")
                else
                    if not gig.warned and left <= Config.warnBeforeDeadlineSec then
                        gig.warned = true
                        say(gig.playerId, ("%s left on %s. Move it."):format(fmtTime(left), gig.title))
                    end
                    local phase = currentPhase(gig)
                    if phase and phase.guards and gig.guardPoint and not gig.engaged and #(gig.guards or {}) > 0 then
                        local d = Open77.players.distance(gig.playerId, gig.guardPoint)
                        if d and d <= Config.guards.engageDistance then engageGuards(gig) end
                    end
                    if phase and phase.arrival and gig.escortNpc then
                        local snap = Open77.npcs.get(gig.escortNpc)
                        if snap and snap.x and dist2(snap, phase.point) <= Config.arrivalDistance then
                            say(gig.playerId, ("%s made it."):format(gig.template.npcName))
                            advance(gig)
                        end
                    end
                end
            end
        end

        local due = {}
        for templateId, at in pairs(republishAt) do
            if now >= at then due[#due + 1] = templateId end
        end
        for _, templateId in ipairs(due) do
            republishAt[templateId] = nil
            if not hasOpenInstance(templateId) then publishGig(templateId, nil) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function defineItems()
    local ok, registered, rejected = pcall(function() return exports.rp_inventory:define(Config.items) end)
    if not ok then
        log("rp_inventory not running: gig items not registered (%s)", tostring(registered))
        return
    end
    local n = type(registered) == "table" and countTable(registered) or 0
    log("items registered in rp_inventory: %d (rejected: %s)", n, type(rejected) == "table" and countTable(rejected) or tostring(rejected))
end

-- Decoration: the props of Config.props (the booth terminal), created at start and removed
-- at stop. A refused prop only logs: the board works without it.
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
    if name == "rp_inventory" then
        defineItems()
        return
    end
    if name ~= GetCurrentResourceName() then return end

    log("started: office at %.1f %.1f %.1f, board without fixer=%s, commission=%d%%",
        Config.office.x, Config.office.y, Config.office.z, tostring(Config.openBoardWithoutFixer),
        math.floor(Config.commissionRate * 100 + 0.5))
    defineItems()
    decideStore()
    spawnProps()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)

    if Config.autoPublish then
        local ids = {}
        for id, template in pairs(Config.templates) do
            if template.auto then ids[#ids + 1] = id end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do publishGig(id, nil) end
    end

    -- Hot start: players already in the world never raise onPlayerReady again.
    CreateThread(function()
        waitForStore()
        for _, playerId in ipairs(Open77.players.all()) do
            CreateThread(function() loadReputation(playerId) end)
        end
    end)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    local n = 0
    for playerId, gig in pairs(activeGigs) do
        n = n + 1
        removeNpcs(gig)
        if isConnected(playerId) then TriggerClientEvent("rp_fixer:objective", playerId, false) end
    end
    removeProps()
    log("stopped: %d running gig(s) dropped without penalty", n)
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then
        Open77.chat.addSuggestions(source, SUGGESTIONS)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    loadReputation(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    local gig = activeGigs[playerId]
    if gig then endGig(gig, "dropped") end
    stageClear(playerId)
    local identifier = repByPlayer[playerId]
    repByPlayer[playerId] = nil
    if identifier then rep[identifier] = nil end
end)
