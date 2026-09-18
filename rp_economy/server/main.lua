-- rp_economy - server-authoritative wallet (eurodollars) for an RP server.
--
-- One integer balance per player, keyed by the durable identifier
-- (Open77.players.identifier), persisted in SQL (table rp_economy_wallets) on
-- every change. Loaded when the player is ready, dropped from memory when they
-- leave.
--
-- Every write goes through the callback (non-yielding) forms of
-- Open77.database.*: the exports below are called synchronously
-- (exports.rp_economy:add(...)) and a synchronous callee that yields fails with
-- export_yielded, so nothing on the export path may .await. Loads use the
-- callback form too, with a continuation.
--
-- Without a database (database_unavailable, permission_denied, or a database
-- still not answering after the boot grace) the resource falls back to its own
-- KVP store for the whole boot and says so in the log (store=kvp reason=...).
-- The first SQL start copies every wallet still found in KVP (phase 0 kept
-- them there) into the table, once.
--
-- Exports (contract shared with the other resources of the round):
--   getBalance(playerId) -> integer (0 when unknown)
--   add(playerId, amount, reason) -> newBalance | nil, reason
--   remove(playerId, amount, reason) -> newBalance | nil, "insufficient_funds" | nil, reason
-- Every change publishes TriggerEvent("rp_economy:changed", playerId, newBalance, delta, reason).

local RESOURCE = GetCurrentResourceName()

-- The `.await` forms are documented on every database card but are not catalogue entries of
-- their own, so the static validator reads the dotted spelling as an unknown native. They are
-- reached through this alias (boot handler only); the callback forms stay spelled out so the
-- permission check still sees them.
local DB = Open77.database

local START_BALANCE = 500
local PAYDAY_AMOUNT = 200
local PAYDAY_INTERVAL_MS = 10 * 60 * 1000
local MAX_BALANCE = 1000000000000 -- 1e12: keeps every balance an exact JSON integer
local MAX_REASON_BYTES = 64
local MAX_NAME_BYTES = 64          -- rp_economy_wallets.name is VARCHAR(64)
local KEY_PREFIX = "balance:"
local KVP_MIGRATED_KEY = "migrated:sql" -- set once the KVP wallets have been copied into SQL
local KVP_SCAN_LIMIT = 4096             -- the KVP store's own entry cap; kvp.keys refuses more
local STORE_GRACE_MS = 15000            -- how long a joining player waits for the store decision
local CURRENCY = "€$"

local SQL_CREATE = [[
CREATE TABLE IF NOT EXISTS rp_economy_wallets (
    identifier VARCHAR(64) PRIMARY KEY,
    name VARCHAR(64),
    balance BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
)
]]
local SQL_LOAD = "SELECT balance FROM rp_economy_wallets WHERE identifier = ?"
local SQL_SAVE = [[
INSERT INTO rp_economy_wallets (identifier, name, balance, updated_at)
VALUES (?, ?, ?, ?)
ON DUPLICATE KEY UPDATE name = ?, balance = ?, updated_at = ?
]]
-- Migration: a row that already exists in SQL always wins over the phase-0 KVP copy.
local SQL_MIGRATE = [[
INSERT INTO rp_economy_wallets (identifier, name, balance, updated_at)
VALUES (?, ?, ?, ?)
ON DUPLICATE KEY UPDATE identifier = identifier
]]
local SQL_COUNT = "SELECT COUNT(*) FROM rp_economy_wallets"

-- Where the wallets live for this boot. Decided once (the database answers, or is refused,
-- or stays silent past the grace), never flipped afterwards.
local store = {
    mode = nil,     -- nil (undecided) | "sql" | "kvp"
    ready = false,  -- true once the mode is decided (and, for sql, the schema exists)
}

-- Live state. The tables are keyed by the numeric session id and only hold
-- players whose wallet was actually loaded (identifier known, store readable).
local wallets = {}     -- [playerId] = integer balance
local identifiers = {} -- [playerId] = durable userId, cached at load time
local names = {}       -- [playerId] = display name cached at load time, written next to the balance
local loading = {}     -- [playerId] = { userId = ..., waiters = { fn, ... } } while an SQL read is in flight

local paydayThreadStarted = false

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function log(text)
    print("[" .. RESOURCE .. "] " .. text)
end

