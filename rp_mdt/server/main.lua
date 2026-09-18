-- rp_mdt: server side of the NCPD / Trauma Team tablet.
--
-- The server decides everything: which mode a player gets (from rp_jobs), whether
-- they are still on duty at every single page action, what a citizen card contains,
-- and which actions a mode may run. The client only shows the page and relays intents.
--
-- Cross-resource data comes through pcall'd exports (rp_jobs, rp_identity, rp_ncpd,
-- rp_trauma, rp_garage, rp_logs) and, when no export covers a need, through READ-ONLY
-- SELECTs on the sibling tables named in the README. The only table this resource
-- writes is its own: rp_mdt_reports.

local RES = "rp_mdt"
local Config = Config -- shared/config.lua

local store = { mode = nil, reason = nil }  -- "sql" | "kvp", chosen once per boot
local open = {}        -- playerId -> { mode = "ncpd"|"trauma", since = unix }
local alerts = {}      -- newest last; the last Config.dispatch.keep rp_ncpd:alert events
local kvpReports = nil -- fallback report list when the database is not available

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[%s] " .. fmt):format(RES, ...))
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, max)
    s = trim(s)
    if #s > max then s = s:sub(1, max) end
    return s
end

local function likeEscape(s)
    return (s:gsub("[%%_\\]", "\\%0"))
end

local function modeColor(mode)
    local def = mode and Config.modes[mode]
    return (def and def.chatColor) or { 200, 200, 200 }
end

-- Chat line to one player, tagged MDT and coloured by mode.
local function say(playerId, mode, text)
    if type(playerId) ~= "number" or playerId <= 0 then
        print(("[%s] %s"):format(RES, text))
        return
    end
    Open77.chat.send(playerId, { author = "MDT", text = text, color = modeColor(mode) })
end

-- Call a sibling's synchronous export. Returns ok, value, reason. `ok == false`
-- means the resource or the export is missing (the call raised), which the tablet
-- shows as "<registry> offline"; a legitimate `nil, reason` answer keeps ok == true.
local function call(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return false, nil, tostring(a) end
    return true, a, b
end

-- Read-only SQL. nil, reason when there is no database or the statement failed
-- (a sibling's table that does not exist because that resource never ran, for
-- instance) -- the page prints the reason instead of a hole.
local function dbRows(sql, params)
    if store.mode ~= "sql" then return nil, "database_offline" end
    local ok, rows = pcall(Open77.database.query.await, sql, params or {})
    if not ok then return nil, "sql_error" end
    if type(rows) ~= "table" then return nil, "sql_error" end
    return rows
end

local function dbSingle(sql, params)
    if store.mode ~= "sql" then return nil, "database_offline" end
    local ok, row = pcall(Open77.database.single.await, sql, params or {})
    if not ok then return nil, "sql_error" end
    if row == nil then return nil, "not_found" end
    return row
end

-- identifier -> connected session id, for every connected player.
local function onlineByIdentifier()
    local map = {}
    for _, id in ipairs(Open77.players.all()) do
        local ident = Open77.players.identifier(id)
        if ident then map[ident] = id end
    end
    return map
end

-- The RP name of a connected player (rp_identity, else the account name).
local function nameOf(playerId)
    local ok, full = call("rp_identity", "fullName", playerId)
    if ok and type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

local function distanceTo(playerId, pos)
    local me = Open77.players.position(playerId)
    if not me or type(pos) ~= "table" then return nil end
    local x, y, z = pos.x or pos[1], pos.y or pos[2], pos.z or pos[3]
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local dx, dy, dz = me.x - x, me.y - y, (me.z or 0) - (type(z) == "number" and z or (me.z or 0))
    return math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5)
end

local function send(playerId, payload)
    TriggerClientEvent("rp_mdt:data", playerId, payload)
end

local function notice(playerId, ok, text)
    send(playerId, { kind = "notice", ok = ok and true or false, text = text })
end

-- Audit trail through rp_logs when it runs (kind becomes rp_mdt:<kind>).
local function audit(kind, text, data)
    pcall(Open77.exports.callSync, "rp_logs", "log", kind, text, data)
end

---------------------------------------------------------------------------
-- Store: SQL first, Open77.kvp when the database never answers
---------------------------------------------------------------------------

local function useKvp(reason)
    if store.mode then return end
    store.mode, store.reason = "kvp", reason
    local raw = Open77.kvp.get("reports", "[]")
    kvpReports = json.decode(raw) or {}
    log("store=kvp reason=%s (reports in Open77.kvp, citizen directory limited to connected players)", tostring(reason))
end

local readyOk, readyReason = Open77.database.ready(function()
    if store.mode == "kvp" then
        log("database answered late: kvp kept for this boot, restart the resource to use SQL")
        return
    end
    local ok, err = pcall(Open77.database.update.await, [[
        CREATE TABLE IF NOT EXISTS rp_mdt_reports (
            id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
            mode        VARCHAR(8)   NOT NULL,
            author      VARCHAR(64)  NOT NULL,
            author_name VARCHAR(80)  NOT NULL,
            target      VARCHAR(64)  NOT NULL DEFAULT '',
            target_name VARCHAR(80)  NOT NULL DEFAULT '',
            title       VARCHAR(80)  NOT NULL,
            text        TEXT         NOT NULL,
            at          BIGINT       NOT NULL,
            PRIMARY KEY (id),
            KEY idx_mode_at (mode, at),
            KEY idx_target (target)
        )
    ]], {})
    if not ok then
        useKvp("schema_failed")
        return
    end
    store.mode = "sql"
    log("store=sql table=rp_mdt_reports")
end)

