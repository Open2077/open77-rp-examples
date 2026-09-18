-- rp_whitelist - connection control for Night City RP.
--
-- Whitelist (allowlist or priority queue), temporary RP bans, and the `/wl` admin
-- command. The decision is taken in `onPlayerConnecting` through the host's deferrals;
-- the lists live in SQL (rp_whitelist_entries, rp_whitelist_bans) mirrored in memory so
-- the exports never yield, with an Open77.kvp fallback when no database answers.
--
-- What is measured, not guessed (see README "Limits" for the whole list):
--   * the host refuses `server_full` BEFORE this gate runs, so Config.maxPlayers must be
--     below network.maximumPlayers for the queue to ever hold anybody;
--   * a hold cannot outlive simulation.connectGateTimeoutSeconds (8 s by default), so a
--     queued player is either admitted within the hold or refused with their position
--     and keeps that position for Config.queue.ttlSeconds across reconnects;
--   * deferrals.update() reaches the server log only, never the player.

local RESOURCE = GetCurrentResourceName()
local LOG_KIND = "whitelist"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local state = {
    enabled = Config.enabled,          -- runtime switch, persisted in KVP ("enabled")
    mode = Config.mode,                -- "allowlist" | "queue"
    storage = "pending",               -- "sql" | "kvp" | "pending"
    loaded = false,                    -- entries and bans are in memory
}

local entries = {}   -- [identifier] = { identifier, note, added_by, at }
local bans = {}      -- [identifier] = { identifier, until_, reason, by }  (until_ = 0: permanent)
local queue = {}     -- [identifier] = { identifier, name, priority, since, lastSeen }
local reserved = {}  -- [identifier] = expiresAt  (slot handed out at the gate, player not yet in)
local refusals = {}  -- ring of the last refusals seen through onPlayerRejected

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function now()
    return Open77.time.unix()
end

local function log(text)
    print(("[%s] %s"):format(RESOURCE, text))
end

local function warn(text)
    Open77.log.warn(("[%s] %s"):format(RESOURCE, text))
end

-- Audit line through rp_logs when it runs; silent otherwise.
local function audit(text, data)
    pcall(function()
        exports.rp_logs:log(LOG_KIND, text, data)
    end)
end

-- Answer the caller of a command: the console reads the log, a player reads the chat.
local function reply(source, text)
    if source == 0 then
        print(text)
    else
        Open77.chat.send(source, { author = "GATE", text = text, color = { 255, 196, 0 } })
    end
end