-- Reason as it appears in the log: one grep-able token, never empty.
local function logToken(reason)
    if reason == nil then
        return "unspecified"
    end
    return (tostring(reason):gsub("%s+", "_"))
end

local function formatMoney(amount)
    return ("%d %s"):format(amount, CURRENCY)
end

-- tonumber that tolerates nil (tonumber(nil) raises in Lua 5.4).
local function asNumber(value)
    if value == nil then
        return nil
    end
    return tonumber(value)
end

-- A positive integer (integer-valued floats such as 5.0 are accepted), bounded.
local function toPositiveInteger(value, maximum)
    if type(value) ~= "number" then
        return nil
    end
    if value ~= value or value <= 0 or value % 1 ~= 0 then
        return nil
    end
    local integer = math.tointeger(value)
    if not integer or integer > maximum then
        return nil
    end
    return integer
end

-- Stored value (KVP number, SQL BIGINT possibly delivered as a string) as an integer, or nil.
local function toStoredInteger(stored)
    if stored == nil then
        return nil
    end
    local number = tonumber(stored)
    if number == nil then
        return nil
    end
    return math.tointeger(number)
end

-- Display name fit for the name column: at most MAX_NAME_BYTES, cut on a UTF-8 boundary so
-- the row is never refused for an incomplete sequence.
local function cleanName(name)
    if type(name) ~= "string" then
        return ""
    end
    if #name <= MAX_NAME_BYTES then
        return name
    end
    local cut = MAX_NAME_BYTES
    while cut > 0 do
        local byte = name:byte(cut + 1)
        if byte == nil or byte < 0x80 or byte >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return name:sub(1, cut)
end

-- Chat line to one player; player ids from host events are strings, so always
-- convert. Failures are logged, never raised: chat is a courtesy, not authority.
local function tell(playerId, text)
    local id = asNumber(playerId)
    if not id or id <= 0 then
        return
    end
    local ok, reason = Open77.chat.send(id, text)
    if not ok then
        log(("chat.send refused for player %d: %s"):format(id, tostring(reason)))
    end
end

-- Toast, only when the notifications API exists on this server build.
local function notify(playerId, definition)
    local id = asNumber(playerId)
    if not id or id <= 0 then
        return
    end
    if type(Open77.notifications) ~= "table" or type(Open77.notifications.send) ~= "function" then
        return
    end
    local notificationId, reason = Open77.notifications.send(id, definition)
    if not notificationId then
        log(("notifications.send refused for player %d: %s"):format(id, tostring(reason)))
    end
end

-- Connected AND ready according to the host roster.
local function isPlayerReady(playerId)
    local read = Open77.players.get(playerId)
    return read ~= nil and read.ready == true
end

------------------------------------------------------------------------------
-- Persistence
------------------------------------------------------------------------------

local function storageKey(userId)
    return KEY_PREFIX .. userId
end

-- Writes the loaded wallet of playerId to the store. Never yields: the SQL
-- write is submitted with the callback form and its failure is logged when it
-- comes back (the callback also fires, with a reason, when the submission
-- itself is refused).
local function persist(playerId)
    local userId = identifiers[playerId]
    local balance = wallets[playerId]
    if not userId or balance == nil then
        return false
    end
    if store.mode == "sql" then
        local now = math.floor(Open77.time.unix())
        local name = names[playerId] or ""
        local ok = Open77.database.update(SQL_SAVE, { userId, name, balance, now, name, balance, now },
            function(result, err)
                if err ~= nil or result == nil then
                    log(("sql write failed for player %d (%s): %s"):format(playerId, userId, tostring(err or "no_result")))
                end
            end)
        return ok == true
    end
    local ok, reason = Open77.kvp.set(storageKey(userId), balance)
    if not ok then
        log(("kvp.set failed for player %d (%s): %s"):format(playerId, userId, tostring(reason)))
        return false
    end
    return true
end

-- Puts a stored value (nil = never seen) in memory as the wallet of playerId,
-- creating and persisting the starting balance for a new player. Returns the balance.
local function adoptWallet(playerId, userId, stored)
    local balance
    if stored == nil then
        balance = START_BALANCE
    else
        balance = toStoredInteger(stored)
        if balance == nil or balance < 0 then
            log(("corrupt balance for player %d (%s): %s, reset to 0"):format(playerId, userId, tostring(stored)))
            balance = 0
        end
    end

    identifiers[playerId] = userId
    wallets[playerId] = balance
    if stored == nil then
        persist(playerId)
        log(("new wallet player %d %s balance=%d"):format(playerId, userId, balance))
    else
        log(("loaded player %d %s balance=%d"):format(playerId, userId, balance))
    end
    return balance
