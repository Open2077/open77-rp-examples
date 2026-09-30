-- =============================================================================
-- open77_prediction -- client
-- =============================================================================
--
-- Two jobs, both cheap:
--
--   1. Hand the server's policy (global state bag `open77.prediction`) to the
--      native prediction families through `Open77.prediction.setPolicy`: door,
--      blast, car-against-car and car-against-player are started natively and
--      gated there, at the moment a prediction would start. Melee, Ground Slam
--      and quickhack predictions are started by open77_cyberware, which reads
--      the same bag key itself -- so its switches also work on a client built
--      before the native gate existed.
--   2. Once per telemetry interval, send the server the NON-ZERO changes of
--      every family's counters (predicted, adopted, refuted, skipped). One
--      small net event a minute per client; nothing when nothing happened.
--
-- The host releases this resource's native policy when it stops, so a later
-- server without it starts from the compiled defaults.
-- =============================================================================

local P = PredictionPolicy
local native = type(Open77.prediction) == "table" and type(Open77.prediction.setPolicy) == "function"
    and type(Open77.prediction.stats) == "function"
local current = P.normalize(nil)

local function read()
    local state = Open77.state
    local bag = type(state) == "table" and state.global or nil
    if type(bag) ~= "table" then return nil end
    local ok, value = pcall(bag.get, bag, P.KEY)
    return ok and value or nil
end

local refusal = nil
local function apply()
    current = P.normalize(read())
    if not native then return end
    local ok, reason = Open77.prediction.setPolicy({ families = current.families, maxPingMs = current.maxPingMs })
    if not ok and reason ~= refusal then
        print(("[open77_prediction] native policy refused: %s"):format(tostring(reason)))
    end
    refusal = not ok and reason or nil
end

-- Natives refuse a call from a resource that is still preparing (top-level
-- code), so the first apply waits for this resource's own start.
AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then apply() end
end)
if type(Open77.state) == "table" and type(Open77.state.onChange) == "function" and Open77.state.global then
    Open77.state.onChange(Open77.state.global, P.KEY, function() apply() end)
end

-- ---------------------------------------------------------------------------
-- Telemetry
-- ---------------------------------------------------------------------------

local function slot(out, name)
    local counts = out[name]
    if not counts then
        counts = { predicted = 0, adopted = 0, refuted = 0, skippedDisabled = 0, skippedLatency = 0 }
        out[name] = counts
    end
    return counts
end

local function number(value)
    value = tonumber(value)
    return value and value == value and value >= 0 and value < math.huge and value or 0
end

-- open77_cyberware's own counters: the three action families' skips (its
-- policy gate), and on a client without the native gate their outcomes too.
local function cyberwareStats()
    local exportsApi = Open77.exports
    if type(exportsApi) ~= "table" or type(exportsApi.callSync) ~= "function" then return nil end
    local ok, value = pcall(exportsApi.callSync, "open77_cyberware", "motionPredictionStats")
    return ok and type(value) == "table" and value or nil
end

-- Cumulative counters of this game process, by family.
local function collect()
    local out, ping = {}, nil
    if native then
        local stats = Open77.prediction.stats()
        if type(stats) == "table" then
            ping = tonumber(stats.ping)
            for name, counts in pairs(type(stats.families) == "table" and stats.families or {}) do
                if P.KNOWN[name] and type(counts) == "table" then
                    local s = slot(out, name)
                    for _, field in ipairs(P.FIELDS) do s[field] = s[field] + number(counts[field]) end
                end
            end
        end
    end
    local cyberware = cyberwareStats()
    if cyberware then
        if not native and type(cyberware.native) == "string" and type(json) == "table" then
            local ok, decoded = pcall(json.decode, cyberware.native)
            if ok and type(decoded) == "table" then
                for _, name in ipairs({ "melee", "slam", "hack" }) do
                    local counts = decoded[name]
                    if type(counts) == "table" then
                        local s = slot(out, name)
                        s.predicted = s.predicted + number(counts.predicted)
                        s.adopted = s.adopted + number(counts.adopted)
                        s.refuted = s.refuted + number(counts.refuted)
                    end
                end
            end
        end
        if type(cyberware.skipped) == "table" then
            for name, counts in pairs(cyberware.skipped) do
                if P.KNOWN[name] and type(counts) == "table" then
                    local s = slot(out, name)
                    s.skippedDisabled = s.skippedDisabled + number(counts.disabled)
                    s.skippedLatency = s.skippedLatency + number(counts.latency)
                end
            end
        end
    end
    if ping == nil and type(Open77.network) == "table" and type(Open77.network.status) == "function" then
        local status = Open77.network.status()
        ping = type(status) == "table" and tonumber(status.ping) or nil
    end
    return out, ping
end

-- This client's cumulative counters by family, and its round trip: what the
-- next report is computed from (for a debug panel or a test).
exports("counters", function()
    local counters, ping = collect()
    return { families = counters, ping = ping, policy = current }
end)

CreateThread(function()
    -- Counters are process-wide: whatever happened before this session is not
    -- this server's to hear about.
    local baseline = collect()
    while true do
        local interval = current.telemetrySeconds
        Wait((interval > 0 and interval or P.DEFAULT_TELEMETRY_SECONDS) * 1000)
        local counters, ping = collect()
        local delta, any = P.delta(counters, baseline)
        baseline = counters
        if any and current.telemetrySeconds > 0 then
            ping = ping and ping > 0 and math.tointeger(math.floor(ping)) or nil
            TriggerServerEvent("open77_prediction:report", { v = P.VERSION, ping = ping, families = delta })
        end
    end
end)
