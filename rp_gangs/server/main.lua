-- rp_gangs / server: territories and criminal life for a Night City RP server.
--
-- Everything that matters is decided here: who is in which gang, influence per
-- zone, who holds a territory, tributes, street deals with the buyer NPCs,
-- robberies of a held player, wars and rackets. The client only draws the gang tag
-- over remote members and relays the ALT+click "Rob" and the buyer prompt.
--
-- Storage: SQL first (rp_gangs_members, rp_gangs_influence) through
-- Open77.database, created inside Open77.database.ready. When the server has no
-- database the resource falls back to Open77.kvp and says so in the log. Exports
-- read an in-memory cache and never yield; every change is written through with
-- the callback forms.

local Config = RpGangsConfig
local RESOURCE = "rp_gangs"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local store = nil            -- "sql" | "kvp" | nil while undecided
local storeReason = nil
local storeDecidedAt = nil

local members = {}           -- playerId -> { identifier, gang, rank, name }
local loaded = {}            -- playerId -> true once the file was read (or found empty)
local gangCounts = {}        -- gang -> total members (online + offline)
local influence = {}         -- zone -> { gang = points }
local holders = {}           -- zone -> gang | nil
local lastTerritory = {}     -- playerId -> zone name (last territory entered)
local wars = {}              -- zone -> war record
local warCooldownUntil = {}  -- zone -> monotonic seconds
local dealCooldown = {}      -- playerId -> monotonic seconds of the last deal
local robCooldown = {}       -- victim identifier -> monotonic seconds of the last robbery
local racketCooldown = {}    -- victim identifier -> monotonic seconds
local buyers = {}            -- tostring(npcId) -> zone name
local buyerByZone = {}       -- zone -> npcId
local itemsRegistered = false

local territoryByName = {}
for _, territory in ipairs(Config.territories) do
    territoryByName[territory.name] = territory
    influence[territory.name] = {}
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function log(text)
    print(("[%s] %s"):format(RESOURCE, text))
end

local function now()
    return Open77.time.monotonic()
end

local function say(playerId, text, gang)
    local color = Config.chatColor
    if gang and Config.gangs[gang] then color = Config.gangs[gang].rgb end
    Open77.chat.send(playerId, { type = "system", author = Config.chatAuthor, text = text, color = color })
end

local function toast(playerId, kind, title, message)
    Open77.notifications.send(playerId, { type = kind, title = title, message = message, durationMs = 6000 })
end

local function playerName(playerId)
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

local function gangLabel(gang)
    local def = Config.gangs[gang]
    return def and def.label or tostring(gang)
end

local function rankLabel(rank)
    return Config.ranks[rank] or tostring(rank)
end

local function territoryLabel(zone)
    local t = territoryByName[zone]
    return t and t.label or tostring(zone)
end