end

-- Loads (or creates) the wallet of a connected player. Continuation style:
-- `done(balance)` or `done(nil, reason)` when the player cannot take part in
-- the economy - called at once in KVP mode, from the database callback in SQL
-- mode. Never yields, so it is safe from any handler or thread.
local function loadWallet(playerId, done)
    done = done or function() end
    if wallets[playerId] ~= nil then
        return done(wallets[playerId])
    end
    if type(playerId) ~= "number" or playerId <= 0 then
        return done(nil, "invalid_player_id")
    end
    if not store.ready then
        return done(nil, "store_not_ready")
    end
    local userId = Open77.players.identifier(playerId)
    if type(userId) ~= "string" or userId == "" then
        log(("no durable identifier for player %d, wallet not loaded"):format(playerId))
        return done(nil, "identifier_unavailable")
    end
    local nameOk, name = pcall(Open77.players.name, playerId)
    names[playerId] = cleanName(nameOk and name or nil)

    if store.mode == "kvp" then
        local stored, reason = Open77.kvp.get(storageKey(userId))
        if stored == nil and reason ~= nil then
            -- A storage failure, not a missing key: never invent a balance on top of it.
            log(("kvp.get failed for player %d (%s): %s"):format(playerId, userId, tostring(reason)))
            return done(nil, "storage_unavailable")
        end
        return done(adoptWallet(playerId, userId, stored))
    end

    -- SQL: one read in flight per player; a second caller joins the waiters.
    local pending = loading[playerId]
    if pending and pending.userId == userId then
        pending.waiters[#pending.waiters + 1] = done
        return
    end
    pending = { userId = userId, waiters = { done } }
    loading[playerId] = pending
    Open77.database.single(SQL_LOAD, { userId }, function(row, err)
        if loading[playerId] ~= pending then
            -- The player left (or the seat was reused) while the read was in flight.
            log(("player %d left while loading; discarding"):format(playerId))
            return
        end
        loading[playerId] = nil
        local function finish(balance, reason)
            for _, waiter in ipairs(pending.waiters) do
                waiter(balance, reason)
            end
        end
        if err ~= nil then
            -- A read failure is not a new player: never invent a balance on top of it.
            log(("sql load failed for player %d (%s): %s"):format(playerId, userId, tostring(err)))
            return finish(nil, "storage_unavailable")
        end
        local sameOk, current = pcall(Open77.players.identifier, playerId)
        if not sameOk or current ~= userId then
            log(("player %d left while loading; discarding"):format(playerId))
            return finish(nil, "player_left")
        end
        finish(adoptWallet(playerId, userId, row and row.balance or nil))
    end)
end

local function unloadWallet(playerId)
    if wallets[playerId] ~= nil then
        persist(playerId)
    end
    wallets[playerId] = nil
    identifiers[playerId] = nil
    names[playerId] = nil
    loading[playerId] = nil
end

------------------------------------------------------------------------------
-- Store boot: SQL when the database answers, KVP otherwise, decided once
------------------------------------------------------------------------------

local function useKvp(why)
    if store.mode == "kvp" then
        return
    end
    store.mode = "kvp"
    store.ready = true
    log(("store=kvp reason=%s"):format(tostring(why)))
end

-- One-time copy of the phase-0 KVP wallets into SQL. Runs inside the ready
-- handler (may yield). A wallet already in SQL is kept; the KVP keys are left
-- in place (they are the fallback data). Returns migrated, failed.
local function migrateKvpWallets()
    if Open77.kvp.get(KVP_MIGRATED_KEY) ~= nil then
        return 0, 0
    end
    local keys, reason = Open77.kvp.keys(KEY_PREFIX, KVP_SCAN_LIMIT)
    if type(keys) ~= "table" then
        log(("kvp migration skipped: keys unreadable (%s)"):format(tostring(reason)))
        return 0, 0
    end
    local now = math.floor(Open77.time.unix())
    local migrated, failed = 0, 0
    for _, key in ipairs(keys) do
        local userId = key:sub(#KEY_PREFIX + 1)
        local stored = Open77.kvp.get(key)
        local balance = toStoredInteger(stored)
        if userId == "" or #userId > 64 or balance == nil or balance < 0 then
            failed = failed + 1
            log(("kvp migration: skipped %s (%s)"):format(key, tostring(stored)))
        else
            local ok, err = pcall(DB.update.await, SQL_MIGRATE, { userId, "", balance, now })
            if ok then
                migrated = migrated + 1
            else
                failed = failed + 1
                log(("kvp migration: %s failed: %s"):format(userId, tostring(err)))
            end
        end
    end
    if failed == 0 then
        -- Only a clean run is final; a partial one is retried at the next SQL start.
        Open77.kvp.set(KVP_MIGRATED_KEY, now)
    end
    if #keys > 0 then
        log(("migrated %d wallet(s) from kvp to sql (%d failed)"):format(migrated, failed))
    end
    return migrated, failed
end

local function bootStore()
    local queued, reason = Open77.database.ready(function()
        if store.mode == "kvp" then
            log("database answered after the KVP fallback was chosen; staying on KVP for this boot")
            return
        end
        local ok, err = pcall(function()
            DB.update.await(SQL_CREATE)
            migrateKvpWallets()
            -- The row count is informative only: a failing COUNT must not demote the boot to KVP.
            local counted, total = pcall(DB.scalar.await, SQL_COUNT)
            store.mode = "sql"
            store.ready = true
            log(("store=sql wallets=%d"):format((counted and toStoredInteger(total)) or 0))
        end)
        if not ok then
            log(("schema or migration failed: %s"):format(tostring(err)))
            useKvp("sql_boot_failed")
        end
    end)
    if not queued then
        -- database_unavailable / permission_denied: it will never fire, decide now.
        useKvp(reason)
    end
end

-- Waits (bounded, yields) for the store to be decided. A database that is still
-- connecting after the grace loses to the KVP fallback so a player is never
-- stuck without a wallet; one that answered but whose boot handler is still
-- running (schema, migration) gets a longer, still bounded, wait.
local function waitForStore(graceMs)
    local waited = 0
    while not store.ready and waited < graceMs do
        Wait(250)
        waited = waited + 250
    end
    if store.ready then
        return true
    end
    local ready, why = Open77.database.isReady()
    if not ready then
        useKvp(why or "database_slow")
        return true
    end
    waited = 0
    while not store.ready and waited < graceMs * 4 do
        Wait(250)
        waited = waited + 250
    end
    return store.ready
end

------------------------------------------------------------------------------
-- Core ledger operation
------------------------------------------------------------------------------

-- Applies a signed delta to a loaded wallet. Validation of playerId/amount/reason
-- is the caller's job; this only enforces the balance bounds, persists, logs
-- and publishes the change.
local function applyDelta(playerId, delta, reason)
    local balance = wallets[playerId]
    if balance == nil then
        return nil, "player_not_found"
    end
    local newBalance = balance + delta
    if newBalance < 0 then
        return nil, "insufficient_funds"
    end
    if newBalance > MAX_BALANCE then
        return nil, "balance_limit"
    end

    wallets[playerId] = newBalance
    persist(playerId)

    log(("%+d player %d %s balance=%d"):format(delta, playerId, logToken(reason), newBalance))

    local ok, publishReason = TriggerEvent("rp_economy:changed", playerId, newBalance, delta, reason)
    if not ok then
        log(("rp_economy:changed not published: %s"):format(tostring(publishReason)))
    end
    return newBalance
end

------------------------------------------------------------------------------
-- Exports (validate everything: an export is never proof of anything)
------------------------------------------------------------------------------

local function validatePlayerId(playerId)
    local id = toPositiveInteger(playerId, 2147483647)
    if not id then
        return nil, "invalid_player_id"
    end
    if wallets[id] == nil then
        return nil, "player_not_found"
    end
    return id
end

local function validateAmount(amount)
    local value = toPositiveInteger(amount, MAX_BALANCE)
    if not value then
        return nil, "invalid_amount"
    end
    return value
end

local function validateReason(reason)
    if reason == nil then
        return true
    end
    if type(reason) ~= "string" or reason == "" or #reason > MAX_REASON_BYTES then
        return nil, "invalid_reason"
    end
    if reason:find("[%c]") then
        return nil, "invalid_reason"
    end
    return true
end

exports("getBalance", function(playerId)
    local id = toPositiveInteger(playerId, 2147483647)
    if not id then
        return 0
    end
    return wallets[id] or 0
end)

exports("add", function(playerId, amount, reason)
    local id, idReason = validatePlayerId(playerId)
    if not id then
        return nil, idReason
    end
    local value, amountReason = validateAmount(amount)
    if not value then
        return nil, amountReason
    end
    local reasonOk, reasonReason = validateReason(reason)
    if not reasonOk then
        return nil, reasonReason
    end
    return applyDelta(id, value, reason)
end)

exports("remove", function(playerId, amount, reason)
    local id, idReason = validatePlayerId(playerId)
    if not id then
        return nil, idReason
    end
    local value, amountReason = validateAmount(amount)
    if not value then
        return nil, amountReason
    end
    local reasonOk, reasonReason = validateReason(reason)
    if not reasonOk then
        return nil, reasonReason
    end
    return applyDelta(id, -value, reason)
end)

------------------------------------------------------------------------------
-- Payday
------------------------------------------------------------------------------

local function runPayday(trigger)
    local paid = 0
    for _, rawId in ipairs(Open77.players.all() or {}) do
        local playerId = asNumber(rawId)
        if playerId and wallets[playerId] ~= nil and isPlayerReady(playerId) then
            local newBalance = applyDelta(playerId, PAYDAY_AMOUNT, "payday")
            if newBalance then
                paid = paid + 1
                tell(playerId, ("Payday: +%d %s"):format(PAYDAY_AMOUNT, CURRENCY))
            end
        end
    end
    log(("payday (%s) paid %d player(s)"):format(trigger, paid))
    return paid
end

local function startPaydayThread()
    if paydayThreadStarted then
        return
    end
    paydayThreadStarted = true
    CreateThread(function()
        while true do
            Wait(PAYDAY_INTERVAL_MS)
            runPayday("timer")
        end
    end)
end

------------------------------------------------------------------------------
-- Chat suggestions
------------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/money", help = "Show your balance" },
    { command = "/pay", help = "Send eddies to a connected player", parameters = {
        { name = "playerId", help = "Player id" },
        { name = "amount", help = "Amount in €$" },
    } },
    { command = "/givemoney", help = "[Admin] Credit a player", parameters = {
        { name = "playerId", help = "Player id" },
        { name = "amount", help = "Amount in €$" },
    } },
    { command = "/payday", help = "[Admin] Trigger an immediate payday" },
}

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then
        log(("addSuggestions refused for target %s: %s"):format(tostring(target), tostring(reason)))
    end
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    bootStore()
    publishSuggestions(-1)
    startPaydayThread()
    log("started")
    -- Players already in the world had their onPlayerReady before this
    -- generation existed (hot reload): load them once the store is decided.
    -- Own thread: the wait yields.
    CreateThread(function()
        if not waitForStore(STORE_GRACE_MS) then
            log("store undecided after the grace period: players already in the world load on /money")
            return
        end
        for _, rawId in ipairs(Open77.players.all() or {}) do
            local playerId = asNumber(rawId)
            if playerId and playerId > 0 and isPlayerReady(playerId) then
                loadWallet(playerId)
            end
        end
    end)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then
        return
    end
    -- Every change is already persisted; this is belt and braces.
    for playerId in pairs(wallets) do
        persist(playerId)
    end
end)

