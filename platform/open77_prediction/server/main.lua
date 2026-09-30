-- =============================================================================
-- open77_prediction -- server
-- =============================================================================
--
-- Owns the prediction policy (review items I6/I9) and its telemetry sink.
--
--   operator   seven family switches, the latency ceiling and the telemetry
--              interval are tunables: Warden, `tunable.set open77_prediction
--              <key> <value>`, or the `prediction` command below. Persisted.
--   gamemode   `exports.open77_prediction:restrict{...}` can only turn families
--              off or lower the ceiling, and only while it runs.
--   clients    read the effective policy from the global state bag
--              (`open77.prediction`): late joiners and reconnects included,
--              no broadcast of our own, and a flip reaches every client in
--              the same tick.
--   telemetry  each client sends its non-zero counter deltas once per
--              interval; one aggregated line per window is logged, plus a
--              bounded list of clients whose refutation rate is high.
-- =============================================================================

local P = PredictionPolicy
local RESOURCE = GetCurrentResourceName()

local FAMILY_TEXT = {
    melee = { "Melee knockdown",
        "A melee hit knocks the victim down on the attacker's screen before the server's verdict." },
    slam = { "Ground Slam knockdown",
        "A Ground Slam knocks nearby players down on the attacker's screen before the server's verdict." },
    hack = { "Quickhack knockdown",
        "A knockdown quickhack drops its target on the hacker's screen before the server's verdict." },
    door = { "Door opening",
        "A network door starts opening as soon as it is used, before the server accepts the request." },
    blast = { "Blast reaction",
        "Cars and players another client simulates react to the shooter's own blast before its relay returns." },
    carContact = { "Car against car",
        "A remote car struck by the local driver starts moving at once instead of ~250 ms later." },
    playerContact = { "Car against player",
        "A player hit by the local driver starts falling at once, before the victim's fall cue returns." },
}

local DECLARATION = {}
for index, name in ipairs(P.FAMILIES) do
    DECLARATION[name] = {
        value = true, type = "boolean", apply = "live", group = "Prediction", order = index,
        label = FAMILY_TEXT[name][1],
        description = FAMILY_TEXT[name][2] .. " Off: this family never predicts; the server's reaction is unchanged.",
    }
end
DECLARATION.maxPingMs = {
    value = P.DEFAULT_MAX_PING_MS, type = "integer", min = 0, max = P.MAX_PING_CEILING_MS, step = 10, unit = "ms",
    apply = "live", group = "Prediction", order = 20, label = "Latency ceiling",
    description = "Above this round trip a client starts no new prediction (one already playing finishes). "
        .. "A late verdict makes a refuted prediction far more visible. 0 removes the ceiling.",
}
DECLARATION.telemetrySeconds = {
    value = P.DEFAULT_TELEMETRY_SECONDS, type = "integer", min = 0, max = P.MAX_TELEMETRY_SECONDS, step = 5,
    unit = "s", apply = "live", group = "Prediction", order = 21, label = "Telemetry interval",
    description = "How often each client reports its prediction counters (only non-zero changes). "
        .. "0 turns reports off; below 15 s counts as 15 s.",
}

-- `declare` raises on a rejected declaration; a host without tunables is a
-- supported state and degrades to the declared defaults.
local Tune = nil
if type(Open77) == "table" and type(Open77.tunables) == "table" and type(Open77.tunables.declare) == "function" then
    local ok, proxy = pcall(Open77.tunables.declare, DECLARATION)
    if ok then Tune = proxy else print(("tunables unavailable, using defaults: %s"):format(tostring(proxy))) end
end

-- Read at the point of use: the proxy is a call behind a metatable.
local function tunable(key)
    if Tune ~= nil then
        local ok, value = pcall(function() return Tune[key] end)
        if ok and value ~= nil then return value end
    end
    return DECLARATION[key].value
end

local function integral(value)
    return type(value) == "number" and value == value and value % 1 == 0 and value > -math.huge and value < math.huge
end

-- ---------------------------------------------------------------------------
-- Gamemode restrictions: resource name -> { off = { family = true }, maxPingMs = n|nil }
-- ---------------------------------------------------------------------------
local restrictions, restrictionCount = {}, 0
local MAX_RESTRICTIONS = 32

local function effective()
    local families = {}
    for _, name in ipairs(P.FAMILIES) do families[name] = tunable(name) ~= false end
    local ceiling = tunable("maxPingMs")
    for _, restriction in pairs(restrictions) do
        for name in pairs(restriction.off) do families[name] = false end
        if restriction.maxPingMs then ceiling = P.tighterCeiling(integral(ceiling) and ceiling or 0, restriction.maxPingMs) end
    end
    return P.normalize({ families = families, maxPingMs = ceiling, telemetrySeconds = tunable("telemetrySeconds") })
