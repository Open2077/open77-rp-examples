-- rp_zones: named zones with entry announcements, server-authoritative membership,
-- safe-zone damage suppression, and exports/events for every job resource.
--
-- Detection: a server tick every Config.tickMs reads Open77.players.positions() (one call for the
-- whole roster) and tests every prepared zone with Open77.zones.contains -- the shared geometry
-- module both runtimes embed (planar distance for cylinders, crossing-number test for polygons).
-- The SERVER is the source of truth for zoneOf: the client never reports membership.
--
-- No SQL table: zone membership is transient by nature (recomputed every tick from live
-- positions), so there is nothing durable to persist.

local RESOURCE = GetCurrentResourceName()

local prepared = {}   -- name -> { zone, def (normalized), rank (bounds radius), centre {x,y,z} }
local order = {}      -- zone names, smallest bounds radius first (zoneOf picks the first match)
local inside = {}     -- playerId (number) -> { [zoneName] = true }
local safeCount = {}  -- playerId (number) -> number of "safe" zones the player stands in
local arbiter         -- the damage arbiter handle, for offDamage
local tickStarted = false

local enterOptions = {}
local exitOptions = { grace = Config.hysteresis or 0 }

local function log(...)
    Open77.log.info(...)
end

-- ---------------------------------------------------------------------------------------------
-- Zone preparation
-- ---------------------------------------------------------------------------------------------

