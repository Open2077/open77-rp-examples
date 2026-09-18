-- rp_trauma - server: Trauma Team and RP death for a Night City RP server.
--
-- Absorbs rp_medic. Commands: /soin /reanimer /911 /medic (from rp_medic, now gated by
-- rp_jobs hasJob "trauma" + onDuty), /respawn, /trauma [av|av off|factures|payer], /contrat.
--
-- The "down" state. The platform exposes nothing that lets a resource hold or cancel
-- the freeroam respawn (no death-hold API, no cancellable death event, no freeroam
-- export or tunable for it - see README). So this resource lets the respawn happen
-- and, the moment the life phase comes back to "alive", re-applies a "down" state at
-- the death position: Open77.players.teleport back to the spot, Open77.players.setFrozen,
-- health set low with regeneration off (Open77.stats), the client blocks every input,
-- and a countdown of Config.downSeconds runs. Every on-duty medic gets a chat line, a
-- toast and a map pin with the distance. /respawn is accepted after the countdown, or
-- at once when no medic is on duty: the body goes to the hospital and the bill is
-- charged (bank account -> society, then cash, then an unpaid row in rp_trauma_bills).
--
-- Authority: everything is decided here; the client only renders (blips, input block)
-- and requests (ALT+click actions). Money goes through rp_bank / rp_economy, jobs
-- through rp_jobs, zones through rp_zones, names through rp_identity - all reached
-- with pcall since none of them may be declared as a dependency of a resource that
-- ships a client script. Persistence is SQL first (Open77.database), Open77.kvp only
-- when the database never answers.

local RESOURCE = GetCurrentResourceName()
local DB = Open77.database

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- [playerId] = { position, heading, since, deadline, deaths, held, applying, reminderAt, announcedOpen }
-- A player with an entry here is down: the next "alive" life phase re-applies the hold.
-- Removing the entry is what frees them.
local down = {}

-- [identifier] = { active, untilAt, failures, startedAt, renewedAt } (unix seconds)
local contracts = {}

-- [identifier] = { { id, amount, reason, createdAt }, ... } unpaid bills, oldest first
local bills = {}

local avByMedic = {}   -- [medicId] = vehicleId
local cooldowns = {}   -- [medicId] = Open77.time.monotonic() of the last paid act
local busy = {}        -- [medicId] = true while a progress bar runs
local loaded = {}      -- [playerId] = true once the player's file was read

-- "pending" until the database answers or is known to be absent, then "sql" or "kvp".
local store = "pending"

local COLOR = Config.colors

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_trauma] " .. fmt):format(...))
end

local function nowMono()
    return Open77.time.monotonic()
end

local function nowUnix()
    return math.floor(Open77.time.unix())
end

local function round(value)
    return math.floor(value + 0.5)
end

-- Chat to one player (or -1). `playerId` is a number everywhere this is called.
local function say(playerId, text, color)
    local ok, reason = Open77.chat.send(playerId, { author = "TRAUMA", text = text, color = color or COLOR.trauma })
    if not ok then
        log("chat.send to %s failed: %s", tostring(playerId), tostring(reason))
    end
end

local function toast(playerId, kind, title, message, durationMs)
    local id, reason = Open77.notifications.send(playerId, {
        type = kind,
        title = title,
        message = message,
        icon = "TT",
        durationMs = durationMs or 6000,
    })
    if not id then
        log("notification to %s failed: %s", tostring(playerId), tostring(reason))
    end
end

local function fmtPos(pos)
    return ("%d, %d, %d"):format(round(pos.x), round(pos.y), round(pos.z))
end

local function playerIdArg(value)
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then
        return nil
    end
    return math.tointeger(n)
end

-- ---------------------------------------------------------------------------
-- Sibling resources (synchronous exports raise when the resource is missing)
-- ---------------------------------------------------------------------------

