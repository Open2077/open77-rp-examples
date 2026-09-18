-- rp_bank / server: accounts, ledger, societies, ATM menu and the three commands.
--
-- Money model
--   cash    -> rp_economy (exports getBalance / add / remove), never touched directly here
--   account -> rp_bank_accounts, keyed by the durable identifier, cached in memory
--   ledger  -> rp_bank_transactions, append only
--   society -> rp_bank_societies, keyed by name, cached in memory
--
-- Every account and society row lives in an in-memory cache that is written through to SQL with
-- the callback (non-yielding) forms of Open77.database.*. That is deliberate: the exports below
-- are called synchronously (exports.rp_bank:deposit(...)) and a synchronous callee that yields
-- fails with export_yielded, so nothing on the export path may .await. The cache is loaded once
-- when the database answers, and every later change goes through the same functions.
--
-- Without a database the resource falls back to Open77.kvp (balances only, the ledger stays in
-- memory) and says so in the log.

local RESOURCE = "rp_bank"

-- The `.await` forms (Open77.database.query.await, ...) are documented on every database card but
-- are not catalogue entries of their own, so the static validator reads the dotted spelling as an
-- unknown native. They are reached through this alias; the callback forms stay spelled out so the
-- permission check still sees them. Same table as the oxmysql-compatible `MySQL` global.
local DB = Open77.database

local store = {
    mode = nil,          -- nil (undecided) | "sql" | "kvp"
    ready = false,       -- true once the mode is decided and the cache is loaded
}

local accounts = {}      -- identifier -> { balance = integer, createdAt = integer }
local societies = {}     -- name -> { balance = integer }
local recent = {}        -- identifier -> { { delta, balanceAfter, kind, note, at }, ... } newest first
local online = {}        -- identifier -> playerId (ready players only)
local sessions = {}      -- playerId -> true while an ATM menu is open

-- ---------------------------------------------------------------------------------------------
-- helpers

local function log(fmt, ...)
    print(("[%s] "):format(RESOURCE) .. fmt:format(...))
end

local function warn(fmt, ...)
    Open77.log.warn(fmt:format(...))
end

local function formatMoney(n)
    local s = tostring(math.tointeger(n) or n)
    local sign = ""
    if s:sub(1, 1) == "-" then sign, s = "-", s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    out = out:gsub("^ ", "")
    return sign .. out .. " €$"
end

-- A chat line from the bank, in one colour, to one player.
local function say(playerId, text)
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local ok, reason = Open77.chat.send(playerId, { author = "NC Bank", text = text, color = { 34, 216, 226 } })
    if not ok then warn("chat.send to %d refused: %s", playerId, tostring(reason)) end
end

-- Positive integer amount within the per-operation cap, or nil, reason.
local function toAmount(value)
    local n = tonumber(value)
    if not n then return nil, "invalid_amount" end
    local i = math.tointeger(n)
    if not i or i < 1 then return nil, "invalid_amount" end
    if i > Config.MaxAmount then return nil, "amount_too_large" end
    return i
end

-- A positive integer player id, or nil, reason. Accepts the string form host events deliver.
local function toPlayerId(value)
    local n = tonumber(value)
    if not n then return nil, "invalid_player_id" end
    local i = math.tointeger(n)
    if not i or i < 1 then return nil, "invalid_player_id" end
    return i
end

local function cleanNote(note)
    if note == nil then return nil end
    if type(note) ~= "string" then return nil, "invalid_reason" end
    if #note < 1 or #note > 128 or note:find("[%c]") then return nil, "invalid_reason" end
    return note
end

local function cleanSocietyName(name)
    if type(name) ~= "string" then return nil, "invalid_society" end
    if #name < 1 or #name > 64 or not name:match("^[%w_%-%.]+$") then return nil, "invalid_society" end
    return name:lower()
end

-- Human reasons for chat. Unknown tokens are shown as they are.
local REASON_TEXT = {
    invalid_amount        = "Amount must be a positive whole number of eddies.",
    amount_too_large      = "That is more eddies than this ATM can move at once.",
    insufficient_funds    = "Not enough eddies in the account.",
    insufficient_cash     = "Not enough cash on you.",
    balance_limit         = "That account cannot hold more.",
    bank_not_ready        = "The bank network is still booting. Try again in a moment.",
    account_not_loaded    = "Your account is not loaded yet. Give it a second.",
    unknown_recipient     = "Unknown recipient. Use a connected player id or a citizen id.",
    self_transfer         = "You cannot wire eddies to yourself, choom.",
    wallet_unavailable    = "The wallet service (rp_economy) is offline.",
    invalid_player_id     = "That is not a player id.",
    player_not_found      = "No such player in Night City right now.",
    invalid_society       = "That is not a society name.",
    invalid_reason        = "Bad reason text.",
}

local function reasonText(reason)
    return REASON_TEXT[reason] or ("Refused: " .. tostring(reason))
end

-- ---------------------------------------------------------------------------------------------
-- persistence: cache + write-through (never yields)

local function persistAccount(identifier)
    local acct = accounts[identifier]
    if not acct then return end
    if store.mode == "sql" then
        Open77.database.update("UPDATE rp_bank_accounts SET balance = ? WHERE identifier = ?",
            { acct.balance, identifier }, function(result)
                if result == nil or result == false then
                    warn("account write failed for %s", identifier)
                end
            end)
    elseif store.mode == "kvp" then
        local ok, reason = Open77.kvp.set("acct:" .. identifier, acct.balance)
        if not ok then warn("kvp write failed for %s: %s", identifier, tostring(reason)) end
    end
end