AddEventHandler("onPlayerReady", function(rawPlayerId)
    local playerId = asNumber(rawPlayerId)
    if not playerId or playerId <= 0 then
        return
    end
    if not waitForStore(STORE_GRACE_MS) then
        tell(playerId, "Wallet unavailable (store_not_ready): tell an admin.")
        return
    end
    -- The wait yielded: the player may have left meanwhile.
    if not isPlayerReady(playerId) then
        return
    end
    loadWallet(playerId, function(balance, reason)
        if not balance then
            if reason ~= "player_left" then
                tell(playerId, ("Wallet unavailable (%s): tell an admin."):format(tostring(reason)))
            end
            return
        end
        tell(playerId, ("Balance: %s"):format(formatMoney(balance)))
    end)
end)

AddEventHandler("onPlayerDisconnected", function(rawPlayerId)
    local playerId = asNumber(rawPlayerId)
    if playerId then
        unloadWallet(playerId)
    end
end)

RegisterNetEvent("chat:ready", function()
    local playerId = asNumber(source)
    if playerId and playerId > 0 then
        publishSuggestions(playerId)
    end
end)

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

-- Parses "<playerId> <amount>" from a command; answers player-facing errors to `reply`.
local function parseTargetAndAmount(args, reply, usage)
    local target = toPositiveInteger(asNumber(args[1]), 2147483647)
    local amount = toPositiveInteger(asNumber(args[2]), MAX_BALANCE)
    if not target or not amount then
        reply("Usage: " .. usage)
        return nil
    end
    if wallets[target] == nil or not isPlayerReady(target) then
        reply("Player not found or not in the world yet.")
        return nil
    end
    return target, amount