-- The host trims a refusal to 127 bytes of UTF-8 anyway; trim here so a long reason is
-- cut cleanly instead of in the middle of a multi-byte character.
local function trimRefusal(text)
    text = tostring(text or "")
    if #text <= 127 then return text end
    local cut = 124
    while cut > 1 and text:byte(cut) >= 0x80 and text:byte(cut) < 0xC0 do
        cut = cut - 1
    end
    return text:sub(1, cut - 1) .. "..."
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    if seconds < 60 then return ("%ds"):format(seconds) end
    if seconds < 3600 then return ("%d min"):format(math.ceil(seconds / 60)) end
    if seconds < 86400 then
        return ("%dh %02dm"):format(seconds // 3600, (seconds % 3600) // 60)
    end
    return ("%dd %dh"):format(seconds // 86400, (seconds % 86400) // 3600)
end

local function formatAgo(unixSeconds)
    if type(unixSeconds) ~= "number" or unixSeconds <= 0 then return "?" end
    return formatDuration(now() - unixSeconds) .. " ago"
end

local function isValidIdentifier(value)
    return type(value) == "string" and #value >= 3 and #value <= 64
        and value:match("^[%w%-%._:@]+$") ~= nil
end

-- The identifier of the player who runs a command, or "console".
local function actorOf(source)
    if source == 0 then return "console" end
    return Open77.players.identifier(source) or ("player:" .. tostring(source))
end

-- identifier -> session id map of everyone online, built on demand.
local function onlineByIdentifier()
    local map = {}
    for _, playerId in ipairs(Open77.players.all()) do
        local identifier = Open77.players.identifier(playerId)
        if identifier then map[identifier] = playerId end
    end
    return map
end

-- RP name through rp_identity, or the account name, or the identifier.
local function displayName(playerId, identifier)
    if playerId then
        local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
        if ok and type(name) == "string" and name ~= "" then return name end
        local account = Open77.players.name(playerId)
        if account then return account end
    end
    return identifier
end

-- `<identifier|playerId>` argument of a command -> identifier, playerId|nil, or nil, nil, reason.
local function resolveTarget(arg)
    if type(arg) ~= "string" or arg == "" then return nil, nil, "missing_target" end
    local playerId = tonumber(arg)
    if playerId then
        if playerId ~= math.floor(playerId) or playerId < 1 then return nil, nil, "invalid_player_id" end
        local identifier = Open77.players.identifier(playerId)
        if not identifier then return nil, nil, "player_not_found" end
        return identifier, playerId
    end
    if not isValidIdentifier(arg) then return nil, nil, "invalid_identifier" end
    return arg, onlineByIdentifier()[arg]
end

local function countOf(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Storage: SQL first, KVP when no database answers. Writes never yield.
-- ---------------------------------------------------------------------------

local SQL_CREATE_ENTRIES = [[
    CREATE TABLE IF NOT EXISTS rp_whitelist_entries (
        `identifier` VARCHAR(64)  NOT NULL,
        `note`       VARCHAR(64)  NOT NULL DEFAULT '',
        `added_by`   VARCHAR(64)  NOT NULL DEFAULT 'console',
        `at`         BIGINT       NOT NULL DEFAULT 0,
        PRIMARY KEY (`identifier`)
    )
]]

local SQL_CREATE_BANS = [[
    CREATE TABLE IF NOT EXISTS rp_whitelist_bans (
        `identifier` VARCHAR(64)  NOT NULL,
        `until`      BIGINT       NOT NULL DEFAULT 0,
        `reason`     VARCHAR(128) NOT NULL DEFAULT '',
        `by`         VARCHAR(64)  NOT NULL DEFAULT 'console',
        PRIMARY KEY (`identifier`)
    )
]]

local function persistEntry(entry)
    if state.storage == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_whitelist_entries (`identifier`, `note`, `added_by`, `at`) VALUES (?, ?, ?, ?) "
                .. "ON DUPLICATE KEY UPDATE `note` = VALUES(`note`), `added_by` = VALUES(`added_by`), `at` = VALUES(`at`)",
            { entry.identifier, entry.note, entry.added_by, entry.at },
            function() end)
    elseif state.storage == "kvp" then
        local ok, reason = Open77.kvp.set("entry:" .. entry.identifier, json.encode(entry))
        if not ok then warn("kvp write failed for entry " .. entry.identifier .. ": " .. tostring(reason)) end
    end
end

local function forgetEntry(identifier)
    if state.storage == "sql" then
        Open77.database.update("DELETE FROM rp_whitelist_entries WHERE `identifier` = ?", { identifier }, function() end)
    elseif state.storage == "kvp" then
        Open77.kvp.delete("entry:" .. identifier)
    end
end

local function persistBan(ban)
    if state.storage == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_whitelist_bans (`identifier`, `until`, `reason`, `by`) VALUES (?, ?, ?, ?) "
                .. "ON DUPLICATE KEY UPDATE `until` = VALUES(`until`), `reason` = VALUES(`reason`), `by` = VALUES(`by`)",
            { ban.identifier, ban.until_, ban.reason, ban.by },
            function() end)
    elseif state.storage == "kvp" then
        local ok, reason = Open77.kvp.set("ban:" .. ban.identifier, json.encode(ban))
        if not ok then warn("kvp write failed for ban " .. ban.identifier .. ": " .. tostring(reason)) end
    end
end

local function forgetBan(identifier)
    if state.storage == "sql" then
        Open77.database.update("DELETE FROM rp_whitelist_bans WHERE `identifier` = ?", { identifier }, function() end)
    elseif state.storage == "kvp" then
        Open77.kvp.delete("ban:" .. identifier)
    end
end

local function persistEnabled(enabled)
    local ok, reason = Open77.kvp.set("enabled", enabled and true or false)
    if not ok then warn("could not persist the enabled flag: " .. tostring(reason)) end
end

local function loadFromKvp()
    entries, bans = {}, {}
    for _, item in ipairs(Open77.kvp.find("entry:", 4096) or {}) do
        local entry = type(item.value) == "string" and json.decode(item.value) or nil
        if type(entry) == "table" and isValidIdentifier(entry.identifier) then
            entries[entry.identifier] = entry
        end
    end
    for _, item in ipairs(Open77.kvp.find("ban:", 4096) or {}) do
        local ban = type(item.value) == "string" and json.decode(item.value) or nil
        if type(ban) == "table" and isValidIdentifier(ban.identifier) then
            ban.until_ = tonumber(ban.until_) or 0
            bans[ban.identifier] = ban
        end
    end
end

-- Runs inside Open77.database.ready: a managed task, so the .await forms are allowed.
local function loadFromSql()
    Open77.database.update.await(SQL_CREATE_ENTRIES)
    Open77.database.update.await(SQL_CREATE_BANS)
    Open77.database.update.await("DELETE FROM rp_whitelist_bans WHERE `until` > 0 AND `until` <= ?", { math.floor(now()) })

    entries, bans = {}, {}
    local rows = Open77.database.query.await("SELECT `identifier`, `note`, `added_by`, `at` FROM rp_whitelist_entries") or {}
    for _, row in ipairs(rows) do
        entries[row.identifier] = {
            identifier = row.identifier,
            note = row.note or "",
            added_by = row.added_by or "console",
            at = tonumber(row.at) or 0,
        }
    end
    rows = Open77.database.query.await("SELECT `identifier`, `until`, `reason`, `by` FROM rp_whitelist_bans") or {}
    for _, row in ipairs(rows) do
        bans[row.identifier] = {
            identifier = row.identifier,
            until_ = tonumber(row["until"]) or 0,
            reason = row.reason or "",
            by = row.by or "console",
        }
    end
end

local function announceLoaded()
    state.loaded = true
    log(("registry loaded from %s: %d entries, %d bans, whitelist %s (%s)"):format(
        state.storage, countOf(entries), countOf(bans), state.enabled and "ENABLED" or "disabled", state.mode))
end

local function initStorage()
    local saved = Open77.kvp.get("enabled", nil)
    if type(saved) == "boolean" then
        state.enabled = saved
    end

    local queued, reason = Open77.database.ready(function()
        if state.loaded then
            log("database answered late: keeping the kvp store for this boot")
            return
        end
        local ok, err = pcall(loadFromSql)
        if ok then
            state.storage = "sql"
        else
            warn("SQL load failed (" .. tostring(err) .. "): falling back to Open77.kvp for the whitelist and the bans")
            state.storage = "kvp"
            loadFromKvp()
        end
        announceLoaded()
    end)

    if not queued then
        -- No database bridge at all: the ready handler will never run.
        warn("database not ready (" .. tostring(reason) .. "): falling back to Open77.kvp for the whitelist and the bans")
        state.storage = "kvp"
        loadFromKvp()
        announceLoaded()
        return
    end
    -- A bridge that stays "connecting" never runs the ready handler either: without this bound
    -- the gate refuses everyone forever (fail closed) and /wl stays "still loading".
    CreateThread(function()
        Wait(Config.storageWaitSeconds * 1000)
        if state.loaded then return end
        local ready, why = Open77.database.isReady()
        if ready then return end
        warn("database still not ready after " .. Config.storageWaitSeconds .. " s (" .. tostring(why) .. "): falling back to Open77.kvp for this boot")
        state.storage = "kvp"
        loadFromKvp()
        announceLoaded()
    end)
end

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------

-- The active ban of an identity, or nil. An expired ban is dropped on sight.
local function activeBan(identifier)
    local ban = bans[identifier]
    if not ban then return nil end
    if ban.until_ ~= 0 and ban.until_ <= now() then
        bans[identifier] = nil
        forgetBan(identifier)
        return nil
    end
    return ban
end

local function banSentence(ban)
    local left = "permanently"
    if ban.until_ ~= 0 then
        left = "for " .. formatDuration(ban.until_ - now())
    end
    return trimRefusal(Config.banText:format(left, ban.reason ~= "" and ban.reason or "no reason given"))
end

local function addEntry(identifier, note, by)
    local entry = {
        identifier = identifier,
        note = (note or ""):sub(1, 64),
        added_by = (by or "console"):sub(1, 64),
        at = math.floor(now()),
    }
    entries[identifier] = entry
    persistEntry(entry)
    TriggerEvent("rp_whitelist:changed", identifier, "added", entry.added_by)
    audit(("whitelist add %s (%s) by %s"):format(identifier, entry.note, entry.added_by),
        { identifier = identifier, note = entry.note, by = entry.added_by })
    return entry
end

local function removeEntry(identifier, by)
    if not entries[identifier] then return false end
    entries[identifier] = nil
    forgetEntry(identifier)
    TriggerEvent("rp_whitelist:changed", identifier, "removed", by)
    audit(("whitelist remove %s by %s"):format(identifier, by), { identifier = identifier, by = by })
    return true
end

local function addBan(identifier, minutes, reason, by)
    local ban = {
        identifier = identifier,
        until_ = minutes > 0 and math.floor(now() + minutes * 60) or 0,
        reason = (reason or ""):sub(1, 128),
        by = (by or "console"):sub(1, 64),
    }
    bans[identifier] = ban
    persistBan(ban)
    TriggerEvent("rp_whitelist:changed", identifier, "banned", ban.by)
    audit(("ban %s %s: %s by %s"):format(identifier,
        minutes > 0 and ("for " .. minutes .. " min") or "permanently", ban.reason, ban.by),
        { identifier = identifier, minutes = minutes, reason = ban.reason, by = ban.by, until_ = ban.until_ })
    return ban
end

local function removeBan(identifier, by)
    if not bans[identifier] then return false end
    bans[identifier] = nil
    forgetBan(identifier)
    TriggerEvent("rp_whitelist:changed", identifier, "unbanned", by)
    audit(("unban %s by %s"):format(identifier, by), { identifier = identifier, by = by })
    return true
end

-- ---------------------------------------------------------------------------
-- Priority queue
-- ---------------------------------------------------------------------------

local function capacity()
    local cap = GetConvarInt(Config.maxPlayersConvar, 0)
    if type(cap) ~= "number" or cap <= 0 then
        cap = tonumber(Config.maxPlayers) or 0
    end
    return math.max(0, math.floor(cap))
end

-- Players in, plus the slots handed out at the gate whose player is not in yet.
local function onlineCount(at)
    local n = #Open77.players.all()
    for identifier, expiresAt in pairs(reserved) do
        if expiresAt <= at then
            reserved[identifier] = nil
        else
            n = n + 1
        end
    end
    return n
end

local function pruneQueue(at)
    for identifier, item in pairs(queue) do
        if at - item.lastSeen > Config.queue.ttlSeconds then
            queue[identifier] = nil
        end
    end
end

-- Listed identities first, then by first knock, then by identifier (stable).
local function queueOrder()
    local list = {}
    for _, item in pairs(queue) do list[#list + 1] = item end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.since ~= b.since then return a.since < b.since end
        return a.identifier < b.identifier
    end)
    return list
end

local function positionOf(identifier)
    local list = queueOrder()
    for index, item in ipairs(list) do
        if item.identifier == identifier then return index, #list end
    end
    return 0, #list
end

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------

-- Returns nil to admit, or the sentence the player reads. May Wait (managed task).
local function decide(player, deferrals)
    local identifier = player.userId
    local name = player.name or "?"
    if not isValidIdentifier(identifier) then
        -- The host verifies the identity before the gate runs; this is belt and braces.
        warn(("gate: no usable userId for %s"):format(name))
        if state.enabled and Config.failClosed then return Config.errorText end
        return nil
    end

    -- 1. Wait for storage after a start, bounded well below the gate deadline.
    if not state.loaded then
        deferrals.update("waiting for the whitelist storage")
        local deadline = now() + Config.loadWaitSeconds
        while not state.loaded and now() < deadline do
            Wait(250)
        end
        if not state.loaded then
            if state.enabled and Config.failClosed then
                warn(("gate: storage not loaded in time, refusing %s (%s)"):format(name, identifier))
                return Config.errorText
            end
            warn(("gate: storage not loaded in time, admitting %s (%s) unchecked"):format(name, identifier))
            return nil
        end
    end

    -- 2. Bans first: a ban is a ban, whitelist on or off (Config.bansWhenDisabled).
    if state.enabled or Config.bansWhenDisabled then
        local ban = activeBan(identifier)
        if ban then
            return banSentence(ban)
        end
    end

    if not state.enabled then
        return nil
    end

    -- 3. The list.
    local listed = entries[identifier] ~= nil
    if state.mode == "allowlist" and not listed then
        return trimRefusal(Config.refusalText:format(Config.discordLink))
    end

    -- 4. Capacity and the priority queue.
    local cap = capacity()
    if cap <= 0 then
        return nil
    end

    local at = now()
    local item = queue[identifier]
    if not item then
        item = { identifier = identifier, since = at }
        queue[identifier] = item
    end
    item.name = name
    item.lastSeen = at
    item.priority = listed and 0 or 1

    local deadline = at + Config.queue.holdSeconds
    local lastNote = -math.huge
    local lastPosition = -1
    while true do
        pruneQueue(at)
        local position, waiting = positionOf(identifier)
        local online = onlineCount(at)
        local free = cap - online

        if position >= 1 and position <= free then
            queue[identifier] = nil
            reserved[identifier] = at + Config.queue.reserveSeconds
            if waiting > 1 or online >= cap - 1 then
                log(("gate: slot %d/%d handed to %s (%s), %d still waiting"):format(online + 1, cap, name, identifier, waiting - 1))
            end
            return nil
        end

        if position ~= lastPosition or at - lastNote >= Config.queue.positionEveryMs / 1000 then
            deferrals.update(("queue #%d of %d, %d/%d online%s"):format(position, waiting, online, cap, listed and " (priority)" or ""))
            lastNote, lastPosition = at, position
        end

        if at >= deadline then
            return trimRefusal(Config.fullText:format(online, cap, position))
        end

        Wait(Config.queue.pollMs)
        at = now()
        item.lastSeen = at
    end
end

AddEventHandler("onPlayerConnecting", function(player, deferrals)
    deferrals.defer()
    local ok, verdict = pcall(decide, player, deferrals)
    if ok then
        deferrals.done(verdict)          -- nil admits, a string refuses
        return
    end
    warn("gate error: " .. tostring(verdict))
    if state.enabled and Config.failClosed then
        deferrals.done(Config.errorText)
    else
        deferrals.done()
    end
end)

AddEventHandler("onPlayerConnected", function(playerId)
    local identifier = Open77.players.identifier(playerId)
    if identifier then
        reserved[identifier] = nil
        queue[identifier] = nil
    end
end)

AddEventHandler("onPlayerRejected", function(userId, name, code, message)
    table.insert(refusals, 1, {
        userId = userId or "", name = name or "", code = code or "", message = message or "", at = now(),
    })
    while #refusals > Config.recentRefusals do
        table.remove(refusals)
    end
end)

-- ---------------------------------------------------------------------------
-- Exports (never yield)
-- ---------------------------------------------------------------------------

-- Would this identity pass the gate right now? -> true | false, reason
exports("isAllowed", function(identifier)
    if not isValidIdentifier(identifier) then return false, "invalid_identifier" end
    if not state.loaded then return false, "not_loaded" end
    if (state.enabled or Config.bansWhenDisabled) and activeBan(identifier) then
        return false, "banned"
    end
    if state.enabled and state.mode == "allowlist" and not entries[identifier] then
        return false, "not_whitelisted"
    end
    return true
end)

-- ban(identifier|playerId, minutes, reason) -> true | nil, reason. 0 minutes = permanent.
-- Does NOT disconnect the player: the next connect is refused.
exports("ban", function(identifier, minutes, reason)
    if type(identifier) == "number" then
        -- Open77.players.identifier throws (VM dead) for 0, negative or fractional ids.
        if identifier < 1 or identifier ~= math.floor(identifier) then return nil, "invalid_player_id" end
        identifier = Open77.players.identifier(identifier)
        if not identifier then return nil, "player_not_found" end
    end
    if not isValidIdentifier(identifier) then return nil, "invalid_identifier" end
    minutes = tonumber(minutes)
    if not minutes or minutes < 0 or minutes ~= minutes then return nil, "invalid_minutes" end
    if not state.loaded then return nil, "not_loaded" end
    addBan(identifier, minutes, tostring(reason or ""), GetInvokingResource() or "script")
    return true
end)

-- ---------------------------------------------------------------------------
-- /wl command (restricted: ACL `command.wl`; the console always may)
-- ---------------------------------------------------------------------------

local USAGE = {
    "/wl ajouter <identifier|playerId> [note]  - add to the whitelist",
    "/wl retirer <identifier|playerId>         - remove from the whitelist",
    "/wl liste                                 - list the entries",
    "/wl ban <identifier|playerId> <minutes> <reason> - RP ban (0 = permanent); no kick",
    "/wl unban <identifier|playerId>           - lift a ban",
    "/wl statut                                - state, storage, capacity, queue, refusals",
    "/wl activer | desactiver                  - switch the whitelist on / off (persisted)",
}

local TARGET_ERRORS = {
    missing_target = "Give an identifier or an online player id.",
    invalid_player_id = "That is not a player id.",
    player_not_found = "No player with that id is online. Use the identifier instead.",
    invalid_identifier = "That identifier does not look right (3-64 characters: letters, digits, - . _ : @).",
}

local function joinFrom(args, from)
    if args.n < from then return "" end
    return table.concat(args, " ", from, args.n)
end

local function activeBanList()
    local list = {}
    for identifier in pairs(bans) do
        if activeBan(identifier) then list[#list + 1] = bans[identifier] end
    end
    table.sort(list, function(a, b) return a.until_ < b.until_ end)
    return list
end

local subcommands = {}

subcommands.ajouter = function(source, args)
    local identifier, playerId, err = resolveTarget(args[2])
    if not identifier then return reply(source, TARGET_ERRORS[err] or err) end
    local note = joinFrom(args, 3)
    if note == "" then note = displayName(playerId, identifier) end
    local existed = entries[identifier] ~= nil
    addEntry(identifier, note, actorOf(source))
    reply(source, ("%s %s on the whitelist as \"%s\"."):format(existed and "Updated" or "Added", identifier, note))
    if playerId then
        Open77.chat.send(playerId, { author = "GATE", text = "You are on the whitelist now, choom. Night City is yours.", color = { 0, 229, 255 } })
    end
end

subcommands.retirer = function(source, args)
    local identifier, _, err = resolveTarget(args[2])
    if not identifier then return reply(source, TARGET_ERRORS[err] or err) end
    if removeEntry(identifier, actorOf(source)) then
        reply(source, ("Removed %s from the whitelist. A running session is not touched."):format(identifier))
    else
        reply(source, ("%s is not on the whitelist."):format(identifier))
    end
end

subcommands.liste = function(source)
    local list = {}
    for _, entry in pairs(entries) do list[#list + 1] = entry end
    table.sort(list, function(a, b) return a.at < b.at end)
    local online = onlineByIdentifier()
    reply(source, ("Whitelist: %d entr%s (%s)."):format(#list, #list == 1 and "y" or "ies", state.enabled and "enabled" or "disabled"))
    local limit = source == 0 and #list or math.min(#list, 30)
    for index = 1, limit do
        local entry = list[index]
        local playerId = online[entry.identifier]
        local status = playerId and ("online as " .. displayName(playerId, entry.identifier) .. " [" .. playerId .. "]") or "offline"
        reply(source, ("- %s  \"%s\"  by %s, %s  (%s)"):format(entry.identifier, entry.note, entry.added_by, formatAgo(entry.at), status))
    end
    if limit < #list then
        reply(source, ("... and %d more (the console lists everything)."):format(#list - limit))
    end
end

subcommands.ban = function(source, args)
    local identifier, playerId, err = resolveTarget(args[2])
    if not identifier then return reply(source, TARGET_ERRORS[err] or err) end
    local minutes = tonumber(args[3])
    if not minutes or minutes < 0 then
        return reply(source, "Usage: /wl ban <identifier|playerId> <minutes> <reason>  (0 = permanent)")
    end
    local reason = joinFrom(args, 4)
    if reason == "" then
        return reply(source, "Give a reason: it is what the player reads at the door.")
    end
    local ban = addBan(identifier, minutes, reason, actorOf(source))
    local label = playerId and displayName(playerId, identifier) or identifier
    reply(source, ("%s banned %s: %s. Not kicked - the next connect is refused%s."):format(
        label, minutes > 0 and ("for " .. formatDuration(minutes * 60)) or "permanently", reason,
        playerId and " (the platform /kick removes them now)" or ""))
    if playerId then
        Open77.chat.send(playerId, { author = "GATE", text = banSentence(ban) .. " You may finish this session.", color = { 255, 80, 80 } })
    end
end

subcommands.unban = function(source, args)
    local identifier, _, err = resolveTarget(args[2])
    if not identifier then return reply(source, TARGET_ERRORS[err] or err) end
    if removeBan(identifier, actorOf(source)) then
        reply(source, ("Ban lifted for %s."):format(identifier))
    else
        reply(source, ("%s has no active ban."):format(identifier))
    end
end

subcommands.statut = function(source)
    local at = now()
    local banList = activeBanList()
    local permanent = 0
    for _, ban in ipairs(banList) do
        if ban.until_ == 0 then permanent = permanent + 1 end
    end
    pruneQueue(at)
    local cap = capacity()
    reply(source, ("Whitelist %s, mode %s, storage %s%s."):format(
        state.enabled and "ENABLED" or "disabled", state.mode, state.storage, state.loaded and "" or " (loading)"))
    reply(source, ("Entries: %d. Active bans: %d (%d permanent). Bans while disabled: %s."):format(
        countOf(entries), #banList, permanent, Config.bansWhenDisabled and "yes" or "no"))
    if cap > 0 then
        reply(source, ("Capacity: %d/%d online (soft cap; must stay below network.maximumPlayers). Queue: %d waiting."):format(
            onlineCount(at), cap, countOf(queue)))
        for index, item in ipairs(queueOrder()) do
            if index > 10 then reply(source, "  ... (more)") break end
            reply(source, ("  #%d %s (%s)%s, last knock %s"):format(index, item.name or "?", item.identifier,
                item.priority == 0 and " priority" or "", formatAgo(item.lastSeen)))
        end
    else
        reply(source, ("Capacity: no soft cap (%d online), the queue is off."):format(#Open77.players.all()))
    end
    for index, ban in ipairs(banList) do
        if index > 10 then reply(source, "  ... (more bans)") break end
        reply(source, ("  ban %s %s: %s (by %s)"):format(ban.identifier,
            ban.until_ == 0 and "permanent" or (formatDuration(ban.until_ - at) .. " left"), ban.reason, ban.by))
    end
    if #refusals > 0 then
        reply(source, ("Last refusals (%d):"):format(#refusals))
        for _, refusal in ipairs(refusals) do
            reply(source, ("  %s: %s (%s) %s - %s"):format(formatAgo(refusal.at), refusal.name, refusal.userId, refusal.code, refusal.message))
        end
    end
end

subcommands.activer = function(source)
    if state.enabled then return reply(source, "The whitelist is already enabled.") end
    state.enabled = true
    persistEnabled(true)
    TriggerEvent("rp_whitelist:changed", "*", "enabled", actorOf(source))
    audit("whitelist enabled by " .. actorOf(source), { by = actorOf(source) })
    reply(source, ("Whitelist ENABLED (%s). Players already in are not kicked; the next connects are checked."):format(state.mode))
end

subcommands.desactiver = function(source)
    if not state.enabled then return reply(source, "The whitelist is already disabled.") end
    state.enabled = false
    persistEnabled(false)
    TriggerEvent("rp_whitelist:changed", "*", "disabled", actorOf(source))
    audit("whitelist disabled by " .. actorOf(source), { by = actorOf(source) })
    reply(source, ("Whitelist disabled. Bans %s."):format(Config.bansWhenDisabled and "still apply" or "are off too"))
end

RegisterCommand("wl", function(source, args)
    local action = (args[1] or ""):lower()
    local handler = subcommands[action]
    if not handler then
        for _, line in ipairs(USAGE) do reply(source, line) end
        return
    end
    if not state.loaded and action ~= "statut" then
        return reply(source, "The whitelist storage is still loading. Try again in a few seconds.")
    end
    handler(source, args)
end, true)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local SUGGESTIONS = {
    {
        command = "/wl",
        help = "Whitelist and RP bans (admin)",
        parameters = {
            { name = "action", help = "ajouter | retirer | liste | ban | unban | statut | activer | desactiver" },
            { name = "args", help = "<identifier|playerId> [note] | <minutes> <reason>" },
        },
    },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    initStorage()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    log(("gate online: whitelist %s, mode %s, soft cap %d, hold %.1fs"):format(
        state.enabled and "ENABLED" or "disabled", state.mode, capacity(), Config.queue.holdSeconds))
end)