local function persistSociety(name)
    local soc = societies[name]
    if not soc then return end
    if store.mode == "sql" then
        Open77.database.update("UPDATE rp_bank_societies SET balance = ? WHERE name = ?",
            { soc.balance, name }, function(result)
                if result == nil or result == false then
                    warn("society write failed for %s", name)
                end
            end)
    elseif store.mode == "kvp" then
        local ok, reason = Open77.kvp.set("soc:" .. name, soc.balance)
        if not ok then warn("kvp write failed for society %s: %s", name, tostring(reason)) end
    end
end

-- Append one ledger line (memory ring + SQL insert when available).
local function record(identifier, delta, balanceAfter, kind, note)
    local at = math.floor(Open77.time.unix())
    local ring = recent[identifier]
    if not ring then ring = {}; recent[identifier] = ring end
    table.insert(ring, 1, { delta = delta, balanceAfter = balanceAfter, kind = kind, note = note, at = at })
    while #ring > Config.HistoryLimit do table.remove(ring) end
    if store.mode == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_bank_transactions (identifier, delta, balance_after, kind, note, `at`) VALUES (?, ?, ?, ?, ?, ?)",
            { identifier, delta, balanceAfter, kind, note or "", at })
    end
end

-- Create an account row in the cache and the store. Returns the account.
local function createAccount(identifier)
    local acct = { balance = 0, createdAt = math.floor(Open77.time.unix()) }
    accounts[identifier] = acct
    if store.mode == "sql" then
        Open77.database.insert("INSERT INTO rp_bank_accounts (identifier, balance, created_at) VALUES (?, ?, ?)",
            { identifier, acct.balance, acct.createdAt })
    elseif store.mode == "kvp" then
        Open77.kvp.set("acct:" .. identifier, acct.balance)
        Open77.kvp.set("acct_created:" .. identifier, acct.createdAt)
    end
    log("new account %s balance=0", identifier)
    return acct
end

-- The account of an identifier, from the cache; in KVP mode a cold identifier is read from disk.
local function findAccount(identifier)
    local acct = accounts[identifier]
    if acct then return acct end
    if store.mode == "kvp" then
        local balance = Open77.kvp.get("acct:" .. identifier, nil)
        if balance ~= nil then
            acct = {
                balance = math.tointeger(balance) or 0,
                createdAt = Open77.kvp.get("acct_created:" .. identifier, 0),
            }
            accounts[identifier] = acct
            return acct
        end
    end
    return nil
end

-- Account of a connected player, created on first sight: nil, reason when the player is not there.
local function accountOf(playerId)
    local id, reason = toPlayerId(playerId)
    if not id then return nil, reason end
    if not store.ready then return nil, "bank_not_ready" end
    local identifier = Open77.players.identifier(id)
    if not identifier then return nil, "player_not_found" end
    local acct = findAccount(identifier) or createAccount(identifier)
    return acct, identifier, id
end

local function findSociety(name)
    local soc = societies[name]
    if soc then return soc end
    if store.mode == "kvp" then
        local balance = Open77.kvp.get("soc:" .. name, nil)
        if balance ~= nil then
            soc = { balance = math.tointeger(balance) or 0 }
            societies[name] = soc
            return soc
        end
    end
    return nil
end

local function ensureSociety(name)
    local soc = findSociety(name)
    if soc then return soc end
    soc = { balance = 0 }
    societies[name] = soc
    if store.mode == "sql" then
        Open77.database.insert("INSERT INTO rp_bank_societies (name, balance) VALUES (?, ?)", { name, 0 })
    elseif store.mode == "kvp" then
        Open77.kvp.set("soc:" .. name, 0)
    end
    log("new society %s balance=0", name)
    return soc
end

local function emitChanged(playerId, identifier, newBalance, delta, kind)
    local ok, reason = TriggerEvent("rp_bank:changed", playerId, identifier, newBalance, delta, kind)
    if not ok then warn("rp_bank:changed not published: %s", tostring(reason)) end
end

-- ---------------------------------------------------------------------------------------------
-- rp_economy bridge (server-only resource: reached through pcall, no dependency line)

local function cashBalance(playerId)
    local ok, balance = pcall(function() return exports.rp_economy:getBalance(playerId) end)
    if not ok then return nil, "wallet_unavailable" end
    return math.tointeger(balance) or 0
end

local function cashRemove(playerId, amount, reason)
    local ok, newBalance, why = pcall(function() return exports.rp_economy:remove(playerId, amount, reason) end)
    if not ok then return nil, "wallet_unavailable" end
    if newBalance == nil then
        if why == "insufficient_funds" then return nil, "insufficient_cash" end
        return nil, why or "wallet_refused"
    end
    return newBalance
end

local function cashAdd(playerId, amount, reason)
    local ok, newBalance, why = pcall(function() return exports.rp_economy:add(playerId, amount, reason) end)
    if not ok then return nil, "wallet_unavailable" end
    if newBalance == nil then return nil, why or "wallet_refused" end
    return newBalance
end

-- ---------------------------------------------------------------------------------------------
-- core operations (synchronous, never yield: safe behind exports.rp_bank:*)

local function getAccount(playerId)
    local acct, identifier = accountOf(playerId)
    if not acct then return nil, identifier end
    return { identifier = identifier, balance = acct.balance, createdAt = acct.createdAt }
end

local function deposit(playerId, amount)
    local acct, identifier, id = accountOf(playerId)
    if not acct then return nil, identifier end
    local n, reason = toAmount(amount)
    if not n then return nil, reason end
    if acct.balance + n > Config.MaxBalance then return nil, "balance_limit" end
    local _, cashReason = cashRemove(id, n, "bank:deposit")
    if cashReason then return nil, cashReason end
    acct.balance = acct.balance + n
    persistAccount(identifier)
    record(identifier, n, acct.balance, "deposit", nil)
    log("player %d deposit %d account=%d", id, n, acct.balance)
    emitChanged(id, identifier, acct.balance, n, "deposit")
    return acct.balance