-- Resolve a gang by id, label or unambiguous prefix (case-insensitive).
local function resolveGang(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local needle = text:lower():gsub("[%s_%-]", "")
    if Config.gangs[text:lower()] then return text:lower() end
    local found = nil
    for _, id in ipairs(Config.gangOrder) do
        local def = Config.gangs[id]
        local label = def.label:lower():gsub("[%s_%-]", "")
        if id == needle or label == needle then return id end
        if id:sub(1, #needle) == needle or label:sub(1, #needle) == needle then
            if found and found ~= id then return nil, "ambiguous" end
            found = id
        end
    end
    if found then return found end
    return nil, "unknown"
end

-- Resolve a territory by zone name, label or unambiguous prefix.
local function resolveTerritory(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local needle = text:lower():gsub("[%s_%-]", "")
    local found = nil
    for _, t in ipairs(Config.territories) do
        local name = t.name:lower():gsub("[%s_%-]", "")
        local label = t.label:lower():gsub("[%s_%-]", "")
        if name == needle or label == needle then return t.name end
        if name:sub(1, #needle) == needle or label:sub(1, #needle) == needle then
            if found and found ~= t.name then return nil, "ambiguous" end
            found = t.name
        end
    end
    if found then return found end
    return nil, "unknown"
end

local function isTerritory(zone)
    return territoryByName[zone] ~= nil
end

-- Distance between two connected players, or nil, reason.
local function distanceBetween(a, b)
    local pa, pb = Open77.players.position(a), Open77.players.position(b)
    if not pa or not pb then return nil, "no_position" end
    if pa.bucket ~= pb.bucket then return nil, "different_bucket" end
    local dx, dy, dz = pa.x - pb.x, pa.y - pb.y, pa.z - pb.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function distanceToPoint(playerId, point)
    local p = Open77.players.position(playerId)
    if not p then return nil, "no_position" end
    local dx, dy, dz = p.x - point.x, p.y - point.y, p.z - point.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isConnected(playerId)
    return Open77.players.name(playerId) ~= nil
end

local function parsePlayerId(text)
    local id = tonumber(text)
    if not id or id < 1 or id % 1 ~= 0 then return nil end
    return math.floor(id)
end

-- The zone the player stands in right now (rp_zones), or nil.
local function zoneOfPlayer(playerId)
    local ok, zone = pcall(function() return exports.rp_zones:zoneOf(playerId) end)
    if ok and type(zone) == "table" then return zone end
    return nil
end

-- The territory the player stands in right now, or nil. A player can stand in
-- several overlapping zones (Kabuki Market inside the Kabuki district): zoneOf answers the
-- smallest one first, so also fall back to isIn per territory.
local function territoryOfPlayer(playerId)
    local zone = zoneOfPlayer(playerId)
    if zone and isTerritory(zone.name) then return zone.name end
    for _, t in ipairs(Config.territories) do
        local ok, inside = pcall(function() return exports.rp_zones:isIn(playerId, t.name) end)
        if ok and inside == true then return t.name end
    end
    return nil
end

local function playersInZone(zone)
    local ok, list = pcall(function() return exports.rp_zones:playersIn(zone) end)
    if ok and type(list) == "table" then return list end
    return {}
end

local function jobOf(playerId)
    local ok, job = pcall(function() return exports.rp_jobs:getJob(playerId) end)
    if ok and type(job) == "string" then return job end
    return nil
end

local function onlineMembers(gang)
    local list = {}
    for _, playerId in ipairs(Open77.players.all()) do
        local m = members[playerId]
        if m and m.gang == gang then list[#list + 1] = playerId end
    end
    table.sort(list)
    return list
end

local function findBoss(gang)
    for _, playerId in ipairs(onlineMembers(gang)) do
        if members[playerId].rank == 2 then return playerId end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local function decideStore(kind, reason)
    if store then return end
    store = kind
    storeReason = reason
    storeDecidedAt = now()
    if kind == "sql" then
        log("store=sql tables=rp_gangs_members,rp_gangs_influence")
    else
        log(("store=kvp reason=%s"):format(tostring(reason)))
    end
end

-- Waits (yields) until the store is decided, at most 15 s, then falls back to kvp.
local function waitForStore()
    local deadline = now() + 15
    while store == nil and now() < deadline do Wait(250) end
    if store == nil then decideStore("kvp", "database not answering after 15 s") end
end

local function kvpMemberKey(identifier) return "member:" .. identifier end
local function kvpCountKey(gang) return "count:" .. gang end
local function kvpInfluenceKey(zone, gang) return "inf:" .. zone .. ":" .. gang end

-- Write one membership row through (callback forms only: never yields).
local function persistMember(identifier, gang, rank)
    if store == "sql" then
        Open77.database.update(
            "INSERT INTO rp_gangs_members (identifier, gang, `rank`, joined_at) VALUES (?, ?, ?, ?) " ..
            "ON DUPLICATE KEY UPDATE gang = VALUES(gang), `rank` = VALUES(`rank`)",
            { identifier, gang, rank, math.floor(Open77.time.unix()) },
            function() end)
    else
        Open77.kvp.set(kvpMemberKey(identifier), gang .. "|" .. tostring(rank))
    end
end

local function deleteMember(identifier)
    if store == "sql" then
        Open77.database.update("DELETE FROM rp_gangs_members WHERE identifier = ?", { identifier }, function() end)
    else
        Open77.kvp.set(kvpMemberKey(identifier), "")
    end
end

local function persistCount(gang)
    if store == "kvp" then
        Open77.kvp.set(kvpCountKey(gang), gangCounts[gang] or 0)
    end
end

local function persistInfluence(zone, gang)
    local points = influence[zone][gang] or 0
    if store == "sql" then
        Open77.database.update(
            "INSERT INTO rp_gangs_influence (zone, gang, points) VALUES (?, ?, ?) " ..
            "ON DUPLICATE KEY UPDATE points = VALUES(points)",
            { zone, gang, points }, function() end)
    else
        Open77.kvp.set(kvpInfluenceKey(zone, gang), points)
    end
end

-- Reads the whole influence table and the member counts (boot, yields).
local function loadGlobals()
    for _, gang in ipairs(Config.gangOrder) do gangCounts[gang] = 0 end
    if store == "sql" then
        local ok, rows = pcall(function()
            return Open77.database.query.await("SELECT zone, gang, points FROM rp_gangs_influence")
        end)
        if ok and type(rows) == "table" then
            for _, row in ipairs(rows) do
                if influence[row.zone] and Config.gangs[row.gang] then
                    influence[row.zone][row.gang] = tonumber(row.points) or 0
                end
            end
        else
            log("influence read failed: " .. tostring(rows))
        end
        local ok2, counts = pcall(function()
            return Open77.database.query.await("SELECT gang, COUNT(*) AS n FROM rp_gangs_members GROUP BY gang")
        end)
        if ok2 and type(counts) == "table" then
            for _, row in ipairs(counts) do
                if Config.gangs[row.gang] then gangCounts[row.gang] = tonumber(row.n) or 0 end
            end
        else
            log("member count read failed: " .. tostring(counts))
        end
    else
        for _, t in ipairs(Config.territories) do
            for _, gang in ipairs(Config.gangOrder) do
                local points = Open77.kvp.get(kvpInfluenceKey(t.name, gang), 0)
                if type(points) == "number" and points > 0 then influence[t.name][gang] = math.floor(points) end
            end
        end
        for _, gang in ipairs(Config.gangOrder) do
            local n = Open77.kvp.get(kvpCountKey(gang), 0)
            gangCounts[gang] = type(n) == "number" and math.floor(n) or 0
        end
    end
    for _, t in ipairs(Config.territories) do
        local best, bestPoints = nil, 0
        for _, gang in ipairs(Config.gangOrder) do
            local p = influence[t.name][gang] or 0
            if p > bestPoints then best, bestPoints = gang, p end
        end
        holders[t.name] = best
    end
end

-- ---------------------------------------------------------------------------
-- Client sync: the roster (nameplates) and each player's own state
-- ---------------------------------------------------------------------------

local function rosterPayload()
    local list = {}
    for _, playerId in ipairs(Open77.players.all()) do
        local m = members[playerId]
        if m then
            list[#list + 1] = {
                playerId = playerId,
                label = ("[%s] %s"):format(gangLabel(m.gang):upper(), m.name or playerName(playerId)),
                color = Config.gangs[m.gang].color,
            }
        end
    end
    return list
end

local function broadcastRoster()
    if not Config.showTag then return end
    TriggerClientEvent("rp_gangs:roster", -1, rosterPayload())
end

local function sendSelf(playerId)
    local m = members[playerId]
    if m then
        TriggerClientEvent("rp_gangs:self", playerId, m.gang, m.rank, gangLabel(m.gang))
    else
        TriggerClientEvent("rp_gangs:self", playerId, false, false, false)
    end
end

local function buyerIds()
    local ids = {}
    for key in pairs(buyers) do ids[#ids + 1] = key end
    return ids
end

local function sendBuyers(playerId)
    TriggerClientEvent("rp_gangs:buyers", playerId, buyerIds())
end

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------

local function setMembership(playerId, gang, rank, reason)
    local m = members[playerId]
    local identifier = m and m.identifier or Open77.players.identifier(playerId)
    if not identifier then return nil, "no_identifier" end
    local previous = m and m.gang or nil
    if gang == nil then
        if not m then return true end
        members[playerId] = nil
        gangCounts[previous] = math.max(0, (gangCounts[previous] or 1) - 1)
        persistCount(previous)
        deleteMember(identifier)
        log(("player %d left %s (%s)"):format(playerId, previous, reason or "?"))
    else
        if previous ~= gang then
            if previous then
                gangCounts[previous] = math.max(0, (gangCounts[previous] or 1) - 1)
                persistCount(previous)
            end
            gangCounts[gang] = (gangCounts[gang] or 0) + 1
            persistCount(gang)
        end
        members[playerId] = { identifier = identifier, gang = gang, rank = rank, name = playerName(playerId) }
        persistMember(identifier, gang, rank)
        log(("player %d gang=%s rank=%d (%s)"):format(playerId, gang, rank, reason or "?"))
    end
    loaded[playerId] = true
    sendSelf(playerId)
    broadcastRoster()
    if previous ~= gang then
        TriggerEvent("rp_gangs:changed", playerId, gang)
    end
    return true
end

-- Reads one player's file (yields: handlers and threads only).
local function loadMember(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    waitForStore()
    if not isConnected(playerId) then return end
    local gang, rank = nil, nil
    if store == "sql" then
        local ok, row = pcall(function()
            return Open77.database.single.await("SELECT gang, `rank` FROM rp_gangs_members WHERE identifier = ?", { identifier })
        end)
        if not ok then
            log(("player %d file read failed: %s"):format(playerId, tostring(row)))
            say(playerId, "The gang ledger is unreachable. Reconnect in a minute, choom.")
            return
        end
        if type(row) == "table" and Config.gangs[row.gang] then
            gang, rank = row.gang, tonumber(row["rank"]) or 0
        end
    else
        local raw = Open77.kvp.get(kvpMemberKey(identifier), "")
        if type(raw) == "string" and raw ~= "" then
            local g, r = raw:match("^([%w_]+)|(%d+)$")
            if g and Config.gangs[g] then gang, rank = g, tonumber(r) or 0 end
        end
    end
    if not isConnected(playerId) then return end
    loaded[playerId] = true
    if gang then
        rank = math.max(0, math.min(2, math.floor(rank)))
        members[playerId] = { identifier = identifier, gang = gang, rank = rank, name = playerName(playerId) }
        log(("player %d loaded gang=%s rank=%d (%s)"):format(playerId, gang, rank, store))
        say(playerId, ("Welcome back to the %s, %s."):format(gangLabel(gang), rankLabel(rank)), gang)
    end
    sendSelf(playerId)
    sendBuyers(playerId)
    broadcastRoster()
end

-- ---------------------------------------------------------------------------
-- Influence and territory control
-- ---------------------------------------------------------------------------

local function topOfZone(zone)
    local rows = {}
    for gang, points in pairs(influence[zone] or {}) do
        if points > 0 then rows[#rows + 1] = { gang = gang, points = points } end
    end
    table.sort(rows, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        return a.gang < b.gang
    end)
    return rows
end

-- Recomputes the holder of a zone: the gang with strictly the most points. On a
-- tie the current holder keeps the zone. Announces a change.
local function refreshHolder(zone)
    local previous = holders[zone]
    local rows = topOfZone(zone)
    local best = rows[1]
    local newHolder = previous
    if not best then
        newHolder = nil
    elseif previous == nil or (influence[zone][previous] or 0) < best.points then
        newHolder = best.gang
    elseif (influence[zone][previous] or 0) == 0 then
        newHolder = best.gang
    end
    if newHolder ~= previous then
        holders[zone] = newHolder
        if newHolder then
            Open77.chat.send(-1, { type = "system", author = Config.chatAuthor,
                text = ("%s now runs %s."):format(gangLabel(newHolder), territoryLabel(zone)),
                color = Config.gangs[newHolder].rgb })
            log(("zone %s holder=%s (was %s)"):format(zone, newHolder, tostring(previous)))
        else
            log(("zone %s holder=none (was %s)"):format(zone, tostring(previous)))
        end
    end
end

local function addInfluenceInternal(zone, gang, points, reason)
    if not isTerritory(zone) then return nil, "unknown_zone" end
    if not Config.gangs[gang] then return nil, "unknown_gang" end
    if type(points) ~= "number" or points ~= points or points % 1 ~= 0 or points == 0 then return nil, "invalid_points" end
    local current = influence[zone][gang] or 0
    local next = math.max(0, current + points)
    influence[zone][gang] = next
    persistInfluence(zone, gang)
    log(("influence %s %s %+d -> %d (%s)"):format(zone, gang, points, next, tostring(reason or "?")))
    refreshHolder(zone)
    return next
end

-- Where a member's influence event lands: their last territory, else the home zone.
local function zoneForMember(playerId)
    local m = members[playerId]
    if not m then return nil end
    local zone = lastTerritory[playerId]
    if zone and isTerritory(zone) then return zone end
    return Config.gangs[m.gang].home
end

-- ---------------------------------------------------------------------------
-- Buyer NPCs and the street deal
-- ---------------------------------------------------------------------------

local buyerProps = {}        -- zone -> prop id (the crate beside the buyer)

local function removeBuyers()
    for _, npcId in pairs(buyerByZone) do Open77.npcs.remove(npcId) end
    buyers, buyerByZone = {}, {}
    for zone, propId in pairs(buyerProps) do
        Open77.props.remove(propId)
        buyerProps[zone] = nil
    end
end

-- The crate beside a buyer: decoration only, a refusal only logs.
local function spawnBuyerProp(t)
    local model = Config.buyerProp and Config.buyerProp.model
    local at = t.buyer and t.buyer.prop
    if not model or not at or buyerProps[t.name] then return end
    local id, reason = Open77.props.create({
        model = model,
        position = { x = at.x, y = at.y, z = at.z },
        yaw = at.yaw or 0.0,
        bucket = 0,
        streamingRadius = 120.0,
    })
    if id then
        buyerProps[t.name] = id
    else
        log(("buyer crate refused zone=%s: %s"):format(t.name, tostring(reason)))
    end
end

local function spawnBuyers()
    removeBuyers()
    for _, t in ipairs(Config.territories) do
        -- A territory without a buyer (the Afterlife) has no street market: nothing to spawn.
        if not t.buyer then goto continue end
        spawnBuyerProp(t)
        local npcId, reason = Open77.npcs.create({
            record = Config.buyer.record,
            position = { x = t.buyer.x, y = t.buyer.y, z = t.buyer.z },
            yaw = t.buyer.yaw or 0.0,
            damagePolicy = Config.buyer.damagePolicy,
            behavior = { combatEnabled = false, voiceEnabled = false },
            persistent = false,
        })
        if npcId then
            buyers[tostring(npcId)] = t.name
            buyerByZone[t.name] = npcId
            local hold, holdReason = Open77.npcs.tasks.hold(npcId)
            if not hold then log(("buyer %s hold refused: %s"):format(t.name, tostring(holdReason))) end
            log(("buyer spawned zone=%s npc=%s at %.1f %.1f %.1f"):format(t.name, tostring(npcId), t.buyer.x, t.buyer.y, t.buyer.z))
        else
            log(("buyer spawn refused zone=%s: %s"):format(t.name, tostring(reason)))
        end
        ::continue::
    end
    TriggerClientEvent("rp_gangs:buyers", -1, buyerIds())
end

-- The "Street deal" E prompt on the buyer NPCs: a server declaration every client
-- applies. The client predicate `rpGangsIsBuyer` keeps it off every other NPC.
local function defineBuyerPrompt()
    -- Same rule as rp_crime: no world target on 2.31 (Open77.world.nearby unproven, crash
    -- correlation 18 Sept); /gang vendre next to the buyer still works.
    if Config.buyer.nativePrompt ~= true then return end
    local ok, result, reason = pcall(function()
        return exports.open77_interactions:define({
            {
                id = "rp_gangs_deal",
                kind = "globalNpc",
                npcs = "open77",   -- the buyer is an Open77-spawned NPC: resolve from the registry, never query the world
                distance = Config.buyer.promptDistance,
                markerDistance = Config.buyer.markerDistance,
                marker = "shop",
                label = "Street deal",
                description = ("Sell a drug pack for %d eddies"):format(Config.dealPrice),
                key = "E",
                icon = "$",
                color = "#FF8030",
                event = "rp_gangs:dealPrompt",
                canInteract = "rpGangsIsBuyer",
            },
        })
    end)
    if not ok then
        log("buyer prompt not declared (open77_interactions export missing): " .. tostring(result))
    elseif result ~= true then
        log("buyer prompt refused: " .. tostring(reason))
    else
        log("buyer prompt declared (Street deal)")
    end
end

-- Sells one drug pack to the buyer of the territory the player stands in.
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

local STAGE = RpGangsConfig.Stage or {}
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

local function streetDeal(playerId, viaPrompt)
    local m = members[playerId]
    if not m then return say(playerId, "The buyer only deals with gang members. Join a gang first.") end
    local zone = territoryOfPlayer(playerId)
    if not zone then return say(playerId, "No street market here. Find a territory (/territoire).") end
    local npcId = buyerByZone[zone]
    if not npcId then return say(playerId, "No buyer around here right now.") end
    local npc = Open77.npcs.get(npcId)
    if not npc then return say(playerId, "The buyer is gone.") end
    local dist = distanceToPoint(playerId, { x = npc.x, y = npc.y, z = npc.z })
    if not dist or dist > Config.buyer.reach then
        return say(playerId, ("Get closer to the buyer (%d m)."):format(math.floor((dist or 99) + 0.5)))
    end
    local last = dealCooldown[playerId]
    if last and now() - last < Config.dealCooldownMs / 1000 then
        local left = math.ceil(Config.dealCooldownMs / 1000 - (now() - last))
        return say(playerId, ("The buyer is counting eddies. Come back in %d s."):format(left))
    end
    local okHas, has = pcall(function() return exports.rp_inventory:has(playerId, Config.dealItem, 1) end)
    if not okHas then return say(playerId, "The pockets are offline (rp_inventory not running).") end
    if has ~= true then return say(playerId, "Nothing to sell. Bring a drug pack.") end
    -- Staged: the pack held out to the buyer for the bar's length (Config.Stage.deal), then
    -- the pockets are checked again before the pack moves.
    local done = stage(playerId, "deal", { label = "Making the deal" })
    if not done or not done.ok then return say(playerId, "You pocket the pack again. The buyer looks away.") end
    okHas, has = pcall(function() return exports.rp_inventory:has(playerId, Config.dealItem, 1) end)
    if not okHas or has ~= true then return say(playerId, "The pack is gone from your pockets. No deal.") end
    local okRemove, removed, removeReason = pcall(function() return exports.rp_inventory:remove(playerId, Config.dealItem, 1) end)
    if not okRemove or removed ~= true then
        return say(playerId, "Could not hand over the pack: " .. tostring(okRemove and removeReason or removed))
    end
    local okAdd, balance, addReason = pcall(function() return exports.rp_economy:add(playerId, Config.dealPrice, "gang:deal") end)
    if not okAdd or not balance then
        -- Give the pack back rather than swallowing it.
        pcall(function() exports.rp_inventory:add(playerId, Config.dealItem, 1) end)
        return say(playerId, "The wallet is offline: " .. tostring(okAdd and addReason or balance))
    end
    dealCooldown[playerId] = now()
    addInfluenceInternal(zone, m.gang, Config.dealInfluence, "deal by player " .. playerId)
    say(playerId, ("Deal done in %s: +%d €$ cash (%d €$). %s influence +%d."):format(
        territoryLabel(zone), Config.dealPrice, balance, gangLabel(m.gang), Config.dealInfluence), m.gang)
    toast(playerId, "success", "Street deal", ("+%d €$"):format(Config.dealPrice))
    log(("deal player=%d zone=%s gang=%s +%d cash=%d via=%s"):format(playerId, zone, m.gang, Config.dealPrice, balance, viaPrompt and "prompt" or "command"))
end

-- ---------------------------------------------------------------------------
-- Robbery of a held player
-- ---------------------------------------------------------------------------

-- Held by the RP kit (cuffed / escorted / searched), or hands up.
local function isHeldOrHandsUp(targetId)
    local ok, state = pcall(function() return exports.open77_rp_basics:state(targetId) end)
    if ok and state ~= nil and state ~= false then return true, "held" end
    local playback = Open77.animations.current(targetId)
    if type(playback) == "table" and playback.active ~= false and type(playback.steps) == "table" then
        for _, step in ipairs(playback.steps) do
            local profile = step.profile or step.profileId or step.id
            if profile == "handsup" then return true, "handsup" end
        end
    end
    return false
end

local function rob(robberId, targetId)
    local m = members[robberId]
    if not m then return say(robberId, "Robbing is gang business. Join a gang first.") end
    if targetId == robberId then return say(robberId, "Rob yourself? Night City has enough clowns.") end
    if not isConnected(targetId) then return say(robberId, "Unknown player.") end
    local dist, why = distanceBetween(robberId, targetId)
    if not dist then return say(robberId, "Cannot reach them (" .. tostring(why) .. ").") end
    if dist > Config.robReach then
        return say(robberId, ("Too far (%d m). Get within %d m."):format(math.floor(dist + 0.5), Config.robReach))
    end
    local held = isHeldOrHandsUp(targetId)
    if not held then return say(robberId, "They are neither cuffed nor surrendering. Make them raise their hands first.") end
    local victimIdentifier = Open77.players.identifier(targetId) or tostring(targetId)
    local last = robCooldown[victimIdentifier]
    if last and now() - last < Config.robCooldownMs / 1000 then
        return say(robberId, "Their pockets were turned inside out a minute ago. Nothing left.")
    end
    -- Staged: the robber goes through the pockets for the bar's length (Config.Stage.rob); the
    -- victim must still be held when it ends.
    say(targetId, ("%s is going through your pockets."):format(playerName(robberId)))
    local done = stage(robberId, "rob", { label = "Turning the pockets out" })
    if not done or not done.ok then return say(robberId, "You back off. Their pockets stay theirs.") end
    if not isConnected(targetId) or not isHeldOrHandsUp(targetId) then
        return say(robberId, "They got their hands down. Nothing taken.")
    end
    robCooldown[victimIdentifier] = now()

    -- Cash: a share of the victim's wallet.
    local taken = 0
    local okBal, balance = pcall(function() return exports.rp_economy:getBalance(targetId) end)
    if okBal and type(balance) == "number" and balance > 0 then
        local share = math.floor(balance * Config.robShare)
        if share > 0 then
            local okRem, newBalance, reason = pcall(function() return exports.rp_economy:remove(targetId, share, "gang:robbed") end)
            if okRem and newBalance then
                local okAdd, added = pcall(function() return exports.rp_economy:add(robberId, share, "gang:robbery") end)
                if okAdd and added then
                    taken = share
                else
                    -- The robber could not receive it: give the victim their eddies back.
                    pcall(function() exports.rp_economy:add(targetId, share, "gang:robbery_refund") end)
                end
            else
                log(("robbery cash refused victim=%d: %s"):format(targetId, tostring(okRem and reason or newBalance)))
            end
        end
    end

    -- Contraband: every illegal item.
    local loot = {}
    local okList, entries = pcall(function() return exports.rp_inventory:list(targetId) end)
    if okList and type(entries) == "table" then
        for _, entry in ipairs(entries) do
            if entry.illegal and entry.count and entry.count > 0 then
                local okRem, removed = pcall(function() return exports.rp_inventory:remove(targetId, entry.id, entry.count) end)
                if okRem and removed == true then
                    local okAdd, added = pcall(function() return exports.rp_inventory:add(robberId, entry.id, entry.count) end)
                    if okAdd and added == true then
                        loot[#loot + 1] = ("%s x%d"):format(entry.label or entry.id, entry.count)
                    else
                        pcall(function() exports.rp_inventory:add(targetId, entry.id, entry.count) end)
                        say(robberId, ("Could not carry %s x%d: left in their pockets."):format(entry.label or entry.id, entry.count))
                    end
                end
            end
        end
    end

    local robberName, victimName = playerName(robberId), playerName(targetId)
    local summary = ("%d €$"):format(taken)
    if #loot > 0 then summary = summary .. ", " .. table.concat(loot, ", ") end
    say(robberId, ("You robbed %s: %s."):format(victimName, summary), m.gang)
    say(targetId, ("%s robbed you: %s."):format(robberName, summary))
    toast(targetId, "warning", "Robbed", summary)
    local pos = Open77.players.position(targetId) or Open77.players.position(robberId)
    TriggerEvent("rp_ncpd:alert", Config.alertKinds.robbery, pos and { x = pos.x, y = pos.y, z = pos.z } or nil,
        ("%s robbed by a %s (%s)"):format(victimName, gangLabel(m.gang), summary), robberId)
    log(("robbery robber=%d victim=%d cash=%d items=%d"):format(robberId, targetId, taken, #loot))
end

-- ---------------------------------------------------------------------------
-- Wars
-- ---------------------------------------------------------------------------

local function gangAtWar(gang)
    for zone, war in pairs(wars) do
        if war.attacker == gang or war.defender == gang then return zone end
    end
    return nil
end

local function tellGang(gang, text, kind, title)
    for _, playerId in ipairs(onlineMembers(gang)) do
        say(playerId, text, gang)
        if kind then toast(playerId, kind, title or "Gang war", text) end
    end
end

local function startWar(bossId, zone)
    local m = members[bossId]
    local defender = holders[zone]
    local war = {
        zone = zone, attacker = m.gang, defender = defender,
        startedAt = now(), endsAt = now() + Config.warMinutes * 60,
        nextTick = now() + Config.warTickMs / 1000,
        score = { [m.gang] = 0, [defender] = 0 },
        ticks = 0,
    }
    wars[zone] = war
    local label = territoryLabel(zone)
    Open77.chat.send(-1, { type = "system", author = Config.chatAuthor,
        text = ("WAR: the %s move on %s, held by the %s. %d minutes on the clock."):format(
            gangLabel(m.gang), label, gangLabel(defender), Config.warMinutes),
        color = Config.gangs[m.gang].rgb })
    tellGang(m.gang, ("War on %s: hold the zone with more members than the %s."):format(label, gangLabel(defender)), "warning")
    tellGang(defender, ("The %s are hitting %s! Defend it, every %d s the bigger crew scores."):format(gangLabel(m.gang), label, math.floor(Config.warTickMs / 1000)), "error")
    local defenderBoss = findBoss(defender)
    if defenderBoss then
        say(defenderBoss, ("Boss, %s declared war on your turf at %s."):format(playerName(bossId), label), defender)
    end
    local t = territoryByName[zone]
    TriggerEvent("rp_ncpd:alert", Config.alertKinds.war, t and t.position or nil,
        ("Gang war at %s: %s vs %s"):format(label, gangLabel(m.gang), gangLabel(defender)), bossId)
    TriggerEvent("rp_gangs:war", zone, m.gang, defender, "start")
    log(("war start zone=%s attacker=%s defender=%s by=%d minutes=%d"):format(zone, m.gang, defender, bossId, Config.warMinutes))
end

local function warTick(war)
    local counts = { [war.attacker] = 0, [war.defender] = 0 }
    for _, playerId in ipairs(playersInZone(war.zone)) do
        local pid = tonumber(playerId)
        local m = pid and members[pid]
        if m and counts[m.gang] then counts[m.gang] = counts[m.gang] + 1 end
    end
    war.ticks = war.ticks + 1
    local winner = nil
    if counts[war.attacker] > counts[war.defender] then winner = war.attacker
    elseif counts[war.defender] > counts[war.attacker] then winner = war.defender end
    if winner then war.score[winner] = war.score[winner] + 1 end
    TriggerEvent("rp_gangs:war", war.zone, war.attacker, war.defender, "tick", {
        attackerScore = war.score[war.attacker], defenderScore = war.score[war.defender],
        attackerInside = counts[war.attacker], defenderInside = counts[war.defender],
        secondsLeft = math.max(0, math.floor(war.endsAt - now())),
    })
    local line = ("%s: %s %d - %d %s (inside: %d vs %d, %d s left)"):format(
        territoryLabel(war.zone), gangLabel(war.attacker), war.score[war.attacker],
        war.score[war.defender], gangLabel(war.defender), counts[war.attacker], counts[war.defender],
        math.max(0, math.floor(war.endsAt - now())))
    tellGang(war.attacker, line)
    tellGang(war.defender, line)
end

local function endWar(war, reason)
    wars[war.zone] = nil
    warCooldownUntil[war.zone] = now() + Config.warCooldownMs / 1000
    local a, d = war.score[war.attacker], war.score[war.defender]
    local winner = nil
    if a > d then winner = war.attacker elseif d > a then winner = war.defender end
    local label = territoryLabel(war.zone)
    if winner then
        addInfluenceInternal(war.zone, winner, Config.warInfluence, "war won")
        Open77.chat.send(-1, { type = "system", author = Config.chatAuthor,
            text = ("WAR OVER: the %s take %s (%d - %d). +%d influence."):format(
                gangLabel(winner), label, math.max(a, d), math.min(a, d), Config.warInfluence),
            color = Config.gangs[winner].rgb })
    else
        Open77.chat.send(-1, { type = "system", author = Config.chatAuthor,
            text = ("WAR OVER: stalemate at %s (%d - %d). The %s keep it."):format(label, a, d, gangLabel(war.defender)),
            color = Config.chatColor })
    end
    TriggerEvent("rp_gangs:war", war.zone, war.attacker, war.defender, "end", {
        attackerScore = a, defenderScore = d, winner = winner, reason = reason,
    })
    log(("war end zone=%s attacker=%s defender=%s score=%d-%d winner=%s (%s)"):format(
        war.zone, war.attacker, war.defender, a, d, tostring(winner), reason))
end

-- ---------------------------------------------------------------------------
-- Tribute
-- ---------------------------------------------------------------------------

local function payTribute()
    for _, t in ipairs(Config.territories) do
        local gang = holders[t.name]
        if gang then
            for _, playerId in ipairs(onlineMembers(gang)) do
                local ok, balance, reason = pcall(function()
                    return exports.rp_economy:add(playerId, Config.tributePerZone, "gang:tribute:" .. t.name)
                end)
                if ok and balance then
                    say(playerId, ("Tribute from %s: +%d €$ (cash %d €$)."):format(t.label, Config.tributePerZone, balance), gang)
                    log(("tribute player=%d gang=%s zone=%s +%d cash=%d"):format(playerId, gang, t.name, Config.tributePerZone, balance))
                else
                    say(playerId, ("No tribute from %s this time: the wallet is offline (%s)."):format(t.label, tostring(ok and reason or balance)))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Items in rp_inventory
-- ---------------------------------------------------------------------------

local function registerItems()
    local ok, registered, rejected = pcall(function() return exports.rp_inventory:define(Config.items) end)
    if ok then
        itemsRegistered = true
        local n = type(registered) == "table" and #registered or tonumber(registered) or 0
        local r = type(rejected) == "table" and #rejected or tonumber(rejected) or 0
        log(("items registered in rp_inventory: %s (rejected: %s)"):format(tostring(n), tostring(r)))
    else
        itemsRegistered = false
        log("items not registered (rp_inventory export missing): " .. tostring(registered))
    end
end

-- ---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
-- ---------------------------------------------------------------------------

exports("gangOf", function(playerId)
    if type(playerId) ~= "number" then return nil end
    local m = members[playerId]
    return m and m.gang or nil
end)

exports("isBoss", function(playerId)
    if type(playerId) ~= "number" then return false end
    local m = members[playerId]
    return m ~= nil and m.rank == 2
end)

exports("rankOf", function(playerId)
    if type(playerId) ~= "number" then return nil end
    local m = members[playerId]
    if not m then return nil end
    return { level = m.rank, label = rankLabel(m.rank) }
end)

exports("influence", function(zone)
    if not isTerritory(zone) then return nil, "unknown_zone" end
    local copy = {}
    for gang, points in pairs(influence[zone]) do copy[gang] = points end
    return copy
end)

exports("holderOf", function(zone)
    if not isTerritory(zone) then return nil, "unknown_zone" end
    return holders[zone]
end)

exports("addInfluence", function(zone, gang, points, reason)
    if type(zone) ~= "string" then return nil, "unknown_zone" end
    if type(gang) ~= "string" then return nil, "unknown_gang" end
    if type(reason) ~= "string" then reason = GetInvokingResource() or "export" end
    return addInfluenceInternal(zone, gang, points, reason)
end)

-- ---------------------------------------------------------------------------
-- Chat suggestions
-- ---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/gang", help = "Your gang: status, creer <gang>, recruter <id>, virer <id>, promouvoir <id>, quitter, vendre, depouiller <id>" },
    { command = "/gang creer", help = "Found a gang and become its boss (jobless only)", parameters = { { name = "gang", help = "maelstrom, tygerclaws, valentinos, sixthstreet, animals, voodooboys, scavs" } } },
    { command = "/gang recruter", help = "Boss/lieutenant: recruit a jobless player within 5 m", parameters = { { name = "playerId", help = "session id (/players)" } } },
    { command = "/gang virer", help = "Boss/lieutenant: kick a member", parameters = { { name = "playerId", help = "session id" } } },
    { command = "/gang promouvoir", help = "Boss: member -> lieutenant -> boss (hands over the seat)", parameters = { { name = "playerId", help = "session id" } } },
    { command = "/gang quitter", help = "Leave your gang" },
    { command = "/gang vendre", help = "Sell one drug pack to the buyer of the territory you stand in" },
    { command = "/gang depouiller", help = "Rob a cuffed or surrendering player within 3 m", parameters = { { name = "playerId", help = "session id" } } },
    { command = "/territoire", help = "Territories, their holder and the top-3 influence" },
    { command = "/guerre", help = "Boss: declare war on a territory your gang does not hold", parameters = { { name = "zone", help = "kabuki_market, lizzies, junkyard, afterlife" } } },
    { command = "/racket", help = "Threaten a player for protection money (NCPD is paged)", parameters = { { name = "playerId", help = "session id" } } },
    { command = "/setgang", help = "Admin: put a player in a gang (or none)", parameters = { { name = "playerId", help = "session id" }, { name = "gang", help = "gang id or none" }, { name = "rank", help = "0..2" } } },
}

RegisterNetEvent("chat:ready", function()
    if source and source ~= 0 then Open77.chat.addSuggestions(source, SUGGESTIONS) end
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function requireGame(source)
    if source == 0 then print("[rp_gangs] run it from the game"); return false end
    return true
end

local function gangStatus(source)
    local m = members[source]
    if not m then
        local labels = {}
        for _, id in ipairs(Config.gangOrder) do
            labels[#labels + 1] = ("%s (%s, %d)"):format(Config.gangs[id].label, id, gangCounts[id] or 0)
        end
        CreateThread(function()
            say(source, "You run with nobody. /gang creer <gang> to found one, or get recruited.")
            Wait(0)
            say(source, "Gangs: " .. table.concat(labels, ", "))
        end)
        return
    end
    local online = onlineMembers(m.gang)
    local names = {}
    for _, pid in ipairs(online) do names[#names + 1] = ("%s [%s]"):format(members[pid].name or playerName(pid), rankLabel(members[pid].rank)) end
    local held = {}
    for _, t in ipairs(Config.territories) do
        if holders[t.name] == m.gang then held[#held + 1] = t.label end
    end
    CreateThread(function()
        say(source, ("%s - %s. %d member(s), %d online: %s"):format(gangLabel(m.gang), rankLabel(m.rank), gangCounts[m.gang] or #online, #online, table.concat(names, ", ")), m.gang)
        Wait(0)
        say(source, ("Territories held: %s. Tribute %d €$ per zone every %d min."):format(#held > 0 and table.concat(held, ", ") or "none", Config.tributePerZone, math.floor(Config.tributeIntervalMs / 60000)), m.gang)
        -- Hideout: the boss's home (rp_housing), when the boss is online and owns one.
        local bossId = findBoss(m.gang)
        if bossId then
            local okHome, home = pcall(function() return exports.rp_housing:homeOf(bossId) end)
            if okHome and type(home) == "table" and home.position then
                Wait(0)
                say(source, ("Hideout: %s at %.0f, %.0f, %.0f (the boss's place)."):format(
                    tostring(home.label or home.id), home.position.x or 0, home.position.y or 0, home.position.z or 0), m.gang)
            end
        end
        local zone = gangAtWar(m.gang)
        if zone then
            Wait(0)
            local war = wars[zone]
            say(source, ("At war in %s: %s %d - %d %s, %d s left."):format(territoryLabel(zone), gangLabel(war.attacker), war.score[war.attacker], war.score[war.defender], gangLabel(war.defender), math.max(0, math.floor(war.endsAt - now()))), m.gang)
        end
    end)
end

local function gangCreate(source, text)
    if members[source] then return say(source, ("You already run with the %s. /gang quitter first."):format(gangLabel(members[source].gang))) end
    if not Config.openFounding then return say(source, "Founding is closed on this server. Get recruited, or ask an admin (/setgang).") end
    if not loaded[source] then return say(source, "Your file is still loading. Try again in a second.") end
    local gang, why = resolveGang(text or "")
    if not gang then
        if why == "ambiguous" then return say(source, "Which gang? Be more specific.") end
        return say(source, "Unknown gang. Pick one: " .. table.concat(Config.gangOrder, ", "))
    end
    if (gangCounts[gang] or 0) > 0 then
        return say(source, ("The %s already have a boss. Get recruited by one of them."):format(gangLabel(gang)))
    end
    local job = jobOf(source)
    if job then return say(source, ("Gangs do not take corpos with a day job (%s). Resign first."):format(job)) end
    local ok, reason = setMembership(source, gang, 2, "founded")
    if not ok then return say(source, "Could not found the gang: " .. tostring(reason)) end
    say(source, ("You founded the %s. You are the boss: /gang recruter <id> to build your crew."):format(gangLabel(gang)), gang)
    toast(source, "success", gangLabel(gang), "You are the boss.")
    Open77.chat.send(-1, { type = "system", author = Config.chatAuthor,
        text = ("Word on the street: %s now runs the %s."):format(playerName(source), gangLabel(gang)),
        color = Config.gangs[gang].rgb })
end

local function gangRecruit(source, targetText)
    local m = members[source]
    if not m then return say(source, "You are in no gang.") end
    if m.rank < 1 then return say(source, "Only the boss and the lieutenants recruit.") end
    local targetId = parsePlayerId(targetText)
    if not targetId then return say(source, "Usage: /gang recruter <playerId>") end
    if targetId == source then return say(source, "You are already in.") end
    if not isConnected(targetId) then return say(source, "Unknown player.") end
    if not loaded[targetId] then return say(source, "Their file is still loading. Try again in a second.") end
    if members[targetId] then return say(source, ("%s already runs with the %s."):format(playerName(targetId), gangLabel(members[targetId].gang))) end
    local job = jobOf(targetId)
    if job then return say(source, ("%s has a day job (%s). Gangs take the jobless only."):format(playerName(targetId), job)) end
    local dist, why = distanceBetween(source, targetId)
    if not dist then return say(source, "Cannot reach them (" .. tostring(why) .. ").") end
    if dist > Config.recruitReach then
        return say(source, ("Too far away (%d m). Get within %d m to recruit someone."):format(math.floor(dist + 0.5), Config.recruitReach))
    end
    local ok, reason = setMembership(targetId, m.gang, 0, "recruited by player " .. source)
    if not ok then return say(source, "Could not recruit: " .. tostring(reason)) end
    say(source, ("%s is now a %s member."):format(playerName(targetId), gangLabel(m.gang)), m.gang)
    say(targetId, ("%s brought you into the %s. Welcome, choom. /gang for your crew."):format(playerName(source), gangLabel(m.gang)), m.gang)
    toast(targetId, "success", gangLabel(m.gang), "You are in.")
end

local function gangFire(source, targetText)
    local m = members[source]
    if not m then return say(source, "You are in no gang.") end
    if m.rank < 1 then return say(source, "Only the boss and the lieutenants kick people out.") end
    local targetId = parsePlayerId(targetText)
    if not targetId then return say(source, "Usage: /gang virer <playerId>") end
    if targetId == source then return say(source, "Use /gang quitter to leave.") end
    local t = members[targetId]
    if not t or t.gang ~= m.gang then return say(source, "They are not in your gang.") end
    if t.rank >= m.rank then return say(source, ("You cannot kick a %s."):format(rankLabel(t.rank))) end
    local gang = m.gang
    setMembership(targetId, nil, nil, "fired by player " .. source)
    say(source, ("%s is out of the %s."):format(playerName(targetId), gangLabel(gang)), gang)
    say(targetId, ("%s cut you loose from the %s. Watch your back."):format(playerName(source), gangLabel(gang)))
end

local function gangPromote(source, targetText)
    local m = members[source]
    if not m then return say(source, "You are in no gang.") end
    if m.rank < 2 then return say(source, "Only the boss promotes.") end
    local targetId = parsePlayerId(targetText)
    if not targetId then return say(source, "Usage: /gang promouvoir <playerId>") end
    if targetId == source then return say(source, "You are already the boss.") end
    local t = members[targetId]
    if not t or t.gang ~= m.gang then return say(source, "They are not in your gang.") end
    local gang = m.gang
    if t.rank == 0 then
        setMembership(targetId, gang, 1, "promoted by player " .. source)
        say(source, ("%s is now a lieutenant."):format(playerName(targetId)), gang)
        say(targetId, ("%s made you a lieutenant of the %s. You can recruit now."):format(playerName(source), gangLabel(gang)), gang)
    else
        setMembership(targetId, gang, 2, "seat handed by player " .. source)
        setMembership(source, gang, 1, "stepped down")
        say(source, ("You handed the %s boss seat to %s. You are now a lieutenant."):format(gangLabel(gang), playerName(targetId)), gang)
        say(targetId, ("%s handed you the %s. You are the boss now."):format(playerName(source), gangLabel(gang)), gang)
        toast(targetId, "success", gangLabel(gang), "You are the boss.")
    end
end

local function gangLeave(source)
    local m = members[source]
    if not m then return say(source, "You are in no gang.") end
    local gang = m.gang
    if m.rank == 2 and (gangCounts[gang] or 1) > 1 then
        return say(source, "A boss does not walk out on the crew. Hand over the seat first: /gang promouvoir <lieutenant>.")
    end
    setMembership(source, nil, nil, "quit")
    say(source, ("You left the %s."):format(gangLabel(gang)))
    if (gangCounts[gang] or 0) == 0 then
        for _, t in ipairs(Config.territories) do
            if (influence[t.name][gang] or 0) > 0 then
                influence[t.name][gang] = 0
                persistInfluence(t.name, gang)
                refreshHolder(t.name)
            end
        end
        log(("gang %s dissolved: last member left, influence cleared"):format(gang))
        Open77.chat.send(-1, { type = "system", author = Config.chatAuthor,
            text = ("The %s are no more. Their turf is up for grabs."):format(gangLabel(gang)), color = Config.chatColor })
    end
end

RegisterCommand("gang", function(source, args)
    if not requireGame(source) then return end
    local sub = (args[1] or ""):lower()
    if sub == "" then return gangStatus(source) end
    if sub == "creer" then return gangCreate(source, args[2]) end
    if sub == "recruter" then return gangRecruit(source, args[2]) end
    if sub == "virer" then return gangFire(source, args[2]) end
    if sub == "promouvoir" then return gangPromote(source, args[2]) end
    if sub == "quitter" then return gangLeave(source) end
    if sub == "vendre" then return streetDeal(source, false) end
    if sub == "depouiller" then
        local targetId = parsePlayerId(args[2])
        if not targetId then return say(source, "Usage: /gang depouiller <playerId>") end
        return rob(source, targetId)
    end
    say(source, "Usage: /gang [creer <gang> | recruter <id> | virer <id> | promouvoir <id> | quitter | vendre | depouiller <id>]")
end, false)

RegisterCommand("territoire", function(source, args)
    local lines = {}
    for _, t in ipairs(Config.territories) do
        local rows = topOfZone(t.name)
        local top = {}
        for i = 1, math.min(3, #rows) do top[#top + 1] = ("%s %d"):format(gangLabel(rows[i].gang), rows[i].points) end
        local holder = holders[t.name] and gangLabel(holders[t.name]) or "nobody"
        local war = wars[t.name]
        local line = ("%s (%s): held by %s%s. Top: %s"):format(t.label, t.name, holder,
            war and (" - AT WAR " .. gangLabel(war.attacker) .. " vs " .. gangLabel(war.defender)) or "",
            #top > 0 and table.concat(top, ", ") or "no influence yet")
        lines[#lines + 1] = line
    end
    if source == 0 then
        for _, line in ipairs(lines) do print("[rp_gangs] " .. line) end
        return
    end
    CreateThread(function()
        say(source, ("Territories (%d): the gang with the most influence holds the zone."):format(#Config.territories))
        for _, line in ipairs(lines) do Wait(0); say(source, line) end
    end)
end, false)

RegisterCommand("guerre", function(source, args)
    if not requireGame(source) then return end
    local m = members[source]
    if not m then return say(source, "You are in no gang.") end
    if m.rank < 2 then return say(source, "Only the boss declares war.") end
    local zone, why = resolveTerritory(args[1] or "")
    if not zone then
        if why == "ambiguous" then return say(source, "Which territory? Be more specific.") end
        local names = {}
        for _, t in ipairs(Config.territories) do names[#names + 1] = t.name end
        return say(source, "Usage: /guerre <zone>. Territories: " .. table.concat(names, ", "))
    end
    local holder = holders[zone]
    if holder == m.gang then return say(source, ("You already hold %s. Nothing to take."):format(territoryLabel(zone))) end
    if not holder then return say(source, ("Nobody holds %s: deal there and take it with influence."):format(territoryLabel(zone))) end
    if wars[zone] then return say(source, ("%s is already at war."):format(territoryLabel(zone))) end
    local until_ = warCooldownUntil[zone]
    if until_ and now() < until_ then
        return say(source, ("%s just cooled down from a war. Try again in %d min."):format(territoryLabel(zone), math.ceil((until_ - now()) / 60)))
    end
    local busy = gangAtWar(m.gang)
    if busy then return say(source, ("The %s are already fighting in %s."):format(gangLabel(m.gang), territoryLabel(busy))) end
    if #onlineMembers(holder) == 0 then
        return say(source, ("The %s have nobody online to defend %s. No glory in that; come back later."):format(gangLabel(holder), territoryLabel(zone)))
    end
    startWar(source, zone)
end, false)

RegisterCommand("racket", function(source, args)
    if not requireGame(source) then return end
    local m = members[source]
    if not m then return say(source, "Rackets are gang business. Join a gang first.") end
    local targetId = parsePlayerId(args[1])
    if not targetId then return say(source, "Usage: /racket <playerId>") end
    if targetId == source then return say(source, "Shaking yourself down? Try somebody else.") end
    if not isConnected(targetId) then return say(source, "Unknown player.") end
    local dist, why = distanceBetween(source, targetId)
    if not dist then return say(source, "Cannot reach them (" .. tostring(why) .. ").") end
    if dist > Config.racketReach then
        return say(source, ("Too far (%d m). Get within %d m."):format(math.floor(dist + 0.5), Config.racketReach))
    end
    local victimIdentifier = Open77.players.identifier(targetId) or tostring(targetId)
    local last = racketCooldown[victimIdentifier]
    if last and now() - last < Config.racketCooldownMs / 1000 then
        return say(source, "They got the message already. Give it a minute.")
    end
    racketCooldown[victimIdentifier] = now()
    local gang = gangLabel(m.gang)
    say(targetId, ("%s of the %s wants %d €$ protection money. Pay up (/pay %d %d) or deal with the consequences."):format(
        playerName(source), gang, Config.racketAmount, source, Config.racketAmount))
    toast(targetId, "warning", gang, ("Protection money: %d €$"):format(Config.racketAmount))
    say(source, ("You leaned on %s for %d €$. Whether they pay is their call (/pay)."):format(playerName(targetId), Config.racketAmount), m.gang)
    local pos = Open77.players.position(targetId)
    TriggerEvent("rp_ncpd:alert", Config.alertKinds.racket, pos and { x = pos.x, y = pos.y, z = pos.z } or nil,
        ("%s is being extorted by the %s"):format(playerName(targetId), gang), source)
    log(("racket by=%d target=%d gang=%s amount=%d"):format(source, targetId, m.gang, Config.racketAmount))
end, false)

-- Admin escape hatch: /setgang <playerId> <gang|none> [rank]. ACL command.setgang, or the console.
RegisterCommand("setgang", function(source, args)
    local function answer(text)
        if source == 0 then print("[rp_gangs] " .. text) else say(source, text) end
    end
    local targetId = parsePlayerId(args[1])
    if not targetId then return answer("Usage: setgang <playerId> <gang|none> [rank 0-2]") end
    if not isConnected(targetId) then return answer("Unknown player.") end
    if not loaded[targetId] then return answer("Their file is still loading.") end
    local what = (args[2] or ""):lower()
    if what == "none" or what == "aucun" then
        if not members[targetId] then return answer("They are in no gang.") end
        local gang = members[targetId].gang
        setMembership(targetId, nil, nil, "setgang by " .. source)
        say(targetId, ("An admin took you out of the %s."):format(gangLabel(gang)))
        return answer(("%s removed from the %s."):format(playerName(targetId), gangLabel(gang)))
    end
    local gang = resolveGang(what)
    if not gang then return answer("Unknown gang. One of: " .. table.concat(Config.gangOrder, ", ") .. ", or none.") end
    local rank = tonumber(args[3] or "0")
    if not rank or rank < 0 or rank > 2 or rank % 1 ~= 0 then return answer("Rank must be 0, 1 or 2.") end
    setMembership(targetId, gang, math.floor(rank), "setgang by " .. source)
    say(targetId, ("An admin made you %s of the %s."):format(rankLabel(math.floor(rank)), gangLabel(gang)), gang)
    answer(("%s is now %s of the %s."):format(playerName(targetId), rankLabel(math.floor(rank)), gangLabel(gang)))
end, true)

-- ---------------------------------------------------------------------------
-- Net events from the client
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_gangs:clientReady", function()
    local playerId = source
    if not playerId or playerId == 0 then return end
    sendSelf(playerId)
    sendBuyers(playerId)
    if Config.showTag then TriggerClientEvent("rp_gangs:roster", playerId, rosterPayload()) end
end)

RegisterNetEvent("rp_gangs:rob", function(targetId)
    local playerId = source
    if not playerId or playerId == 0 then return end
    targetId = tonumber(targetId)
    if not targetId or targetId < 1 or targetId % 1 ~= 0 then return say(playerId, "Rob who?") end
    rob(playerId, math.floor(targetId))
end)

-- The buyer prompt: reported by open77_interactions, re-measured by the server.
AddEventHandler("onNpcInteracted", function(npcId, playerId, interactionId, choiceId, distance)
    local zone = buyers[tostring(npcId)]
    if not zone then return end
    if type(interactionId) ~= "string" or interactionId:sub(1, 13) ~= "rp_gangs_deal" then return end
    local pid = tonumber(playerId)
    if not pid then return end
    if (tonumber(distance) or 99) > Config.buyer.reach then return say(pid, "Get closer to the buyer.") end
    streetDeal(pid, true)
end)

-- ---------------------------------------------------------------------------
-- Bus events from the other resources
-- ---------------------------------------------------------------------------

AddEventHandler("rp_zones:entered", function(playerId, name)
    local pid = tonumber(playerId)
    if pid and isTerritory(name) then lastTerritory[pid] = name end
end)

-- A member arrested by the NCPD costs the gang influence.
AddEventHandler("rp_ncpd:arrest", function(playerId, byPlayerId, minutes)
    local pid = tonumber(playerId)
    local m = pid and members[pid]
    if not m then return end
    local zone = zoneForMember(pid)
    if not zone then return end
    local before = influence[zone][m.gang] or 0
    if before <= 0 then return end
    addInfluenceInternal(zone, m.gang, Config.arrestInfluence, "arrest of player " .. pid)
    tellGang(m.gang, ("%s got booked by the NCPD: %s influence in %s (%d -> %d)."):format(
        m.name or playerName(pid), Config.arrestInfluence, territoryLabel(zone), before, influence[zone][m.gang] or 0))
end)

-- A gig completed by a member earns the gang influence.
AddEventHandler("rp_fixer:gig", function(gigId, phase, playerId)
    if phase ~= "success" and phase ~= "done" then return end
    local pid = tonumber(playerId)
    local m = pid and members[pid]
    if not m then return end
    local zone = zoneForMember(pid)
    if not zone then return end
    addInfluenceInternal(zone, m.gang, Config.gigInfluence, "gig " .. tostring(gigId) .. " by player " .. pid)
    say(pid, ("Gig done for the %s: +%d influence in %s."):format(gangLabel(m.gang), Config.gigInfluence, territoryLabel(zone)), m.gang)
end)

-- A member who takes a job is cut loose (membership is for the jobless).
AddEventHandler("rp_jobs:changed", function(playerId, jobName)
    if not Config.dropOnJob then return end
    local pid = tonumber(playerId)
    local m = pid and members[pid]
    if not m or jobName == nil then return end
    local gang, wasBoss = m.gang, m.rank == 2
    setMembership(pid, nil, nil, "took job " .. tostring(jobName))
    say(pid, ("You took a day job (%s): the %s cut you loose."):format(tostring(jobName), gangLabel(gang)))
    if wasBoss then
        local heir = nil
        for _, other in ipairs(onlineMembers(gang)) do
            if not heir or members[other].rank > members[heir].rank then heir = other end
        end
        if heir then
            setMembership(heir, gang, 2, "succession")
            say(heir, ("The boss went straight. You run the %s now."):format(gangLabel(gang)), gang)
        elseif (gangCounts[gang] or 0) > 0 then
            log(("gang %s has no boss online after succession; an admin can fix it with /setgang"):format(gang))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onPlayerReady", function(playerId)
    local pid = tonumber(playerId)
    if not pid then return end
    loadMember(pid)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = tonumber(playerId)
    if not pid then return end
    members[pid] = nil
    loaded[pid] = nil
    lastTerritory[pid] = nil
    dealCooldown[pid] = nil
    stageClear(pid)
    broadcastRoster()
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and name ~= GetCurrentResourceName() then
        registerItems()
        return
    end
    if name == "open77_interactions" and name ~= GetCurrentResourceName() then
        defineBuyerPrompt()
        return
    end
    if name ~= GetCurrentResourceName() then return end

    log(("started: %d gangs, %d territories, tribute %d eddies per zone every %d min, war %d min, deal %d eddies"):format(
        #Config.gangOrder, #Config.territories, Config.tributePerZone, math.floor(Config.tributeIntervalMs / 60000),
        Config.warMinutes, Config.dealPrice))
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    registerItems()

    -- Storage decision.
    local ok, reason = Open77.database.ready(function()
        local created = pcall(function()
            Open77.database.update.await([[
                CREATE TABLE IF NOT EXISTS rp_gangs_members (
                    identifier VARCHAR(64) NOT NULL PRIMARY KEY,
                    gang       VARCHAR(32) NOT NULL,
                    `rank`     TINYINT     NOT NULL DEFAULT 0,
                    joined_at  BIGINT      NOT NULL DEFAULT 0,
                    INDEX idx_rp_gangs_members_gang (gang)
                )
            ]])
            Open77.database.update.await([[
                CREATE TABLE IF NOT EXISTS rp_gangs_influence (
                    zone   VARCHAR(32) NOT NULL,
                    gang   VARCHAR(32) NOT NULL,
                    points INT         NOT NULL DEFAULT 0,
                    PRIMARY KEY (zone, gang)
                )
            ]])
        end)
        if created then decideStore("sql") else decideStore("kvp", "schema creation failed") end
    end)
    if not ok then decideStore("kvp", tostring(reason)) end

    CreateThread(function()
        waitForStore()
        loadGlobals()
        local held = {}
        for _, t in ipairs(Config.territories) do
            held[#held + 1] = ("%s=%s"):format(t.name, holders[t.name] or "none")
        end
        log("territories: " .. table.concat(held, " "))
        -- Players already connected on a hot start.
        for _, pid in ipairs(Open77.players.all()) do
            if not loaded[pid] then CreateThread(function() loadMember(pid) end) end
        end
        spawnBuyers()
        defineBuyerPrompt()
    end)

    -- Tribute.
    CreateThread(function()
        while true do
            Wait(Config.tributeIntervalMs)
            payTribute()
        end
    end)

    -- War clock.
    CreateThread(function()
        while true do
            Wait(1000)
            for zone, war in pairs(wars) do
                if now() >= war.endsAt then
                    endWar(war, "time")
                elseif now() >= war.nextTick then
                    war.nextTick = war.nextTick + Config.warTickMs / 1000
                    warTick(war)
                end
            end
        end
    end)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for zone, war in pairs(wars) do endWar(war, "resource_stopping") end
    removeBuyers()
    pcall(function() exports.open77_interactions:undefine() end)
end)
