-- rp_logs - audit trail for the Night City RP stack.
--
-- What it does:
--   * listens (AddEventHandler) to every rp_*:... event the other resources
--     raise, plus the platform lifecycle (join, leave, death, admin acts,
--     resource start/stop), and turns each one into a row;
--   * keeps the newest rows in a ring buffer answered by the synchronous
--     `query` export (never yields);
--   * writes rows to `rp_logs_events` in batches (every 2 s or 10 rows: the bridge caps a
--     statement at 64 positional parameters) with
--     the callback forms of Open77.database, so no export ever touches SQL;
--   * mirrors the sensitive kinds to a Discord webhook, one POST per second.
--
-- The resource declares no dependency on purpose: an audit trail must keep
-- running when any other resource stops. The two cross-resource lookups it
-- makes (rp_identity:fullName for the Discord name, rp_needs:get for the
-- threshold sampler) are wrapped in pcall and are optional.

local cfg = RpLogsConfig
local RESOURCE = GetCurrentResourceName()

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------

local function nowUnix()
    return math.tointeger(math.floor(Open77.time.unix())) or 0
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function truthy(v)
    return v == true or v == "true" or v == 1 or v == "1"
end

local function fmtNum(v)
    local n = tonumber(v)
    if not n then return tostring(v) end
    if n == math.floor(n) then return ("%d"):format(n) end
    return ("%.2f"):format(n)
end

local function signed(v)
    local n = tonumber(v)
    if not n then return tostring(v) end
    if n == math.floor(n) then return ("%+d"):format(n) end
    return ("%+.2f"):format(n)
end