end

local function withdraw(playerId, amount)
    local acct, identifier, id = accountOf(playerId)
    if not acct then return nil, identifier end
    local n, reason = toAmount(amount)
    if not n then return nil, reason end
    if acct.balance < n then return nil, "insufficient_funds" end
    -- Debit first, then hand the cash over; give the eddies back if the wallet refuses.
    acct.balance = acct.balance - n
    local _, cashReason = cashAdd(id, n, "bank:withdraw")
    if cashReason then
        acct.balance = acct.balance + n
        return nil, cashReason
    end
    persistAccount(identifier)
    record(identifier, -n, acct.balance, "withdraw", nil)
    log("player %d withdraw %d account=%d", id, n, acct.balance)
    emitChanged(id, identifier, acct.balance, -n, "withdraw")
    return acct.balance
end

-- Account to account. `fee` (optional, integer >= 0) is taken from the sender on top of `amount`
-- and leaves circulation. Returns the sender's new balance.
local function transfer(fromPlayerId, toIdentifier, amount, fee)
    local from, fromIdentifier, fromId = accountOf(fromPlayerId)
    if not from then return nil, fromIdentifier end
    if type(toIdentifier) ~= "string" or #toIdentifier < 1 or #toIdentifier > 96 then
        return nil, "unknown_recipient"
    end
    local n, reason = toAmount(amount)
    if not n then return nil, reason end
    local f = 0
    if fee ~= nil then
        f = math.tointeger(tonumber(fee) or -1) or -1
        if f < 0 or f > Config.MaxAmount then return nil, "invalid_amount" end
    end
    if toIdentifier == fromIdentifier then return nil, "self_transfer" end
    local to = findAccount(toIdentifier)
    if not to then return nil, "unknown_recipient" end
    if from.balance < n + f then return nil, "insufficient_funds" end
    if to.balance + n > Config.MaxBalance then return nil, "balance_limit" end

    from.balance = from.balance - n - f
    to.balance = to.balance + n
    persistAccount(fromIdentifier)
    persistAccount(toIdentifier)
    record(fromIdentifier, -n, from.balance + f, "transfer_out", "to:" .. toIdentifier)
    if f > 0 then record(fromIdentifier, -f, from.balance, "fee", "transfer:" .. toIdentifier) end
    record(toIdentifier, n, to.balance, "transfer_in", "from:" .. fromIdentifier)

    local toId = online[toIdentifier]
    log("player %d transfer %d fee %d to %s account=%d", fromId, n, f, toIdentifier, from.balance)
    if toId then log("player %d transfer_in %d from %s account=%d", toId, n, fromIdentifier, to.balance) end
    emitChanged(fromId, fromIdentifier, from.balance, -(n + f), "transfer_out")
    emitChanged(toId, toIdentifier, to.balance, n, "transfer_in")
    return from.balance
end

local function society(name)
    local clean, reason = cleanSocietyName(name)
    if not clean then return nil, reason end
    if not store.ready then return nil, "bank_not_ready" end
    local soc = ensureSociety(clean)
    return { name = clean, balance = soc.balance }
end

local function societyAdd(name, amount, reason)
    local clean, why = cleanSocietyName(name)
    if not clean then return nil, why end
    if not store.ready then return nil, "bank_not_ready" end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local note, noteReason = cleanNote(reason)
    if reason ~= nil and not note then return nil, noteReason end
    local soc = ensureSociety(clean)
    if soc.balance + n > Config.MaxBalance then return nil, "balance_limit" end
    soc.balance = soc.balance + n
    persistSociety(clean)
    record("society:" .. clean, n, soc.balance, "society_add", note)
    log("society %s +%d %s balance=%d", clean, n, note or "-", soc.balance)
    emitChanged(nil, "society:" .. clean, soc.balance, n, "society_add")
    return soc.balance
end

local function societyRemove(name, amount, reason)
    local clean, why = cleanSocietyName(name)
    if not clean then return nil, why end
    if not store.ready then return nil, "bank_not_ready" end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local note, noteReason = cleanNote(reason)
    if reason ~= nil and not note then return nil, noteReason end
    local soc = ensureSociety(clean)
    if soc.balance < n then return nil, "insufficient_funds" end
    soc.balance = soc.balance - n
    persistSociety(clean)
    record("society:" .. clean, -n, soc.balance, "society_remove", note)
    log("society %s -%d %s balance=%d", clean, n, note or "-", soc.balance)
    emitChanged(nil, "society:" .. clean, soc.balance, -n, "society_remove")
    return soc.balance
end

-- Account -> society, in one move: a fine, a hospital bill, a subscription. `reason` is a short
-- note kept on both ledgers. Returns the player's new account balance.
local function charge(playerId, amount, toSociety, reason)
    local acct, identifier, id = accountOf(playerId)
    if not acct then return nil, identifier end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local clean, why = cleanSocietyName(toSociety)
    if not clean then return nil, why end
    local note, noteReason = cleanNote(reason)
    if reason ~= nil and not note then return nil, noteReason end
    if acct.balance < n then return nil, "insufficient_funds" end
    local soc = ensureSociety(clean)
    if soc.balance + n > Config.MaxBalance then return nil, "balance_limit" end
    acct.balance = acct.balance - n
    soc.balance = soc.balance + n
    persistAccount(identifier)
    persistSociety(clean)
    record(identifier, -n, acct.balance, "charge", clean .. (note and (":" .. note) or ""))
    record("society:" .. clean, n, soc.balance, "society_add", "charge:" .. identifier)
    log("player %d charged %d to society %s (%s) account=%d", id, n, clean, note or "-", acct.balance)
    emitChanged(id, identifier, acct.balance, -n, "charge")
    emitChanged(nil, "society:" .. clean, soc.balance, n, "society_add")
    return acct.balance
