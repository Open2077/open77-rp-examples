-- The shape of the prediction policy, shared by the server that publishes it
-- and the clients that apply it (review items I6/I9). Pure data and pure
-- functions: no engine call, so both sides agree on every default and the
-- rules are tested without a game (scripting/tests/prediction_policy_resource_test.lua).
PredictionPolicy = {}
local P = PredictionPolicy

-- Key of the global state bag. `[A-Za-z][A-Za-z0-9_.-]*`, 64 bytes at most.
P.KEY = "open77.prediction"
P.VERSION = 1
-- Fixed spellings: the tunable keys, the bag keys and the telemetry keys.
-- They match network/PredictionPolicy.hpp in the client.
P.FAMILIES = { "melee", "slam", "hack", "door", "blast", "carContact", "playerContact" }
P.KNOWN = {}
for _, name in ipairs(P.FAMILIES) do P.KNOWN[name] = true end
-- The client's compiled default ceiling; 0 removes the ceiling.
P.DEFAULT_MAX_PING_MS = 250
P.MAX_PING_CEILING_MS = 5000
-- Telemetry cadence. 0 turns reports off; anything else is held to [15, 3600].
P.DEFAULT_TELEMETRY_SECONDS = 60
P.MIN_TELEMETRY_SECONDS = 15
P.MAX_TELEMETRY_SECONDS = 3600
-- Report fields, in a fixed order for logs.
P.FIELDS = { "predicted", "adopted", "refuted", "skippedDisabled", "skippedLatency" }
-- One window's count per field and family is capped: no honest client comes
-- near it (a prediction is a hit, a crash or a door), and it bounds what one
-- forged report can add to an aggregate.
P.MAX_COUNT = 100000

local function integral(value)
    return type(value) == "number" and value == value and value % 1 == 0
        and value > -math.huge and value < math.huge
end

--- A fresh, complete policy from a published value; anything missing or
--- malformed falls back to the default for that field alone.
function P.normalize(value)
    local out = { families = {}, maxPingMs = P.DEFAULT_MAX_PING_MS, telemetrySeconds = P.DEFAULT_TELEMETRY_SECONDS }
    for _, name in ipairs(P.FAMILIES) do out.families[name] = true end
    if type(value) ~= "table" then return out end
    if type(value.families) == "table" then
        for _, name in ipairs(P.FAMILIES) do
            if value.families[name] == false then out.families[name] = false end
        end
    end
    local ping = value.maxPingMs
    if integral(ping) and ping >= 0 and ping <= P.MAX_PING_CEILING_MS then out.maxPingMs = math.tointeger(ping) end
    local telemetry = value.telemetrySeconds
    if integral(telemetry) and telemetry >= 0 and telemetry <= P.MAX_TELEMETRY_SECONDS then
        out.telemetrySeconds = telemetry == 0 and 0 or math.max(P.MIN_TELEMETRY_SECONDS, math.tointeger(telemetry))
    end
    return out
end

--- The tighter of two ceilings, where 0 means "none".
function P.tighterCeiling(a, b)
    if a == 0 then return b end
    if b == 0 then return a end
    return math.min(a, b)
end

--- A client report, validated field by field: `{ families = {...}, ping = n|nil }`
--- or nil, reason. Unknown families and fields are ignored; a non-integral,
--- negative or oversized count refuses the whole report.
function P.validateReport(report)
    if type(report) ~= "table" or type(report.families) ~= "table" then return nil, "malformed" end
    local families, any = {}, false
    for name, counts in pairs(report.families) do
        if P.KNOWN[name] then
            if type(counts) ~= "table" then return nil, "malformed" end
            local clean = {}
            for _, field in ipairs(P.FIELDS) do
                local value = counts[field]
                if value ~= nil then
                    if not integral(value) or value < 0 or value > P.MAX_COUNT then return nil, "out_of_range" end
                    if value > 0 then clean[field] = math.tointeger(value); any = true end
                end
            end
            if next(clean) then families[name] = clean end
        end
    end
    if not any then return nil, "empty" end
    local ping = report.ping
    if not (integral(ping) and ping >= 0 and ping <= 60000) then ping = nil end
    return { families = families, ping = ping and math.tointeger(ping) or nil }
end

--- Counter delta since the previous reading. A counter that went backwards
--- was reset (a resource restart): its current value is the delta.
function P.delta(current, previous)
    local out, any = {}, false
    for _, name in ipairs(P.FAMILIES) do
        local now, before = current[name], previous and previous[name]
        if now then
            local counts = {}
            for _, field in ipairs(P.FIELDS) do
                local a, b = now[field] or 0, before and before[field] or 0
                local d = a >= b and a - b or a
                if d > 0 then counts[field] = math.min(d, P.MAX_COUNT); any = true end
            end
            if next(counts) then out[name] = counts end
        end
    end
    return out, any
end
