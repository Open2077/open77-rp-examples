-- rp_inventory / server: the authoritative inventory of a Night City RP server.
--
-- Everything that moves an item runs here. Clients only render and request.
-- Exports are synchronous-safe (they never yield): the in-memory cache is the
-- truth for a connected player, and every change is written straight through
-- to SQL (or the kvp store when no database answers). The /inv panel is a
-- WebUI page (web/index.html) fed by rp_inventory:panel and driven by
-- rp_inventory:intent; every intent lands in the same functions as the commands.

local RESOURCE = GetCurrentResourceName()
local Items = RpInventoryItems
local Config = RpInventoryConfig

local inventories = {}   -- [playerId] = { kind = "player", id = playerId, identifier, items = {}, capacity, loaded }
local stashes = {}       -- [stashId]  = { kind = "stash", id = stashId, items = {}, capacity, loaded }
local drops = {}         -- [tostring(lootId)] = { itemId, count }
local dbReady = false
local dbFailReason = nil

-- Panel refresh hooks, defined with the panel code below and forward-declared
-- so the primitive mutations can schedule a push whoever caused the change
-- (a command, the page, or another resource through the exports).
local refreshPanel        -- function(playerId, notice?)
local refreshStashViewers -- function(stashId)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_inventory] " .. fmt):format(...))
end

local function tell(playerId, text)
    if type(playerId) ~= "number" or playerId <= 0 then
        print("[rp_inventory] " .. text)
        return
    end
    Open77.chat.send(playerId, { type = "system", author = "POCKETS", text = text, color = { 0, 229, 255 } })
end

local REASONS = {
    invalid_player = "That is not a player id.",
    player_not_found = "Nobody with that id in Night City.",
    not_loaded = "Pockets still loading. Try again in a second.",
    unknown_item = "No such item. Check the id or name.",
    invalid_count = "Give me a whole number above zero.",
    not_enough = "You do not have that many.",
    too_heavy = "Too heavy, choom. Drop something first (40 kg max).",
    target_too_heavy = "They cannot carry that much.",
    stash_full = "The stash is full.",
    not_usable = "You cannot use that. Sell it, give it, or drop it.",
    too_far = "Get closer. Three metres, arm's length.",
    self_target = "Giving things to yourself. Bold. No.",
    position_unknown = "The server has no fix on your position yet.",
    not_in_vehicle = "Sit in a vehicle first; the can does not pour itself.",
    fuel_unavailable = "No fuel system on this server. The can stays in your pockets.",
    full_health = "You are already at full health. Save it.",
    needs_refused = "You are not hungry or thirsty enough for that.",
    not_illegal = "That item is legal. NCPD cannot seize it.",
    not_surrendered = "They are neither cuffed nor surrendering. Cuff them or make them raise their hands.",
    loot_unavailable = "The loot system is not running. Nothing dropped.",
    dialog_active = "Close the other dialog first.",
    progress_active = "Finish what you are doing first.",
}

local function explain(reason)
    return REASONS[reason] or ("Refused: " .. tostring(reason))
end

local function isCount(n)
    return type(n) == "number" and n >= 1 and n % 1 == 0 and n <= 1000000
end

