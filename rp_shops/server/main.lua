-- rp_shops v2: shops in the world, each with a talking vendor.
--
-- /boutiques                  every shop with its distance from you
-- /boutiques <shopId>         a shop's catalogue (and stock) in chat
-- /boutiques restock <shopId> society boss: refill the shelves, paid from the society
-- /acheter <item> [count]     buy without the menu, within reach of a vendor
--
-- The server decides everything: prices, opening hours, the gun licence, the
-- payment (cash first, then the bank account), the delivery (rp_inventory,
-- open77_weapons, the wardrobe), the society share and the stock. The client
-- only draws the ring + E prompt on each vendor and forwards the press.
--
-- Persistence: SQL first (rp_shops_stock, rp_shops_sales, rp_shops_licences),
-- Open77.kvp only when the server has no database. Exports never yield: the
-- caches below are written through with the callback forms.

local RESOURCE = GetCurrentResourceName()
local LOG = "[" .. RESOURCE .. "]"
local Config = RpShopsConfig

local shops = {}          -- shopId -> shop (config entry + npcId at runtime)
local shopOrder = {}      -- shops in config order
local byNpc = {}          -- tostring(npcId) -> shopId
local stock = {}          -- shopId -> { itemId -> count } (society shops only)
local licences = {}       -- identifier -> true | false once loaded
local robbedAt = {}       -- shopId -> Open77.time.monotonic() of the last robbery
local pendingWeapons = {} -- requestId (string) -> { playerId, shop, item, price, paidWith }
local busy = {}           -- playerId -> true while a shop dialog is open
local store = nil         -- "sql" | "kvp" once decided
local warnedClock = false

local LICENCE_ID = "licence" -- pseudo item of the gun shop (/acheter licence)
local STORE_WAIT_MS = 15000  -- how long to wait for a connecting database

