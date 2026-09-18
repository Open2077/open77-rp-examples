-- rp_config: central, hot-reloadable settings store for the Night City RP resources.
--
-- The catalogue (shared/defaults.lua) is flattened into dotted keys at load. An override is a
-- row of rp_config_values (SQL first, the resource KVP store while the database is not ready).
-- Every export answers from the in-memory cache and never yields: SQL writes use the callback
-- forms, reload() schedules the re-read. Every change is announced on the host bus as
-- rp_config:changed (key, value); a reload announces rp_config:reloaded (count, source).

local LOG = "[rp_config] "
local CHAT_AUTHOR = "CONFIG"
local CHAT_COLOR = { 0, 229, 255 }
local MAX_KEY_BYTES = 190
local MAX_STRING_BYTES = 1024
local KVP_PREFIX = "override:"

local CREATE_SQL = [[
CREATE TABLE IF NOT EXISTS `rp_config_values` (
    `key` VARCHAR(190) NOT NULL,
    `value` TEXT NOT NULL,
    `updated_at` BIGINT NOT NULL DEFAULT 0,
    `updated_by` VARCHAR(128) NOT NULL DEFAULT '',
    PRIMARY KEY (`key`)
)]]
local SELECT_SQL = "SELECT `key`, `value`, `updated_at`, `updated_by` FROM `rp_config_values`"
local UPSERT_SQL = "INSERT INTO `rp_config_values` (`key`, `value`, `updated_at`, `updated_by`) VALUES (?, ?, ?, ?) "
    .. "ON DUPLICATE KEY UPDATE `value` = VALUES(`value`), `updated_at` = VALUES(`updated_at`), `updated_by` = VALUES(`updated_by`)"
local DELETE_SQL = "DELETE FROM `rp_config_values` WHERE `key` = ?"

-- ---------------------------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------------------------

local DEFAULTS = {}   -- dotted key -> scalar default
local LEAVES = {}     -- every dotted key, sorted
local CHILDREN = {}   -- branch prefix -> sorted array of the leaf keys below it
local OVERRIDES = {}  -- dotted key -> scalar override (effective)
local META = {}       -- dotted key -> { updatedAt, updatedBy }
local RESOURCES = 0   -- top-level sections of the catalogue

local storage = { sqlReady = false, mode = "memory" }

local function segmentOk(seg)
    return type(seg) == "string" and seg:match("^[%w_]+$") ~= nil
end

-- Flattens a nested table into out[dotted key] = scalar. Raises on an unsupported key or value.
local function flatten(node, prefix, out)
    for k, v in pairs(node) do
        local seg
        if math.type(k) == "integer" then
            seg = tostring(k)
        elseif segmentOk(k) then
            seg = k
        else
            error(("invalid key segment %s under '%s'"):format(tostring(k), prefix))
        end
        local key = prefix == "" and seg or (prefix .. "." .. seg)
        local t = type(v)
        if t == "table" then
            flatten(v, key, out)
        elseif t == "number" or t == "boolean" or t == "string" then
            if t == "number" and (v ~= v or v == math.huge or v == -math.huge) then
                error(("non-finite number at '%s'"):format(key))
            end
            out[key] = v
        else
            error(("unsupported value type %s at '%s'"):format(t, key))
        end
    end
end