if not readyOk then
    useKvp(readyReason or "database_unavailable")
else
    CreateThread(function()
        Wait((Config.databaseGraceSeconds or 15) * 1000)
        if not store.mode then useKvp("database_not_answering") end
    end)
end

---------------------------------------------------------------------------
-- Duty and mode
---------------------------------------------------------------------------

-- The mode a player is entitled to right now: "ncpd" | "trauma", or nil, reason.
local function resolveMode(playerId)
    local ok, job = call("rp_jobs", "getJob", playerId)
    if not ok then return nil, "roster_offline" end
    if not job then return nil, "no_job" end
    local mode = Config.jobModes[job]
    if not mode then return nil, "wrong_job" end
    local ok2, duty = call("rp_jobs", "onDuty", playerId)
    if not ok2 then return nil, "roster_offline" end
    if not duty then return nil, "off_duty" end
    return mode
end

local dutyText = {
    roster_offline = "The job roster (rp_jobs) is offline: no tablet without a badge check.",
    no_job = "No badge, no tablet, choom. The MDT is for the NCPD and Trauma Team.",
    wrong_job = "Your job has no tablet. The MDT is for the NCPD and Trauma Team.",
    off_duty = "Clock in first (/service): the tablet only works on duty.",
}

local function modeHasTab(mode, tab)
    local def = Config.modes[mode]
    if not def then return false end
    for _, t in ipairs(def.tabs) do
        if t == tab then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Citizens
---------------------------------------------------------------------------

-- Search connected players (exports) and the civil registry (read-only SQL).
local function searchCitizens(query)
    local results, seen = {}, {}
    local limit = Config.limits.results
    local lower = query:lower()
    local number = tonumber(query:match("^#?(%d+)$"))

    -- Connected players first: works without a database.
    local online = Open77.players.all()
    for _, id in ipairs(online) do
        local ident = Open77.players.identifier(id)
        local name = nameOf(id)
        local hit = (number ~= nil and number == id) or (name:lower():find(lower, 1, true) ~= nil)
        if ident and hit and not seen[ident] then
            seen[ident] = true
            local okReg, registered = call("rp_identity", "isRegistered", id)
            results[#results + 1] = {
                identifier = ident, name = name, online = true, playerId = id,
                -- nil when rp_identity is offline: the page shows no badge rather than a wrong one
                registered = okReg and (registered and true or false) or nil,
            }
        end
    end

    -- Then the civil registry: citizen id or name, offline citizens included.
    local rows, reason
    if number then
        rows, reason = dbRows(
            "SELECT id, identifier, first_name, last_name FROM rp_identity_citizens WHERE id = ? LIMIT 1",
            { number })
    else
        local like = "%" .. likeEscape(lower) .. "%"
        rows, reason = dbRows(([[
            SELECT id, identifier, first_name, last_name FROM rp_identity_citizens
            WHERE LOWER(CONCAT(first_name, ' ', last_name)) LIKE ? OR LOWER(first_name) LIKE ? OR LOWER(last_name) LIKE ?
            ORDER BY last_name, first_name LIMIT %d
        ]]):format(limit), { like, like, like })
    end
    local map = onlineByIdentifier()
    if rows then
        for _, row in ipairs(rows) do
            if row.identifier and not seen[row.identifier] then
                seen[row.identifier] = true
                results[#results + 1] = {
                    identifier = row.identifier, citizenId = row.id,
                    name = ("%s %s"):format(row.first_name or "?", row.last_name or "?"),
                    online = map[row.identifier] ~= nil, playerId = map[row.identifier],
                    registered = true,
                }
            else
                -- A connected hit gets its citizen id from the registry row.
                for _, r in ipairs(results) do
                    if r.identifier == row.identifier then r.citizenId = row.id end
                end
            end
            if #results >= limit then break end
        end
    end
    -- Citizen ids for connected hits found by name only.
    if store.mode == "sql" and not number then
        for _, r in ipairs(results) do
            if r.online and not r.citizenId then
                local row = dbSingle("SELECT id FROM rp_identity_citizens WHERE identifier = ?", { r.identifier })
                if row then r.citizenId = row.id end
            end
        end
    end
    return results, (rows == nil) and reason or nil
end

