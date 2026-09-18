-- rp_garage: owned vehicles for a Night City RP server (Open77 2.31.13+op77.76).
--
-- The server is the source of truth for ownership: every vehicle this resource creates gets a
-- plate (NC-XXXX) written to the vehicle's state bag and to SQL together with the owner's durable
-- identifier, the record, the paint / health / damage snapshot (Open77.vehicles.getProperties)
-- and the fuel level (open77_fuel). Garages store and take vehicles out, the dealership sells
-- them, keys are duplicates other citizens hold, the impound lot keeps a vehicle until the owner
-- pays the fee. Exports never yield: the cache answers, SQL is written through with callbacks.

local function log(fmt, ...)
    print(("[rp_garage] " .. fmt):format(...))
end

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------

local store = { mode = "pending", reason = nil }   -- pending | sql | kvp
local vehicles = {}        -- plate -> row (see newRow)
local keys = {}            -- plate -> { [holderIdentifier] = { name, givenBy, at } }
local live = {}            -- tostring(vehicleId) -> plate, for vehicles currently in the world
local menuBusy = {}        -- playerId -> Open77.time.monotonic() seconds when a dialog was opened
local stolenSeen = {}      -- plate .. "|" .. identifier -> unix seconds of the last alert
local plateWriteWarned = false

local SOCIETY_PREFIX = "society:"

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------

local function toPlayerId(value)
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then return nil end
    return math.tointeger(n) or n
end

local function now()
    return math.floor(Open77.time.unix())
end

local function say(playerId, text, author)
    if playerId == 0 then
        print("[rp_garage] " .. text)
        return
    end
    Open77.chat.send(playerId, { author = author or "Garage", text = text, color = { 0, 229, 255 } })
end

local function warn(playerId, text, author)
    if playerId == 0 then
        print("[rp_garage] " .. text)
        return
    end
    Open77.chat.send(playerId, { author = author or "Garage", text = text, color = { 255, 120, 0 } })
end

local function toast(playerId, kind, title, message)
    Open77.notifications.send(playerId, { type = kind, title = title, message = message, durationMs = 6000 })
end

local function eddies(amount)
    local s = tostring(math.floor(amount))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", "")) .. " \u{20AC}$"
end