local function displayName(playerId)
    local ok, name = pcall(function()
        return exports.rp_identity:fullName(playerId)
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

-- true / false when rp_jobs answered, nil when its exports are unavailable.
local function isMedicOnDuty(playerId)
    local ok, result = pcall(function()
        return exports.rp_jobs:hasJob(playerId, Config.job) and exports.rp_jobs:onDuty(playerId)
    end)
    if not ok then
        return nil
    end
    return result == true
end

local function listOnDuty(job)
    local ok, list = pcall(function()
        return exports.rp_jobs:listOnDuty(job)
    end)
    if ok and type(list) == "table" then
        return list
    end
    return {}
end

local function medicsOnDuty(except)
    local out = {}
    for _, id in ipairs(listOnDuty(Config.job)) do
        id = tonumber(id)
        if id and id ~= except then
            out[#out + 1] = id
        end
    end
    return out
end

-- account -> trauma society. newBalance | nil, reason ("bank_unavailable" without rp_bank)
local function bankCharge(playerId, amount, reason)
    local ok, newBalance, why = pcall(function()
        return exports.rp_bank:charge(playerId, amount, Config.society, reason)
    end)
    if not ok then
        return nil, "bank_unavailable"
    end
    if newBalance == nil then
        return nil, why or "refused"
    end
    return newBalance
end

local function societyAdd(amount, reason)
    local ok, result, why = pcall(function()
        return exports.rp_bank:societyAdd(Config.society, amount, reason)
    end)
    if not ok or result == nil then
        log("societyAdd %d (%s) failed: %s", amount, reason, tostring(ok and why or result))
        return false
    end
    return true
end

local function cashBalance(playerId)
    local ok, balance = pcall(function()
        return exports.rp_economy:getBalance(playerId)
    end)
    if ok and type(balance) == "number" then
        return balance
    end
    return nil
end

local function cashRemove(playerId, amount, reason)
    local ok, newBalance, why = pcall(function()
        return exports.rp_economy:remove(playerId, amount, reason)
    end)
    if not ok then
        return nil, "economy_unavailable"
    end
    if newBalance == nil then
        return nil, why or "refused"
    end
    return newBalance
end

-- ---------------------------------------------------------------------------
-- Persistence: contracts and bills (SQL first, kvp when the database never answers)
-- ---------------------------------------------------------------------------

local SQL_CONTRACTS = [[
CREATE TABLE IF NOT EXISTS rp_trauma_contracts (
    identifier VARCHAR(64) PRIMARY KEY,
    active     TINYINT(1) NOT NULL DEFAULT 1,
    until_at   BIGINT     NOT NULL DEFAULT 0,
    failures   TINYINT    NOT NULL DEFAULT 0,
    started_at BIGINT     NOT NULL DEFAULT 0,
    renewed_at BIGINT     NOT NULL DEFAULT 0
)]]

local SQL_BILLS = [[
CREATE TABLE IF NOT EXISTS rp_trauma_bills (
    id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    identifier VARCHAR(64)  NOT NULL,
    amount     INT          NOT NULL,
    reason     VARCHAR(32)  NOT NULL DEFAULT '',
    created_at BIGINT       NOT NULL DEFAULT 0,
    paid_at    BIGINT       NULL,
    KEY idx_rp_trauma_bills_identifier (identifier)
)]]

local function useKvp(reason)
    if store ~= "kvp" then
        store = "kvp"
        log("store=kvp reason=%s (contracts and bills fall back to Open77.kvp)", tostring(reason))
    end
end

-- Runs `fn` once the store is decided, without ever yielding the caller (writes may
-- happen inside an export). Waits at most 20 s, then falls back to kvp for the boot.
local function whenStoreDecided(fn)
    if store ~= "pending" then
        return fn()
    end
    CreateThread(function()
        local waited = 0
        while store == "pending" and waited < 20000 do
            Wait(500)
            waited = waited + 500
        end
        if store == "pending" then
            useKvp("database not answering after 20 s")
        end
        fn()
    end)
end

local function saveContract(identifier)
    local c = contracts[identifier]
    if not c then
        return
    end
    if store == "pending" then
        return whenStoreDecided(function()
            saveContract(identifier)
        end)
    end
    if store == "sql" then
        DB.update([[
            INSERT INTO rp_trauma_contracts (identifier, active, until_at, failures, started_at, renewed_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE active = VALUES(active), until_at = VALUES(until_at),
                failures = VALUES(failures), started_at = VALUES(started_at), renewed_at = VALUES(renewed_at)
        ]], { identifier, c.active and 1 or 0, c.untilAt, c.failures, c.startedAt, c.renewedAt or 0 }, function() end)
    else
        Open77.kvp.set("contract:" .. identifier .. ":active", c.active and 1 or 0)
        Open77.kvp.set("contract:" .. identifier .. ":until", c.untilAt)
        Open77.kvp.set("contract:" .. identifier .. ":failures", c.failures)
        Open77.kvp.set("contract:" .. identifier .. ":started", c.startedAt)
    end
end

local function debtTotal(identifier)
    local total = 0
    for _, row in ipairs(bills[identifier] or {}) do
        total = total + row.amount
    end
    return total
end

local function addBill(playerId, amount, reason)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        return
    end
    bills[identifier] = bills[identifier] or {}
    local row = { amount = amount, reason = reason, createdAt = nowUnix() }
    table.insert(bills[identifier], row)
    whenStoreDecided(function()
        if store == "sql" then
            DB.insert("INSERT INTO rp_trauma_bills (identifier, amount, reason, created_at) VALUES (?, ?, ?, ?)",
                { identifier, amount, reason, row.createdAt }, function(id)
                    row.id = id
                end)
        else
            Open77.kvp.set("debt:" .. identifier, debtTotal(identifier))
        end
    end)
    log("player %d owes %d (%s), total debt %d", playerId, amount, reason, debtTotal(identifier))
end

local function markBillPaid(identifier, row)
    local list = bills[identifier] or {}
    for i, r in ipairs(list) do
        if r == row then
            table.remove(list, i)
            break
        end
    end
    whenStoreDecided(function()
        if store == "sql" then
            if row.id then
                DB.update("UPDATE rp_trauma_bills SET paid_at = ? WHERE id = ?", { nowUnix(), row.id }, function() end)
            end
        else
            Open77.kvp.set("debt:" .. identifier, debtTotal(identifier))
        end
    end)
end

-- Reads one player's contract and unpaid bills into the caches. Waits for the store
-- decision (at most 20 s), then falls back to kvp for the whole boot.
local function loadPlayer(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        return
    end
    local waited = 0
    while store == "pending" and waited < 20000 do
        Wait(500)
        waited = waited + 500
    end
    if store == "pending" then
        useKvp("database not answering after 20 s")
    end

    if store == "sql" then
        DB.single("SELECT active, until_at, failures, started_at, renewed_at FROM rp_trauma_contracts WHERE identifier = ?",
            { identifier }, function(row)
                if row then
                    contracts[identifier] = {
                        active = tonumber(row.active) == 1,
                        untilAt = tonumber(row.until_at) or 0,
                        failures = tonumber(row.failures) or 0,
                        startedAt = tonumber(row.started_at) or 0,
                        renewedAt = tonumber(row.renewed_at) or 0,
                    }
                end
                loaded[playerId] = true
            end)
        DB.query("SELECT id, amount, reason, created_at FROM rp_trauma_bills WHERE identifier = ? AND paid_at IS NULL ORDER BY id ASC",
            { identifier }, function(rows)
                local list = {}
                for _, r in ipairs(rows or {}) do
                    list[#list + 1] = { id = r.id, amount = tonumber(r.amount) or 0, reason = r.reason, createdAt = tonumber(r.created_at) or 0 }
                end
                bills[identifier] = list
                local total = debtTotal(identifier)
                if total > 0 then
                    say(playerId, ("Trauma Team reminder: you owe %d €$ in unpaid bills. /trauma payer settles them."):format(total), COLOR.alert)
                end
            end)
    else
        local active = Open77.kvp.get("contract:" .. identifier .. ":active", 0)
        local untilAt = Open77.kvp.get("contract:" .. identifier .. ":until", 0)
        if untilAt and untilAt > 0 then
            contracts[identifier] = {
                active = active == 1,
                untilAt = untilAt,
                failures = Open77.kvp.get("contract:" .. identifier .. ":failures", 0) or 0,
                startedAt = Open77.kvp.get("contract:" .. identifier .. ":started", 0) or 0,
            }
        end
        local debt = Open77.kvp.get("debt:" .. identifier, 0) or 0
        bills[identifier] = {}
        if debt > 0 then
            bills[identifier][1] = { amount = debt, reason = "carried", createdAt = 0 }
            say(playerId, ("Trauma Team reminder: you owe %d €$ in unpaid bills. /trauma payer settles them."):format(debt), COLOR.alert)
        end
        loaded[playerId] = true
    end
end

-- ---------------------------------------------------------------------------
-- Money: account -> society, then cash, then an unpaid bill
-- ---------------------------------------------------------------------------

-- Returns { account, cash, debt } (amounts), never nil.
local function collect(playerId, amount, reason)
    local result = { account = 0, cash = 0, debt = 0 }
    if amount <= 0 then
        return result
    end
    local newBalance, why = bankCharge(playerId, amount, reason)
    if newBalance then
        result.account = amount
        return result
    end
    log("player %d: bank charge %d (%s) refused: %s, trying cash", playerId, amount, reason, tostring(why))

    local balance = cashBalance(playerId) or 0
    local take = math.min(balance, amount)
    if take > 0 then
        local paid, cwhy = cashRemove(playerId, take, "trauma_" .. reason)
        if paid then
            result.cash = take
            societyAdd(take, reason)
        else
            log("player %d: cash remove %d refused: %s", playerId, take, tostring(cwhy))
        end
    end

    local remaining = amount - result.account - result.cash
    if remaining > 0 then
        result.debt = remaining
        addBill(playerId, remaining, reason)
    end
    return result
end

local function billSentence(result)
    local parts = {}
    if result.account > 0 then
        parts[#parts + 1] = ("%d €$ from your account"):format(result.account)
    end
    if result.cash > 0 then
        parts[#parts + 1] = ("%d €$ in cash"):format(result.cash)
    end
    if result.debt > 0 then
        parts[#parts + 1] = ("%d €$ still owed (/trauma payer)"):format(result.debt)
    end
    if #parts == 0 then
        return "nothing charged"
    end
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- Contracts
-- ---------------------------------------------------------------------------

local function contractOf(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        return nil, nil
    end
    return contracts[identifier], identifier
end

local function hasContract(playerId)
    local c = contractOf(playerId)
    return c ~= nil and c.active == true
end

local function subscribe(playerId)
    local c, identifier = contractOf(playerId)
    if not identifier then
        return say(playerId, "Identity unknown: try again in a moment.")
    end
    if c and c.active then
        return say(playerId, "You already hold a Trauma Team contract.")
    end
    local newBalance, why = bankCharge(playerId, Config.contractPrice, "contract")
    if not newBalance then
        if why == "insufficient_funds" then
            return say(playerId, ("Your bank account is short: %d €$ needed (/solde, /bank)."):format(Config.contractPrice))
        end
        return say(playerId, "The contract could not be charged: " .. tostring(why) .. ".")
    end
    local now = nowUnix()
    contracts[identifier] = {
        active = true,
        untilAt = now + Config.contractMinutes * 60,
        failures = 0,
        startedAt = now,
        renewedAt = now,
    }
    saveContract(identifier)
    say(playerId, ("Trauma Team contract signed: %d €$ charged, renewed every %d min while your account is funded. Free revives, priority dispatch."):format(Config.contractPrice, Config.contractMinutes))
    toast(playerId, "success", "Trauma Team", "Contract active. Platinum coverage, choom.")
    log("player %d contract signed until %d account=%d", playerId, contracts[identifier].untilAt, newBalance)
end

local function cancelContract(playerId)
    local c, identifier = contractOf(playerId)
    if not c or not c.active then
        return say(playerId, "You hold no Trauma Team contract.")
    end
    c.active = false
    saveContract(identifier)
    say(playerId, "Trauma Team contract cancelled. No refund for the running period.")
    log("player %d contract cancelled", playerId)
end

-- Every 30 s: renew the contracts of connected players whose period ended.
local function renewContracts()
    local now = nowUnix()
    for _, id in ipairs(Open77.players.all()) do
        local c, identifier = contractOf(id)
        if c and c.active and c.untilAt <= now then
            local newBalance, why = bankCharge(id, Config.contractPrice, "contract")
            if newBalance then
                c.failures = 0
                c.untilAt = math.max(c.untilAt, now) + Config.contractMinutes * 60
                c.renewedAt = now
                say(id, ("Trauma Team contract renewed: %d €$ charged. Account: %d €$."):format(Config.contractPrice, newBalance))
                log("player %d contract renewed until %d", id, c.untilAt)
            else
                c.failures = c.failures + 1
                if c.failures >= Config.contractMaxFailures then
                    c.active = false
                    say(id, ("Trauma Team contract cancelled: the renewal failed %d times (%s). /contrat to sign again."):format(c.failures, tostring(why)), COLOR.alert)
                    toast(id, "error", "Trauma Team", "Contract cancelled: account unfunded.")
                    log("player %d contract cancelled after %d failed renewals (%s)", id, c.failures, tostring(why))
                else
                    c.untilAt = now + Config.contractMinutes * 60
                    say(id, ("Trauma Team contract renewal failed (%s). Fund your account: the next failure cancels it."):format(tostring(why)), COLOR.alert)
                    log("player %d contract renewal failed (%s) failures=%d", id, tostring(why), c.failures)
                end
            end
            saveContract(identifier)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Medic counters (kvp, keyed by the durable identifier)
-- ---------------------------------------------------------------------------

local function bump(medicId, kind)
    local identifier = Open77.players.identifier(medicId)
    if not identifier then
        return
    end
    local key = kind .. ":" .. identifier
    local current = Open77.kvp.get(key, 0) or 0
    Open77.kvp.set(key, current + 1)
end

local function statsLine(medicId)
    local identifier = Open77.players.identifier(medicId)
    if not identifier then
        return nil
    end
    local heals = Open77.kvp.get("heal:" .. identifier, 0) or 0
    local revives = Open77.kvp.get("revive:" .. identifier, 0) or 0
    return ("Your interventions: %d stabilised, %d revived."):format(heals, revives)
end

-- ---------------------------------------------------------------------------
-- The down state
-- ---------------------------------------------------------------------------

local function secondsLeft(entry)
    return math.max(0, math.ceil(entry.deadline - nowMono()))
end

local function downList(except)
    local list = {}
    for id, entry in pairs(down) do
        if id ~= except then
            list[#list + 1] = {
                playerId = id,
                position = entry.position,
                name = displayName(id),
                contract = hasContract(id),
            }
        end
    end
    return list
end

-- Tells one client whether it is an on-duty medic (and which players are down).
local function pushMedicState(playerId)
    local onDuty = isMedicOnDuty(playerId) == true
    TriggerClientEvent("rp_trauma:medic", playerId, onDuty, onDuty and downList(playerId) or {})
end

local function announceDown(victim, entry)
    local name = displayName(victim)
    local contract = hasContract(victim)
    local notified = 0
    for _, medic in ipairs(medicsOnDuty(victim)) do
        local metres = Open77.players.distance(medic, entry.position)
        local dist = metres and ("%.0f m"):format(metres) or "unknown distance"
        say(medic, ("%s%s (id %d) is down at %s, %s away. ALT+click the body: Revive."):format(
            contract and "[CONTRACT] " or "", name, victim, fmtPos(entry.position), dist), COLOR.alert)
        toast(medic, "warning", contract and "Trauma Team: contract holder down" or "Trauma Team: citizen down",
            ("%s - %s away"):format(name, dist), 10000)
        TriggerClientEvent("rp_trauma:downBlip", medic, victim, entry.position, name, contract)
        notified = notified + 1
    end
    return notified
end

local function downMessage(entry)
    local left = secondsLeft(entry)
    if left > 0 then
        return ("You are down. Trauma Team has been notified. /respawn opens in %d s (Vik's bill %d €$)."):format(left, Config.hospitalBill)
    end
    return ("You are down. /respawn wakes you up at Vik's clinic (%d €$) - or wait for Trauma Team."):format(Config.hospitalBill)
end

-- Frees the body: drops the hold, restores regeneration, sets the health, tells the
-- clients. `healthFraction` nil leaves the health alone.
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

local function releaseHold(playerId, healthFraction)
    local entry = down[playerId]
    down[playerId] = nil
    if entry and entry.pose then stageRelease(playerId, entry.pose); entry.pose = nil end
    local ok, reason = Open77.players.setFrozen(playerId, false)
    if not ok then
        log("setFrozen(%d, false): %s", playerId, tostring(reason))
    end
    Open77.stats.setHealthRegenEnabled(playerId, true)
    if healthFraction then
        if healthFraction >= 1.0 then
            Open77.stats.restoreHealth(playerId)
        else
            local stats = Open77.stats.get(playerId)
            local maximum = stats and stats.health and stats.health.maximum or 100
            Open77.stats.setHealth(playerId, math.max(1, math.floor(maximum * healthFraction)))
        end
    end
    TriggerClientEvent("rp_trauma:hold", playerId, false, 0)
    TriggerClientEvent("rp_trauma:downClear", -1, playerId)
end

-- Runs when the life phase is back to "alive" for a down player: back to the death
-- spot, frozen, low health, inputs blocked on the client.
local function applyHold(playerId)
    local entry = down[playerId]
    if not entry or entry.applying then
        return
    end
    entry.applying = true

    -- Back to the death spot. The respawn may still be settling ("recovering"), so a
    -- refusal is retried a few times before the hold is applied where the body stands.
    for attempt = 1, 4 do
        local pending, reason = Open77.players.teleport(playerId, entry.position, { heading = entry.heading, dismount = true })
        local landed, err
        if pending then
            landed, err = pending:await()
        else
            err = reason
        end
        if landed or down[playerId] ~= entry then
            break
        end
        log("player %d: teleport back to the death spot failed (attempt %d): %s", playerId, attempt, tostring(err))
        Wait(1000)
    end
    if down[playerId] ~= entry then
        entry.applying = false
        return  -- revived or respawned while the body was in transit
    end

    local ok, why
    for _ = 1, 10 do
        ok, why = Open77.players.setFrozen(playerId, true)
        if ok or down[playerId] ~= entry then
            break
        end
        Wait(500)  -- transition_in_progress: the respawn is still being acked
    end
    if down[playerId] ~= entry then
        entry.applying = false
        return
    end
    if not ok then
        log("player %d: setFrozen refused: %s", playerId, tostring(why))
    end

    local stats = Open77.stats.get(playerId)
    local maximum = stats and stats.health and stats.health.maximum or 100
    local low = math.max(1, math.floor(maximum * Config.downHealthFraction))
    local okH, whyH = Open77.stats.setHealth(playerId, low)
    if not okH then
        log("player %d: setHealth(%d) refused: %s", playerId, low, tostring(whyH))
    end
    Open77.stats.setHealthRegenEnabled(playerId, false)

    entry.held = true
    entry.applying = false
    -- The wounded pose for as long as the player is down (Config.Stage.down).
    entry.pose = stageHold(playerId, "down")
    TriggerClientEvent("rp_trauma:hold", playerId, true, secondsLeft(entry))
    say(playerId, downMessage(entry))
    toast(playerId, "error", "You are down", "Trauma Team has been notified.", 8000)
    log("player %d held down at %s, %d s left", playerId, fmtPos(entry.position), secondsLeft(entry))
end

-- A scripted kill is a move, not a death: the admin tools (open77_admin /tp, /goto, /bring)
-- kill with cause "script" and weapon "open77_admin:<verb>" then respawn at the destination.
-- Such a death must not put the player down. Anything else (weapons, falls, /suicide, an
-- explosion) is a real death.
local function isScriptedMove(playerId)
    local life = Open77.players.getLifeState(playerId)
    if type(life) ~= "table" then return false end
    local weapon = tostring(life.weapon or life.lastWeapon or "")
    local cause = tostring(life.cause or life.lastCause or "")
    if weapon:find("^open77_admin:") then return true end
    if cause == "script" and weapon ~= "" and not weapon:find("suicide") then return true end
    return false
end

local function onDeath(playerId)
    if isScriptedMove(playerId) then
        log("player %d killed by a scripted move (admin teleport): not a death", playerId)
        return
    end
    local read = Open77.players.get(playerId)
    local pos = (read and read.position) or Open77.players.position(playerId)
    local entry = down[playerId]
    if entry then
        entry.deaths = entry.deaths + 1
        if pos then
            entry.position = { x = pos.x, y = pos.y, z = pos.z }
        end
        entry.held = false
        log("player %d died again while down (%d deaths)", playerId, entry.deaths)
        return
    end
    if not pos then
        log("player %d died with no known position: no down state", playerId)
        return
    end
    entry = {
        position = { x = pos.x, y = pos.y, z = pos.z },
        heading = (read and read.heading) or 0.0,
        since = nowMono(),
        deadline = nowMono() + Config.downSeconds,
        deaths = 1,
        held = false,
        applying = false,
        reminderAt = nowMono() + Config.downReminderSeconds,
        announcedOpen = false,
    }
    down[playerId] = entry
    local notified = announceDown(playerId, entry)
    say(playerId, downMessage(entry))
    toast(playerId, "error", "You are down", "Trauma Team has been notified.", 8000)
    TriggerEvent("rp_trauma:down", playerId, entry.position)
    log("player %d down at %s, %d medic(s) notified, %d s", playerId, fmtPos(entry.position), notified, Config.downSeconds)
end

-- A connecting client reports a "dead" phase while its pristine template loads (measured
-- 2026-09-18: the event arrived 10 ms after the freeroam gate opened, at the handoff
-- position 2567, 113, 79, and would have held the player there). A death only counts once
-- the player has been seen alive after onPlayerReady, and never inside the connect grace.
local seenAlive = {}
local readyAt = {}
local CONNECT_GRACE_SECONDS = 15

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Players already in the world when the resource (re)starts have settled long ago.
    for _, id in ipairs(Open77.players.all()) do
        readyAt[id] = nowMono() - CONNECT_GRACE_SECONDS
        seenAlive[id] = not Open77.players.isDead(id)
    end
end)

AddEventHandler("onPlayerLifeStateChanged", function(playerId, revision, phase)
    local id = tonumber(playerId)
    if not id then
        return
    end
    if phase == "dead" then
        local life = Open77.players.getLifeState(id)
        if type(life) == "table" then
            local parts = {}
            for k, v in pairs(life) do if type(v) ~= "table" then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end end
            table.sort(parts)
            log("player %d life snapshot: %s", id, table.concat(parts, " "))
        end
        local since = readyAt[id] and (nowMono() - readyAt[id]) or -1
        if not seenAlive[id] or since < CONNECT_GRACE_SECONDS then
            log("player %d dead phase ignored (connect grace: alive=%s, %.0f s after ready)", id,
                tostring(seenAlive[id] == true), since)
            return
        end
        onDeath(id)
    elseif phase == "alive" then
        if readyAt[id] then
            seenAlive[id] = true
        end
        if down[id] then
            applyHold(id)
        end
    end
end)

-- Countdown reminders for down players.
CreateThread(function()
    while true do
        Wait(1000)
        for id, entry in pairs(down) do
            local left = secondsLeft(entry)
            if left == 0 and not entry.announcedOpen then
                entry.announcedOpen = true
                say(id, ("/respawn is open: Vik's clinic takes you for %d €$. Or keep waiting for Trauma Team."):format(Config.hospitalBill))
                toast(id, "info", "Trauma Team", "/respawn is open.", 6000)
                if entry.held then
                    TriggerClientEvent("rp_trauma:hold", id, true, 0)
                end
            elseif nowMono() >= entry.reminderAt then
                entry.reminderAt = nowMono() + Config.downReminderSeconds
                say(id, downMessage(entry))
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(30000)
        renewContracts()
    end
end)

-- ---------------------------------------------------------------------------
-- Hospital respawn
-- ---------------------------------------------------------------------------

local function hospitalRespawn(playerId)
    local entry = down[playerId]
    if not entry then
        return
    end
    releaseHold(playerId, nil)

    local target = Config.hospital.respawn
    if Open77.players.isDead(playerId) then
        local ok, reason = Open77.players.respawn(playerId, {
            position = target, heading = Config.hospital.heading, health = 1.0, graceMs = Config.reviveGraceMs,
        })
        if not ok then
            say(playerId, "Hospital respawn refused: " .. tostring(reason) .. ". Try /respawn again.")
            log("player %d: respawn at the hospital refused: %s", playerId, tostring(reason))
            return
        end
    else
        local pending, reason = Open77.players.teleport(playerId, target, { heading = Config.hospital.heading, dismount = true })
        if not pending then
            say(playerId, "Transfer to Vik's clinic refused: " .. tostring(reason) .. ".")
            log("player %d: teleport to the hospital refused: %s", playerId, tostring(reason))
        else
            local landed, err = pending:await()
            if not landed then
                say(playerId, "Transfer to Vik's clinic failed: " .. tostring(err) .. ".")
                log("player %d: teleport to the hospital failed: %s", playerId, tostring(err))
            end
        end
        Open77.stats.restoreHealth(playerId)
    end

    local result = collect(playerId, Config.hospitalBill, "hospital")
    say(playerId, ("Trauma Team dropped you at Vik's clinic. Bill: %s."):format(billSentence(result)))
    toast(playerId, "info", "Vik's clinic", ("Patched up. %d €$ billed."):format(Config.hospitalBill), 8000)
    TriggerEvent("rp_trauma:revived", playerId, nil)
    log("player %d hospital respawn: account=%d cash=%d debt=%d", playerId, result.account, result.cash, result.debt)
end

RegisterCommand("respawn", function(source)
    if source == 0 then
        return print("[rp_trauma] /respawn must be used by a player in game, not from the console")
    end
    local entry = down[source]
    if not entry then
        return say(source, "You are not down, choom. Nothing to respawn from.")
    end
    if entry.applying then
        return say(source, "Hold on, the body is still settling. Try again in a second.")
    end
    local left = secondsLeft(entry)
    local medics = #medicsOnDuty(source)
    if left > 0 and medics > 0 then
        return say(source, ("Trauma Team is on duty (%d medic%s). /respawn opens in %d s."):format(medics, medics > 1 and "s" or "", left))
    end
    if left > 0 and Config.countdownWithoutMedics then
        return say(source, ("Hold on, choom: /respawn opens in %d s."):format(left))
    end
    hospitalRespawn(source)
end, false)

-- ---------------------------------------------------------------------------
-- Medic acts: heal (stabilise) and revive
-- ---------------------------------------------------------------------------

-- Fills the patient's health. opts.fee > 0 charges the patient. true | nil, reason.
local function doHeal(patient, medic, opts)
    if Open77.players.isDead(patient) or down[patient] then
        return nil, "patient_down"
    end
    local ok, reason = Open77.stats.restoreHealth(patient)
    if not ok then
        return nil, reason or "heal_failed"
    end
    local fee = opts and opts.fee or 0
    local result = fee > 0 and collect(patient, fee, "heal") or nil
    if medic then
        bump(medic, "heal")
        local medicName = displayName(medic)
        say(patient, result and ("Medic %s stabilised you: %s."):format(medicName, billSentence(result))
            or ("Medic %s stabilised you."):format(medicName))
    end
    log("player %s stabilised player %d fee=%d", tostring(medic), patient, fee)
    return true
end

-- Brings a down (or dead) patient back. opts.fee > 0 charges the patient unless they
-- hold a contract. true | nil, reason.
local function doRevive(patient, medic, opts)
    local entry = down[patient]
    local wasDead = Open77.players.isDead(patient)
    if not wasDead and not entry then
        return nil, "patient_not_down"
    end
    if wasDead then
        down[patient] = nil
        if entry and entry.pose then stageRelease(patient, entry.pose); entry.pose = nil end
        local ok, reason = Open77.players.revive(patient, { health = Config.reviveHealthFraction, graceMs = Config.reviveGraceMs })
        if not ok then
            down[patient] = entry
            return nil, reason or "revive_failed"
        end
        TriggerClientEvent("rp_trauma:hold", patient, false, 0)
        TriggerClientEvent("rp_trauma:downClear", -1, patient)
    else
        releaseHold(patient, Config.reviveHealthFraction)
    end
    local fee = opts and opts.fee or 0
    local free = fee <= 0 or hasContract(patient)
    local result = (not free) and collect(patient, fee, "revive") or nil
    if medic then
        bump(medic, "revive")
        local medicName = displayName(medic)
        if result then
            say(patient, ("Medic %s revived you: %s."):format(medicName, billSentence(result)))
        elseif fee > 0 then
            say(patient, ("Medic %s revived you. Contract holder: no charge."):format(medicName))
        else
            say(patient, ("Medic %s revived you."):format(medicName))
        end
        toast(patient, "success", "Trauma Team", "Back on your feet.", 6000)
    end
    TriggerEvent("rp_trauma:revived", patient, medic)
    log("player %s revived player %d fee=%d dead=%s", tostring(medic), patient, free and 0 or fee, tostring(wasDead))
    return true
end

local function cooldownLeft(medic)
    local last = cooldowns[medic]
    if not last then
        return 0
    end
    return math.max(0, Config.medicCooldownSeconds - (nowMono() - last))
end

-- The whole medic flow: gates, progress bar, re-check, act. `range` in metres.
local function performAction(medic, kind, target, range)
    if busy[medic] then
        return say(medic, "Finish your current intervention first.")
    end
    local onDuty = isMedicOnDuty(medic)
    if onDuty == nil then
        return say(medic, "Trauma Team roster unavailable (rp_jobs offline). Try again later.")
    end
    if not onDuty then
        return say(medic, "Trauma Team on duty only. Get the job and /service to clock in.")
    end
    local left = cooldownLeft(medic)
    if left > 0 then
        return say(medic, ("Wait another %d s before your next intervention."):format(math.ceil(left)))
    end
    if not target then
        return say(medic, "Usage: /" .. (kind == "revive" and "reanimer" or "soin") .. " <playerId>")
    end
    if target == medic then
        return say(medic, "You can't treat yourself, choom.")
    end
    local read, reason = Open77.players.get(target)
    if not read then
        return say(medic, ("Player %d not found (%s)."):format(target, tostring(reason)))
    end
    if not read.ready then
        return say(medic, "This player is not in the world yet.")
    end
    local metres, dreason = Open77.players.distance(medic, target)
    if not metres then
        return say(medic, "Patient position unknown (" .. tostring(dreason) .. ").")
    end
    if metres > range then
        return say(medic, ("Too far: %.1f m (%.0f m max)."):format(metres, range))
    end

    local dead = Open77.players.isDead(target)
    local isDownTarget = down[target] ~= nil
    if kind == "stabilise" then
        if dead or isDownTarget then
            return say(medic, "This patient is down: use Revive (/reanimer).")
        end
        local stats = Open77.stats.get(target)
        if stats and stats.health and stats.health.value >= stats.health.maximum then
            return say(medic, "This patient is already at full health.")
        end
    else
        if not dead and not isDownTarget then
            return say(medic, "This patient is on their feet: use Stabilise (/soin).")
        end
    end

    local duration = kind == "stabilise" and Config.stabiliseMs or Config.reviveMs
    local label = kind == "stabilise" and "Stabilising the patient" or "Reviving the patient"
    busy[medic] = true
    -- Staged: the medic kneels over the patient, injector in hand, for the whole bar
    -- (Config.Stage.stabilise / revive); without the UI kit the stage keeps the beat itself.
    local answer, err = stage(medic, kind, { label = label, durationMs = duration })
    busy[medic] = nil
    if not answer then
        return say(medic, "Intervention interrupted (" .. tostring(err) .. ").")
    end
    if not answer.ok then
        return say(medic, "Intervention cancelled.")
    end

    -- The world moved during the bar: check again.
    if Open77.players.isDead(medic) or down[medic] then
        return
    end
    local again = Open77.players.distance(medic, target)
    if not again or again > range + 1.0 then
        return say(medic, "The patient is out of reach.")
    end

    local ok, why
    if kind == "stabilise" then
        ok, why = doHeal(target, medic, { fee = Config.healFee })
    else
        ok, why = doRevive(target, medic, { fee = Config.reviveFee })
    end
    if not ok then
        return say(medic, "Intervention failed: " .. tostring(why) .. ".")
    end
    cooldowns[medic] = nowMono()
    local patientName = displayName(target)
    if kind == "stabilise" then
        say(medic, ("Patient %s stabilised. %d €$ billed to the patient for Trauma Team."):format(patientName, Config.healFee))
    elseif hasContract(target) then
        say(medic, ("Patient %s revived. Contract holder: no charge."):format(patientName))
    else
        say(medic, ("Patient %s revived. %d €$ billed to the patient for Trauma Team."):format(patientName, Config.reviveFee))
    end
end

RegisterCommand("soin", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /soin must be used by a player in game, not from the console")
    end
    performAction(source, "stabilise", playerIdArg(args[1]), Config.commandRange)
end, false)

RegisterCommand("reanimer", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /reanimer must be used by a player in game, not from the console")
    end
    performAction(source, "revive", playerIdArg(args[1]), Config.commandRange)
end, false)

-- ALT+click on a player: the client only names the target and the verb.
RegisterNetEvent("rp_trauma:action", function(kind, targetId)
    if type(source) ~= "number" or source < 1 then
        return
    end
    if kind ~= "stabilise" and kind ~= "revive" then
        return
    end
    performAction(source, kind, playerIdArg(targetId), Config.actionRange + 1.0)
end)

-- ---------------------------------------------------------------------------
-- /911 and /medic (from rp_medic)
-- ---------------------------------------------------------------------------

RegisterCommand("911", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /911 must be used by a player in game, not from the console")
    end
    local message = table.concat(args, " ", 1, args.n or #args):match("^%s*(.-)%s*$")
    if message == "" then
        return say(source, "Usage: /911 <message>")
    end
    local pos = Open77.players.position(source)
    local where = pos and fmtPos(pos) or "unknown position"
    gesture(source, "call")
    local alert = {
        author = "911",
        text = ("%s (id %d) at %s: %s"):format(displayName(source), source, where, message),
        color = COLOR.alert,
    }
    local responders = {}
    for _, id in ipairs(listOnDuty(Config.job)) do
        responders[tonumber(id) or -1] = true
    end
    for _, id in ipairs(listOnDuty("ncpd")) do
        responders[tonumber(id) or -1] = true
    end
    local notified = 0
    for id in pairs(responders) do
        if id ~= source and id > 0 then
            local ok, reason = Open77.chat.send(id, alert)
            if ok then
                notified = notified + 1
                toast(id, "warning", "911", ("%s: %s"):format(displayName(source), message), 8000)
            else
                log("911 alert to player %d failed: %s", id, tostring(reason))
            end
        end
    end
    if pos then
        TriggerEvent("rp_ncpd:alert", "911", { x = pos.x, y = pos.y, z = pos.z }, message, source)
    end
    say(source, ("Call relayed to %d responder(s) on duty (Trauma Team and NCPD)."):format(notified))
    log("player %d called 911 at %s notified=%d", source, where, notified)
end, false)

RegisterCommand("medic", function(source)
    if source == 0 then
        return print("[rp_trauma] /medic must be used by a player in game, not from the console")
    end
    local medics = {}
    local callerIsMedic = false
    for _, id in ipairs(listOnDuty(Config.job)) do
        id = tonumber(id)
        if id == source then
            callerIsMedic = true
        elseif id then
            medics[#medics + 1] = { id = id, name = displayName(id), metres = Open77.players.distance(source, id) }
        end
    end
    table.sort(medics, function(a, b)
        if a.metres and b.metres then
            return a.metres < b.metres
        end
        return a.metres ~= nil and b.metres == nil
    end)
    if #medics == 0 then
        say(source, callerIsMedic and "No other medic on duty." or "No medic on duty: /respawn is immediate if you go down.")
    else
        say(source, ("%d medic(s) on duty:"):format(#medics))
        for _, medic in ipairs(medics) do
            Wait(0)  -- two sends in the same tick arrive in reverse order
            local dist = medic.metres and ("%.0f m"):format(medic.metres) or "unknown distance"
            say(source, ("- %s (id %d): %s"):format(medic.name, medic.id, dist))
        end
    end
    if callerIsMedic then
        local line = statsLine(source)
        if line then
            Wait(0)
            say(source, line)
        end
    end
end, false)

-- ---------------------------------------------------------------------------
-- /trauma [av | av off | factures | payer]
-- ---------------------------------------------------------------------------

local function removeAv(medic)
    local vehicleId = avByMedic[medic]
    if not vehicleId then
        return false
    end
    avByMedic[medic] = nil
    local ok = Open77.vehicles.remove(vehicleId)
    log("player %d AV %s removed ok=%s", medic, tostring(vehicleId), tostring(ok))
    return true
end

local function traumaAv(medic, mode)
    local onDuty = isMedicOnDuty(medic)
    if onDuty == nil then
        return say(medic, "Trauma Team roster unavailable (rp_jobs offline).")
    end
    if not onDuty then
        return say(medic, "Trauma Team on duty only.")
    end
    if mode == "off" then
        if removeAv(medic) then
            return say(medic, "Your AV went back to the hangar.")
        end
        return say(medic, "You have no AV out.")
    end
    local read = Open77.players.get(medic)
    if not read or not read.position then
        return say(medic, "Your position is unknown: move a little and try again.")
    end
    -- The pad is a street point (Config.av.pad), not a zone: the clinic interior cannot take an AV.
    local pad = Config.av.pad
    local dx, dy = read.position.x - pad.x, read.position.y - pad.y
    local padDistance = math.sqrt(dx * dx + dy * dy)
    if padDistance > pad.radius then
        return say(medic, ("The AV pad is on the %s (%d, %d), %d m from you: stand on it first."):format(
            pad.label, math.floor(pad.x + 0.5), math.floor(pad.y + 0.5), math.floor(padDistance + 0.5)))
    end
    removeAv(medic)
    local yaw = read.heading or 0.0
    local rad = math.rad(yaw)
    local position = {
        x = read.position.x + math.sin(rad) * Config.av.spawnDistance,
        y = read.position.y + math.cos(rad) * Config.av.spawnDistance,
        z = read.position.z + Config.av.spawnUp,
    }
    local id, reason = Open77.vehicles.create({
        record = Config.av.record,
        position = position,
        yaw = yaw,
        ttlMs = Config.av.ttlMs,
        despawnWhenUnobserved = Config.av.despawnWhenUnobserved,
    })
    if not id then
        return say(medic, ("AV request refused (%s). Record: %s."):format(tostring(reason), Config.av.record))
    end
    avByMedic[medic] = id
    local ok, why = Open77.vehicles.warpPlayerIntoVehicle(medic, id, "driver")
    if ok then
        say(medic, "Trauma Team AV on the pad. You are at the controls. /trauma av off sends it back.")
    else
        say(medic, ("Trauma Team AV on the pad (id %s), seat refused: %s. Walk to it."):format(tostring(id), tostring(why)))
    end
    log("player %d spawned AV %s (%s) at %s seat=%s", medic, tostring(id), Config.av.record, fmtPos(position), tostring(ok))
end

local function listBills(playerId)
    local identifier = Open77.players.identifier(playerId)
    local list = identifier and bills[identifier] or {}
    if #list == 0 then
        return say(playerId, "No unpaid Trauma Team bill. Clean slate, choom.")
    end
    say(playerId, ("%d unpaid bill(s), %d €$ in total. /trauma payer settles them (account, then cash)."):format(#list, debtTotal(identifier)))
    for _, row in ipairs(list) do
        Wait(0)
        say(playerId, ("- %d €$ (%s)"):format(row.amount, row.reason))
    end
end

local function payBills(playerId)
    local identifier = Open77.players.identifier(playerId)
    local list = identifier and bills[identifier] or {}
    if #list == 0 then
        return say(playerId, "No unpaid Trauma Team bill.")
    end
    local paid = 0
    while #list > 0 do
        local row = list[1]
        local newBalance = bankCharge(playerId, row.amount, "bill")
        if not newBalance then
            local balance = cashBalance(playerId) or 0
            if balance >= row.amount and cashRemove(playerId, row.amount, "trauma_bill") then
                societyAdd(row.amount, "bill")
            else
                break
            end
        end
        paid = paid + row.amount
        markBillPaid(identifier, row)  -- removes the row from `list`
    end
    if paid == 0 then
        return say(playerId, ("Nothing could be paid: %d €$ still owed. Fund your account or your pockets."):format(debtTotal(identifier)))
    end
    local left = debtTotal(identifier)
    if left > 0 then
        say(playerId, ("Paid %d €$ of Trauma Team bills. %d €$ still owed."):format(paid, left))
    else
        say(playerId, ("Paid %d €$ of Trauma Team bills. Clean slate."):format(paid))
    end
    log("player %d paid bills %d left=%d", playerId, paid, left)
end

local function traumaStatus(playerId)
    local entry = down[playerId]
    local c = contractOf(playerId)
    local identifier = Open77.players.identifier(playerId)
    local debt = identifier and debtTotal(identifier) or 0
    local contractText = "no contract (/contrat)"
    if c and c.active then
        contractText = ("contract active, %d min left in this period"):format(math.max(0, math.ceil((c.untilAt - nowUnix()) / 60)))
    end
    say(playerId, ("Trauma Team: %s; %s; unpaid bills %d €$."):format(
        entry and ("you are DOWN, /respawn in %d s"):format(secondsLeft(entry)) or "you are on your feet",
        contractText, debt))
    if isMedicOnDuty(playerId) then
        local list = downList(playerId)
        Wait(0)
        if #list == 0 then
            say(playerId, "Dispatch: nobody is down.")
        else
            say(playerId, ("Dispatch: %d citizen(s) down:"):format(#list))
            for _, item in ipairs(list) do
                Wait(0)
                local metres = Open77.players.distance(playerId, item.position)
                say(playerId, ("- %s%s (id %d) at %s, %s"):format(item.contract and "[CONTRACT] " or "", item.name,
                    item.playerId, fmtPos(item.position), metres and ("%.0f m"):format(metres) or "unknown distance"))
            end
        end
        Wait(0)
        say(playerId, "/trauma av spawns the AV on the Afterlife street pad; ALT+click a body to Stabilise or Revive.")
    end
end

RegisterCommand("trauma", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /trauma must be used by a player in game, not from the console")
    end
    local sub = (args[1] or ""):lower()
    if sub == "av" then
        traumaAv(source, (args[2] or ""):lower())
    elseif sub == "factures" or sub == "bills" then
        listBills(source)
    elseif sub == "payer" or sub == "pay" then
        payBills(source)
    else
        traumaStatus(source)
    end
end, false)

-- ---------------------------------------------------------------------------
-- /contrat: UI kit menu (server twin)
-- ---------------------------------------------------------------------------

RegisterCommand("contrat", function(source)
    if source == 0 then
        return print("[rp_trauma] /contrat must be used by a player in game, not from the console")
    end
    if down[source] then
        return say(source, "Sign it when you are back on your feet.")
    end
    local c = contractOf(source)
    local options = {}
    if c and c.active then
        options[#options + 1] = {
            id = "status", label = "My contract",
            description = ("Active. Renews for %d €$ in %d min, charged from your account."):format(
                Config.contractPrice, math.max(0, math.ceil((c.untilAt - nowUnix()) / 60))),
        }
        options[#options + 1] = {
            id = "cancel", label = "Cancel my contract", tone = "danger",
            description = "No refund for the running period.",
        }
    else
        options[#options + 1] = {
            id = "subscribe", label = ("Subscribe - %d €$ per %d min"):format(Config.contractPrice, Config.contractMinutes),
            description = "Free revives, priority dispatch, gold pin on every medic's map. Renewed while your account is funded.",
            metadata = { { label = "Price", value = ("%d €$"):format(Config.contractPrice) } },
        }
    end
    options[#options + 1] = { id = "leave", label = "Leave" }

    local promise, dispatchError = Open77.exports.call("open77_uikit", "context", source, {
        id = "rp_trauma_contract",
        title = "Trauma Team contract",
        description = "Platinum coverage for Night City's finest citizens.",
        options = options,
    }, { timeoutMs = 60000 })
    if not promise then
        return say(source, "The contract terminal is offline (" .. tostring(dispatchError) .. ").")
    end
    local answer, reason = promise:await()
    if not answer then
        return say(source, "The contract terminal did not answer (" .. tostring(reason) .. ").")
    end
    if not answer.ok then
        return
    end
    local picked = answer.value and answer.value.id
    if picked == "subscribe" then
        subscribe(source)
    elseif picked == "cancel" then
        cancelContract(source)
    elseif picked == "status" then
        traumaStatus(source)
    end
end, false)

-- ---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
-- ---------------------------------------------------------------------------

exports("isDown", function(playerId)
    local id = playerIdArg(playerId)
    return id ~= nil and down[id] ~= nil
end)

exports("hasContract", function(playerId)
    local id = playerIdArg(playerId)
    return id ~= nil and hasContract(id)
end)

-- Exports never charge a fee: the caller owns the money decision.
exports("heal", function(playerId, byPlayerId)
    local id = playerIdArg(playerId)
    if not id then
        return nil, "invalid_player_id"
    end
    if not Open77.players.get(id) then
        return nil, "player_not_found"
    end
    return doHeal(id, playerIdArg(byPlayerId), { fee = 0 })
end)

exports("revive", function(playerId, byPlayerId)
    local id = playerIdArg(playerId)
    if not id then
        return nil, "invalid_player_id"
    end
    if not Open77.players.get(id) then
        return nil, "player_not_found"
    end
    return doRevive(id, playerIdArg(byPlayerId), { fee = 0 })
end)

-- ---------------------------------------------------------------------------
-- Client sync, job events, lifecycle
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_trauma:clientReady", function()
    if type(source) ~= "number" or source < 1 then
        return
    end
    pushMedicState(source)
    local entry = down[source]
    if entry and entry.held then
        TriggerClientEvent("rp_trauma:hold", source, true, secondsLeft(entry))
    end
end)

AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    local id = tonumber(playerId)
    if id then
        pushMedicState(id)
    end
end)

AddEventHandler("rp_jobs:changed", function(playerId, jobName)
    local id = tonumber(playerId)
    if id then
        pushMedicState(id)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    local id = tonumber(playerId)
    if not id then
        return
    end
    readyAt[id] = nowMono()
    seenAlive[id] = false
    -- The connect phases have settled by now; a ready player who is not dead was seen alive.
    SetTimeout(CONNECT_GRACE_SECONDS * 1000, function()
        if readyAt[id] and not Open77.players.isDead(id) then
            seenAlive[id] = true
        end
    end)
    loadPlayer(id)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if not id then
        return
    end
    seenAlive[id] = nil
    readyAt[id] = nil
    if down[id] then
        down[id] = nil
        TriggerClientEvent("rp_trauma:downClear", -1, id)
        log("player %d disconnected while down", id)
    end
    removeAv(id)
    cooldowns[id] = nil
    busy[id] = nil
    loaded[id] = nil
    stageClear(id)
end)

local SUGGESTIONS = {
    { command = "/soin", help = "Stabilise a hurt patient within 5 m (Trauma Team on duty, 100 €$)",
      parameters = { { name = "playerId", help = "Patient id (/id)" } } },
    { command = "/reanimer", help = "Revive a down patient within 5 m (Trauma Team on duty, 300 €$)",
      parameters = { { name = "playerId", help = "Patient id (/id)" } } },
    { command = "/911", help = "Alert Trauma Team and the NCPD with your position",
      parameters = { { name = "message", help = "What is happening" } } },
    { command = "/medic", help = "Medics on duty and their distance" },
    { command = "/respawn", help = "While down: give up and wake up at Vik's clinic (500 €$)" },
    { command = "/trauma", help = "Status; av | av off (medic, on the Afterlife street pad); factures | payer",
      parameters = { { name = "action", help = "av, av off, factures, payer" } } },
    { command = "/contrat", help = "Trauma Team contract: free revives and priority dispatch" },
}

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then
        log("addSuggestions(%s) failed: %s", tostring(target), tostring(reason))
    end
end

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source < 1 then
        return
    end
    publishSuggestions(source)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    publishSuggestions(-1)

    local queued, reason = Open77.database.ready(function()
        DB.update(SQL_CONTRACTS, {}, function()
            DB.update(SQL_BILLS, {}, function()
                store = "sql"
                log("store=sql tables=rp_trauma_contracts,rp_trauma_bills")
            end)
        end)
    end)
    if not queued then
        useKvp(reason)
    end

    for _, id in ipairs(Open77.players.all()) do
        pushMedicState(id)
        if not loaded[id] then
            CreateThread(function()
                loadPlayer(id)  -- may wait for the store decision: one task per player
            end)
        end
    end
    log("started: down=%d s, hospital bill=%d, fees heal=%d revive=%d, contract=%d €$/%d min, hospital at %s, av=%s",
        Config.downSeconds, Config.hospitalBill, Config.healFee, Config.reviveFee, Config.contractPrice,
        Config.contractMinutes, fmtPos(Config.hospital.respawn), Config.av.record)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then
        return
    end
    for id, entry in pairs(down) do
        if entry.pose then stageRelease(id, entry.pose) end
        Open77.players.setFrozen(id, false)
        Open77.stats.setHealthRegenEnabled(id, true)
        Open77.stats.restoreHealth(id)
        TriggerClientEvent("rp_trauma:hold", id, false, 0)
    end
    down = {}
    for medic in pairs(avByMedic) do
        removeAv(medic)
    end
    log("stopped: every held player freed")
end)