end

-- ---------------------------------------------------------------------------------------------
-- exports (phase 1 contract + charge)

exports("getAccount", getAccount)
exports("deposit", deposit)
exports("withdraw", withdraw)
exports("transfer", transfer)
exports("society", society)
exports("societyAdd", societyAdd)
exports("societyRemove", societyRemove)
exports("charge", charge)

-- ---------------------------------------------------------------------------------------------
-- database boot: three states (ready / coming / never), the cache loads once

local function loadCacheFromSql()
    DB.update.await([[
        CREATE TABLE IF NOT EXISTS rp_bank_accounts (
            identifier VARCHAR(96) NOT NULL PRIMARY KEY,
            balance BIGINT NOT NULL DEFAULT 0,
            created_at BIGINT NOT NULL DEFAULT 0
        )
    ]])
    DB.update.await([[
        CREATE TABLE IF NOT EXISTS rp_bank_transactions (
            id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            identifier VARCHAR(96) NOT NULL,
            delta BIGINT NOT NULL,
            balance_after BIGINT NOT NULL,
            kind VARCHAR(32) NOT NULL,
            note VARCHAR(128) NULL,
            `at` BIGINT NOT NULL,
            INDEX idx_rp_bank_transactions_identifier (identifier, id)
        )
    ]])
    DB.update.await([[
        CREATE TABLE IF NOT EXISTS rp_bank_societies (
            name VARCHAR(64) NOT NULL PRIMARY KEY,
            balance BIGINT NOT NULL DEFAULT 0
        )
    ]])
    local rows = DB.query.await("SELECT identifier, balance, created_at FROM rp_bank_accounts") or {}
    for _, row in ipairs(rows) do
        accounts[row.identifier] = {
            balance = math.tointeger(tonumber(row.balance)) or 0,
            createdAt = math.tointeger(tonumber(row.created_at)) or 0,
        }
    end
    local socRows = DB.query.await("SELECT name, balance FROM rp_bank_societies") or {}
    for _, row in ipairs(socRows) do
        societies[row.name] = { balance = math.tointeger(tonumber(row.balance)) or 0 }
    end
    return #rows, #socRows
end

local function useKvp(why)
    store.mode = "kvp"
    store.ready = true
    warn("database not available (%s): balances fall back to Open77.kvp, the ledger stays in memory", tostring(why))
    log("store=kvp reason=%s", tostring(why))
end

local function bootStore()
    local queued, reason = Open77.database.ready(function()
        if store.mode == "kvp" then
            warn("database answered after the KVP fallback was chosen; staying on KVP for this boot")
            return
        end
        local ok, err = pcall(function()
            local nAccounts, nSocieties = loadCacheFromSql()
            store.mode = "sql"
            store.ready = true
            log("store=sql accounts=%d societies=%d", nAccounts, nSocieties)
        end)
        if not ok then
            Open77.log.error("schema or cache load failed: " .. tostring(err))
            useKvp("sql_boot_failed")
        end
    end)
    if not queued then
        -- database_unavailable / permission_denied: it will never fire, decide now.
        useKvp(reason)
    end
end

-- Wait (bounded) for the store to be decided; a database that is still connecting after the
-- grace period loses to the KVP fallback so a player is never stuck without an account.
local function waitForStore(graceMs)
    local waited = 0
    while not store.ready and waited < graceMs do
        Wait(250)
        waited = waited + 250
    end
    if not store.ready then
        local ready, why = Open77.database.isReady()
        if not ready then useKvp(why or "database_slow") end
    end
    return store.ready
end

-- ---------------------------------------------------------------------------------------------
-- ATM location check

local function nearestAtm(playerId, range)
    local pos = Open77.players.position(playerId)
    if not pos then return nil end
    local best, bestDist
    for _, atm in ipairs(Config.Atms) do
        local dx, dy = pos.x - atm.position.x, pos.y - atm.position.y
        local dz = math.abs(pos.z - atm.position.z)
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= range and dz <= Config.AtmHeightTolerance and (not bestDist or d < bestDist) then
            best, bestDist = atm, d
        end
    end
    return best, bestDist
end

local function atmById(id)
    if type(id) ~= "string" then return nil end
    for _, atm in ipairs(Config.Atms) do
        if atm.id == id then return atm end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- UI kit helpers (server twins, asynchronous: only from handlers, never from an export)