do
    flatten(RpConfigDefaults, "", DEFAULTS)
    for key in pairs(DEFAULTS) do LEAVES[#LEAVES + 1] = key end
    table.sort(LEAVES)
    for _, key in ipairs(LEAVES) do
        local prefix = key
        while true do
            local cut = prefix:match("^(.*)%.[^.]+$")
            if not cut then break end
            prefix = cut
            CHILDREN[prefix] = CHILDREN[prefix] or {}
            table.insert(CHILDREN[prefix], key)
        end
    end
    for _ in pairs(RpConfigDefaults) do RESOURCES = RESOURCES + 1 end
end

local function validKey(key)
    if type(key) ~= "string" or #key == 0 or #key > MAX_KEY_BYTES then return false end
    if not key:match("^[%w_%.]+$") then return false end
    if key:sub(1, 1) == "." or key:sub(-1) == "." or key:find("..", 1, true) then return false end
    return true
end

-- Checks a candidate value against the default of `key` and returns the normalised value, or
-- nil and a reason. An integer default only takes integral numbers; a float default any number.
local function coerce(key, value)
    local default = DEFAULTS[key]
    if default == nil then return nil, "unknown_key" end
    local want = type(default)
    if want == "number" then
        if type(value) ~= "number" then return nil, "type_mismatch:number" end
        if value ~= value or value == math.huge or value == -math.huge then return nil, "invalid_value" end
        if math.type(default) == "integer" then
            local i = math.tointeger(value)
            if i == nil then return nil, "not_integer" end
            return i
        end
        return value + 0.0
    elseif want == "boolean" then
        if type(value) ~= "boolean" then return nil, "type_mismatch:boolean" end
        return value
    elseif want == "string" then
        if type(value) ~= "string" then return nil, "type_mismatch:string" end
        if #value > MAX_STRING_BYTES then return nil, "string_too_long" end
        return value
    end
    return nil, "invalid_default"
end

local function effective(key)
    local v = OVERRIDES[key]
    if v ~= nil then return v end
    return DEFAULTS[key]
end

local function segKey(seg)
    if seg:match("^%d+$") then return math.tointeger(tonumber(seg)) end
    return seg
end

-- Rebuilds the table below a branch prefix from its leaves (override or default).
local function assemble(prefix)
    local leaves = CHILDREN[prefix]
    if not leaves then return nil end
    local root = {}
    local start = #prefix + 2
    for _, key in ipairs(leaves) do
        local segs = {}
        for seg in key:sub(start):gmatch("[^.]+") do segs[#segs + 1] = seg end
        local node = root
        for i = 1, #segs - 1 do
            local k = segKey(segs[i])
            if type(node[k]) ~= "table" then node[k] = {} end
            node = node[k]
        end
        node[segKey(segs[#segs])] = effective(key)
    end
    return root
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function render(v)
    if type(v) == "string" then return ("%q"):format(v) end
    return tostring(v)
end

-- ---------------------------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------------------------

local function encodeValue(value)
    local text = json.encode(value)
    if type(text) ~= "string" then return nil end
    return text
end

-- The column holds the JSON of a scalar. A row written by hand as a bare word still parses.
local function decodeValue(text)
    if type(text) ~= "string" then return text end
    local v = json.decode(text)
    if v ~= nil then return v end
    local n = tonumber(text)
    if n then return n end
    local lower = text:lower()
    if lower == "true" then return true end
    if lower == "false" then return false end
    return text
end

local function persist(key, value, by, now)
    local text = encodeValue(value)
    if not text then
        print(LOG .. ("cannot encode the value of %s -- kept in memory only"):format(key))
        return "memory"
    end
    if storage.sqlReady then
        Open77.database.update(UPSERT_SQL, { key, text, now, by }, function(result)
            if result == nil or result == false then
                print(LOG .. ("SQL write failed for %s -- the override lives in memory until the next set"):format(key))
            end
        end)
        return "sql"
    end
    local ok, reason = Open77.kvp.set(KVP_PREFIX .. key, text)
    if not ok then
        print(LOG .. ("KVP write failed for %s (%s) -- kept in memory only"):format(key, tostring(reason)))
        return "memory"
    end
    print(LOG .. ("database not ready -- override %s kept in the KVP fallback until SQL answers"):format(key))
    return "kvp"
end

local function forget(key)
    if storage.sqlReady then
        Open77.database.update(DELETE_SQL, { key }, function() end)
    end
    Open77.kvp.delete(KVP_PREFIX .. key)
end

-- Turns rows { key, value, updated_at, updated_by } into a fresh override map. Rows for keys
-- the catalogue does not know, or whose value no longer fits the default, are reported and
-- ignored (they stay in the table: /config unset <key> purges them).
local function parseRows(rows, source)
    local fresh, meta, skipped = {}, {}, 0
    for _, row in ipairs(rows) do
        local key = tostring(row.key or "")
        local coerced, err = coerce(key, decodeValue(row.value))
        if coerced == nil then
            skipped = skipped + 1
            print(LOG .. ("ignoring stored override %s from %s: %s"):format(key, source, tostring(err)))
        else
            fresh[key] = coerced
            meta[key] = { updatedAt = tonumber(row.updated_at) or 0, updatedBy = tostring(row.updated_by or "") }
        end
    end
    return fresh, meta, skipped
end

local function readKvp()
    local entries, reason = Open77.kvp.find(KVP_PREFIX, 4096)
    if type(entries) ~= "table" then
        if reason then print(LOG .. "KVP read failed: " .. tostring(reason)) end
        return {}
    end
    local rows = {}
    for _, entry in ipairs(entries) do
        rows[#rows + 1] = { key = entry.key:sub(#KVP_PREFIX + 1), value = entry.value, updated_at = 0, updated_by = "kvp" }
    end
    return rows
end

-- Replaces the override map, announcing every key whose effective value moved.
local function applyOverrides(fresh, meta, source)
    local changed, seen = {}, {}
    for key, value in pairs(fresh) do
        seen[key] = true
        if OVERRIDES[key] ~= value then changed[#changed + 1] = key end
    end
    for key in pairs(OVERRIDES) do
        if not seen[key] then changed[#changed + 1] = key end
    end
    OVERRIDES = fresh
    META = meta
    table.sort(changed)
    for _, key in ipairs(changed) do
        TriggerEvent("rp_config:changed", key, effective(key))
    end
    TriggerEvent("rp_config:reloaded", countKeys(fresh), source)
    return #changed
end

-- Never yields: the SQL read lands in a callback. onDone(ok, changedCount, source) is optional.
local function scheduleReload(by, onDone)
    if not storage.sqlReady then
        local fresh, meta = parseRows(readKvp(), "kvp")
        local changed = applyOverrides(fresh, meta, "kvp")
        print(LOG .. ("reloaded %d override(s) from KVP (database not ready), %d value(s) changed, by %s"):format(countKeys(fresh), changed, by))
        if onDone then onDone(true, changed, "kvp") end
        return true, "kvp"
    end
    Open77.database.query(SELECT_SQL, {}, function(rows)
        if type(rows) ~= "table" then
            print(LOG .. "reload: SQL read failed, the cache is unchanged")
            if onDone then onDone(nil, 0, "sql_failed") end
            return
        end
        local fresh, meta = parseRows(rows, "sql")
        local changed = applyOverrides(fresh, meta, "sql")
        print(LOG .. ("reloaded %d override(s) from SQL, %d value(s) changed, by %s"):format(countKeys(fresh), changed, by))
        if onDone then onDone(true, changed, "sql") end
    end)
    return true, "scheduled"
end

-- ---------------------------------------------------------------------------------------------
-- Core operations (shared by the exports and the command)
-- ---------------------------------------------------------------------------------------------

local function getValue(key, default)
    if type(key) ~= "string" then return default end
    local v = OVERRIDES[key]
    if v ~= nil then return v end
    v = DEFAULTS[key]
    if v ~= nil then return v end
    if CHILDREN[key] then return assemble(key) end
    return default
end

local function applyOne(key, value, by)
    local now = math.floor(Open77.time.unix())
    OVERRIDES[key] = value
    META[key] = { updatedAt = now, updatedBy = by }
    local where = persist(key, value, by, now)
    TriggerEvent("rp_config:changed", key, value)
    print(LOG .. ("%s = %s (by %s, %s)"):format(key, render(value), by, where))
end

local function setValue(key, value, by)
    if not validKey(key) then return nil, "invalid_key" end
    if DEFAULTS[key] ~= nil then
        local coerced, err = coerce(key, value)
        if coerced == nil then return nil, err end
        applyOne(key, coerced, by)
        return true
    end
    if CHILDREN[key] then
        if type(value) ~= "table" then return nil, "type_mismatch:table" end
        local flat = {}
        local ok = pcall(flatten, value, key, flat)
        if not ok then return nil, "invalid_value" end
        local coercedAll, n = {}, 0
        for leaf, v in pairs(flat) do
            if DEFAULTS[leaf] == nil then return nil, "unknown_key:" .. leaf end
            local c, err = coerce(leaf, v)
            if c == nil then return nil, err .. ":" .. leaf end
            coercedAll[leaf] = c
            n = n + 1
        end
        if n == 0 then return nil, "invalid_value" end
        local ordered = {}
        for leaf in pairs(coercedAll) do ordered[#ordered + 1] = leaf end
        table.sort(ordered)
        for _, leaf in ipairs(ordered) do applyOne(leaf, coercedAll[leaf], by) end
        return true
    end
    return nil, "unknown_key"
end

-- Removes the override(s) of a leaf or a whole branch; returns how many were live.
-- A key the catalogue does not know still gets its stale row deleted.
local function unsetValue(key, by)
    if not validKey(key) then return nil, "invalid_key" end
    local keys = CHILDREN[key] or { key }
    local removed = 0
    for _, k in ipairs(keys) do
        if OVERRIDES[k] ~= nil then
            OVERRIDES[k] = nil
            META[k] = nil
            removed = removed + 1
            TriggerEvent("rp_config:changed", k, DEFAULTS[k])
            print(LOG .. ("%s reset to default %s (by %s)"):format(k, render(DEFAULTS[k]), by))
        end
        forget(k)
    end
    return removed
end

local function allValues(prefix)
    if prefix ~= nil and type(prefix) ~= "string" then return nil, "invalid_prefix" end
    prefix = prefix or ""
    local out = {}
    for _, key in ipairs(LEAVES) do
        if key:sub(1, #prefix) == prefix then out[key] = effective(key) end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Exports (synchronous, never yield)
-- ---------------------------------------------------------------------------------------------

exports("get", function(key, default)
    return getValue(key, default)
end)

exports("set", function(key, value)
    return setValue(key, value, GetInvokingResource() or "export")
end)

exports("unset", function(key)
    return unsetValue(key, GetInvokingResource() or "export")
end)

exports("reload", function()
    return scheduleReload(GetInvokingResource() or "export")
end)

exports("all", function(prefix)
    return allValues(prefix)
end)

-- ---------------------------------------------------------------------------------------------
-- Chat helpers
-- ---------------------------------------------------------------------------------------------

local SUGGESTIONS = {
    {
        command = "/config",
        help = "Central settings store (admin): get / set / unset / list / reload / export",
        parameters = {
            { name = "action", help = "get | set | unset | list | reload | export" },
            { name = "key", help = "dotted key, e.g. rp_bank.transferFeePercent (list: a prefix)" },
            { name = "value", help = "set only: a number, true/false, text, or x=1,y=2,z=3 for a branch" },
        },
    },
}

local function reply(source, text)
    if source == 0 then
        print(LOG .. text)
        return
    end
    Open77.chat.send(source, { author = CHAT_AUTHOR, text = text, color = CHAT_COLOR })
end

-- Several lines that must read in order: one tick apart (chat guide, "Ordering"). Command
-- handlers are managed tasks, so Wait is allowed here.
local function replyLines(source, lines)
    if source == 0 then
        for _, line in ipairs(lines) do print(LOG .. line) end
        return
    end
    for _, line in ipairs(lines) do
        Open77.chat.send(source, { author = CHAT_AUTHOR, text = line, color = CHAT_COLOR })
        Wait(0)
    end
end

local function joinArgs(args, from)
    local parts = {}
    for i = from, args.n or #args do parts[#parts + 1] = tostring(args[i]) end
    return table.concat(parts, " ")
end

local function parseBoolean(raw)
    local s = raw:lower()
    if s == "true" or s == "on" or s == "yes" or s == "1" then return true end
    if s == "false" or s == "off" or s == "no" or s == "0" then return false end
    return nil
end

-- Parses the text after `set <key>` against the key's type. A branch takes a JSON object or
-- the quote-free form `x=381,y=-2401,z=182` (dotted names allowed: position.x=381).
local function parseValue(key, raw)
    if DEFAULTS[key] ~= nil then
        local want = type(DEFAULTS[key])
        if want == "number" then
            local n = tonumber(raw)
            if not n then return nil, "expected a number" end
            return n
        elseif want == "boolean" then
            local b = parseBoolean(raw)
            if b == nil then return nil, "expected true or false" end
            return b
        end
        return raw
    end
    if CHILDREN[key] then
        local t = json.decode(raw)
        if type(t) == "table" then return t end
        local out, n = {}, 0
        for pair in raw:gmatch("[^,]+") do
            local name, value = pair:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
            if not name or value == "" then
                return nil, "expected a JSON object or name=value pairs, e.g. x=381,y=-2401,z=182"
            end
            local leaf = key .. "." .. name
            if DEFAULTS[leaf] == nil then return nil, "unknown key " .. leaf end
            local parsed, err = parseValue(leaf, value)
            if parsed == nil then return nil, err .. " for " .. name end
            local node = out
            local segs = {}
            for seg in name:gmatch("[^.]+") do segs[#segs + 1] = seg end
            for i = 1, #segs - 1 do
                node[segs[i]] = node[segs[i]] or {}
                node = node[segs[i]]
            end
            node[segs[#segs]] = parsed
            n = n + 1
        end
        if n == 0 then return nil, "expected a JSON object or name=value pairs" end
        return out
    end
    return nil, "unknown key"
end

local function describeLine(key)
    local override = OVERRIDES[key]
    if override == nil then
        return ("%s = %s"):format(key, render(DEFAULTS[key]))
    end
    return ("* %s = %s  (default %s)"):format(key, render(override), render(DEFAULTS[key]))
end

local function whoWhen(key)
    local meta = META[key]
    if not meta then return "" end
    return (" -- by %s at %d"):format(meta.updatedBy ~= "" and meta.updatedBy or "?", meta.updatedAt or 0)
end

local USAGE = {
    "Usage: /config get <key> | set <key> <value> | unset <key> | list [prefix] | reload | export",
    "Keys are dotted: rp_bank.transferFeePercent, rp_jobs.salary.ncpd.3, rp_zones.kabuki_market.radius",
}

-- ---------------------------------------------------------------------------------------------
-- /config (restricted: ACL command.config; the console always may)
-- ---------------------------------------------------------------------------------------------

RegisterCommand("config", function(source, args)
    if source ~= 0 and (type(source) ~= "number" or source < 1) then return end
    local by = source == 0 and "console" or (Open77.players.identifier(source) or ("player:" .. tostring(source)))
    local action = (args[1] or ""):lower()
    local key = args[2]

    if action == "get" then
        if not validKey(key) then return reply(source, "Usage: /config get <key>") end
        if DEFAULTS[key] ~= nil then
            return reply(source, describeLine(key) .. whoWhen(key))
        end
        if CHILDREN[key] then
            local overridden = 0
            for _, leaf in ipairs(CHILDREN[key]) do
                if OVERRIDES[leaf] ~= nil then overridden = overridden + 1 end
            end
            return reply(source, ("%s = %s  (%d key(s), %d overridden)"):format(
                key, json.encode(assemble(key)) or "?", #CHILDREN[key], overridden))
        end
        return reply(source, ("Unknown key %s. /config list <prefix> shows what exists."):format(key))

    elseif action == "set" then
        if not validKey(key) or (args.n or #args) < 3 then
            return reply(source, "Usage: /config set <key> <value>")
        end
        local value, err = parseValue(key, joinArgs(args, 3))
        if value == nil then return reply(source, ("Refused: %s."):format(err)) end
        local before = DEFAULTS[key] ~= nil and effective(key) or nil
        local ok, reason = setValue(key, value, by)
        if not ok then return reply(source, ("Refused: %s."):format(tostring(reason))) end
        if DEFAULTS[key] ~= nil then
            return reply(source, ("Set %s (was %s). Live now; %s."):format(
                describeLine(key), render(before),
                storage.sqlReady and "saved to SQL" or "saved to the KVP fallback, database not ready"))
        end
        return reply(source, ("Set %s = %s. Live now."):format(key, json.encode(assemble(key)) or "?"))

    elseif action == "unset" or action == "reset" then
        if not validKey(key) then return reply(source, "Usage: /config unset <key>") end
        local removed, reason = unsetValue(key, by)
        if removed == nil then return reply(source, ("Refused: %s."):format(tostring(reason))) end
        if removed == 0 then
            return reply(source, ("No live override on %s (a stale row, if any, was purged)."):format(key))
        end
        return reply(source, ("%d override(s) removed under %s, back to the defaults."):format(removed, key))

    elseif action == "list" then
        local prefix = key or ""
        if prefix ~= "" and not prefix:match("^[%w_%.]+$") then
            return reply(source, "Usage: /config list [prefix]")
        end
        local lines, overridden, total = {}, 0, 0
        for _, leaf in ipairs(LEAVES) do
            if leaf:sub(1, #prefix) == prefix then
                total = total + 1
                if OVERRIDES[leaf] ~= nil then overridden = overridden + 1 end
                lines[#lines + 1] = describeLine(leaf)
            end
        end
        if total == 0 then
            return reply(source, ("No key under '%s'. Top-level sections: rp_<resource>."):format(prefix))
        end
        local cap = source == 0 and total or getValue("rp_config.chatListMax", 30)
        local out = { ("%d key(s) under '%s', %d overridden (* marks an override)"):format(total, prefix, overridden) }
        for i = 1, math.min(cap, #lines) do out[#out + 1] = lines[i] end
        if #lines > cap then
            out[#out + 1] = ("... %d more. Narrow the prefix, or run it from the server console."):format(#lines - cap)
        end
        return replyLines(source, out)

    elseif action == "reload" then
        reply(source, storage.sqlReady and "Re-reading rp_config_values..." or "Database not ready: re-reading the KVP fallback...")
        scheduleReload(by, function(ok, changed, where)
            if not ok then return reply(source, "Reload failed: the SQL read did not answer. Cache unchanged.") end
            reply(source, ("Reloaded from %s: %d override(s) live, %d value(s) changed."):format(where, countKeys(OVERRIDES), changed))
        end)
        return

    elseif action == "export" then
        local keys = {}
        for k in pairs(OVERRIDES) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {
            ("-- rp_config overrides: %d key(s), exported at %d by %s"):format(#keys, math.floor(Open77.time.unix()), by),
            "RpConfigOverrides = {",
        }
        for _, k in ipairs(keys) do
            out[#out + 1] = ("    [%q] = %s,%s"):format(k, render(OVERRIDES[k]), whoWhen(k))
        end
        out[#out + 1] = "}"
        if source ~= 0 then
            -- the server log keeps a copy the owner can paste from
            for _, line in ipairs(out) do print(LOG .. line) end
        end
        return replyLines(source, out)

    elseif action == "help" or action == "" then
        return replyLines(source, USAGE)
    end
    return replyLines(source, USAGE)
end, true)

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source < 1 then return end
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    print(LOG .. ("catalogue: %d key(s) across %d resource section(s)"):format(#LEAVES, RESOURCES))

    -- Provisional cache: KVP rows only exist when a set() fell back while SQL was not ready.
    local kvpRows = readKvp()
    if #kvpRows > 0 then
        local fresh, meta = parseRows(kvpRows, "kvp")
        applyOverrides(fresh, meta, "kvp")
        print(LOG .. ("%d override(s) loaded from the KVP fallback while waiting for SQL"):format(countKeys(fresh)))
    end

    local ok, reason = Open77.database.ready(function()
        local created = Open77.database.update.await(CREATE_SQL)
        if created == nil or created == false then
            print(LOG .. "could not create rp_config_values -- staying on the KVP fallback")
            storage.mode = "kvp"
            return
        end
        local rows = Open77.database.query.await(SELECT_SQL)
        if type(rows) ~= "table" then
            print(LOG .. "could not read rp_config_values -- staying on the KVP fallback")
            storage.mode = "kvp"
            return
        end
        storage.sqlReady = true
        storage.mode = "sql"
        local fresh, meta, skipped = parseRows(rows, "sql")

        -- Overrides set while the database was connecting win over older SQL rows: move them.
        local migrated = 0
        for _, row in ipairs(readKvp()) do
            local coerced = coerce(row.key, decodeValue(row.value))
            if coerced ~= nil then
                fresh[row.key] = coerced
                meta[row.key] = { updatedAt = math.floor(Open77.time.unix()), updatedBy = "kvp-migration" }
                persist(row.key, coerced, "kvp-migration", math.floor(Open77.time.unix()))
                migrated = migrated + 1
            end
            Open77.kvp.delete(KVP_PREFIX .. row.key)
        end

        local changed = applyOverrides(fresh, meta, "sql")
        print(LOG .. ("schema ready (rp_config_values); %d override(s) loaded from SQL, %d migrated from KVP, %d ignored, %d value(s) changed"):format(
            countKeys(fresh), migrated, skipped, changed))
    end)
    if not ok then
        storage.mode = "kvp"
        print(LOG .. ("database unavailable (%s) -- overrides live in this resource's KVP store"):format(tostring(reason)))
    end

    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    print(LOG .. "started; /config (ACL command.config) is live")
end)
