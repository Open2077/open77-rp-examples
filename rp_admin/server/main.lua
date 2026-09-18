-- rp_admin - server: the admin panel (/rpadmin), its restricted slash equivalents, admin mode,
-- player reports (/report), the ticket queue (/tickets) and the action journal.
--
-- Server-authoritative: every check, every decision and every message comes from here. The
-- client only draws the [ADMIN] tag the server relays. Money, jobs, revives and records are
-- delegated to the RP resources that own them (rp_economy, rp_bank, rp_jobs, rp_trauma,
-- rp_ncpd) through exports called inside pcall, so a missing resource degrades to a chat line.

local Config = RpAdminConfig
local RESOURCE = "rp_admin"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local store = nil            -- "sql" | "kvp", decided once per boot
local tickets = {}           -- id -> ticket row (open and taken tickets only)
local nextTicketId = 1       -- kvp store only
local nextActionId = 1       -- kvp store only
local pendingActions = {}    -- actions journaled before the store was decided
local adminMode = {}         -- adminId -> true
local spectating = {}        -- adminId -> targetId
local frozenBy = {}          -- targetId -> true while THIS resource holds a freeze claim
local panelOpen = {}         -- adminId -> true while the panel is on screen

local ADMIN_COLOR = { 255, 77, 77 }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function log(fmt, ...)
    print(("[rp_admin] " .. fmt):format(...))
end

local function now()
    return math.floor(Open77.time.unix())
end

-- A positive integer session id, from a number or the string form host events deliver.
local function toId(value)
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then return nil end
    return math.floor(n)
end

local function isOnline(playerId)
    -- Open77.players.name throws (and kills the VM) for 0, negative or fractional ids.
    local id = toId(playerId)
    return id ~= nil and Open77.players.name(id) ~= nil
end

-- Strips control characters and clips to maxBytes.
local function clip(text, maxBytes)
    text = tostring(text or ""):gsub("%c", " ")
    if #text > maxBytes then text = text:sub(1, maxBytes) end
    return text
end