-- Resolve "burrito", "Burrito", "bur" to an item id.
local function findItem(query)
    if type(query) ~= "string" or query == "" then return nil end
    local q = query:lower()
    if Items[q] then return q end
    for id, def in pairs(Items) do
        if def.label:lower() == q then return id end
    end
    local hit, hits = nil, 0
    for id, def in pairs(Items) do
        if id:sub(1, #q) == q or def.label:lower():sub(1, #q) == q then
            hit, hits = id, hits + 1
        end
    end
    if hits == 1 then return hit end
    return nil
end

local function containerWeight(c)
    local total = 0
    for itemId, n in pairs(c.items) do
        local def = Items[itemId]
        if def then total = total + def.weight * n end
    end
    return total
end

local function canCarry(c, itemId, n)
    local def = Items[itemId]
    if not def then return false end
    return containerWeight(c) + def.weight * n <= c.capacity + 1e-6
end

local function sortedEntries(c)
    local entries = {}
    for itemId, n in pairs(c.items) do
        local def = Items[itemId]
        if def and n > 0 then
            entries[#entries + 1] = {
                id = itemId, label = def.label, count = n, weight = def.weight,
                total = def.weight * n, usable = def.usable == true, illegal = def.illegal == true,
                category = def.category or (def.effect and def.effect.kind) or "misc",
            }
        end
    end
    table.sort(entries, function(a, b) return a.label < b.label end)
    return entries
end

-- Calls another resource's export: inline first, and through the promise form
-- when the callee needs to yield (a database-backed export). Returns
-- available (boolean), then the export's own values. A missing resource or
-- export answers false, reason and never raises.
local function callExport(resource, name, ...)
    local r = table.pack(pcall(Open77.exports.callSync, resource, name, ...))
    if r[1] then return true, table.unpack(r, 2, r.n) end
    local err = tostring(r[2])
    if err:find("export_yielded", 1, true) then
        local promise = Open77.exports.call(resource, name, ...)
        if promise then
            local a = table.pack(promise:await())
            if a[1] == nil and type(a[2]) == "string" and a[2]:find("^export_") then return false, a[2] end
            return true, table.unpack(a, 1, a.n)
        end
    end
    return false, err
end

-- An item is illegal for a holder unless they hold the permit job.
local function isIllegalFor(def, playerId)
    if not def.illegal then return false end
    if def.permit then
        local available, licensed = callExport("rp_jobs", "hasJob", playerId, def.permit)
        if available and licensed == true then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Persistence: SQL first, kvp only when the database is not ready
---------------------------------------------------------------------------

local function persist(c, itemId)
    local n = c.items[itemId] or 0
    if c.kind == "player" then
        if dbReady then
            if n > 0 then
                Open77.database.update("INSERT INTO rp_inventory_items (identifier, item_id, count) VALUES (?, ?, ?) "
                    .. "ON DUPLICATE KEY UPDATE count = VALUES(count)", { c.identifier, itemId, n })
            else
                Open77.database.update("DELETE FROM rp_inventory_items WHERE identifier = ? AND item_id = ?",
                    { c.identifier, itemId })
            end
        else
            local key = "inv:" .. c.identifier .. ":" .. itemId
            if n > 0 then Open77.kvp.set(key, n) else Open77.kvp.delete(key) end
        end
    else
        if dbReady then
            if n > 0 then
                Open77.database.update("INSERT INTO rp_inventory_stashes (stash_id, item_id, count) VALUES (?, ?, ?) "
                    .. "ON DUPLICATE KEY UPDATE count = VALUES(count)", { c.id, itemId, n })
            else
                Open77.database.update("DELETE FROM rp_inventory_stashes WHERE stash_id = ? AND item_id = ?",
                    { c.id, itemId })
            end
        else
            local key = "stash:" .. c.id .. ":" .. itemId
            if n > 0 then Open77.kvp.set(key, n) else Open77.kvp.delete(key) end
        end
    end
end

-- Runs one database call in its callback form and waits for the answer, with a
-- deadline. The cards document `.await` too, but the static validator does not
-- catalogue that spelling; a promise around the callback is the same wait and
-- cannot strand the task when the worker never answers.
-- Returns value, nil, true when the worker answered; nil, reason otherwise.
local function dbAwait(call, sql, params)
    local p = promise.new()
    local timer = SetTimeout(15000, function() p:reject("database_timeout") end)
    call(sql, params or {}, function(result)
        ClearTimeout(timer)
        p:resolve({ value = result })
    end)
    local box, reason = p:await()
    if type(box) ~= "table" then return nil, reason or "database_failed" end
    return box.value, nil, true
end

-- Wait a little for a database that is still connecting; never for one that will not come.
local function waitForDatabase(maxMs)
    local deadline = Open77.time.monotonic() + maxMs / 1000
    while not dbReady do
        local ready, reason = Open77.database.isReady()
        if not ready and reason ~= "database_connecting" and reason ~= "database_unreachable" then break end
        if Open77.time.monotonic() >= deadline then break end
        Wait(250)
    end
    return dbReady
end

-- Fills c.items from SQL or kvp. Yields: call from a managed task only.
local function loadContainer(c)
    waitForDatabase(10000)
    local items = {}
    if dbReady then
        local rows, reason
        for attempt = 1, 3 do
            if c.kind == "player" then
                rows, reason = dbAwait(Open77.database.query,
                    "SELECT item_id, count FROM rp_inventory_items WHERE identifier = ?", { c.identifier })
            else
                rows, reason = dbAwait(Open77.database.query,
                    "SELECT item_id, count FROM rp_inventory_stashes WHERE stash_id = ?", { c.id })
            end
            if type(rows) == "table" then break end
            log("%s %s: load attempt %d failed (%s)", c.kind, tostring(c.id), attempt, tostring(reason or "no rows"))
            Wait(2000)
        end
        if type(rows) ~= "table" then
            -- Never mark a container loaded on a failed read: a later write would erase the real rows.
            c.error = reason or "database_failed"
            log("%s %s NOT loaded: the database did not answer; it stays read-only until a reconnect", c.kind, tostring(c.id))
            return c
        end
        for _, row in ipairs(rows) do
            local n = tonumber(row.count) or 0
            if Items[row.item_id] and n > 0 then items[row.item_id] = math.floor(n) end
        end
        c.source = "sql"
    else
        local prefix = (c.kind == "player") and ("inv:" .. c.identifier .. ":") or ("stash:" .. c.id .. ":")
        for _, entry in ipairs(Open77.kvp.find(prefix, 512) or {}) do
            local itemId = entry.key:sub(#prefix + 1)
            local n = tonumber(entry.value) or 0
            if Items[itemId] and n > 0 then items[itemId] = math.floor(n) end
        end
        c.source = "kvp"
        local _, state = Open77.database.isReady()
        log("%s %s loaded from kvp: database not ready (%s)", c.kind, tostring(c.id),
            tostring(dbFailReason or state or "unknown"))
    end
    c.items = items
    c.loaded = true
    return c
end

---------------------------------------------------------------------------
-- Player containers
---------------------------------------------------------------------------

local function loadPlayer(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        log("player %d has no identifier yet, inventory not loaded", playerId)
        return nil
    end
    local inv = { kind = "player", id = playerId, identifier = identifier, items = {},
                  capacity = Config.maxCarryWeight, loaded = false }
    inventories[playerId] = inv
    loadContainer(inv)
    if inventories[playerId] ~= inv then return nil end  -- left while loading
    if not inv.loaded then
        tell(playerId, "Your pockets could not be read from the database. Reconnect in a minute.")
        return nil
    end
    log("player %d inventory loaded from %s: %d item kinds, %.1f kg", playerId, tostring(inv.source),
        #sortedEntries(inv), containerWeight(inv))
    return inv
end

local function resolvePlayer(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId <= 0 or playerId % 1 ~= 0 then return nil, "invalid_player" end
    local inv = inventories[playerId]
    if not inv then return nil, "player_not_found" end
    if not inv.loaded then return nil, "not_loaded" end
    return inv, playerId
end

-- The two primitive mutations. Both are synchronous and both log + persist + notify.
local function creditPlayer(playerId, itemId, n, why)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(n) then return nil, "invalid_count" end
    if not canCarry(inv, itemId, n) then return nil, "too_heavy" end
    inv.items[itemId] = (inv.items[itemId] or 0) + n
    persist(inv, itemId)
    log("player %d +%d %s total=%d%s", inv.id, n, itemId, inv.items[itemId], why and (" " .. why) or "")
    TriggerEvent("rp_inventory:changed", inv.id, itemId, n)
    if refreshPanel then refreshPanel(inv.id) end
    return true
end

local function debitPlayer(playerId, itemId, n, why)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(n) then return nil, "invalid_count" end
    local have = inv.items[itemId] or 0
    if have < n then return nil, "not_enough" end
    local left = have - n
    inv.items[itemId] = left > 0 and left or nil
    persist(inv, itemId)
    log("player %d -%d %s total=%d%s", inv.id, n, itemId, left, why and (" " .. why) or "")
    TriggerEvent("rp_inventory:changed", inv.id, itemId, -n)
    if refreshPanel then refreshPanel(inv.id) end
    return true
end

local function creditStash(stash, playerId, itemId, n)
    if not canCarry(stash, itemId, n) then return nil, "stash_full" end
    stash.items[itemId] = (stash.items[itemId] or 0) + n
    persist(stash, itemId)
    log("stash %s +%d %s total=%d by player %d", stash.id, n, itemId, stash.items[itemId], playerId)
    if refreshStashViewers then refreshStashViewers(stash.id) end
    return true
end

local function debitStash(stash, playerId, itemId, n)
    local have = stash.items[itemId] or 0
    if have < n then return nil, "not_enough" end
    local left = have - n
    stash.items[itemId] = left > 0 and left or nil
    persist(stash, itemId)
    log("stash %s -%d %s total=%d by player %d", stash.id, n, itemId, left, playerId)
    if refreshStashViewers then refreshStashViewers(stash.id) end
    return true
end

---------------------------------------------------------------------------
-- Exports (phase 1 contract): has add remove count list openStash
-- Synchronous callers (exports.rp_inventory:add(...)) are fine: nothing here yields.
---------------------------------------------------------------------------

-- define(items) -> registered, rejected | nil, reason
-- Lets another resource declare its own items (a crowbar, a boxed implant, a quickhack...) in
-- the same shape as shared/items.lua. Idempotent: a definer calls it from its onResourceStart
-- and again when rp_inventory itself restarts (its VM restarts with the built-in table only;
-- rows of undefined ids stay in SQL and come back after the next definition + load).
exports("define", function(items)
    if type(items) ~= "table" then return nil, "invalid_items" end
    local registered, rejected = 0, 0
    for id, def in pairs(items) do
        if type(id) == "string" and id:match("^[%l%d_]+$") and type(def) == "table"
            and type(def.label) == "string" and #def.label > 0 and #def.label <= 48
            and type(def.weight) == "number" and def.weight >= 0 and def.weight <= 100 then
            Items[id] = {
                label = def.label, weight = def.weight, usable = def.usable == true,
                illegal = def.illegal == true, permit = def.permit,
                effect = type(def.effect) == "table" and def.effect or nil,
                record = def.record, visual = def.visual, definedBy = GetInvokingResource(),
                category = (type(def.category) == "string" and def.category:match("^%l+$")) and def.category or nil,
            }
            registered = registered + 1
        else
            rejected = rejected + 1
        end
    end
    log("define: %d item(s) registered, %d rejected", registered, rejected)
    return registered, rejected
end)

exports("has", function(playerId, itemId, count)
    local inv = resolvePlayer(playerId)
    if not inv then return false end
    local n = tonumber(count) or 1
    return (inv.items[itemId] or 0) >= n
end)

exports("add", function(playerId, itemId, count)
    return creditPlayer(playerId, itemId, tonumber(count) or 1, "(export add)")
end)

exports("remove", function(playerId, itemId, count)
    return debitPlayer(playerId, itemId, tonumber(count) or 1, "(export remove)")
end)

exports("count", function(playerId, itemId)
    local inv = resolvePlayer(playerId)
    if not inv then return 0 end
    return inv.items[itemId] or 0
end)

-- list(playerId) -> entries, totalWeight, capacity | nil, reason
-- entries: { { id, label, count, weight, total, usable, illegal }, ... } sorted by label
exports("list", function(playerId)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    return sortedEntries(inv), containerWeight(inv), inv.capacity
end)

---------------------------------------------------------------------------
-- UI kit server twins
---------------------------------------------------------------------------

-- Runs one uikit twin and normalises the answer: table | nil, reason.
local function uikit(method, playerId, ...)
    local promise, reason = Open77.exports.call("open77_uikit", method, playerId, ...)
    if not promise then return nil, reason end
    local answer, err = promise:await()
    if type(answer) ~= "table" then return nil, err or "no_answer" end
    return answer
end

local function chatListing(playerId, c, title)
    local entries = sortedEntries(c)
    tell(playerId, ("%s - %.1f / %.0f kg"):format(title, containerWeight(c), c.capacity))
    if #entries == 0 then
        tell(playerId, "Empty. Not even lint.")
        return
    end
    local parts = {}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = ("%s x%d (%.1f kg)%s"):format(e.label, e.count, e.total, e.illegal and " [ILLEGAL]" or "")
    end
    tell(playerId, table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- Use
---------------------------------------------------------------------------

-- Applies the effect of one item. Returns true | nil, reason. May yield (fuel export, stats).
local function applyEffect(playerId, itemId, def)
    local effect = def.effect or {}
    local kind = effect.kind

    -- Items another resource declared through `define` own their effect: this resource only
    -- debits and raises rp_inventory:used; the definer applies whatever the item does. A
    -- `needs` table on the effect is applied here through rp_needs:apply for convenience.
    if def.definedBy then
        if type(effect.needs) == "table" then
            local called, result, reason = callExport("rp_needs", "apply", playerId, effect.needs, def.label)
            if called and not result then return nil, reason or "needs_refused" end
        end
        tell(playerId, effect.text or ("You use the %s."):format(def.label:lower()))
        return true
    end

    if kind == "heal" then
        local stats = Open77.stats.get(playerId)
        if stats and stats.health and stats.health.value >= stats.health.maximum and not effect.stamina then
            return nil, "full_health"
        end
        local ok, reason = Open77.players.heal(playerId, effect.amount or 25)
        if not ok then return nil, reason or "heal_refused" end
        if effect.stamina then Open77.players.restoreStamina(playerId) end
        tell(playerId, ("%s applied. +%d health."):format(def.label, effect.amount or 25))
        return true
    end

    if kind == "stamina" then
        local ok, reason = Open77.players.restoreStamina(playerId)
        if not ok then return nil, reason or "stamina_refused" end
        tell(playerId, "Your heart races. Stamina restored. Your nose will hate you tomorrow.")
        return true
    end

    if kind == "food" or kind == "drink" then
        -- rp_needs is written in parallel: reach it through pcall, never a dependency.
        local called, result, reason = callExport("rp_needs", "consume", playerId, itemId)
        if called then
            if not result then return nil, reason or "needs_refused" end
            tell(playerId, (kind == "food") and ("You eat the %s. Better."):format(def.label:lower())
                or ("You drink the %s. Better."):format(def.label:lower()))
        else
            tell(playerId, ("You %s the %s. (No needs system on this server, so it is just flavour.)")
                :format(kind == "food" and "eat" or "drink", def.label:lower()))
        end
        return true
    end

    if kind == "fuel" then
        local seat = Open77.vehicles.getPlayerSeat(playerId)
        if not seat then return nil, "not_in_vehicle" end
        local litres = effect.litres or 20
        local called, result, reason = callExport("open77_fuel", "refuel", seat.vehicleId, litres)
        if not called then return nil, "fuel_unavailable" end
        if result == nil or result == false then return nil, reason or "refuel_refused" end
        local _, level = callExport("open77_fuel", "level", seat.vehicleId)
        if type(level) == "number" then
            tell(playerId, ("Poured %d L of CHOOH2. Tank: %.0f L."):format(litres, level))
        else
            tell(playerId, ("Poured %d L of CHOOH2 into the tank."):format(litres))
        end
        return true
    end

    if kind == "smoke" then
        tell(playerId, "You light one up. Night City smells a little worse.")
        return true
    end

    return nil, "not_usable"
end

-- Uses one unit of an item: progress bar, effect, debit, event. May yield.
local function useItem(playerId, itemId)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not def.usable then return nil, "not_usable" end
    if (inv.items[itemId] or 0) < 1 then return nil, "not_enough" end

    -- A short bar, cancellable, no focus taken. If the kit refuses it, use without it.
    local bar, barReason = uikit("progress", playerId, {
        label = "Using " .. def.label,
        duration = Config.useDurationMs,
        disable = { move = true, combat = true },
    })
    if bar then
        if not bar.ok then return nil, "cancelled" end
    elseif barReason == "progress_active" or barReason == "dialog_active" then
        return nil, barReason
    end

    -- Re-check after the wait: the item may have been given away meanwhile.
    if (inv.items[itemId] or 0) < 1 then return nil, "not_enough" end
    local ok, why = applyEffect(playerId, itemId, def)
    if not ok then return nil, why end
    local debited, dreason = debitPlayer(playerId, itemId, 1, "(used)")
    if not debited then return nil, dreason end
    TriggerEvent("rp_inventory:used", playerId, itemId)
    return true
end

---------------------------------------------------------------------------
-- Drop / pick up through the loot API
---------------------------------------------------------------------------

local function createDrop(def, itemId, count, pos)
    return Open77.loot.create({
        item = def.record or Config.lootRecord,
        quantity = count,
        position = { x = pos.x, y = pos.y, z = pos.z + 1.0 },
        bucket = pos.bucket,
        radius = 2.0,
        label = def.label,
        visualItem = def.visual or Config.lootVisual,
        ttlMs = Config.dropTtlMs,
    })
end

local function dropItems(playerId, itemId, count)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(count) then return nil, "invalid_count" end
    if (inv.items[itemId] or 0) < count then return nil, "not_enough" end
    local pos = Open77.players.position(playerId)
    if not pos then return nil, "position_unknown" end
    -- Loot first, debit second: a refused drop costs nothing.
    local dropId, lreason = createDrop(def, itemId, count, pos)
    if not dropId then return nil, lreason or "loot_unavailable" end
    drops[tostring(dropId)] = { itemId = itemId, count = count }
    local ok, dreason = debitPlayer(playerId, itemId, count, ("(dropped as loot %s)"):format(tostring(dropId)))
    if not ok then
        drops[tostring(dropId)] = nil
        Open77.loot.remove(dropId)
        return nil, dreason
    end
    return true, dropId
end

-- Credits a picked-up drop, or puts it back on the ground when the picker cannot carry it.
local function creditDrop(playerId, key, drop, how)
    local def = Items[drop.itemId]
    if not def then return end
    local ok, reason = creditPlayer(playerId, drop.itemId, drop.count, ("(picked up loot %s%s)"):format(key, how))
    if ok then
        tell(playerId, ("Picked up %s x%d."):format(def.label, drop.count))
        return
    end
    local pos = Open77.players.position(playerId)
    local newId = pos and createDrop(def, drop.itemId, drop.count, pos) or nil
    if newId then drops[tostring(newId)] = drop end
    tell(playerId, explain(reason) .. (newId and " It stays on the ground." or ""))
end

AddEventHandler("onLootPickup", function(playerId, dropId, item, quantity, ownerResource)
    if ownerResource ~= RESOURCE then return end
    local key = tostring(dropId)
    local drop = drops[key]
    if not drop then
        log("pickup of unknown drop %s by player %s ignored", key, tostring(playerId))
        return
    end
    drops[key] = nil
    creditDrop(tonumber(playerId), key, drop, "")
end)

AddEventHandler("onLootRemoved", function(id, reason, resource)
    if resource ~= RESOURCE then return end
    if reason == "picked_up" then return end   -- onLootPickup owns that path
    local key = tostring(id)
    if drops[key] then
        log("drop %s (%s x%d) gone: %s", key, drops[key].itemId, drops[key].count, tostring(reason))
        drops[key] = nil
    end
end)

-- Fallback to the native prompt: take the nearest of our drops within reach.
local function pickUpNearest(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then return nil, "position_unknown" end
    local best, bestKey, bestDist
    for _, d in ipairs(Open77.loot.all(pos.bucket) or {}) do
        local key = tostring(d.id)
        local entry = drops[key]
        if entry then
            local p = d.position or d
            local dx = (tonumber(p.x) or 0) - pos.x
            local dy = (tonumber(p.y) or 0) - pos.y
            local dz = (tonumber(p.z) or 0) - pos.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= Config.interactDistance + 0.75 and (not bestDist or dist < bestDist) then
                best, bestKey, bestDist = d, key, dist
            end
        end
    end
    if not best then return nil, "nothing_nearby" end
    local entry = drops[bestKey]
    local inv = resolvePlayer(playerId)
    if not inv then return nil, "not_loaded" end
    if not canCarry(inv, entry.itemId, entry.count) then return nil, "too_heavy" end
    if not Open77.loot.remove(best.id) then
        drops[bestKey] = nil
        return nil, "already_taken"
    end
    drops[bestKey] = nil
    creditDrop(playerId, bestKey, entry, " via /ramasser")
    return true
end

---------------------------------------------------------------------------
-- Give
---------------------------------------------------------------------------

-- Validates a player-to-player target: number, exists, not self, loaded, within reach.
local function checkTarget(source, targetId)
    targetId = tonumber(targetId)
    if not targetId or targetId <= 0 or targetId % 1 ~= 0 then return nil, "invalid_player" end
    if targetId == source then return nil, "self_target" end
    if not Open77.players.name(targetId) then return nil, "player_not_found" end
    local tinv, reason = resolvePlayer(targetId)
    if not tinv then return nil, reason end
    local metres, dreason = Open77.players.distance(source, targetId)
    if not metres then return nil, dreason or "position_unknown" end
    if metres > Config.interactDistance then return nil, "too_far" end
    return targetId, tinv
end

local function giveItems(source, targetId, itemId, count)
    local inv, reason = resolvePlayer(source)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(count) then return nil, "invalid_count" end
    if (inv.items[itemId] or 0) < count then return nil, "not_enough" end
    local tid, tinv = checkTarget(source, targetId)
    if not tid then return nil, tinv end
    if not canCarry(tinv, itemId, count) then return nil, "target_too_heavy" end
    local ok, dreason = debitPlayer(source, itemId, count, ("(given to player %d)"):format(tid))
    if not ok then return nil, dreason end
    local credited, creason = creditPlayer(tid, itemId, count, ("(given by player %d)"):format(source))
    if not credited then
        creditPlayer(source, itemId, count, "(give rolled back)")
        return nil, creason
    end
    local from = Open77.players.name(source) or ("#" .. source)
    local to = Open77.players.name(tid) or ("#" .. tid)
    tell(source, ("You hand %s x%d to %s."):format(def.label, count, to))
    tell(tid, ("%s hands you %s x%d."):format(from, def.label, count))
    return true
end

-- The dialog half of a give: pick the item (and how many) from the giver's pockets, then move it.
-- targetId may be nil: then the giver picks somebody within reach.
local function giveDialog(source, targetId)
    local inv, reason = resolvePlayer(source)
    if not inv then tell(source, explain(reason)) return end
    local entries = sortedEntries(inv)
    if #entries == 0 then tell(source, "Nothing to give. Your pockets are empty.") return end

    local fields = {}
    if not targetId then
        local near = Open77.players.nearby(source, Config.interactDistance) or {}
        local options = {}
        for _, p in ipairs(near) do
            options[#options + 1] = { value = tostring(p.playerId),
                label = ("%s (#%d, %.1f m)"):format(p.name or "?", p.playerId, p.distance or 0) }
        end
        if #options == 0 then tell(source, "Nobody within arm's length to give anything to.") return end
        fields[#fields + 1] = { id = "target", type = "select", label = "To whom?", options = options, required = true }
    else
        local tid, terr = checkTarget(source, targetId)
        if not tid then tell(source, explain(terr)) return end
        targetId = tid
    end
    local itemOptions = {}
    for _, e in ipairs(entries) do
        itemOptions[#itemOptions + 1] = { value = e.id, label = ("%s x%d (%.1f kg)"):format(e.label, e.count, e.weight) }
    end
    fields[#fields + 1] = { id = "item", type = "select", label = "What?", options = itemOptions, required = true }
    fields[#fields + 1] = { id = "count", type = "number", label = "How many?", min = 1, max = 1000, default = 1, required = true }

    local answer, uerr = uikit("input", source, {
        title = targetId and ("Give to " .. (Open77.players.name(targetId) or ("#" .. targetId))) or "Give an item",
        description = "The server checks the distance and their carry weight.",
        fields = fields, confirm = "Give", cancel = "Cancel", timeoutMs = 60000,
    })
    if not answer then
        tell(source, "Dialog unavailable (" .. tostring(uerr) .. "). Use /give <playerId> <item> [count].")
        return
    end
    if not answer.ok then return end
    local v = answer.value or {}
    local tid = targetId or tonumber(v.target)
    local n = math.floor(tonumber(v.count) or 0)
    local ok, gerr = giveItems(source, tid, v.item, n)
    if not ok then tell(source, explain(gerr)) end
end

---------------------------------------------------------------------------
-- Search (fouiller) and seize (saisir)
---------------------------------------------------------------------------

-- Does an animation state mention a profile id, wherever the host put it?
local function mentionsProfile(state, profileId)
    if type(state) ~= "table" then return false end
    local keys = { "profileId", "profile", "id" }
    for _, key in ipairs(keys) do
        if state[key] == profileId then return true end
    end
    if type(state.steps) == "table" then
        for _, step in ipairs(state.steps) do
            if step == profileId then return true end
            if type(step) == "table" then
                for _, key in ipairs(keys) do
                    if step[key] == profileId then return true end
                end
            end
        end
    end
    local encoded = json.encode(state)
    return encoded ~= nil and encoded:find('"' .. profileId .. '"', 1, true) ~= nil
end

-- Held by the RP kit, or hands up: the two states that allow a frisk.
local function isSurrendered(targetId)
    local called, hold = callExport("open77_rp_basics", "state", targetId)
    if called and hold then return true, "held" end
    local anim = Open77.animations.current(targetId)
    if anim and mentionsProfile(anim, "handsup") then return true, "handsup" end
    return false
end

local function searchPlayer(source, targetId)
    local tid, tinv = checkTarget(source, targetId)
    if not tid then return nil, tinv end
    if not isSurrendered(tid) then return nil, "not_surrendered" end
    local name = Open77.players.name(tid) or ("#" .. tid)
    tell(tid, ("%s is going through your pockets."):format(Open77.players.name(source) or "Someone"))
    chatListing(source, tinv, name .. "'s pockets")
    local illegal = {}
    for _, e in ipairs(sortedEntries(tinv)) do
        if isIllegalFor(Items[e.id], tid) then illegal[#illegal + 1] = e.id end
    end
    if #illegal > 0 then
        tell(source, ("Contraband found: %s. Seize it with /saisir %d <item>."):format(table.concat(illegal, ", "), tid))
    end
    log("player %d searched player %d", source, tid)
    return true
end

local function seizeItem(source, targetId, itemId)
    local tid, tinv = checkTarget(source, targetId)
    if not tid then return nil, tinv end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isSurrendered(tid) then return nil, "not_surrendered" end
    if not isIllegalFor(def, tid) then return nil, "not_illegal" end
    local n = tinv.items[itemId] or 0
    if n < 1 then return nil, "not_enough" end
    local inv = resolvePlayer(source)
    if not inv then return nil, "not_loaded" end
    if not canCarry(inv, itemId, n) then return nil, "too_heavy" end
    local ok, reason = debitPlayer(tid, itemId, n, ("(seized by player %d)"):format(source))
    if not ok then return nil, reason end
    local credited, creason = creditPlayer(source, itemId, n, ("(seized from player %d)"):format(tid))
    if not credited then
        creditPlayer(tid, itemId, n, "(seizure rolled back)")
        return nil, creason
    end
    tell(source, ("Seized %s x%d from %s."):format(def.label, n, Open77.players.name(tid) or ("#" .. tid)))
    tell(tid, ("%s seized your %s x%d."):format(Open77.players.name(source) or "Someone", def.label, n))
    return true
end

---------------------------------------------------------------------------
-- The /inv panel: a WebUI page shipped by this resource (web/index.html).
--
-- The server owns the panel. It pushes the whole state through
-- rp_inventory:panel (on open and after every change, whoever caused it) and
-- answers each page intent with the same functions the slash commands use.
-- The page renders and asks; it never decides. A stash opened through the
-- openStash export is the same panel with a second column.
---------------------------------------------------------------------------

local panels = {}        -- [playerId] = { stashId = string | nil, name = string }
local panelPending = {}  -- [playerId] = { notice = table | nil } while a push is scheduled

-- The RP name of a connected player (rp_identity, else the account name). fullName never yields.
local function nameOf(playerId)
    local ok, full = callExport("rp_identity", "fullName", playerId)
    if ok and type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

local function containerView(c)
    return { id = c.id, entries = sortedEntries(c), weight = containerWeight(c), capacity = c.capacity }
end

-- The nearest other player within reach, the one a panel "Give" goes to.
local function nearestPlayer(playerId)
    local entry = Open77.players.closest(playerId, { radius = Config.interactDistance })
    if type(entry) ~= "table" or type(entry.playerId) ~= "number" then return nil end
    return { playerId = entry.playerId, name = nameOf(entry.playerId), distance = entry.distance or 0 }
end

-- Everything the page renders, nothing else. nil when the panel is not open.
local function panelState(playerId, notice)
    local session = panels[playerId]
    local inv = resolvePlayer(playerId)
    if not session or not inv then return nil end
    local state = {
        open = true,
        playerId = playerId,
        name = session.name,
        pockets = containerView(inv),
        nearest = nearestPlayer(playerId),
        notice = notice,
    }
    local stash = session.stashId and stashes[session.stashId]
    if stash and stash.loaded then state.stash = containerView(stash) end
    return state
end

-- Coalesces every refresh of the next 50 ms into one push (a give is a debit
-- plus a credit, a rollback three changes). The last notice wins.
refreshPanel = function(playerId, notice)
    if not panels[playerId] then return end
    local pending = panelPending[playerId]
    if pending then
        if notice then pending.notice = notice end
        return
    end
    panelPending[playerId] = { notice = notice }
    SetTimeout(50, function()
        local p = panelPending[playerId]
        panelPending[playerId] = nil
        local state = panelState(playerId, p and p.notice or nil)
        if state then TriggerClientEvent("rp_inventory:panel", playerId, state) end
    end)
end

refreshStashViewers = function(stashId)
    for id, session in pairs(panels) do
        if session.stashId == stashId then refreshPanel(id) end
    end
end

local function closePanel(playerId, tellClient)
    if not panels[playerId] then return end
    panels[playerId] = nil
    panelPending[playerId] = nil
    if tellClient then TriggerClientEvent("rp_inventory:panel", playerId, { open = false }) end
end

-- Loads a stash on first use and waits for a load already in flight. Yields.
-- Returns the stash | nil.
local function loadStash(stashId, capacity)
    local stash = stashes[stashId]
    if not stash then
        stash = { kind = "stash", id = stashId, items = {}, capacity = capacity, loaded = false }
        stashes[stashId] = stash
        loadContainer(stash)
        if not stash.loaded then
            stashes[stashId] = nil   -- let the next caller retry the read
            return nil
        end
        log("stash %s loaded from %s: %d item kinds", stashId, tostring(stash.source), #sortedEntries(stash))
    elseif not stash.loaded then
        for _ = 1, 40 do
            Wait(250)
            if stash.loaded or stash.error then break end
        end
        if not stash.loaded then
            stashes[stashId] = nil
            return nil
        end
    end
    stash.capacity = capacity
    return stash
end

-- Opens (or re-opens) the panel; with a stash id, the two-column form. Yields (stash load).
local function openPanel(playerId, stashId, capacity)
    local inv, reason = resolvePlayer(playerId)
    if not inv then tell(playerId, explain(reason)) return end
    local session = { stashId = nil, name = nameOf(playerId) }
    if stashId then
        local stash = loadStash(stashId, capacity)
        if not stash then
            tell(playerId, "The stash could not be read. Try again in a minute.")
            return
        end
        session.stashId = stashId
    end
    if not inventories[playerId] then return end   -- left while the stash was loading
    panels[playerId] = session
    refreshPanel(playerId)
end

-- Pockets <-> stash moves. Both check the receiving side first, then move with a rollback.
local function takeFromStash(playerId, stash, itemId, n)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if not isCount(n) then return nil, "invalid_count" end
    if (stash.items[itemId] or 0) < n then return nil, "not_enough" end
    if not canCarry(inv, itemId, n) then return nil, "too_heavy" end
    local ok, why = debitStash(stash, playerId, itemId, n)
    if not ok then return nil, why end
    local credited, cwhy = creditPlayer(playerId, itemId, n, ("(from stash %s)"):format(stash.id))
    if not credited then
        creditStash(stash, playerId, itemId, n)
        return nil, cwhy
    end
    return true
end

local function storeToStash(playerId, stash, itemId, n)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if not isCount(n) then return nil, "invalid_count" end
    if (inv.items[itemId] or 0) < n then return nil, "not_enough" end
    if not canCarry(stash, itemId, n) then return nil, "stash_full" end
    local ok, why = debitPlayer(playerId, itemId, n, ("(into stash %s)"):format(stash.id))
    if not ok then return nil, why end
    local stored, swhy = creditStash(stash, playerId, itemId, n)
    if not stored then
        creditPlayer(playerId, itemId, n, "(stash store rolled back)")
        return nil, swhy
    end
    return true
end

-- Page intents. Each returns ok, text (the notice the page shows); the state
-- push that follows is scheduled by the mutation itself or by the dispatcher.
local intents = {}

local function intentItem(payload)
    local itemId = type(payload.item) == "string" and payload.item or ""
    if not Items[itemId] then return nil, "unknown_item" end
    return itemId, math.floor(tonumber(payload.count) or 1)
end

intents.refresh = function() return true end

intents.use = function(playerId, session, payload)
    local itemId, err = intentItem(payload)
    if not itemId then return false, explain(err) end
    local ok, why = useItem(playerId, itemId)
    if ok then return true, ("Used %s."):format(Items[itemId].label) end
    if why == "cancelled" then return false, nil end
    return false, explain(why)
end

intents.drop = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n) end
    local ok, why = dropItems(playerId, itemId, n)
    if not ok then return false, explain(why) end
    local text = ("Dropped %s x%d at your feet."):format(Items[itemId].label, n)
    tell(playerId, text .. " The prompt or /ramasser picks it up.")
    return true, text
end

-- The server picks the receiver: the nearest other player within 3 m, exactly what /give checks.
intents.give = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n) end
    local near = nearestPlayer(playerId)
    if not near then return false, "Nobody within arm's length to give anything to." end
    local ok, why = giveItems(playerId, near.playerId, itemId, n)
    if not ok then return false, explain(why) end
    return true, ("Handed %s x%d to %s."):format(Items[itemId].label, n, near.name)
end

local function openStashOf(session)
    local stash = session.stashId and stashes[session.stashId]
    if stash and stash.loaded then return stash end
    return nil
end

intents.store = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n) end
    local stash = openStashOf(session)
    if not stash then return false, "No stash open." end
    local ok, why = storeToStash(playerId, stash, itemId, n)
    if not ok then return false, explain(why) end
    local text = ("Stored %s x%d."):format(Items[itemId].label, n)
    tell(playerId, text)
    return true, text
end

intents.take = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n) end
    local stash = openStashOf(session)
    if not stash then return false, "No stash open." end
    local ok, why = takeFromStash(playerId, stash, itemId, n)
    if not ok then return false, explain(why) end
    local text = ("Took %s x%d."):format(Items[itemId].label, n)
    tell(playerId, text)
    return true, text
end

-- Transport: the page -> client -> rp_inventory:intent -> here -> rp_inventory:panel
RegisterNetEvent("rp_inventory:intent", function(payload)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
    local action = payload.action

    -- Escape / the X on the page, or a client that (re)started: nothing to check.
    if action == "close" then
        closePanel(playerId, false)
        return
    end
    -- The client has no WebUI: the chat listing stands in, as rp_mdt's fallback does.
    if action == "unavailable" then
        local session = panels[playerId]
        closePanel(playerId, false)
        local inv = resolvePlayer(playerId)
        if not inv then return end
        chatListing(playerId, inv, "Pockets")
        local stash = session and openStashOf(session)
        if stash then chatListing(playerId, stash, "Stash " .. stash.id) end
        tell(playerId, ("Panel unavailable (%s); listed in chat. Commands: /use /drop /give."):format(
            tostring(payload.reason or "webui_unavailable")))
        return
    end
    local session = panels[playerId]
    if not session then
        -- A page nobody opened from here (stale client state): put it away.
        TriggerClientEvent("rp_inventory:panel", playerId, { open = false })
        return
    end
    local handler = intents[action]
    if not handler then
        refreshPanel(playerId, { ok = false, text = "Unknown panel action." })
        return
    end
    local ok, text = handler(playerId, session, payload)
    if not panels[playerId] then return end   -- closed while the intent ran (a 3 s use, say)
    refreshPanel(playerId, text and { ok = ok == true, text = text } or nil)
end)

-- openStash(playerId, stashId, capacity) -> true (panel scheduled) | nil, reason
exports("openStash", function(playerId, stashId, capacity)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if type(stashId) ~= "string" or #stashId == 0 or #stashId > 64 or not stashId:match("^[%w_%-:%.]+$") then
        return nil, "invalid_stash"
    end
    local cap = tonumber(capacity) or Config.defaultStashCapacity
    if cap <= 0 then return nil, "invalid_capacity" end
    CreateThread(function() openPanel(inv.id, stashId, cap) end)
    return true
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function fromGame(source)
    if source == 0 then
        print("[rp_inventory] run this from the game, not the console")
        return false
    end
    return true
end

RegisterCommand("inv", function(source)
    if not fromGame(source) then return end
    openPanel(source)
end, false)

RegisterCommand("use", function(source, args)
    if not fromGame(source) then return end
    local itemId = findItem(args[1])
    if not itemId then return tell(source, "Usage: /use <item>. " .. explain("unknown_item")) end
    local ok, reason = useItem(source, itemId)
    if not ok and reason ~= "cancelled" then tell(source, explain(reason)) end
end, false)

RegisterCommand("drop", function(source, args)
    if not fromGame(source) then return end
    local itemId = findItem(args[1])
    if not itemId then return tell(source, "Usage: /drop <item> [count]. " .. explain("unknown_item")) end
    local n = math.floor(tonumber(args[2]) or 1)
    local ok, reason = dropItems(source, itemId, n)
    if ok then
        tell(source, ("Dropped %s x%d at your feet. The prompt or /ramasser picks it up."):format(Items[itemId].label, n))
    else
        tell(source, explain(reason))
    end
end, false)

RegisterCommand("ramasser", function(source)
    if not fromGame(source) then return end
    local ok, reason = pickUpNearest(source)
    if not ok then
        if reason == "nothing_nearby" then tell(source, "Nothing dropped within reach.")
        elseif reason == "already_taken" then tell(source, "Someone was faster.")
        else tell(source, explain(reason)) end
    end
end, false)

RegisterCommand("give", function(source, args)
    if not fromGame(source) then return end
    local target = tonumber(args[1])
    local itemId = findItem(args[2])
    if not target or not itemId then
        return tell(source, "Usage: /give <playerId> <item> [count]  (or ALT+click a player > Give item)")
    end
    local n = math.floor(tonumber(args[3]) or 1)
    local ok, reason = giveItems(source, target, itemId, n)
    if not ok then tell(source, explain(reason)) end
end, false)

RegisterCommand("fouiller", function(source, args)
    if not fromGame(source) then return end
    local target = tonumber(args[1])
    if not target then return tell(source, "Usage: /fouiller <playerId>") end
    local ok, reason = searchPlayer(source, target)
    if not ok then tell(source, explain(reason)) end
end, false)

RegisterCommand("saisir", function(source, args)
    if not fromGame(source) then return end
    local target = tonumber(args[1])
    local itemId = findItem(args[2])
    if not target or not itemId then return tell(source, "Usage: /saisir <playerId> <item>") end
    local ok, reason = seizeItem(source, target, itemId)
    if not ok then tell(source, explain(reason)) end
end, false)

-- Admin / console: put items in somebody's pockets. ACL: command.giveitem.
RegisterCommand("giveitem", function(source, args)
    local target = tonumber(args[1])
    local itemId = findItem(args[2])
    local n = math.floor(tonumber(args[3]) or 1)
    if not target or not itemId then return tell(source, "Usage: /giveitem <playerId> <item> [count]") end
    local ok, reason = creditPlayer(target, itemId, n, ("(giveitem by %d)"):format(source))
    if not ok then return tell(source, explain(reason)) end
    tell(source, ("Gave %s x%d to player %d."):format(Items[itemId].label, n, target))
    if target ~= source then tell(target, ("%s x%d appeared in your pockets."):format(Items[itemId].label, n)) end
end, true)

---------------------------------------------------------------------------
-- Client requests (context menu actions)
---------------------------------------------------------------------------

RegisterNetEvent("rp_inventory:giveMenu", function(targetId)
    if type(source) ~= "number" or source <= 0 then return end
    giveDialog(source, targetId)
end)

RegisterNetEvent("rp_inventory:search", function(targetId)
    if type(source) ~= "number" or source <= 0 then return end
    local ok, reason = searchPlayer(source, targetId)
    if not ok then tell(source, explain(reason)) end
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/inv", help = "Open your pockets" },
    { command = "/use", help = "Use an item", parameters = { { name = "item", help = "Item id or name" } } },
    { command = "/drop", help = "Drop an item on the ground", parameters = {
        { name = "item", help = "Item id or name" }, { name = "count", help = "How many (default 1)" } } },
    { command = "/ramasser", help = "Pick up the nearest dropped item" },
    { command = "/give", help = "Give an item to a player (or ALT+click them)", parameters = {
        { name = "playerId", help = "Their id" }, { name = "item", help = "Item id or name" },
        { name = "count", help = "How many (default 1)" } } },
    { command = "/fouiller", help = "Search a cuffed or surrendering player", parameters = {
        { name = "playerId", help = "Their id" } } },
    { command = "/saisir", help = "Seize an illegal item from a searched player", parameters = {
        { name = "playerId", help = "Their id" }, { name = "item", help = "Item id or name" } } },
    { command = "/giveitem", help = "(admin) Put items in a player's pockets", parameters = {
        { name = "playerId", help = "Their id" }, { name = "item", help = "Item id or name" },
        { name = "count", help = "How many" } } },
}

local readyOk, readyReason = Open77.database.ready(function()
    local _, e1, a1 = dbAwait(Open77.database.update, [[
        CREATE TABLE IF NOT EXISTS rp_inventory_items (
            identifier VARCHAR(64) NOT NULL,
            item_id VARCHAR(32) NOT NULL,
            count INT NOT NULL DEFAULT 0,
            PRIMARY KEY (identifier, item_id)
        )
    ]])
    local _, e2, a2 = dbAwait(Open77.database.update, [[
        CREATE TABLE IF NOT EXISTS rp_inventory_stashes (
            stash_id VARCHAR(64) NOT NULL,
            item_id VARCHAR(32) NOT NULL,
            count INT NOT NULL DEFAULT 0,
            PRIMARY KEY (stash_id, item_id)
        )
    ]])
    if not a1 or not a2 then
        dbFailReason = e1 or e2 or "schema_failed"
        log("database answered ready but the schema could not be ensured (%s): persistence falls back to Open77.kvp",
            tostring(dbFailReason))
        return
    end
    dbReady = true
    log("database ready: rp_inventory_items and rp_inventory_stashes ensured")
end)
if not readyOk then
    dbFailReason = readyReason
    log("database not available (%s): persistence falls back to Open77.kvp", tostring(readyReason))
end

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    -- Hot reload: players already in the city need their pockets back.
    for _, id in ipairs(Open77.players.all() or {}) do
        local playerId = tonumber(id)
        if playerId and not inventories[playerId] then
            CreateThread(function() loadPlayer(playerId) end)
        end
    end
    log("started")
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then
        Open77.chat.addSuggestions(source, SUGGESTIONS)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    if inventories[playerId] and inventories[playerId].loaded then return end
    loadPlayer(playerId)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    for id in pairs(panels) do
        TriggerClientEvent("rp_inventory:panel", id, { open = false })
    end
    panels = {}
    panelPending = {}
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    panels[playerId] = nil
    panelPending[playerId] = nil
    if inventories[playerId] then
        log("player %d inventory unloaded (every change was already persisted)", playerId)
        inventories[playerId] = nil
    end
end)
