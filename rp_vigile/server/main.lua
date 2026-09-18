-- rp_vigile: private security for a Night City RP server.
--
-- Guard contracts for a place (a zone from rp_zones) or a person (a bodyguard),
-- paid per guarded minute. Everything is decided here: who may take a contract,
-- whether a minute counts, who pays whom, what a guard may do inside the zone.
-- Clients only render the ALT+click actions and send requests.
--
-- Money flow (VigileConfig.ratePerMinute = 20 €$, societyShare = 20 %):
--   zone contract, society client : societyRemove(<job>, 20)  -> guard +16 cash, `vigile` society +4
--   zone contract, corpo           : platform prints           -> guard +16 cash, `vigile` society +4
--   person contract                : charge(client, minutes*20, "vigile") at posting (escrow in the
--                                    `vigile` society), each paid minute societyRemove("vigile", 16)
--                                    -> guard +16 cash; unpaid minutes are refunded in cash on /garde fin
--
-- Cross-resource exports are reached through pcall (Open77.exports.callSync
-- raises when the provider is away); every refusal reaches the player in chat.

local RESOURCE = GetCurrentResourceName()
local C = VigileConfig
local SOCIETY = C.societyName
local RATE = math.floor(C.ratePerMinute)
local CUT = math.floor(RATE * C.societyShare)
local GUARD_SHARE = RATE - CUT

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_vigile] " .. fmt):format(...))
end

local function now()
    return math.floor(Open77.time.unix())
end

-- A player id from a command argument or a client payload: a positive integer, or nil.
-- Open77.players.* raise on 0, a negative or a non-integer id, so nothing else reaches them.
local function toId(value)
    local id = math.tointeger(tonumber(value))
    if not id or id < 1 then return nil end
    return id
end

local function fmtMoney(n)
    n = math.floor(n or 0)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^%s+", "")) .. " €$"
end

local function say(playerId, text)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then return end
    Open77.chat.send(playerId, { author = C.chatAuthor, text = text, color = C.chatColor })
end

-- Several lines that must read in order: one tick apart (see the chat guide).
local function sayLines(playerId, lines)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then return end
    CreateThread(function()
        for _, line in ipairs(lines) do
            say(playerId, line)
            Wait(0)
        end
    end)
end

-- Synchronous cross-resource call. `nil, "unavailable:<resource>"` when the
-- provider is not running or the export is missing; otherwise its own values.
local function callExport(resource, name, ...)
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, "unavailable:" .. resource end
    return a, b
end

local function playerName(playerId)
    playerId = tonumber(playerId)
    if not playerId then return "somebody" end
    local full = callExport("rp_identity", "fullName", playerId)
    if type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(playerId) or ("citizen #" .. playerId)
end

local function playerOnline(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then return false end
    local read = Open77.players.get(playerId)
    return read ~= nil and read.ready ~= false
end

local function isVigile(playerId)
    local has = callExport("rp_jobs", "hasJob", playerId, "vigile")
    return has == true
end

local function onDuty(playerId)
    local duty = callExport("rp_jobs", "onDuty", playerId)
    return duty == true
end

local function hasJob(playerId, job)
    local has = callExport("rp_jobs", "hasJob", playerId, job)
    return has == true
end

local function isNcpdOnDuty(playerId)
    local duty = callExport("rp_ncpd", "isOnDuty", playerId)
    if duty == true then return true end
    return hasJob(playerId, "ncpd") and onDuty(playerId)
end

local function zoneIsIn(playerId, zone)
    local inside = callExport("rp_zones", "isIn", playerId, zone)
    return inside == true
end

local function zoneLabel(zone)
    local list = callExport("rp_zones", "list")
    if type(list) == "table" then
        for _, z in ipairs(list) do
            if z.name == zone then return z.label or zone end
        end
    end
    return zone
end

local function zoneKnown(zone)
    local list, reason = callExport("rp_zones", "list")
    if type(list) ~= "table" then return nil, reason or "zones_unavailable" end
    for _, z in ipairs(list) do
        if z.name == zone then return true end
    end
    return false
end

local function jobLabel(job)
    local labels = { ncpd = "NCPD", trauma = "Trauma Team", delamain = "Delamain", mecano = "the mechanics",
        ripper = "the ripperdoc", nomade = "the nomads", ferrailleur = "the scrappers", barman = "the bar",
        fixer = "the fixer", netrunner = "the netrunners", vigile = "the security company" }
    return labels[job] or job
end

---------------------------------------------------------------------------
-- Store: SQL first, kvp only when the database never answers
---------------------------------------------------------------------------

local store = { mode = nil, ready = false, nextId = 1 }   -- mode: "sql" | "kvp"

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS rp_vigile_contracts (
    id                   INT UNSIGNED NOT NULL PRIMARY KEY,
    kind                 VARCHAR(8)   NOT NULL,
    zone                 VARCHAR(32)  NOT NULL DEFAULT '',
    payer                VARCHAR(48)  NOT NULL DEFAULT '',
    guard_identifier     VARCHAR(64)  NOT NULL DEFAULT '',
    client_identifier    VARCHAR(64)  NOT NULL DEFAULT '',
    protected_identifier VARCHAR(64)  NOT NULL DEFAULT '',
    minutes              INT          NOT NULL DEFAULT 0,
    rate                 INT          NOT NULL DEFAULT 0,
    paid_minutes         INT          NOT NULL DEFAULT 0,
    fee                  INT          NOT NULL DEFAULT 0,
    earned               INT          NOT NULL DEFAULT 0,
    society_cut          INT          NOT NULL DEFAULT 0,
    refund_due           INT          NOT NULL DEFAULT 0,
    state                VARCHAR(8)   NOT NULL DEFAULT 'open',
    end_reason           VARCHAR(32)  NOT NULL DEFAULT '',
    posted_at            BIGINT       NOT NULL DEFAULT 0,
    started_at           BIGINT       NOT NULL DEFAULT 0,
    ended_at             BIGINT       NOT NULL DEFAULT 0,
    INDEX rp_vigile_client_refund (client_identifier, refund_due)
)
]]

local function allocateId()
    local id = store.nextId
    store.nextId = id + 1
    if store.mode == "kvp" then Open77.kvp.set("next_id", store.nextId) end
    return id
end

-- Write-through: callback forms only, so the exports never yield.
local function persistInsert(c)
    if store.mode == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_vigile_contracts (id, kind, zone, payer, guard_identifier, client_identifier, protected_identifier, minutes, rate, paid_minutes, fee, earned, society_cut, refund_due, state, end_reason, posted_at, started_at, ended_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            { c.id, c.kind, c.zone or "", c.payer, c.guardIdentifier or "", c.clientIdentifier or "",
              c.protectedIdentifier or "", c.minutes, c.rate, c.paidMinutes, c.fee, c.earned, c.societyCut,
              c.refundDue, c.state, c.endReason or "", c.postedAt, c.startedAt or 0, c.endedAt or 0 })
    elseif store.mode == "kvp" then
        Open77.kvp.set("contract:" .. c.id, json.encode({
            id = c.id, kind = c.kind, zone = c.zone, payer = c.payer, state = c.state, minutes = c.minutes,
            rate = c.rate, paidMinutes = c.paidMinutes, fee = c.fee, earned = c.earned, refundDue = c.refundDue,
            endReason = c.endReason, clientIdentifier = c.clientIdentifier, guardIdentifier = c.guardIdentifier,
        }) or "{}")
    end