local function fmtDuration(seconds)
    local s = math.floor(tonumber(seconds) or 0)
    if s >= 86400 then return ("%dd"):format(s // 86400) end
    if s >= 3600 then return ("%dh"):format(s // 3600) end
    if s >= 60 then return ("%dmin"):format(s // 60) end
    return ("%ds"):format(s)
end

-- Days since 1970-01-01 -> civil date (Howard Hinnant's algorithm). The
-- sandbox has no os.date, and the log lines want a readable UTC stamp.
local function civilFromDays(z)
    z = z + 719468
    local era = (z >= 0 and z or z - 146096) // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

local function formatUtc(unix)
    unix = math.tointeger(math.floor(tonumber(unix) or 0)) or 0
    local days = unix // 86400
    local secs = unix % 86400
    local y, m, d = civilFromDays(days)
    return ("%04d-%02d-%02d %02d:%02d:%02d"):format(y, m, d, secs // 3600, (secs % 3600) // 60, secs % 60)
end

-- Cut a string to `limit` bytes without leaving half a UTF-8 sequence.
local function cutBytes(s, limit)
    s = tostring(s or "")
    if #s <= limit then return s end
    local cut = limit
    while cut > 1 and s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0 do cut = cut - 1 end
    return s:sub(1, cut - 1) .. "…"
end

-- One-line rendering of any value for a generic event text.
local function brief(v)
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "string" then return cutBytes(v, 80) end
    if t == "number" then return fmtNum(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "table" then
        local ok, encoded = pcall(json.encode, v)
        if ok and type(encoded) == "string" then return cutBytes(encoded, 120) end
        return "{...}"
    end
    return "<" .. t .. ">"
end

-- A copy of the packed varargs that json.encode accepts (no nil holes).
local function plainArgs(args)
    local out = {}
    for i = 1, args.n do
        local v = args[i]
        local t = type(v)
        if v == nil then out[i] = "nil"
        elseif t == "string" or t == "number" or t == "boolean" or t == "table" then out[i] = v
        else out[i] = "<" .. t .. ">" end
    end
    return out
end

local function isWebhookUrl(url)
    return url:match("^https://discord%.com/api/webhooks/%d+/[%w%-_%.]+$") ~= nil
        or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w%-_%.]+$") ~= nil
end

-- Only the webhook id is ever shown; the token never reaches chat or the log.
local function maskWebhook(url)
    local id = url:match("/api/webhooks/(%d+)/")
    return id and ("discord webhook #" .. id) or "discord webhook"
end

------------------------------------------------------------------------
-- Players: names and identifiers, remembered for the leave/ban rows
------------------------------------------------------------------------

local known = {}      -- tostring(playerId) -> { identifier, name }
local knownCount = 0

local function playerInfo(playerId)
    if playerId == nil then return nil, nil, nil end
    local pid = tonumber(playerId)
    if not pid then return nil, nil, nil end
    -- 0 / negative / fractional ids (console actors, defaults) are not players:
    -- Open77.players.identifier(0) throws and would kill the resource VM.
    if pid < 1 or pid ~= math.floor(pid) then return nil, nil, nil end
    local key = tostring(pid)
    local identifier = Open77.players.identifier(pid)
    local name = Open77.players.name(pid)
    local remembered = known[key]
    if identifier or name then
        if not remembered then
            knownCount = knownCount + 1
            if knownCount > 512 then known = {}; knownCount = 1 end
        end
        known[key] = {
            identifier = identifier or (remembered and remembered.identifier),
            name = name or (remembered and remembered.name),
        }
        remembered = known[key]
    end
    if remembered then
        identifier = identifier or remembered.identifier
        name = name or remembered.name
    end
    return pid, identifier, name
end

-- The RP name for a Discord embed: rp_identity when it runs, else the
-- display name. Optional lookup, hence the pcall.
local function rpName(pid, fallback)
    if pid then
        local ok, full = pcall(function() return exports.rp_identity:fullName(pid) end)
        if ok and type(full) == "string" and full ~= "" then return full end
    end
    return fallback
end

------------------------------------------------------------------------
-- Ring buffer: the newest cfg.cacheSize rows, answered by `query`
------------------------------------------------------------------------

local ring = {}
local ringNext, ringCount = 1, 0

local function ringPush(row)
    ring[ringNext] = row
    ringNext = ringNext % cfg.cacheSize + 1
    if ringCount < cfg.cacheSize then ringCount = ringCount + 1 end
end

-- Iterate newest -> oldest; the callback returns false to stop.
local function ringEach(fn)
    local idx = ringNext - 1
    for _ = 1, ringCount do
        if idx < 1 then idx = cfg.cacheSize end
        if fn(ring[idx]) == false then return end
        idx = idx - 1
    end
end

local function ringSnapshotOldestFirst()
    local newestFirst = {}
    ringEach(function(row) newestFirst[#newestFirst + 1] = row end)
    local out = {}
    for i = #newestFirst, 1, -1 do out[#out + 1] = newestFirst[i] end
    return out
end

local function ringRebuild(oldestFirst)
    ring, ringNext, ringCount = {}, 1, 0
    for _, row in ipairs(oldestFirst) do ringPush(row) end
end

------------------------------------------------------------------------
-- Rows, pending batch, counters
------------------------------------------------------------------------

local seq = 0
local pending = {}
local counters = {
    rows = 0, flushed = 0, dropped = 0, failedBatches = 0,
    webhookSent = 0, webhookFailed = 0, webhookDropped = 0,
    counted = {}, -- kind -> count (zones, sms)
    zones = {},   -- zone name -> { entered = n, left = n }
}
local warnedPendingFull = false

local dbState = "waiting" -- waiting | ready | unavailable
local dbReason = nil
local flushInFlight = false
local flushStartedAt = 0

local enqueueWebhook -- defined below

local function encodeData(data)
    if data == nil then return nil, nil end
    if type(data) ~= "table" then data = { value = tostring(data) } end
    local ok, encoded = pcall(json.encode, data)
    if not ok or type(encoded) ~= "string" then return nil, nil end
    if #encoded > cfg.maxDataBytes then
        local marker = { truncated = true, bytes = #encoded }
        return json.encode(marker), marker
    end
    return encoded, data
end

local function record(kind, text, opts)
    opts = opts or {}
    local pid, identifier, name = playerInfo(opts.playerId)
    identifier = opts.identifier or identifier
    name = opts.playerName or name
    local encoded, data = encodeData(opts.data)
    seq = seq + 1
    local row = {
        seq = seq,
        id = nil, -- the SQL id, known once the batch is inserted
        at = nowUnix(),
        kind = kind,
        identifier = identifier,
        player_name = name,
        text = cutBytes(text or "", cfg.maxTextBytes),
        data = data,
        json = encoded,
        attempts = 0,
    }
    ringPush(row)
    counters.rows = counters.rows + 1
    if dbState ~= "unavailable" then
        pending[#pending + 1] = row
        if #pending > cfg.pendingMax then
            table.remove(pending, 1)
            counters.dropped = counters.dropped + 1
            if not warnedPendingFull then
                warnedPendingFull = true
                Open77.log.warn(("more than %d rows waiting for the database; the oldest are being dropped"):format(cfg.pendingMax))
            end
        end
    end
    if cfg.sensitiveKinds[kind] then enqueueWebhook(row, pid) end
    return row
end

------------------------------------------------------------------------
-- No-database fallback (Open77.kvp), only when the bridge never comes
------------------------------------------------------------------------

local KVP_FALLBACK = "rp_logs:fallback"
local KVP_COUNTERS = "rp_logs:counters"

local function persistFallback()
    local rows = {}
    ringEach(function(row)
        rows[#rows + 1] = {
            at = row.at, kind = row.kind, identifier = row.identifier,
            player_name = row.player_name, text = row.text, json = row.json,
        }
        if #rows >= cfg.kvpFallbackRows then return false end
    end)
    local encoded = json.encode(rows)
    while encoded and #encoded > cfg.kvpFallbackMaxBytes and #rows > 10 do
        for _ = 1, 10 do rows[#rows] = nil end
        encoded = json.encode(rows)
    end
    if not encoded then return end
    local ok, reason = Open77.kvp.set(KVP_FALLBACK, encoded)
    if not ok then Open77.log.warn("kvp fallback write refused: " .. tostring(reason)) end
end

local function loadFallback()
    local encoded = Open77.kvp.get(KVP_FALLBACK)
    if type(encoded) ~= "string" then return 0 end
    local rows = json.decode(encoded)
    if type(rows) ~= "table" then return 0 end
    local oldestFirst = {}
    for i = #rows, 1, -1 do
        local r = rows[i]
        if type(r) == "table" then
            seq = seq + 1
            oldestFirst[#oldestFirst + 1] = {
                seq = seq, id = nil, at = tonumber(r.at) or 0, kind = tostring(r.kind or "?"),
                identifier = r.identifier, player_name = r.player_name, text = tostring(r.text or ""),
                data = type(r.json) == "string" and json.decode(r.json) or nil, json = r.json, attempts = 0,
            }
        end
    end
    for _, row in ipairs(ringSnapshotOldestFirst()) do oldestFirst[#oldestFirst + 1] = row end
    ringRebuild(oldestFirst)
    return #rows
end

local function persistCounters()
    local ok = pcall(function()
        Open77.kvp.set(KVP_COUNTERS, json.encode({ counted = counters.counted, zones = counters.zones }))
    end)
    if not ok then Open77.log.warn("could not persist counters") end
end

local function loadCounters()
    local encoded = Open77.kvp.get(KVP_COUNTERS)
    if type(encoded) ~= "string" then return end
    local saved = json.decode(encoded)
    if type(saved) ~= "table" then return end
    if type(saved.counted) == "table" then counters.counted = saved.counted end
    if type(saved.zones) == "table" then counters.zones = saved.zones end
end

------------------------------------------------------------------------
-- SQL: schema, batched INSERT with the callback form, listing
------------------------------------------------------------------------

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS rp_logs_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    at BIGINT NOT NULL,
    kind VARCHAR(48) NOT NULL,
    identifier VARCHAR(64) NULL,
    player_name VARCHAR(64) NULL,
    text VARCHAR(512) NOT NULL,
    data JSON NULL,
    PRIMARY KEY (id),
    KEY idx_kind_at (kind, at),
    KEY idx_identifier_at (identifier, at)
)]]

local function buildInsert(batch)
    local values, params = {}, {}
    for _, row in ipairs(batch) do
        -- NULLIF keeps the positional parameter list free of nil holes.
        values[#values + 1] = "(?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''))"
        params[#params + 1] = row.at
        params[#params + 1] = row.kind
        params[#params + 1] = row.identifier or ""
        params[#params + 1] = row.player_name or ""
        params[#params + 1] = row.text
        params[#params + 1] = row.json or ""
    end
    return "INSERT INTO rp_logs_events (at, kind, identifier, player_name, text, data) VALUES "
        .. table.concat(values, ","), params
end

local function takeBatch()
    local n = math.min(#pending, cfg.flushBatchSize)
    local batch, rest = {}, {}
    for i = 1, n do batch[i] = pending[i] end
    for i = n + 1, #pending do rest[#rest + 1] = pending[i] end
    pending = rest
    return batch
end

local function submitBatch(batch, track)
    if #batch == 0 then return end
    local sql, params = buildInsert(batch)
    if track then
        flushInFlight = true
        flushStartedAt = Open77.time.monotonic()
    end
    Open77.database.insert(sql, params, function(result)
        if track then flushInFlight = false end
        if result == nil then
            counters.failedBatches = counters.failedBatches + 1
            local retry, dropped = {}, 0
            for _, row in ipairs(batch) do
                row.attempts = row.attempts + 1
                if row.attempts < cfg.maxBatchAttempts then retry[#retry + 1] = row else dropped = dropped + 1 end
            end
            if dropped > 0 then
                counters.dropped = counters.dropped + dropped
                Open77.log.error(("%d rows dropped after %d failed inserts"):format(dropped, cfg.maxBatchAttempts))
            end
            if #retry > 0 then
                for _, row in ipairs(pending) do retry[#retry + 1] = row end
                pending = retry
                Open77.log.warn(("insert of %d rows failed, %d kept for a retry"):format(#batch, #retry))
            end
            return
        end
        counters.flushed = counters.flushed + #batch
        -- Best effort: a multi-row INSERT answers its first auto-increment id
        -- and the rows of one statement get consecutive ids.
        local firstId = tonumber(result)
        if firstId then
            for i, row in ipairs(batch) do row.id = firstId + i - 1 end
        end
    end)
end

local function flush()
    if #pending == 0 then return end
    if dbState == "unavailable" then
        persistFallback()
        pending = {}
        return
    end
    if dbState ~= "ready" or flushInFlight then return end
    submitBatch(takeBatch(), true)
end

-- Submit everything that waits, without the single-batch throttle (stop path).
local function flushAll()
    if dbState ~= "ready" then
        if dbState == "unavailable" then persistFallback(); pending = {} end
        return
    end
    while #pending > 0 do submitBatch(takeBatch(), false) end
end

-- Wait (from a managed task only) until the pending rows reached SQL.
local function awaitFlush(timeoutMs)
    local deadline = Open77.time.monotonic() + (timeoutMs or 2000) / 1000
    flush()
    while (flushInFlight or #pending > 0) and Open77.time.monotonic() < deadline do
        Wait(50)
        flush()
    end
end

local function loadRecentFromSql()
    local rows = Open77.database.query.await(
        ("SELECT id, at, kind, identifier, player_name, text, data FROM rp_logs_events ORDER BY id DESC LIMIT %d"):format(cfg.cacheSize)
    )
    if type(rows) ~= "table" then return 0 end
    local oldestFirst = {}
    for i = #rows, 1, -1 do
        local r = rows[i]
        seq = seq + 1
        oldestFirst[#oldestFirst + 1] = {
            seq = seq, id = tonumber(r.id), at = tonumber(r.at) or 0, kind = tostring(r.kind or "?"),
            identifier = r.identifier, player_name = r.player_name, text = tostring(r.text or ""),
            data = type(r.data) == "string" and json.decode(r.data) or nil,
            json = type(r.data) == "string" and r.data or nil, attempts = 0,
        }
    end
    -- Rows recorded before the database answered are newer: keep them last.
    for _, row in ipairs(ringSnapshotOldestFirst()) do oldestFirst[#oldestFirst + 1] = row end
    ringRebuild(oldestFirst)
    return #rows
end

local readyOk, readyReason = Open77.database.ready(function()
    local result = Open77.database.update.await(SCHEMA)
    if result == nil then
        Open77.log.warn("CREATE TABLE rp_logs_events answered nothing; inserts may fail")
    end
    dbState = "ready"
    local ok, loaded = pcall(loadRecentFromSql)
    if ok then
        print(("database ready, %d recent rows loaded into the cache, %d rows waiting"):format(loaded, #pending))
    else
        Open77.log.warn("could not preload the cache from SQL: " .. tostring(loaded))
    end
    flush()
end)

if not readyOk then
    dbState = "unavailable"
    dbReason = readyReason
    local restored = loadFallback()
    Open77.log.warn(("database %s: rows stay in memory (last %d) and in the kvp fallback (%d restored); /logs reads the cache"):format(
        tostring(readyReason), cfg.cacheSize, restored))
end

-- Flush thread: every flushIntervalMs, or as soon as a batch is full.
CreateThread(function()
    while true do
        Wait(cfg.flushIntervalMs)
        if flushInFlight and Open77.time.monotonic() - flushStartedAt > 30 then
            flushInFlight = false
            Open77.log.warn("an INSERT never answered in 30 s; resuming the flushes")
        end
        flush()
    end
end)

------------------------------------------------------------------------
-- Discord webhook: URL resolution, queue, 1 POST/s, embeds
------------------------------------------------------------------------

-- The tunable is the durable, operator-owned home of the URL: visible and
-- editable in the Warden panel, persisted by the host in tunables.json.
-- GetConvar(webhookKey) reads server.jsonc "convars" first and falls through
-- to this tunable by exact key, so one read covers both sources.
Open77.tunables.declare({
    [cfg.webhookKey] = {
        value = "",
        type = "string",
        apply = "live",
        label = "Discord webhook URL",
        description = "Receives the sensitive audit kinds (arrests, robberies, admin acts, gang wars, bans). Empty = off. Set here or with /logs webhook <url>.",
        group = "Discord",
    },
})

local webhookQueue = {}
local webhookDisabled = nil   -- configuration refusal token; cleared when the URL changes
local webhookBackoffUntil = 0
local warnedInvalidUrl = false

local function webhookUrl()
    local url = GetConvar(cfg.webhookKey, "")
    if type(url) ~= "string" then return nil end
    url = trim(url)
    if url == "" then return nil end
    if not isWebhookUrl(url) then
        if not warnedInvalidUrl then
            warnedInvalidUrl = true
            Open77.log.warn(cfg.webhookKey .. " is set but is not a https://discord.com/api/webhooks/<id>/<token> URL; webhook off")
        end
        return nil, "invalid_webhook_url"
    end
    return url
end

enqueueWebhook = function(row, pid)
    if not webhookUrl() or webhookDisabled then return end
    if #webhookQueue >= cfg.webhookQueueMax then
        table.remove(webhookQueue, 1)
        counters.webhookDropped = counters.webhookDropped + 1
    end
    webhookQueue[#webhookQueue + 1] = { row = row, name = rpName(pid, row.player_name) }
end

local function postWebhook(entry)
    local url = webhookUrl()
    if not url then return end
    local row = entry.row
    local payload = {
        username = cfg.webhookUsername,
        embeds = { {
            title = row.kind,
            description = cutBytes(row.text, 2000),
            color = cfg.embedColors[row.kind] or cfg.embedColors.default,
            fields = {
                { name = "Choom", value = cutBytes(entry.name or "-", 256), inline = true },
                { name = "Identifier", value = cutBytes(row.identifier or "-", 256), inline = true },
                { name = "When (UTC)", value = formatUtc(row.at), inline = true },
            },
            footer = { text = "rp_logs · Night City audit trail" },
            timestamp = Open77.time.utc(),
        } },
    }
    local accepted, reason = PerformHttpRequest(url, function(status, body, headers, err)
        if status == 0 then
            counters.webhookFailed = counters.webhookFailed + 1
            Open77.log.warn("webhook did not complete: " .. tostring(err))
        elseif status == 429 then
            counters.webhookFailed = counters.webhookFailed + 1
            webhookBackoffUntil = Open77.time.monotonic() + cfg.webhookBackoffSeconds
            table.insert(webhookQueue, 1, entry)
            Open77.log.warn(("Discord rate-limited the webhook; pausing %d s"):format(cfg.webhookBackoffSeconds))
        elseif status >= 400 then
            counters.webhookFailed = counters.webhookFailed + 1
            Open77.log.warn(("webhook answered HTTP %d"):format(status))
        else
            counters.webhookSent = counters.webhookSent + 1
        end
    end, "POST", payload, { ["Content-Type"] = "application/json" })
    if not accepted then
        if reason == "http_unavailable" or reason == "host_not_allowed" or reason == "permission_denied:http.request" then
            webhookDisabled = reason
            Open77.log.error(("webhook disabled: %s (enable http in server.jsonc with allowedHosts [\"discord.com\"])"):format(tostring(reason)))
        elseif reason ~= "too_many_requests" then
            Open77.log.warn("webhook refused: " .. tostring(reason))
        end
    end
end

-- Drain thread: one POST per webhookMinIntervalMs at most.
CreateThread(function()
    while true do
        Wait(cfg.webhookMinIntervalMs)
        if #webhookQueue > 0 and not webhookDisabled and Open77.time.monotonic() >= webhookBackoffUntil then
            postWebhook(table.remove(webhookQueue, 1))
        end
    end
end)

AddEventHandler("onTunableChanged", function(key, value, pendingWrite)
    if key ~= cfg.webhookKey then return end
    webhookDisabled = nil
    warnedInvalidUrl = false
    local url = webhookUrl()
    print(url and ("webhook configured: " .. maskWebhook(url)) or "webhook off")
end)

------------------------------------------------------------------------
-- Event descriptors: one function per subscribed event
--   returns nil (skip) or { playerId=, identifier=, text=, data= }
------------------------------------------------------------------------

local describe = {}

-- Generic capture for an event whose payload is not documented: the first
-- argument that resolves to a live player becomes the row's player.
local function describeGeneric(prefix)
    return function(...)
        local args = table.pack(...)
        local playerId
        local parts = {}
        for i = 1, args.n do
            local v = args[i]
            if playerId == nil and (type(v) == "number" or (type(v) == "string" and tonumber(v))) then
                local pid = tonumber(v)
                if pid and pid >= 1 and pid == math.floor(pid) and Open77.players.identifier(pid) then
                    playerId = pid
                end
            end
            parts[#parts + 1] = brief(v)
        end
        local text = table.concat(parts, " ")
        if prefix then text = prefix .. (text ~= "" and (": " .. text) or "") end
        return { playerId = playerId, text = text, data = { args = plainArgs(args) } }
    end
end

describe["rp_economy:changed"] = function(playerId, newBalance, delta, reason)
    return {
        playerId = playerId,
        text = ("cash %s €$ (%s), now %s €$"):format(signed(delta), tostring(reason or "?"), fmtNum(newBalance)),
        data = { balance = newBalance, delta = delta, reason = reason },
    }
end

describe["rp_bank:changed"] = function(playerId, identifier, newBalance, delta, kind)
    return {
        playerId = playerId,
        identifier = identifier,
        text = ("bank %s €$ (%s), now %s €$"):format(signed(delta), tostring(kind or "?"), fmtNum(newBalance)),
        data = { balance = newBalance, delta = delta, kind = kind },
    }
end

describe["rp_jobs:changed"] = function(playerId, name)
    return {
        playerId = playerId,
        text = name and ("job set to %s"):format(tostring(name)) or "job cleared",
        data = { job = name },
    }
end

describe["rp_jobs:duty"] = function(playerId, name, onDuty)
    local on = truthy(onDuty)
    return {
        playerId = playerId,
        text = ("%s duty %s"):format(tostring(name or "?"), on and "on" or "off"),
        data = { job = name, onDuty = on },
    }
end

describe["rp_inventory:changed"] = function(playerId, itemId, delta)
    return {
        playerId = playerId,
        text = ("inventory %s %s"):format(tostring(itemId), signed(delta)),
        data = { itemId = itemId, delta = delta },
    }
end

describe["rp_inventory:used"] = function(playerId, itemId)
    return { playerId = playerId, text = ("used %s"):format(tostring(itemId)), data = { itemId = itemId } }
end

describe["rp_identity:changed"] = function(playerId)
    local pid = tonumber(playerId)
    local name = rpName(pid, nil)
    return { playerId = playerId, text = "identity updated" .. (name and (": " .. name) or ""), data = { fullName = name } }
end

describe["rp_ncpd:alert"] = function(kind, position, text, byPlayerId)
    return {
        playerId = byPlayerId,
        text = ("NCPD alert [%s] %s"):format(tostring(kind or "?"), tostring(text or "")),
        data = { alertKind = kind, position = position },
    }
end

-- Payload not in the delivered contract: captured generically.
describe["rp_ncpd:arrest"] = describeGeneric("arrest")

describe["rp_trauma:down"] = function(playerId, position)
    return { playerId = playerId, text = "went down, Trauma Team paged", data = { position = position } }
end

describe["rp_trauma:revived"] = describeGeneric("revived")
describe["rp_delamain:ride"] = describeGeneric("Delamain ride")
describe["rp_mecano:bill"] = describeGeneric("mecano bill")
describe["rp_mecano:impounded"] = describeGeneric("impounded")
describe["rp_vigile:contract"] = describeGeneric("security contract")

describe["rp_fixer:gig"] = function(gigId, phase, playerId)
    return {
        playerId = playerId,
        text = ("gig %s %s"):format(tostring(gigId), tostring(phase)),
        data = { gigId = gigId, phase = phase },
    }
end

describe["rp_netrunner:jammed"] = function(jammed)
    local on = truthy(jammed)
    return { text = on and "NET jammed by a netrunner" or "NET jamming ended", data = { jammed = on } }
end

describe["rp_garage:changed"] = function(identifier, plate, action)
    return {
        identifier = identifier,
        text = ("vehicle %s %s"):format(tostring(plate), tostring(action)),
        data = { plate = plate, action = action },
    }
end

describe["rp_garage:stolen"] = function(plate, byPlayerId)
    return { playerId = byPlayerId, text = ("vehicle %s stolen"):format(tostring(plate)), data = { plate = plate } }
end

describe["rp_shops:sale"] = function(shopId, playerId, itemId, count, price)
    return {
        playerId = playerId,
        text = ("bought %s x %s at %s for %s €$"):format(fmtNum(count), tostring(itemId), tostring(shopId), fmtNum(price)),
        data = { shopId = shopId, itemId = itemId, count = count, price = price },
    }
end

describe["rp_shops:robbed"] = function(shopId, byPlayerId, amount)
    return {
        playerId = byPlayerId,
        text = ("robbed shop %s for %s €$"):format(tostring(shopId), fmtNum(amount)),
        data = { shopId = shopId, amount = amount },
    }
end

describe["rp_housing:changed"] = function(identifier, homeId, action)
    return {
        identifier = identifier,
        text = ("home %s %s"):format(tostring(homeId), tostring(action)),
        data = { homeId = homeId, action = action },
    }
end

describe["rp_gangs:changed"] = function(playerId, gang)
    return {
        playerId = playerId,
        text = gang and ("joined gang %s"):format(tostring(gang)) or "left their gang",
        data = { gang = gang },
    }
end

describe["rp_gangs:war"] = function(zone, attacker, defender, phase)
    return {
        text = ("gang war in %s: %s vs %s (%s)"):format(tostring(zone), tostring(attacker), tostring(defender), tostring(phase)),
        data = { zone = zone, attacker = attacker, defender = defender, phase = phase },
    }
end

describe["rp_crime:robbery"] = function(kind, position, byPlayerId)
    return {
        playerId = byPlayerId,
        text = ("robbery: %s"):format(tostring(kind)),
        data = { robberyKind = kind, position = position },
    }
end

describe["rp_admin:action"] = function(adminId, action, targetId, text)
    local _, targetIdentifier, targetName = playerInfo(targetId)
    return {
        playerId = adminId,
        text = ("%s -> %s: %s"):format(tostring(action), targetName or tostring(targetId or "-"), tostring(text or "")),
        data = { action = action, targetId = targetId, targetIdentifier = targetIdentifier, targetName = targetName },
    }
end

-- rp_needs is sampled: a row only when hunger/thirst/fatigue crosses 25 or 0.
local needsLast = {}

local function needsBand(v)
    local t = cfg.needsThresholds
    if v <= (t[2] or 0) then return "empty" end
    if v <= (t[1] or 25) then return "low" end
    return "ok"
end

describe["rp_needs:changed"] = function(playerId, first, thirst, fatigue)
    local pid = tonumber(playerId)
    if not pid then return nil end
    local needs
    if type(first) == "table" then
        needs = first
    elseif type(first) == "number" then
        -- rp_needs raises (playerId, hunger, thirst, fatigue) every tick: no export call needed.
        needs = { hunger = first, thirst = thirst, fatigue = fatigue }
    else
        local ok, got = pcall(function() return exports.rp_needs:get(pid) end)
        if ok and type(got) == "table" then needs = got end
    end
    if type(needs) ~= "table" then return nil end
    local last = needsLast[pid]
    local current, crossings = {}, {}
    for _, key in ipairs({ "hunger", "thirst", "fatigue" }) do
        local v = tonumber(needs[key])
        if v then
            current[key] = v
            if last and last[key] then
                local before, after = needsBand(last[key]), needsBand(v)
                if before ~= after then
                    crossings[#crossings + 1] = ("%s %s -> %s (%s)"):format(key, before, after, fmtNum(v))
                end
            end
        end
    end
    needsLast[pid] = current
    if #crossings == 0 then return nil end
    return { playerId = pid, text = "needs: " .. table.concat(crossings, ", "), data = current }
end

-- Counted-only events (never stored): zones and SMS.
local function count(kind)
    counters.counted[kind] = (counters.counted[kind] or 0) + 1
end

AddEventHandler("rp_zones:entered", function(playerId, name, kind)
    count("rp_zones:entered")
    local z = counters.zones[tostring(name)] or { entered = 0, left = 0 }
    z.entered = z.entered + 1
    counters.zones[tostring(name)] = z
end)

AddEventHandler("rp_zones:left", function(playerId, name, kind)
    count("rp_zones:left")
    local z = counters.zones[tostring(name)] or { entered = 0, left = 0 }
    z.left = z.left + 1
    counters.zones[tostring(name)] = z
end)

AddEventHandler("rp_phone:sms", function()
    -- Count only: the text is never read, never stored.
    count("rp_phone:sms")
end)

-- Register every descriptor.
local function handleEvent(name, fn, ...)
    local d = fn(...)
    if d == nil then return end
    record(name, d.text, { playerId = d.playerId, identifier = d.identifier, data = d.data })
end

for name, fn in pairs(describe) do
    AddEventHandler(name, function(...)
        local ok, err = pcall(handleEvent, name, fn, ...)
        if not ok then Open77.log.warn(("handler for %s failed: %s"):format(name, tostring(err))) end
    end)
end

------------------------------------------------------------------------
-- Platform lifecycle: join, leave, death, admin acts, resources
------------------------------------------------------------------------

AddEventHandler("onPlayerReady", function(playerId, detail)
    local _, _, name = playerInfo(playerId)
    record("player:join", ("%s joined Night City"):format(name or "someone"), {
        playerId = playerId,
        data = { detail = (type(detail) == "table" or type(detail) == "string") and detail or nil },
    })
end)

AddEventHandler("onPlayerDisconnected", function(playerId, reason)
    record("player:leave", ("left (%s)"):format(tostring(reason or "?")), { playerId = playerId, data = { reason = reason } })
    needsLast[tonumber(playerId) or -1] = nil
end)

-- Death. The connect-time `dead` phase (registered/restored/resync) and the
-- admin tp/goto kill (weapon open77_admin:<verb>) are not deaths.
AddEventHandler("onPlayerLifeStateChanged", function(playerId, revision, phase, reason)
    if phase ~= "dead" then return end
    if reason == "registered" or reason == "restored" or reason == "resync_requested" then return end
    -- The host delivers the id as a string; getLifeState only takes an integer and answers nil
    -- otherwise, which would turn every admin tp (weapon open77_admin:tp) into a death row.
    local life = Open77.players.getLifeState(tonumber(playerId))
    local weapon = life and life.weapon
    local cause = life and life.cause
    if type(weapon) == "string" and weapon:find("^open77_admin:") then return end
    local detail = tostring(cause or reason or "?")
    if weapon then detail = detail .. ", " .. tostring(weapon) end
    record("player:death", ("flatlined (%s)"):format(detail), {
        playerId = playerId,
        data = { cause = cause, weapon = weapon, reason = reason, revision = revision, killer = life and (life.killer or life.killerId or life.attacker) or nil },
    })
end)

AddEventHandler("open77:admin:playerBanned", function(playerId, author, durationSeconds)
    local seconds = tonumber(durationSeconds)
    local span = (seconds and seconds > 0) and fmtDuration(seconds) or "permanent"
    record("admin:ban", ("banned by %s (%s)"):format(tostring(author or "?"), span), {
        playerId = playerId, data = { author = author, durationSeconds = seconds },
    })
end)

AddEventHandler("open77:admin:playerKicked", function(playerId, author)
    record("admin:kick", ("kicked by %s"):format(tostring(author or "?")), { playerId = playerId, data = { author = author } })
end)

AddEventHandler("open77:admin:playerWarned", function(playerId, author)
    record("admin:warn", ("warned by %s"):format(tostring(author or "?")), { playerId = playerId, data = { author = author } })
end)

AddEventHandler("open77:admin:announcement", function(text)
    record("admin:announce", tostring(text or ""), nil)
end)

------------------------------------------------------------------------
-- Exports
------------------------------------------------------------------------

local function validKind(kind)
    return type(kind) == "string" and #kind >= 1 and #kind <= 48 and kind:match("^[%w_:%.%-]+$") ~= nil
end

-- log(kind, text, data) -> true | nil, reason
-- A kind without ':' is prefixed by the calling resource ("rp_mdt:lookup").
-- data.playerId (or data.identifier) fills the row's identifier/name columns.
exports("log", function(kind, text, data)
    if not validKind(kind) then return nil, "invalid_kind" end
    if text ~= nil and type(text) ~= "string" then return nil, "invalid_text" end
    if data ~= nil and type(data) ~= "table" then return nil, "invalid_data" end
    local caller = GetInvokingResource()
    if not kind:find(":", 1, true) and caller then kind = caller .. ":" .. kind end
    if #kind > 48 then return nil, "invalid_kind" end
    local opts = { data = data }
    if data then
        opts.playerId = data.playerId
        opts.identifier = type(data.identifier) == "string" and data.identifier or nil
        if caller and data.source == nil then data.source = caller end
    elseif caller then
        opts.data = { source = caller }
    end
    record(kind, text or "", opts)
    return true
end)

-- query({ kind=, identifier=, playerId=, since=, limit= }) -> rows (newest first)
-- Answered from the in-memory ring only, so it never yields. History beyond
-- the cache is the /logs command (SQL, may yield).
exports("query", function(filter)
    filter = type(filter) == "table" and filter or {}
    local kind = type(filter.kind) == "string" and filter.kind or nil
    local identifier = type(filter.identifier) == "string" and filter.identifier or nil
    if not identifier and filter.playerId ~= nil then
        local _, id = playerInfo(filter.playerId)
        identifier = id
        if not identifier then return {} end
    end
    local since = tonumber(filter.since)
    local limit = math.floor(tonumber(filter.limit) or 50)
    if limit < 1 then limit = 1 elseif limit > cfg.cacheSize then limit = cfg.cacheSize end
    local rows = {}
    ringEach(function(row)
        if since and row.at < since then return end
        if kind and row.kind ~= kind and not row.kind:find(kind, 1, true) then return end
        if identifier and row.identifier ~= identifier then return end
        rows[#rows + 1] = {
            id = row.id, seq = row.seq, at = row.at, kind = row.kind,
            identifier = row.identifier, player_name = row.player_name,
            text = row.text, data = row.data,
        }
        if #rows >= limit then return false end
    end)
    return rows
end)

------------------------------------------------------------------------
-- /logs command (restricted: ACL command.logs; the console always may)
------------------------------------------------------------------------

local function reply(source, text)
    if source == 0 then print(text) else Open77.chat.send(source, text) end
end

-- Chat delivers two sends of one tick in reverse order: Wait(0) between lines.
local function replyLines(source, lines)
    for i, line in ipairs(lines) do
        reply(source, line)
        if source ~= 0 and i < #lines then Wait(0) end
    end
end

local function formatRow(row)
    local who = row.player_name or (row.identifier and ("id " .. row.identifier)) or "-"
    local stamp = formatUtc(row.at):sub(12)
    return ("#%s %s %s [%s] %s"):format(row.id and tostring(row.id) or "~", stamp, row.kind, who, row.text)
end

local function sanitizeKind(kind)
    return (tostring(kind or ""):gsub("[^%w_:%.%-]", ""))
end

local function cmdList(source, kind, count)
    local lines = {}
    if dbState == "ready" then
        awaitFlush(2000)
        local rows
        if kind then
            rows = Open77.database.query.await(
                ("SELECT id, at, kind, identifier, player_name, text FROM rp_logs_events WHERE kind LIKE ? ORDER BY id DESC LIMIT %d"):format(count),
                { "%" .. kind .. "%" })
        else
            rows = Open77.database.query.await(
                ("SELECT id, at, kind, identifier, player_name, text FROM rp_logs_events ORDER BY id DESC LIMIT %d"):format(count))
        end
        if type(rows) ~= "table" then
            reply(source, "[LOGS] The database did not answer; try again in a moment.")
            return
        end
        lines[#lines + 1] = ("[LOGS] last %d event(s)%s from SQL%s"):format(#rows, kind and (" matching '" .. kind .. "'") or "", #rows == 0 and " (none yet)" or "")
        for i = #rows, 1, -1 do lines[#lines + 1] = formatRow(rows[i]) end
    else
        local rows = {}
        ringEach(function(row)
            if kind and not row.kind:find(kind, 1, true) then return end
            rows[#rows + 1] = row
            if #rows >= count then return false end
        end)
        lines[#lines + 1] = ("[LOGS] last %d event(s)%s from the memory cache (database %s)"):format(#rows, kind and (" matching '" .. kind .. "'") or "", tostring(dbReason or dbState))
        for i = #rows, 1, -1 do lines[#lines + 1] = formatRow(rows[i]) end
    end
    replyLines(source, lines)
end

local function cmdStats(source)
    local lines = {
        ("[LOGS] rows %d, flushed %d, waiting %d, dropped %d, failed batches %d, cache %d/%d, database %s"):format(
            counters.rows, counters.flushed, #pending, counters.dropped, counters.failedBatches, ringCount, cfg.cacheSize, dbState == "ready" and "ready" or tostring(dbReason or dbState)),
        ("[LOGS] webhook: %s, queued %d, sent %d, failed %d, dropped %d"):format(
            webhookDisabled and ("disabled (" .. webhookDisabled .. ")") or (webhookUrl() and "configured" or "off"),
            #webhookQueue, counters.webhookSent, counters.webhookFailed, counters.webhookDropped),
        ("[LOGS] counted only: zones entered %d / left %d, sms %d"):format(
            counters.counted["rp_zones:entered"] or 0, counters.counted["rp_zones:left"] or 0, counters.counted["rp_phone:sms"] or 0),
    }
    local zoneParts = {}
    for name, z in pairs(counters.zones) do zoneParts[#zoneParts + 1] = ("%s %d/%d"):format(name, z.entered, z.left) end
    table.sort(zoneParts)
    if #zoneParts > 0 then lines[#lines + 1] = "[LOGS] zones (entered/left): " .. table.concat(zoneParts, ", ") end
    replyLines(source, lines)
end

local function cmdWebhook(source, value)
    value = trim(value)
    if value == "" or value:lower() == "status" then
        local url = webhookUrl()
        if webhookDisabled then
            reply(source, ("[LOGS] webhook disabled: %s. Enable http in server.jsonc (allowedHosts [\"discord.com\"]) then set the URL again."):format(webhookDisabled))
        elseif url then
            reply(source, ("[LOGS] webhook on (%s), %d embed(s) queued. /logs webhook off to stop."):format(maskWebhook(url), #webhookQueue))
        else
            reply(source, "[LOGS] webhook off. /logs webhook <https://discord.com/api/webhooks/...> to enable.")
        end
        return
    end
    if value:lower() == "off" then
        local ok, message = Open77.tunables.set(cfg.webhookKey, "")
        if not ok then return reply(source, "[LOGS] Could not clear the webhook: " .. tostring(message)) end
        webhookQueue = {}
        if webhookUrl() then
            return reply(source, "[LOGS] Tunable cleared, but a server.jsonc convar " .. cfg.webhookKey .. " still sets a URL; remove it there.")
        end
        return reply(source, "[LOGS] Webhook off. Sensitive kinds stay in SQL only.")
    end
    if not isWebhookUrl(value) then
        return reply(source, "[LOGS] That is not a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>).")
    end
    local ok, message = Open77.tunables.set(cfg.webhookKey, value)
    if not ok then return reply(source, "[LOGS] Could not store the webhook: " .. tostring(message)) end
    local effective = webhookUrl()
    if effective ~= value then
        return reply(source, "[LOGS] Stored, but a server.jsonc convar " .. cfg.webhookKey .. " overrides it; that URL stays in use.")
    end
    reply(source, ("[LOGS] Webhook set (%s). Arrests, robberies, admin acts, gang wars and bans now reach Discord. /logs test to try it."):format(maskWebhook(value)))
end

local function cmdTest(source, args)
    local words = {}
    for i = 2, args.n do words[#words + 1] = args[i] end
    local text = #words > 0 and table.concat(words, " ") or "webhook test from /logs"
    record("rp_logs:test", text, { playerId = source ~= 0 and source or nil, data = { by = source } })
    if webhookDisabled then
        reply(source, "[LOGS] Row written; the webhook is disabled (" .. webhookDisabled .. ").")
    elseif webhookUrl() then
        reply(source, "[LOGS] Row written and queued for Discord; check the channel within a few seconds.")
    else
        reply(source, "[LOGS] Row written; no webhook configured (/logs webhook <url>).")
    end
end

RegisterCommand("logs", function(source, args)
    local first = args[1] and args[1]:lower() or nil
    if first == "webhook" then return cmdWebhook(source, args[2]) end
    if first == "stats" then return cmdStats(source) end
    if first == "test" then return cmdTest(source, args) end
    if first == "help" then
        return replyLines(source, {
            "[LOGS] /logs [kind] [n] - last n events (SQL). /logs stats - counters. /logs test [text] - write a test row (mirrored to Discord).",
            "[LOGS] /logs webhook <url|off|status> - Discord webhook for the sensitive kinds.",
        })
    end
    local kind, count = nil, cfg.defaultListCount
    if first then
        if tonumber(first) then
            count = tonumber(first)
        else
            kind = sanitizeKind(first)
            if kind == "" then kind = nil end
            count = tonumber(args[2]) or count
        end
    end
    count = math.floor(count)
    if count < 1 then count = 1 elseif count > cfg.maxListCount then count = cfg.maxListCount end
    cmdList(source, kind, count)
end, true)

------------------------------------------------------------------------
-- Chat suggestions and own lifecycle
------------------------------------------------------------------------

local function publishSuggestions(target)
    Open77.chat.addSuggestion(target, "/logs", "Audit trail (admin): last events, stats, webhook, test", {
        { name = "kind|n", help = "a kind filter (bank, ncpd, admin...) or a count" },
        { name = "n", help = "how many events (max 50)" },
    })
end

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then publishSuggestions(source) end
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        record("resource:start", ("%s started"):format(tostring(name)), { data = { resource = name } })
        return
    end
    loadCounters()
    publishSuggestions(-1)
    record("rp_logs:start", "audit trail online", { data = { database = dbState } })
    local url = webhookUrl()
    print(("rp_logs up: database %s, webhook %s"):format(dbState == "ready" and "ready" or tostring(dbReason or dbState), url and maskWebhook(url) or "off"))
end)

AddEventHandler("onResourceStop", function(name, reason)
    if name ~= RESOURCE then
        record("resource:stop", ("%s stopped (%s)"):format(tostring(name), tostring(reason or "?")), { data = { resource = name, reason = reason } })
        return
    end
    record("rp_logs:stop", ("audit trail stopping (%s)"):format(tostring(reason or "?")), nil)
    persistCounters()
    flushAll()
end)

AddEventHandler("open77:admin:serverShuttingDown", function(reason)
    record("server:shutdown", ("server going down (%s)"):format(tostring(reason or "?")), nil)
    persistCounters()
    flushAll()
end)