-- MDT reports filed on one citizen, for this mode.
local function reportsOn(mode, identifier, limit)
    if store.mode == "kvp" then
        local out = {}
        for i = #kvpReports, 1, -1 do
            local r = kvpReports[i]
            if r.mode == mode and r.target == identifier then
                out[#out + 1] = { id = r.id, title = r.title, author_name = r.author_name, at = r.at }
                if #out >= limit then break end
            end
        end
        return out
    end
    return dbRows(
        ("SELECT id, title, author_name, at FROM rp_mdt_reports WHERE mode = ? AND target = ? ORDER BY at DESC LIMIT %d"):format(limit),
        { mode, identifier }) or {}
end

-- Everything the card shows, gathered from exports for a connected citizen and from
-- read-only SQL for an offline one. Every block carries its source so the page can
-- say "offline" instead of "nothing".
local function buildCard(mode, identifier)
    local L = Config.limits
    local map = onlineByIdentifier()
    local playerId = map[identifier]
    local card = {
        identifier = identifier,
        short = identifier:sub(1, 10),
        online = playerId ~= nil,
        playerId = playerId,
        mode = mode,
    }

    -- Identity
    if playerId then
        local ok, info = call("rp_identity", "get", playerId)
        if ok and type(info) == "table" then
            card.name = ("%s %s"):format(info.firstName or "?", info.lastName or "?")
            card.birth, card.sex, card.origin = info.birth, info.sex, info.origin
            card.registered = true
            card.identitySource = "export"
        elseif ok then
            card.registered = false
            card.identitySource = "export"
        else
            card.identitySource = "offline"
        end
        card.name = card.name or nameOf(playerId)
        card.accountName = Open77.players.name(playerId)
    end
    local row = dbSingle(
        "SELECT id, first_name, last_name, birth, sex, origin FROM rp_identity_citizens WHERE identifier = ?",
        { identifier })
    if row then
        card.citizenId = row.id
        card.name = card.name or ("%s %s"):format(row.first_name or "?", row.last_name or "?")
        card.birth, card.sex, card.origin = card.birth or row.birth, card.sex or row.sex, card.origin or row.origin
        card.registered = true
        card.identitySource = card.identitySource or "sql"
    end
    card.name = card.name or "Unknown citizen"
    card.identitySource = card.identitySource or (store.mode == "sql" and "sql" or "offline")

    -- Trauma Team contract (both modes: the police see who is covered too)
    if playerId then
        local ok, has = call("rp_trauma", "hasContract", playerId)
        if ok then card.contract = has and true or false; card.contractSource = "export"
        else card.contractSource = "offline" end
        local okD, down = call("rp_trauma", "isDown", playerId)
        if okD then card.down = down and true or false end
    end
    if card.contract == nil then
        local c = dbSingle("SELECT active, until_at FROM rp_trauma_contracts WHERE identifier = ?", { identifier })
        if c then
            card.contract = (tonumber(c.active) == 1) and (tonumber(c.until_at) or 0) > Open77.time.unix()
            card.contractSource = "sql"
        elseif store.mode == "sql" then
            card.contract, card.contractSource = false, "sql"
        else
            card.contractSource = card.contractSource or "offline"
        end
    end

    if mode == "ncpd" then
        -- Warrant
        if playerId then
            local ok, w = call("rp_ncpd", "wanted", playerId)
            if ok then
                card.warrant = (type(w) == "table") and { level = w.level, reason = w.reason } or false
                card.warrantSource = "export"
            else
                card.warrantSource = "offline"
            end
        end
        if card.warrant == nil then
            local w = dbSingle(
                "SELECT level, reason, officer_name, created_at FROM rp_ncpd_warrants WHERE identifier = ?",
                { identifier })
            if w then
                card.warrant = { level = w.level, reason = w.reason, officer = w.officer_name, at = w.created_at }
                card.warrantSource = "sql"
            elseif store.mode == "sql" then
                card.warrant, card.warrantSource = false, "sql"
            else
                card.warrantSource = card.warrantSource or "offline"
            end
        end

        -- Criminal record
        if playerId then
            local ok, rec = call("rp_ncpd", "record", playerId)
            if ok and type(rec) == "table" then
                card.record = {}
                for i, e in ipairs(rec.entries or {}) do
                    if i > L.records then break end
                    card.record[#card.record + 1] = { kind = e.kind, text = e.text, officer = e.officer, at = e.at }
                end
                card.recordSource = "export"
            elseif ok then
                card.record, card.recordSource = {}, "export"
            else
                card.recordSource = "offline"
            end
        end
        if card.record == nil then
            local rows, reason = dbRows(
                ("SELECT kind, text, officer_name, created_at FROM rp_ncpd_records WHERE identifier = ? ORDER BY id DESC LIMIT %d"):format(L.records),
                { identifier })
            if rows then
                card.record = {}
                for _, e in ipairs(rows) do
                    card.record[#card.record + 1] = { kind = e.kind, text = e.text, officer = e.officer_name, at = e.created_at }
                end
                card.recordSource = "sql"
            else
                card.record, card.recordSource = {}, card.recordSource or reason or "offline"
            end
        end

        -- Unpaid fines: no export gives them, read-only SQL on rp_ncpd_fines.
        local fines, reason = dbRows(
            -- rp_ncpd_fines.paid_at is BIGINT NOT NULL DEFAULT 0 (0 = unpaid), never NULL.
            "SELECT amount, remaining, reason, officer_name, created_at FROM rp_ncpd_fines WHERE identifier = ? AND (paid_at IS NULL OR paid_at = 0) AND remaining > 0 ORDER BY id DESC LIMIT 20",
            { identifier })
        card.fines, card.finesTotal = {}, 0
        if fines then
            for _, f in ipairs(fines) do
                local left = tonumber(f.remaining) or tonumber(f.amount) or 0
                card.fines[#card.fines + 1] = { amount = f.amount, remaining = left, reason = f.reason, officer = f.officer_name, at = f.created_at }
                card.finesTotal = card.finesTotal + left
            end
            card.finesSource = "sql"
        else
            card.finesSource = reason or "offline"
        end

        -- Vehicles
        if playerId then
            local ok, list = call("rp_garage", "vehiclesOf", playerId)
            if ok and type(list) == "table" then
                card.vehicles = {}
                for i, v in ipairs(list) do
                    if i > L.vehicles then break end
                    card.vehicles[#card.vehicles + 1] = { plate = v.plate, label = v.label, state = v.state or (v.stored and "stored" or "out"), wanted = v.wanted and true or false }
                end
                card.vehiclesSource = "export"
            else
                card.vehiclesSource = "offline"
            end
        end
        if card.vehicles == nil then
            local rows, reason2 = dbRows(
                ("SELECT plate, label, state, wanted, wanted_reason FROM rp_garage_vehicles WHERE owner = ? ORDER BY plate LIMIT %d"):format(L.vehicles),
                { identifier })
            if rows then
                card.vehicles = {}
                for _, v in ipairs(rows) do
                    card.vehicles[#card.vehicles + 1] = { plate = v.plate, label = v.label, state = v.state, wanted = tonumber(v.wanted) == 1, wantedReason = v.wanted_reason }
                end
                card.vehiclesSource = "sql"
            else
                card.vehicles, card.vehiclesSource = {}, card.vehiclesSource or reason2 or "offline"
            end
        end

        -- Gun licence: rp_shops has no export for it, read-only SQL on rp_shops_licences.
        local lic, reason3 = dbSingle("SELECT name, fee, created_at FROM rp_shops_licences WHERE identifier = ?", { identifier })
        if lic then
            card.licence, card.licenceSource = { name = lic.name, fee = lic.fee, at = lic.created_at }, "sql"
        elseif reason3 == "not_found" then
            card.licence, card.licenceSource = false, "sql"
        else
            card.licenceSource = reason3 or "offline"
        end
    end

    if mode == "trauma" then
        -- Unpaid Trauma Team bills: read-only SQL on rp_trauma_bills.
        local bills, reason = dbRows(
            "SELECT amount, reason, created_at FROM rp_trauma_bills WHERE identifier = ? AND paid_at IS NULL ORDER BY id DESC LIMIT 20",
            { identifier })
        card.bills, card.billsTotal = {}, 0
        if bills then
            for _, b in ipairs(bills) do
                card.bills[#card.bills + 1] = { amount = b.amount, reason = b.reason, at = b.created_at }
                card.billsTotal = card.billsTotal + (tonumber(b.amount) or 0)
            end
            card.billsSource = "sql"
        else
            card.billsSource = reason or "offline"
        end
    end

    card.reports = reportsOn(mode, identifier, 10)
    card.recordKinds = Config.recordKinds
    card.warrantLevels = Config.warrant
    return card
end

---------------------------------------------------------------------------
-- Vehicles
---------------------------------------------------------------------------

local function searchVehicles(query)
    local results = {}
    local limit = Config.limits.results
    local map = onlineByIdentifier()
    local upper = query:upper()
    local like = "%" .. likeEscape(upper) .. "%"
    local rows, reason = dbRows(([[
        SELECT plate, label, record, state, owner, owner_name, wanted, wanted_reason, impound_reason
        FROM rp_garage_vehicles
        WHERE UPPER(plate) LIKE ? OR UPPER(owner_name) LIKE ?
        ORDER BY plate LIMIT %d
    ]]):format(limit), { like, like })
    if rows then
        for _, v in ipairs(rows) do
            results[#results + 1] = {
                plate = v.plate, label = v.label, record = v.record, state = v.state,
                owner = v.owner, ownerName = v.owner_name, ownerOnline = map[v.owner] ~= nil,
                wanted = tonumber(v.wanted) == 1, wantedReason = v.wanted_reason, impoundReason = v.impound_reason,
            }
        end
        return results, "sql"
    end
    -- No database: walk the connected owners through the export.
    local seen = {}
    for _, id in ipairs(Open77.players.all()) do
        local ok, list = call("rp_garage", "vehiclesOf", id)
        if not ok then return results, "offline" end
        local ident = Open77.players.identifier(id)
        for _, v in ipairs(list or {}) do
            local plate = tostring(v.plate or "")
            if not seen[plate] and (plate:upper():find(upper, 1, true) or nameOf(id):upper():find(upper, 1, true)) then
                seen[plate] = true
                results[#results + 1] = {
                    plate = plate, label = v.label, record = v.record, state = v.state or (v.stored and "stored" or "out"),
                    owner = ident, ownerName = nameOf(id), ownerOnline = true, wanted = v.wanted and true or false,
                }
                if #results >= limit then return results, "export" end
            end
        end
    end
    return results, "export"
end

---------------------------------------------------------------------------
-- Reports (the one table this resource writes)
---------------------------------------------------------------------------

local function addReport(mode, playerId, targetIdentifier, targetName, title, text)
    local row = {
        mode = mode,
        author = Open77.players.identifier(playerId) or "",
        author_name = nameOf(playerId),
        target = targetIdentifier or "",
        target_name = targetName or "",
        title = title, text = text,
        at = math.floor(Open77.time.unix()),
    }
    if store.mode == "kvp" then
        row.id = math.floor(tonumber(Open77.kvp.get("nextId", 1)) or 1)
        Open77.kvp.set("nextId", row.id + 1)
        kvpReports[#kvpReports + 1] = row
        while #kvpReports > Config.limits.kvpReports do table.remove(kvpReports, 1) end
        -- The kvp store caps a value at 64 KiB: drop the oldest reports until it fits.
        local encoded = json.encode(kvpReports) or "[]"
        while #encoded > 60000 and #kvpReports > 1 do
            table.remove(kvpReports, 1)
            encoded = json.encode(kvpReports) or "[]"
        end
        local okSet, whySet = Open77.kvp.set("reports", encoded)
        if not okSet then
            log("kvp write refused: %s (report #%d kept in memory only)", tostring(whySet), row.id)
        end
        return row.id
    end
    local ok, id = pcall(Open77.database.insert.await,
        "INSERT INTO rp_mdt_reports (mode, author, author_name, target, target_name, title, text, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        { row.mode, row.author, row.author_name, row.target, row.target_name, row.title, row.text, row.at })
    if not ok then return nil, "sql_error" end
    return id
end

local function searchReports(mode, query)
    local limit = Config.limits.reports
    if store.mode == "kvp" then
        local out, lower = {}, query:lower()
        for i = #kvpReports, 1, -1 do
            local r = kvpReports[i]
            if r.mode == mode and (query == "" or (r.title .. " " .. r.text .. " " .. r.target_name .. " " .. r.author_name):lower():find(lower, 1, true)) then
                out[#out + 1] = { id = r.id, title = r.title, author_name = r.author_name, target_name = r.target_name, excerpt = r.text:sub(1, 160), at = r.at }
                if #out >= limit then break end
            end
        end
        return out, "kvp"
    end
    local rows, reason
    if query == "" then
        rows, reason = dbRows(
            ("SELECT id, title, author_name, target_name, LEFT(text, 160) AS excerpt, at FROM rp_mdt_reports WHERE mode = ? ORDER BY at DESC LIMIT %d"):format(limit),
            { mode })
    else
        local like = "%" .. likeEscape(query:lower()) .. "%"
        rows, reason = dbRows(([[
            SELECT id, title, author_name, target_name, LEFT(text, 160) AS excerpt, at FROM rp_mdt_reports
            WHERE mode = ? AND (LOWER(title) LIKE ? OR LOWER(text) LIKE ? OR LOWER(target_name) LIKE ? OR LOWER(author_name) LIKE ?)
            ORDER BY at DESC LIMIT %d
        ]]):format(limit), { mode, like, like, like, like })
    end
    if not rows then return {}, reason or "offline" end
    return rows, "sql"
end

local function getReport(mode, id)
    if store.mode == "kvp" then
        for _, r in ipairs(kvpReports) do
            if r.id == id and r.mode == mode then return r end
        end
        return nil, "not_found"
    end
    return dbSingle("SELECT id, title, text, author_name, target, target_name, at FROM rp_mdt_reports WHERE id = ? AND mode = ?", { id, mode })
end

---------------------------------------------------------------------------
-- Dispatch, medical, net traces
---------------------------------------------------------------------------

local function dispatchRows(mode, playerId)
    local def = Config.modes[mode]
    local rows = {}
    for i = #alerts, 1, -1 do
        local a = alerts[i]
        if not def.dispatchKinds or def.dispatchKinds[a.kind] then
            rows[#rows + 1] = {
                kind = a.kind, text = a.text, by = a.by, at = a.at,
                distance = distanceTo(playerId, a.position),
                x = a.position and a.position.x, y = a.position and a.position.y,
            }
        end
    end
    return rows
end

local function medicalRows(playerId)
    local out = { down = {}, contracts = {}, bills = {}, revives = nil }
    local traumaUp = call("rp_trauma", "isDown", playerId)
    out.traumaSource = traumaUp and "export" or "offline"
    if traumaUp then
        for _, id in ipairs(Open77.players.all()) do
            local ok, down = call("rp_trauma", "isDown", id)
            local ok2, contract = call("rp_trauma", "hasContract", id)
            if ok and down then
                local pos = Open77.players.position(id)
                out.down[#out.down + 1] = { playerId = id, name = nameOf(id), distance = pos and distanceTo(playerId, pos), contract = (ok2 and contract) and true or false }
            end
            if ok2 and contract then
                out.contracts[#out.contracts + 1] = { playerId = id, name = nameOf(id) }
            end
        end
    end

    -- Unpaid bills, with the civil name when the registry table is there.
    local rows, reason = dbRows(([[
        SELECT b.identifier, b.amount, b.reason, b.created_at, c.first_name, c.last_name
        FROM rp_trauma_bills b LEFT JOIN rp_identity_citizens c ON c.identifier = b.identifier
        WHERE b.paid_at IS NULL ORDER BY b.id DESC LIMIT %d
    ]]):format(Config.limits.reports), {})
    if not rows then
        rows, reason = dbRows(
            ("SELECT identifier, amount, reason, created_at FROM rp_trauma_bills WHERE paid_at IS NULL ORDER BY id DESC LIMIT %d"):format(Config.limits.reports),
            {})
    end
    if rows then
        local map = onlineByIdentifier()
        for _, b in ipairs(rows) do
            local name = (b.first_name and (b.first_name .. " " .. (b.last_name or ""))) or (map[b.identifier] and nameOf(map[b.identifier])) or tostring(b.identifier):sub(1, 10)
            out.bills[#out.bills + 1] = { identifier = b.identifier, name = name, amount = b.amount, reason = b.reason, at = b.created_at }
        end
        out.billsSource = "sql"
    else
        out.billsSource = reason or "offline"
    end

    local ok, revives = call("rp_logs", "query", { kind = "rp_trauma:revived", limit = Config.limits.logs })
    if ok and type(revives) == "table" then
        out.revives = {}
        for _, r in ipairs(revives) do
            out.revives[#out.revives + 1] = { at = r.at, text = r.text, name = r.player_name }
        end
        out.revivesSource = "export"
    else
        out.revivesSource = "offline"
    end
    return out
end

local function netTraceRows()
    local ok, rows = call("rp_logs", "query", { kind = "rp_netrunner", limit = Config.limits.logs })
    if not ok or type(rows) ~= "table" then return nil, "offline" end
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { at = r.at, kind = r.kind, text = r.text, name = r.player_name }
    end
    return out, "export"
end

---------------------------------------------------------------------------
-- Intent handlers: (playerId, mode, payload) -> nothing; they send themselves.
---------------------------------------------------------------------------

local actions = {}

local function resolveTargetName(identifier)
    local map = onlineByIdentifier()
    if map[identifier] then return nameOf(map[identifier]) end
    local row = dbSingle("SELECT first_name, last_name FROM rp_identity_citizens WHERE identifier = ?", { identifier })
    if row then return ("%s %s"):format(row.first_name or "?", row.last_name or "?") end
    return identifier:sub(1, 10)
end

actions.citizen_search = function(playerId, mode, p)
    local query = clip(p.query, Config.limits.query)
    if #query < 1 then return notice(playerId, false, "Type a name or a citizen id.") end
    local results, reason = searchCitizens(query)
    send(playerId, { kind = "citizen_search", query = query, results = results, registrySource = reason and "offline" or (store.mode == "sql" and "sql" or "export"), reason = reason })
    audit("lookup", ("citizen search '%s': %d hit(s)"):format(query, #results), { playerId = playerId, query = query })
end

actions.citizen_card = function(playerId, mode, p)
    local identifier = clip(p.identifier, 64)
    if identifier == "" then return notice(playerId, false, "No citizen selected.") end
    send(playerId, { kind = "citizen_card", card = buildCard(mode, identifier) })
    audit("lookup", ("opened the file of %s"):format(identifier:sub(1, 10)), { playerId = playerId, identifier = identifier })
end

actions.warrant_set = function(playerId, mode, p)
    if mode ~= "ncpd" then return notice(playerId, false, "Warrants are NCPD business.") end
    local identifier = clip(p.identifier, 64)
    local level = math.floor(tonumber(p.level) or 0)
    local reason = clip(p.reason, Config.limits.reason)
    if identifier == "" then return notice(playerId, false, "No citizen selected.") end
    if level < Config.warrant.minLevel or level > Config.warrant.maxLevel then
        return notice(playerId, false, ("Warrant level must be %d to %d."):format(Config.warrant.minLevel, Config.warrant.maxLevel))
    end
    if reason == "" then return notice(playerId, false, "A warrant needs a reason.") end
    local target = onlineByIdentifier()[identifier]
    if not target then
        return notice(playerId, false, "Citizen offline: the NCPD registry only sets warrants on connected citizens.")
    end
    local ok, res, why = call("rp_ncpd", "setWanted", target, level, reason)
    if not ok then return notice(playerId, false, "NCPD registry offline (rp_ncpd is not running).") end
    if not res then return notice(playerId, false, "Warrant refused: " .. tostring(why)) end
    local name = nameOf(target)
    notice(playerId, true, ("Warrant level %d set on %s: %s"):format(level, name, reason))
    log("player %d set warrant L%d on player %d (%s): %s", playerId, level, target, identifier:sub(1, 10), reason)
    audit("warrant", ("warrant L%d set on %s: %s"):format(level, name, reason), { playerId = playerId, identifier = identifier, level = level })
    send(playerId, { kind = "citizen_card", card = buildCard(mode, identifier) })
end

actions.warrant_lift = function(playerId, mode, p)
    if mode ~= "ncpd" then return notice(playerId, false, "Warrants are NCPD business.") end
    local identifier = clip(p.identifier, 64)
    if identifier == "" then return notice(playerId, false, "No citizen selected.") end
    local target = onlineByIdentifier()[identifier]
    if not target then
        return notice(playerId, false, "Citizen offline: the NCPD registry only lifts warrants on connected citizens.")
    end
    local ok, res, why = call("rp_ncpd", "setWanted", target, 0, "lifted from the MDT")
    if not ok then return notice(playerId, false, "NCPD registry offline (rp_ncpd is not running).") end
    if not res then return notice(playerId, false, "Nothing to lift: " .. tostring(why)) end
    local name = nameOf(target)
    notice(playerId, true, ("Warrant lifted on %s."):format(name))
    log("player %d lifted the warrant on player %d (%s)", playerId, target, identifier:sub(1, 10))
    audit("warrant", ("warrant lifted on %s"):format(name), { playerId = playerId, identifier = identifier, level = 0 })
    send(playerId, { kind = "citizen_card", card = buildCard(mode, identifier) })
end

actions.record_add = function(playerId, mode, p)
    if mode ~= "ncpd" then return notice(playerId, false, "Criminal records are NCPD business.") end
    local identifier = clip(p.identifier, 64)
    local kind = clip(p.kind, 24):lower()
    local text = clip(p.text, 240)
    if identifier == "" then return notice(playerId, false, "No citizen selected.") end
    local known = false
    for _, k in ipairs(Config.recordKinds) do if k == kind then known = true end end
    if not known then return notice(playerId, false, "Pick a record kind from the list.") end
    if #text < 3 then return notice(playerId, false, "Write at least a few words.") end
    local target = onlineByIdentifier()[identifier]
    if not target then
        return notice(playerId, false, "Citizen offline: the NCPD registry only takes entries on connected citizens. File an MDT report instead.")
    end
    local ok, res, why = call("rp_ncpd", "addRecord", target, kind, text, playerId)
    if not ok then return notice(playerId, false, "NCPD registry offline (rp_ncpd is not running).") end
    if not res then return notice(playerId, false, "Entry refused: " .. tostring(why)) end
    notice(playerId, true, ("Record entry [%s] added on %s."):format(kind, nameOf(target)))
    log("player %d added a [%s] record entry on player %d", playerId, kind, target)
    audit("record", ("[%s] %s"):format(kind, text), { playerId = playerId, identifier = identifier })
    send(playerId, { kind = "citizen_card", card = buildCard(mode, identifier) })
end

actions.vehicle_search = function(playerId, mode, p)
    if not modeHasTab(mode, "vehicles") then return notice(playerId, false, "Plates are NCPD business.") end
    local query = clip(p.query, Config.limits.query)
    if #query < 2 then return notice(playerId, false, "Type at least two characters of a plate or an owner's name.") end
    local results, source = searchVehicles(query)
    send(playerId, { kind = "vehicle_search", query = query, results = results, source = source })
    audit("lookup", ("plate search '%s': %d hit(s)"):format(query, #results), { playerId = playerId, query = query })
end

actions.vehicle_flag = function(playerId, mode, p)
    if mode ~= "ncpd" then return notice(playerId, false, "Plates are NCPD business.") end
    local plate = clip(p.plate, 16):upper()
    local stolen = p.stolen and true or false
    local reason = clip(p.reason, Config.limits.reason)
    if plate == "" then return notice(playerId, false, "No plate selected.") end
    if stolen and reason == "" then reason = "stolen" end
    local ok, res, why = call("rp_garage", "setWanted", plate, stolen, reason)
    if not ok then return notice(playerId, false, "Vehicle registry offline (rp_garage is not running).") end
    if not res then return notice(playerId, false, "Flag refused: " .. tostring(why)) end
    notice(playerId, true, stolen and ("Plate %s flagged: %s. Every officer on duty got the APB."):format(plate, reason)
        or ("Plate %s cleared."):format(plate))
    log("player %d flagged plate %s wanted=%s reason=%s", playerId, plate, tostring(stolen), reason)
    audit("plate", ("plate %s wanted=%s %s"):format(plate, tostring(stolen), reason), { playerId = playerId, plate = plate })
    local results, source = searchVehicles(plate)
    send(playerId, { kind = "vehicle_search", query = plate, results = results, source = source })
end

actions.report_add = function(playerId, mode, p)
    local title = clip(p.title, Config.limits.title)
    local text = clip(p.text, Config.limits.text)
    local targetIdentifier = clip(p.targetIdentifier, 64)
    local targetName = clip(p.targetName, 80)
    if #title < 3 then return notice(playerId, false, "Give the report a title (3 characters or more).") end
    if #text < 3 then return notice(playerId, false, "The report body is empty.") end
    if targetIdentifier ~= "" then targetName = resolveTargetName(targetIdentifier) end
    local id, why = addReport(mode, playerId, targetIdentifier, targetName, title, text)
    if not id then return notice(playerId, false, "Report not saved: " .. tostring(why)) end
    notice(playerId, true, ("Report #%s filed: %s"):format(tostring(id), title))
    log("player %d filed %s report #%s: %s", playerId, mode, tostring(id), title)
    audit("report", ("%s report #%s: %s"):format(mode, tostring(id), title), { playerId = playerId, identifier = targetIdentifier ~= "" and targetIdentifier or nil })
    local rows, source = searchReports(mode, "")
    send(playerId, { kind = "reports", query = "", rows = rows, source = source })
    -- Filed from a citizen's file: refresh that file so the new report is listed on it.
    if targetIdentifier ~= "" then
        send(playerId, { kind = "citizen_card", card = buildCard(mode, targetIdentifier) })
    end
end

actions.report_search = function(playerId, mode, p)
    local query = clip(p.query, Config.limits.query)
    local rows, source = searchReports(mode, query)
    send(playerId, { kind = "reports", query = query, rows = rows, source = source })
end

actions.report_get = function(playerId, mode, p)
    local id = math.floor(tonumber(p.id) or 0)
    if id <= 0 then return notice(playerId, false, "No report selected.") end
    local row, why = getReport(mode, id)
    if not row then return notice(playerId, false, "Report not found (" .. tostring(why) .. ").") end
    send(playerId, { kind = "report", report = { id = row.id, title = row.title, text = row.text, author_name = row.author_name, target = row.target, target_name = row.target_name, at = row.at } })
end

actions.dispatch = function(playerId, mode, p)
    send(playerId, { kind = "dispatch", rows = dispatchRows(mode, playerId), keep = Config.dispatch.keep })
end

actions.medical = function(playerId, mode, p)
    if mode ~= "trauma" then return notice(playerId, false, "Medical data is Trauma Team business.") end
    send(playerId, { kind = "medical", data = medicalRows(playerId) })
end

actions.nettrace = function(playerId, mode, p)
    if not modeHasTab(mode, "nettrace") then return notice(playerId, false, "Net traces are NCPD business.") end
    local rows, source = netTraceRows()
    send(playerId, { kind = "nettrace", rows = rows or {}, source = source })
end

---------------------------------------------------------------------------
-- Transport: the page -> client -> rp_mdt:intent -> here -> rp_mdt:data
---------------------------------------------------------------------------

RegisterNetEvent("rp_mdt:intent", function(payload)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    if type(payload) ~= "table" or type(payload.action) ~= "string" then return end

    -- Putting the tablet away needs no badge.
    if payload.action == "close" then
        open[playerId] = nil
        return
    end
    -- Duty is re-checked on every other intent; a client that lost its badge is closed.
    local mode, why = resolveMode(playerId)
    if not mode then
        open[playerId] = nil
        TriggerClientEvent("rp_mdt:close", playerId)
        say(playerId, nil, dutyText[why] or "Tablet refused.")
        return
    end
    local session = open[playerId]
    if not session or session.mode ~= mode then
        TriggerClientEvent("rp_mdt:close", playerId)
        say(playerId, mode, "Open the tablet with /mdt first.")
        return
    end
    local handler = actions[payload.action]
    if not handler then return notice(playerId, false, "Unknown tablet action.") end
    handler(playerId, mode, payload)
end)

local function openTablet(playerId)
    local mode, why = resolveMode(playerId)
    if not mode then
        say(playerId, nil, dutyText[why] or "Tablet refused.")
        return
    end
    local def = Config.modes[mode]
    open[playerId] = { mode = mode, since = Open77.time.unix() }
    local okGrade, grade = call("rp_jobs", "getGrade", playerId)
    TriggerClientEvent("rp_mdt:open", playerId, {
        mode = mode,
        label = def.label,
        title = def.title,
        tabs = def.tabs,
        officer = {
            name = nameOf(playerId),
            grade = (okGrade and type(grade) == "table") and grade.label or nil,
            playerId = playerId,
        },
        store = store.mode or "loading",
        panel = Config.panel,
    })
    say(playerId, mode, ("%s tablet online. Escape or /mdt fermer to put it away."):format(def.label))
    log("player %d opened the %s tablet", playerId, mode)
end

local function closeTablet(playerId, silent)
    local was = open[playerId]
    open[playerId] = nil
    TriggerClientEvent("rp_mdt:close", playerId)
    if not silent then
        say(playerId, was and was.mode, was and "Tablet put away." or "Your tablet was not open.")
    end
end

RegisterCommand("mdt", function(source, args)
    if source == 0 then
        local n = 0
        for _ in pairs(open) do n = n + 1 end
        print(("[%s] run /mdt from the game. store=%s open tablets=%d alerts kept=%d"):format(RES, tostring(store.mode), n, #alerts))
        return
    end
    local sub = (args[1] or ""):lower()
    if sub == "" then
        openTablet(source)
    elseif sub == "fermer" or sub == "close" then
        closeTablet(source, false)
    else
        say(source, nil, "Usage: /mdt (open the tablet) or /mdt fermer (put it away).")
    end
end, false)

---------------------------------------------------------------------------
-- Bus subscriptions
---------------------------------------------------------------------------

-- rp_ncpd:alert (kind, position, text, byPlayerId): raised by rp_shops, rp_trauma (911),
-- rp_crime... Kept in memory for the Dispatch tab.
AddEventHandler("rp_ncpd:alert", function(kind, position, text, byPlayerId)
    local by = tonumber(byPlayerId)
    local pos = nil
    if type(position) == "table" then
        local x, y, z = position.x or position[1], position.y or position[2], position.z or position[3]
        if type(x) == "number" and type(y) == "number" then
            pos = { x = x, y = y, z = (type(z) == "number") and z or nil }
        end
    end
    alerts[#alerts + 1] = {
        kind = tostring(kind or "alert"),
        text = tostring(text or ""),
        position = pos,
        by = (by and by > 0) and nameOf(by) or nil,
        at = math.floor(Open77.time.unix()),
    }
    while #alerts > (Config.dispatch.keep or 20) do table.remove(alerts, 1) end
end)

-- An officer who clocks out loses the tablet at once.
AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    local id = tonumber(playerId)
    if id and open[id] and not onDuty then
        local mode = open[id].mode
        closeTablet(id, true)
        say(id, mode, "Off duty: tablet locked.")
    end
end)

AddEventHandler("rp_jobs:changed", function(playerId, jobName)
    local id = tonumber(playerId)
    if id and open[id] and Config.jobModes[jobName or ""] ~= open[id].mode then
        closeTablet(id, true)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if id then open[id] = nil end
end)

local suggestions = {
    { command = "/mdt", help = "NCPD / Trauma Team tablet (on duty)", parameters = { { name = "fermer", help = "optional: put the tablet away" } } },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, suggestions)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.chat.addSuggestions(-1, suggestions)
    log("started: modes ncpd (%d tabs) / trauma (%d tabs), panel %dx%d, dispatch keeps %d alerts, db grace %ds",
        #Config.modes.ncpd.tabs, #Config.modes.trauma.tabs, Config.panel.width, Config.panel.height,
        Config.dispatch.keep, Config.databaseGraceSeconds)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for id in pairs(open) do
        TriggerClientEvent("rp_mdt:close", id)
    end
    open = {}
end)
