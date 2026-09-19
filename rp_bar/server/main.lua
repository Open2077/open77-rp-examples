-- rp_bar server: the Afterlife bar counter.
-- Server-authoritative: the till, the pockets, the price, the buzz and the ledger are
-- decided here. Clients render the counter prompt, the menus and the ALT+click action,
-- and request.
--
-- Cross-resource contracts (all reached through pcall'd synchronous exports, none
-- declared as a dependency because this manifest has a client script):
--   rp_jobs      getJob / onDuty                     -> who may work the counter
--   rp_inventory define / has / count / add / remove -> drinks and ingredients
--   rp_bank      society / societyAdd / societyRemove -> the till (society "barman")
--   rp_economy   remove / add                        -> the customer's cash, the tip
--   rp_needs     (through rp_inventory's item effect) -> thirst restored on /use

local RESOURCE = GetCurrentResourceName()
local C = RpBarConfig
local PINK = { 255, 95, 162 }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_bar] " .. fmt):format(...))
end

local function chat(playerId, text)
    if playerId == 0 then print(text); return end
    local ok, reason = Open77.chat.send(playerId, { type = "system", author = "Afterlife", text = text, color = PINK })
    if not ok then log("chat refused for player %s: %s", tostring(playerId), tostring(reason)) end
end

local function toast(playerId, kind, title, message)
    if playerId == 0 then return end
    Open77.notifications.send(playerId, {
        type = kind, title = title or "Afterlife", message = message, icon = "BAR", durationMs = 6000,
    })
end

-- "12 345 €$"
local function money(amount)
    amount = math.floor(tonumber(amount) or 0)
    local s = tostring(amount)
    local out = ""
    while #s > 3 do
        out = " " .. s:sub(-3) .. out
        s = s:sub(1, -4)
    end
    return s .. out .. " €$"
end

local function playerName(playerId)
    local ok, name = pcall(Open77.exports.callSync, "rp_identity", "fullName", playerId)
    if ok and type(name) == "string" and name ~= "" then return name end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

local function isConnected(playerId)
    return type(playerId) == "number" and playerId > 0 and Open77.players.name(playerId) ~= nil
end

-- Calls another resource's synchronous export. First value: whether the call reached
-- the export at all (false = resource or export missing, or it raised); then the
-- export's own return values.
local function callExport(resource, name, ...)
    local packed = table.pack(pcall(Open77.exports.callSync, resource, name, ...))
    if not packed[1] then return false, tostring(packed[2]) end
    return true, table.unpack(packed, 2, packed.n)
end

local function why(reason)
    local text = {
        insufficient_funds = "not enough eddies",
        insufficient_cash = "not enough cash",
        not_enough = "not enough of it in the pockets",
        too_heavy = "the pockets are too heavy",
        unknown_item = "unknown item",
        player_not_found = "unknown player",
        not_loaded = "pockets still loading, try again in a second",
        bank_not_ready = "the bank is still booting",
        wallet_unavailable = "the wallet system is offline",
    }
    return text[reason] or tostring(reason)
end

-- ---------------------------------------------------------------------------
-- Drinks and ingredients
-- ---------------------------------------------------------------------------