local function prepareZones()
    prepared, order = {}, {}
    local seen = {}
    for index, zone in ipairs(Config.zones or {}) do
        local name = zone.name
        if type(name) ~= "string" or not name:match("^[a-z0-9_]+$") then
            log(("zone #%d skipped: invalid name %s"):format(index, tostring(name)))
        elseif seen[name] then
            log(("zone %s skipped: duplicate name"):format(name))
        elseif not Config.kinds[zone.kind] then
            log(("zone %s skipped: unknown kind %s"):format(name, tostring(zone.kind)))
        else
            local raw, adaptError = RpZonesShared.definition(zone)
            local def, reason
            if raw then def, reason = Open77.zones.normalize(raw) end
            if not def then
                log(("zone %s skipped: %s"):format(name, tostring(reason or adaptError)))
            else
                local bounds = Open77.zones.bounds(def)
                local centre = zone.centre or (bounds and { x = bounds.x, y = bounds.y, z = bounds.z or 0 }) or nil
                prepared[name] = {
                    zone = zone,
                    def = def,
                    rank = (bounds and bounds.radius) or math.huge,
                    centre = centre,
                }
                seen[name] = true
                order[#order + 1] = name
            end
        end
    end
    table.sort(order, function(a, b)
        local ra, rb = prepared[a].rank, prepared[b].rank
        if ra == rb then return a < b end
        return ra < rb
    end)
    log(("%d zone(s) prepared: %s"):format(#order, table.concat(order, ", ")))
end

local function summary(name)
    local entry = prepared[name]
    if not entry then return nil end
    local zone = entry.zone
    local flags = {}
    for k, v in pairs(zone.flags or {}) do flags[k] = v end
    return { name = name, label = zone.label or name, kind = zone.kind, flags = flags }
end

-- ---------------------------------------------------------------------------------------------
-- Announcements
-- ---------------------------------------------------------------------------------------------

local function notify(playerId, definition)
    local id, reason = Open77.notifications.send(playerId, definition)
    if not id then
        log(("notification to %s refused: %s"):format(tostring(playerId), tostring(reason)))
    end
end

local function chat(playerId, text, color)
    local ok, reason = Open77.chat.send(playerId, { author = "ZONE", text = text, color = color or { 0, 229, 255 } })
    if not ok then
        log(("chat to %s refused: %s"):format(tostring(playerId), tostring(reason)))
    end
end

local function raise(event, playerId, name, kind)
    local ok, reason = TriggerEvent(event, playerId, name, kind)
    if not ok then
        log(("%s not published for %s/%s: %s"):format(event, tostring(playerId), name, tostring(reason)))
    end
end

local function onEnter(playerId, name)
    local entry = prepared[name]
    local zone = entry.zone
    local kind = RpZonesShared.kindOf(zone)

    if zone.kind == "safe" then
        safeCount[playerId] = (safeCount[playerId] or 0) + 1
    end

    notify(playerId, {
        id = "rp_zones:" .. name,
        replace = true,
        type = kind.type,
        title = zone.label or kind.title,
        message = kind.flavour ~= "" and kind.flavour or kind.title,
        icon = kind.icon,
        position = Config.notify.position,
        durationMs = Config.notify.durationMs,
    })
    if kind.chat then
        chat(playerId, kind.chat, { 255, 120, 0 })
    end

    raise("rp_zones:entered", playerId, name, zone.kind)
end

local function onLeave(playerId, name, silent)
    local entry = prepared[name]
    if not entry then return end
    local zone = entry.zone
    local kind = RpZonesShared.kindOf(zone)

    if zone.kind == "safe" then
        local count = (safeCount[playerId] or 1) - 1
        safeCount[playerId] = count > 0 and count or nil
        if not silent then
            notify(playerId, {
                id = "rp_zones:" .. name,
                replace = true,
                type = "warning",
                title = "Leaving " .. (zone.label or kind.title),
                message = kind.leave or "You're fair game again, choom.",
                icon = kind.icon,
                position = Config.notify.position,
                durationMs = Config.notify.leaveDurationMs,
            })
        end
    end

    raise("rp_zones:left", playerId, name, zone.kind)
end

-- ---------------------------------------------------------------------------------------------
-- Detection tick
-- ---------------------------------------------------------------------------------------------

local function evaluate(playerId, position)
    local was = inside[playerId] or {}
    local now = {}
    for _, name in ipairs(order) do
        local entry = prepared[name]
        -- Exit test carries the hysteresis grace; the enter test does not.
        local options = was[name] and exitOptions or enterOptions
        local hit = Open77.zones.contains(entry.def, position, options)
        if hit then now[name] = true end
    end
    inside[playerId] = now
    for name in pairs(now) do
        if not was[name] then onEnter(playerId, name) end
    end
    for name in pairs(was) do
        if not now[name] then onLeave(playerId, name) end
    end
end

local function tick()
    local positions = Open77.players.positions()
    if type(positions) ~= "table" then return end
    for playerId, position in pairs(positions) do
        local pid = tonumber(playerId)
        if pid and type(position) == "table" then
            evaluate(pid, position)
        end
    end
end

local function startTick()
    if tickStarted then return end
    tickStarted = true
    CreateThread(function()
        while true do
            Wait(Config.tickMs or 500)
            local ok, err = pcall(tick)
            if not ok then log("tick failed: " .. tostring(err)) end
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Safe zones: server-side damage arbiter (Open77.combat.onDamage, permission combat.config).
-- Returning false cancels the hit; the first refusal wins. Kept short: it runs in the damage path.
-- ---------------------------------------------------------------------------------------------

local function installArbiter()
    if arbiter then return end
    arbiter = Open77.combat.onDamage(function(event)
        local safe = Config.safe
        if not safe or not safe.blockDamage then return end
        local victim = tonumber(event.victim)
        if victim and safeCount[victim] then return false end
        if safe.blockDamageFromInside then
            local attacker = tonumber(event.attacker)
            if attacker and attacker ~= victim and safeCount[attacker] then return false end
        end
    end)
    if arbiter then
        log("safe-zone damage arbiter installed")
    else
        log("safe-zone damage arbiter NOT installed (combat.config missing?)")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Exports (synchronous, never yield: they read the in-memory state only)
-- ---------------------------------------------------------------------------------------------

-- zoneOf(playerId) -> { name, label, kind, flags } | nil   (the smallest zone the player is in)
exports("zoneOf", function(playerId)
    local pid = tonumber(playerId)
    if not pid then return nil end
    local set = inside[pid]
    if not set then return nil end
    for _, name in ipairs(order) do
        if set[name] then return summary(name) end
    end
    return nil
end)

-- isIn(playerId, name) -> boolean
exports("isIn", function(playerId, name)
    local pid = tonumber(playerId)
    if not pid or type(name) ~= "string" then return false end
    local set = inside[pid]
    return (set ~= nil and set[name] == true) or false
end)

-- list() -> { { name, label, kind }, ... } in config order
exports("list", function()
    local out = {}
    for _, zone in ipairs(Config.zones or {}) do
        if prepared[zone.name] then
            out[#out + 1] = { name = zone.name, label = zone.label or zone.name, kind = zone.kind }
        end
    end
    return out
end)

-- playersIn(name) -> { playerId, ... } ascending
exports("playersIn", function(name)
    local out = {}
    if type(name) ~= "string" or not prepared[name] then return out end
    for pid, set in pairs(inside) do
        if set[name] then out[#out + 1] = pid end
    end
    table.sort(out)
    return out
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/zones", help = "List every zone and how far its centre is from you" },
    { command = "/zone", help = "Which zone you are standing in" },
}

local function planarDistance(a, b)
    if not a or not b then return nil end
    local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

RegisterCommand("zones", function(source)
    if source == 0 then
        print("zones: run this from the game, not the console")
        return
    end
    local position = Open77.players.position(source)
    local rows = {}
    for _, name in ipairs(order) do
        local entry = prepared[name]
        local distance = position and planarDistance(position, entry.centre) or nil
        rows[#rows + 1] = { name = name, label = entry.zone.label or name, kind = entry.zone.kind, distance = distance }
    end
    table.sort(rows, function(a, b)
        local da, db = a.distance or math.huge, b.distance or math.huge
        if da == db then return a.name < b.name end
        return da < db
    end)
    local set = inside[source] or {}
    chat(source, ("%d zone(s) on this server:"):format(#rows))
    for _, row in ipairs(rows) do
        Wait(0)
        local where = row.distance and ("%.0f m"):format(row.distance) or "unknown"
        local mark = set[row.name] and " [HERE]" or ""
        chat(source, ("  %s - %s (%s) - %s%s"):format(row.name, row.label, row.kind, where, mark), { 190, 190, 190 })
    end
end, false)

RegisterCommand("zone", function(source)
    if source == 0 then
        print("zone: run this from the game, not the console")
        return
    end
    local set = inside[source]
    local current
    local others = {}
    if set then
        for _, name in ipairs(order) do
            if set[name] then
                if not current then current = name else others[#others + 1] = name end
            end
        end
    end
    if not current then
        chat(source, "Open Night City - no zone here, choom.")
        return
    end
    local entry = prepared[current]
    local text = ("You are in %s (%s, %s)"):format(entry.zone.label or current, current, entry.zone.kind)
    if #others > 0 then
        text = text .. (" - also inside: %s"):format(table.concat(others, ", "))
    end
    chat(source, text)
end, false)

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    prepareZones()
    startTick()
    -- The arbiter is a bonus on top of detection: a refusal must never stop the tick.
    local installed, err = pcall(installArbiter)
    if not installed then log("safe-zone damage arbiter failed: " .. tostring(err)) end
    local ok, reason = Open77.chat.addSuggestions(-1, SUGGESTIONS)
    if not ok then log("suggestions not published: " .. tostring(reason)) end
    log("started, tick every " .. tostring(Config.tickMs) .. " ms")
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    if arbiter then
        Open77.combat.offDamage(arbiter)
        arbiter = nil
    end
end)

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source == 0 then return end
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = tonumber(playerId)
    if not pid then return end
    local set = inside[pid]
    inside[pid] = nil
    safeCount[pid] = nil
    if set then
        -- Consumers keep their counts consistent: one "left" per zone the player was in.
        for name in pairs(set) do
            local entry = prepared[name]
            if entry then raise("rp_zones:left", pid, name, entry.zone.kind) end
        end
    end
end)