local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function relativeTime(at)
    local delta = math.floor(Open77.time.unix()) - (at or 0)
    if delta < 60 then return "just now" end
    if delta < 3600 then return ("%d min ago"):format(delta // 60) end
    if delta < 86400 then return ("%d h ago"):format(delta // 3600) end
    return ("%d d ago"):format(delta // 86400)
end

local KIND_LABEL = {
    deposit = "Deposit", withdraw = "Withdrawal", transfer_out = "Wire sent",
    transfer_in = "Wire received", fee = "Wire fee", charge = "Charge", society_add = "Society credit",
    society_remove = "Society debit",
}

-- Last N ledger lines, newest first (SQL when available, the memory ring otherwise).
local function history(identifier)
    if store.mode == "sql" then
        local rows = DB.query.await(
            "SELECT delta, balance_after, kind, note, `at` FROM rp_bank_transactions WHERE identifier = ? ORDER BY id DESC LIMIT "
                .. tostring(math.tointeger(Config.HistoryLimit) or 10),
            { identifier })
        if rows then
            local out = {}
            for _, row in ipairs(rows) do
                out[#out + 1] = {
                    delta = math.tointeger(tonumber(row.delta)) or 0,
                    balanceAfter = math.tointeger(tonumber(row.balance_after)) or 0,
                    kind = row.kind, note = row.note, at = math.tointeger(tonumber(row.at)) or 0,
                }
            end
            return out
        end
    end
    return recent[identifier] or {}
end

-- Resolve a recipient typed at the ATM: a connected player id, or a citizen id (identifier).
local function resolveRecipient(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    local id = toPlayerId(text)
    if id then
        -- A connected player always has an account (created on first sight).
        local acct, identifier = accountOf(id)
        if acct then return identifier, id end
    end
    if findAccount(text) then return text, online[text] end
    return nil
end

local function askAmount(playerId, title, description)
    local answer, reason = uikit("input", playerId, {
        title = title,
        description = description,
        fields = {
            { id = "amount", type = "number", label = "Amount (eddies)", min = 1, max = Config.MaxAmount, step = 1, required = true },
        },
        confirm = "Confirm", cancel = "Back", timeoutMs = 60000,
    })
    if answer == nil then return nil, reason end
    if not answer.ok then return nil, "cancelled" end
    return answer.value.amount
end

local function showHistory(playerId, identifier)
    local rows = history(identifier)
    local options = {}
    for i, tx in ipairs(rows) do
        local sign = tx.delta >= 0 and "+" or "-"
        options[#options + 1] = {
            id = "tx" .. i,
            label = ("%s%s  %s"):format(sign, formatMoney(math.abs(tx.delta)), KIND_LABEL[tx.kind] or tx.kind),
            description = ("%s  ·  balance %s%s"):format(relativeTime(tx.at), formatMoney(tx.balanceAfter),
                (tx.note and tx.note ~= "") and ("  ·  " .. tx.note) or ""),
            disabled = true,
        }
    end
    if #options == 0 then
        options[1] = { id = "none", label = "No transactions yet", description = "Your ledger is clean, choom.", disabled = true }
    end
    options[#options + 1] = { id = "back", label = "Back", icon = "<" }
    uikit("context", playerId, {
        id = "rp_bank_history",
        title = "Statement",
        description = ("Last %d operations"):format(Config.HistoryLimit),
        options = options,
    }, { timeoutMs = 60000 })
end

-- The ATM menu loop. `atm` is the ATM the player stands at.
-- ---------------------------------------------------------------------------
-- Staging: a pose, a prop in the hand (or at the feet) and a progress bar for
-- every action that manipulates something, so nothing completes instantly and
-- everybody around sees it. Pattern of rp_nomade's carry pose: profiles tried
-- in order through Open77.animations.get, every native call inside pcall, a
-- refusal logged once and never fatal. RP animations are workspots: the
-- platform cancels one when the player moves more than 0.5 m, so the UI-kit bar
-- keeps the player still (disable.move, client side); the server never freezes
-- anyone. Everything comes from Config.Stage (shared/config.lua).
-- ---------------------------------------------------------------------------

local STAGE = Config.Stage or {}
local STAGE_TAG = "[" .. GetCurrentResourceName() .. "]"
local stageWarned = {}          -- "<what>" -> true once logged
local stageResolved = {}        -- key -> { profile, clip } | false
local stageActive = {}          -- playerId -> { key, playbackId, props = { ids } } while staged

local function stageLog(fmt, ...)
    print((STAGE_TAG .. " " .. fmt):format(...))
end

local function stageWarnOnce(what, fmt, ...)
    if stageWarned[what] then return end
    stageWarned[what] = true
    stageLog(fmt, ...)
end

local function stageAnimationsApi()
    return type(Open77.animations) == "table" and type(Open77.animations.play) == "function"
end

local function stagePropsApi()
    return type(Open77.props) == "table" and type(Open77.props.attach) == "function"
end

-- First profile of `pose.profiles` the server's catalogue knows (memoised per key).
local function stageResolvePose(key, pose)
    if stageResolved[key] ~= nil then return stageResolved[key] or nil end
    local found = false
    if type(pose) == "table" and stageAnimationsApi() then
        for _, candidate in ipairs(pose.profiles or {}) do
            local ok, profile = pcall(Open77.animations.get, candidate.profile)
            if ok and type(profile) == "table" then
                local clip = candidate.clip
                if clip then
                    local known = false
                    for _, name in ipairs(profile.clips or {}) do
                        if name == clip then known = true break end
                    end
                    if not known then
                        stageLog("stage %s: clip %s is not in profile %s, using %s", key, clip, candidate.profile, tostring(profile.clip))
                        clip = nil
                    end
                end
                found = { profile = candidate.profile, clip = clip or profile.clip }
                break
            end
        end
    end
    stageResolved[key] = found
    if not found then
        local names = {}
        for _, candidate in ipairs(type(pose) == "table" and pose.profiles or {}) do names[#names + 1] = tostring(candidate.profile) end
        stageWarnOnce("pose:" .. key, "stage %s: no known profile among [%s], the action runs without a pose", key, table.concat(names, ", "))
    end
    return found or nil
end

local function stagePoseWord(key)
    local r = stageResolved[key]
    if not r then return "none" end
    return r.profile .. "/" .. tostring(r.clip)
end

-- Start a pose on a player. A `loop` pose runs until stagePoseStop; a one-shot uses
-- `durationMs` (the platform accepts 1 000..600 000 ms). Returns the playback id or nil.
local function stagePoseStart(playerId, key, pose, durationMs)
    if type(pose) ~= "table" then return nil end
    local resolved = stageResolvePose(key, pose)
    if not resolved then return nil end
    local options = {}
    if pose.loop == false then
        options.loop = false
        options.durationMs = math.floor(math.max(1000, math.min(600000, tonumber(durationMs) or tonumber(pose.durationMs) or 5000)))
    else
        options.loop = true
    end
    if resolved.clip then options.clip = resolved.clip end
    local ok, playback, reason = pcall(Open77.animations.play, playerId, resolved.profile, options)
    if ok and type(playback) == "table" and playback.playbackId then
        return playback.playbackId
    end
    if not ok then reason = playback end
    stageWarnOnce("play:" .. key .. ":" .. tostring(reason), "stage %s: pose %s refused for player %d: %s (the action runs without it)",
        key, resolved.profile, playerId, tostring(reason))
    return nil
end

local function stagePoseStop(playerId, playbackId)
    if not playbackId or not stageAnimationsApi() then return end
    local ok, stopped, why = pcall(Open77.animations.stop, playerId, playbackId)
    if ok and not stopped and why ~= "stale_playback" then
        stageLog("stage: pose stop refused for player %d: %s", playerId, tostring(why))
    end
end

-- Spawn a curated prop and make it follow the player (a hand slot, or the root frame:
-- +y where the player faces, +x their right, +z up, origin at the feet). Returns the
-- prop id and the model, or nil.
local function stagePropHold(playerId, key, prop)
    if type(prop) ~= "table" or not stagePropsApi() then return nil end
    local ok0, pos = pcall(Open77.players.position, playerId)
    if not ok0 or type(pos) ~= "table" or type(pos.x) ~= "number" then return nil end
    for _, model in ipairs(prop.models or {}) do
        local okC, id, reason = pcall(Open77.props.create, {
            model = model,
            position = { x = pos.x, y = pos.y, z = pos.z or 0.0 },
            yaw = 0.0,
            bucket = pos.bucket or 0,
        })
        if not okC then id, reason = nil, id end
        if id then
            local okA, attached, why = pcall(Open77.props.attach, id, {
                parentType = "player",
                parentId = playerId,
                bone = prop.bone or "",
                offset = prop.offset or { x = 0.0, y = 0.0, z = 0.0 },
                rotation = prop.rotation or { x = 0.0, y = 0.0, z = 0.0 },
            })
            if okA and attached then return id, model end
            if not okA then why = attached end
            pcall(Open77.props.remove, id)
            stageWarnOnce("attach:" .. key .. ":" .. model, "stage %s: attach of %s to player %d refused: %s (no prop shown)",
                key, model, playerId, tostring(why))
            return nil
        end
        stageWarnOnce("prop:" .. key .. ":" .. model, "stage %s: prop %s refused: %s", key, model, tostring(reason))
    end
    return nil
end

local function stagePropDrop(propId)
    if propId and stagePropsApi() then pcall(Open77.props.remove, propId) end
end

local function stageSlotWord(prop)
    if type(prop) ~= "table" then return "root" end
    return (prop.bone and prop.bone ~= "") and prop.bone or "root"
end

-- Everything a staged action put on a player is taken back.
local function stageFinish(playerId, entry)
    if not entry then return end
    if stageActive[playerId] == entry then stageActive[playerId] = nil end
    stagePoseStop(playerId, entry.playbackId)
    entry.playbackId = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
    entry.props = {}
end

-- Pose + props of `def` on a player, returned as an entry for stageFinish.
local function stageBegin(playerId, key, def, durationMs)
    local entry = { key = key, props = {}, words = {} }
    stageActive[playerId] = entry
    if STAGE.enabled == false or type(def) ~= "table" then return entry end
    entry.playbackId = stagePoseStart(playerId, key, def.pose, durationMs)
    if def.prop then
        local id, model = stagePropHold(playerId, key .. ".prop", def.prop)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.prop = model .. "@" .. stageSlotWord(def.prop)
        end
    end
    if def.place then
        local id, model = stagePropHold(playerId, key .. ".place", def.place)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.place = model
        end
    end
    return entry
end

-- The UI-kit bar (server twin). A plain wait keeps the beat when the kit is missing.
local function stageBar(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, definition)
    if not promise then
        if reason == "progress_active" or reason == "dialog_active" then return nil, reason end
        stageWarnOnce("uikit:" .. tostring(reason), "stage: uikit progress unavailable (%s), plain wait instead", tostring(reason))
        Wait(definition.duration)
        return { ok = true, outcome = "ok", fallback = true }
    end
    local answer, err = promise:await()
    if not answer then return nil, err end
    return answer
end

-- Run a staged action on `playerId`: pose + props + bar, then everything is cleaned up.
-- `key` names a Config.Stage entry; opts.label / opts.durationMs / opts.cancellable override
-- it. Returns the bar's answer ({ ok, outcome }) or nil, reason when the bar never showed.
-- Yields: capture `source` before calling.
local function stage(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 5000)
    local entry = stageBegin(playerId, key, def, durationMs)
    local answer, err = stageBar(playerId, {
        label = opts.label or def.label or key,
        duration = durationMs,
        position = "bottom",
        style = "bar",
        color = def.color or STAGE.color,
        cancellable = opts.cancellable ~= false,
        cancelKey = "X",
        disable = { move = true, combat = true },
    })
    stageFinish(playerId, entry)
    stageLog("player %d stage %s: pose=%s prop=%s place=%s %d ms -> %s", playerId, key, stagePoseWord(key),
        entry.words.prop or "none", entry.words.place or "none", durationMs,
        answer and (answer.ok and "ok" or tostring(answer.outcome or "cancelled")) or ("failed:" .. tostring(err)))
    return answer, err
end

-- A gesture without a bar (a hand-over, a wave, a sip): pose + props for `durationMs`,
-- taken back by a timer. Never yields. Returns the entry.
local function gesture(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 3000)
    local entry = stageBegin(playerId, key, def, durationMs)
    SetTimeout(durationMs, function() stageFinish(playerId, entry) end)
    stageLog("player %d gesture %s: pose=%s prop=%s %d ms", playerId, key, stagePoseWord(key), entry.words.prop or "none", durationMs)
    return entry
end

-- A pose held until stageRelease (a cuffed suspect, a patient on the ground). Never yields.
local function stageHold(playerId, key)
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local entry = stageBegin(playerId, key, def, nil)
    stageLog("player %d hold %s: pose=%s prop=%s", playerId, key, stagePoseWord(key), entry.words.prop or "none")
    return entry
end

local function stageRelease(playerId, entry)
    stageFinish(playerId, entry or stageActive[playerId])
end

-- Disconnect: the pose died with the player, the props must not survive them.
local function stageClear(playerId)
    local entry = stageActive[playerId]
    if not entry then return end
    stageActive[playerId] = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
end

local function runBankSession(playerId, atm)
    if sessions[playerId] then
        say(playerId, "You already have the bank open.")
        return
    end
    sessions[playerId] = true
    -- The typing pose on the terminal for as long as the menu is open (Config.Stage.atm).
    local atmPose = stageHold(playerId, "atm")
    local ok, err = pcall(function()
        while true do
            local acct, identifier = accountOf(playerId)
            if not acct then say(playerId, reasonText(identifier)); return end
            local cash = cashBalance(playerId)
            local answer, reason = uikit("context", playerId, {
                id = "rp_bank_main",
                title = "Night City Bank",
                description = ("%s  ·  Account %s  ·  Cash %s"):format(atm and atm.label or "Mobile banking",
                    formatMoney(acct.balance), cash and formatMoney(cash) or "unknown"),
                options = {
                    { id = "deposit",  label = "Deposit eddies",    icon = "+", description = "Cash into the account." },
                    { id = "withdraw", label = "Withdraw eddies",   icon = "-", description = "Account into cash." },
                    { id = "transfer", label = "Wire to a citizen", icon = ">", description = "Player id or citizen id. No fee at the ATM." },
                    { id = "history",  label = "Statement",         icon = "=", description = ("Last %d operations."):format(Config.HistoryLimit) },
                    { id = "leave",    label = "Leave",             icon = "x", tone = "danger" },
                },
            }, { timeoutMs = 60000 })
            if answer == nil then
                warn("bank menu for %d never answered (%s)", playerId, tostring(reason))
                if reason == "dialog_active" then say(playerId, "Close the other window first.") end
                return
            end
            if not answer.ok then return end
            local pick = answer.value and answer.value.id
            if pick == "deposit" then
                local amount, why = askAmount(playerId, "Deposit", ("Cash on you: %s"):format(cash and formatMoney(cash) or "unknown"))
                if amount then
                    stage(playerId, "process", { label = "Counting the eddies", cancellable = false })
                    local newBalance, failReason = deposit(playerId, amount)
                    if newBalance then
                        say(playerId, ("Deposited %s. Account: %s."):format(formatMoney(amount), formatMoney(newBalance)))
                    else
                        say(playerId, reasonText(failReason))
                    end
                elseif why ~= "cancelled" then
                    warn("deposit input for %d: %s", playerId, tostring(why))
                end
            elseif pick == "withdraw" then
                local amount, why = askAmount(playerId, "Withdraw", ("Account: %s"):format(formatMoney(acct.balance)))
                if amount then
                    stage(playerId, "process", { label = "Dispensing the eddies", cancellable = false })
                    local newBalance, failReason = withdraw(playerId, amount)
                    if newBalance then
                        say(playerId, ("Withdrew %s. Account: %s."):format(formatMoney(amount), formatMoney(newBalance)))
                    else
                        say(playerId, reasonText(failReason))
                    end
                elseif why ~= "cancelled" then
                    warn("withdraw input for %d: %s", playerId, tostring(why))
                end
            elseif pick == "transfer" then
                local form = uikit("input", playerId, {
                    title = "Wire transfer",
                    description = "Recipient: a connected player id (e.g. 3) or a citizen id.",
                    fields = {
                        { id = "to", type = "text", label = "Recipient", max = 96, required = true },
                        { id = "amount", type = "number", label = "Amount (eddies)", min = 1, max = Config.MaxAmount, step = 1, required = true },
                    },
                    confirm = "Wire it", cancel = "Back", timeoutMs = 60000,
                })
                if form and form.ok then
                    local toIdentifier, toId = resolveRecipient(form.value.to)
                    if not toIdentifier then
                        say(playerId, reasonText("unknown_recipient"))
                    else
                        local amount = form.value.amount
                        stage(playerId, "process", { label = "Wiring the eddies", cancellable = false })
                        local newBalance, failReason = transfer(playerId, toIdentifier, amount, 0)
                        if newBalance then
                            local who = toId and Open77.players.name(toId) or toIdentifier
                            say(playerId, ("Wired %s to %s. Account: %s."):format(formatMoney(amount), tostring(who), formatMoney(newBalance)))
                            if toId then
                                say(toId, ("%s wired you %s."):format(Open77.players.name(playerId) or "Someone", formatMoney(amount)))
                            end
                        else
                            say(playerId, reasonText(failReason))
                        end
                    end
                end
            elseif pick == "history" then
                showHistory(playerId, identifier)
            else
                return
            end
            -- A dialog is a long time in a game world: make sure the player is still at the ATM.
            if atm and not nearestAtm(playerId, Config.AtmPromptRange + 2.0) then
                say(playerId, "You walked away from the ATM.")
                return
            end
        end
    end)
    stageRelease(playerId, atmPose)
    sessions[playerId] = nil
    if not ok then Open77.log.error("bank session for " .. tostring(playerId) .. " failed: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------------------------
-- lifecycle

local SUGGESTIONS = {
    { command = "/bank", help = "Open the bank menu at an ATM (within 3 m)" },
    { command = "/solde", help = "Your cash and account balance" },
    { command = "/virement", help = "Wire eddies to a connected player (1 % fee, min 1)",
      parameters = { { name = "playerId", help = "Connected player id" }, { name = "amount", help = "Eddies to send" } } },
    { command = "/societe", help = "Your job's society balance" },
}

-- The ATM terminals: one prop per configured ATM (Config.AtmProp.model at atm.prop), owned by
-- this resource and removed on stop. A refusal only logs: the ring and the prompt still work.
local atmProps = {}      -- atm id -> prop id (decimal string)

local function spawnAtmProps()
    local model = Config.AtmProp and Config.AtmProp.model
    if not model then return end
    for _, atm in ipairs(Config.Atms) do
        local at = atm.prop
        if at and not atmProps[atm.id] then
            local id, reason = Open77.props.create({
                model = model,
                position = { x = at.x, y = at.y, z = at.z },
                yaw = at.yaw or 0.0,
                bucket = 0,
                streamingRadius = Config.AtmProp.streamingRadius or 120.0,
            })
            if id then
                atmProps[atm.id] = id
                log("terminal prop %s for %s at %.1f %.1f %.1f", tostring(id), atm.id, at.x, at.y, at.z)
            else
                log("terminal prop for %s not spawned (%s): the ring alone marks it", atm.id, tostring(reason))
            end
        end
    end
end

local function removeAtmProps()
    for atmId, propId in pairs(atmProps) do
        Open77.props.remove(propId)
        atmProps[atmId] = nil
    end
end

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    bootStore()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    log("started, %d ATMs configured", #Config.Atms)
    local spawned, err = pcall(spawnAtmProps)
    if not spawned then log("terminal props failed: %s", tostring(err)) end
    -- Players already in the world when the resource (re)starts.
    for _, id in ipairs(Open77.players.all()) do
        local identifier = Open77.players.identifier(id)
        if identifier then online[identifier] = id end
    end
end)

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source <= 0 then return end
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onPlayerReady", function(playerId)
    local id = toPlayerId(playerId)
    if not id then return end
    local identifier = Open77.players.identifier(id)
    if not identifier then return end
    online[identifier] = id
    if not waitForStore(15000) then return end
    -- The player may have left during the wait.
    if Open77.players.identifier(id) ~= identifier then online[identifier] = nil; return end
    local acct = findAccount(identifier) or createAccount(identifier)
    say(id, ("Account balance: %s."):format(formatMoney(acct.balance)))
    log("player %d loaded %s account=%d", id, identifier, acct.balance)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    removeAtmProps()
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = toPlayerId(playerId)
    if not id then return end
    sessions[id] = nil
    stageClear(id)
    for identifier, onlineId in pairs(online) do
        if onlineId == id then online[identifier] = nil end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- ATM prompt intent (client -> server)

RegisterNetEvent("rp_bank:useAtm", function(atmId)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local atm = atmById(atmId)
    if not atm then return end
    local near = nearestAtm(playerId, Config.AtmPromptRange)
    if not near or near.id ~= atm.id then
        say(playerId, "Get closer to the ATM.")
        return
    end
    runBankSession(playerId, atm)
end)

-- ---------------------------------------------------------------------------------------------
-- commands

RegisterCommand("bank", function(source)
    if source == 0 then return print("bank: run this from the game, not the console") end
    local atm = nearestAtm(source, Config.AtmRange)
    if not atm then
        say(source, "No ATM within 3 m. Find one on the map.")
        return
    end
    runBankSession(source, atm)
end, false)

RegisterCommand("solde", function(source)
    if source == 0 then return print("solde: run this from the game, not the console") end
    local cash, cashReason = cashBalance(source)
    local acct, reason = accountOf(source)
    local cashText = cash and formatMoney(cash) or ("unavailable (" .. tostring(cashReason) .. ")")
    local acctText = acct and formatMoney(acct.balance) or ("unavailable: " .. reasonText(reason))
    say(source, ("Cash: %s  ·  Account: %s"):format(cashText, acctText))
end, false)

RegisterCommand("virement", function(source, args)
    if source == 0 then return print("virement: run this from the game, not the console") end
    local targetId = toPlayerId(args[1])
    local amount = toAmount(args[2])
    if not targetId or not amount then
        say(source, "Usage: /virement <playerId> <amount>  (1 % fee, at least 1 eddie)")
        return
    end
    if targetId == source then say(source, reasonText("self_transfer")); return end
    -- accountOf creates the account of a connected player who has none yet.
    local targetAcct, toIdentifier = accountOf(targetId)
    if not targetAcct then
        say(source, reasonText(toIdentifier == "bank_not_ready" and "bank_not_ready" or "player_not_found"))
        return
    end
    local fee = math.max(Config.TransferFeeMin, math.ceil(amount * Config.TransferFeePercent / 100))
    local newBalance, reason = transfer(source, toIdentifier, amount, fee)
    if not newBalance then
        say(source, reasonText(reason))
        return
    end
    local targetName = Open77.players.name(targetId) or ("player " .. targetId)
    say(source, ("Wired %s to %s (fee %s). Account: %s."):format(formatMoney(amount), targetName, formatMoney(fee), formatMoney(newBalance)))
    say(targetId, ("%s wired you %s. Check /solde."):format(Open77.players.name(source) or "Someone", formatMoney(amount)))
end, false)

RegisterCommand("societe", function(source)
    if source == 0 then return print("societe: run this from the game, not the console") end
    local ok, job = pcall(function() return exports.rp_jobs:getJob(source) end)
    if not ok then
        say(source, "The jobs service (rp_jobs) is offline.")
        return
    end
    if type(job) ~= "string" or job == "" then
        say(source, "You have no job, choom. No society, no funds.")
        return
    end
    local soc, reason = society(job)
    if not soc then say(source, reasonText(reason)); return end
    say(source, ("Society %s: %s."):format(soc.name, formatMoney(soc.balance)))
end, false)