local SUGGESTIONS = {
    { command = "/boutiques", help = "The shops around you, with distances; /boutiques <shopId> for a catalogue",
      parameters = { { name = "shopId | restock <shopId>", help = "supermarket, pharmacy, gunshop, clothes, blackmarket" } } },
    { command = "/acheter", help = "Buy from the vendor you are standing next to (within 3 m)",
      parameters = { { name = "item", help = "water, burrito, bandage, pistol, licence..." }, { name = "count", help = "1 by default" } } },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function say(playerId, text)
    local ok, reason = Open77.chat.send(playerId, text)
    if not ok then
        print(LOG .. " chat.send refused for player " .. tostring(playerId) .. ": " .. tostring(reason))
    end
end

local function eddies(amount)
    return tostring(math.floor(tonumber(amount) or 0)) .. " €$"
end

local function identifierOf(playerId)
    local identifier = Open77.players.identifier(playerId)
    if identifier == nil or identifier == "" then
        return nil
    end
    return tostring(identifier)
end

local function playerName(playerId)
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

-- A synchronous cross-resource export, wrapped: raises when the resource is
-- missing. Returns ok (the call reached the export), then its values.
local function callExport(resource, name, ...)
    local args = table.pack(...)
    return pcall(function()
        local proxy = exports[resource]
        return proxy[name](proxy, table.unpack(args, 1, args.n))
    end)
end

local function planarDistance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Fresh position of a player, or nil, reason.
local function positionOf(playerId)
    local me, reason = Open77.players.get(playerId)
    if not me then
        return nil, reason or "player_not_found"
    end
    if not me.position or (me.ageMs or 0) > Config.positionMaxAgeMs then
        return nil, "position_stale"
    end
    return me.position
end

-- Refuses the console and dead players; returns true when the caller may trade.
local function canTrade(playerId)
    if playerId == 0 then
        print(LOG .. " this command runs from the game, not from the console")
        return false
    end
    local dead, reason = Open77.players.isDead(playerId)
    if dead == nil then
        say(playerId, "Can't check your state (" .. tostring(reason or "unknown") .. "), try again in a moment.")
        return false
    end
    if dead then
        say(playerId, "You're flatlined, choom. Vendors don't serve corpses.")
        return false
    end
    return true
end

-- Is the player within reach of that shop's vendor? Returns true, or false, reason, distance.
local function withinReach(playerId, shop, reach)
    local pos, reason = positionOf(playerId)
    if not pos then
        return false, reason
    end
    local distance = planarDistance(pos, shop.position)
    if distance > (reach or Config.reach) then
        return false, "too_far", distance
    end
    return true, nil, distance
end

local function nearestShop(playerId, reach)
    local pos = positionOf(playerId)
    if not pos then
        return nil
    end
    local best, bestDistance
    for _, shop in ipairs(shopOrder) do
        local distance = planarDistance(pos, shop.position)
        if distance <= (reach or Config.reach) and (not best or distance < bestDistance) then
            best, bestDistance = shop, distance
        end
    end
    return best, bestDistance
end

local function findItem(shop, wanted)
    wanted = string.lower(wanted or "")
    if wanted == "" then
        return nil
    end
    for _, item in ipairs(shop.catalogue) do
        if item.id == wanted then
            return item
        end
    end
    local match
    for _, item in ipairs(shop.catalogue) do
        local label = string.lower(item.label)
        if label:sub(1, #wanted) == wanted or item.id:sub(1, #wanted) == wanted then
            if match then
                return nil, "ambiguous"
            end
            match = item
        end
    end
    return match
end

-- Server-world hour gate for the black market. Unknown clock = never closed (logged once).
local function blackmarketOpen()
    local bm = Config.blackmarket
    if bm.openHour == bm.closeHour then
        return true
    end
    local env, reason = Open77.environment.getState()
    if not env then
        if not warnedClock then
            print(LOG .. " no clock authority (" .. tostring(reason) .. "): the black market never closes")
            warnedClock = true
        end
        return true
    end
    local hour = tonumber(env.hour) or 0
    if bm.openHour > bm.closeHour then
        return hour >= bm.openHour or hour < bm.closeHour
    end
    return hour >= bm.openHour and hour < bm.closeHour
end

-- Stock and licences need the store; until the database has answered (or the
-- kvp fallback was chosen) a society shop and the gun shop cannot trade safely.
local function storeReadyFor(shop)
    return store ~= nil or not (shop.society or shop.kind == "weapons")
end

-- ---------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------

-- Takes `amount` from the player: cash first, then the bank account (withdrawn
-- to cash, then taken). Returns "cash" | "account", or nil, reason.
local function takePayment(playerId, amount, reason)
    local ok, balance, why = callExport("rp_economy", "remove", playerId, amount, reason)
    if not ok then
        return nil, "economy_offline"
    end
    if balance ~= nil then
        return "cash"
    end
    if why ~= "insufficient_funds" then
        return nil, tostring(why or "refused")
    end
    local okBank, newBalance, whyBank = callExport("rp_bank", "withdraw", playerId, amount)
    if not okBank then
        return nil, "insufficient_funds" -- no bank on this server: cash was the only option
    end
    if newBalance == nil then
        return nil, tostring(whyBank or "bank_refused")
    end
    local ok2, balance2, why2 = callExport("rp_economy", "remove", playerId, amount, reason)
    if ok2 and balance2 ~= nil then
        return "account"
    end
    callExport("rp_bank", "deposit", playerId, amount) -- put the withdrawal back
    return nil, tostring((ok2 and why2) or balance2 or "refused")
end

local function refund(playerId, amount, reason, why)
    local ok, balance, err = callExport("rp_economy", "add", playerId, amount, reason)
    if ok and balance ~= nil then
        say(playerId, ("Delivery failed (%s): %s refunded in cash."):format(tostring(why), eddies(amount)))
    else
        say(playerId, ("Delivery failed (%s) and the refund failed (%s): call an admin."):format(tostring(why), tostring(err or balance)))
        print(LOG .. " REFUND FAILED player " .. tostring(playerId) .. " amount " .. amount .. ": " .. tostring(err or balance))
    end
end

local function explainPayment(playerId, why, amount)
    if why == "insufficient_funds" then
        say(playerId, ("Not enough eddies: that's %s, cash or account."):format(eddies(amount)))
    elseif why == "economy_offline" then
        say(playerId, "Money system offline: nobody can pay right now.")
    else
        say(playerId, "Payment refused (" .. tostring(why) .. ").")
    end
end

local function creditSociety(shop, amount, reason)
    if not shop.society then
        return
    end
    local share = math.floor(amount * Config.societyShare)
    if share <= 0 then
        return
    end
    local ok, balance, why = callExport("rp_bank", "societyAdd", shop.society, share, reason)
    if ok and balance ~= nil then
        print(LOG .. (" society %s +%d (%s) balance=%s"):format(shop.society, share, reason, tostring(balance)))
    else
        print(LOG .. (" society %s credit of %d failed: %s"):format(shop.society, share, tostring(why or balance)))
    end
end

-- ---------------------------------------------------------------------------
-- Persistence: stock, licences, sales
-- ---------------------------------------------------------------------------

local function persistStock(shopId, itemId)
    local counts = stock[shopId]
    if not counts then
        return
    end
    if store == "sql" then
        Open77.database.update(
            "INSERT INTO rp_shops_stock (shop_id, item_id, count) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE count = VALUES(count)",
            { shopId, itemId, counts[itemId] or 0 },
            function(result)
                if result == nil then
                    print(LOG .. " stock write failed for " .. shopId .. "/" .. itemId)
                end
            end)
    else
        local ok, reason = Open77.kvp.set("stock:" .. shopId, json.encode(counts) or "{}")
        if not ok then
            print(LOG .. " kvp stock write failed for " .. shopId .. ": " .. tostring(reason))
        end
    end
end

-- Society shops start with `restockTo` of everything the first time (free opening stock).
local function seedStock(shop)
    stock[shop.id] = stock[shop.id] or {}
    for _, item in ipairs(shop.catalogue) do
        if stock[shop.id][item.id] == nil then
            stock[shop.id][item.id] = item.restockTo or shop.restockTo or 0
            persistStock(shop.id, item.id)
        end
    end
end

local function loadStockFromKvp()
    for _, shop in ipairs(shopOrder) do
        if shop.society then
            local raw = Open77.kvp.get("stock:" .. shop.id, nil)
            local counts = type(raw) == "string" and json.decode(raw) or nil
            stock[shop.id] = {}
            if type(counts) == "table" then
                for itemId, count in pairs(counts) do
                    stock[shop.id][itemId] = math.floor(tonumber(count) or 0)
                end
            end
            seedStock(shop)
        end
    end
end

local function persistLicence(identifier, name)
    if store == "sql" then
        Open77.database.update(
            "INSERT INTO rp_shops_licences (identifier, name, fee, created_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE fee = VALUES(fee)",
            { identifier, name, Config.gunLicenceFee, math.floor(Open77.time.unix()) },
            function(result)
                if result == nil then
                    print(LOG .. " licence write failed for " .. identifier)
                end
            end)
    else
        local ok, reason = Open77.kvp.set("licence:" .. identifier, true)
        if not ok then
            print(LOG .. " kvp licence write failed for " .. identifier .. ": " .. tostring(reason))
        end
    end
end

-- Yields (SQL): call it from a handler or a thread, never from an export.
local function ensureLicenceLoaded(identifier)
    if licences[identifier] ~= nil then
        return
    end
    if store == "sql" then
        local row = Open77.database.single.await("SELECT identifier FROM rp_shops_licences WHERE identifier = ?", { identifier })
        licences[identifier] = row ~= nil
    elseif store == "kvp" then
        licences[identifier] = Open77.kvp.get("licence:" .. identifier, false) == true
    end
end

local function logSale(shop, playerId, kind, itemId, count, price, paidWith)
    local identifier = identifierOf(playerId) or "?"
    local name = playerName(playerId)
    print(LOG .. (" sale shop=%s %s=%s x%d price=%d player %s (%s) paid=%s"):format(
        shop.id, kind, itemId, count, price, tostring(playerId), identifier, paidWith))
    if store == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_shops_sales (shop_id, kind, item_id, count, price, buyer, buyer_name, paid_with, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            { shop.id, kind, itemId, count, price, identifier, name, paidWith, math.floor(Open77.time.unix()) },
            function(id)
                if id == nil then
                    print(LOG .. " sales log write failed for " .. shop.id .. "/" .. itemId)
                end
            end)
    end
end

local function useKvp(reason)
    if store then
        return
    end
    store = "kvp"
    print(LOG .. " store=kvp reason=" .. tostring(reason) .. " (licences and stock in the resource kvp, no sales ledger)")
    loadStockFromKvp()
end

local function setupStore()
    local ok, reason = Open77.database.ready(function()
        if store == "kvp" then
            print(LOG .. " database came up late: staying on kvp for this boot")
            return
        end
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_shops_stock (
                shop_id VARCHAR(32) NOT NULL,
                item_id VARCHAR(48) NOT NULL,
                count   INT NOT NULL DEFAULT 0,
                PRIMARY KEY (shop_id, item_id)
            )
        ]])
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_shops_sales (
                id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                shop_id    VARCHAR(32) NOT NULL,
                kind       VARCHAR(16) NOT NULL,
                item_id    VARCHAR(48) NOT NULL,
                count      INT NOT NULL DEFAULT 1,
                price      INT NOT NULL DEFAULT 0,
                buyer      VARCHAR(64) NOT NULL,
                buyer_name VARCHAR(80) NOT NULL DEFAULT '',
                paid_with  VARCHAR(16) NOT NULL DEFAULT 'cash',
                created_at BIGINT NOT NULL DEFAULT 0,
                INDEX idx_rp_shops_sales_shop (shop_id),
                INDEX idx_rp_shops_sales_buyer (buyer)
            )
        ]])
        Open77.database.update.await([[
            CREATE TABLE IF NOT EXISTS rp_shops_licences (
                identifier VARCHAR(64) NOT NULL PRIMARY KEY,
                name       VARCHAR(80) NOT NULL DEFAULT '',
                fee        INT NOT NULL DEFAULT 0,
                created_at BIGINT NOT NULL DEFAULT 0
            )
        ]])
        store = "sql"
        local rows = Open77.database.query.await("SELECT shop_id, item_id, count FROM rp_shops_stock") or {}
        for _, row in ipairs(rows) do
            stock[row.shop_id] = stock[row.shop_id] or {}
            stock[row.shop_id][row.item_id] = math.floor(tonumber(row.count) or 0)
        end
        for _, shop in ipairs(shopOrder) do
            if shop.society then
                seedStock(shop)
            end
        end
        print(LOG .. " store=sql tables=rp_shops_stock,rp_shops_sales,rp_shops_licences stock rows=" .. #rows)
    end)
    if not ok then
        useKvp(reason)
        return
    end
    CreateThread(function()
        Wait(STORE_WAIT_MS)
        if not store then
            local ready, why = Open77.database.isReady()
            if not ready then
                useKvp(why or "database_not_answering")
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Vendors (NPCs)
-- ---------------------------------------------------------------------------

local stopping = false -- set on onResourceStop: a vendor removed by the stop is not respawned

local function spawnVendor(shop)
    if shop.npcId then return end
    local where = shop.vendorPosition or shop.position -- 1.2 m behind the ring, facing it
    local npcId, reason = Open77.npcs.create({
        record = (shop.vendor and shop.vendor.record) or Config.vendor.record,
        position = where,
        yaw = shop.yaw or 0.0,
        damagePolicy = 2, -- invulnerable: this build wants the numeric policy
        behavior = { combatEnabled = false },
        streamingRadius = Config.vendor.streamingRadius,
        persistent = false, -- gone with the resource, recreated on start
    })
    if npcId then
        shop.npcId = npcId
        byNpc[tostring(npcId)] = shop.id
        print(LOG .. (" vendor %s of %s spawned at %.1f %.1f %.1f (npc %s)"):format(
            shop.vendor and shop.vendor.name or "?", shop.id, where.x, where.y, where.z, tostring(npcId)))
    else
        print(LOG .. " vendor of " .. shop.id .. " not created: " .. tostring(reason))
    end
end

local function spawnVendors()
    for _, shop in ipairs(shopOrder) do
        spawnVendor(shop)
    end
end

local function removeVendors()
    for _, shop in ipairs(shopOrder) do
        if shop.npcId then
            Open77.npcs.remove(shop.npcId)
            byNpc[tostring(shop.npcId)] = nil
            shop.npcId = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Stall props: one real streamed prop per shop (shop.prop), next to the vendor.
-- A refused model only logs; the ring and the vendor still mark the stall.
-- ---------------------------------------------------------------------------

local function spawnProps()
    for _, shop in ipairs(shopOrder) do
        local prop = shop.prop
        if prop and not shop.propId then
            for _, model in ipairs(prop.models or {}) do
                local ok, id, reason = pcall(Open77.props.create, {
                    model = model,
                    position = { x = prop.position.x, y = prop.position.y, z = prop.position.z },
                    yaw = prop.yaw or shop.yaw or 0.0,
                    bucket = 0,
                    streamingRadius = 120.0,
                })
                if ok and id then
                    shop.propId = id
                    print(LOG .. (" prop %s of %s at %.1f %.1f %.1f (%s)"):format(
                        tostring(id), shop.id, prop.position.x, prop.position.y, prop.position.z, model))
                    break
                end
                print(LOG .. (" prop of %s refused (%s): %s"):format(shop.id, tostring(ok and reason or id), model))
            end
            if not shop.propId then print(LOG .. " no prop spawned for " .. shop.id .. ": the vendor alone marks the stall") end
        end
    end
end

local function removeProps()
    for _, shop in ipairs(shopOrder) do
        if shop.propId then
            pcall(Open77.props.remove, shop.propId)
            shop.propId = nil
        end
    end
end

local function vendorIsRobbed(shop)
    local at = robbedAt[shop.id]
    return at ~= nil and (Open77.time.monotonic() - at) * 1000 < Config.robHandsUpMs
end

local function vendorSpeak(shop, voice, options)
    if not shop.npcId then
        return
    end
    local ok, reason = Open77.npcs.speak(shop.npcId, voice, options)
    if not ok and reason ~= "npc_voice_busy" and reason ~= "npc_not_streamed" then
        print(LOG .. " vendor of " .. shop.id .. " stayed silent (" .. tostring(reason) .. ")")
    end
end

local function vendorGreets(shop, playerId)
    if not shop.npcId or vendorIsRobbed(shop) then
        return
    end
    pcall(function()
        Open77.npcs.tasks.lookAt(shop.npcId, playerId, { timeoutMs = 15000 })
    end)
    vendorSpeak(shop, Config.vendor.greeting)
end

-- ---------------------------------------------------------------------------
-- Gun licence
-- ---------------------------------------------------------------------------

local function isLicenceExempt(playerId)
    for _, job in ipairs(Config.gunLicenceExemptJobs) do
        local ok, has = callExport("rp_jobs", "hasJob", playerId, job)
        if ok and has == true then
            return true
        end
    end
    return false
end

-- NCPD veto: a wanted citizen, or one whose record carries a warrant, buys nothing.
local function ncpdClears(playerId)
    local ok, wanted = callExport("rp_ncpd", "wanted", playerId)
    if ok and type(wanted) == "table" then
        return false, ("NCPD has a warrant on you (level %s). No iron for you."):format(tostring(wanted.level or "?"))
    end
    local okRecord, record = callExport("rp_ncpd", "record", playerId)
    if okRecord and type(record) == "table" and record.warrant then
        return false, "Your NCPD record carries a warrant. Come back once it's lifted."
    end
    return true
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

local STAGE = RpShopsConfig.Stage or {}
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

-- The hand-over: the buyer's gesture with the bag (Config.Stage) and the vendor NPC playing
-- the same clip through Open77.npcs.tasks.workspot (a refusal only logs once).
local vendorWorkspotWarned = false
local function handOver(playerId, shop, key)
    local entry = gesture(playerId, key)
    local profile = Config.Stage and Config.Stage.vendorWorkspot
    if not profile or not shop.npcId or Config.Stage.enabled == false then return entry end
    local def = Config.Stage[key] or {}
    local ok, task, reason = pcall(Open77.npcs.tasks.workspot, shop.npcId, profile, { durationMs = def.durationMs or 2500 })
    if not ok then task, reason = nil, task end
    if not task and not vendorWorkspotWarned then
        vendorWorkspotWarned = true
        print(("%s vendor workspot %s refused: %s (the vendors stay still)"):format(LOG, profile, tostring(reason)))
    end
    return entry
end

local function buyLicence(playerId, shop)
    local identifier = identifierOf(playerId)
    if not identifier then
        say(playerId, "Identity not found: the licence needs a name on it.")
        return false
    end
    ensureLicenceLoaded(identifier)
    if licences[identifier] then
        say(playerId, "You already hold an NCPD gun licence.")
        return true
    end
    local clear, why = ncpdClears(playerId)
    if not clear then
        say(playerId, why)
        return false
    end
    local fee = Config.gunLicenceFee
    local reason = "gun_licence"
    local paidWith
    local ok, balance, err = callExport("rp_economy", "remove", playerId, fee, reason)
    if ok and balance ~= nil then
        paidWith = "cash"
        callExport("rp_bank", "societyAdd", Config.gunLicenceSociety, fee, reason)
    elseif ok and err == "insufficient_funds" then
        local okCharge, newBalance, whyCharge = callExport("rp_bank", "charge", playerId, fee, Config.gunLicenceSociety, reason)
        if okCharge and newBalance ~= nil then
            paidWith = "account"
        else
            explainPayment(playerId, (okCharge and whyCharge) or "insufficient_funds", fee)
            return false
        end
    else
        explainPayment(playerId, (ok and err) or "economy_offline", fee)
        return false
    end
    licences[identifier] = true
    persistLicence(identifier, playerName(playerId))
    logSale(shop, playerId, "licence", LICENCE_ID, 1, fee, paidWith)
    handOver(playerId, shop, "licence")
    TriggerEvent("rp_shops:sale", shop.id, playerId, LICENCE_ID, 1, fee)
    say(playerId, ("NCPD gun licence issued for %s (%s). Now pick your iron."):format(eddies(fee), paidWith))
    print(LOG .. (" licence issued to player %s (%s) paid=%s"):format(tostring(playerId), identifier, paidWith))
    return true
end

-- ---------------------------------------------------------------------------
-- Purchases
-- ---------------------------------------------------------------------------

-- Reasons rp_inventory:add can give, in the vendor's words.
local function explainInventory(playerId, why)
    if why == "too_heavy" then
        say(playerId, "Your pockets are full: drop something first.")
    elseif why == "unknown_item" then
        say(playerId, "That merch isn't stocked on this server (item unknown to rp_inventory).")
    elseif why == "not_loaded" then
        say(playerId, "Your pockets are still loading, try again in a moment.")
    elseif why == "inventory_offline" then
        say(playerId, "Pockets system offline: nothing can be handed over.")
    else
        say(playerId, "The vendor couldn't hand it over (" .. tostring(why) .. ").")
    end
end

-- Goods that go into the pockets (supermarket, pharmacy, black market).
-- `ctx.checkReach` is false when another resource opened the shop by export.
local function purchaseItem(playerId, shop, item, count, ctx)
    count = math.floor(tonumber(count) or 0)
    if count < 1 or count > Config.maxCountPerPurchase then
        say(playerId, ("Quantity must be 1 to %d."):format(Config.maxCountPerPurchase))
        return false
    end
    if not canTrade(playerId) then
        return false
    end
    if ctx.checkReach then
        local near, why = withinReach(playerId, shop)
        if not near then
            say(playerId, why == "too_far" and "Step back to the counter first." or ("Position unknown (" .. tostring(why) .. ")."))
            return false
        end
    end
    if shop.kind == "blackmarket" and not blackmarketOpen() then
        say(playerId, shop.closedLine or "Closed by day.")
        return false
    end
    if shop.society then
        local left = (stock[shop.id] or {})[item.id] or 0
        if left < count then
            if left <= 0 then
                say(playerId, ("%s is sold out. The %s boss can restock it."):format(item.label, shop.society))
            else
                say(playerId, ("Only %d x %s left on the shelf."):format(left, item.label))
            end
            return false
        end
    end
    local price = item.price * count
    local paidWith, why = takePayment(playerId, price, "shop:" .. shop.id .. ":" .. item.id)
    if not paidWith then
        explainPayment(playerId, why, price)
        return false
    end
    local ok, added, err = callExport("rp_inventory", "add", playerId, item.id, count)
    if not ok then
        refund(playerId, price, "refund:" .. shop.id .. ":" .. item.id, "inventory_offline")
        explainInventory(playerId, "inventory_offline")
        return false
    end
    if added ~= true then
        refund(playerId, price, "refund:" .. shop.id .. ":" .. item.id, tostring(err or "refused"))
        explainInventory(playerId, err)
        return false
    end
    if shop.society then
        stock[shop.id][item.id] = (stock[shop.id][item.id] or 0) - count
        persistStock(shop.id, item.id)
    end
    creditSociety(shop, price, "sale:" .. shop.id .. ":" .. item.id)
    logSale(shop, playerId, "item", item.id, count, price, paidWith)
    TriggerEvent("rp_shops:sale", shop.id, playerId, item.id, count, price)
    handOver(playerId, shop, "purchase")
    say(playerId, ("Bought %d x %s for %s (%s). It's in your pockets."):format(count, item.label, eddies(price), paidWith))
    return true
end

-- Weapons: licence, NCPD veto, payment, then the open77_weapons relay; the
-- money is already taken, the answer comes back on open77:weapons:completed.
local function purchaseWeapon(playerId, shop, item, ctx)
    if not canTrade(playerId) then
        return false
    end
    if ctx.checkReach then
        local near, why = withinReach(playerId, shop)
        if not near then
            say(playerId, why == "too_far" and "Step back to the counter first." or ("Position unknown (" .. tostring(why) .. ")."))
            return false
        end
    end
    local identifier = identifierOf(playerId)
    if not identifier then
        say(playerId, "Identity not found: every gun sale goes in the ledger with a name.")
        return false
    end
    if not isLicenceExempt(playerId) then
        ensureLicenceLoaded(identifier)
        if not licences[identifier] then
            say(playerId, ("No NCPD gun licence on file. Buy one here for %s (/acheter licence)."):format(eddies(Config.gunLicenceFee)))
            return false
        end
    end
    local clear, why = ncpdClears(playerId)
    if not clear then
        say(playerId, why)
        return false
    end
    local price = item.price
    local paidWith, whyPay = takePayment(playerId, price, "shop:" .. shop.id .. ":" .. item.id)
    if not paidWith then
        explainPayment(playerId, whyPay, price)
        return false
    end
    local requestId, reason = Open77.weapons.assign(playerId, item.record, item.slot, { active = true })
    if not requestId then
        refund(playerId, price, "refund:" .. shop.id .. ":" .. item.id, tostring(reason or "refused"))
        return false
    end
    local key = tostring(requestId)
    pendingWeapons[key] = { playerId = playerId, shop = shop, item = item, price = price, paidWith = paidWith }
    handOver(playerId, shop, "weapon")
    CreateThread(function()
        Wait(Config.weaponFallbackMs)
        local pending = pendingWeapons[key]
        if pending then
            pendingWeapons[key] = nil
            print(LOG .. " weapon request " .. key .. " never completed for player " .. tostring(playerId))
            refund(playerId, price, "refund:" .. shop.id .. ":" .. item.id, "no answer from the client")
        end
    end)
    say(playerId, ("%s for %s (%s), delivery in progress..."):format(item.label, eddies(price), paidWith))
    return true
end

AddEventHandler("open77:weapons:completed", function(playerId, requestId, operation, accepted, reason, result)
    local pending = pendingWeapons[tostring(requestId)]
    if not pending then
        return
    end
    pendingWeapons[tostring(requestId)] = nil
    local target = tonumber(playerId) or pending.playerId
    if accepted == true or accepted == "true" then
        local slot = (type(result) == "table" and result.slot) or pending.item.slot
        creditSociety(pending.shop, pending.price, "sale:" .. pending.shop.id .. ":" .. pending.item.id)
        logSale(pending.shop, target, "weapon", pending.item.id, 1, pending.price, pending.paidWith)
        TriggerEvent("rp_shops:sale", pending.shop.id, target, pending.item.id, 1, pending.price)
        say(target, ("Delivered: %s (slot %s). Keep it holstered around the NCPD."):format(pending.item.label, tostring(slot)))
    else
        refund(target, pending.price, "refund:" .. pending.shop.id .. ":" .. pending.item.id, tostring(reason or operation or "refused"))
    end
end)

-- Clothes: a flat styling fee, then the wardrobe opens on the customer's client.
local function purchaseStyling(playerId, shop, item, ctx)
    if not canTrade(playerId) then
        return false
    end
    if ctx.checkReach then
        local near, why = withinReach(playerId, shop)
        if not near then
            say(playerId, why == "too_far" and "Step back to the counter first." or ("Position unknown (" .. tostring(why) .. ")."))
            return false
        end
    end
    local price = item.price or Config.stylingFee
    local paidWith, why = takePayment(playerId, price, "shop:" .. shop.id .. ":" .. item.id)
    if not paidWith then
        explainPayment(playerId, why, price)
        return false
    end
    creditSociety(shop, price, "sale:" .. shop.id .. ":" .. item.id)
    logSale(shop, playerId, "service", item.id, 1, price, paidWith)
    TriggerEvent("rp_shops:sale", shop.id, playerId, item.id, 1, price)
    local sent, reason = TriggerClientEvent("rp_shops:wardrobe", playerId)
    if sent == false then
        print(LOG .. " wardrobe event not sent to player " .. tostring(playerId) .. ": " .. tostring(reason))
    end
    say(playerId, ("Styling fee %s (%s) paid. The racks are yours: if the wardrobe didn't pop, type /wardrobe."):format(eddies(price), paidWith))
    return true
end

-- One entry: the item the player named, the count, the shop; routes by kind.
local function purchase(playerId, shop, item, count, ctx)
    if shop.kind == "weapons" then
        if item.id == LICENCE_ID then
            return buyLicence(playerId, shop)
        end
        return purchaseWeapon(playerId, shop, item, ctx)
    elseif shop.kind == "clothes" then
        return purchaseStyling(playerId, shop, item, ctx)
    end
    return purchaseItem(playerId, shop, item, count, ctx)
end

-- ---------------------------------------------------------------------------
-- The menu (UI kit server twins)
-- ---------------------------------------------------------------------------

local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then
        return nil, reason
    end
    return promise:await()
end

local function buildOptions(playerId, shop, identifier)
    local options = {}
    if shop.kind == "weapons" and not isLicenceExempt(playerId) and identifier and not licences[identifier] then
        options[#options + 1] = {
            id = LICENCE_ID, label = "NCPD gun licence", icon = "ID",
            description = "Required before any sale. Clean record only.",
            metadata = { { label = "Fee", value = eddies(Config.gunLicenceFee) } },
        }
    end
    for _, item in ipairs(shop.catalogue) do
        local option = { id = item.id, label = item.label, metadata = { { label = "Price", value = eddies(item.price) } } }
        if shop.society then
            local left = (stock[shop.id] or {})[item.id] or 0
            option.description = left > 0 and (left .. " in stock") or "Sold out"
            if left <= 0 then
                option.disabled = true
            end
        elseif shop.kind == "weapons" then
            option.description = "Slot " .. tostring(item.slot)
        end
        options[#options + 1] = option
    end
    options[#options + 1] = { id = "leave", label = "Leave" }
    return options
end

-- Runs the whole dialog for one player; called inside a managed task.
local function runShop(playerId, shop, ctx)
    local identifier = identifierOf(playerId)
    if shop.kind == "weapons" and identifier then
        ensureLicenceLoaded(identifier)
    end
    for _ = 1, 8 do -- a few purchases per visit, then the menu closes
        local answer, reason = uikit("context", playerId, {
            id = "rp_shops_" .. shop.id,
            title = shop.label,
            description = ((shop.vendor and shop.vendor.name) or "Vendor") .. " - pick what you need, pay cash or account.",
            options = buildOptions(playerId, shop, identifier),
        }, { timeoutMs = 60000 })
        if answer == nil then
            if reason == "dialog_active" then
                say(playerId, "Close the other screen first, then talk to the vendor again.")
            else
                say(playerId, ("The shop screen didn't answer (%s). Use /acheter <item> [count] at the counter."):format(tostring(reason)))
            end
            return
        end
        if not answer.ok or type(answer.value) ~= "table" or answer.value.id == "leave" then
            return
        end
        local chosen = answer.value.id
        local item
        if chosen == LICENCE_ID then
            item = { id = LICENCE_ID, label = "NCPD gun licence", price = Config.gunLicenceFee }
        else
            item = findItem(shop, chosen)
        end
        if not item then
            return
        end
        local count = 1
        if shop.kind == "items" or shop.kind == "blackmarket" then
            local ask, why = uikit("input", playerId, {
                title = "How many " .. item.label .. "?",
                description = ("%s each. Cash first, then your account."):format(eddies(item.price)),
                fields = {
                    { id = "count", type = "number", label = "Quantity", min = 1, max = Config.maxCountPerPurchase, default = 1, required = true },
                },
                confirm = "Buy", cancel = "Back", timeoutMs = 60000,
            })
            if ask == nil then
                say(playerId, "The quantity screen didn't answer (" .. tostring(why) .. ").")
                return
            end
            if not ask.ok then
                count = nil -- back to the catalogue
            else
                count = tonumber(type(ask.value) == "table" and (ask.value.count or ask.value[1]) or ask.value) or 1
            end
        end
        if count then
            purchase(playerId, shop, item, count, ctx)
            if shop.kind ~= "items" and shop.kind ~= "blackmarket" then
                return -- a weapon or a styling session ends the visit
            end
        end
    end
end

-- Opens the shop for a player. `checkReach` is false only for the export.
local function openShopFor(playerId, shopId, checkReach)
    local shop = shops[shopId]
    if not shop then
        say(playerId, "Unknown shop. /boutiques lists them.")
        return false
    end
    if busy[playerId] then
        say(playerId, "One counter at a time, choom.")
        return false
    end
    if not canTrade(playerId) then
        return false
    end
    if checkReach then
        local near, why, distance = withinReach(playerId, shop)
        if not near then
            if why == "too_far" then
                say(playerId, ("%s is %.0f m away: walk up to the vendor."):format(shop.label, distance or 0))
            else
                say(playerId, "Position unknown (" .. tostring(why) .. "): move a bit and try again.")
            end
            return false
        end
    end
    if not storeReadyFor(shop) then
        say(playerId, "The shop's terminal is still booting (database connecting): try again in a few seconds.")
        return false
    end
    if shop.zone then
        local ok, inside = callExport("rp_zones", "isIn", playerId, shop.zone)
        if ok and inside == false then
            say(playerId, "Wrong alley. The dealer works inside the " .. shop.zone .. " zone.")
            return false
        end
    end
    if shop.kind == "blackmarket" and not blackmarketOpen() then
        vendorSpeak(shop, "rep_ask_to_leave")
        say(playerId, shop.closedLine or "Closed by day.")
        return false
    end
    if vendorIsRobbed(shop) then
        say(playerId, "The vendor still has their hands up. Give them a minute.")
        return false
    end
    vendorGreets(shop, playerId)
    if shop.welcome then
        say(playerId, shop.welcome)
    end
    busy[playerId] = true
    local ok, err = pcall(runShop, playerId, shop, { checkReach = checkReach })
    busy[playerId] = nil
    if not ok then
        print(LOG .. " shop dialog error for player " .. tostring(playerId) .. ": " .. tostring(err))
        say(playerId, "The vendor's terminal glitched. Try again or use /acheter.")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Net events (the E prompt on a vendor) and commands
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_shops:open", function(shopId)
    if type(source) ~= "number" or source == 0 then
        return
    end
    if type(shopId) ~= "string" then
        return
    end
    openShopFor(source, shopId, true)
end)

RegisterCommand("boutiques", function(source, args, raw)
    local sub = args[1] and string.lower(args[1]) or nil

    -- /boutiques restock <shopId>: the society boss (or the console) refills the shelves.
    if sub == "restock" then
        local shop = shops[args[2] and string.lower(args[2]) or ""]
        if not shop then
            if source == 0 then print(LOG .. " usage: boutiques restock <shopId>") else say(source, "Usage: /boutiques restock <shopId>") end
            return
        end
        if not shop.society then
            if source == 0 then print(LOG .. " " .. shop.id .. " is not a society shop") else say(source, shop.label .. " isn't player-run: its shelves never empty.") end
            return
        end
        if not store then
            if source == 0 then print(LOG .. " store not ready yet") else say(source, "The shop's terminal is still booting: try again in a few seconds.") end
            return
        end
        if source ~= 0 then
            local okJob, job = callExport("rp_jobs", "getJob", source)
            local okBoss, boss = callExport("rp_jobs", "isBoss", source)
            if not okJob or not okBoss then
                say(source, "Jobs system offline: nobody can restock right now.")
                return
            end
            if job ~= shop.society or boss ~= true then
                say(source, ("Only the %s boss restocks %s."):format(shop.society, shop.label))
                return
            end
        end
        local cost, units = 0, 0
        for _, item in ipairs(shop.catalogue) do
            local target = item.restockTo or shop.restockTo or 0
            local missing = target - ((stock[shop.id] or {})[item.id] or 0)
            if missing > 0 then
                units = units + missing
                cost = cost + math.floor(missing * item.price * Config.restockCostRatio)
            end
        end
        if units == 0 then
            if source == 0 then print(LOG .. " " .. shop.id .. " shelves are full") else say(source, shop.label .. " is fully stocked.") end
            return
        end
        if cost > 0 then
            local ok, balance, why = callExport("rp_bank", "societyRemove", shop.society, cost, "restock:" .. shop.id)
            if not ok then
                if source == 0 then print(LOG .. " rp_bank offline") else say(source, "Bank offline: the society can't pay the supplier.") end
                return
            end
            if balance == nil then
                local text = why == "insufficient_funds"
                    and ("The %s society can't cover the %s restock (%d units)."):format(shop.society, eddies(cost), units)
                    or ("Society payment refused (%s)."):format(tostring(why))
                if source == 0 then print(LOG .. " " .. text) else say(source, text) end
                return
            end
        end
        stock[shop.id] = stock[shop.id] or {}
        for _, item in ipairs(shop.catalogue) do
            local target = item.restockTo or shop.restockTo or 0
            if (stock[shop.id][item.id] or 0) < target then
                stock[shop.id][item.id] = target
                persistStock(shop.id, item.id)
            end
        end
        local text = ("%s restocked: %d units for %s from the %s society."):format(shop.label, units, eddies(cost), shop.society)
        print(LOG .. " " .. text .. " (by " .. tostring(source) .. ")")
        if source ~= 0 then
            say(source, text)
        end
        return
    end

    -- /boutiques <shopId>: one catalogue.
    if sub and shops[sub] then
        local shop = shops[sub]
        local lines = { ("=== %s (%s) === /acheter <item> [count] at the counter"):format(shop.label, shop.id) }
        if shop.kind == "weapons" then
            lines[#lines + 1] = ("  licence: NCPD gun licence - %s (once, clean record)"):format(eddies(Config.gunLicenceFee))
        end
        for _, item in ipairs(shop.catalogue) do
            local extra = ""
            if shop.society then
                extra = (" - stock %d"):format((stock[shop.id] or {})[item.id] or 0)
            end
            lines[#lines + 1] = ("  %s: %s - %s%s"):format(item.id, item.label, eddies(item.price), extra)
        end
        if shop.society then
            lines[#lines + 1] = ("Run by the %s society (%d%% of sales)."):format(shop.society, math.floor(Config.societyShare * 100))
        end
        if shop.kind == "blackmarket" then
            lines[#lines + 1] = blackmarketOpen() and "Open now (night hours)." or ("Closed until %02d:00."):format(Config.blackmarket.openHour)
        end
        for _, line in ipairs(lines) do
            if source == 0 then print(LOG .. " " .. line) else say(source, line) end
            Wait(0)
        end
        return
    end

    -- /boutiques: every shop with its distance.
    local pos = source ~= 0 and positionOf(source) or nil
    local lines = { "=== Shops === walk up to a vendor and press E, or /acheter at the counter" }
    for _, shop in ipairs(shopOrder) do
        local where = pos and ("%.0f m"):format(planarDistance(pos, shop.position)) or ("%.0f, %.0f"):format(shop.position.x, shop.position.y)
        local note = ""
        if shop.kind == "blackmarket" then
            note = blackmarketOpen() and " [open]" or (" [closed until %02d:00]"):format(Config.blackmarket.openHour)
        elseif shop.society then
            note = " [" .. shop.society .. "]"
        end
        lines[#lines + 1] = ("  %s (%s) - %s - %d lines%s"):format(shop.label, shop.id, where, #shop.catalogue, note)
    end
    for _, line in ipairs(lines) do
        if source == 0 then print(LOG .. " " .. line) else say(source, line) end
        Wait(0)
    end
end, false)

RegisterCommand("acheter", function(source, args, raw)
    if not canTrade(source) then
        return
    end
    local wanted = args[1] and string.lower(args[1]) or nil
    if not wanted then
        say(source, "Usage: /acheter <item> [count], within 3 m of a vendor. /boutiques <shopId> for the items.")
        return
    end
    local shop, distance = nearestShop(source)
    if not shop then
        say(source, "No vendor within 3 m. /boutiques lists them with distances.")
        return
    end
    if busy[source] then
        say(source, "Close the shop screen first.")
        return
    end
    local item, why
    if wanted == LICENCE_ID and shop.kind == "weapons" then
        item = { id = LICENCE_ID, label = "NCPD gun licence", price = Config.gunLicenceFee }
    else
        item, why = findItem(shop, wanted)
    end
    if not item then
        if why == "ambiguous" then
            say(source, "Several items match: be more specific.")
        else
            say(source, ("%s doesn't sell that. /boutiques %s for the catalogue."):format(shop.label, shop.id))
        end
        return
    end
    if not storeReadyFor(shop) then
        say(source, "The shop's terminal is still booting (database connecting): try again in a few seconds.")
        return
    end
    if shop.zone then
        local ok, inside = callExport("rp_zones", "isIn", source, shop.zone)
        if ok and inside == false then
            say(source, "Wrong alley. The dealer works inside the " .. shop.zone .. " zone.")
            return
        end
    end
    if shop.kind == "blackmarket" and not blackmarketOpen() then
        vendorSpeak(shop, "rep_ask_to_leave")
        say(source, shop.closedLine or "Closed by day.")
        return
    end
    if vendorIsRobbed(shop) then
        say(source, "The vendor still has their hands up. Give them a minute.")
        return
    end
    local count = tonumber(args[2] or "1")
    if not count then
        say(source, "The count must be a number.")
        return
    end
    busy[source] = true
    local ok, err = pcall(purchase, source, shop, item, count, { checkReach = true })
    busy[source] = nil
    if not ok then
        print(LOG .. " /acheter error for player " .. tostring(source) .. ": " .. tostring(err))
        say(source, "The vendor's terminal glitched. Try again.")
    end
end, false)

-- ---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
-- ---------------------------------------------------------------------------

exports("openShop", function(playerId, shopId)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then
        return nil, "invalid_player"
    end
    if type(shopId) ~= "string" or not shops[shopId] then
        return nil, "unknown_shop"
    end
    CreateThread(function()
        openShopFor(playerId, shopId, false)
    end)
    return true
end)

exports("stock", function(shopId)
    local shop = type(shopId) == "string" and shops[shopId] or nil
    if not shop then
        return nil, "unknown_shop"
    end
    local rows = {}
    for _, item in ipairs(shop.catalogue) do
        rows[#rows + 1] = {
            itemId = item.id,
            price = item.price,
            count = shop.society and ((stock[shop.id] or {})[item.id] or 0) or -1, -- -1 = unlimited
        }
    end
    return rows
end)

-- rp_crime calls this: the vendor raises hands and hands over the register.
exports("rob", function(shopId, byPlayerId)
    local shop = type(shopId) == "string" and shops[shopId] or nil
    if not shop then
        return nil, "unknown_shop"
    end
    byPlayerId = tonumber(byPlayerId)
    if not byPlayerId or byPlayerId < 1 then
        return nil, "invalid_player"
    end
    local now = Open77.time.monotonic()
    local last = robbedAt[shop.id]
    if last and now - last < Config.robCooldownSeconds then
        return nil, "cooldown"
    end
    local near, why = withinReach(byPlayerId, shop, Config.robDistance)
    if not near then
        return nil, why == "too_far" and "too_far" or tostring(why)
    end
    local loot = math.random(Config.robLoot.min, Config.robLoot.max)
    if shop.society and Config.robTakesFromSociety then
        local ok, balance, err = callExport("rp_bank", "societyRemove", shop.society, loot, "robbery:" .. shop.id)
        if ok and balance == nil and err == "insufficient_funds" then
            local okS, society = callExport("rp_bank", "society", shop.society)
            local left = (okS and type(society) == "table" and math.floor(tonumber(society.balance) or 0)) or 0
            if left <= 0 then
                return nil, "register_empty"
            end
            loot = left
            callExport("rp_bank", "societyRemove", shop.society, loot, "robbery:" .. shop.id)
        end
    end
    local ok, balance, err = callExport("rp_economy", "add", byPlayerId, loot, "robbery:" .. shop.id)
    if not ok then
        return nil, "economy_offline"
    end
    if balance == nil then
        return nil, tostring(err or "refused")
    end
    robbedAt[shop.id] = now
    if shop.npcId then
        pcall(function()
            Open77.npcs.tasks.clear(shop.npcId)
            Open77.npcs.tasks.workspot(shop.npcId, "handsup", { durationMs = Config.robHandsUpMs })
        end)
        vendorSpeak(shop, Config.vendor.robbed, { ignoreDistance = true })
    end
    say(byPlayerId, ("%s empties the register: %s in cash. NCPD dispatch just got the call."):format(
        (shop.vendor and shop.vendor.name) or "The vendor", eddies(loot)))
    print(LOG .. (" ROBBERY shop=%s by player %s loot=%d"):format(shop.id, tostring(byPlayerId), loot))
    TriggerEvent("rp_shops:robbed", shop.id, byPlayerId, loot)
    TriggerEvent("rp_ncpd:alert", "robbery", shop.position, shop.label .. " robbed", byPlayerId)
    return loot
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then
        return -- Open77.players.identifier raises on id 0 and that kills the VM
    end
    local identifier = identifierOf(playerId)
    if identifier and store then
        ensureLicenceLoaded(identifier)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    busy[tonumber(playerId) or playerId] = nil
    if tonumber(playerId) then stageClear(tonumber(playerId)) end
end)

-- A vendor removed behind our back (admin, cleanup): forget the id so the
-- shop keeps trading silently instead of logging a refusal per customer.
AddEventHandler("onNpcRemoved", function(npcId, reason, resource)
    local shopId = byNpc[tostring(npcId)]
    if not shopId then
        return
    end
    byNpc[tostring(npcId)] = nil
    if shops[shopId] then
        shops[shopId].npcId = nil
    end
    print(LOG .. " vendor of " .. shopId .. " removed (" .. tostring(reason) .. ")")
    -- The counter must not stay empty until the next restart: put the vendor back
    -- (a few seconds later, so an explosion / cleanup sweep has finished).
    if stopping then return end
    SetTimeout(5000, function()
        local shop = shops[shopId]
        if shop and not shop.npcId and not stopping then
            spawnVendor(shop)
        end
    end)
end)

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source == 0 then
        return
    end
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    for _, shop in ipairs(Config.shops) do
        shops[shop.id] = shop
        shopOrder[#shopOrder + 1] = shop
    end
    setupStore()
    spawnVendors()
    spawnProps()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    print(LOG .. (" %d shops open around %.0f, %.0f; gun licence %d, styling %d, black market %02d:00-%02d:00"):format(
        #shopOrder, Config.hub.x, Config.hub.y, Config.gunLicenceFee, Config.stylingFee, Config.blackmarket.openHour, Config.blackmarket.closeHour))
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then
        return
    end
    stopping = true
    removeVendors()
    removeProps()
end)