end

local function persistUpdate(c)
    if store.mode == "sql" then
        Open77.database.update(
            "UPDATE rp_vigile_contracts SET guard_identifier = ?, paid_minutes = ?, earned = ?, society_cut = ?, refund_due = ?, state = ?, end_reason = ?, started_at = ?, ended_at = ? WHERE id = ?",
            { c.guardIdentifier or "", c.paidMinutes, c.earned, c.societyCut, c.refundDue, c.state,
              c.endReason or "", c.startedAt or 0, c.endedAt or 0, c.id })
    elseif store.mode == "kvp" then
        persistInsert(c)
    end
end

-- A refund the client could not receive now (offline): kept until they are back.
local function persistRefundDue(c)
    if store.mode == "kvp" then
        local key = "refund:" .. (c.clientIdentifier or "")
        Open77.kvp.set(key, (Open77.kvp.get(key, 0) or 0) + c.refundDue)
    end
    persistUpdate(c)
end

local function useKvp(reason)
    if store.mode then return end
    store.mode = "kvp"
    store.nextId = tonumber(Open77.kvp.get("next_id", 1)) or 1
    store.ready = true
    log("store=kvp reason=%s (contracts are kept in the resource kvp store, not in SQL)", tostring(reason))
end

local function useSql()
    if store.mode then return end
    store.mode = "sql"
    CreateThread(function()
        -- `.await` raises on failure; without the pcall the desk would stay "booting" forever.
        local ok, err = pcall(function()
            Open77.database.update.await(SCHEMA)
            local maxId = Open77.database.scalar.await("SELECT MAX(id) FROM rp_vigile_contracts")
            store.nextId = (tonumber(maxId) or 0) + 1
            -- Contracts left open or active by a previous boot are over; a bodyguard
            -- escrow that was never spent goes back to the client when they return.
            local t = now()
            Open77.database.update.await(
                "UPDATE rp_vigile_contracts SET refund_due = refund_due + GREATEST(fee - paid_minutes * rate, 0) WHERE state <> 'done' AND kind = 'person' AND fee > 0")
            Open77.database.update.await(
                "UPDATE rp_vigile_contracts SET state = 'done', end_reason = 'server_restart', ended_at = ? WHERE state <> 'done'", { t })
        end)
        if not ok then
            store.mode = nil
            useKvp("sql_init_failed:" .. tostring(err))
            return
        end
        store.ready = true
        log("store=sql table=rp_vigile_contracts next_id=%d", store.nextId)
    end)
end

local function initStore()
    local queued, reason = Open77.database.ready(function() useSql() end)
    if not queued then
        useKvp(reason or "database_unavailable")
        return
    end
    CreateThread(function()
        Wait(C.storeFallbackAfterSec * 1000)
        if not store.mode then
            local _, why = Open77.database.isReady()
            useKvp(why or "database_silent")
        end
    end)
end

---------------------------------------------------------------------------
-- Contracts
---------------------------------------------------------------------------

-- contracts[id] = {
--   id, kind ("zone"|"person"), zone, payer ("society:<job>"|"corpo"|"account"),
--   state ("open"|"active"|"done"), minutes, rate, fee, paidMinutes, earned, societyCut, refundDue,
--   guardId, guardIdentifier, clientId, clientIdentifier, protectedId, protectedIdentifier,
--   offerTo (guard id a bodyguard offer is addressed to), posterName,
--   postedAt, startedAt, endedAt, expiresAt (open offers), nextMinuteAt, decidedMinutes,
--   samples, coveredSamples, unpaidStreak, lastUnpaidReason, endReason }
local contracts = {}
local journal = {}          -- journal[zone] = { {at, playerId, name, kind}, ... } newest last
local escorts = {}          -- escorts[targetId] = { guardId, zone, contractId }
local templateShown = {}    -- board option id -> template / contract id, per player

local function activeAsGuard(playerId)
    for _, c in pairs(contracts) do
        if c.state == "active" and c.guardId == playerId then return c end
    end
    return nil
end

local function contractAsClient(playerId, kind)
    for _, c in pairs(contracts) do
        if c.state ~= "done" and (not kind or c.kind == kind)
            and (c.clientId == playerId or c.protectedId == playerId) then return c end
    end
    return nil
end

local function zonePosted(zone)
    for _, c in pairs(contracts) do
        if c.state == "open" and c.kind == "zone" and c.zone == zone then return c end
    end
    return nil
end

local function zoneGuarded(zone)
    for _, c in pairs(contracts) do
        if c.state == "active" and c.kind == "zone" and c.zone == zone then return c end
    end
    return nil
end

local function contractLabel(c)
    if c.kind == "zone" then
        return ("guarding %s"):format(zoneLabel(c.zone))
    end
    return ("bodyguard for %s"):format(c.protectedId and playerName(c.protectedId) or "a client")
end

local function minutesLeft(c)
    if c.state ~= "active" then return c.minutes end
    return math.max(0, c.minutes - (c.decidedMinutes or 0))
end

local function emitContract(c, phase)
    TriggerEvent("rp_vigile:contract", c.id, phase, c.guardId, c.clientId)
end