local function fmtMoney(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local sign = ""
    if s:sub(1, 1) == "-" then sign = "-"; s = s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
    return sign .. out .. " €$"
end

local function ago(seconds)
    seconds = math.max(0, now() - (tonumber(seconds) or 0))
    if seconds < 60 then return ("%ds ago"):format(seconds) end
    if seconds < 3600 then return ("%dm ago"):format(seconds // 60) end
    if seconds < 86400 then return ("%dh ago"):format(seconds // 3600) end
    return ("%dd ago"):format(seconds // 86400)
end

-- Chat line from "ADMIN". The console (0) reads it in the log instead.
local function say(playerId, text)
    if playerId == nil or playerId == 0 then
        print("[rp_admin] " .. text)
        return
    end
    Open77.chat.send(playerId, { author = "ADMIN", text = text, color = ADMIN_COLOR })
end

local function toast(playerId, kind, title, message)
    if not isOnline(playerId) then return end
    Open77.notifications.send(playerId, {
        type = kind,
        title = title,
        message = clip(message, 380),
        icon = "A",
        durationMs = 8000,
    })
end

-- Cross-resource call, synchronous, inside pcall: a missing resource or export raises.
-- Returns reachable(boolean), value, reason.
local function callExport(resource, name, ...)
    local args = table.pack(...)
    local ok, a, b = pcall(function()
        local proxy = exports[resource]
        return proxy[name](proxy, table.unpack(args, 1, args.n or #args))
    end)
    if not ok then
        return false, nil, resource .. "_offline"
    end
    return true, a, b
end

local function displayName(playerId)
    if playerId == 0 then return "console" end
    if not toId(playerId) then return "#" .. tostring(playerId) end
    local ok, name = callExport("rp_identity", "fullName", playerId)
    if ok and type(name) == "string" and #name > 0 then return name end
    return Open77.players.name(playerId) or ("#" .. tostring(playerId))
end

local function identifierOf(playerId)
    if playerId == nil then return "" end
    if playerId == 0 then return "console" end
    return Open77.players.identifier(playerId) or ("session:" .. tostring(playerId))
end

-- isAdmin: the ACL right Config.AdminRight (command.rpadmin) on the player's identity.
-- The console (0) is not a player for the ACL; it is allowed by the restricted commands themselves.
local function isAdmin(playerId)
    local id = toId(playerId)
    if not id then return false end
    local allowed = Open77.acl.isAllowed(id, Config.AdminRight)
    return allowed == true
end

local function onlineAdmins()
    local list = {}
    for _, id in ipairs(Open77.players.all()) do
        if isAdmin(id) then list[#list + 1] = id end
    end
    return list
end

local function playerByIdentifier(identifier)
    if not identifier or identifier == "" then return nil end
    for _, id in ipairs(Open77.players.all()) do
        if Open77.players.identifier(id) == identifier then return id end
    end
    return nil
end

-- Resolves a target argument: a connected player other than nobody.
local function resolveTarget(adminId, raw)
    local target = toId(raw)
    if not target then
        say(adminId, "Give a player id (see /players).")
        return nil
    end
    if not isOnline(target) then
        say(adminId, ("No player #%d on the server."):format(target))
        return nil
    end
    return target
end

-- ---------------------------------------------------------------------------
-- Persistence: SQL first, Open77.kvp only when the database is not there
-- ---------------------------------------------------------------------------
local SQL_TICKETS = [[
CREATE TABLE IF NOT EXISTS rp_admin_tickets (
    id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    identifier    VARCHAR(64)  NOT NULL,
    reporter_name VARCHAR(80)  NOT NULL DEFAULT '',
    `text`        VARCHAR(300) NOT NULL,
    status        VARCHAR(16)  NOT NULL DEFAULT 'open',
    taken_by      VARCHAR(64)  NOT NULL DEFAULT '',
    taken_by_name VARCHAR(80)  NOT NULL DEFAULT '',
    answer        VARCHAR(300) NOT NULL DEFAULT '',
    notified      TINYINT(1)   NOT NULL DEFAULT 0,
    created_at    BIGINT       NOT NULL DEFAULT 0,
    closed_at     BIGINT       NOT NULL DEFAULT 0,
    INDEX rp_admin_tickets_status (status),
    INDEX rp_admin_tickets_identifier (identifier)
)]]

local SQL_ACTIONS = [[
CREATE TABLE IF NOT EXISTS rp_admin_actions (
    id          INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    admin       VARCHAR(64)  NOT NULL,
    admin_name  VARCHAR(80)  NOT NULL DEFAULT '',
    action      VARCHAR(32)  NOT NULL,
    target      VARCHAR(64)  NOT NULL DEFAULT '',
    target_name VARCHAR(80)  NOT NULL DEFAULT '',
    `text`      VARCHAR(300) NOT NULL DEFAULT '',
    `at`        BIGINT       NOT NULL DEFAULT 0,
    INDEX rp_admin_actions_admin (admin),
    INDEX rp_admin_actions_target (target)
)]]

local function kvpSaveTicket(t)
    Open77.kvp.set("ticket:" .. t.id, json.encode(t))
end

local function kvpSaveOpenIndex()
    local ids = {}
    for id in pairs(tickets) do ids[#ids + 1] = id end
    table.sort(ids)
    Open77.kvp.set("tickets:open", json.encode(ids))
end

local function kvpLoad()
    nextTicketId = tonumber(Open77.kvp.get("tickets:next", 1)) or 1
    nextActionId = tonumber(Open77.kvp.get("actions:next", 1)) or 1
    local ids = json.decode(Open77.kvp.get("tickets:open", "[]") or "[]") or {}
    local count = 0
    for _, id in ipairs(ids) do
        local row = json.decode(Open77.kvp.get("ticket:" .. tostring(id), "null") or "null")
        if type(row) == "table" and row.id then
            tickets[row.id] = row
            count = count + 1
        end
    end
    return count
end

-- Journals one action: SQL row (or kvp), rp_logs when present, the rp_admin:action event.
local function writeAction(entry)
    if store == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_admin_actions (admin, admin_name, action, target, target_name, `text`, `at`) VALUES (?, ?, ?, ?, ?, ?, ?)",
            { entry.admin, entry.adminName, entry.action, entry.target, entry.targetName, entry.text, entry.at },
            function() end)
    elseif store == "kvp" then
        local id = nextActionId
        nextActionId = id + 1
        Open77.kvp.set("actions:next", nextActionId)
        Open77.kvp.set("action:" .. id, json.encode(entry))
    else
        pendingActions[#pendingActions + 1] = entry
    end
end

local function logAction(adminId, action, targetId, text)
    local entry = {
        admin = identifierOf(adminId),
        adminName = displayName(adminId),
        action = action,
        target = targetId and identifierOf(targetId) or "",
        targetName = (targetId and isOnline(targetId)) and displayName(targetId) or "",
        text = clip(text or "", 300),
        at = now(),
    }
    log("action=%s by=%s (%s) target=%s (%s) text=%s",
        action, entry.adminName, entry.admin, entry.targetName, entry.target, entry.text)
    writeAction(entry)
    local who = entry.targetName ~= "" and entry.targetName or (entry.target ~= "" and entry.target or "-")
    callExport("rp_logs", "log", "admin",
        ("%s %s -> %s: %s"):format(entry.adminName, action, who, entry.text), entry)
    TriggerEvent("rp_admin:action", adminId, action, targetId or 0, entry.text)
end

local function countOpenTickets()
    local n = 0
    for _ in pairs(tickets) do n = n + 1 end
    return n
end

local function chooseStore(kind, reason)
    if store then return end
    store = kind
    if kind == "sql" then
        log("store=sql tables=rp_admin_tickets,rp_admin_actions open_tickets=%d", countOpenTickets())
    else
        local n = kvpLoad()
        log("store=kvp reason=%s (no database: tickets and actions fall back to Open77.kvp) open_tickets=%d",
            tostring(reason), n)
    end
    for _, entry in ipairs(pendingActions) do writeAction(entry) end
    pendingActions = {}
end

local readyOk, readyReason = Open77.database.ready(function()
    if store == "kvp" then
        log("database answered late: keeping the kvp store for this boot")
        return
    end
    Open77.database.update.await(SQL_TICKETS)
    Open77.database.update.await(SQL_ACTIONS)
    local rows = Open77.database.query.await(
        "SELECT id, identifier, reporter_name, `text`, status, taken_by, taken_by_name, created_at FROM rp_admin_tickets WHERE status <> 'closed' ORDER BY id")
    for _, row in ipairs(rows or {}) do
        tickets[row.id] = row
    end
    chooseStore("sql")
end)

if not readyOk then
    chooseStore("kvp", readyReason)
else
    CreateThread(function()
        Wait(Config.DatabaseWaitMs)
        if store == nil then
            local ready, reason = Open77.database.isReady()
            if not ready then chooseStore("kvp", reason) end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Tickets
-- ---------------------------------------------------------------------------
local function openTicketList()
    local list = {}
    for _, t in pairs(tickets) do list[#list + 1] = t end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Creates a ticket; may yield (SQL insert): call from a handler, never from an export.
local function createTicket(reporterId, text)
    if store == nil then return nil, "store_not_ready" end
    local row = {
        identifier = identifierOf(reporterId),
        reporter_name = displayName(reporterId),
        text = text,
        status = "open",
        taken_by = "",
        taken_by_name = "",
        created_at = now(),
    }
    if store == "sql" then
        -- .await raises when the bridge refuses: a failed insert must answer the reporter, not kill the handler.
        local okInsert, id = pcall(function()
            return Open77.database.insert.await(
                "INSERT INTO rp_admin_tickets (identifier, reporter_name, `text`, status, created_at) VALUES (?, ?, ?, 'open', ?)",
                { row.identifier, row.reporter_name, row.text, row.created_at })
        end)
        if not okInsert then return nil, "insert_failed" end
        id = tonumber(type(id) == "table" and (id.insertId or id.id) or id)
        if not id then return nil, "insert_failed" end
        row.id = id
    else
        row.id = nextTicketId
        nextTicketId = nextTicketId + 1
        Open77.kvp.set("tickets:next", nextTicketId)
        kvpSaveTicket(row)
    end
    tickets[row.id] = row
    if store == "kvp" then kvpSaveOpenIndex() end
    return row.id
end

local function listTickets(adminId)
    local list = openTicketList()
    if #list == 0 then return say(adminId, "No open report. Night City is quiet, for once.") end
    say(adminId, ("%d open report(s):"):format(#list))
    for i = 1, math.min(#list, Config.TicketListLimit) do
        local t = list[i]
        local state = t.status == "taken" and ("taken by " .. t.taken_by_name) or "open"
        Wait(0) -- two sends in one tick arrive reversed
        say(adminId, ("  #%d [%s] %s (%s): %s"):format(t.id, state, t.reporter_name, ago(t.created_at), t.text))
    end
    if #list > Config.TicketListLimit then
        Wait(0)
        say(adminId, ("  ... and %d more."):format(#list - Config.TicketListLimit))
    end
    Wait(0)
    say(adminId, "/tickets prendre <id> to take one, /tickets fermer <id> <answer> to close it.")
end

local function takeTicket(adminId, id)
    local t = id and tickets[id]
    if not t then return say(adminId, ("No open report #%s."):format(tostring(id or "?"))) end
    local me = identifierOf(adminId)
    if t.status == "taken" and t.taken_by ~= me then
        return say(adminId, ("Report #%d is already taken by %s."):format(id, t.taken_by_name))
    end
    t.status = "taken"
    t.taken_by = me
    t.taken_by_name = displayName(adminId)
    if store == "sql" then
        Open77.database.update("UPDATE rp_admin_tickets SET status = 'taken', taken_by = ?, taken_by_name = ? WHERE id = ?",
            { t.taken_by, t.taken_by_name, id }, function() end)
    else
        kvpSaveTicket(t)
    end
    local reporter = playerByIdentifier(t.identifier)
    if reporter then
        say(reporter, ("%s is looking into your report #%d."):format(t.taken_by_name, id))
        toast(reporter, "info", ("Report #%d"):format(id), t.taken_by_name .. " is on it.")
    end
    say(adminId, ("You took report #%d from %s: %s"):format(id, t.reporter_name, t.text))
    logAction(adminId, "ticket_take", reporter, ("#%d %s"):format(id, t.text))
end

local function closeTicket(adminId, id, answer)
    local t = id and tickets[id]
    if not t then return say(adminId, ("No open report #%s."):format(tostring(id or "?"))) end
    answer = clip(answer, Config.AnswerMaxBytes)
    if #answer == 0 then return say(adminId, "Usage: /tickets fermer <id> <answer for the reporter>") end
    local reporter = playerByIdentifier(t.identifier)
    local notified = reporter and 1 or 0
    tickets[id] = nil
    if store == "sql" then
        Open77.database.update(
            "UPDATE rp_admin_tickets SET status = 'closed', answer = ?, closed_at = ?, notified = ? WHERE id = ?",
            { answer, now(), notified, id }, function() end)
    else
        t.status = "closed"
        t.answer = answer
        t.closed_at = now()
        t.notified = notified
        kvpSaveTicket(t)
        kvpSaveOpenIndex()
        if not reporter then
            local key = "pending:" .. t.identifier
            local pending = json.decode(Open77.kvp.get(key, "[]") or "[]") or {}
            pending[#pending + 1] = { id = id, answer = answer }
            Open77.kvp.set(key, json.encode(pending))
        end
    end
    if reporter then
        say(reporter, ("Your report #%d is closed. %s: %s"):format(id, displayName(adminId), answer))
        toast(reporter, "success", ("Report #%d closed"):format(id), answer)
    end
    say(adminId, ("Report #%d closed%s."):format(id, reporter and " (the reporter was told)" or " (the reporter is offline: told on their next visit)"))
    logAction(adminId, "ticket_close", reporter, ("#%d %s"):format(id, answer))
end

-- Answers left for a player while they were offline.
local function deliverPendingAnswers(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    if store == "sql" then
        -- .await raises on a bridge failure; a player joining must never trip on it.
        local okQuery, rows = pcall(function()
            return Open77.database.query.await(
                "SELECT id, answer FROM rp_admin_tickets WHERE identifier = ? AND status = 'closed' AND notified = 0 ORDER BY id",
                { identifier })
        end)
        if not okQuery or not rows or #rows == 0 then return end
        for _, row in ipairs(rows) do
            say(playerId, ("While you were away, report #%d was closed: %s"):format(row.id, row.answer))
            Wait(0)
        end
        Open77.database.update(
            "UPDATE rp_admin_tickets SET notified = 1 WHERE identifier = ? AND status = 'closed' AND notified = 0",
            { identifier }, function() end)
    elseif store == "kvp" then
        local key = "pending:" .. identifier
        local pending = json.decode(Open77.kvp.get(key, "[]") or "[]") or {}
        if #pending == 0 then return end
        for _, p in ipairs(pending) do
            say(playerId, ("While you were away, report #%d was closed: %s"):format(p.id, p.answer))
            Wait(0)
        end
        Open77.kvp.set(key, "[]")
    end
end

-- ---------------------------------------------------------------------------
-- Admin mode: [ADMIN] tag (client relay) + god mode
-- ---------------------------------------------------------------------------
local function rosterPayload()
    local list = {}
    for id in pairs(adminMode) do
        if isOnline(id) then list[#list + 1] = { id = id, name = displayName(id) } end
    end
    return list
end

local function setAdminMode(adminId, enabled)
    adminMode[adminId] = enabled or nil
    TriggerClientEvent("rp_admin:tag", -1, adminId, enabled, displayName(adminId))
    local godText = ""
    if Config.GodModeInAdminMode then
        local ok, reason = Open77.players.setGodMode(adminId, enabled)
        if ok then
            godText = enabled and " God mode on." or " God mode off."
        else
            godText = " God mode refused: " .. tostring(reason) .. "."
        end
    end
    logAction(adminId, enabled and "mode_on" or "mode_off", nil, "")
    say(adminId, (enabled and "Admin mode ON: everyone sees your [ADMIN] tag." or "Admin mode off.") .. godText)
end

-- ---------------------------------------------------------------------------
-- The actions. Each returns ok(boolean), message for the admin.
-- ---------------------------------------------------------------------------
local function actSetGrade(adminId, target, grade)
    grade = tonumber(grade)
    if not grade or grade % 1 ~= 0 or grade < 0 or grade > Config.MaxGrade then
        return false, ("Grade must be 0 to %d."):format(Config.MaxGrade)
    end
    grade = math.floor(grade)
    local reachable, job = callExport("rp_jobs", "getJob", target)
    if not reachable then return false, "rp_jobs is offline: no job file to edit." end
    local name = displayName(target)
    if not job then return false, ("%s has no job. Give one first with /setjob %d <job> %d."):format(name, target, grade) end
    local ok, reason
    reachable, ok, reason = callExport("rp_jobs", "setJob", target, job, grade)
    if not reachable then return false, "rp_jobs is offline: no job file to edit." end
    if not ok then return false, ("rp_jobs refused: %s."):format(tostring(reason)) end
    say(target, ("An admin set your %s grade to %d/%d."):format(job, grade, Config.MaxGrade))
    toast(target, "info", "Job grade", ("%s: grade %d/%d"):format(job, grade, Config.MaxGrade))
    logAction(adminId, "setgrade", target, ("%s grade %d"):format(job, grade))
    return true, ("%s is now %s grade %d/%d."):format(name, job, grade, Config.MaxGrade)
end

local function validAmount(amount)
    amount = tonumber(amount)
    if not amount or amount % 1 ~= 0 or amount < 0 or amount > Config.MaxMoney then return nil end
    return math.floor(amount)
end

local function actSetMoney(adminId, target, amount)
    amount = validAmount(amount)
    if not amount then return false, ("Amount must be a whole number between 0 and %s."):format(fmtMoney(Config.MaxMoney)) end
    local reachable, balance = callExport("rp_economy", "getBalance", target)
    if not reachable then return false, "rp_economy is offline: no wallet to set." end
    balance = math.floor(tonumber(balance) or 0)
    local delta = amount - balance
    local name = displayName(target)
    if delta ~= 0 then
        local result, reason
        if delta > 0 then
            reachable, result, reason = callExport("rp_economy", "add", target, delta, "admin:setmoney")
        else
            reachable, result, reason = callExport("rp_economy", "remove", target, -delta, "admin:setmoney")
        end
        if not reachable then return false, "rp_economy is offline: no wallet to set." end
        if result == nil then return false, ("rp_economy refused: %s."):format(tostring(reason)) end
        say(target, ("An admin set your cash to %s (%s%s)."):format(fmtMoney(amount), delta > 0 and "+" or "", fmtMoney(delta)))
        toast(target, "info", "Cash", ("Now %s"):format(fmtMoney(amount)))
    end
    logAction(adminId, "setmoney", target, ("%d (was %d)"):format(amount, balance))
    return true, ("%s: cash %s -> %s."):format(name, fmtMoney(balance), fmtMoney(amount))
end

-- The bank only moves money between cash and the account (deposit / withdraw), so a change of
-- the account balance is a cash delta from rp_economy followed by the matching bank move, and
-- the first step is rolled back when the second refuses.
local function actSetBank(adminId, target, amount)
    amount = validAmount(amount)
    if not amount then return false, ("Amount must be a whole number between 0 and %s."):format(fmtMoney(Config.MaxMoney)) end
    local reachable, account, reason = callExport("rp_bank", "getAccount", target)
    if not reachable then return false, "rp_bank is offline: no account to set." end
    if not account then return false, ("rp_bank refused: %s."):format(tostring(reason)) end
    local balance = math.floor(tonumber(account.balance) or 0)
    local delta = amount - balance
    local name = displayName(target)
    if delta > 0 then
        local added
        reachable, added, reason = callExport("rp_economy", "add", target, delta, "admin:setbank")
        if not reachable then return false, "rp_economy is offline: the bank cannot be credited without a wallet." end
        if added == nil then return false, ("rp_economy refused: %s."):format(tostring(reason)) end
        local deposited
        reachable, deposited, reason = callExport("rp_bank", "deposit", target, delta)
        if not reachable or deposited == nil then
            callExport("rp_economy", "remove", target, delta, "admin:setbank_rollback")
            return false, ("rp_bank refused the deposit: %s."):format(tostring(reason or "rp_bank_offline"))
        end
    elseif delta < 0 then
        local withdrawn
        reachable, withdrawn, reason = callExport("rp_bank", "withdraw", target, -delta)
        if not reachable then return false, "rp_bank is offline: no account to set." end
        if withdrawn == nil then return false, ("rp_bank refused the withdrawal: %s."):format(tostring(reason)) end
        local removed
        reachable, removed, reason = callExport("rp_economy", "remove", target, -delta, "admin:setbank")
        if not reachable or removed == nil then
            callExport("rp_bank", "deposit", target, -delta)
            return false, ("rp_economy refused: %s."):format(tostring(reason or "rp_economy_offline"))
        end
    end
    if delta ~= 0 then
        say(target, ("An admin set your bank account to %s (%s%s)."):format(fmtMoney(amount), delta > 0 and "+" or "", fmtMoney(delta)))
        toast(target, "info", "NC Bank", ("Account now %s"):format(fmtMoney(amount)))
    end
    logAction(adminId, "setbank", target, ("%d (was %d)"):format(amount, balance))
    return true, ("%s: account %s -> %s."):format(name, fmtMoney(balance), fmtMoney(amount))
end

local function actWarn(adminId, target, text)
    text = clip(text, Config.WarnMaxBytes)
    if #text == 0 then return false, "Give the warning text." end
    say(target, ("[WARNING] %s. Next time it is a kick, choom."):format(text))
    toast(target, "warning", "Admin warning", text)
    logAction(adminId, "warn", target, text)
    return true, ("Warned %s: %s"):format(displayName(target), text)
end

local function actFreeze(adminId, target)
    local name = displayName(target)
    if frozenBy[target] then
        local ok, reason = Open77.players.setFrozen(target, false)
        if not ok then return false, ("Thaw refused: %s."):format(tostring(reason)) end
        frozenBy[target] = nil
        logAction(adminId, "unfreeze", target, "")
        say(target, "An admin released you. Move along.")
        if Open77.players.isFrozen(target) then
            return true, ("%s: your hold is released, but another script still holds them (cuffs, a down state...)."):format(name)
        end
        return true, ("%s is free to move again."):format(name)
    end
    local already = Open77.players.isFrozen(target)
    local ok, reason = Open77.players.setFrozen(target, true)
    if not ok then return false, ("Freeze refused: %s."):format(tostring(reason)) end
    frozenBy[target] = true
    logAction(adminId, "freeze", target, "")
    say(target, "An admin froze you in place. Stay put and answer in chat.")
    toast(target, "warning", "Frozen", "An admin holds you in place.")
    return true, ("%s is frozen%s. Run it again to release."):format(name, already and " (another script already held them)" or "")
end

local function actSpectate(adminId, target)
    if adminId == 0 then return false, "Spectate needs a body: run it from the game." end
    if not target then
        if not spectating[adminId] then return false, "You are not spectating anyone." end
        local watched = spectating[adminId]
        local ok, reason = Open77.players.spectate(adminId, false)
        spectating[adminId] = nil
        if not ok then return false, ("Stop refused: %s."):format(tostring(reason)) end
        logAction(adminId, "spectate_stop", watched, "")
        return true, "Back in your own body."
    end
    if target == adminId then return false, "You cannot spectate yourself." end
    local ok, reason = Open77.players.spectate(adminId, target, Config.Spectate)
    if not ok then return false, ("Spectate refused: %s."):format(tostring(reason)) end
    spectating[adminId] = target
    -- The world streams around the spectator's own body: move the ghost next to the target.
    local pos = Open77.players.position(target)
    if pos then
        local pending = Open77.players.teleport(adminId, { x = pos.x, y = pos.y, z = pos.z }, { bucket = pos.bucket, fade = false })
        if pending then
            CreateThread(function()
                local landed, err = pending:await()
                if not landed then log("spectate: ghost teleport failed for %d: %s", adminId, tostring(err)) end
            end)
        end
    end
    logAction(adminId, "spectate", target, "")
    return true, ("Spectating %s. /spectate alone (or the panel) to stop; use it again if they travel far."):format(displayName(target))
end

-- verb: "goto" (the admin joins the target) or "bring" (the target joins the admin).
local function actTeleport(adminId, target, verb)
    if adminId == 0 then return false, "Teleports need your body: run it from the game." end
    if target == adminId then return false, "That is you." end
    local mover, anchor = adminId, target
    if verb == "bring" then mover, anchor = target, adminId end
    local pos = Open77.players.position(anchor)
    if not pos then return false, ("Unknown position for %s."):format(displayName(anchor)) end
    local dest = { x = pos.x + Config.TeleportOffset, y = pos.y, z = pos.z }
    local pending, reason = Open77.players.teleport(mover, dest, { bucket = pos.bucket, dismount = true })
    if not pending then return false, ("Teleport refused: %s."):format(tostring(reason)) end
    local landed, err = pending:await()
    if not landed then return false, ("Teleport failed: %s."):format(tostring(err)) end
    logAction(adminId, verb, target, ("%.1f %.1f %.1f"):format(dest.x, dest.y, dest.z))
    if verb == "bring" then
        say(target, "An admin brought you to them.")
        return true, ("%s is beside you (%s)."):format(displayName(target), landed.state or "arrived")
    end
    return true, ("You are beside %s (%s)."):format(displayName(target), landed.state or "arrived")
end

local function actRevive(adminId, target)
    local name = displayName(target)
    local reachable, ok, reason = callExport("rp_trauma", "revive", target, adminId ~= 0 and adminId or nil)
    if reachable then
        if not ok then
            if reason == "patient_not_down" then return false, ("%s is not down."):format(name) end
            return false, ("Trauma Team refused: %s."):format(tostring(reason))
        end
        logAction(adminId, "revive", target, "rp_trauma")
        return true, ("%s is back on their feet (Trauma Team)."):format(name)
    end
    -- rp_trauma is not running: the platform revive, where they fell.
    if not Open77.players.isDead(target) then return false, ("%s is not dead."):format(name) end
    ok, reason = Open77.players.revive(target, { health = 1.0, graceMs = 3000 })
    if not ok then return false, ("Revive refused: %s."):format(tostring(reason)) end
    say(target, "An admin revived you.")
    logAction(adminId, "revive", target, "platform")
    return true, ("%s is back on their feet (rp_trauma offline: platform revive)."):format(name)
end

local function actRecord(adminId, target)
    local name = displayName(target)
    local reachable, rec = callExport("rp_ncpd", "record", target)
    if not reachable then return false, "rp_ncpd is offline: no criminal records." end
    local entries = type(rec) == "table" and rec.entries or {}
    logAction(adminId, "record", target, ("%d entries"):format(#entries))
    if #entries == 0 then return true, ("%s has a clean record."):format(name) end
    local shown = math.min(#entries, Config.RecordLines)
    say(adminId, ("Record of %s: %d entries, last %d:"):format(name, #entries, shown))
    for i = 1, shown do
        local e = entries[i]
        Wait(0)
        say(adminId, ("  %s [%s] %s - %s"):format(tostring(e.date or ""), string.upper(tostring(e.kind or "")),
            tostring(e.text or ""), tostring(e.officer or "")))
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- The panel (UI kit server twins: context and input)
-- ---------------------------------------------------------------------------
local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Asks one number; returns the number, or nil and "cancelled" / "timeout" / a refusal.
local function askNumber(adminId, title, description, label, min, max)
    local answer, reason = uikit("input", adminId, {
        title = title,
        description = description,
        fields = { { id = "value", type = "number", label = label, min = min, max = max, required = true } },
        confirm = "Apply",
        cancel = "Back",
        timeoutMs = Config.PanelTimeoutMs,
    })
    if answer == nil then return nil, tostring(reason) end
    if not answer.ok then return nil, answer.outcome end
    return tonumber(answer.value and answer.value.value), nil
end

local function askText(adminId, title, description, label, max)
    local answer, reason = uikit("input", adminId, {
        title = title,
        description = description,
        fields = { { id = "text", type = "textarea", label = label, max = max, required = true } },
        confirm = "Send",
        cancel = "Back",
        timeoutMs = Config.PanelTimeoutMs,
    })
    if answer == nil then return nil, tostring(reason) end
    if not answer.ok then return nil, answer.outcome end
    return answer.value and answer.value.text, nil
end

local function playerSummary(id)
    local _, job = callExport("rp_jobs", "getJob", id)
    local _, grade = callExport("rp_jobs", "getGrade", id)
    local _, cash = callExport("rp_economy", "getBalance", id)
    local _, account = callExport("rp_bank", "getAccount", id)
    local _, zone = callExport("rp_zones", "zoneOf", id)
    local jobText = job and (type(grade) == "table" and ("%s %d/%d"):format(job, grade.level or 0, Config.MaxGrade) or job) or "no job"
    return {
        job = jobText,
        cash = fmtMoney(cash or 0),
        bank = type(account) == "table" and fmtMoney(account.balance or 0) or "-",
        zone = type(zone) == "table" and (zone.label or zone.name) or "-",
    }
end

local function rootMenu(adminId)
    local options = {}
    local all = Open77.players.all()
    for i = 1, math.min(#all, Config.MenuPlayers) do
        local id = all[i]
        local s = playerSummary(id)
        options[#options + 1] = {
            id = "p:" .. id,
            label = ("%s  #%d%s"):format(displayName(id), id, id == adminId and " (you)" or ""),
            description = ("%s · %s cash · %s"):format(s.job, s.cash, s.zone),
            metadata = {
                { label = "Job", value = s.job },
                { label = "Cash", value = s.cash },
                { label = "Bank", value = s.bank },
                { label = "Zone", value = s.zone },
            },
        }
    end
    options[#options + 1] = { id = "tickets", label = ("Reports: %d open"):format(countOpenTickets()), icon = "R",
        description = "Take or close a ticket." }
    options[#options + 1] = { id = "mode", icon = "M",
        label = adminMode[adminId] and "Admin mode: ON" or "Admin mode: off",
        description = adminMode[adminId] and "Hide the [ADMIN] tag and drop god mode." or "Show the [ADMIN] tag to everyone, god mode on.",
        tone = adminMode[adminId] and "success" or nil }
    if spectating[adminId] then
        options[#options + 1] = { id = "stopspectate", label = "Stop spectating", icon = "S", tone = "danger" }
    end
    return {
        id = "rp_admin_root",
        title = "Admin panel",
        description = ("%d player(s) online. Pick one."):format(#all),
        options = options,
    }
end

local function playerMenu(adminId, target)
    local s = playerSummary(target)
    local frozen = frozenBy[target] == true
    return {
        id = "rp_admin_player",
        title = ("%s  #%d"):format(displayName(target), target),
        description = ("%s · cash %s · bank %s · %s"):format(s.job, s.cash, s.bank, s.zone),
        options = {
            { id = "setgrade", label = "Set grade", icon = "G", description = "Job grade 0-3 (rp_jobs)." },
            { id = "setmoney", label = "Set cash", icon = "C", description = "Cash in hand (rp_economy)." },
            { id = "setbank", label = "Set bank account", icon = "K", description = "Account balance (rp_bank)." },
            { id = "warn", label = "Warn", icon = "W", description = "A warning in their chat and a toast." },
            { id = "freeze", label = frozen and "Thaw" or "Freeze", icon = "F", tone = frozen and "success" or "danger",
              description = frozen and "Release your hold." or "Hold them where they stand." },
            { id = "spectate", label = "Spectate", icon = "S", description = "Ghost behind their shoulder.", disabled = target == adminId },
            { id = "revive", label = "Revive", icon = "R", description = "Trauma Team revive." },
            { id = "goto", label = "Teleport to", icon = "T", description = "Move yourself beside them.", disabled = target == adminId },
            { id = "bring", label = "Bring here", icon = "H", description = "Move them beside you.", disabled = target == adminId },
            { id = "record", label = "Criminal record", icon = "N", description = "NCPD file (rp_ncpd)." },
            { id = "back", label = "Back", icon = "B" },
        },
    }
end

local function report(adminId, ok, message)
    if message then say(adminId, message) end
    if ok and message then toast(adminId, "success", "Admin", message) elseif not ok and message then toast(adminId, "error", "Admin", message) end
end

-- Runs one action picked in the player menu. Returns false when the whole panel must close.
local function runPlayerAction(adminId, target, action)
    if not isOnline(target) then
        say(adminId, "That player left.")
        return true
    end
    local s = playerSummary(target)
    if action == "setgrade" then
        local grade, why = askNumber(adminId, "Set grade", ("%s: %s"):format(displayName(target), s.job), ("Grade 0-%d"):format(Config.MaxGrade), 0, Config.MaxGrade)
        if grade == nil then return why ~= "timeout" end
        report(adminId, actSetGrade(adminId, target, grade))
    elseif action == "setmoney" then
        local amount, why = askNumber(adminId, "Set cash", ("%s has %s in hand."):format(displayName(target), s.cash), "New cash amount", 0, Config.MaxMoney)
        if amount == nil then return why ~= "timeout" end
        report(adminId, actSetMoney(adminId, target, amount))
    elseif action == "setbank" then
        local amount, why = askNumber(adminId, "Set bank account", ("%s's account holds %s."):format(displayName(target), s.bank), "New account balance", 0, Config.MaxMoney)
        if amount == nil then return why ~= "timeout" end
        report(adminId, actSetBank(adminId, target, amount))
    elseif action == "warn" then
        local text, why = askText(adminId, "Warn " .. displayName(target), "They read it in chat and as a toast. It is journaled.", "Warning", Config.WarnMaxBytes)
        if text == nil then return why ~= "timeout" end
        report(adminId, actWarn(adminId, target, text))
    elseif action == "freeze" then
        report(adminId, actFreeze(adminId, target))
    elseif action == "spectate" then
        report(adminId, actSpectate(adminId, target))
        return false -- the camera is on the target now: close the panel
    elseif action == "revive" then
        report(adminId, actRevive(adminId, target))
    elseif action == "goto" then
        report(adminId, actTeleport(adminId, target, "goto"))
    elseif action == "bring" then
        report(adminId, actTeleport(adminId, target, "bring"))
    elseif action == "record" then
        report(adminId, actRecord(adminId, target))
    end
    return true
end

local function ticketsMenu(adminId)
    local list = openTicketList()
    local options = {}
    for i = 1, math.min(#list, 60) do
        local t = list[i]
        options[#options + 1] = {
            id = "t:" .. t.id,
            label = ("#%d %s (%s)"):format(t.id, t.reporter_name, ago(t.created_at)),
            description = t.text,
            tone = t.status == "taken" and "success" or nil,
            metadata = { { label = "Status", value = t.status == "taken" and ("taken by " .. t.taken_by_name) or "open" } },
        }
    end
    options[#options + 1] = { id = "back", label = "Back", icon = "B" }
    return { id = "rp_admin_tickets", title = "Reports", description = ("%d open."):format(#list), options = options }
end

-- Returns false when the whole panel must close (Escape / timeout / no answer).
local function ticketsPanel(adminId)
    while true do
        local answer, reason = uikit("context", adminId, ticketsMenu(adminId), { timeoutMs = Config.PanelTimeoutMs })
        if answer == nil then say(adminId, "Panel unavailable: " .. tostring(reason)); return false end
        if not answer.ok then return false end
        local pick = answer.value and answer.value.id or "back"
        if pick == "back" then return true end
        local id = toId(pick:sub(3))
        local t = id and tickets[id]
        if t then
            local act
            act, reason = uikit("context", adminId, {
                id = "rp_admin_ticket",
                title = ("Report #%d"):format(id),
                description = ("%s, %s: %s"):format(t.reporter_name, ago(t.created_at), t.text),
                options = {
                    { id = "take", label = "Take it", icon = "T", description = "Tell the reporter you are on it." },
                    { id = "close", label = "Close with an answer", icon = "C", tone = "danger" },
                    { id = "back", label = "Back", icon = "B" },
                },
            }, { timeoutMs = Config.PanelTimeoutMs })
            if act == nil then say(adminId, "Panel unavailable: " .. tostring(reason)); return false end
            if not act.ok then return false end
            local verb = act.value and act.value.id
            if verb == "take" then
                takeTicket(adminId, id)
            elseif verb == "close" then
                local text, why = askText(adminId, ("Close report #%d"):format(id), t.text, "Answer for the reporter", Config.AnswerMaxBytes)
                if text == nil and why == "timeout" then return false end
                if text then closeTicket(adminId, id, text) end
            end
        end
    end
end

local function openPanel(adminId)
    if panelOpen[adminId] then return say(adminId, "The panel is already open.") end
    panelOpen[adminId] = true
    local ok, err = pcall(function()
        while true do
            local answer, reason = uikit("context", adminId, rootMenu(adminId), { timeoutMs = Config.PanelTimeoutMs })
            if answer == nil then say(adminId, "Panel unavailable: " .. tostring(reason)); return end
            if not answer.ok then return end
            local pick = answer.value and answer.value.id or ""
            if pick == "mode" then
                setAdminMode(adminId, not adminMode[adminId])
            elseif pick == "tickets" then
                if not ticketsPanel(adminId) then return end
            elseif pick == "stopspectate" then
                report(adminId, actSpectate(adminId, nil))
            elseif pick:sub(1, 2) == "p:" then
                local target = toId(pick:sub(3))
                while target and isOnline(target) do
                    local pa
                    pa, reason = uikit("context", adminId, playerMenu(adminId, target), { timeoutMs = Config.PanelTimeoutMs })
                    if pa == nil then say(adminId, "Panel unavailable: " .. tostring(reason)); return end
                    if not pa.ok then return end
                    local action = pa.value and pa.value.id or "back"
                    if action == "back" then break end
                    if not runPlayerAction(adminId, target, action) then return end
                end
            end
        end
    end)
    panelOpen[adminId] = nil
    if not ok then log("panel error for %d: %s", adminId, tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
-- Restricted (RegisterCommand ..., true): the platform refuses a player without the ACL right
-- command.<name> before the handler runs; the dedicated console (source 0) is always allowed.

RegisterCommand("rpadmin", function(source, args)
    local sub = args[1] and args[1]:lower() or nil
    if sub == "mode" then
        if source == 0 then return print("[rp_admin] admin mode needs a body: run /rpadmin mode from the game") end
        return setAdminMode(source, not adminMode[source])
    end
    if source == 0 then
        return print("[rp_admin] the panel needs a client. From this console: tickets, setgrade, setmoney, setbank, warn, freeze")
    end
    if not isAdmin(source) then return say(source, "Admins only.") end
    openPanel(source)
end, true)

RegisterCommand("setgrade", function(source, args)
    local target = resolveTarget(source, args[1])
    if not target then return end
    if args[2] == nil then return say(source, ("Usage: /setgrade <playerId> <0-%d>"):format(Config.MaxGrade)) end
    report(source, actSetGrade(source, target, args[2]))
end, true)

RegisterCommand("setmoney", function(source, args)
    local target = resolveTarget(source, args[1])
    if not target then return end
    if args[2] == nil then return say(source, "Usage: /setmoney <playerId> <amount>") end
    report(source, actSetMoney(source, target, args[2]))
end, true)

RegisterCommand("setbank", function(source, args)
    local target = resolveTarget(source, args[1])
    if not target then return end
    if args[2] == nil then return say(source, "Usage: /setbank <playerId> <amount>") end
    report(source, actSetBank(source, target, args[2]))
end, true)

RegisterCommand("warn", function(source, args)
    local target = resolveTarget(source, args[1])
    if not target then return end
    local text = table.concat(args, " ", 2, args.n or #args)
    if #text == 0 then return say(source, "Usage: /warn <playerId> <text>") end
    report(source, actWarn(source, target, text))
end, true)

RegisterCommand("freeze", function(source, args)
    local target = resolveTarget(source, args[1])
    if not target then return end
    report(source, actFreeze(source, target))
end, true)

RegisterCommand("spectate", function(source, args)
    if source == 0 then return print("[rp_admin] spectate needs a body: run it from the game") end
    if args[1] == nil then return report(source, actSpectate(source, nil)) end
    local target = resolveTarget(source, args[1])
    if not target then return end
    report(source, actSpectate(source, target))
end, true)

RegisterCommand("tickets", function(source, args)
    local sub = args[1] and args[1]:lower() or nil
    if sub == nil or sub == "list" then
        return listTickets(source)
    elseif sub == "prendre" then
        return takeTicket(source, toId(args[2]))
    elseif sub == "fermer" then
        return closeTicket(source, toId(args[2]), table.concat(args, " ", 3, args.n or #args))
    end
    say(source, "Usage: /tickets | /tickets prendre <id> | /tickets fermer <id> <answer>")
end, true)

-- Anyone: files a report for the admins.
RegisterCommand("report", function(source, args)
    if source == 0 then return print("[rp_admin] report: run it from the game (the console has nobody to report)") end
    local text = clip(table.concat(args, " ", 1, args.n or #args), Config.ReportMaxBytes)
    if #text < 3 then return say(source, "Usage: /report <what happened>. An admin will read it.") end
    local id, reason = createTicket(source, text)
    if not id then return say(source, ("Report refused: %s. Try again in a moment."):format(tostring(reason))) end
    local name = displayName(source)
    say(source, ("Report #%d filed. An admin will get back to you, choom."):format(id))
    local admins = onlineAdmins()
    for _, a in ipairs(admins) do
        toast(a, "warning", ("Report #%d"):format(id), ("%s: %s"):format(name, text))
        say(a, ("[REPORT #%d] %s: %s   (/tickets prendre %d)"):format(id, name, text, id))
    end
    if #admins == 0 then say(source, "No admin online right now: your report is saved for them.") end
    log("report #%d by %s (%s): %s (admins told: %d)", id, name, identifierOf(source), text, #admins)
    callExport("rp_logs", "log", "report", ("#%d %s: %s"):format(id, name, text),
        { ticket = id, identifier = identifierOf(source), name = name, at = now() })
end, false)

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
-- isAdmin(playerId) -> boolean. Synchronous, never yields (Open77.acl.isAllowed is a read).
exports("isAdmin", function(playerId)
    return isAdmin(playerId)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local SUGGESTIONS = {
    { command = "/rpadmin", help = "Admin panel; /rpadmin mode toggles the [ADMIN] tag and god mode (admins)" },
    { command = "/setgrade", help = "Admin: set a player's job grade", parameters = { { name = "playerId", help = "session id" }, { name = "grade", help = "0-3" } } },
    { command = "/setmoney", help = "Admin: set a player's cash", parameters = { { name = "playerId", help = "session id" }, { name = "amount", help = "eddies" } } },
    { command = "/setbank", help = "Admin: set a player's bank account", parameters = { { name = "playerId", help = "session id" }, { name = "amount", help = "eddies" } } },
    { command = "/warn", help = "Admin: warn a player", parameters = { { name = "playerId", help = "session id" }, { name = "text", help = "the warning" } } },
    { command = "/freeze", help = "Admin: freeze / thaw a player", parameters = { { name = "playerId", help = "session id" } } },
    { command = "/spectate", help = "Admin: watch a player; alone to stop", parameters = { { name = "playerId", help = "session id" } } },
    { command = "/report", help = "Report a problem or a player to the admins", parameters = { { name = "text", help = "what happened" } } },
    { command = "/tickets", help = "Admin: open reports; prendre <id> / fermer <id> <answer>" },
}

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    log("started: admin right %s, panel timeout %d s, god mode in admin mode: %s",
        Config.AdminRight, Config.PanelTimeoutMs // 1000, tostring(Config.GodModeInAdminMode))
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
end)

RegisterNetEvent("chat:ready", function()
    if source and source ~= 0 then Open77.chat.addSuggestions(source, SUGGESTIONS) end
end)

-- A client asks for the admins currently in admin mode (its start, or a hot reload).
RegisterNetEvent("rp_admin:clientReady", function()
    if source and source ~= 0 then TriggerClientEvent("rp_admin:roster", source, rosterPayload()) end
end)

AddEventHandler("onPlayerReady", function(playerId)
    local id = toId(playerId)
    if not id then return end
    -- The store may still be undecided during the first seconds of a boot.
    local waited = 0
    while store == nil and waited < Config.DatabaseWaitMs + 2000 do
        Wait(500)
        waited = waited + 500
    end
    if not isOnline(id) then return end
    deliverPendingAnswers(id)
    if isAdmin(id) then
        local open = countOpenTickets()
        if open > 0 then say(id, ("%d open report(s) are waiting: /tickets"):format(open)) end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = toId(playerId)
    if not id then return end
    if adminMode[id] then
        adminMode[id] = nil
        TriggerClientEvent("rp_admin:tag", -1, id, false, "")
    end
    spectating[id] = nil
    frozenBy[id] = nil
    panelOpen[id] = nil
    for admin, target in pairs(spectating) do
        if target == id then spectating[admin] = nil end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    for id in pairs(adminMode) do
        if Config.GodModeInAdminMode and isOnline(id) then Open77.players.setGodMode(id, false) end
    end
    for admin in pairs(spectating) do
        if isOnline(admin) then Open77.players.spectate(admin, false) end
    end
    for target in pairs(frozenBy) do
        if isOnline(target) then Open77.players.setFrozen(target, false) end
    end
    adminMode, spectating, frozenBy, panelOpen = {}, {}, {}, {}
end)
