-- rp_hud: server half.
--
-- Builds one snapshot per player from the exports of the other RP resources
-- (every call in pcall: none of them is a manifest dependency, because this
-- resource ships a client script) and pushes it to that player's client
-- through the net event rp_hud:state. Pushes are throttled to one every
-- RpHudConfig.minPushIntervalMs per player (4 per second by default): a burst
-- of events is coalesced into a single snapshot sent when the window closes.
--
-- Nothing is decided or persisted here: the HUD shows what the other
-- resources own. There is no SQL table.

local Config = RpHudConfig
local RESOURCE = GetCurrentResourceName()

local connected = {}   -- playerId (number) -> true once the player is ready or asked for a snapshot
local throttle = {}    -- playerId (number) -> { lastAt = seconds | nil, pending = boolean }
local depSet = {}      -- resource name -> true for the resources whose events feed the panel
for _, name in ipairs(Config.dependencies) do depSet[name] = true end

local function now()
    return Open77.time.monotonic()
end

local function log(fmt, ...)
    print(("[rp_hud] " .. fmt):format(...))
end

-- Runs one export call and swallows the raise a missing resource or export
-- produces. Returns the export's own results, or nil, "unavailable".
local function safe(fn)
    local ok, a, b = pcall(fn)
    if ok then return a, b end
    return nil, "unavailable"
end

local function countConnected()
    local n = 0
    for _ in pairs(connected) do n = n + 1 end
    return n
end

-- --------------------------------------------------------------------------
-- Snapshot
-- --------------------------------------------------------------------------

-- Everything the panel shows, read fresh from the owning resources. A field
-- is absent (nil) when its resource is not running, so the page draws "--"
-- instead of a wrong number.
local function snapshot(playerId)
    local s = { id = playerId, at = math.floor(now() * 1000) }

    s.name = Open77.players.name(playerId) or ("citizen " .. tostring(playerId))

    local fullName = safe(function() return exports.rp_identity:fullName(playerId) end)
    if type(fullName) == "string" and fullName ~= "" then
        s.rpName = fullName
    end

    local cash = safe(function() return exports.rp_economy:getBalance(playerId) end)
    if type(cash) == "number" then
        s.cash = math.floor(cash)
    end

    local account = safe(function() return exports.rp_bank:getAccount(playerId) end)
    if type(account) == "table" and type(account.balance) == "number" then
        s.account = math.floor(account.balance)
    end

    local job = safe(function() return exports.rp_jobs:getJob(playerId) end)
    if type(job) == "string" and job ~= "" then
        local grade = safe(function() return exports.rp_jobs:getGrade(playerId) end)
        local onDuty = safe(function() return exports.rp_jobs:onDuty(playerId) end)
        s.job = {
            name = job,
            label = Config.jobLabels[job] or job:upper(),
            grade = type(grade) == "table" and tonumber(grade.level) or nil,
            gradeLabel = type(grade) == "table" and grade.label or nil,
            onDuty = onDuty == true,
        }
    end

    local needs = safe(function() return exports.rp_needs:get(playerId) end)
    if type(needs) == "table" then
        s.needs = {
            hunger = tonumber(needs.hunger),
            thirst = tonumber(needs.thirst),
            fatigue = tonumber(needs.fatigue),
        }
    end

    local zone = safe(function() return exports.rp_zones:zoneOf(playerId) end)
    if type(zone) == "table" then
        s.zone = { name = zone.name, label = zone.label or zone.name, kind = zone.kind }
    end

    return s
end

-- --------------------------------------------------------------------------
-- Throttled push
-- --------------------------------------------------------------------------

local function send(playerId)
    local t = throttle[playerId]
    if t then
        t.lastAt = now()
        t.pending = false
    end
    if not connected[playerId] then return end
    local ok, reason = TriggerClientEvent("rp_hud:state", playerId, snapshot(playerId))
    if ok == false then
        log("push to player %d refused: %s", playerId, tostring(reason))
    end
end

-- Schedules a snapshot for one player. Immediate when the last one is older
-- than the window; otherwise one flush is armed at the end of the window and
-- every further request until then rides on it.
local function push(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId <= 0 or not connected[playerId] then return end

    local t = throttle[playerId]
    if not t then
        t = { lastAt = nil, pending = false }
        throttle[playerId] = t
    end
    if t.pending then return end

    local elapsedMs = t.lastAt and ((now() - t.lastAt) * 1000) or math.huge
    if elapsedMs >= Config.minPushIntervalMs then
        send(playerId)
        return
    end

    t.pending = true
    SetTimeout(math.max(1, math.ceil(Config.minPushIntervalMs - elapsedMs)), function()
        send(playerId)
    end)
end

local function pushEveryone()
    for playerId in pairs(connected) do
        push(playerId)
    end
end

-- --------------------------------------------------------------------------
-- Consumed events (host-wide bus). Every one of them names the player as its
-- first argument; rp_bank:changed passes nil for an offline recipient or a
-- society, and those have no panel to refresh.
-- --------------------------------------------------------------------------

AddEventHandler("rp_economy:changed", function(playerId) push(playerId) end)
AddEventHandler("rp_bank:changed", function(playerId)
    if playerId ~= nil then push(playerId) end
end)
AddEventHandler("rp_jobs:changed", function(playerId) push(playerId) end)
AddEventHandler("rp_jobs:duty", function(playerId) push(playerId) end)
AddEventHandler("rp_needs:changed", function(playerId) push(playerId) end)
AddEventHandler("rp_zones:entered", function(playerId) push(playerId) end)
AddEventHandler("rp_zones:left", function(playerId) push(playerId) end)
AddEventHandler("rp_identity:changed", function(playerId) push(playerId) end)

-- --------------------------------------------------------------------------
-- Player lifecycle
-- --------------------------------------------------------------------------

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    connected[playerId] = true
    push(playerId)
    -- The other resources load their rows on the same event, asynchronously:
    -- a second snapshot a few seconds later catches what the first one missed.
    if Config.joinRepushMs and Config.joinRepushMs > 0 then
        SetTimeout(Config.joinRepushMs, function() push(playerId) end)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    connected[playerId] = nil
    throttle[playerId] = nil
end)

-- The client asks for a snapshot when its page has loaded (and on
-- /interface refresh). `source` is the authenticated sender; a bus event of
-- the same name would arrive without one and is ignored.
RegisterNetEvent("rp_hud:request", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    connected[playerId] = true
    push(playerId)
end)

-- --------------------------------------------------------------------------
-- Resource lifecycle
-- --------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name == RESOURCE then
        for _, playerId in ipairs(Open77.players.all()) do
            connected[playerId] = true
        end
        log("started: %d player(s) online, one snapshot per %d ms per player, keepalive every %d ms",
            countConnected(), Config.minPushIntervalMs, Config.refreshMs or 0)
        pushEveryone()
        return
    end
    if depSet[name] then
        -- The resource came back with an empty cache; let it reload, then refresh everyone.
        SetTimeout(Config.dependencyRepushMs or 4000, function()
            log("%s restarted, refreshing %d panel(s)", name, countConnected())
            pushEveryone()
        end)
    end
end)

-- Keepalive: a slow periodic snapshot so a value that changed without an
-- event (needs decay between rp_needs ticks, a dependency that was down)
-- reaches the panel within refreshMs.
if Config.refreshMs and Config.refreshMs > 0 then
    CreateThread(function()
        while true do
            Wait(Config.refreshMs)
            pushEveryone()
        end
    end)
end