local function pushGuardState(playerId)
    playerId = tonumber(playerId)
    if not playerId or not playerOnline(playerId) then return end
    local c = activeAsGuard(playerId)
    local escorting = {}
    for targetId, e in pairs(escorts) do
        if e.guardId == playerId then escorting[#escorting + 1] = targetId end
    end
    if c and c.kind == "zone" then
        TriggerClientEvent("rp_vigile:state", playerId, { guarding = true, zone = c.zone, label = zoneLabel(c.zone), escorting = escorting })
    else
        TriggerClientEvent("rp_vigile:state", playerId, { guarding = false, escorting = escorting })
    end
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------

local function addCash(guardId, amount, reason)
    if amount <= 0 then return true end
    local newBalance, why = callExport("rp_economy", "add", guardId, amount, reason)
    if newBalance == nil then return nil, why or "wallet_refused" end
    return true
end

local function societyAdd(name, amount, reason)
    if amount <= 0 then return true end
    local ok, why = callExport("rp_bank", "societyAdd", name, amount, reason)
    if ok == nil then return nil, why or "bank_refused" end
    return true
end

local function societyRemove(name, amount, reason)
    if amount <= 0 then return true end
    local ok, why = callExport("rp_bank", "societyRemove", name, amount, reason)
    if ok == nil then return nil, why or "bank_refused" end
    return true
end

-- One guarded minute. Returns true when the guard was paid, else nil, reason.
local function payMinute(c)
    local tag = "vigile:" .. c.id
    if c.payer == "corpo" then
        local ok, why = addCash(c.guardId, GUARD_SHARE, "guard")
        if not ok then return nil, why end
        societyAdd(SOCIETY, CUT, tag)
    elseif c.payer:sub(1, 8) == "society:" then
        local job = c.payer:sub(9)
        local ok, why = societyRemove(job, RATE, tag)
        if not ok then return nil, (why == "insufficient_funds") and ("the " .. jobLabel(job) .. " society is dry") or why end
        local paid, payWhy = addCash(c.guardId, GUARD_SHARE, "guard")
        if not paid then
            societyAdd(job, RATE, tag .. ":refund")
            return nil, payWhy
        end
        societyAdd(SOCIETY, CUT, tag)
    else -- "account": the escrow sits in the vigile society since the posting
        local ok, why = societyRemove(SOCIETY, GUARD_SHARE, tag)
        if not ok then
            -- The client already paid; a dry society is the company's problem, not the guard's.
            log("contract %d: vigile society could not cover a paid minute (%s), platform pays", c.id, tostring(why))
        end
        local paid, payWhy = addCash(c.guardId, GUARD_SHARE, "guard")
        if not paid then
            if ok then societyAdd(SOCIETY, GUARD_SHARE, tag .. ":refund") end
            return nil, payWhy
        end
    end
    c.paidMinutes = c.paidMinutes + 1
    c.earned = c.earned + GUARD_SHARE
    c.societyCut = c.societyCut + CUT
    return true
end

-- Give the unspent escrow of a bodyguard contract back to the client, in cash;
-- kept as a debt when the client is offline.
local function refundClient(c)
    if c.kind ~= "person" or c.payer ~= "account" then return end
    local refund = c.fee - c.paidMinutes * RATE
    if refund <= 0 then return end
    local ok, why = societyRemove(SOCIETY, refund, "vigile:" .. c.id .. ":refund")
    if not ok then
        log("contract %d: vigile society could not cover the refund (%s), platform pays", c.id, tostring(why))
    end
    if c.clientId and playerOnline(c.clientId) then
        local paid = addCash(c.clientId, refund, "vigile_refund")
        if paid then
            c.fee = c.paidMinutes * RATE
            say(c.clientId, ("Refund: %s for the %d minute(s) nobody guarded. Cash."):format(fmtMoney(refund), math.floor(refund / RATE)))
            return
        end
    end
    c.refundDue = (c.refundDue or 0) + refund
    c.fee = c.paidMinutes * RATE
    persistRefundDue(c)
    log("contract %d: refund of %d kept for %s", c.id, refund, tostring(c.clientIdentifier))
end

local function payRefundsDue(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return end
    if store.mode == "sql" then
        Open77.database.query("SELECT id, refund_due FROM rp_vigile_contracts WHERE client_identifier = ? AND refund_due > 0", { identifier }, function(rows)
            if type(rows) ~= "table" then return end
            for _, row in ipairs(rows) do
                local amount = tonumber(row.refund_due) or 0
                if amount > 0 and playerOnline(playerId) and addCash(playerId, amount, "vigile_refund") then
                    Open77.database.update("UPDATE rp_vigile_contracts SET refund_due = 0 WHERE id = ?", { row.id })
                    say(playerId, ("Security refund from contract #%s: %s, in cash."):format(tostring(row.id), fmtMoney(amount)))
                    log("player %d refund_due %d paid (contract %s)", playerId, math.floor(amount), tostring(row.id))
                end
            end
        end)
    elseif store.mode == "kvp" then
        local key = "refund:" .. identifier
        local amount = tonumber(Open77.kvp.get(key, 0)) or 0
        if amount > 0 and addCash(playerId, amount, "vigile_refund") then
            Open77.kvp.delete(key)
            say(playerId, ("Security refund: %s, in cash."):format(fmtMoney(amount)))
        end
    end
end

---------------------------------------------------------------------------
-- Journal (camera log)
---------------------------------------------------------------------------

local function clock(at)
    local s = math.floor(at % 86400)
    return ("%02d:%02d:%02d"):format(s // 3600, (s % 3600) // 60, s % 60)
end

local function journalAdd(zone, playerId, kind)
    local entries = journal[zone]
    if not entries then
        entries = {}
        journal[zone] = entries
    end
    entries[#entries + 1] = { at = now(), playerId = playerId, name = playerName(playerId), kind = kind }
    while #entries > C.journalSize do table.remove(entries, 1) end
end

local function journalLines(zone)
    local entries = journal[zone] or {}
    if #entries == 0 then
        return { ("Camera log of %s: nothing recorded yet."):format(zoneLabel(zone)) }
    end
    local lines = { ("Camera log of %s (last %d, UTC):"):format(zoneLabel(zone), #entries) }
    local verbs = { entered = "entered", left = "left", present = "was inside when the watch began",
        expelled = "was thrown out by security", escorted_out = "was escorted out" }
    for _, e in ipairs(entries) do
        lines[#lines + 1] = ("[%s] %s (#%d) %s"):format(clock(e.at), e.name, e.playerId, verbs[e.kind] or e.kind)
    end
    return lines
end

---------------------------------------------------------------------------
-- Contract lifecycle
---------------------------------------------------------------------------

local function newContract(kind, minutes, payer)
    local c = {
        id = allocateId(), kind = kind, payer = payer, state = "open",
        minutes = minutes, rate = RATE, fee = 0, paidMinutes = 0, earned = 0, societyCut = 0, refundDue = 0,
        postedAt = now(), decidedMinutes = 0, samples = 0, coveredSamples = 0, unpaidStreak = 0,
    }
    contracts[c.id] = c
    return c
end

local function startContract(c, guardId)
    c.state = "active"
    c.guardId = guardId
    c.guardIdentifier = Open77.players.identifier(guardId) or ""
    c.startedAt = now()
    c.nextMinuteAt = c.startedAt + 60
    c.decidedMinutes, c.samples, c.coveredSamples, c.unpaidStreak = 0, 0, 0, 0
    c.expiresAt = nil
    persistUpdate(c)
    emitContract(c, "started")
    log("contract %d started kind=%s zone=%s guard=%d client=%s payer=%s minutes=%d",
        c.id, c.kind, tostring(c.zone), guardId, tostring(c.clientId), c.payer, c.minutes)
    if c.kind == "zone" then
        say(guardId, ("Contract #%d: guard %s for %d min at %s/min (%s to you, %s to the company). Stay inside the ring; ALT+click a troublemaker to escort them out, /expulser <id> to throw them out."):format(
            c.id, zoneLabel(c.zone), c.minutes, fmtMoney(RATE), fmtMoney(GUARD_SHARE), fmtMoney(CUT)))
        if c.clientId and playerOnline(c.clientId) then
            say(c.clientId, ("%s took your security contract for %s (#%d)."):format(playerName(guardId), zoneLabel(c.zone), c.id))
        end
    else
        say(guardId, ("Contract #%d: bodyguard for %s, %d min at %s/min. Stay within %d m of them."):format(
            c.id, playerName(c.protectedId), c.minutes, fmtMoney(GUARD_SHARE), math.floor(C.bodyguardRange)))
        if c.clientId and playerOnline(c.clientId) then
            say(c.clientId, ("%s is on your detail for %d min (#%d). Keep them within %d m."):format(
                playerName(guardId), c.minutes, c.id, math.floor(C.bodyguardRange)))
        end
        if c.protectedId and c.protectedId ~= c.clientId and playerOnline(c.protectedId) then
            say(c.protectedId, ("%s is your bodyguard for the next %d min."):format(playerName(guardId), c.minutes))
        end
    end
    if c.kind == "zone" then
        -- Whoever is already inside opens the camera log.
        local inside = callExport("rp_zones", "playersIn", c.zone)
        if type(inside) == "table" then
            for _, pid in ipairs(inside) do journalAdd(c.zone, pid, "present") end
        end
    end
    pushGuardState(guardId)
end

local function releaseEscort(targetId, reason, tell)
    local e = escorts[targetId]
    if not e then return end
    escorts[targetId] = nil
    local ok, res, why = pcall(Open77.exports.callSync, "open77_rp_basics", "release", targetId, e.guardId, reason)
    if ok and res ~= true and why then
        -- The hold may already be gone (expired, target left...): nothing to undo.
        log("release of %d answered %s", targetId, tostring(why))
    end
    if tell and playerOnline(targetId) then say(targetId, tell) end
    if playerOnline(e.guardId) then pushGuardState(e.guardId) end
end

local function endContract(c, reason)
    if c.state == "done" then return end
    local wasActive = c.state == "active"
    c.state = "done"
    c.endReason = reason
    c.endedAt = now()
    if wasActive and c.kind == "zone" then
        for targetId, e in pairs(escorts) do
            if e.contractId == c.id then releaseEscort(targetId, "contract_over", "Security let you go: the contract is over.") end
        end
    end
    refundClient(c)
    persistUpdate(c)
    local phase = wasActive and "ended" or (reason == "expired" and "expired" or "cancelled")
    emitContract(c, phase)
    log("contract %d %s reason=%s paid_minutes=%d earned=%d cut=%d", c.id, phase,
        reason, c.paidMinutes, c.earned, c.societyCut)

    local reasons = {
        completed = "the shift is over", guard_ended = "the guard ended it", client_ended = "the client ended it",
        guard_left = "the guard left the city", client_left = "the client left the city",
        off_duty = "the guard clocked out", job_lost = "the guard is no longer with the company",
        expired = "nobody took it in time", resource_stop = "the security company closed for the night",
    }
    local why = reasons[reason] or reason
    if wasActive and c.guardId and playerOnline(c.guardId) then
        say(c.guardId, ("Contract #%d over (%s): %d/%d minute(s) paid, %s earned."):format(c.id, why, c.paidMinutes, c.minutes, fmtMoney(c.earned)))
        pushGuardState(c.guardId)
    end
    if c.clientId and playerOnline(c.clientId) and c.clientId ~= c.guardId then
        say(c.clientId, ("Security contract #%d over (%s): %d/%d minute(s) guarded."):format(c.id, why, c.paidMinutes, c.minutes))
    end
    if c.protectedId and c.protectedId ~= c.clientId and playerOnline(c.protectedId) then
        say(c.protectedId, ("Your security detail is over (%s)."):format(why))
    end
    -- The row stays in SQL as the ledger; the memory entry can go.
    contracts[c.id] = nil
end

-- Post a bodyguard contract. `clientId` pays (nil = platform), `protectedId` is
-- guarded, `offerTo` restricts it to one guard. Returns the contract, or nil, reason.
local function postPersonContract(clientId, protectedId, minutes, offerTo)
    if not playerOnline(protectedId) then return nil, "player_not_found" end
    local payer = "corpo"
    if clientId then
        if not playerOnline(clientId) then return nil, "client_not_found" end
        if contractAsClient(clientId, "person") then return nil, "client_busy" end
        payer = "account"
    end
    if protectedId ~= clientId and contractAsClient(protectedId, "person") then return nil, "target_busy" end
    if offerTo then
        if not playerOnline(offerTo) then return nil, "guard_not_found" end
        if not isVigile(offerTo) then return nil, "not_a_guard" end
        if not onDuty(offerTo) then return nil, "guard_off_duty" end
        if activeAsGuard(offerTo) then return nil, "guard_busy" end
    end
    local fee = 0
    if payer == "account" then
        fee = minutes * RATE
        local balance, why = callExport("rp_bank", "charge", clientId, fee, SOCIETY, "bodyguard:" .. tostring(offerTo or 0))
        if balance == nil then return nil, why or "bank_refused" end
    end
    local c = newContract("person", minutes, payer)
    c.fee = fee
    c.clientId = clientId
    c.clientIdentifier = clientId and Open77.players.identifier(clientId) or ""
    c.protectedId = protectedId
    c.protectedIdentifier = Open77.players.identifier(protectedId) or ""
    c.offerTo = offerTo
    c.posterName = clientId and playerName(clientId) or "Corpo"
    c.expiresAt = now() + C.offerTimeoutSec
    persistInsert(c)
    emitContract(c, "posted")
    log("contract %d posted kind=person protected=%d client=%s offerTo=%s minutes=%d fee=%d",
        c.id, protectedId, tostring(clientId), tostring(offerTo), minutes, fee)
    if offerTo then
        say(offerTo, ("%s wants to hire you as a bodyguard for %d min (%s/min for you). /garde to accept, %d s to decide."):format(
            c.posterName, minutes, fmtMoney(GUARD_SHARE), C.offerTimeoutSec))
    else
        -- Every on-duty guard hears about an open bodyguard job.
        local guards = callExport("rp_jobs", "listOnDuty", "vigile")
        if type(guards) == "table" then
            for _, gid in ipairs(guards) do
                if not activeAsGuard(gid) then
                    say(gid, ("Bodyguard job posted: %s, %d min at %s/min. /garde to take it."):format(playerName(protectedId), minutes, fmtMoney(GUARD_SHARE)))
                end
            end
        end
    end
    return c
end

-- Post a zone contract (a business, a fixer or the console). Returns the contract, or nil, reason.
local function postZoneContract(zone, minutes, byPlayerId)
    local known, why = zoneKnown(zone)
    if known == nil then return nil, why end
    if not known then return nil, "unknown_zone" end
    if zoneGuarded(zone) then return nil, "zone_guarded" end
    if zonePosted(zone) then return nil, "zone_already_posted" end
    local job = C.zoneSociety[zone]
    local c = newContract("zone", minutes, job and ("society:" .. job) or "corpo")
    c.zone = zone
    c.expiresAt = now() + C.zoneOfferTimeoutSec
    if byPlayerId and byPlayerId > 0 and playerOnline(byPlayerId) then
        c.clientId = byPlayerId
        c.clientIdentifier = Open77.players.identifier(byPlayerId) or ""
        c.posterName = playerName(byPlayerId)
    else
        c.posterName = job and jobLabel(job) or "Corpo"
    end
    persistInsert(c)
    emitContract(c, "posted")
    log("contract %d posted kind=zone zone=%s by=%s payer=%s minutes=%d", c.id, zone, tostring(byPlayerId), c.payer, minutes)
    return c
end

---------------------------------------------------------------------------
-- The minute tick: sampling, payouts, expiries, escort bookkeeping
---------------------------------------------------------------------------

local function covered(c)
    if not c.guardId or not playerOnline(c.guardId) then return false, "guard offline" end
    if not onDuty(c.guardId) then return false, "you are off duty" end
    if c.kind == "zone" then
        if not zoneIsIn(c.guardId, c.zone) then return false, ("you were outside %s"):format(zoneLabel(c.zone)) end
        return true
    end
    if not c.protectedId or not playerOnline(c.protectedId) then return false, "your client is gone" end
    local metres = Open77.players.distance(c.guardId, c.protectedId)
    if not metres then return false, "your client's position is unknown" end
    if metres > C.bodyguardRange then
        return false, ("you were more than %d m from your client"):format(math.floor(C.bodyguardRange))
    end
    return true
end

local function decideMinute(c)
    local samples = math.max(c.samples, 1)
    local coverage = c.coveredSamples / samples
    local reason = c.lastUnpaidReason or "you were away"
    c.samples, c.coveredSamples, c.lastUnpaidReason = 0, 0, nil
    local paid, why
    if coverage >= C.minuteCoverage then
        paid, why = payMinute(c)
        if not paid then reason = why or "payment refused" end
    end
    if paid then
        c.unpaidStreak = 0
        persistUpdate(c)
        log("contract %d minute %d paid guard=%d +%d cut=%d", c.id, c.decidedMinutes + 1, c.guardId, GUARD_SHARE, CUT)
        say(c.guardId, ("+%s (minute %d/%d guarded). Total %s."):format(fmtMoney(GUARD_SHARE), c.decidedMinutes + 1, c.minutes, fmtMoney(c.earned)))
    else
        c.unpaidStreak = c.unpaidStreak + 1
        log("contract %d minute %d unpaid reason=%s", c.id, c.decidedMinutes + 1, tostring(reason))
        if c.unpaidStreak >= C.unpaidWarnAfter then
            say(c.guardId, ("No pay for the last %d minute(s): %s."):format(c.unpaidStreak, reason))
        end
    end
end

CreateThread(function()
    while true do
        Wait(C.tickMs)
        local t = now()
        for id, c in pairs(contracts) do
            if c.state == "open" and c.expiresAt and t >= c.expiresAt then
                endContract(c, "expired")
            elseif c.state == "active" then
                local ok, why = covered(c)
                c.samples = c.samples + 1
                if ok then c.coveredSamples = c.coveredSamples + 1 else c.lastUnpaidReason = why end
                while c.state == "active" and t >= c.nextMinuteAt do
                    decideMinute(c)
                    c.decidedMinutes = c.decidedMinutes + 1
                    c.nextMinuteAt = c.nextMinuteAt + 60
                    if c.decidedMinutes >= c.minutes then endContract(c, "completed") end
                end
            end
        end
        -- Holds that ended on their own (expired, target left...) leave our table.
        for targetId, e in pairs(escorts) do
            local ok, hold = pcall(Open77.exports.callSync, "open77_rp_basics", "state", targetId)
            if not ok or hold == nil then
                escorts[targetId] = nil
                if playerOnline(e.guardId) then pushGuardState(e.guardId) end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Rights inside a guarded zone: escort out, release, expel
---------------------------------------------------------------------------

-- The guard's active zone contract, if they stand in that zone. Else nil, message.
local function guardingZone(guardId)
    local c = activeAsGuard(guardId)
    if not c or c.kind ~= "zone" then return nil, "You are not guarding a zone right now. /garde to take a contract." end
    if not zoneIsIn(guardId, c.zone) then return nil, ("You are outside %s. Security rights stop at the ring."):format(zoneLabel(c.zone)) end
    return c
end

local function escortOut(guardId, targetId)
    local c, why = guardingZone(guardId)
    if not c then return say(guardId, why) end
    if targetId == guardId then return say(guardId, "Escort yourself out? Nice try, choom.") end
    if not playerOnline(targetId) then return say(guardId, "Nobody with that id in the city.") end
    if not zoneIsIn(targetId, c.zone) then return say(guardId, ("%s is not inside %s."):format(playerName(targetId), zoneLabel(c.zone))) end
    if escorts[targetId] then return say(guardId, ("%s is already being escorted."):format(playerName(targetId))) end
    local metres = Open77.players.distance(guardId, targetId)
    if not metres or metres > C.escortRange then
        return say(guardId, ("Too far away (%s m). Get within %d m."):format(metres and ("%.0f"):format(metres) or "?", math.floor(C.escortRange)))
    end
    local ok, res, reason = pcall(Open77.exports.callSync, "open77_rp_basics", "escort", guardId, targetId, { holdMs = C.escortHoldMs })
    if not ok then
        local err = tostring(res)
        if err:find("unavailable", 1, true) or err:find("not_found", 1, true) or err:find("target_stopped", 1, true) then
            return say(guardId, "The role-play kit (open77_rp_basics) is not running on this server: no escort, use /expulser.")
        end
        return say(guardId, ("Escort failed: %s."):format(err))
    end
    if res ~= true then
        if reason == "not_authorised" then
            return say(guardId, "Security has no escort rights here (ACL rp.escort not granted to guards). Use /expulser.")
        end
        return say(guardId, ("Escort refused: %s."):format(tostring(reason)))
    end
    escorts[targetId] = { guardId = guardId, zone = c.zone, contractId = c.id }
    say(guardId, ("Escorting %s out of %s. They are released at the ring."):format(playerName(targetId), zoneLabel(c.zone)))
    say(targetId, ("Security is escorting you out of %s. Walk with them."):format(zoneLabel(c.zone)))
    log("contract %d guard %d escorts %d out of %s", c.id, guardId, targetId, c.zone)
    pushGuardState(guardId)
end

local function releaseByGuard(guardId, targetId)
    local e = escorts[targetId]
    if not e or e.guardId ~= guardId then return say(guardId, "You are not escorting that person.") end
    releaseEscort(targetId, "released", "Security let you go.")
    say(guardId, ("Released %s."):format(playerName(targetId)))
end

local function expelPoint(c, targetId, guardId)
    local target = Open77.players.position(targetId)
    if not target then return nil, "position_unknown" end
    local g = C.zoneGeometry[c.zone]
    local x, y, z
    if g then
        local dx, dy = target.x - g.x, target.y - g.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.5 then
            local guard = Open77.players.position(guardId)
            if guard then dx, dy = target.x - guard.x, target.y - guard.y; len = math.sqrt(dx * dx + dy * dy) end
            if len < 0.5 then dx, dy, len = 1.0, 0.0, 1.0 end
        end
        local d = (g.radius or 0) + C.expelDistance
        x, y, z = g.x + dx / len * d, g.y + dy / len * d, g.z or target.z
    else
        local guard = Open77.players.position(guardId)
        local dx, dy = 1.0, 0.0
        if guard then
            dx, dy = target.x - guard.x, target.y - guard.y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 0.5 then dx, dy = 1.0, 0.0 else dx, dy = dx / len, dy / len end
        end
        x, y, z = target.x + dx * C.expelDistance, target.y + dy * C.expelDistance, target.z
    end
    -- The real ground under the point, when a client near enough can see it.
    local groundZ = Open77.world.groundZ({ x = x, y = y }, { timeout = 2500 })
    if groundZ then z = groundZ + 0.3 end
    return { x = x, y = y, z = z }
end

local function expel(guardId, targetId)
    local c, why = guardingZone(guardId)
    if not c then return say(guardId, why) end
    if targetId == guardId then return say(guardId, "Throw yourself out? Take a walk instead.") end
    if not playerOnline(targetId) then return say(guardId, "Nobody with that id in the city.") end
    if not zoneIsIn(targetId, c.zone) then return say(guardId, ("%s is not inside %s."):format(playerName(targetId), zoneLabel(c.zone))) end
    if isNcpdOnDuty(targetId) then return say(guardId, "That is an NCPD officer on duty. Security does not throw out badges.") end
    local point, pointWhy = expelPoint(c, targetId, guardId)
    if not point then return say(guardId, ("Cannot place them: %s."):format(tostring(pointWhy))) end
    if escorts[targetId] then releaseEscort(targetId, "expelled", nil) end
    local pending, reason = Open77.players.teleport(targetId, point, { dismount = true })
    if not pending then return say(guardId, ("Expulsion refused: %s."):format(tostring(reason))) end
    say(guardId, ("Throwing %s out of %s..."):format(playerName(targetId), zoneLabel(c.zone)))
    local landed, err = pending:await()
    if not landed then
        return say(guardId, ("Expulsion failed: %s."):format(tostring(err)))
    end
    journalAdd(c.zone, targetId, "expelled")
    log("contract %d guard %d expelled %d from %s to %.1f %.1f %.1f (%s)", c.id, guardId, targetId, c.zone, landed.x, landed.y, landed.z, landed.state)
    say(guardId, ("%s is out of %s."):format(playerName(targetId), zoneLabel(c.zone)))
    say(targetId, ("Security threw you out of %s. Don't come back, choom."):format(zoneLabel(c.zone)))
end

---------------------------------------------------------------------------
-- The board (UI kit context, server twin)
---------------------------------------------------------------------------

local function boardOptions(guardId)
    local options, map = {}, {}
    for i, t in ipairs(C.templates) do
        local known = zoneKnown(t.zone)
        if known and not zoneGuarded(t.zone) and not zonePosted(t.zone) then
            local job = C.zoneSociety[t.zone]
            local id = "t_" .. i
            map[id] = { template = t }
            options[#options + 1] = {
                id = id,
                label = ("Guard %s"):format(zoneLabel(t.zone)),
                description = ("%d min - client: %s"):format(t.minutes, job and jobLabel(job) or "corpo"),
                metadata = { { label = "Pay", value = fmtMoney(GUARD_SHARE) .. "/min" }, { label = "Length", value = t.minutes .. " min" } },
            }
        end
    end
    local ids = {}
    for id in pairs(contracts) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local c = contracts[id]
        if #options >= 63 then break end   -- 64 options per menu, the last one is Leave
        if c.state == "open" and (not c.offerTo or c.offerTo == guardId) and c.protectedId ~= guardId and c.clientId ~= guardId then
            local optId = "c_" .. c.id
            map[optId] = { contract = c.id }
            if c.kind == "zone" then
                options[#options + 1] = {
                    id = optId,
                    label = ("Guard %s (posted by %s)"):format(zoneLabel(c.zone), c.posterName or "?"),
                    description = ("%d min - contract #%d"):format(c.minutes, c.id),
                    metadata = { { label = "Pay", value = fmtMoney(GUARD_SHARE) .. "/min" }, { label = "Length", value = c.minutes .. " min" } },
                }
            else
                options[#options + 1] = {
                    id = optId,
                    label = ("Bodyguard for %s"):format(c.protectedId and playerName(c.protectedId) or "?"),
                    description = ("%d min - hired by %s - contract #%d"):format(c.minutes, c.posterName or "?", c.id),
                    metadata = { { label = "Pay", value = fmtMoney(GUARD_SHARE) .. "/min" }, { label = "Length", value = c.minutes .. " min" } },
                }
            end
        end
    end
    options[#options + 1] = { id = "leave", label = "Leave" }
    return options, map
end

local function takeOption(guardId, pick)
    if activeAsGuard(guardId) then return say(guardId, "You already have a contract. /garde fin to end it first.") end
    if not onDuty(guardId) then return say(guardId, "Clock in first: /service.") end
    if pick.template then
        local t = pick.template
        if zoneGuarded(t.zone) then return say(guardId, ("Somebody took %s meanwhile."):format(zoneLabel(t.zone))) end
        local c, why = postZoneContract(t.zone, t.minutes, nil)
        if not c then return say(guardId, ("Contract refused: %s."):format(tostring(why))) end
        startContract(c, guardId)
        return
    end
    local c = contracts[pick.contract]
    if not c or c.state ~= "open" then return say(guardId, "That contract is gone.") end
    if c.offerTo and c.offerTo ~= guardId then return say(guardId, "That offer is addressed to another guard.") end
    if c.kind == "person" and (not c.protectedId or not playerOnline(c.protectedId)) then
        endContract(c, "client_left")
        return say(guardId, "The client left the city; the contract is void.")
    end
    startContract(c, guardId)
end

local function openBoard(guardId)
    local options, map = boardOptions(guardId)
    if #options == 1 then return say(guardId, "No contract on the board right now. Come back later, choom.") end
    templateShown[guardId] = map
    local promise, dispatchError = Open77.exports.call("open77_uikit", "context", guardId, {
        id = "rp_vigile_board",
        title = "Security contracts",
        description = ("Paid per guarded minute: %s to you, %s to the company."):format(fmtMoney(GUARD_SHARE), fmtMoney(CUT)),
        options = options,
    }, { timeoutMs = 60000 })
    if not promise then return say(guardId, ("The board is offline (%s)."):format(tostring(dispatchError))) end
    local answer, reason = promise:await()
    if not answer then return say(guardId, ("The board did not answer (%s)."):format(tostring(reason))) end
    if not answer.ok then return end
    local picked = answer.value and answer.value.id
    if not picked or picked == "leave" then return end
    local pick = templateShown[guardId] and templateShown[guardId][picked]
    templateShown[guardId] = nil
    if not pick then return say(guardId, "That contract is gone.") end
    takeOption(guardId, pick)
end

---------------------------------------------------------------------------
-- Status and journal
---------------------------------------------------------------------------

local function statusLines(playerId)
    local lines = {}
    local g = activeAsGuard(playerId)
    if g then
        lines[#lines + 1] = ("Contract #%d: %s - %d/%d minute(s) left, %d paid, %s earned (%s/min)."):format(
            g.id, contractLabel(g), minutesLeft(g), g.minutes, g.paidMinutes, fmtMoney(g.earned), fmtMoney(GUARD_SHARE))
        if g.kind == "zone" then
            lines[#lines + 1] = zoneIsIn(playerId, g.zone) and "You are inside the zone: the minute counts." or "You are OUTSIDE the zone: this minute will not be paid."
            local n = 0
            for _, e in pairs(escorts) do if e.guardId == playerId then n = n + 1 end end
            if n > 0 then lines[#lines + 1] = ("Escorting %d person(s) out."):format(n) end
        else
            local metres = g.protectedId and Open77.players.distance(playerId, g.protectedId)
            lines[#lines + 1] = metres and ("Client %.0f m away (max %d m)."):format(metres, math.floor(C.bodyguardRange)) or "Client position unknown."
        end
    end
    local cl = contractAsClient(playerId)
    if cl then
        if cl.state == "open" then
            lines[#lines + 1] = ("Your offer #%d (%s, %d min, %s) is waiting for a guard. /garde fin to cancel and get refunded."):format(
                cl.id, contractLabel(cl), cl.minutes, fmtMoney(cl.fee))
        elseif cl.kind == "zone" then
            lines[#lines + 1] = ("Your zone contract #%d: %s guards %s, %d/%d minute(s) left, %d paid. /garde journal for the camera log."):format(
                cl.id, cl.guardId and playerName(cl.guardId) or "?", zoneLabel(cl.zone), minutesLeft(cl), cl.minutes, cl.paidMinutes)
        else
            lines[#lines + 1] = ("Your security detail #%d: %s on duty, %d/%d minute(s) left, %d guarded."):format(
                cl.id, cl.guardId and playerName(cl.guardId) or "?", minutesLeft(cl), cl.minutes, cl.paidMinutes)
        end
    end
    return lines
end

-- Which zone's camera log this player may read: their own guarded zone, a zone
-- whose society employs them, or a zone contract they posted.
local function readableJournalZone(playerId)
    local g = activeAsGuard(playerId)
    if g and g.kind == "zone" then return g.zone end
    local job = callExport("rp_jobs", "getJob", playerId)
    for _, c in pairs(contracts) do
        if c.state == "active" and c.kind == "zone" then
            if c.clientId == playerId then return c.zone end
            if job and C.zoneSociety[c.zone] == job then return c.zone end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local HELP = {
    "/garde - your contract, or the board of contracts when you are free",
    "/garde engager <guardId> <minutes> - hire a guard as your bodyguard (paid from your account)",
    "/garde fin - end your contract (unguarded minutes are refunded to the client)",
    "/garde journal - the camera log of the zone you guard (or that your society pays for)",
    "/garde escorter <playerId> - escort somebody out of the zone you guard (ALT+click does the same)",
    "/garde relacher <playerId> - release an escort",
    "/expulser <playerId> - throw somebody out of the zone you guard (20 m past the ring)",
}

local function cmdGarde(source, args)
    local sub = (args[1] or ""):lower()
    if sub == "" then
        local lines = statusLines(source)
        if #lines > 0 then return sayLines(source, lines) end
        if not isVigile(source) then
            return say(source, "You are not with the security company. Sign up at the employment agency (/agence) as a security guard, or /garde engager <guardId> <minutes> to hire one.")
        end
        if not onDuty(source) then return say(source, "Clock in first: /service. Then /garde for the board.") end
        if not store.ready then return say(source, "The security desk is still booting. Try again in a moment.") end
        return openBoard(source)
    end
    if sub == "aide" or sub == "help" then return sayLines(source, HELP) end
    if sub == "engager" then
        local guardId, minutes = toId(args[2]), tonumber(args[3])
        if not guardId or not minutes or minutes % 1 ~= 0 then return say(source, "Usage: /garde engager <guardId> <minutes>") end
        if guardId == source then return say(source, "You cannot hire yourself.") end
        if minutes < C.minMinutes or minutes > C.maxMinutes then
            return say(source, ("Between %d and %d minutes."):format(C.minMinutes, C.maxMinutes))
        end
        if not store.ready then return say(source, "The security desk is still booting. Try again in a moment.") end
        local c, why = postPersonContract(source, source, math.floor(minutes), guardId)
        if not c then
            local messages = {
                player_not_found = "Nobody with that id in the city.", guard_not_found = "Nobody with that id in the city.",
                not_a_guard = "That person is not a security guard.", guard_off_duty = "That guard is off duty.",
                guard_busy = "That guard already has a contract.", client_busy = "You already have a security contract. /garde fin first.",
                insufficient_funds = ("Not enough eddies in your account: %s needed. /bank to deposit."):format(fmtMoney(minutes * RATE)),
                bank_not_ready = "The bank is not answering. Try again in a moment.",
                ["unavailable:rp_bank"] = "The bank is offline: nobody can charge your account.",
                ["unavailable:rp_jobs"] = "The job registry is offline: no guard can be found.",
            }
            return say(source, messages[why] or ("Hiring refused: %s."):format(tostring(why)))
        end
        return say(source, ("Offer #%d sent to %s: %d min for %s (charged to your account, refunded if nobody guards you)."):format(
            c.id, playerName(guardId), c.minutes, fmtMoney(c.fee)))
    end
    if sub == "fin" then
        local g = activeAsGuard(source)
        if g then
            endContract(g, "guard_ended")
            return
        end
        local cl = contractAsClient(source)
        if cl then
            endContract(cl, "client_ended")
            return
        end
        return say(source, "No contract to end.")
    end
    if sub == "journal" then
        local zone = readableJournalZone(source)
        if not zone then return say(source, "No camera log for you: guard a zone, or be the society that pays for one.") end
        return sayLines(source, journalLines(zone))
    end
    if sub == "escorter" then
        local targetId = toId(args[2])
        if not targetId then return say(source, "Usage: /garde escorter <playerId>") end
        return escortOut(source, targetId)
    end
    if sub == "relacher" then
        local targetId = toId(args[2])
        if not targetId then return say(source, "Usage: /garde relacher <playerId>") end
        return releaseByGuard(source, targetId)
    end
    return sayLines(source, HELP)
end

RegisterCommand("garde", function(source, args)
    if source == 0 then return print("rp_vigile: /garde runs from the game, not the console") end
    cmdGarde(source, args)
end, false)

RegisterCommand("expulser", function(source, args)
    if source == 0 then return print("rp_vigile: /expulser runs from the game, not the console") end
    local targetId = toId(args[1])
    if not targetId then return say(source, "Usage: /expulser <playerId>") end
    expel(source, targetId)
end, false)

local SUGGESTIONS = {
    { command = "/garde", help = "Security: your contract, or the board of contracts", parameters = {
        { name = "engager|fin|journal|escorter|relacher|aide", help = "optional sub-command" } } },
    { command = "/expulser", help = "Security: throw somebody out of the zone you guard", parameters = {
        { name = "playerId", help = "the player to expel" } } },
}

---------------------------------------------------------------------------
-- Net events (the client's requests) and platform events
---------------------------------------------------------------------------

RegisterNetEvent("rp_vigile:escort", function(targetId)
    local guardId = source
    targetId = toId(targetId)
    if type(guardId) ~= "number" or guardId < 1 or not targetId then return end
    escortOut(guardId, targetId)
end)

RegisterNetEvent("rp_vigile:release", function(targetId)
    local guardId = source
    targetId = toId(targetId)
    if type(guardId) ~= "number" or guardId < 1 or not targetId then return end
    releaseByGuard(guardId, targetId)
end)

RegisterNetEvent("rp_vigile:clientReady", function()
    if type(source) == "number" and source > 0 then pushGuardState(source) end
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then Open77.chat.addSuggestions(source, SUGGESTIONS) end
end)

-- Camera log + escort release at the ring.
AddEventHandler("rp_zones:entered", function(playerId, zone)
    playerId = tonumber(playerId)
    if not playerId or not zoneGuarded(zone) then return end
    journalAdd(zone, playerId, "entered")
end)

AddEventHandler("rp_zones:left", function(playerId, zone)
    playerId = tonumber(playerId)
    if not playerId then return end
    local e = escorts[playerId]
    if e and e.zone == zone then
        releaseEscort(playerId, "escorted_out", ("You have been escorted out of %s."):format(zoneLabel(zone)))
        journalAdd(zone, playerId, "escorted_out")
        if playerOnline(e.guardId) then say(e.guardId, ("%s is out of %s. Released."):format(playerName(playerId), zoneLabel(zone))) end
        log("player %d escorted out of %s by %d", playerId, zone, e.guardId)
        return
    end
    local g = zoneGuarded(zone)
    if not g then return end
    journalAdd(zone, playerId, "left")
    if g.guardId == playerId then
        say(playerId, ("You left %s: the clock keeps running, but a minute spent outside is not paid."):format(zoneLabel(zone)))
    end
end)

-- A guard who clocks out or loses the job loses the contract.
AddEventHandler("rp_jobs:duty", function(playerId, jobName, isOn)
    playerId = tonumber(playerId)
    if not playerId or isOn == true then return end
    local c = activeAsGuard(playerId)
    if c then endContract(c, "off_duty") end
end)

AddEventHandler("rp_jobs:changed", function(playerId, jobName)
    playerId = tonumber(playerId)
    if not playerId or jobName == "vigile" then return end
    local c = activeAsGuard(playerId)
    if c then endContract(c, "job_lost") end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    if store.ready then
        payRefundsDue(playerId)
    else
        CreateThread(function()
            local waited = 0
            while not store.ready and waited < 30000 do Wait(1000); waited = waited + 1000 end
            if store.ready and playerOnline(playerId) then payRefundsDue(playerId) end
        end)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    templateShown[playerId] = nil
    if escorts[playerId] then escorts[playerId] = nil end
    for targetId, e in pairs(escorts) do
        if e.guardId == playerId then releaseEscort(targetId, "officer_left", "Security let you go.") end
    end
    local g = activeAsGuard(playerId)
    if g then endContract(g, "guard_left") end
    -- A bodyguard contract dies with its client; a posted zone contract only
    -- loses its poster (the society keeps paying the guard).
    for _, c in pairs(contracts) do
        if c.state ~= "done" and c.kind == "person" and (c.clientId == playerId or c.protectedId == playerId) then
            endContract(c, "client_left")
        elseif c.state ~= "done" and c.kind == "zone" and c.clientId == playerId then
            c.clientId = nil
        end
    end
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    initStore()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    log("started: %d templates, %s/min (%s guard + %s company), bodyguard range %d m, expel %d m past the ring",
        #C.templates, fmtMoney(RATE), fmtMoney(GUARD_SHARE), fmtMoney(CUT), math.floor(C.bodyguardRange), math.floor(C.expelDistance))
    for _, id in ipairs(Open77.players.all()) do pushGuardState(id) end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    for targetId in pairs(escorts) do releaseEscort(targetId, "resource_stopping", nil) end
    local ids = {}
    for id in pairs(contracts) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local c = contracts[id]
        if c then endContract(c, "resource_stop") end
    end
end)

---------------------------------------------------------------------------
-- Exports (synchronous, never yield: memory cache written through with callbacks)
---------------------------------------------------------------------------

-- postContract(kind, target, minutes, byPlayerId) -> contractId | nil, reason
--   kind "zone"  : target = zone name; byPlayerId (optional) posts it and may read the log.
--                  Paid by the zone's society (VigileConfig.zoneSociety) or by the platform.
--   kind "person": target = the player to protect; byPlayerId pays (charged now), nil = platform.
exports("postContract", function(kind, target, minutes, byPlayerId)
    if not store.ready then return nil, "store_not_ready" end
    minutes = tonumber(minutes)
    if not minutes or minutes % 1 ~= 0 or minutes < C.minMinutes or minutes > C.maxMinutes then return nil, "invalid_minutes" end
    minutes = math.floor(minutes)
    byPlayerId = toId(byPlayerId)
    if kind == "zone" then
        if type(target) ~= "string" or target == "" then return nil, "invalid_zone" end
        local c, why = postZoneContract(target, minutes, byPlayerId)
        if not c then return nil, why end
        return c.id
    elseif kind == "person" then
        local protectedId = toId(target)
        if not protectedId then return nil, "invalid_player_id" end
        local c, why = postPersonContract(byPlayerId, protectedId, minutes, nil)
        if not c then return nil, why end
        return c.id
    end
    return nil, "invalid_kind"
end)

-- activeContract(playerId) -> a copy of the contract the player is on (as guard,
-- client or protected person), or nil.
exports("activeContract", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return nil end
    local c = activeAsGuard(playerId) or contractAsClient(playerId)
    if not c then return nil end
    return {
        id = c.id, kind = c.kind, zone = c.zone, state = c.state, payer = c.payer,
        guardId = c.guardId, clientId = c.clientId, protectedId = c.protectedId,
        minutes = c.minutes, minutesLeft = minutesLeft(c), paidMinutes = c.paidMinutes,
        rate = RATE, guardShare = GUARD_SHARE, earned = c.earned, fee = c.fee,
        postedAt = c.postedAt, startedAt = c.startedAt,
    }
end)