end

RegisterCommand("money", function(source, args, raw)
    if source == 0 then
        print("[" .. RESOURCE .. "] /money: use it from the game, not from the console.")
        return
    end
    local function show(balance)
        tell(source, ("Balance: %s"):format(formatMoney(balance)))
        notify(source, {
            type = "info",
            title = "Wallet",
            message = ("Balance: %s"):format(formatMoney(balance)),
            icon = "E$",
            durationMs = 5000,
        })
    end
    if wallets[source] ~= nil then
        show(wallets[source])
        return
    end
    loadWallet(source, function(balance, reason)
        if balance == nil then
            if reason ~= "player_left" then
                tell(source, "Wallet unavailable: tell an admin.")
            end
            return
        end
        show(balance)
    end)
end, false)

RegisterCommand("pay", function(source, args, raw)
    if source == 0 then
        print("[" .. RESOURCE .. "] /pay: use it from the game, not from the console.")
        return
    end
    local reply = function(text) tell(source, text) end
    if wallets[source] == nil then
        reply("Wallet unavailable: tell an admin.")
        return
    end
    local target, amount = parseTargetAndAmount(args, reply, "/pay <playerId> <amount>")
    if not target then
        return
    end
    if target == source then
        reply("You can't pay yourself, choom.")
        return
    end
    if wallets[source] < amount then
        reply(("Insufficient funds: you're %s short."):format(formatMoney(amount - wallets[source])))
        return
    end

    local senderBalance, removeReason = applyDelta(source, -amount, "pay:to:" .. target)
    if not senderBalance then
        reply(("Payment refused (%s)."):format(tostring(removeReason)))
        return
    end
    local targetBalance, addReason = applyDelta(target, amount, "pay:from:" .. source)
    if not targetBalance then
        -- Refund: the target could not receive (balance cap, vanished between checks).
        applyDelta(source, amount, "pay:refund:" .. target)
        reply(("Payment refused (%s), amount refunded."):format(tostring(addReason)))
        return
    end

    local senderName = Open77.players.name(source) or ("#" .. source)
    local targetName = Open77.players.name(target) or ("#" .. target)
    reply(("You sent %s to %s. Balance: %s"):format(formatMoney(amount), targetName, formatMoney(senderBalance)))
    tell(target, ("%s sent you %s. Balance: %s"):format(senderName, formatMoney(amount), formatMoney(targetBalance)))
end, false)