local function drinkList()
    local list = {}
    for _, id in ipairs(C.drinkOrder or {}) do
        if C.drinks[id] then list[#list + 1] = id end
    end
    for id in pairs(C.drinks) do
        local seen = false
        for _, known in ipairs(list) do if known == id then seen = true end end
        if not seen then list[#list + 1] = id end
    end
    return list
end

local function ingredientList()
    local list = {}
    for _, id in ipairs(C.ingredientOrder or {}) do
        if C.ingredients[id] then list[#list + 1] = id end
    end
    for id in pairs(C.ingredients) do
        local seen = false
        for _, known in ipairs(list) do if known == id then seen = true end end
        if not seen then list[#list + 1] = id end
    end
    return list
end

local function labelOf(itemId)
    local item = C.drinks[itemId] or C.ingredients[itemId]
    return (item and item.label) or itemId
end

-- Resolves a drink by id, label or unambiguous prefix (case-insensitive).
local function resolveDrink(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local needle = text:lower()
    if C.drinks[needle] then return needle end
    local found = nil
    for _, id in ipairs(drinkList()) do
        local label = (C.drinks[id].label or id):lower()
        if label == needle then return id end
        if id:sub(1, #needle) == needle or label:sub(1, #needle) == needle then
            if found and found ~= id then return nil, "ambiguous" end
            found = id
        end
    end
    if found then return found end
    return nil, "unknown"
end

-- The table handed to rp_inventory:define -- only the fields it knows.
local function itemDefinitions()
    local items = {}
    for id, drink in pairs(C.drinks) do
        items[id] = {
            label = drink.label, weight = drink.weight,
            usable = drink.usable ~= false, illegal = drink.illegal == true,
            effect = drink.effect,
        }
    end
    for id, ingredient in pairs(C.ingredients) do
        items[id] = {
            label = ingredient.label, weight = ingredient.weight,
            usable = false, illegal = ingredient.illegal == true,
        }
    end
    return items
end

local itemsDefined = false
local function defineItems(reason)
    local available, registered, rejected = callExport("rp_inventory", "define", itemDefinitions())
    if not available then
        itemsDefined = false
        log("items not defined (%s): rp_inventory unavailable: %s", reason, tostring(registered))
        return
    end
    itemsDefined = true
    local function describe(value)
        if type(value) == "table" then
            local names = {}
            for k, v in pairs(value) do names[#names + 1] = type(k) == "number" and tostring(v) or tostring(k) end
            table.sort(names)
            return #names == 0 and "none" or table.concat(names, ",")
        end
        return tostring(value)
    end
    log("items defined (%s): registered=%s rejected=%s", reason, describe(registered), describe(rejected))
end

-- ---------------------------------------------------------------------------
-- Pockets, cash and till (thin wrappers with the player told why)
-- ---------------------------------------------------------------------------

local function pocketCount(playerId, itemId)
    local available, count = callExport("rp_inventory", "count", playerId, itemId)
    if not available then return 0 end
    return tonumber(count) or 0
end

local function pocketHas(playerId, itemId, count)
    local available, has = callExport("rp_inventory", "has", playerId, itemId, count or 1)
    return available and has == true
end

local function pocketAdd(playerId, itemId, count)
    local available, ok, reason = callExport("rp_inventory", "add", playerId, itemId, count or 1)
    if not available then return nil, "inventory_offline" end
    if not ok then return nil, reason or "refused" end
    return true
end

local function pocketRemove(playerId, itemId, count)
    local available, ok, reason = callExport("rp_inventory", "remove", playerId, itemId, count or 1)
    if not available then return nil, "inventory_offline" end
    if not ok then return nil, reason or "refused" end
    return true
end

local function tillBalance()
    local available, society, reason = callExport("rp_bank", "society", C.society)
    if not available then return nil, "bank_offline" end
    if type(society) ~= "table" then return nil, reason or "bank_refused" end
    return tonumber(society.balance) or 0
end

local function tillAdd(amount, reason)
    local available, balance, err = callExport("rp_bank", "societyAdd", C.society, amount, reason)
    if not available then return nil, "bank_offline" end
    if balance == nil then return nil, err or "bank_refused" end
    return balance
end

local function tillRemove(amount, reason)
    local available, balance, err = callExport("rp_bank", "societyRemove", C.society, amount, reason)
    if not available then return nil, "bank_offline" end
    if balance == nil then return nil, err or "bank_refused" end
    return balance
end

local function cashRemove(playerId, amount, reason)
    local available, balance, err = callExport("rp_economy", "remove", playerId, amount, reason)
    if not available then return nil, "economy_offline" end
    if balance == nil then return nil, err or "refused" end
    return balance
end

local function cashAdd(playerId, amount, reason)
    local available, balance, err = callExport("rp_economy", "add", playerId, amount, reason)
    if not available then return nil, "economy_offline" end
    if balance == nil then return nil, err or "refused" end
    return balance
end

-- ---------------------------------------------------------------------------
-- The job: who is a barman, who is on duty
-- ---------------------------------------------------------------------------

local function jobOf(playerId)
    local available, job = callExport("rp_jobs", "getJob", playerId)
    if not available then return nil, "jobs_offline" end
    return job
end

local function isBarman(playerId)
    local job, reason = jobOf(playerId)
    if job == nil then return false, reason end
    return job == C.job
end

local function barmanOnDuty(playerId)
    local isOne, reason = isBarman(playerId)
    if not isOne then return false, reason or "not_barman" end
    local available, onDuty = callExport("rp_jobs", "onDuty", playerId)
    if not available then return false, "jobs_offline" end
    if onDuty ~= true then return false, "off_duty" end
    return true
end

local function pushDuty(playerId)
    local onDuty = barmanOnDuty(playerId)
    TriggerClientEvent("rp_bar:duty", playerId, onDuty == true)
end

-- Refuses a caller who is not an on-duty barman, with the reason in chat.
local function requireBarman(playerId)
    local ok, reason = barmanOnDuty(playerId)
    if ok then return true end
    if reason == "jobs_offline" then
        chat(playerId, "The jobs system is offline, choom. No shift, no counter.")
    elseif reason == "off_duty" then
        chat(playerId, "You are off duty. /service to clock in behind the counter.")
    else
        chat(playerId, "Staff only behind the counter. /agence to sign up as a bartender.")
    end
    return false
end

local function distanceToCounter(playerId)
    return Open77.players.distance(playerId, C.counter.position)
end

local function requireAtCounter(playerId)
    local reach = tonumber(C.counter.reach) or 0
    if reach <= 0 then return true end
    local metres, reason = distanceToCounter(playerId)
    if not metres then
        chat(playerId, ("Can't tell where you are (%s). Try again in a second."):format(tostring(reason)))
        return false
    end
    if metres > reach then
        chat(playerId, ("Get behind the counter at the Afterlife (%.0f m away, %.0f, %.0f)."):format(
            metres, C.counter.position.x, C.counter.position.y))
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Persistence: the sales ledger, SQL first, KVP when there is no database
-- ---------------------------------------------------------------------------

local store = "pending"       -- "pending" | "sql" | "kvp"
local queuedSales = {}        -- sales made before the store was decided
local sessionSales = 0
local sessionRevenue = 0

local function kvpWriteSale(sale)
    local n = math.floor(tonumber(Open77.kvp.get("sales:count", 0)) or 0) + 1
    Open77.kvp.set("sales:count", n)
    Open77.kvp.set(("sales:%d"):format(n), table.concat({
        tostring(sale.barman), tostring(sale.customer), tostring(sale.drink),
        tostring(sale.price), tostring(sale.at),
    }, "|"))
end

local function writeSale(sale)
    if store == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_bar_sales (barman, customer, drink, price, at) VALUES (?, ?, ?, ?, ?)",
            { sale.barman, sale.customer, sale.drink, sale.price, sale.at },
            function(id)
                if id == nil then log("sale insert failed (sql) drink=%s price=%d", sale.drink, sale.price) end
            end)
    elseif store == "kvp" then
        kvpWriteSale(sale)
    else
        queuedSales[#queuedSales + 1] = sale
    end
end

local function flushQueuedSales()
    local queued = queuedSales
    queuedSales = {}
    for _, sale in ipairs(queued) do writeSale(sale) end
    if #queued > 0 then log("flushed %d queued sale(s) to %s", #queued, store) end
end

local function useKvp(reason)
    if store ~= "pending" then return end
    store = "kvp"
    log("store=kvp reason=%s", tostring(reason))
    flushQueuedSales()
end

local function setupStore()
    local queued, reason = Open77.database.ready(function()
        if store ~= "pending" then
            log("database answered after the KVP fallback was chosen; keeping kvp for this boot")
            return
        end
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_bar_sales (
                id       BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
                barman   VARCHAR(64)  NOT NULL,
                customer VARCHAR(64)  NOT NULL,
                drink    VARCHAR(32)  NOT NULL,
                price    INT          NOT NULL,
                at       BIGINT       NOT NULL,
                INDEX rp_bar_sales_at (at),
                INDEX rp_bar_sales_barman (barman)
            )
        ]])
        store = "sql"
        log("store=sql table=rp_bar_sales")
        flushQueuedSales()
    end)
    if not queued then
        useKvp(reason)
        return
    end
    -- Configured but not answering: do not wait forever.
    SetTimeout(tonumber(C.persistence.dbWaitMs) or 15000, function()
        if store == "pending" then useKvp("database not answering after " .. tostring(C.persistence.dbWaitMs) .. " ms") end
    end)
end

-- Records a completed sale: the ledger, the session counters, the bus event.
local function recordSale(barmanId, customerId, drinkId, price)
    local sale = {
        barman = Open77.players.identifier(barmanId) or ("session:" .. tostring(barmanId)),
        customer = Open77.players.identifier(customerId) or ("session:" .. tostring(customerId)),
        drink = drinkId,
        price = price,
        at = math.floor(Open77.time.unix()),
    }
    sessionSales = sessionSales + 1
    sessionRevenue = sessionRevenue + price
    writeSale(sale)
    TriggerEvent("rp_bar:sold", barmanId, customerId, drinkId, price)
end

-- Today's sales (since midnight UTC) for the till view; awaits, so only from handlers.
local function todaySales()
    if store ~= "sql" then return nil end
    local now = math.floor(Open77.time.unix())
    local dayStart = now - (now % 86400)
    -- `.await` raises on a failed read; the till view then falls back to the session counters.
    local ok, row = pcall(Open77.database.single.await,
        "SELECT COUNT(*) AS n, COALESCE(SUM(price), 0) AS total FROM rp_bar_sales WHERE at >= ?",
        { dayStart })
    if not ok then log("today's sales read failed: %s", tostring(row)); return nil end
    if type(row) ~= "table" then return nil end
    return tonumber(row.n) or 0, tonumber(row.total) or 0
end

-- ---------------------------------------------------------------------------
-- The buzz
-- ---------------------------------------------------------------------------

local drunk = {}              -- playerId -> level 0..max
local animationWarned = false
local warnedOnce = {}         -- reason -> true, so a refusal is logged once, not every minute

local function warnOnce(key, fmt, ...)
    if warnedOnce[key] then return end
    warnedOnce[key] = true
    log(fmt, ...)
end

local function drunkLabel(level)
    for _, entry in ipairs(C.drunk.labels or {}) do
        if level > entry.above then return entry.text end
    end
    return "sober"
end

local function drunkLine(level)
    return ("Buzz: %d/%d (%s)"):format(level, C.drunk.max, drunkLabel(level))
end

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

local STAGE = RpBarConfig.Stage or {}
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

local function playProfile(playerId, profile, durationMs)
    if type(profile) == "table" then
        local selected
        for _, candidate in ipairs(profile) do
            local ok, entry = pcall(Open77.animations.get, candidate)
            if ok and type(entry) == "table" then selected = candidate; break end
        end
        profile = selected
    end
    if not profile then return end
    local playback, reason = Open77.animations.play(playerId, profile, { durationMs = durationMs, loop = false })
    if not playback and not animationWarned then
        animationWarned = true
        log("RP animation '%s' refused (%s); the bar works without it", tostring(profile), tostring(reason))
    end
end

local function applyWobble(playerId, level)
    if level <= C.drunk.screenAbove then return end
    local strength = 1.0
    for _, tier in ipairs(C.drunk.tiers or {}) do
        if level > tier.above then strength = tier.strength; break end
    end
    -- Finite duration on purpose: it outlives the next tick by a few seconds and expires
    -- by itself once the level drops, so nothing another resource put on the screen is
    -- ever cleared by this one.
    local duration = math.floor((tonumber(C.drunk.tickMs) or 60000) / 1000) + 5
    local ok, reason = Open77.effects.screen(playerId, "drunk", { strength = strength, duration = duration })
    if not ok then warnOnce("screen:" .. tostring(reason), "drunk overlay refused (%s); the buzz works without it", tostring(reason)) end
end

local function stumble(playerId)
    local result, reason = Open77.players.ragdoll(playerId, { durationMs = C.drunk.stumbleDurationMs or 2000 })
    if not result then
        -- motion_unavailable on a server without a database, body_unavailable in a car
        -- or while down, motion_busy right after another fall: the message still lands.
        warnOnce("ragdoll:" .. tostring(reason), "stumble refused (%s); only the chat line is shown", tostring(reason))
        return false
    end
    return true
end

local function setDrunk(playerId, level, source)
    level = math.max(0, math.min(C.drunk.max, math.floor(level)))
    local before = drunk[playerId] or 0
    if level == 0 then drunk[playerId] = nil else drunk[playerId] = level end
    if level ~= before then
        TriggerEvent("rp_bar:drunk", playerId, level)
        log("player %d buzz %d -> %d (%s)", playerId, before, level, source)
    end
    return level, before
end

local function onDrank(playerId, drinkId)
    local drink = C.drinks[drinkId]
    if not drink then return end
    local alcohol = tonumber(drink.alcohol) or 0
    if alcohol <= 0 then
        playProfile(playerId, C.drunk.profile, C.drunk.profileDurationMs or 4000)
        chat(playerId, ("%s %s"):format(drink.flavour or ("You drink the " .. drink.label .. "."), drunkLine(drunk[playerId] or 0)))
        return
    end
    local level, before = setDrunk(playerId, (drunk[playerId] or 0) + alcohol, "drank " .. drinkId)
    chat(playerId, ("%s %s"):format(drink.flavour or ("You drink the " .. drink.label .. "."), drunkLine(level)))
    if level > C.drunk.screenAbove then
        applyWobble(playerId, level)
        if before <= C.drunk.screenAbove then
            chat(playerId, "The room starts to tilt. Night City looks better like this anyway.")
        end
    end
    if level > C.drunk.stumbleAbove then
        -- No drinking pose for a wasted drinker: the body goes down instead.
        chat(playerId, "Your legs have opinions of their own now. Watch your step, choom.")
        stumble(playerId)
    else
        playProfile(playerId, C.drunk.profile, C.drunk.profileDurationMs or 4000)
    end
end

-- One point sobers up per tick; the overlay is refreshed and the wasted stumble.
CreateThread(function()
    local tick = tonumber(C.drunk.tickMs) or 60000
    while true do
        Wait(tick)
        for playerId, level in pairs(drunk) do
            if not isConnected(playerId) then
                drunk[playerId] = nil
            else
                local newLevel = setDrunk(playerId, level - 1, "tick")
                if newLevel > C.drunk.screenAbove then applyWobble(playerId, newLevel) end
                if newLevel > C.drunk.stumbleAbove then
                    chat(playerId, "You stumble. Maybe a synth soda next, choom.")
                    stumble(playerId)
                elseif newLevel == 0 and level > 0 then
                    chat(playerId, "Sober again. The city is exactly as ugly as you left it.")
                end
            end
        end
    end
end)

AddEventHandler("rp_inventory:used", function(playerId, itemId)
    playerId = tonumber(playerId)
    if not playerId or not C.drinks[itemId] then return end
    onDrank(playerId, itemId)
end)

-- ---------------------------------------------------------------------------
-- The UI kit (server twins)
-- ---------------------------------------------------------------------------

local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Registers a sub-menu without showing it. Only a refused dispatch or an explicit
-- transport error counts as a failure: the register-only twin's own answer shape is
-- not documented, so a quiet resolution is taken as success.
local function registerMenu(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "context", playerId, definition, { show = false })
    if not promise then return nil, reason end
    local answer, err = promise:await()
    if answer == nil and err ~= nil then return nil, err end
    return true
end

local function showMenu(playerId, definition, timeoutMs)
    return uikit("context", playerId, definition, { timeoutMs = timeoutMs or 60000 })
end

-- ---------------------------------------------------------------------------
-- Mixing and restocking
-- ---------------------------------------------------------------------------

local function recipeText(drinkId)
    local parts = {}
    for _, ingredientId in ipairs(ingredientList()) do
        local units = C.drinks[drinkId].recipe and C.drinks[drinkId].recipe[ingredientId]
        if units and units > 0 then parts[#parts + 1] = ("%d x %s"):format(units, labelOf(ingredientId)) end
    end
    return table.concat(parts, ", ")
end

local function missingIngredients(playerId, drinkId)
    local missing = {}
    for ingredientId, units in pairs(C.drinks[drinkId].recipe or {}) do
        local have = pocketCount(playerId, ingredientId)
        if have < units then missing[#missing + 1] = ("%s (%d/%d)"):format(labelOf(ingredientId), have, units) end
    end
    return missing
end

local function craft(playerId, drinkId)
    local drink = C.drinks[drinkId]
    if not drink then chat(playerId, "That is not on the card."); return false end
    local missing = missingIngredients(playerId, drinkId)
    if #missing > 0 then
        chat(playerId, ("Missing for a %s: %s. Restock at the counter."):format(drink.label, table.concat(missing, ", ")))
        return false
    end

    -- Staged: the pose, the bottle in the hand and the bar, for C.craft.durationMs.
    local answer, reason = stage(playerId, "mix", { label = ("Mixing a %s"):format(drink.label), durationMs = C.craft.durationMs or 4000 })
    if answer == nil then
        chat(playerId, ("The mixing bar never showed (%s). Nothing was used."):format(tostring(reason)))
        return false
    end
    if not answer.ok then
        chat(playerId, "You put the shaker down. Nothing was used.")
        return false
    end

    -- Four seconds is long enough for the pockets to have changed: re-check, then take.
    missing = missingIngredients(playerId, drinkId)
    if #missing > 0 then
        chat(playerId, ("The ingredients are gone: %s. Nothing was mixed."):format(table.concat(missing, ", ")))
        return false
    end
    local taken = {}
    for ingredientId, units in pairs(drink.recipe or {}) do
        local ok, err = pocketRemove(playerId, ingredientId, units)
        if not ok then
            -- Put back what was already taken and stop.
            for _, t in ipairs(taken) do pocketAdd(playerId, t.id, t.units) end
            chat(playerId, ("Could not take the %s (%s). Nothing was mixed."):format(labelOf(ingredientId), why(err)))
            return false
        end
        taken[#taken + 1] = { id = ingredientId, units = units }
    end
    local ok, err = pocketAdd(playerId, drinkId, 1)
    if not ok then
        for _, t in ipairs(taken) do pocketAdd(playerId, t.id, t.units) end
        chat(playerId, ("No room for the %s (%s). Ingredients returned."):format(drink.label, why(err)))
        return false
    end
    log("player %d mixed %s", playerId, drinkId)
    chat(playerId, ("%s ready. You now carry %d. Sells for %s."):format(drink.label, pocketCount(playerId, drinkId), money(drink.price)))
    toast(playerId, "success", "Afterlife", ("%s mixed."):format(drink.label))
    return true
end

local function restock(playerId, ingredientId)
    local ingredient = C.ingredients[ingredientId]
    if not ingredient then chat(playerId, "The supplier does not carry that."); return false end
    local cost = tonumber(ingredient.cost) or 0
    local balance, err = tillRemove(cost, "restock:" .. ingredientId)
    if balance == nil then
        if err == "insufficient_funds" then
            chat(playerId, ("The till is dry: %s costs %s, the till has %s."):format(ingredient.label, money(cost), money(tillBalance() or 0)))
        elseif err == "bank_offline" then
            chat(playerId, "The bank is offline, choom. No till, no restock.")
        else
            chat(playerId, ("The till refused (%s)."):format(why(err)))
        end
        return false
    end
    local ok, addErr = pocketAdd(playerId, ingredientId, 1)
    if not ok then
        tillAdd(cost, "restock_refund:" .. ingredientId)
        chat(playerId, ("No room for the %s (%s). The till was refunded."):format(ingredient.label, why(addErr)))
        return false
    end
    log("player %d restocked %s for %s till=%s", playerId, ingredientId, tostring(cost), tostring(balance))
    gesture(playerId, "restock")
    chat(playerId, ("Restocked 1 x %s for %s. Till: %s. You carry %d."):format(
        ingredient.label, money(cost), money(balance), pocketCount(playerId, ingredientId)))
    return true
end

-- ---------------------------------------------------------------------------
-- The counter menu
-- ---------------------------------------------------------------------------

local function buildRecipesMenu(playerId)
    local options = {}
    for _, drinkId in ipairs(drinkList()) do
        local drink = C.drinks[drinkId]
        local missing = missingIngredients(playerId, drinkId)
        options[#options + 1] = {
            id = drinkId,
            label = drink.label,
            description = recipeText(drinkId),
            disabled = #missing > 0,
            metadata = {
                { label = "Price", value = money(drink.price) },
                { label = "In pockets", value = tostring(pocketCount(playerId, drinkId)) },
                { label = "Missing", value = #missing > 0 and table.concat(missing, ", ") or "nothing" },
            },
        }
    end
    return { id = "rp_bar_recipes", title = "Recipes", description = "Ingredients come out of your pockets. 4 s each.", options = options }
end

local function buildRestockMenu(playerId, balance)
    local options = {}
    for _, ingredientId in ipairs(ingredientList()) do
        local ingredient = C.ingredients[ingredientId]
        options[#options + 1] = {
            id = ingredientId,
            label = ("%s - %s"):format(ingredient.label, money(ingredient.cost)),
            description = "Paid by the till, one unit per pick.",
            disabled = balance ~= nil and balance < (tonumber(ingredient.cost) or 0),
            metadata = {
                { label = "Cost", value = money(ingredient.cost) },
                { label = "In pockets", value = tostring(pocketCount(playerId, ingredientId)) },
            },
        }
    end
    return {
        id = "rp_bar_restock", title = "Restock",
        description = balance and ("Till: " .. money(balance)) or "The bank is offline.",
        options = options,
    }
end

local function buildCounterMenu(balance)
    return {
        id = "rp_bar_counter",
        title = "Afterlife - bar counter",
        description = balance and ("Till: " .. money(balance)) or "Till: bank offline",
        options = {
            { id = "recipes", label = "Recipes", icon = "R", description = "Mix a drink from your ingredients.", menu = "rp_bar_recipes" },
            { id = "restock", label = "Restock", icon = "S", description = "Buy ingredients with the till's money.", menu = "rp_bar_restock" },
            { id = "till", label = "Till", icon = "T", description = "Balance and today's sales.",
              metadata = { { label = "Balance", value = balance and money(balance) or "offline" } } },
            { id = "leave", label = "Leave the counter", icon = "X" },
        },
    }
end

local counterOpen = {}   -- playerId -> true while the counter loop runs

local function openCounter(playerId)
    if counterOpen[playerId] then return end
    if not itemsDefined then
        defineItems("late")
        if not itemsDefined then
            chat(playerId, "The pockets system (rp_inventory) is offline: nothing can be mixed or served.")
            return
        end
    end
    counterOpen[playerId] = true
    while true do
        local balance = tillBalance()
        local okRecipes, r1 = registerMenu(playerId, buildRecipesMenu(playerId))
        local okRestock, r2 = registerMenu(playerId, buildRestockMenu(playerId, balance))
        if not okRecipes or not okRestock then
            chat(playerId, ("The counter menu could not open (%s)."):format(tostring(r1 or r2)))
            break
        end
        local answer, reason = showMenu(playerId, buildCounterMenu(balance))
        if answer == nil then
            chat(playerId, ("The counter menu never answered (%s)."):format(tostring(reason)))
            break
        end
        if not answer.ok then break end   -- Escape, back at the root, or timeout
        local pick = answer.value or {}
        if pick.menu == "rp_bar_recipes" then
            if not requireBarman(playerId) or not requireAtCounter(playerId) then break end
            craft(playerId, pick.id)
        elseif pick.menu == "rp_bar_restock" then
            if not requireBarman(playerId) or not requireAtCounter(playerId) then break end
            restock(playerId, pick.id)
        elseif pick.id == "till" then
            local line = balance and ("Till: %s."):format(money(balance)) or "Till: the bank is offline."
            local n, total = todaySales()
            if n then
                line = line .. (" Today: %d drink(s) sold for %s."):format(n, money(total))
            else
                line = line .. (" This session: %d drink(s) sold for %s."):format(sessionSales, money(sessionRevenue))
            end
            chat(playerId, line)
        else
            break
        end
    end
    counterOpen[playerId] = nil
end

-- The E prompt at the counter.
RegisterNetEvent("rp_bar:counter", function()
    local playerId = source
    if not requireBarman(playerId) then return end
    if not requireAtCounter(playerId) then return end
    openCounter(playerId)
end)

-- ---------------------------------------------------------------------------
-- Serving a customer (ALT+click, /servir)
-- ---------------------------------------------------------------------------

local pendingSales = {}   -- interactionId -> sale
local saleOfBarman = {}   -- barmanId -> interactionId (one offer at a time)

local function tellBoth(sale, barmanText, customerText)
    if barmanText ~= "" and isConnected(sale.barman) then chat(sale.barman, barmanText) end
    if customerText ~= "" and isConnected(sale.customer) then chat(sale.customer, customerText) end
end

-- The transaction, run once the customer consented: cash, till, tip, the glass.
-- The bottle shown in the bartender's hand from the offer to the hand-over (Stage.serve).
local serveHold = {}   -- barman -> stage entry

local function releaseServe(barman)
    if serveHold[barman] then stageRelease(barman, serveHold[barman]); serveHold[barman] = nil end
end

local function settleSale(sale, how)
    releaseServe(sale.barman)
    local drink = C.drinks[sale.drink]
    local barman, customer, price = sale.barman, sale.customer, sale.price
    if not isConnected(barman) or not isConnected(customer) then
        log("sale dropped: a party left (barman %s, customer %s)", tostring(barman), tostring(customer))
        return false
    end
    if not pocketHas(barman, sale.drink, 1) then
        tellBoth(sale, ("The %s is not in your pockets any more. No sale."):format(drink.label),
            ("The bartender lost your %s somewhere. No charge."):format(drink.label))
        return false
    end
    local newCash, err = cashRemove(customer, price, "bar:" .. sale.drink)
    if newCash == nil then
        if err == "insufficient_funds" then
            tellBoth(sale, ("%s cannot pay %s. No eddies, no drink."):format(playerName(customer), money(price)),
                ("You are short: a %s is %s. No eddies, no drink."):format(drink.label, money(price)))
        else
            tellBoth(sale, ("The payment failed (%s). No sale."):format(why(err)),
                ("The payment failed (%s). No charge."):format(why(err)))
        end
        return false
    end
    local ok, removeErr = pocketRemove(barman, sale.drink, 1)
    if not ok then
        cashAdd(customer, price, "bar:refund")
        tellBoth(sale, ("Could not hand the %s over (%s). Refunded."):format(drink.label, why(removeErr)),
            "The hand-over failed. You were refunded.")
        return false
    end
    ok, err = pocketAdd(customer, sale.drink, 1)
    if not ok then
        pocketAdd(barman, sale.drink, 1)
        cashAdd(customer, price, "bar:refund")
        tellBoth(sale, ("%s cannot carry the %s (%s). Refunded."):format(playerName(customer), drink.label, why(err)),
            ("You cannot carry the %s (%s). Refunded."):format(drink.label, why(err)))
        return false
    end

    local tillShare = math.floor(price * (tonumber(C.sale.tillShare) or 0.7))
    local tip = price - tillShare
    local tillNow = tillAdd(tillShare, "sale:" .. sale.drink)
    if tillNow == nil then
        -- The bank is not there to take its share: the eddies stay on the counter, in the
        -- barman's hand, rather than vanishing.
        tip = price
        chat(barman, "The bank is offline: the whole price goes to your pocket for now.")
    end
    local tipBalance = cashAdd(barman, tip, "bar:tip")
    recordSale(barman, customer, sale.drink, price)
    log("sale %s: %s -> %s for %s (till +%s, tip +%s, via %s)", sale.drink, tostring(barman), tostring(customer),
        tostring(price), tostring(tillNow and tillShare or 0), tostring(tip), how)
    chat(barman, ("Served a %s to %s for %s. Tip: %s%s%s."):format(
        drink.label, playerName(customer), money(price), money(tip),
        tipBalance and (" (cash " .. money(tipBalance) .. ")") or "",
        tillNow and (". Till: " .. money(tillNow)) or ""))
    chat(customer, ("%s slides you a %s. -%s. /use %s to drink it."):format(
        playerName(barman), drink.label, money(price), sale.drink))
    toast(customer, "success", "Afterlife", ("%s bought for %s."):format(drink.label, money(price)))
    gesture(customer, "sip")
    toast(barman, "success", "Afterlife", ("Sold: %s. Tip %s."):format(drink.label, money(tip)))
    return true
end

-- No interaction service: the customer answers a UI-kit dialog with the price instead.
local function offerWithDialog(sale)
    local drink = C.drinks[sale.drink]
    local answer, reason = uikit("alert", sale.customer, {
        title = "Afterlife",
        message = ("%s offers you a %s for %s. %s"):format(playerName(sale.barman), drink.label, money(sale.price), drink.flavour or ""),
        confirm = ("Pay %s"):format(money(sale.price)),
        cancel = "No thanks",
        timeoutMs = C.sale.inviteTimeoutMs or 20000,
    })
    saleOfBarman[sale.barman] = nil
    releaseServe(sale.barman)
    if answer == nil then
        tellBoth(sale, ("%s never answered (%s)."):format(playerName(sale.customer), tostring(reason)), "")
        return false
    end
    if not answer.ok then
        tellBoth(sale, ("%s passed on the %s."):format(playerName(sale.customer), drink.label),
            ("You pass on the %s."):format(drink.label))
        return false
    end
    -- The dialog is the consent; the give kind then runs without a second invitation.
    local state = Open77.playerInteractions.request(sale.barman, sale.customer, "give", {
        durationMs = C.sale.durationMs or 4000, consent = false,
        startDistance = C.sale.distance or 3.0, breakDistance = C.sale.breakDistance or 5.0,
    })
    if state and state.id then
        pendingSales[state.id] = sale
        saleOfBarman[sale.barman] = state.id
        serveHold[sale.barman] = stageHold(sale.barman, "serve")
        return true
    end
    return settleSale(sale, "dialog")
end

local function startSale(barman, customer, drinkId)
    local drink = C.drinks[drinkId]
    if not drink then chat(barman, "That is not on the card."); return false end
    if barman == customer then
        chat(barman, "You cannot serve yourself, choom. Pour one and /use it.")
        return false
    end
    if not isConnected(customer) then chat(barman, "No such customer in the bar."); return false end
    if saleOfBarman[barman] then chat(barman, "Finish the drink you are already serving."); return false end
    if not pocketHas(barman, drinkId, 1) then
        chat(barman, ("You have no %s in your pockets. Mix one at the counter first."):format(drink.label))
        return false
    end
    local metres, reason = Open77.players.distance(barman, customer)
    if not metres then chat(barman, ("Cannot place the customer (%s)."):format(tostring(reason))); return false end
    if metres > (C.sale.distance or 3.0) then
        chat(barman, ("%s is %.1f m away. Get within %.0f m to serve."):format(playerName(customer), metres, C.sale.distance or 3.0))
        return false
    end
    local busy = Open77.playerInteractions.current(customer)
    if busy then chat(barman, ("%s is busy with someone else."):format(playerName(customer))); return false end

    local sale = { barman = barman, customer = customer, drink = drinkId, price = tonumber(drink.price) or 0, at = Open77.time.unix() }
    chat(customer, ("%s offers you a %s for %s. Accept the offer to pay (or /interaction accept), decline to pass."):format(
        playerName(barman), drink.label, money(sale.price)))
    toast(customer, "info", "Afterlife", ("%s for %s? Accept the offer to pay."):format(drink.label, money(sale.price)))

    local state, err = Open77.playerInteractions.request(barman, customer, "give", {
        durationMs = C.sale.durationMs or 4000,
        consent = true,
        inviteTimeoutMs = C.sale.inviteTimeoutMs or 20000,
        startDistance = C.sale.distance or 3.0,
        breakDistance = C.sale.breakDistance or 5.0,
    })
    if not state then
        if err == "interactions_unavailable" then
            saleOfBarman[barman] = "dialog"
            chat(barman, "No hand-over service on this server: asking the customer with a dialog instead.")
            return offerWithDialog(sale)
        end
        local text = {
            too_far = "the customer is too far",
            player_reserved = "the customer is busy",
            player_in_vehicle = "nobody serves through a car window",
            player_not_alive = "the customer is down",
            animation_busy = "one of you is busy with an animation",
            player_not_ready = "the customer is not in the world yet",
            wrong_bucket = "the customer is in another instance",
        }
        chat(barman, ("Cannot serve: %s."):format(text[err] or tostring(err)))
        return false
    end
    pendingSales[state.id] = sale
    saleOfBarman[barman] = state.id
    serveHold[barman] = stageHold(barman, "serve")
    log("offer %s: %d -> %d for %s (interaction %s)", drinkId, barman, customer, tostring(sale.price), tostring(state.id))
    chat(barman, ("Offer sent: %s for %s. Waiting for %s to accept."):format(drink.label, money(sale.price), playerName(customer)))
    return true
end

AddEventHandler("onPlayerInteractionCompleted", function(state)
    if type(state) ~= "table" then return end
    local sale = pendingSales[state.id]
    pendingSales[state.id] = nil
    if not sale then return end
    saleOfBarman[sale.barman] = nil
    settleSale(sale, "interaction")
end)

AddEventHandler("onPlayerInteractionCancelled", function(state)
    if type(state) ~= "table" then return end
    local sale = pendingSales[state.id]
    pendingSales[state.id] = nil
    if not sale then return end
    saleOfBarman[sale.barman] = nil
    releaseServe(sale.barman)
    local drink = C.drinks[sale.drink]
    local reason = tostring(state.reason or "cancelled")
    if reason == "declined" or reason == "rejected" then
        tellBoth(sale, ("%s passed on the %s."):format(playerName(sale.customer), drink.label),
            ("You pass on the %s."):format(drink.label))
    elseif reason == "timeout" or reason == "invite_timeout" then
        tellBoth(sale, ("%s never answered. Offer withdrawn."):format(playerName(sale.customer)),
            ("The %s offer expired."):format(drink.label))
    else
        tellBoth(sale, ("The hand-over was cancelled (%s). No sale."):format(reason),
            ("The hand-over was cancelled (%s). No charge."):format(reason))
    end
    log("offer cancelled (%s) barman %s customer %s", reason, tostring(sale.barman), tostring(sale.customer))
end)

-- ALT+click > Serve a drink: the barman picks which drink from a menu.
RegisterNetEvent("rp_bar:serve", function(targetId)
    local barman = source
    -- Only a positive integer may reach Open77.players.* (a float like 1e300 passes `% 1 == 0`).
    targetId = math.tointeger(tonumber(targetId))
    if not requireBarman(barman) then return end
    if not targetId or targetId < 1 then chat(barman, "No customer selected."); return end
    if targetId == barman then chat(barman, "You cannot serve yourself, choom. Pour one and /use it."); return end
    if not isConnected(targetId) then chat(barman, "That customer is gone."); return end
    if saleOfBarman[barman] then chat(barman, "Finish the drink you are already serving."); return end

    local options = {}
    for _, drinkId in ipairs(drinkList()) do
        local count = pocketCount(barman, drinkId)
        if count > 0 then
            options[#options + 1] = {
                id = drinkId,
                label = ("%s x%d - %s"):format(C.drinks[drinkId].label, count, money(C.drinks[drinkId].price)),
                description = C.drinks[drinkId].flavour,
            }
        end
    end
    if #options == 0 then chat(barman, "Nothing to serve: your pockets are empty. Mix something at the counter."); return end
    local answer, reason = showMenu(barman, {
        id = "rp_bar_serve", title = ("Serve %s"):format(playerName(targetId)),
        description = "They pay in cash; 70 % to the till, 30 % is your tip.", options = options,
    }, 30000)
    if answer == nil then chat(barman, ("The serve menu never answered (%s)."):format(tostring(reason))); return end
    if not answer.ok then return end
    startSale(barman, targetId, answer.value and answer.value.id)
end)

-- Fallback: /servir <playerId> <drink>
RegisterCommand("servir", function(source, args)
    if source == 0 then print("servir: run this from the game, not the console"); return end
    if not requireBarman(source) then return end
    local target = math.tointeger(tonumber(args[1]))
    if not target or target < 1 or not args[2] then
        chat(source, "Usage: /servir <playerId> <drink> - drinks: " .. table.concat(drinkList(), ", "))
        return
    end
    local drinkId, err = resolveDrink(args[2])
    if not drinkId then
        chat(source, ("Unknown drink '%s' (%s). On the card: %s."):format(tostring(args[2]), tostring(err), table.concat(drinkList(), ", ")))
        return
    end
    startSale(source, target, drinkId)
end, false)

-- ---------------------------------------------------------------------------
-- /bar
-- ---------------------------------------------------------------------------

local function sendLines(playerId, lines)
    for _, line in ipairs(lines) do
        chat(playerId, line)
        Wait(0)
    end
end

local function cardLines(playerId)
    local lines = { "Afterlife - on the card tonight:" }
    for _, drinkId in ipairs(drinkList()) do
        local drink = C.drinks[drinkId]
        local buzz = (tonumber(drink.alcohol) or 0) > 0 and (" (buzz +%d)"):format(drink.alcohol) or " (no buzz)"
        lines[#lines + 1] = ("  %s - %s%s"):format(drink.label, money(drink.price), buzz)
    end
    lines[#lines + 1] = "Ask the bartender (ALT+click you > Serve a drink), then /use <drink>."
    lines[#lines + 1] = drunkLine(drunk[playerId] or 0)
    return lines
end

RegisterCommand("bar", function(source)
    if source == 0 then print("bar: run this from the game, not the console"); return end
    local onDuty, reason = barmanOnDuty(source)
    if not onDuty then
        local lines = cardLines(source)
        if reason == "off_duty" then lines[#lines + 1] = "You are the staff here: /service to clock in, then /bar again for the counter." end
        sendLines(source, lines)
        return
    end
    local balance = tillBalance()
    local stock = {}
    for _, ingredientId in ipairs(ingredientList()) do
        stock[#stock + 1] = ("%s x%d"):format(labelOf(ingredientId), pocketCount(source, ingredientId))
    end
    local drinks = {}
    for _, drinkId in ipairs(drinkList()) do
        drinks[#drinks + 1] = ("%s x%d"):format(labelOf(drinkId), pocketCount(source, drinkId))
    end
    sendLines(source, {
        ("Till: %s. Session sales: %d for %s."):format(balance and money(balance) or "bank offline", sessionSales, money(sessionRevenue)),
        "Stock: " .. table.concat(stock, ", "),
        "Drinks: " .. table.concat(drinks, ", "),
        drunkLine(drunk[source] or 0),
    })
    if not requireAtCounter(source) then return end
    openCounter(source)
end, false)

local SUGGESTIONS = {
    { command = "/bar", help = "The Afterlife: the card and prices; the counter (recipes, restock, till) for the barman on duty" },
    { command = "/servir", help = "Barman: serve a drink from your pockets to a customer, who pays on acceptance",
      parameters = { { name = "playerId", help = "The customer's session id (/players)" }, { name = "drink", help = "beer, whisky, johnny_silverhand, synth_soda" } } },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

-- ---------------------------------------------------------------------------
-- Ambience at the counter
-- ---------------------------------------------------------------------------

local hearing = {}   -- playerId -> true while the loop plays on that client

local function ambienceStart(playerId)
    local ok, reason = Open77.sound.play(playerId, C.ambience.file, {
        id = C.ambience.id, loop = true, volume = C.ambience.volume or 0.5,
        position = C.counter.position,
        maxDistance = C.ambience.maxDistance or 32.0, refDistance = C.ambience.refDistance or 4.0,
    })
    if not ok then
        log("ambience refused for player %d: %s", playerId, tostring(reason))
        return false
    end
    hearing[playerId] = true
    return true
end

local function ambienceStop(playerId)
    hearing[playerId] = nil
    if isConnected(playerId) then Open77.sound.stop(playerId, C.ambience.id) end
end

CreateThread(function()
    if not C.ambience or not C.ambience.file then return end
    local sweep = tonumber(C.ambience.sweepMs) or 5000
    while true do
        Wait(sweep)
        local near = Open77.players.nearby(C.counter.position, C.ambience.stopRadius or 34.0) or {}
        local inside = {}
        for _, entry in ipairs(near) do
            local id = entry.playerId
            if entry.distance <= (C.ambience.radius or 30.0) or hearing[id] then inside[id] = true end
            if inside[id] and not hearing[id] then ambienceStart(id) end
        end
        for id in pairs(hearing) do
            if not inside[id] then ambienceStop(id) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Duty synchronisation with the clients
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_bar:clientReady", function()
    pushDuty(source)
end)

AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    playerId = tonumber(playerId)
    if not playerId then return end
    if jobName == C.job then
        TriggerClientEvent("rp_bar:duty", playerId, onDuty == true)
        if onDuty == true then
            chat(playerId, ("Behind the counter. The ring is at %.0f, %.0f: press E there or /bar."):format(
                C.counter.position.x, C.counter.position.y))
        end
    end
end)

AddEventHandler("rp_jobs:changed", function(playerId)
    playerId = tonumber(playerId)
    if playerId and isConnected(playerId) then pushDuty(playerId) end
end)

-- ---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
-- ---------------------------------------------------------------------------

exports("getDrunk", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return nil, "invalid_player_id" end
    return drunk[playerId] or 0
end)

exports("addDrunk", function(playerId, amount)
    playerId = tonumber(playerId)
    amount = tonumber(amount)
    if not playerId or not isConnected(playerId) then return nil, "player_not_found" end
    if not amount then return nil, "invalid_amount" end
    local level = setDrunk(playerId, (drunk[playerId] or 0) + amount, "export addDrunk")
    if level > C.drunk.screenAbove then applyWobble(playerId, level) end
    return level
end)

exports("card", function()
    local card = {}
    for _, drinkId in ipairs(drinkList()) do
        local drink = C.drinks[drinkId]
        card[#card + 1] = { id = drinkId, label = drink.label, price = drink.price, alcohol = drink.alcohol or 0 }
    end
    return card
end)

exports("isBarmanOnDuty", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return false end
    return barmanOnDuty(playerId) == true
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Decoration: the props of RpBarConfig.props, created at start and removed at stop.
-- A refused prop only logs: the counter works without it.
local propIds = {}

local function spawnProps()
    for i, def in ipairs(C.props or {}) do
        local id, reason = Open77.props.create({
            model = def.model,
            position = { x = def.position.x, y = def.position.y, z = def.position.z },
            yaw = def.yaw or 0.0,
            bucket = 0,
        })
        if id then
            propIds[#propIds + 1] = id
        else
            log("prop %d (%s) not spawned: %s", i, tostring(def.model), tostring(reason))
        end
    end
    if #propIds > 0 then log("props spawned: %d", #propIds) end
end

local function removeProps()
    for _, id in ipairs(propIds) do Open77.props.remove(id) end
    propIds = {}
end

AddEventHandler("onResourceStart", function(name)
    if name == RESOURCE then
        defineItems("start")
        setupStore()
        spawnProps()
        Open77.chat.addSuggestions(-1, SUGGESTIONS)
        for _, playerId in ipairs(Open77.players.all()) do pushDuty(playerId) end
        log("started: counter at %.1f %.1f %.1f (reach %s m), %d drinks, %d ingredients, society '%s', ambience %s",
            C.counter.position.x, C.counter.position.y, C.counter.position.z, tostring(C.counter.reach),
            #drinkList(), #ingredientList(), C.society, C.ambience.file and "on" or "off")
    elseif name == "rp_inventory" then
        -- Its VM came back with the built-in items only: declare ours again.
        defineItems("rp_inventory restarted")
    elseif name == "rp_jobs" then
        for _, playerId in ipairs(Open77.players.all()) do pushDuty(playerId) end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    drunk[playerId] = nil
    hearing[playerId] = nil
    counterOpen[playerId] = nil
    saleOfBarman[playerId] = nil
    serveHold[playerId] = nil
    stageClear(playerId)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    for playerId in pairs(hearing) do
        if isConnected(playerId) then Open77.sound.stop(playerId, C.ambience.id) end
    end
    removeProps()
    log("stopped: %d sale(s) this session for %s", sessionSales, tostring(sessionRevenue))
end)