local function planar(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function identifierOf(playerId)
    return Open77.players.identifier(playerId)
end

local function displayName(playerId)
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return Open77.players.name(playerId) or ("citizen #" .. tostring(playerId))
end

local function playerByIdentifier(identifier)
    for _, pid in ipairs(Open77.players.all()) do
        if Open77.players.identifier(pid) == identifier then return pid end
    end
    return nil
end

-- rp_jobs (optional, pcall'd: server exports raise when the resource is missing)
local function hasJob(playerId, job)
    local ok, r = pcall(function() return exports.rp_jobs:hasJob(playerId, job) end)
    return ok and r == true
end

local function isBoss(playerId)
    local ok, r = pcall(function() return exports.rp_jobs:isBoss(playerId) end)
    return ok and r == true
end

local function getJob(playerId)
    local ok, r = pcall(function() return exports.rp_jobs:getJob(playerId) end)
    if ok and type(r) == "string" then return r end
    return nil
end

local function onDuty(playerId)
    local ok, r = pcall(function() return exports.rp_jobs:onDuty(playerId) end)
    return ok and r == true
end

local function listOnDuty(job)
    local ok, r = pcall(function() return exports.rp_jobs:listOnDuty(job) end)
    if ok and type(r) == "table" then return r end
    return {}
end

-- open77_fuel (optional)
local function fuelLevel(vehicleId)
    local ok, litres = pcall(function() return exports.open77_fuel:level(vehicleId) end)
    if ok and type(litres) == "number" then return litres end
    return nil
end

local function fuelSet(vehicleId, litres)
    if type(litres) ~= "number" then return end
    pcall(function() return exports.open77_fuel:set(vehicleId, litres) end)
end

-- Money: account -> society (rp_bank:charge); cash fallback (rp_economy:remove) then the society
-- is credited so the eddies end in the same place. Returns "account" | "cash" | nil, reason.
local function pay(playerId, amount, society, reason)
    local okBank, balance, why = pcall(function() return exports.rp_bank:charge(playerId, amount, society, reason) end)
    if okBank and balance ~= nil then return "account" end
    local okCash, newCash, whyCash = pcall(function() return exports.rp_economy:remove(playerId, amount, reason) end)
    if okCash and newCash ~= nil then
        pcall(function() return exports.rp_bank:societyAdd(society, amount, reason) end)
        return "cash"
    end
    if not okBank and not okCash then return nil, "no_wallet" end
    if okCash and whyCash == "insufficient_funds" then return nil, "insufficient_funds" end
    if okBank and why then return nil, tostring(why) end
    if okCash and whyCash then return nil, tostring(whyCash) end
    return nil, "payment_refused"
end

local function societyPay(society, amount, reason)
    local ok, balance, why = pcall(function() return exports.rp_bank:societyRemove(society, amount, reason) end)
    if not ok then return nil, "bank_offline" end
    if balance == nil then return nil, tostring(why or "payment_refused") end
    return true
end

local function payWhy(reason)
    if reason == "insufficient_funds" or reason == "insufficient_cash" then
        return "Not enough eddies, choom: neither the account nor the pockets cover it."
    elseif reason == "no_wallet" then
        return "No bank and no wallet on this server: nobody can take your eddies."
    end
    return "Payment refused (" .. tostring(reason) .. ")."
end

-- ---------------------------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------------------------

local function newRow(plate, owner, ownerName, record, label)
    local at = now()
    return {
        plate = plate,
        owner = owner,             -- durable identifier, or "society:<job>"
        ownerName = ownerName,     -- RP name at the last write (offline lookups)
        record = record,
        label = label,
        state = "stored",          -- stored | out | impounded
        garage = "public",         -- garage id of the last store, or where it was bought
        props = nil,               -- Open77.vehicles.getProperties snapshot (table)
        fuel = nil,                -- litres, nil when open77_fuel is not running
        wanted = false,
        wantedReason = "",
        impoundReason = "",
        boughtAt = at,
        updatedAt = at,
        vehicleId = nil,           -- integer while state == "out"
    }
end

local function isSocietyOwner(owner)
    return type(owner) == "string" and owner:sub(1, #SOCIETY_PREFIX) == SOCIETY_PREFIX
end

local function societyOf(owner)
    if isSocietyOwner(owner) then return owner:sub(#SOCIETY_PREFIX + 1) end
    return nil
end

local function rowOfVehicle(vehicleId)
    if vehicleId == nil then return nil end
    local plate = live[tostring(vehicleId)]
    return plate and vehicles[plate] or nil
end

local function normalizePlate(text)
    if type(text) ~= "string" then return nil end
    local p = text:upper():gsub("%s", "")
    if p == "" then return nil end
    if p:sub(1, #Config.plate.prefix) ~= Config.plate.prefix then
        p = Config.plate.prefix .. p
    end
    return p
end

local function generatePlate()
    local alphabet = Config.plate.alphabet
    for _ = 1, 50 do
        local body = {}
        for i = 1, Config.plate.length do
            local k = math.random(1, #alphabet)
            body[i] = alphabet:sub(k, k)
        end
        local plate = Config.plate.prefix .. table.concat(body)
        if not vehicles[plate] then return plate end
    end
    return nil
end

local function paintText(props)
    local paint = props and props.paint
    if type(paint) ~= "table" or not paint.applied then return "" end
    local function hex(c)
        if type(c) ~= "table" then return "?" end
        return ("#%02X%02X%02X"):format(math.floor(c.r or c[1] or 0), math.floor(c.g or c[2] or 0), math.floor(c.b or c[3] or 0))
    end
    return hex(paint.primary) .. "/" .. hex(paint.secondary)
end

local function conditionText(row)
    local props = row.props
    local health = props and tonumber(props.health) or 1.0
    local fuel = row.fuel and ("%.0f L"):format(row.fuel) or "fuel n/a"
    return ("%d%% condition, %s"):format(math.floor(health * 100 + 0.5), fuel)
end

-- Who may open an owned vehicle: the owner, a key holder, or any employee of the owning society.
local function holdsKey(playerId, row)
    if not row then return false end
    local identifier = identifierOf(playerId)
    if not identifier then return false end
    if row.owner == identifier then return true end
    local holders = keys[row.plate]
    if holders and holders[identifier] then return true end
    local society = societyOf(row.owner)
    if society and hasJob(playerId, society) then return true end
    return false
end

local function isOwner(playerId, row)
    if not row then return false end
    local identifier = identifierOf(playerId)
    if not identifier then return false end
    if row.owner == identifier then return true end
    local society = societyOf(row.owner)
    if society and hasJob(playerId, society) and isBoss(playerId) then return true end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Persistence: SQL first, KVP fallback (write-through, callback forms only)
-- ---------------------------------------------------------------------------------------------

local SQL_VEHICLES = [[
CREATE TABLE IF NOT EXISTS rp_garage_vehicles (
    plate          VARCHAR(16)  NOT NULL PRIMARY KEY,
    owner          VARCHAR(64)  NOT NULL,
    owner_name     VARCHAR(80)  NOT NULL DEFAULT '',
    record         VARCHAR(256) NOT NULL,
    label          VARCHAR(64)  NOT NULL DEFAULT '',
    state          VARCHAR(16)  NOT NULL DEFAULT 'stored',
    garage         VARCHAR(32)  NOT NULL DEFAULT 'public',
    paint          VARCHAR(32)  NOT NULL DEFAULT '',
    fuel           DOUBLE       NULL,
    props          TEXT         NULL,
    wanted         TINYINT(1)   NOT NULL DEFAULT 0,
    wanted_reason  VARCHAR(64)  NOT NULL DEFAULT '',
    impound_reason VARCHAR(64)  NOT NULL DEFAULT '',
    bought_at      BIGINT       NOT NULL DEFAULT 0,
    updated_at     BIGINT       NOT NULL DEFAULT 0,
    INDEX rp_garage_vehicles_owner (owner)
)]]

local SQL_KEYS = [[
CREATE TABLE IF NOT EXISTS rp_garage_keys (
    plate       VARCHAR(16) NOT NULL,
    holder      VARCHAR(64) NOT NULL,
    holder_name VARCHAR(80) NOT NULL DEFAULT '',
    given_by    VARCHAR(64) NOT NULL DEFAULT '',
    at          BIGINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (plate, holder)
)]]

local SQL_UPSERT = [[
INSERT INTO rp_garage_vehicles
    (plate, owner, owner_name, record, label, state, garage, paint, fuel, props, wanted, wanted_reason, impound_reason, bought_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE
    owner = VALUES(owner), owner_name = VALUES(owner_name), record = VALUES(record), label = VALUES(label),
    state = VALUES(state), garage = VALUES(garage), paint = VALUES(paint), fuel = VALUES(fuel),
    props = VALUES(props), wanted = VALUES(wanted), wanted_reason = VALUES(wanted_reason),
    impound_reason = VALUES(impound_reason), bought_at = VALUES(bought_at), updated_at = VALUES(updated_at)]]

local function rowToPlain(row)
    return {
        plate = row.plate, owner = row.owner, ownerName = row.ownerName, record = row.record,
        label = row.label, state = row.state, garage = row.garage, props = row.props, fuel = row.fuel,
        wanted = row.wanted, wantedReason = row.wantedReason, impoundReason = row.impoundReason,
        boughtAt = row.boughtAt, updatedAt = row.updatedAt,
    }
end

local function persistVehicle(row)
    row.updatedAt = now()
    if store.mode == "sql" then
        -- No nil holes in a params array (the bridge stops at the first one): an unknown fuel
        -- level travels as -1 and empty props as "", both mapped back to nil when the row loads.
        local propsJson = row.props and json.encode(row.props) or ""
        Open77.database.update(SQL_UPSERT, {
            row.plate, row.owner, row.ownerName or "", row.record, row.label or "", row.state, row.garage or "public",
            paintText(row.props), row.fuel or -1, propsJson, row.wanted and 1 or 0, row.wantedReason or "",
            row.impoundReason or "", row.boughtAt or 0, row.updatedAt,
        }, function(result)
            if result == nil then log("SQL write failed for plate %s", row.plate) end
        end)
    elseif store.mode == "kvp" then
        local encoded = json.encode(rowToPlain(row))
        if encoded then Open77.kvp.set("veh:" .. row.plate, encoded) end
    end
end

local function persistKeys(plate)
    if store.mode == "kvp" then
        local list = {}
        for holder, entry in pairs(keys[plate] or {}) do
            list[#list + 1] = { holder = holder, name = entry.name, givenBy = entry.givenBy, at = entry.at }
        end
        local encoded = json.encode(list)
        if encoded then Open77.kvp.set("keys:" .. plate, encoded) end
    end
end

local function persistKeyAdd(plate, holder, entry)
    if store.mode == "sql" then
        Open77.database.update(
            "INSERT IGNORE INTO rp_garage_keys (plate, holder, holder_name, given_by, at) VALUES (?, ?, ?, ?, ?)",
            { plate, holder, entry.name or "", entry.givenBy or "", entry.at or 0 },
            function(result)
                if result == nil then log("SQL key write failed for plate %s", plate) end
            end)
    else
        persistKeys(plate)
    end
end

local function persistKeyClear(plate)
    if store.mode == "sql" then
        Open77.database.update("DELETE FROM rp_garage_keys WHERE plate = ?", { plate }, function() end)
    else
        persistKeys(plate)
    end
end

local function adoptRow(plain)
    local row = newRow(plain.plate, plain.owner, plain.ownerName or plain.owner_name or "", plain.record, plain.label or "")
    row.state = plain.state or "stored"
    row.garage = plain.garage or "public"
    row.props = type(plain.props) == "table" and plain.props or nil
    row.fuel = tonumber(plain.fuel)
    if row.fuel and row.fuel < 0 then row.fuel = nil end   -- -1 = unknown (see persistVehicle)
    row.wanted = plain.wanted == true or plain.wanted == 1
    row.wantedReason = plain.wantedReason or plain.wanted_reason or ""
    row.impoundReason = plain.impoundReason or plain.impound_reason or ""
    row.boughtAt = tonumber(plain.boughtAt or plain.bought_at) or 0
    row.updatedAt = tonumber(plain.updatedAt or plain.updated_at) or 0
    -- The world is empty after a restart (and a resource stop removes the vehicles it created):
    -- whatever was out is back in the garage.
    if row.state == "out" then row.state = "stored" end
    return row
end

local function loadFromSql()
    Open77.database.update.await(SQL_VEHICLES)
    Open77.database.update.await(SQL_KEYS)
    local rows = Open77.database.query.await("SELECT * FROM rp_garage_vehicles") or {}
    local count = 0
    for _, r in ipairs(rows) do
        local plain = {
            plate = r.plate, owner = r.owner, ownerName = r.owner_name, record = r.record, label = r.label,
            state = r.state, garage = r.garage, fuel = r.fuel, wanted = r.wanted, wantedReason = r.wanted_reason,
            impoundReason = r.impound_reason, boughtAt = r.bought_at, updatedAt = r.updated_at,
        }
        if type(r.props) == "string" and r.props ~= "" then
            plain.props = json.decode(r.props)
            if not plain.props then log("corrupt props column for plate %s, condition reset", tostring(r.plate)) end
        end
        if type(plain.plate) == "string" and type(plain.owner) == "string" and type(plain.record) == "string" then
            vehicles[plain.plate] = adoptRow(plain)
            count = count + 1
        end
    end
    local krows = Open77.database.query.await("SELECT plate, holder, holder_name, given_by, at FROM rp_garage_keys") or {}
    local keyCount = 0
    for _, k in ipairs(krows) do
        if vehicles[k.plate] then
            keys[k.plate] = keys[k.plate] or {}
            keys[k.plate][k.holder] = { name = k.holder_name or "", givenBy = k.given_by or "", at = tonumber(k.at) or 0 }
            keyCount = keyCount + 1
        end
    end
    store.mode = "sql"
    log("store=sql tables=rp_garage_vehicles,rp_garage_keys vehicles=%d keys=%d", count, keyCount)
    -- Rows that were `out` at the last shutdown were read back as `stored` (adoptRow): write that
    -- through, so rp_mdt's direct SELECTs on rp_garage_vehicles do not keep showing `out`.
    for _, r in ipairs(rows) do
        local row = vehicles[r.plate]
        if row and r.state == "out" then persistVehicle(row) end
    end
end

local function loadFromKvp(reason)
    store.mode = "kvp"
    store.reason = reason
    local count, keyCount = 0, 0
    for _, key in ipairs(Open77.kvp.keys("veh:") or {}) do
        local raw = Open77.kvp.get(key)
        local plain = type(raw) == "string" and json.decode(raw) or nil
        if type(plain) == "table" and type(plain.plate) == "string" and type(plain.owner) == "string" and type(plain.record) == "string" then
            vehicles[plain.plate] = adoptRow(plain)
            count = count + 1
            local rawKeys = Open77.kvp.get("keys:" .. plain.plate)
            local list = type(rawKeys) == "string" and json.decode(rawKeys) or nil
            if type(list) == "table" then
                keys[plain.plate] = {}
                for _, entry in ipairs(list) do
                    if type(entry.holder) == "string" then
                        keys[plain.plate][entry.holder] = { name = entry.name or "", givenBy = entry.givenBy or "", at = tonumber(entry.at) or 0 }
                        keyCount = keyCount + 1
                    end
                end
            end
        end
    end
    log("store=kvp reason=%s vehicles=%d keys=%d", tostring(reason), count, keyCount)
end

local function startStore()
    local ok, reason = Open77.database.ready(function()
        if store.mode ~= "pending" then
            log("database answered late, keeping store=%s for this boot", store.mode)
            return
        end
        loadFromSql()
    end)
    if not ok then
        loadFromKvp(reason or "database_unavailable")
        return
    end
    -- Configured but not answering 15 s after start: fall back for the whole boot.
    CreateThread(function()
        Wait(15000)
        if store.mode == "pending" then
            local _, why = Open77.database.isReady()
            loadFromKvp(why or "database_unreachable")
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- The plate on the vehicle, the lock and the keys
-- ---------------------------------------------------------------------------------------------

local function writePlate(vehicleId, plate)
    local ok, result, reason = pcall(function()
        local bag, why = Open77.state.entity("vehicle", vehicleId)
        if not bag then return false, why end
        return bag:set("plate", plate)
    end)
    if ok and result == true then return true end
    if not plateWriteWarned then
        plateWriteWarned = true
        log("plate state bag refused: %s (the plate stays in SQL, /plaque and the exports still answer)",
            tostring(ok and reason or result))
    end
    return false
end

-- The street sees a locked car; everybody holding a key gets a per-player exception.
local function applyKeyExceptions(row)
    if row.state ~= "out" or not row.vehicleId then return end
    for _, pid in ipairs(Open77.players.all()) do
        if holdsKey(pid, row) then
            Open77.vehicles.setLockedForPlayer(row.vehicleId, pid, false)
        end
    end
end

local function grantException(row, playerId)
    if row.state == "out" and row.vehicleId then
        Open77.vehicles.setLockedForPlayer(row.vehicleId, playerId, false)
    end
end

local function revokeExceptions(row, holders)
    if row.state ~= "out" or not row.vehicleId then return end
    for holder in pairs(holders) do
        local pid = playerByIdentifier(holder)
        if pid then Open77.vehicles.setLockedForPlayer(row.vehicleId, pid, nil) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Spawning and snapshots
-- ---------------------------------------------------------------------------------------------

local function freeSpot(spawnPoint, bucket)
    for i = 0, Config.spawnTries - 1 do
        local p = { x = spawnPoint.x + i * Config.spawnStep, y = spawnPoint.y, z = spawnPoint.z }
        local near = Open77.vehicles.nearby(p, Config.spawnClearance, { limit = 1, bucket = bucket or false })
        if near == nil or #near == 0 then return p end
    end
    return nil
end

-- Sanitise a stored snapshot before it goes back on a fresh car: a wreck comes back rolling,
-- the engine is off, the car is locked for the street (key holders get exceptions).
local function restorableProps(row)
    local props = row.props
    if type(props) ~= "table" then return nil end
    props.record = row.record
    props.engineOn = false
    props.siren = false
    props.lights = "off"
    props.locked = true
    props.drivable = true
    if type(props.damage) == "table" then
        props.damage.destroyed = false
        props.damage.exploded = false
    end
    local health = tonumber(props.health) or 1.0
    if health < Config.minHealthOnTakeOut then health = Config.minHealthOnTakeOut end
    props.health = health
    return props
end

-- Creates the row's vehicle in the world. Returns vehicleId | nil, reason.
local function spawnRow(row, spawnPoint, bucket, playerId)
    local spot = freeSpot(spawnPoint, bucket)
    if not spot then return nil, "bay_blocked" end
    local id, reason = Open77.vehicles.create({
        record = row.record,
        position = spot,
        yaw = spawnPoint.yaw or 0.0,
        bucket = bucket or 0,
        health = 1.0,
        flags = Open77.vehicles.flags.locked,
    })
    if not id then return nil, "spawn_failed:" .. tostring(reason) end
    local props = restorableProps(row)
    local restored = true
    if props then
        local ok, why = Open77.vehicles.setProperties(id, props, { ignoreUnsupported = true })
        if not ok then
            restored = false
            log("condition of %s not restored: %s", row.plate, tostring(why))
        end
    end
    fuelSet(id, row.fuel)
    writePlate(id, row.plate)
    row.state = "out"
    row.vehicleId = id
    live[tostring(id)] = row.plate
    applyKeyExceptions(row)
    if playerId then Open77.vehicles.setLockedForPlayer(id, playerId, false) end
    return id, restored
end

local function snapshotRow(row)
    if row.state ~= "out" or not row.vehicleId then return end
    local props = Open77.vehicles.getProperties(row.vehicleId)
    if type(props) == "table" then row.props = props end
    local litres = fuelLevel(row.vehicleId)
    if litres then row.fuel = litres end
end

-- Takes the vehicle out of the world and keeps its state. `nextState` is stored | impounded.
local function retireRow(row, nextState, garageId, reason)
    local id = row.vehicleId
    if id then
        snapshotRow(row)
        live[tostring(id)] = nil
        row.vehicleId = nil
        Open77.vehicles.remove(id)
    end
    row.state = nextState
    if garageId then row.garage = garageId end
    if nextState == "impounded" then
        row.impoundReason = reason or ""
    else
        row.impoundReason = ""
    end
    persistVehicle(row)
end

local function tellOwner(row, text)
    if isSocietyOwner(row.owner) then
        for _, pid in ipairs(listOnDuty(societyOf(row.owner))) do
            local n = toPlayerId(pid)
            if n then say(n, text) end
        end
        return
    end
    local pid = playerByIdentifier(row.owner)
    if pid then say(pid, text) end
end

-- ---------------------------------------------------------------------------------------------
-- Lookups around a player
-- ---------------------------------------------------------------------------------------------

local function seatedRow(playerId)
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    if not seat then return nil, nil end
    return rowOfVehicle(seat.vehicleId), seat
end

-- Nearest tracked vehicle within `radius` that satisfies `predicate(row)`; second value is the
-- nearest tracked vehicle that failed it (so the player can be told why), third the nearest
-- untracked server vehicle entry.
local function nearestTracked(playerId, radius, predicate)
    local list = Open77.vehicles.nearby(playerId, radius) or {}
    local refused, untracked = nil, nil
    for _, entry in ipairs(list) do
        local row = rowOfVehicle(entry.id)
        if row then
            if predicate == nil or predicate(row) then return row, entry end
            if not refused then refused = row end
        elseif not untracked then
            untracked = entry
        end
    end
    return nil, refused, untracked
end

local function garageNear(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then return nil end
    local best, bestDistance = nil, nil
    for _, g in ipairs(Config.garages) do
        local d = planar(pos, g.position)
        if d <= Config.reach.garage and math.abs(pos.z - g.position.z) <= Config.reach.height then
            if not bestDistance or d < bestDistance then best, bestDistance = g, d end
        end
    end
    return best, pos
end

local function garageById(id)
    for _, g in ipairs(Config.garages) do
        if g.id == id then return g end
    end
    return nil
end

local function atDealership(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then return false end
    local d = planar(pos, Config.dealership.position)
    return d <= Config.reach.garage and math.abs(pos.z - Config.dealership.position.z) <= Config.reach.height, pos
end

local function storeReady(playerId)
    if store.mode == "pending" then
        warn(playerId, "The garage registry is still loading. Try again in a few seconds.")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- UI kit server twins
-- ---------------------------------------------------------------------------------------------

local function uikit(name, playerId, ...)
    local promise, err = Open77.exports.call("open77_uikit", name, playerId, ...)
    if not promise then return nil, err end
    return promise:await()
end

-- One dialog per player at a time. Open77.time.monotonic() counts seconds; a claim older than
-- the two dialog timeouts is stale (the handler died) and is taken over.
local function claimMenu(playerId)
    local opened = menuBusy[playerId]
    local seconds = Open77.time.monotonic()
    if opened and (seconds - opened) < ((Config.menuTimeoutMs + Config.confirmTimeoutMs) / 1000 + 10) then
        warn(playerId, "Finish what's on your screen first.")
        return false
    end
    menuBusy[playerId] = seconds
    return true
end

local function releaseMenu(playerId)
    menuBusy[playerId] = nil
end

local function confirm(playerId, title, message, button)
    local answer, why = uikit("alert", playerId, {
        title = title, message = message, confirm = button, cancel = "Walk away",
        tone = "warning", timeoutMs = Config.confirmTimeoutMs,
    })
    if not answer then
        warn(playerId, "The confirmation could not be shown (" .. tostring(why) .. ").")
        return false
    end
    return answer.ok == true
end

-- ---------------------------------------------------------------------------------------------
-- Actions: buy, store, take out, release
-- ---------------------------------------------------------------------------------------------

local function buy(playerId, item, forSociety)
    local identifier = identifierOf(playerId)
    if not identifier then return warn(playerId, "Unknown identity: reconnect.") end
    -- The plate is reserved before any eddies move, so a refund is never needed.
    local plate = generatePlate()
    if not plate then return warn(playerId, "The DMV ran out of plates. Come back later.", "Dealer") end
    local owner, ownerName = identifier, displayName(playerId)
    local paidWith
    if forSociety then
        local ok, why = societyPay(forSociety, item.price, "purchase:" .. item.record)
        if not ok then
            return warn(playerId, ("The %s society cannot pay %s: %s."):format(forSociety, eddies(item.price), tostring(why)), "Dealer")
        end
        owner, ownerName, paidWith = SOCIETY_PREFIX .. forSociety, forSociety .. " society", "society funds"
    else
        local how, why = pay(playerId, item.price, Config.society, "purchase:" .. item.record)
        if not how then return warn(playerId, payWhy(why), "Dealer") end
        paidWith = how
    end
    local row = newRow(plate, owner, ownerName, item.record, item.label)
    row.garage = "dealership"
    vehicles[plate] = row
    local pos = Open77.players.position(playerId)
    local id, detail = spawnRow(row, Config.dealership.spawnPoint, pos and pos.bucket or 0, playerId)
    if not id then
        row.state = "stored"
        row.garage = "public"
        persistVehicle(row)
        warn(playerId, ("The forecourt is blocked (%s): your %s is waiting at the public garage."):format(tostring(detail), item.label), "Dealer")
    else
        persistVehicle(row)
        say(playerId, ("Congrats, choom: %s, plate %s, paid %s (%s). It is locked for the street; you hold the keys."):format(
            item.label, plate, eddies(item.price), paidWith), "Dealer")
        toast(playerId, "success", "Dealership", ("%s - plate %s"):format(item.label, plate))
    end
    log("player %d bought %s (%s) plate=%s owner=%s paid=%s", playerId, item.label, item.record, plate, owner, paidWith)
    TriggerEvent("rp_garage:changed", owner, plate, "bought")
end

local function storeVehicle(playerId, garage)
    local seated = seatedRow(playerId)
    if seated then return warn(playerId, "Step out first: a garage takes an empty car.") end
    local row, refused, untracked = nearestTracked(playerId, Config.reach.store, function(r) return holdsKey(playerId, r) end)
    if not row then
        if refused then return warn(playerId, ("The %s (plate %s) is not yours and you hold no key for it."):format(refused.label, refused.plate)) end
        if untracked then return warn(playerId, "That ride has no plate on file: only an owned vehicle can be stored.") end
        return warn(playerId, ("No vehicle of yours within %.0f m."):format(Config.reach.store))
    end
    if garage.kind == "society" and isSocietyOwner(row.owner) and societyOf(row.owner) ~= garage.society then
        return warn(playerId, "That fleet vehicle belongs to another crew.")
    end
    local car = Open77.vehicles.get(row.vehicleId)
    if car and car.occupants and #car.occupants > 0 then
        return warn(playerId, ("Somebody is still inside the %s."):format(row.label))
    end
    retireRow(row, "stored", garage.id)
    say(playerId, ("%s (plate %s) stored at the %s: %s."):format(row.label, row.plate, garage.label, conditionText(row)))
    toast(playerId, "info", garage.label, ("%s stored"):format(row.label))
    log("player %d stored %s plate=%s at %s", playerId, row.label, row.plate, garage.id)
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "stored")
end

local function takeOut(playerId, row, garage)
    if row.state ~= "stored" then
        return warn(playerId, ("The %s (plate %s) is not in the garage (%s)."):format(row.label, row.plate, row.state))
    end
    if not holdsKey(playerId, row) then return warn(playerId, "You hold no key for that vehicle.") end
    local pos = Open77.players.position(playerId)
    local id, detail = spawnRow(row, garage.spawnPoint, pos and pos.bucket or 0, playerId)
    if not id then
        return warn(playerId, ("The bay is blocked (%s): move the vehicles standing in front of the %s."):format(tostring(detail), garage.label))
    end
    row.garage = garage.id
    persistVehicle(row)
    say(playerId, ("%s (plate %s) is out at the %s bay: %s.%s"):format(row.label, row.plate, garage.label, conditionText(row),
        detail == false and " Condition could not be fully restored." or ""))
    toast(playerId, "success", garage.label, ("%s ready"):format(row.label))
    log("player %d took out %s plate=%s at %s vehicle=%s", playerId, row.label, row.plate, garage.id, tostring(id))
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "taken_out")
end

local function releaseImpounded(playerId, row, garage)
    if row.state ~= "impounded" then return warn(playerId, "That vehicle is not at the impound lot.") end
    if not isOwner(playerId, row) then return warn(playerId, "Only the owner can settle the impound.") end
    if not confirm(playerId, ("Release the %s?"):format(row.label),
        ("The NCPD impound lot wants %s to hand the %s (plate %s) back. Reason on file: %s."):format(
            eddies(Config.impound.fee), row.label, row.plate, row.impoundReason ~= "" and row.impoundReason or "none"),
        "Pay " .. eddies(Config.impound.fee)) then
        return say(playerId, "The vehicle stays at the impound lot.")
    end
    if row.state ~= "impounded" then return warn(playerId, "Somebody already settled it.") end
    local how, why
    local society = societyOf(row.owner)
    if society then
        local ok, sWhy = societyPay(society, Config.impound.fee, "impound:" .. row.plate)
        how, why = ok and "society funds" or nil, sWhy
        if ok then pcall(function() return exports.rp_bank:societyAdd(Config.impound.society, Config.impound.fee, "impound:" .. row.plate) end) end
    else
        how, why = pay(playerId, Config.impound.fee, Config.impound.society, "impound:" .. row.plate)
    end
    if not how then return warn(playerId, payWhy(why)) end
    row.state = "stored"
    row.impoundReason = ""
    row.garage = garage.id
    persistVehicle(row)
    say(playerId, ("Impound settled (%s, %s): the %s (plate %s) is back in the %s."):format(eddies(Config.impound.fee), how, row.label, row.plate, garage.label))
    log("player %d released %s plate=%s fee=%d (%s)", playerId, row.label, row.plate, Config.impound.fee, how)
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "released")
end

-- ---------------------------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------------------------

local function ownedRows(playerId, garage)
    local identifier = identifierOf(playerId)
    local list = {}
    for _, row in pairs(vehicles) do
        local mine = row.owner == identifier
        local fleet = garage and garage.kind == "society" and row.owner == SOCIETY_PREFIX .. garage.society
        if mine or fleet then list[#list + 1] = row end
    end
    table.sort(list, function(a, b) return a.plate < b.plate end)
    return list
end

local function openGarage(playerId, garage)
    if not storeReady(playerId) then return end
    if garage.kind == "society" and not hasJob(playerId, garage.society) then
        return warn(playerId, ("This bay is for the %s crew. The public lot is 12 m west, on the Afterlife street."):format(garage.society))
    end
    if not claimMenu(playerId) then return end
    local options = {}
    local candidate = nearestTracked(playerId, Config.reach.store, function(r) return holdsKey(playerId, r) end)
    if candidate and not seatedRow(playerId) then
        options[#options + 1] = {
            id = "store", label = ("Store the %s"):format(candidate.label), icon = "P",
            description = ("Plate %s, within %.0f m. State saved, vehicle removed."):format(candidate.plate, Config.reach.store),
        }
    end
    local rows = ownedRows(playerId, garage)
    for _, row in ipairs(rows) do
        local fleet = isSocietyOwner(row.owner) and " [fleet]" or ""
        if row.state == "stored" then
            options[#options + 1] = {
                id = "out:" .. row.plate, label = ("Take out the %s%s"):format(row.label, fleet), icon = "V",
                description = conditionText(row),
                metadata = { { label = "Plate", value = row.plate }, { label = "Wanted", value = row.wanted and "YES" or "no" } },
            }
        elseif row.state == "impounded" then
            options[#options + 1] = {
                id = "release:" .. row.plate, label = ("Impound: %s%s"):format(row.label, fleet), icon = "I", tone = "danger",
                description = ("Held by the NCPD (%s). Pay %s to get it back."):format(row.impoundReason ~= "" and row.impoundReason or "no reason on file", eddies(Config.impound.fee)),
                metadata = { { label = "Plate", value = row.plate }, { label = "Fee", value = eddies(Config.impound.fee) } },
            }
        else
            options[#options + 1] = {
                id = "outside:" .. row.plate, label = ("%s%s is out in the city"):format(row.label, fleet), icon = "O", disabled = true,
                description = "Bring it within 8 m of a garage to store it.",
                metadata = { { label = "Plate", value = row.plate } },
            }
        end
    end
    options[#options + 1] = { id = "leave", label = "Leave", icon = "X" }
    local answer, why = uikit("context", playerId, {
        id = "rp_garage_menu",
        title = garage.label,
        description = #rows == 0 and "No vehicle on file. The dealership sells them." or ("%d vehicle(s) on file."):format(#rows),
        options = options,
    }, { timeoutMs = Config.menuTimeoutMs })
    if not answer then
        releaseMenu(playerId)
        return warn(playerId, "The garage menu could not be opened (" .. tostring(why) .. ").")
    end
    if not answer.ok or not answer.value then
        releaseMenu(playerId)
        return
    end
    local choice = tostring(answer.value.id or "")
    -- Everything is re-checked: the player may have walked away while the menu was open.
    local still = garageNear(playerId)
    if not still or still.id ~= garage.id then
        releaseMenu(playerId)
        return warn(playerId, ("Come back within %.0f m of the %s."):format(Config.reach.garage, garage.label))
    end
    if choice == "store" then
        storeVehicle(playerId, garage)
    elseif choice:sub(1, 4) == "out:" then
        local row = vehicles[choice:sub(5)]
        if row then takeOut(playerId, row, garage) else warn(playerId, "That vehicle is gone from the registry.") end
    elseif choice:sub(1, 8) == "release:" then
        local row = vehicles[choice:sub(9)]
        if row then releaseImpounded(playerId, row, garage) else warn(playerId, "That vehicle is gone from the registry.") end
    end
    releaseMenu(playerId)
end

local function openDealership(playerId)
    if not storeReady(playerId) then return end
    if not claimMenu(playerId) then return end
    local options = {}
    for i, item in ipairs(Config.vehicles) do
        local data = Open77.data.vehicle(item.record)
        local desc = data and ("%s, %d seat(s)"):format(data.classLabel or data.class or "vehicle", tonumber(data.seats) or 0) or "Night City classic"
        options[#options + 1] = {
            id = "buy:" .. i, label = item.label, icon = "B",
            description = desc,
            metadata = { { label = "Price", value = eddies(item.price) } },
        }
    end
    local job = getJob(playerId)
    local fleetGarage
    if job and isBoss(playerId) then
        for _, g in ipairs(Config.garages) do
            if g.kind == "society" and g.society == job then fleetGarage = g end
        end
    end
    if fleetGarage then
        for i, item in ipairs(Config.vehicles) do
            options[#options + 1] = {
                id = "fleet:" .. i, label = ("%s for the %s fleet"):format(item.label, job), icon = "F",
                description = ("Paid by the %s society, parked at the %s."):format(job, fleetGarage.label),
                metadata = { { label = "Price", value = eddies(item.price) } },
            }
        end
    end
    options[#options + 1] = { id = "leave", label = "Leave", icon = "X" }
    local answer, why = uikit("context", playerId, {
        id = "rp_garage_dealer",
        title = Config.dealership.label,
        description = "Every ride comes with a plate and a set of keys. Account first, cash if the account is short.",
        options = options,
    }, { timeoutMs = Config.menuTimeoutMs })
    if not answer then
        releaseMenu(playerId)
        return warn(playerId, "The dealership menu could not be opened (" .. tostring(why) .. ").", "Dealer")
    end
    if not answer.ok or not answer.value then
        releaseMenu(playerId)
        return
    end
    local choice = tostring(answer.value.id or "")
    local kind, index = choice:match("^(%a+):(%d+)$")
    local item = index and Config.vehicles[tonumber(index)] or nil
    if not item then
        releaseMenu(playerId)
        return
    end
    local forSociety = kind == "fleet" and fleetGarage and fleetGarage.society or nil
    local title = ("Buy the %s?"):format(item.label)
    local message = forSociety
        and ("%s from the %s society funds. Every employee will hold a key."):format(eddies(item.price), forSociety)
        or ("%s from your account (cash if the account is short). Plate and keys included, no refunds."):format(eddies(item.price))
    if not confirm(playerId, title, message, "Buy") then
        releaseMenu(playerId)
        return say(playerId, "Maybe next payday, choom.", "Dealer")
    end
    if not atDealership(playerId) then
        releaseMenu(playerId)
        return warn(playerId, "Come back to the dealership to sign.", "Dealer")
    end
    if forSociety and not isBoss(playerId) then
        releaseMenu(playerId)
        return warn(playerId, "Only the boss signs for the fleet.", "Dealer")
    end
    buy(playerId, item, forSociety)
    releaseMenu(playerId)
end

-- ---------------------------------------------------------------------------------------------
-- Keys, lock, plate
-- ---------------------------------------------------------------------------------------------

-- The vehicle a key command refers to: an explicit plate, else the one the player sits in, else
-- the nearest owned vehicle within reach. Returns row | nil, message.
local function ownedVehicleFor(playerId, plateArg, reach)
    if plateArg then
        local plate = normalizePlate(plateArg)
        local row = plate and vehicles[plate]
        if not row then return nil, ("No vehicle with plate %s on file."):format(tostring(plate or plateArg)) end
        if not isOwner(playerId, row) then return nil, ("The %s (plate %s) is not yours."):format(row.label, row.plate) end
        return row
    end
    local seated = seatedRow(playerId)
    if seated then
        if not isOwner(playerId, seated) then return nil, ("The %s you sit in (plate %s) is not yours."):format(seated.label, seated.plate) end
        return seated
    end
    local row, refused = nearestTracked(playerId, reach, function(r) return isOwner(playerId, r) end)
    if row then return row end
    if refused then return nil, ("The %s (plate %s) is not yours."):format(refused.label, refused.plate) end
    return nil, ("No vehicle of yours within %.0f m. Sit in it, or give the plate: /cles <playerId> <plate>."):format(reach)
end

local function giveKey(playerId, targetId, plateArg)
    if not storeReady(playerId) then return end
    if not targetId or targetId == playerId then return warn(playerId, "Usage: /cles <playerId> [plate] - somebody else, within 5 m.") end
    if not Open77.players.name(targetId) then return warn(playerId, ("No player with id %d online."):format(targetId)) end
    local metres = Open77.players.distance(playerId, targetId)
    if not metres or metres > Config.reach.key then
        return warn(playerId, ("%s is too far away (%s m): keys change hands within %.0f m."):format(displayName(targetId), metres and ("%.1f"):format(metres) or "?", Config.reach.key))
    end
    local row, why = ownedVehicleFor(playerId, plateArg, Config.reach.keyVehicle)
    if not row then return warn(playerId, why) end
    if isSocietyOwner(row.owner) then return warn(playerId, "Fleet vehicles come with a key for every employee already.") end
    local holder = identifierOf(targetId)
    if not holder then return warn(playerId, "That player has no identity yet.") end
    keys[row.plate] = keys[row.plate] or {}
    if keys[row.plate][holder] then return say(playerId, ("%s already holds a key for the %s."):format(displayName(targetId), row.label)) end
    local entry = { name = displayName(targetId), givenBy = identifierOf(playerId) or "", at = now() }
    keys[row.plate][holder] = entry
    persistKeyAdd(row.plate, holder, entry)
    grantException(row, targetId)
    say(playerId, ("Key of the %s (plate %s) handed to %s."):format(row.label, row.plate, entry.name))
    say(targetId, ("%s handed you a key of their %s (plate %s). /verrouiller works on it now."):format(displayName(playerId), row.label, row.plate))
    log("player %d gave a key of plate %s to player %d (%s)", playerId, row.plate, targetId, holder)
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "key_given")
end

local function revokeKeys(playerId, plateArg)
    if not storeReady(playerId) then return end
    local row, why = ownedVehicleFor(playerId, plateArg, Config.reach.keyVehicle)
    if not row then return warn(playerId, why) end
    local holders = keys[row.plate] or {}
    local count = 0
    for _ in pairs(holders) do count = count + 1 end
    if count == 0 then return say(playerId, ("Nobody else holds a key of the %s (plate %s)."):format(row.label, row.plate)) end
    revokeExceptions(row, holders)
    keys[row.plate] = {}
    persistKeyClear(row.plate)
    say(playerId, ("%d duplicate key(s) of the %s (plate %s) cancelled."):format(count, row.label, row.plate))
    log("player %d revoked %d key(s) of plate %s", playerId, count, row.plate)
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "keys_revoked")
end

local function listKeys(playerId)
    if not storeReady(playerId) then return end
    local rows = ownedRows(playerId, nil)
    if #rows == 0 then return say(playerId, "No vehicle on file. Westbrook Motors sells them.") end
    say(playerId, ("%d vehicle(s) on file:"):format(#rows))
    for _, row in ipairs(rows) do
        Wait(0)
        local names = {}
        for _, entry in pairs(keys[row.plate] or {}) do names[#names + 1] = entry.name ~= "" and entry.name or "?" end
        table.sort(names)
        local holders = #names > 0 and ("keys: " .. table.concat(names, ", ")) or "no duplicate key"
        say(playerId, ("  %s - %s - %s - %s%s"):format(row.plate, row.label, row.state, holders, row.wanted and " - WANTED" or ""))
    end
end

local function toggleLock(playerId, vehicleId)
    if not storeReady(playerId) then return end
    local row, refused, untracked
    if vehicleId then
        row = rowOfVehicle(vehicleId)
        if not row then return warn(playerId, "That ride has no plate on file: nothing to lock with a key.") end
        if not holdsKey(playerId, row) then return warn(playerId, ("The %s (plate %s) is not yours and you hold no key."):format(row.label, row.plate)) end
        local d = Open77.players.distance(playerId, Open77.vehicles.getPosition(row.vehicleId) or {})
        if not d or d > Config.reach.lock then return warn(playerId, ("Get within %.0f m of the %s."):format(Config.reach.lock, row.label)) end
    else
        row = seatedRow(playerId)
        if row and not holdsKey(playerId, row) then
            return warn(playerId, ("The %s you sit in (plate %s) is not yours."):format(row.label, row.plate))
        end
        if not row then
            row, refused, untracked = nearestTracked(playerId, Config.reach.lock, function(r) return holdsKey(playerId, r) end)
        end
        if not row then
            if refused then return warn(playerId, ("The %s (plate %s) is not yours and you hold no key."):format(refused.label, refused.plate)) end
            if untracked then return warn(playerId, "That ride has no plate on file: /lock still works on it, keys do not.") end
            return warn(playerId, ("No vehicle of yours within %.0f m."):format(Config.reach.lock))
        end
    end
    local locked = Open77.vehicles.isLocked(row.vehicleId)
    if locked == nil then return warn(playerId, "That vehicle is gone.") end
    local ok, why = Open77.vehicles.setLocked(row.vehicleId, not locked)
    if not ok then return warn(playerId, "Lock refused: " .. tostring(why)) end
    Open77.vehicles.triggerHorn(row.vehicleId, 150)
    say(playerId, ("%s (plate %s) %s."):format(row.label, row.plate, locked and "unlocked" or "locked for the street"))
    log("player %d %s plate %s", playerId, locked and "unlocked" or "locked", row.plate)
end

local function readPlate(playerId, vehicleId)
    local row, entry
    if vehicleId then
        row = rowOfVehicle(vehicleId)
        if not row then
            local car = Open77.vehicles.get(vehicleId)
            if not car then return warn(playerId, "That vehicle is gone.", "DMV") end
            return say(playerId, ("No plate on file: an unregistered ride (%s)."):format(car.record or "?"), "DMV")
        end
    else
        local seated = seatedRow(playerId)
        if seated then
            row = seated
        else
            local seat = Open77.vehicles.getPlayerSeat(playerId)
            if seat then
                return say(playerId, "No plate on file: an unregistered ride.", "DMV")
            end
            local nearest = Open77.vehicles.closest(playerId, { radius = Config.reach.plate })
            if not nearest then return warn(playerId, ("No server vehicle within %.0f m (vanilla traffic has no plate)."):format(Config.reach.plate), "DMV") end
            row = rowOfVehicle(nearest.id)
            entry = nearest
            if not row then return say(playerId, ("No plate on file: an unregistered ride (%s, %.1f m)."):format(nearest.record or "?", nearest.distance or 0), "DMV") end
        end
    end
    local owner = row.ownerName ~= "" and row.ownerName or "unknown citizen"
    if isSocietyOwner(row.owner) then owner = ("%s society fleet"):format(societyOf(row.owner)) end
    local yours = holdsKey(playerId, row) and " - you hold a key" or ""
    say(playerId, ("Plate %s - %s - owner: %s%s%s."):format(row.plate, row.label, owner, yours, entry and (" - %.1f m"):format(entry.distance or 0) or ""), "DMV")
    if row.wanted then
        local reason = (hasJob(playerId, "ncpd") and onDuty(playerId)) and (": " .. (row.wantedReason ~= "" and row.wantedReason or "no reason on file")) or " by the NCPD"
        Wait(0)
        warn(playerId, ("WANTED%s."):format(reason), "DMV")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Exports (the phase 3-5 contract; none of them yields)
-- ---------------------------------------------------------------------------------------------

exports("ownerOf", function(vehicleId)
    local row = rowOfVehicle(vehicleId)
    return row and row.owner or nil
end)

exports("hasKey", function(playerId, vehicleId)
    local pid = toPlayerId(playerId)
    if not pid then return false end
    return holdsKey(pid, rowOfVehicle(vehicleId))
end)

exports("vehiclesOf", function(playerId)
    local pid = toPlayerId(playerId)
    if not pid then return {} end
    local identifier = identifierOf(pid)
    local list = {}
    if not identifier then return list end
    for _, row in pairs(vehicles) do
        if row.owner == identifier then
            list[#list + 1] = {
                plate = row.plate, record = row.record, stored = row.state == "stored", wanted = row.wanted == true,
                label = row.label, state = row.state, vehicleId = row.vehicleId,
            }
        end
    end
    table.sort(list, function(a, b) return a.plate < b.plate end)
    return list
end)

exports("plateOf", function(vehicleId)
    local row = rowOfVehicle(vehicleId)
    return row and row.plate or nil
end)

exports("impound", function(vehicleId, reason, byPlayerId)
    if vehicleId == nil then return nil, "invalid_vehicle_id" end
    local row = rowOfVehicle(vehicleId)
    if not row then return nil, "not_owned" end
    if row.state ~= "out" then return nil, "not_in_world" end
    local why = type(reason) == "string" and reason:sub(1, 64) or "impounded"
    local by = toPlayerId(byPlayerId)
    retireRow(row, "impounded", nil, why)
    log("vehicle %s plate=%s impounded by %s via %s: %s", tostring(vehicleId), row.plate,
        by and ("player " .. by) or "server", tostring(GetInvokingResource() or "?"), why)
    tellOwner(row, ("Your %s (plate %s) was impounded: %s. Settle %s at any garage to get it back."):format(row.label, row.plate, why, eddies(Config.impound.fee)))
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "impounded")
    return true
end)

exports("setWanted", function(plate, flag, reason)
    local p = normalizePlate(plate)
    local row = p and vehicles[p]
    if not row then return nil, "unknown_plate" end
    local wanted = flag == true
    row.wanted = wanted
    row.wantedReason = wanted and (type(reason) == "string" and reason:sub(1, 64) or "") or ""
    persistVehicle(row)
    if wanted then
        for _, pid in ipairs(listOnDuty("ncpd")) do
            local n = toPlayerId(pid)
            if n then warn(n, ("APB: %s, plate %s, flagged: %s."):format(row.label, row.plate, row.wantedReason ~= "" and row.wantedReason or "no reason given"), "NCPD") end
        end
    end
    log("plate %s wanted=%s reason=%s", row.plate, tostring(wanted), row.wantedReason)
    TriggerEvent("rp_garage:changed", row.owner, row.plate, wanted and "wanted" or "unwanted")
    return true
end)

exports("spawnOwned", function(playerId, plate)
    local pid = toPlayerId(playerId)
    if not pid then return nil, "invalid_player_id" end
    if not Open77.players.name(pid) then return nil, "player_not_found" end
    local p = normalizePlate(plate)
    local row = p and vehicles[p]
    if not row then return nil, "unknown_plate" end
    if not holdsKey(pid, row) then return nil, "not_owner" end
    if row.state == "impounded" then return nil, "impounded" end
    if row.state == "out" then return nil, "already_out" end
    local pos = Open77.players.position(pid)
    if not pos then return nil, "position_unknown" end
    local spawnPoint = { x = pos.x + 4.0, y = pos.y, z = pos.z, yaw = 0.0 }
    local id, detail = spawnRow(row, spawnPoint, pos.bucket or 0, pid)
    if not id then return nil, detail end
    persistVehicle(row)
    log("spawnOwned: player %d plate=%s vehicle=%s (by %s)", pid, row.plate, tostring(id), tostring(GetInvokingResource() or "?"))
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "taken_out")
    return id
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

local function fromGame(source)
    if source == 0 then
        print("[rp_garage] run it from the game")
        return false
    end
    return true
end

RegisterCommand("garage", function(source)
    if not fromGame(source) then return end
    local garage = garageNear(source)
    if not garage then
        return warn(source, ("No garage within %.0f m. Afterlife street lot: %.0f, %.0f; mechanic's garage: %.0f, %.0f."):format(
            Config.reach.garage, Config.garages[1].position.x, Config.garages[1].position.y, Config.garages[2].position.x, Config.garages[2].position.y))
    end
    openGarage(source, garage)
end, false)

RegisterCommand("concession", function(source)
    if not fromGame(source) then return end
    if not atDealership(source) then
        return warn(source, ("The dealership is at %.0f, %.0f (%.0f m reach)."):format(Config.dealership.position.x, Config.dealership.position.y, Config.reach.garage), "Dealer")
    end
    openDealership(source)
end, false)

RegisterCommand("cles", function(source, args)
    if not fromGame(source) then return end
    local first = args[1]
    if not first then return listKeys(source) end
    if first:lower() == "revoke" or first:lower() == "retirer" then return revokeKeys(source, args[2]) end
    local target = toPlayerId(first)
    if not target then return warn(source, "Usage: /cles <playerId> [plate] | /cles revoke [plate] | /cles") end
    giveKey(source, target, args[2])
end, false)

RegisterCommand("verrouiller", function(source)
    if not fromGame(source) then return end
    toggleLock(source, nil)
end, false)

RegisterCommand("plaque", function(source)
    if not fromGame(source) then return end
    readPlate(source, nil)
end, false)

-- ---------------------------------------------------------------------------------------------
-- Net events (the client's POIs and ALT+click entries; every check is redone here)
-- ---------------------------------------------------------------------------------------------

RegisterNetEvent("rp_garage:open", function(garageId)
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    local garage = garageById(tostring(garageId))
    if not garage then return end
    local near = garageNear(playerId)
    if not near or near.id ~= garage.id then
        return warn(playerId, ("Get within %.0f m of the %s."):format(Config.reach.garage, garage.label))
    end
    openGarage(playerId, garage)
end)

RegisterNetEvent("rp_garage:dealer", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    if not atDealership(playerId) then return warn(playerId, "Get within reach of the dealership.", "Dealer") end
    openDealership(playerId)
end)

RegisterNetEvent("rp_garage:giveKey", function(targetId)
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    giveKey(playerId, toPlayerId(targetId), nil)
end)

RegisterNetEvent("rp_garage:action", function(action, vehicleId)
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    if vehicleId == nil then return end
    if action == "lock" then
        toggleLock(playerId, vehicleId)
    elseif action == "plate" then
        readPlate(playerId, vehicleId)
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Host and bus events
-- ---------------------------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/garage", help = "Open the garage you stand at: store, take out, settle the impound" },
    { command = "/concession", help = "Buy a vehicle at the dealership (plate and keys included)" },
    { command = "/cles", help = "Hand a key of your vehicle to a nearby player, or list your vehicles", parameters = {
        { name = "playerId", help = "The player receiving the key (or 'revoke')" },
        { name = "plate", help = "Optional plate; default: the vehicle you sit in or the nearest one" } } },
    { command = "/verrouiller", help = "Lock / unlock the nearest vehicle you hold a key for (6 m)" },
    { command = "/plaque", help = "Read the plate, the owner and the wanted flag of the nearest vehicle" },
}

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then Open77.chat.addSuggestions(source, SUGGESTIONS) end
end)

-- ---------------------------------------------------------------------------------------------
-- World props: the garage sign and the showroom neon (Config.<poi>.props). Real streamed
-- entities next to the rings; a refused model only logs, the ring alone marks the POI.
-- ---------------------------------------------------------------------------------------------

local propIds = {}   -- prop ids (decimal strings) this resource created, removed on stop

local function spawnProps(owner, props)
    for _, prop in ipairs(props or {}) do
        local created = nil
        for _, model in ipairs(prop.models or {}) do
            local ok, id, reason = pcall(Open77.props.create, {
                model = model,
                position = { x = prop.position.x, y = prop.position.y, z = prop.position.z },
                yaw = prop.yaw or 0.0,
                bucket = 0,
                streamingRadius = 120.0,
            })
            if ok and id then
                created = id
                propIds[#propIds + 1] = id
                log("prop %s of %s at %.1f %.1f %.1f (%s)", tostring(id), owner, prop.position.x, prop.position.y, prop.position.z, model)
                break
            end
            log("prop of %s refused (%s): %s", owner, tostring(ok and reason or id), model)
        end
        if not created then log("no prop spawned for %s: the ring alone marks it", owner) end
    end
end

local function removeProps()
    for _, id in ipairs(propIds) do
        pcall(Open77.props.remove, id)
    end
    propIds = {}
end

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log("started: %d garage(s), dealership at %.0f %.0f, %d record(s) for sale, impound fee %d, society %s",
        #Config.garages, Config.dealership.position.x, Config.dealership.position.y, #Config.vehicles, Config.impound.fee, Config.society)
    startStore()
    for _, g in ipairs(Config.garages) do spawnProps(g.id, g.props) end
    spawnProps("dealership", Config.dealership.props)
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    removeProps()
end)

AddEventHandler("onPlayerReady", function(playerId)
    local pid = toPlayerId(playerId)
    if not pid then return end
    -- A key holder who reconnects gets their per-player lock exceptions back.
    for _, row in pairs(vehicles) do
        if row.state == "out" and row.vehicleId and holdsKey(pid, row) then
            Open77.vehicles.setLockedForPlayer(row.vehicleId, pid, false)
        end
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = toPlayerId(playerId)
    if pid then menuBusy[pid] = nil end
end)

-- Somebody without a key at the wheel of an owned vehicle: the stolen signal for rp_crime / rp_ncpd.
AddEventHandler("onPlayerEnteredVehicle", function(playerId, vehicleId, seat)
    if tostring(seat) ~= "seat_front_left" then return end
    local pid = toPlayerId(playerId)
    local row = rowOfVehicle(vehicleId)
    if not pid or not row or holdsKey(pid, row) then return end
    local identifier = identifierOf(pid) or "?"
    local key = row.plate .. "|" .. identifier
    local t = now()
    if stolenSeen[key] and (t - stolenSeen[key]) < Config.stolenCooldownS then return end
    stolenSeen[key] = t
    warn(pid, ("Hot ride: the %s (plate %s) is not yours. The NCPD will want a word."):format(row.label, row.plate))
    tellOwner(row, ("Somebody just took the wheel of your %s (plate %s) without a key."):format(row.label, row.plate))
    log("plate %s taken by player %d (%s) without a key", row.plate, pid, identifier)
    TriggerEvent("rp_garage:stolen", row.plate, pid)
end)

-- A tracked vehicle removed by something else (admin /dv, explosion clean-up, a time to live,
-- rp_mecano's /fourriere): it goes back to the garage in its last known state.
AddEventHandler("onVehicleRemoved", function(vehicleId, reason)
    local plate = live[tostring(vehicleId)]
    if not plate then return end
    local row = vehicles[plate]
    live[tostring(vehicleId)] = nil
    if not row then return end
    row.vehicleId = nil
    row.state = "stored"
    persistVehicle(row)
    log("plate %s lost from the world (%s): back in the garage", plate, tostring(reason))
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "lost")
end)

-- rp_mecano keeps its own impound log and removes the vehicle itself; ownership follows here.
AddEventHandler("rp_mecano:impounded", function(vehicleId, byPlayerId, record, plate)
    local p = normalizePlate(plate)
    local row = p and vehicles[p]
    if not row then return end
    local id = row.vehicleId
    if id and tostring(id) == tostring(vehicleId) then
        live[tostring(id)] = nil
        row.vehicleId = nil
    end
    row.state = "impounded"
    row.impoundReason = "towed by the garage"
    persistVehicle(row)
    log("plate %s impounded by rp_mecano (player %s)", row.plate, tostring(byPlayerId))
    tellOwner(row, ("Your %s (plate %s) was towed to the impound lot. Settle %s at any garage to get it back."):format(row.label, row.plate, eddies(Config.impound.fee)))
    TriggerEvent("rp_garage:changed", row.owner, row.plate, "impounded")
end)

-- Condition and fuel of every vehicle out in the city, in memory, so a lost vehicle comes back
-- as it was.
CreateThread(function()
    while true do
        Wait(Config.snapshotIntervalMs)
        for _, row in pairs(vehicles) do
            if row.state == "out" and row.vehicleId then
                if Open77.vehicles.get(row.vehicleId) == nil then
                    -- Gone without onVehicleRemoved reaching us (event lost, handler raised):
                    -- same outcome as the handler below, back in the garage as last snapshotted.
                    live[tostring(row.vehicleId)] = nil
                    row.vehicleId = nil
                    row.state = "stored"
                    persistVehicle(row)
                    log("plate %s lost from the world (sweep): back in the garage", row.plate)
                    TriggerEvent("rp_garage:changed", row.owner, row.plate, "lost")
                else
                    snapshotRow(row)
                end
            end
        end
    end
end)