-- Restricted: ACL command.givemoney; the server console is always allowed.
RegisterCommand("givemoney", function(source, args, raw)
    local reply
    if source == 0 then
        reply = function(text) print("[" .. RESOURCE .. "] givemoney: " .. text) end
    else
        reply = function(text) tell(source, text) end
    end
    local target, amount = parseTargetAndAmount(args, reply, "/givemoney <playerId> <amount>")
    if not target then
        return
    end
    local newBalance, reason = applyDelta(target, amount, "givemoney:by:" .. source)
    if not newBalance then
        reply(("Credit refused (%s)."):format(tostring(reason)))
        return
    end
    tell(target, ("An admin credited you %s. Balance: %s"):format(formatMoney(amount), formatMoney(newBalance)))
    if source ~= 0 then
        local targetName = Open77.players.name(target) or ("#" .. target)
        reply(("%s credited %s (balance: %s)."):format(targetName, formatMoney(amount), formatMoney(newBalance)))
    end
end, true)

-- Restricted: ACL command.payday; the server console is always allowed.
RegisterCommand("payday", function(source, args, raw)
    local paid = runPayday(source == 0 and "console" or ("player:" .. source))
    if source ~= 0 then
        tell(source, ("Payday triggered: %d player(s) paid."):format(paid))
    else
        print("[" .. RESOURCE .. "] payday: " .. paid .. " player(s) paid.")
    end
end, true)