end

local function describe(policy)
    local off = {}
    for _, name in ipairs(P.FAMILIES) do if not policy.families[name] then off[#off + 1] = name end end
    return ("off=%s maxPingMs=%d telemetry=%ds"):format(#off > 0 and table.concat(off, ",") or "none",
        policy.maxPingMs, policy.telemetrySeconds)
end

local current = effective()
local published, publishFailure = nil, nil

local function globalBag()
    local state = type(Open77) == "table" and Open77.state or nil
    local bag = type(state) == "table" and state.global or nil
    return type(bag) == "table" and bag or nil
end

local function publish()
    current = effective()
    local bag = globalBag()
    if not bag then
        if publishFailure ~= "state_unavailable" then print("state bags unavailable: clients keep their defaults") end
        publishFailure = "state_unavailable"
        return false, "state_unavailable"
    end
    local ok, reason = bag:set(P.KEY, {
        v = P.VERSION, families = current.families, maxPingMs = current.maxPingMs,
        telemetrySeconds = current.telemetrySeconds,
    })
    if not ok then
        if publishFailure ~= reason then print(("policy publish refused: %s"):format(tostring(reason))) end
        publishFailure = reason
        return false, reason
    end
    publishFailure = nil
    local text = describe(current)
    if text ~= published then print("policy " .. text); published = text end
    return true
end

local function copyPolicy(policy)
    local families = {}
    for _, name in ipairs(P.FAMILIES) do families[name] = policy.families[name] end
    return { families = families, maxPingMs = policy.maxPingMs, telemetrySeconds = policy.telemetrySeconds }
end

exports("policy", function() return copyPolicy(current) end)

-- Restrictions survive a reload of this resource (`Open77.state.save` is the
-- note a VM leaves its successor), not a stop or restart: after one of those a
-- gamemode re-applies on `open77_prediction:ready`.
local function saveRestrictions()
    if type(Open77.state) ~= "table" or type(Open77.state.save) ~= "function" then return end
    local carried = {}
    for owner, restriction in pairs(restrictions) do
        local off = {}
        for name in pairs(restriction.off) do off[#off + 1] = name end
        carried[#carried + 1] = { owner = owner, off = off, maxPingMs = restriction.maxPingMs }
    end
    pcall(Open77.state.save, { restrictions = carried })
end

local function setRestriction(owner, restriction)
    if restriction and not restrictions[owner] then restrictionCount = restrictionCount + 1
    elseif not restriction and restrictions[owner] then restrictionCount = restrictionCount - 1
    elseif not restriction then return end
    restrictions[owner] = restriction
    saveRestrictions()
    publish()
end

do
    local ok, carried = false, nil
    if type(Open77.state) == "table" and type(Open77.state.load) == "function" then ok, carried = pcall(Open77.state.load) end
    if ok and type(carried) == "table" and type(carried.restrictions) == "table" then
        for _, entry in ipairs(carried.restrictions) do
            -- Only for a gamemode still running: a stopped one would never withdraw it.
            if type(entry) == "table" and type(entry.owner) == "string" and restrictionCount < MAX_RESTRICTIONS
                and type(GetResourceState) == "function" and GetResourceState(entry.owner) == "running" then
                local off = {}
                for _, name in ipairs(type(entry.off) == "table" and entry.off or {}) do
                    if P.KNOWN[name] then off[name] = true end
                end
                local ceiling = integral(entry.maxPingMs) and entry.maxPingMs >= 1
                    and entry.maxPingMs <= P.MAX_PING_CEILING_MS and math.tointeger(entry.maxPingMs) or nil
                restrictions[entry.owner] = { off = off, maxPingMs = ceiling }
                restrictionCount = restrictionCount + 1
            end
        end
        current = effective()
    end
end

--- A gamemode's restriction, replacing its previous one. It can only turn a
--- family off or lower the ceiling (1..5000 ms); the operator's switches and
--- ceiling always still apply. nil withdraws it, as does the caller's stop.
exports("restrict", function(spec)
    local owner = GetInvokingResource and GetInvokingResource() or nil
    if type(owner) ~= "string" or owner == "" then return false, "unknown_caller" end
    if spec == nil then
        setRestriction(owner, nil)
        return true
    end
    if type(spec) ~= "table" then return false, "invalid_restriction" end
    local off = {}
    if spec.families ~= nil then
        if type(spec.families) ~= "table" then return false, "invalid_prediction_family" end
        for name, enabled in pairs(spec.families) do
            if not P.KNOWN[name] or type(enabled) ~= "boolean" then return false, "invalid_prediction_family" end
            if not enabled then off[name] = true end
        end
    end
    local ceiling = nil
    if spec.maxPingMs ~= nil then
        if not integral(spec.maxPingMs) or spec.maxPingMs < 1 or spec.maxPingMs > P.MAX_PING_CEILING_MS then
            return false, "invalid_ping_ceiling"
        end
        ceiling = math.tointeger(spec.maxPingMs)
    end
    if not restrictions[owner] and restrictionCount >= MAX_RESTRICTIONS then return false, "restriction_limit" end
    setRestriction(owner, { off = off, maxPingMs = ceiling })
    return true
end)

exports("clearRestriction", function()
    local owner = GetInvokingResource and GetInvokingResource() or nil
    if type(owner) == "string" then setRestriction(owner, nil) end
    return true
end)

AddEventHandler("onTunableChanged", function() publish() end)

AddEventHandler("onResourceStop", function(name, reason)
    if name == RESOURCE then
        -- Clients fall back to their compiled defaults, not a stale policy. A
        -- reload prepares the successor VM before this one stops, and it has
        -- already published: clearing the key then would erase its policy.
        if reason ~= "reload" then
            local bag = globalBag()
            if bag then bag:set(P.KEY, nil) end
        end
        return
    end
    setRestriction(name, nil)
end)

-- ---------------------------------------------------------------------------
-- Telemetry
-- ---------------------------------------------------------------------------
local MAX_CLIENTS_PER_WINDOW = 4096
-- A client is named when a family it predicted had at least this many
-- verdicts in the window and at least this share of them were refutations.
local OUTLIER_MIN_VERDICTS, OUTLIER_RATIO, OUTLIER_LINES = 5, 0.5, 5

local function newWindow()
    return { started = Open77.time.monotonic(), reports = 0, dropped = 0, clients = {}, clientCount = 0, totals = {} }
end
local window = newWindow()
local totals, since = {}, Open77.time.monotonic()
local cumulative = { reports = 0, dropped = 0, reasons = {} }
local lastWindow = nil
local lastReport = {}

local function add(into, family, counts)
    local slot = into[family]
    if not slot then slot = {}; into[family] = slot end
    for _, field in ipairs(P.FIELDS) do
        if counts[field] then slot[field] = (slot[field] or 0) + counts[field] end
    end
end

local function drop(reason)
    window.dropped = window.dropped + 1
    cumulative.dropped = cumulative.dropped + 1
    -- A handful of fixed reasons: a bounded table.
    cumulative.reasons[reason] = (cumulative.reasons[reason] or 0) + 1
end

RegisterNetEvent("open77_prediction:report", function(report)
    local player = tonumber(source)
    if not player or player < 1 or player % 1 ~= 0 then return end
    local interval = current.telemetrySeconds
    if interval == 0 then return end
    local now = Open77.time.monotonic()
    -- One report per interval; half of it is tolerated (a restart, scheduler
    -- jitter), anything faster is refused before it is even parsed.
    local last = lastReport[player]
    if last and now - last < interval * 0.5 then return drop("rate_limited") end
    local clean, invalid = P.validateReport(report)
    if not clean then return drop(invalid or "malformed") end
    local client = window.clients[player]
    if not client then
        if window.clientCount >= MAX_CLIENTS_PER_WINDOW then return drop("client_limit") end
        client = { families = {} }
        window.clients[player] = client
        window.clientCount = window.clientCount + 1
    end
    lastReport[player] = now
    window.reports = window.reports + 1
    cumulative.reports = cumulative.reports + 1
    client.ping = clean.ping or client.ping
    for family, counts in pairs(clean.families) do
        add(window.totals, family, counts)
        add(client.families, family, counts)
        add(totals, family, counts)
    end
end)

AddEventHandler("playerDropped", function()
    local player = tonumber(source)
    if player then lastReport[player] = nil end
end)

-- `refuted` over verdicts (adopted + refuted): a prediction cut short by a
-- despawn or a session change has neither and does not count.
local function refutationRate(counts)
    local verdicts = (counts.adopted or 0) + (counts.refuted or 0)
    if verdicts == 0 then return nil, 0 end
    return (counts.refuted or 0) / verdicts, verdicts
end

local function formatFamily(name, counts)
    local rate = refutationRate(counts)
    return ("%s p=%d a=%d r=%d off=%d lag=%d%s"):format(name, counts.predicted or 0, counts.adopted or 0,
        counts.refuted or 0, counts.skippedDisabled or 0, counts.skippedLatency or 0,
        rate and (" rr=%d%%"):format(math.floor(rate * 100 + 0.5)) or "")
end

local function formatTotals(values)
    local parts = {}
    for _, name in ipairs(P.FAMILIES) do
        if values[name] then parts[#parts + 1] = formatFamily(name, values[name]) end
    end
    return #parts > 0 and table.concat(parts, " | ") or "none"
end

local function flush()
    local w = window
    window = newWindow()
    if w.reports == 0 and w.dropped == 0 then return end
    local seconds = math.floor(Open77.time.monotonic() - w.started + 0.5)
    print(("telemetry %ds clients=%d reports=%d dropped=%d | %s"):format(seconds, w.clientCount, w.reports, w.dropped,
        formatTotals(w.totals)))
    local players = {}
    for player in pairs(w.clients) do players[#players + 1] = player end
    table.sort(players)
    local outliers = 0
    for _, player in ipairs(players) do
        local client = w.clients[player]
        for _, name in ipairs(P.FAMILIES) do
            local counts = client.families[name]
            local rate, verdicts = nil, 0
            if counts then rate, verdicts = refutationRate(counts) end
            if rate and verdicts >= OUTLIER_MIN_VERDICTS and rate >= OUTLIER_RATIO then
                outliers = outliers + 1
                if outliers <= OUTLIER_LINES then
                    print(("high refutation player=%d ping=%s %s"):format(player,
                        client.ping and (client.ping .. "ms") or "?", formatFamily(name, counts)))
                end
            end
        end
    end
    if outliers > OUTLIER_LINES then print(("... %d more high-refutation entries this window"):format(outliers - OUTLIER_LINES)) end
    lastWindow = { seconds = seconds, clients = w.clientCount, reports = w.reports, dropped = w.dropped,
        outliers = outliers, totals = w.totals }
end

exports("telemetry", function()
    return {
        since = math.floor(Open77.time.monotonic() - since + 0.5), reports = cumulative.reports,
        dropped = cumulative.dropped, dropReasons = cumulative.reasons, totals = totals, lastWindow = lastWindow,
    }
end)

CreateThread(function()
    -- Publish once the VM runs (a refusal is logged and retried below), then
    -- tell gamemodes: after a stop or restart of this resource their
    -- restrictions are gone and `open77_prediction:ready` is the cue to re-apply.
    publish()
    if type(TriggerEvent) == "function" then TriggerEvent("open77_prediction:ready") end
    while true do
        local interval = current.telemetrySeconds
        Wait(math.max(P.MIN_TELEMETRY_SECONDS, interval > 0 and interval or P.DEFAULT_TELEMETRY_SECONDS) * 1000)
        -- A refused publish (bag caps, a host that was not ready) is retried here.
        if publishFailure then publish() end
        flush()
    end
end)

-- ---------------------------------------------------------------------------
-- Operator command. Restricted: ACL `command.prediction`.
-- ---------------------------------------------------------------------------
local USAGE = "usage: prediction [status] | on <family> | off <family> | ping <ms> | telemetry <seconds>; families: "
    .. table.concat(P.FAMILIES, ", ")

local function setTunable(key, value)
    if not (Tune and type(Open77.tunables.set) == "function") then print("tunables unavailable") return end
    local ok, message, pending = Open77.tunables.set(key, value)
    if ok then
        print(("%s = %s%s"):format(key, tostring(value), pending and " (pending)" or ""))
        -- The host announces the write with `onTunableChanged` a tick or two
        -- later; the operator who typed the command gets it now.
        publish()
    else
        print(("%s refused: %s"):format(key, tostring(message)))
    end
end

local function status()
    print("policy " .. describe(current))
    local owners = {}
    for owner, restriction in pairs(restrictions) do
        local off = {}
        for _, name in ipairs(P.FAMILIES) do if restriction.off[name] then off[#off + 1] = name end end
        owners[#owners + 1] = ("%s(off=%s%s)"):format(owner, #off > 0 and table.concat(off, ",") or "none",
            restriction.maxPingMs and (" maxPingMs=" .. restriction.maxPingMs) or "")
    end
    table.sort(owners)
    print("restrictions " .. (#owners > 0 and table.concat(owners, " ") or "none"))
    print(("totals %ds reports=%d dropped=%d | %s"):format(math.floor(Open77.time.monotonic() - since + 0.5),
        cumulative.reports, cumulative.dropped, formatTotals(totals)))
    if lastWindow then
        print(("last window %ds clients=%d reports=%d outliers=%d | %s"):format(lastWindow.seconds, lastWindow.clients,
            lastWindow.reports, lastWindow.outliers, formatTotals(lastWindow.totals)))
    end
end

RegisterCommand("prediction", function(_, args)
    local verb = args and args[1] or "status"
    if verb == "status" then return status() end
    if verb == "on" or verb == "off" then
        local name = args[2]
        if not P.KNOWN[name] then print(USAGE) return end
        return setTunable(name, verb == "on")
    end
    if verb == "ping" or verb == "telemetry" then
        local value = math.tointeger(tonumber(args[2]))
        if value == nil then print(USAGE) return end
        return setTunable(verb == "ping" and "maxPingMs" or "telemetrySeconds", value)
    end
    print(USAGE)
end, true)
