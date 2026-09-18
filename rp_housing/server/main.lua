-- rp_housing / server: deeds, keys, rent, the "inside" state and every decision.
-- Money goes through rp_bank (account -> the "housing" society, a sink) with a
-- cash fallback through rp_economy; the stash is rp_inventory's; names come
-- from rp_identity; districts from rp_zones. All of them are reached through
-- pcall, so the resource still runs (with less flavour) when one is missing.

local TAG = "[rp_housing]"
local AUTHOR = "NC Housing"
local COLOR = { 0, 229, 255 }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local homes = {}    -- [homeId] = { identifier, ownerName, paid, boughtAt, rentDueAt, unpaid, spawnAtHome }
local keys = {}     -- [homeId] = { [identifier] = { name = , grantedBy = , grantedAt = } }
local inside = {}   -- [playerId] = homeId, toggled by every door pass-through, cleared by distance / disconnect
local moving = {}   -- [playerId] = true while a teleport is in flight
local store = nil   -- "sql" | "kvp"; nil while the registry is still loading
local loaded = false
local interiorZones = {}  -- [homeId] = prepared sphere around the interior
local doorState = {}      -- [doorId] = "ready" | "missing" (open77_doors integration)
local autoDoorLogged = {} -- [homeId] = true once the "not discovered yet" line was printed
local propIds = {}        -- prop ids (decimal strings) this resource created, removed on stop
local deriveRings         -- (home, door) -> moves the door rings A / B and the stash ring; defined with the auto door

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(TAG .. " " .. string.format(fmt, ...))
end

local function now()
    return math.floor(Open77.time.unix())
end

local function money(n)
    -- 25000 -> "25 000"
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end

local function say(playerId, text)
    local id = tonumber(playerId)
    if not id or id <= 0 then return end
    Open77.chat.send(id, { author = AUTHOR, text = text, color = COLOR })
end

local function toast(playerId, kind, title, message)
    local id = tonumber(playerId)
    if not id or id <= 0 then return end
    Open77.notifications.send(id, {
        type = kind,
        title = title,
        message = message,
        icon = "H",
        durationMs = 6000,
    })
end

local function ident(playerId)
    return Open77.players.identifier(playerId)
end

local function displayName(playerId)
    local ok, name = pcall(function() return exports.rp_identity:fullName(playerId) end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return Open77.players.name(playerId) or ("citizen #" .. tostring(playerId))
end

local function zoneLabel(home)
    if not home.zone then return home.district end
    local ok, list = pcall(function() return exports.rp_zones:list() end)
    if ok and type(list) == "table" then
        for _, zone in ipairs(list) do
            if zone.name == home.zone and zone.label then return zone.label end
        end
    end
    return home.district
end

local function homeIdOf(identifier)
    if not identifier then return nil end
    for id, h in pairs(homes) do
        if h.identifier == identifier then return id end
    end
    return nil
end

local function hasAccess(identifier, homeId)
    if not identifier or not homes[homeId] then return false end
    if homes[homeId].identifier == identifier then return true end
    local ring = keys[homeId]
    return ring ~= nil and ring[identifier] ~= nil
end

local function holdersOf(homeId)
    local list = {}
    for identifier, key in pairs(keys[homeId] or {}) do
        list[#list + 1] = { identifier = identifier, name = key.name }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function playerByIdentifier(identifier)
    for _, pid in ipairs(Open77.players.all()) do
        if ident(pid) == identifier then return pid end
    end
    return nil
end

local function changed(identifier, homeId, action)
    TriggerEvent("rp_housing:changed", identifier, homeId, action)
end

-- ---------------------------------------------------------------------------
-- Persistence: SQL first, Open77.kvp only when the database never answers
-- ---------------------------------------------------------------------------

local SQL_HOMES = [[
CREATE TABLE IF NOT EXISTS rp_housing_homes (
    home_id       VARCHAR(32)  NOT NULL PRIMARY KEY,
    identifier    VARCHAR(64)  NOT NULL,
    owner_name    VARCHAR(64)  NOT NULL DEFAULT '',
    paid          INT          NOT NULL DEFAULT 0,
    bought_at     INT          NOT NULL DEFAULT 0,
    rent_due_at   INT          NOT NULL DEFAULT 0,
    unpaid_rent   INT          NOT NULL DEFAULT 0,
    spawn_at_home TINYINT      NOT NULL DEFAULT 0,
    INDEX rp_housing_homes_identifier (identifier)
)]]

local SQL_KEYS = [[
CREATE TABLE IF NOT EXISTS rp_housing_keys (
    home_id     VARCHAR(32) NOT NULL,
    identifier  VARCHAR(64) NOT NULL,
    holder_name VARCHAR(64) NOT NULL DEFAULT '',
    granted_by  VARCHAR(64) NOT NULL DEFAULT '',
    granted_at  INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (home_id, identifier)
)]]

local function kvpSave()
    local ok1, r1 = Open77.kvp.set("homes", json.encode(homes) or "{}")
    local ok2, r2 = Open77.kvp.set("keys", json.encode(keys) or "{}")
    if not ok1 or not ok2 then log("kvp write failed: %s / %s", tostring(r1), tostring(r2)) end
end

local function persistHome(homeId)
    local h = homes[homeId]
    if not h then return end
    if store == "sql" then
        Open77.database.update([[
            INSERT INTO rp_housing_homes
                (home_id, identifier, owner_name, paid, bought_at, rent_due_at, unpaid_rent, spawn_at_home)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                identifier = VALUES(identifier), owner_name = VALUES(owner_name), paid = VALUES(paid),
                bought_at = VALUES(bought_at), rent_due_at = VALUES(rent_due_at),
                unpaid_rent = VALUES(unpaid_rent), spawn_at_home = VALUES(spawn_at_home)
        ]], { homeId, h.identifier, h.ownerName, h.paid, h.boughtAt, h.rentDueAt, h.unpaid, h.spawnAtHome and 1 or 0 },
        function() end)
    elseif store == "kvp" then
        kvpSave()
    end
end

local function eraseHome(homeId)
    homes[homeId] = nil
    keys[homeId] = nil
    if store == "sql" then
        Open77.database.update("DELETE FROM rp_housing_homes WHERE home_id = ?", { homeId }, function() end)
        Open77.database.update("DELETE FROM rp_housing_keys WHERE home_id = ?", { homeId }, function() end)
    elseif store == "kvp" then
        kvpSave()
    end
end

local function persistKey(homeId, identifier)
    local key = keys[homeId] and keys[homeId][identifier]
    if not key then return end
    if store == "sql" then
        Open77.database.update([[
            INSERT INTO rp_housing_keys (home_id, identifier, holder_name, granted_by, granted_at)
            VALUES (?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE holder_name = VALUES(holder_name), granted_by = VALUES(granted_by),
                granted_at = VALUES(granted_at)
        ]], { homeId, identifier, key.name, key.grantedBy, key.grantedAt }, function() end)
    elseif store == "kvp" then
        kvpSave()
    end
end

local function eraseKey(homeId, identifier)
    if keys[homeId] then keys[homeId][identifier] = nil end
    if store == "sql" then
        Open77.database.update("DELETE FROM rp_housing_keys WHERE home_id = ? AND identifier = ?",
            { homeId, identifier }, function() end)
    elseif store == "kvp" then
        kvpSave()
    end
end

local function acceptHomeRow(homeId, row)
    if not Config.home(homeId) then
        log("row for unknown home %s kept in storage but ignored (not in shared/config.lua)", tostring(homeId))
        return
    end
    homes[homeId] = {
        identifier = tostring(row.identifier or ""),
        ownerName = tostring(row.ownerName or row.owner_name or ""),
        paid = tonumber(row.paid) or 0,
        boughtAt = tonumber(row.boughtAt or row.bought_at) or 0,
        rentDueAt = tonumber(row.rentDueAt or row.rent_due_at) or 0,
        unpaid = tonumber(row.unpaid or row.unpaid_rent) or 0,
        spawnAtHome = (row.spawnAtHome == true) or (tonumber(row.spawn_at_home) or 0) ~= 0,
    }
end

local function acceptKeyRow(homeId, identifier, row)
    if not homes[homeId] then return end
    keys[homeId] = keys[homeId] or {}
    keys[homeId][identifier] = {
        name = tostring(row.name or row.holder_name or "?"),
        grantedBy = tostring(row.grantedBy or row.granted_by or ""),
        grantedAt = tonumber(row.grantedAt or row.granted_at) or 0,
    }
end

local function countHomes()
    local n, k = 0, 0
    for _ in pairs(homes) do n = n + 1 end
    for _, ring in pairs(keys) do for _ in pairs(ring) do k = k + 1 end end
    return n, k
end

local function loadFromKvp(reason)
    if loaded then return end
    store = "kvp"
    loaded = true
    local rawHomes = json.decode(Open77.kvp.get("homes", "{}") or "{}") or {}
    local rawKeys = json.decode(Open77.kvp.get("keys", "{}") or "{}") or {}
    for homeId, row in pairs(rawHomes) do
        if type(row) == "table" then acceptHomeRow(tostring(homeId), row) end
    end
    for homeId, ring in pairs(rawKeys) do
        if type(ring) == "table" then
            for identifier, row in pairs(ring) do
                if type(row) == "table" then acceptKeyRow(tostring(homeId), tostring(identifier), row) end
            end
        end
    end
    local n, k = countHomes()
    log("store=kvp reason=%s homes=%d keys=%d", tostring(reason), n, k)
end

local function loadFromSql()
    if loaded then return end
    local homeRows, keyRows
    local ok, err = pcall(function()
        Open77.database.update.await(SQL_HOMES)
        Open77.database.update.await(SQL_KEYS)
        homeRows = Open77.database.query.await("SELECT * FROM rp_housing_homes") or {}
        keyRows = Open77.database.query.await("SELECT * FROM rp_housing_keys") or {}
    end)
    if loaded then
        -- The watchdog gave up on the database meanwhile: the kvp store is live,
        -- do not mix two sources of truth.
        log("sql answered after the kvp fallback was chosen; staying on kvp until the next restart")
        return
    end
    if not ok then
        log("sql load failed (%s): falling back to Open77.kvp", tostring(err))
        loadFromKvp("sql_error")
        return
    end
    homes, keys = {}, {}
    for _, row in ipairs(homeRows) do acceptHomeRow(tostring(row.home_id), row) end
    for _, row in ipairs(keyRows) do acceptKeyRow(tostring(row.home_id), tostring(row.identifier), row) end
    store = "sql"
    loaded = true
    local n, k = countHomes()
    log("store=sql homes=%d keys=%d", n, k)
end

-- ---------------------------------------------------------------------------
-- Client state (map pins, "Give a key" predicate)
-- ---------------------------------------------------------------------------

local function stateFor(playerId)
    local identifier = ident(playerId)
    local owned = {}
    for id, h in pairs(homes) do owned[id] = h.ownerName ~= "" and h.ownerName or "someone" end
    local withKey = {}
    for id, ring in pairs(keys) do
        if identifier and ring[identifier] then withKey[#withKey + 1] = id end
    end
    -- The rings: the auto door moves all three at runtime (door side A, door
    -- side B, stash), so the client takes them from here rather than from its
    -- copy of the shared config.
    local sideA, sideB, stashes = {}, {}, {}
    for _, home in ipairs(Config.homes) do
        sideA[home.id] = { x = home.sideA.x, y = home.sideA.y, z = home.sideA.z }
        sideB[home.id] = { x = home.sideB.x, y = home.sideB.y, z = home.sideB.z }
        stashes[home.id] = { x = home.stash.x, y = home.stash.y, z = home.stash.z }
    end
    return { mine = homeIdOf(identifier) or false, owned = owned, keys = withKey, inside = inside[playerId] or false,
        sideA = sideA, sideB = sideB, stashes = stashes }
end

local function sendState(playerId)
    local id = tonumber(playerId)
    if not id or id <= 0 then return end
    TriggerClientEvent("rp_housing:state", id, stateFor(id))
end

local function broadcastState()
    for _, id in ipairs(Open77.players.all()) do sendState(id) end
end

-- ---------------------------------------------------------------------------
-- open77_doors (optional): lock a real door to the owner and the key holders.
-- The doorId comes from the "auto door" search below (or from the config).
-- ---------------------------------------------------------------------------

local function doors(method, ...)
    local pending, err = Open77.exports.call("open77_doors", method, ...)
    if not pending then return nil, err end
    return pending:await()
end

local function syncDoor(home)
    if not home or home.doorId == "" then return end
    local snapshot = doors("get", home.doorId, 0)
    if not snapshot then
        if doorState[home.doorId] ~= "missing" then
            log("door %s of %s is not discovered yet (or open77_doors is absent); will retry", home.doorId, home.id)
        end
        doorState[home.doorId] = "missing"
        return
    end
    -- A hand-set doorId never went through resolveAutoDoor: derive the rings
    -- from the door the first time it is seen.
    if not home.ringsDerived and type(snapshot.position) == "table" then
        deriveRings(home, { id = home.doorId, position = snapshot.position })
        broadcastState()
    end
    if doorState[home.doorId] ~= "ready" then
        local owned, why = doors("register", { id = home.doorId, bucket = 0, position = snapshot.position })
        if not owned then
            log("door %s of %s could not be claimed: %s", home.doorId, home.id, tostring(why))
            doorState[home.doorId] = "missing"
            return
        end
        local ok, why2 = doors("configure", home.doorId, 0, {
            automatic = true, autoClose = true, defaultAccess = false,
        })
        if not ok then log("door %s of %s configure refused: %s", home.doorId, home.id, tostring(why2)) end
        doorState[home.doorId] = "ready"
        log("door %s locked to the owner and key holders of %s", home.doorId, home.id)
    end
    for _, pid in ipairs(Open77.players.all()) do
        local identifier = ident(pid)
        local grant = identifier ~= nil and hasAccess(identifier, home.id)
        doors("setAccess", home.doorId, 0, pid, grant)
    end
end

local function syncHomeDoor(homeId)
    local home = Config.home(homeId)
    if not home or home.doorId == "" then return end
    CreateThread(function() syncDoor(home) end)
end

local function syncAllDoors()
    for _, home in ipairs(Config.homes) do syncHomeDoor(home.id) end
end

-- ---------------------------------------------------------------------------
-- Auto door: the flat's own front door. open77_doors:near(interior, 0, radius)
-- lists the doors a client has discovered around the interior point, nearest
-- first; the first one becomes the home's doorId and the three rings are
-- derived from it (deriveRings). Nothing is discovered until a client has
-- streamed the flat, so the static fallback (shared/config.lua: side A = the
-- interior point, side B = interior + 3 m along x, stash = interior + 1.5 m
-- along x) stays in force and the search is retried every
-- Config.autoDoor.retrySec. Runs inside a thread (near() is awaited).
-- ---------------------------------------------------------------------------

-- Unit vector pointing from the door to the outside (the street side).
local function outsideAxis(home, door)
    local p = door.position
    local dx, dy
    local facing = door.facing or door.heading or door.yaw
    if type(facing) == "table" and type(facing.x) == "number" and type(facing.y) == "number" then
        dx, dy = facing.x, facing.y
    elseif type(facing) == "number" then
        dx, dy = -math.sin(math.rad(facing)), math.cos(math.rad(facing))
    else
        -- The snapshot carries no facing (measured: id, bucket, position, state
        -- flags only): "outside" is away from the interior point, +x when the
        -- door sits on the interior point itself.
        dx, dy = p.x - home.interior.x, p.y - home.interior.y
    end
    local n = math.sqrt(dx * dx + dy * dy)
    if n < 0.01 then dx, dy, n = 1.0, 0.0, 1.0 end
    return dx / n, dy / n
end

-- The rule (measured 2026-09-18, Northside: a fixed x offset put the rings
-- inside the walls, and the "which side is inside" guess was wrong - the AMM
-- interior point is the corridor in front of the unit door): the door is a
-- two-sided pass-through. Every ring lies on the interior -> door axis: side A
-- = door - `ring` m (interior side), side B = door + `ring` m (beyond the
-- door), both at the door's z; a pass-through lands `land` m from the door on
-- the far side (landA / landB). The stash = interior + `stashInside` m further
-- from the door, at the interior's z (the floor spawn-at-home lands on).
deriveRings = function(home, door)
    local ox, oy = outsideAxis(home, door)
    local p = door.position
    local ring, land, deep = Config.autoDoor.ring, Config.autoDoor.land, Config.autoDoor.stashInside
    home.sideA = { x = p.x - ox * ring, y = p.y - oy * ring, z = p.z }
    home.sideB = { x = p.x + ox * ring, y = p.y + oy * ring, z = p.z }
    home.landA = { x = p.x - ox * land, y = p.y - oy * land, z = p.z }
    home.landB = { x = p.x + ox * land, y = p.y + oy * land, z = p.z }
    home.stash = { x = home.interior.x - ox * deep, y = home.interior.y - oy * deep, z = home.interior.z }
    home.ringsDerived = true
    log("auto door of %s: %s at %.1f, %.1f, %.1f; door ring A moved to %.1f, %.1f, %.1f; door ring B to %.1f, %.1f, %.1f; stash ring to %.1f, %.1f, %.1f",
        home.id, tostring(door.id), p.x, p.y, p.z, home.sideA.x, home.sideA.y, home.sideA.z,
        home.sideB.x, home.sideB.y, home.sideB.z, home.stash.x, home.stash.y, home.stash.z)
end

local function resolveAutoDoor(home)
    if home.doorId ~= "" or not home.autoDoor then return false end
    local ok, result = pcall(doors, "near",
        { x = home.interior.x, y = home.interior.y, z = home.interior.z }, 0, Config.autoDoor.radius)
    if not ok then
        log("auto door of %s: open77_doors:near raised (%s); retry in %d s", home.id, tostring(result), Config.autoDoor.retrySec)
        return false
    end
    local list = type(result) == "table" and result.doors or nil
    -- Same floor only: `near` is a 3-D radius, and a megabuilding stacks flats 4 m apart,
    -- so the nearest door can be the unit BELOW (measured 18 Sept: Northside got the door
    -- at z 18.2 while the flat's floor is 22.2 and the rings went under the floor).
    local door = nil
    if type(list) == "table" then
        for _, candidate in ipairs(list) do
            local p = type(candidate) == "table" and candidate.position or nil
            if type(p) == "table" and type(p.z) == "number"
                and math.abs(p.z - home.interior.z) <= (Config.autoDoor.floorTolerance or 1.5) then
                door = candidate
                break
            end
        end
    end
    if type(door) ~= "table" or type(door.id) ~= "string" or type(door.position) ~= "table" then
        if not autoDoorLogged[home.id] then
            log("auto door of %s: no door discovered within %.0f m of the interior yet (a client must stream the flat); static rings A %.1f, %.1f, %.1f / B %.1f, %.1f, %.1f in force, retry every %d s",
                home.id, Config.autoDoor.radius, home.sideA.x, home.sideA.y, home.sideA.z,
                home.sideB.x, home.sideB.y, home.sideB.z, Config.autoDoor.retrySec)
            autoDoorLogged[home.id] = true
        end
        return false
    end
    home.doorId = door.id
    deriveRings(home, door)
    broadcastState()
    return true
end

-- ---------------------------------------------------------------------------
-- World props: the agency's listings terminal (Config.agency.props). A refused
-- model only logs; the ring alone marks the desk.
-- ---------------------------------------------------------------------------

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
    for _, id in ipairs(propIds) do pcall(Open77.props.remove, id) end
    propIds = {}
end

-- ---------------------------------------------------------------------------
-- Money: account first (rp_bank:charge into the housing society), cash second
-- ---------------------------------------------------------------------------

local function charge(playerId, amount, reason)
    local ok, balance, why = pcall(function()
        return exports.rp_bank:charge(playerId, amount, Config.society, reason)
    end)
    if ok and balance then return true, "account" end
    local bankWhy = ok and (why or "refused") or "rp_bank_unavailable"
    local ok2, cash, why2 = pcall(function()
        return exports.rp_economy:remove(playerId, amount, reason)
    end)
    if ok2 and cash then return true, "cash" end
    local cashWhy = ok2 and (why2 or "refused") or "rp_economy_unavailable"
    return nil, bankWhy, cashWhy
end

local function refund(playerId, amount, reason)
    -- The housing society is a sink: debit it for the ledger when it can, and
    -- hand the eddies back in cash whatever it says.
    pcall(function() exports.rp_bank:societyRemove(Config.society, amount, reason) end)
    local ok, balance, why = pcall(function()
        return exports.rp_economy:add(playerId, amount, reason)
    end)
    if ok and balance then return true end
    return nil, ok and (why or "refused") or "rp_economy_unavailable"
end

-- ---------------------------------------------------------------------------
-- Moving a player (enter / leave / spawn at home)
-- ---------------------------------------------------------------------------

local function move(playerId, position, heading)
    if moving[playerId] then return nil, "already_moving" end
    if Open77.players.isDead(playerId) then return nil, "player_not_alive" end
    moving[playerId] = true
    local options = { fade = true, fadeOutMs = Config.enterFade, fadeInMs = Config.enterFade }
    if heading then options.heading = heading end
    local pending, reason = Open77.players.teleport(playerId,
        { x = position.x, y = position.y, z = position.z }, options)
    if not pending then
        moving[playerId] = nil
        return nil, reason
    end
    local landed, err = pending:await()
    moving[playerId] = nil
    if not landed then return nil, err end
    return landed
end

local function within(playerId, position, radius)
    local metres = Open77.players.distance(playerId, position)
    if not metres then return false, "position_unknown" end
    return metres <= radius, metres
end

-- ---------------------------------------------------------------------------
-- Deeds
-- ---------------------------------------------------------------------------

local function buy(playerId, homeId)
    if not loaded then return nil, "The housing registry is still loading, choom. Try again in a moment." end
    local home = Config.home(homeId)
    if not home then return nil, "No such place on the market." end
    local identifier = ident(playerId)
    if not identifier then return nil, "Unknown citizen." end
    if homes[homeId] then
        if homes[homeId].identifier == identifier then return nil, "That one is already yours." end
        return nil, ("%s is taken (owned by %s)."):format(home.label, homes[homeId].ownerName)
    end
    local mine = homeIdOf(identifier)
    if mine then
        return nil, ("You already own %s. One roof per citizen: sell it first (/maison vendre)."):format(Config.home(mine).label)
    end
    local ok, via, cashWhy = charge(playerId, home.price, "buy:" .. homeId)
    if not ok then
        if via == "insufficient_funds" and cashWhy == "insufficient_funds" then
            return nil, ("Not enough eddies: %s €$ needed, account or cash."):format(money(home.price))
        end
        return nil, ("Payment refused (%s / %s)."):format(tostring(via), tostring(cashWhy))
    end
    homes[homeId] = {
        identifier = identifier,
        ownerName = displayName(playerId),
        paid = home.price,
        boughtAt = now(),
        rentDueAt = now() + Config.rentIntervalSec,
        unpaid = 0,
        spawnAtHome = false,
    }
    keys[homeId] = {}
    persistHome(homeId)
    log("player %d %s bought %s for %d from %s", playerId, identifier, homeId, home.price, via)
    changed(identifier, homeId, "bought")
    broadcastState()
    syncHomeDoor(homeId)
    toast(playerId, "success", "Deed signed", ("%s is yours."):format(home.label))
    return true, via
end

local function leaveIfInside(playerId, homeId)
    if inside[playerId] ~= homeId then return end
    inside[playerId] = nil
    local home = Config.home(homeId)
    if not home then return end
    CreateThread(function()
        local ok, why = move(playerId, home.landB)
        if not ok then log("player %d could not be moved out of %s: %s", playerId, homeId, tostring(why)) end
        sendState(playerId)
    end)
end

local function sell(playerId)
    if not loaded then return nil, "The housing registry is still loading, choom." end
    local identifier = ident(playerId)
    local homeId = homeIdOf(identifier)
    if not homeId then return nil, "You own nothing to sell. The agency is at Kabuki Market, The Crossing." end
    local home = Config.home(homeId)
    local amount = math.floor(home.price * Config.sellBackRatio)
    leaveIfInside(playerId, homeId)
    for _, pid in ipairs(Open77.players.all()) do
        if inside[pid] == homeId then leaveIfInside(pid, homeId) end
    end
    eraseHome(homeId)
    local ok, why = refund(playerId, amount, "sell:" .. homeId)
    if not ok then log("refund of %d to player %d failed: %s", amount, playerId, tostring(why)) end
    log("player %d %s sold %s for %d (%d%%)", playerId, identifier, homeId, amount, math.floor(Config.sellBackRatio * 100))
    changed(identifier, homeId, "sold")
    broadcastState()
    syncHomeDoor(homeId)
    toast(playerId, "info", "Deed transferred", ("%s €$ in cash for %s."):format(money(amount), home.label))
    return true, amount
end

local function evict(homeId, why)
    local h = homes[homeId]
    if not h then return end
    local home = Config.home(homeId)
    local identifier = h.identifier
    local ownerId = playerByIdentifier(identifier)
    for _, pid in ipairs(Open77.players.all()) do
        if inside[pid] == homeId then leaveIfInside(pid, homeId) end
    end
    eraseHome(homeId)
    log("%s evicted from %s: %s", identifier, homeId, why)
    changed(identifier, homeId, "evicted")
    broadcastState()
    syncHomeDoor(homeId)
    if ownerId then
        say(ownerId, ("EVICTED. Two unpaid rents on %s: the landlord changed the locks and voided every key."):format(home.label))
        toast(ownerId, "error", "Evicted", home.label)
    end
end

-- ---------------------------------------------------------------------------
-- Rent
-- ---------------------------------------------------------------------------

local function collectRent(playerId, homeId, count, advance)
    local h = homes[homeId]
    local home = Config.home(homeId)
    if not h or not home then return nil, "no_home" end
    local due = home.rent * count
    local ok, via, cashWhy = charge(playerId, due, "rent:" .. homeId)
    if ok then
        h.unpaid = 0
        if advance then h.rentDueAt = math.max(h.rentDueAt, now()) + Config.rentIntervalSec end
        persistHome(homeId)
        log("player %d %s paid rent %d for %s from %s", playerId, h.identifier, due, homeId, via)
        changed(h.identifier, homeId, "rent_paid")
        return true, via
    end
    return nil, via, cashWhy
end

local function rentDue(playerId, homeId)
    -- One payday came: charge one rent; unpaid twice in a row = out.
    local h = homes[homeId]
    local home = Config.home(homeId)
    if not h or not home then return end
    h.rentDueAt = now() + Config.rentIntervalSec
    local ok, via, cashWhy = collectRent(playerId, homeId, 1, false)
    if ok then
        say(playerId, ("Rent paid: %s €$ for %s (%s). Next payday in %d min."):format(
            money(home.rent), home.label, via, math.floor(Config.rentIntervalSec / 60)))
        return
    end
    h.unpaid = h.unpaid + 1
    persistHome(homeId)
    log("player %d %s missed rent %d for %s (%d/%d): %s / %s", playerId, h.identifier, home.rent, homeId,
        h.unpaid, Config.evictAfter, tostring(via), tostring(cashWhy))
    changed(h.identifier, homeId, "rent_unpaid")
    if h.unpaid >= Config.evictAfter then
        evict(homeId, "unpaid rent")
        return
    end
    say(playerId, ("RENT UNPAID (%d/%d): %s €$ for %s. Fill your account and /loyer payer before the next payday, or you are out."):format(
        h.unpaid, Config.evictAfter, money(home.rent), home.label))
    toast(playerId, "warning", "Rent unpaid", ("%d/%d - /loyer payer"):format(h.unpaid, Config.evictAfter))
end

local function rentTick()
    if not loaded then return end
    local t = now()
    for _, pid in ipairs(Open77.players.all()) do
        local homeId = homeIdOf(ident(pid))
        if homeId and homes[homeId] and homes[homeId].rentDueAt <= t then
            rentDue(pid, homeId)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

local function giveKey(playerId, targetId)
    if not loaded then return nil, "The housing registry is still loading, choom." end
    local identifier = ident(playerId)
    local homeId = homeIdOf(identifier)
    if not homeId then return nil, "You own no place to hand keys for." end
    targetId = tonumber(targetId)
    -- integer >= 1 only: Open77.players.identifier raises on anything else and that kills the VM
    if not targetId or targetId < 1 or targetId % 1 ~= 0 or targetId == playerId then return nil, "Who? /maison cles <playerId>." end
    local targetIdentifier = ident(targetId)
    if not targetIdentifier or not Open77.players.name(targetId) then return nil, "Nobody with that id in the city." end
    local close, metres = within(playerId, targetId, Config.keyDistance)
    if not close then
        return nil, ("Get closer to hand over a key (%s m, max %d m)."):format(
            type(metres) == "number" and string.format("%.1f", metres) or "?", Config.keyDistance)
    end
    if hasAccess(targetIdentifier, homeId) then return nil, "They already hold a key." end
    keys[homeId] = keys[homeId] or {}
    keys[homeId][targetIdentifier] = { name = displayName(targetId), grantedBy = identifier, grantedAt = now() }
    persistKey(homeId, targetIdentifier)
    local home = Config.home(homeId)
    log("player %d gave a key of %s to player %d %s", playerId, homeId, targetId, targetIdentifier)
    changed(targetIdentifier, homeId, "key_given")
    sendState(playerId)
    sendState(targetId)
    syncHomeDoor(homeId)
    say(targetId, ("%s handed you a key to %s. Find the door on your map."):format(displayName(playerId), home.label))
    toast(targetId, "success", "New key", home.label)
    return true, displayName(targetId)
end

local function revokeKey(playerId, targetIdentifier)
    local identifier = ident(playerId)
    local homeId = homeIdOf(identifier)
    if not homeId then return nil, "You own no place." end
    if not keys[homeId] or not keys[homeId][targetIdentifier] then return nil, "They hold no key of yours." end
    local name = keys[homeId][targetIdentifier].name
    eraseKey(homeId, targetIdentifier)
    log("player %d revoked the key of %s to %s", playerId, targetIdentifier, homeId)
    changed(targetIdentifier, homeId, "key_revoked")
    local targetId = playerByIdentifier(targetIdentifier)
    if targetId then
        if inside[targetId] == homeId then leaveIfInside(targetId, homeId) end
        sendState(targetId)
        say(targetId, ("%s took back the key to %s."):format(displayName(playerId), Config.home(homeId).label))
    end
    sendState(playerId)
    syncHomeDoor(homeId)
    return true, name
end

-- ---------------------------------------------------------------------------
-- Door pass-through and stash (net events raised by the client's E prompts)
-- ---------------------------------------------------------------------------

-- The door is two-sided: E on either "Apartment door" ring moves the player to
-- the other side of the door (the nearer ring says which side they stand on).
-- Which side is the flat proper is not knowable, so `inside` toggles on every
-- pass-through: the first crossing marks the player inside, the next one out.
local function passThrough(playerId, homeId)
    if not loaded then return say(playerId, "The housing registry is still loading, choom.") end
    local home = Config.home(homeId)
    if not home then return say(playerId, "That door goes nowhere.") end
    local reach = Config.promptDistance + Config.serverTolerance
    local nearA, metresA = within(playerId, home.sideA, reach)
    local nearB, metresB = within(playerId, home.sideB, reach)
    if not nearA and not nearB then
        return say(playerId, ("Too far from the door of %s."):format(home.label))
    end
    if Open77.players.isDead(playerId) then return say(playerId, "Dead people do not go home.") end
    local identifier = ident(playerId)
    if not homes[homeId] then
        return say(playerId, ("%s is for sale (%s €$). The agency is at Kabuki Market, The Crossing, or /agence_immo."):format(
            home.label, money(home.price)))
    end
    if not hasAccess(identifier, homeId) then
        return say(playerId, ("Locked. %s belongs to %s and you hold no key, choom."):format(
            home.label, homes[homeId].ownerName))
    end
    -- Both rings can be within reach at once (they are 4 m apart): the nearer
    -- one is the side the player stands on, the far one's landing is the target.
    local fromSide, toSide, target = "A", "B", home.landB
    if not nearA or (nearB and metresB < metresA) then fromSide, toSide, target = "B", "A", home.landA end
    local ok, why = move(playerId, target)
    if not ok then return say(playerId, ("The door jammed (%s). Try again."):format(tostring(why))) end
    if inside[playerId] == homeId then inside[playerId] = nil else inside[playerId] = homeId end
    sendState(playerId)
    if inside[playerId] == homeId then
        if homes[homeId].identifier == identifier then
            say(playerId, "Welcome home. E on the stash, E on the door again to step back out.")
        else
            say(playerId, ("You let yourself into %s with %s's key."):format(home.label, homes[homeId].ownerName))
        end
    else
        say(playerId, ("You step out of %s."):format(home.label))
    end
    log("player %d passed through the door of %s: side %s -> side %s, inside=%s", playerId, homeId, fromSide, toSide,
        tostring(inside[playerId] == homeId))
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

local function openStash(playerId, homeId)
    local home = Config.home(homeId)
    if not home then return end
    if inside[playerId] ~= homeId then
        return say(playerId, "Get inside first. The stash does not open from the street.")
    end
    local close = within(playerId, home.stash, Config.promptDistance + Config.serverTolerance)
    if not close then return say(playerId, "Too far from the stash.") end
    local identifier = ident(playerId)
    if not hasAccess(identifier, homeId) then
        return say(playerId, "Your key does not open this stash any more.")
    end
    -- Staged: crouched at the stash for the bar's length, then the panel opens (Config.Stage.stash).
    local done = stage(playerId, "stash", { label = "Opening the stash" })
    if not done or not done.ok then return say(playerId, "You leave the stash shut.") end
    if inside[playerId] ~= homeId or not hasAccess(ident(playerId), homeId) then return end
    local ok, opened, why = pcall(function()
        return exports.rp_inventory:openStash(playerId, "home:" .. homeId, Config.stashCapacity)
    end)
    if not ok then return say(playerId, "The stash is jammed: rp_inventory is not running.") end
    if not opened then return say(playerId, ("The stash refused: %s."):format(tostring(why))) end
    log("player %d opened stash home:%s", playerId, homeId)
end

-- ---------------------------------------------------------------------------
-- The agency (UI kit server twins; chat fallback through /maison acheter)
-- ---------------------------------------------------------------------------

local function uikit(name, ...)
    local pending, reason = Open77.exports.call("open77_uikit", name, ...)
    if not pending then return nil, reason end
    return pending:await()
end

local function atAgency(playerId)
    local close, metres = within(playerId, Config.agency.position, Config.agencyRadius)
    if close then return true end
    return false, metres
end

local function marketLine(home)
    local h = homes[home.id]
    local status = "for sale"
    if h then status = "owned by " .. h.ownerName end
    return ("%s (%s) - %s €$, rent %s €$/payday - %s"):format(home.label, home.id, money(home.price), money(home.rent), status)
end

local function sendMarket(playerId)
    say(playerId, "On the market (/maison acheter <id> at the agency):")
    for _, home in ipairs(Config.homes) do
        Wait(0)
        say(playerId, "  " .. marketLine(home))
    end
end

local function openAgency(playerId)
    if not loaded then return say(playerId, "The housing registry is still loading, choom.") end
    local ok, metres = atAgency(playerId)
    if not ok then
        return say(playerId, ("No real-estate agent here (%s m away). The agency is %d m from the spawn, south-west."):format(
            type(metres) == "number" and string.format("%.0f", metres) or "?", 7))
    end
    local identifier = ident(playerId)
    local mine = homeIdOf(identifier)
    local options = {}
    for _, home in ipairs(Config.homes) do
        local h = homes[home.id]
        local row = {
            id = home.id,
            label = home.label,
            icon = "H",
            metadata = {
                { label = "Price", value = money(home.price) .. " €$" },
                { label = "Rent", value = money(home.rent) .. " €$ / payday" },
                { label = "District", value = zoneLabel(home) },
            },
        }
        if h and h.identifier == identifier then
            row.description = ("Yours. Sell it back for %s €$."):format(money(math.floor(home.price * Config.sellBackRatio)))
            row.tone = "success"
        elseif h then
            row.description = "Owned by " .. h.ownerName .. "."
            row.disabled = true
        elseif mine then
            row.description = "For sale. Sell yours first: one roof per citizen."
            row.disabled = true
        else
            row.description = "For sale."
        end
        options[#options + 1] = row
    end
    options[#options + 1] = { id = "leave", label = "Leave", description = "Just looking." }

    local answer, reason = uikit("context", playerId, {
        id = "rp_housing_agency",
        title = "Night City Real Estate",
        description = "Deeds, keys, rent. No refunds on the view.",
        options = options,
    })
    if answer == nil then
        say(playerId, ("The agent's terminal is down (%s). Chat listing instead:"):format(tostring(reason)))
        return sendMarket(playerId)
    end
    if not answer.ok then return end
    local pick = answer.value and answer.value.id
    if not pick or pick == "leave" then return end
    local home = Config.home(pick)
    if not home then return end
    if not atAgency(playerId) then return say(playerId, "Come back to the desk to sign.") end

    if mine == pick then
        local amount = math.floor(home.price * Config.sellBackRatio)
        local confirm = uikit("alert", playerId, {
            title = ("Sell %s?"):format(home.label),
            message = ("The agency pays %s €$ back in cash (%d %% of %s €$). Every key is voided and the stash stays where it is."):format(
                money(amount), math.floor(Config.sellBackRatio * 100), money(home.price)),
            confirm = "Sell it", cancel = "Keep it", tone = "danger", timeoutMs = 30000,
        })
        if confirm == nil then return say(playerId, "Confirm in chat: /maison vendre oui") end
        if not confirm.ok then return end
        local sold, why = sell(playerId)
        if not sold then return say(playerId, why) end
        return say(playerId, ("Sold %s for %s €$ in cash."):format(home.label, money(why)))
    end

    local confirm = uikit("alert", playerId, {
        title = ("Buy %s?"):format(home.label),
        message = ("%s €$ now (account first, cash if the account is short), then %s €$ every payday charged from your account. Two unpaid rents and you are out."):format(
            money(home.price), money(home.rent)),
        confirm = "Sign", cancel = "Not today", tone = "warning", timeoutMs = 30000,
    })
    if confirm == nil then return say(playerId, ("Confirm in chat: /maison acheter %s"):format(pick)) end
    if not confirm.ok then return end
    local bought, why = buy(playerId, pick)
    if not bought then return say(playerId, why) end
    say(playerId, ("%s is yours (paid from %s). The door is marked on your map: E to enter."):format(home.label, why))
end

-- ---------------------------------------------------------------------------
-- Net events (client prompts and ALT+click)
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_housing:clientReady", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    sendState(playerId)
end)

RegisterNetEvent("rp_housing:door", function(homeId)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    passThrough(playerId, tostring(homeId))
end)

-- Kept for older clients: the separate "Front door" ring is gone, the door is
-- the same pass-through from either side.
RegisterNetEvent("rp_housing:exit", function(homeId)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    passThrough(playerId, tostring(homeId))
end)

RegisterNetEvent("rp_housing:stash", function(homeId)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    openStash(playerId, tostring(homeId))
end)

RegisterNetEvent("rp_housing:agency", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    openAgency(playerId)
end)

RegisterNetEvent("rp_housing:giveKey", function(targetId)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local ok, why = giveKey(playerId, tonumber(targetId))
    if not ok then return say(playerId, why) end
    say(playerId, ("You handed a key to %s."):format(why))
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/maison", help = "Your place: status, keys, spawn, sale", parameters = {
        { name = "action", help = "cles <id> | retirer <id|tous> | spawn | vendre | acheter <home>" } } },
    { command = "/loyer", help = "Rent status; /loyer payer pays now", parameters = {
        { name = "payer", help = "pay the rent now (optional)" } } },
    { command = "/agence_immo", help = "Open the real-estate agency menu (at the desk)" },
}

local function fromConsole(source)
    if source == 0 then
        print(TAG .. " run this from the game, not the console")
        return true
    end
    return false
end

RegisterCommand("agence_immo", function(source)
    if fromConsole(source) then return end
    openAgency(source)
end, false)

local function status(playerId)
    local identifier = ident(playerId)
    local homeId = homeIdOf(identifier)
    if not homeId then
        local held = {}
        for id, ring in pairs(keys) do
            if identifier and ring[identifier] then held[#held + 1] = Config.home(id).label end
        end
        say(playerId, "You own no place in Night City. The agency is 7 m south-west of the spawn (/agence_immo at the desk).")
        if #held > 0 then
            Wait(0)
            say(playerId, "Keys in your pocket: " .. table.concat(held, ", "))
        end
        return
    end
    local h = homes[homeId]
    local home = Config.home(homeId)
    local left = h.rentDueAt - now()
    local due = left > 0 and ("next rent in %d min"):format(math.ceil(left / 60)) or "rent due at the next tick"
    say(playerId, ("%s (%s) - bought for %s €$ - rent %s €$/payday - %s - unpaid %d/%d - spawn at home: %s"):format(
        home.label, homeId, money(h.paid), money(home.rent), due, h.unpaid, Config.evictAfter,
        h.spawnAtHome and "ON" or "off"))
    Wait(0)
    local holders = holdersOf(homeId)
    if #holders == 0 then
        say(playerId, "Keys: nobody but you. /maison cles <playerId> or ALT+click a choom > Give a key.")
    else
        local names = {}
        for _, holder in ipairs(holders) do names[#names + 1] = holder.name end
        say(playerId, ("Keys (%d): %s"):format(#holders, table.concat(names, ", ")))
    end
    Wait(0)
    say(playerId, "/maison cles <id> - /maison retirer <id|tous> - /maison spawn - /maison vendre - /loyer")
end

RegisterCommand("maison", function(source, args)
    if fromConsole(source) then return end
    local action = (args[1] or ""):lower()
    if action == "" then return status(source) end

    if action == "cles" or action == "cle" then
        local ok, why = giveKey(source, tonumber(args[2]))
        if not ok then return say(source, why) end
        return say(source, ("You handed a key to %s."):format(why))
    end

    if action == "retirer" then
        local who = (args[2] or ""):lower()
        local homeId = homeIdOf(ident(source))
        if not homeId then return say(source, "You own no place.") end
        if who == "tous" or who == "all" then
            local holders = holdersOf(homeId)
            if #holders == 0 then return say(source, "Nobody holds a key.") end
            for _, holder in ipairs(holders) do revokeKey(source, holder.identifier) end
            return say(source, ("Locks changed: %d key(s) voided."):format(#holders))
        end
        local targetId = tonumber(who)
        if targetId and (targetId < 1 or targetId % 1 ~= 0) then targetId = nil end -- ident() raises on id 0 / floats
        local targetIdentifier = targetId and ident(targetId)
        if not targetIdentifier then return say(source, "Usage: /maison retirer <playerId> or /maison retirer tous") end
        local ok, why = revokeKey(source, targetIdentifier)
        if not ok then return say(source, why) end
        return say(source, ("Took the key back from %s."):format(why))
    end

    if action == "spawn" then
        if not loaded then return say(source, "The housing registry is still loading, choom.") end
        local homeId = homeIdOf(ident(source))
        if not homeId then return say(source, "You own no place to wake up in.") end
        local h = homes[homeId]
        h.spawnAtHome = not h.spawnAtHome
        persistHome(homeId)
        changed(h.identifier, homeId, h.spawnAtHome and "spawn_on" or "spawn_off")
        log("player %d spawn at home %s: %s", source, homeId, tostring(h.spawnAtHome))
        if h.spawnAtHome then
            return say(source, ("Spawn at home ON: next time you connect you wake up inside %s."):format(Config.home(homeId).label))
        end
        return say(source, "Spawn at home OFF: you will spawn at Kabuki Market like everybody.")
    end

    if action == "vendre" then
        local homeId = homeIdOf(ident(source))
        if not homeId then return say(source, "You own nothing to sell.") end
        local home = Config.home(homeId)
        local amount = math.floor(home.price * Config.sellBackRatio)
        local confirmed = (args[2] or ""):lower() == "oui"
        if not confirmed then
            local confirm = uikit("alert", source, {
                title = ("Sell %s?"):format(home.label),
                message = ("%s €$ back in cash (%d %% of %s €$). Keys voided."):format(
                    money(amount), math.floor(Config.sellBackRatio * 100), money(home.price)),
                confirm = "Sell it", cancel = "Keep it", tone = "danger", timeoutMs = 30000,
            })
            if confirm == nil then return say(source, ("Sell %s for %s €$? Confirm: /maison vendre oui"):format(home.label, money(amount))) end
            if not confirm.ok then return end
        end
        local sold, why = sell(source)
        if not sold then return say(source, why) end
        return say(source, ("Sold %s for %s €$ in cash."):format(home.label, money(why)))
    end

    if action == "acheter" then
        local homeId = args[2] and args[2]:lower()
        if not homeId then
            sendMarket(source)
            return
        end
        if not atAgency(source) then return say(source, "Deeds are signed at the agency desk, 7 m south-west of the spawn.") end
        local bought, why = buy(source, homeId)
        if not bought then return say(source, why) end
        local home = Config.home(homeId)
        return say(source, ("%s is yours (paid from %s). E on the door to enter."):format(home.label, why))
    end

    say(source, "/maison - /maison cles <playerId> - /maison retirer <playerId|tous> - /maison spawn - /maison vendre - /maison acheter <home>")
end, false)

RegisterCommand("loyer", function(source, args)
    if fromConsole(source) then return end
    if not loaded then return say(source, "The housing registry is still loading, choom.") end
    local homeId = homeIdOf(ident(source))
    if not homeId then return say(source, "No rent to pay: you own no place.") end
    local h = homes[homeId]
    local home = Config.home(homeId)
    local action = (args[1] or ""):lower()
    if action == "payer" or action == "pay" then
        local count = h.unpaid > 0 and h.unpaid or 1
        local advance = h.unpaid == 0
        local ok, via, cashWhy = collectRent(source, homeId, count, advance)
        if not ok then
            return say(source, ("Could not collect %s €$ (%s / %s). Deposit at an ATM first."):format(
                money(home.rent * count), tostring(via), tostring(cashWhy)))
        end
        if advance then
            return say(source, ("Paid one payday in advance: %s €$ from %s. Next rent in %d min."):format(
                money(home.rent), via, math.ceil((h.rentDueAt - now()) / 60)))
        end
        return say(source, ("Arrears cleared: %s €$ from %s. You keep %s."):format(money(home.rent * count), via, home.label))
    end
    local left = h.rentDueAt - now()
    say(source, ("%s: rent %s €$ per payday (every %d min), %s, unpaid %d/%d. /loyer payer pays now."):format(
        home.label, money(home.rent), math.floor(Config.rentIntervalSec / 60),
        left > 0 and ("next in %d min"):format(math.ceil(left / 60)) or "due now", h.unpaid, Config.evictAfter))
end, false)

-- ---------------------------------------------------------------------------
-- Exports (phase 3 contract; synchronous-safe, nothing yields)
-- ---------------------------------------------------------------------------

-- Session ids only (integer >= 1): Open77.players.identifier raises on anything else,
-- and a raise inside a synchronous export kills this VM.
local function sessionId(playerId)
    local id = tonumber(playerId)
    if not id or id < 1 or id % 1 ~= 0 then return nil end
    return id
end

exports("homeOf", function(playerId)
    playerId = sessionId(playerId)
    if not playerId then return nil end
    local homeId = homeIdOf(ident(playerId))
    if not homeId then return nil end
    local home = Config.home(homeId)
    return { id = homeId, label = home.label, position = { x = home.sideB.x, y = home.sideB.y, z = home.sideB.z } }
end)

exports("hasKey", function(playerId, homeId)
    playerId = sessionId(playerId)
    if not playerId or type(homeId) ~= "string" then return false end
    return hasAccess(ident(playerId), homeId)
end)

exports("stashOf", function(homeId)
    if type(homeId) ~= "string" or not Config.home(homeId) then return nil end
    return "home:" .. homeId
end)

exports("isInside", function(playerId)
    playerId = sessionId(playerId)
    if not playerId then return nil end
    return inside[playerId]
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

RegisterNetEvent("chat:ready", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    Open77.chat.addSuggestions(playerId, SUGGESTIONS)
end)

AddEventHandler("onPlayerReady", function(playerId)
    local id = sessionId(playerId)
    if not id then return end
    local waited = 0
    while not loaded and waited < 30000 do
        Wait(500)
        waited = waited + 500
    end
    if not Open77.players.name(id) then return end
    sendState(id)
    local identifier = ident(id)
    local homeId = homeIdOf(identifier)
    if not homeId then return end
    local home = Config.home(homeId)
    local h = homes[homeId]
    syncHomeDoor(homeId)
    say(id, ("Welcome back. %s is waiting for you (%s). /maison for the details."):format(
        home.label, h.unpaid > 0 and ("rent unpaid %d/%d"):format(h.unpaid, Config.evictAfter) or "rent in order"))
    if not h.spawnAtHome then return end

    -- No spawn-point API on this host: the gamemode places the body at the
    -- market, and we move it once it is standing (never on the continue screen).
    local t, alive = 0, false
    while t < Config.spawnWaitSec * 1000 do
        if not Open77.players.name(id) then return end
        local life = Open77.players.getLifeState(id)
        if life and life.phase == "alive" then alive = true break end
        Wait(1000)
        t = t + 1000
    end
    -- Never move a body that is not standing (continue screen = client crash): give up instead.
    if not alive then
        log("player %d never reached the alive phase within %d s: spawn at home skipped", id, Config.spawnWaitSec)
        return
    end
    Wait(1500)
    if not Open77.players.name(id) or not homes[homeId] or homes[homeId].identifier ~= identifier then return end
    local ok, why = move(id, home.interior, home.heading)
    if not ok then
        log("player %d could not spawn at home %s: %s", id, homeId, tostring(why))
        return say(id, ("Could not bring you home (%s). Walk there, the door is on your map."):format(tostring(why)))
    end
    inside[id] = homeId
    sendState(id)
    say(id, ("Home sweet home: you wake up in %s."):format(home.label))
    log("player %d spawned at home %s", id, homeId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if not id then return end
    inside[id] = nil
    moving[id] = nil
    stageClear(id)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log("started, %d homes, agency at %.1f, %.1f, %.1f", #Config.homes,
        Config.agency.position.x, Config.agency.position.y, Config.agency.position.z)
    Open77.chat.addSuggestions(-1, SUGGESTIONS)

    for _, home in ipairs(Config.homes) do
        local zone, why = Open77.zones.normalize({
            shape = "sphere",
            position = { x = home.interior.x, y = home.interior.y, z = home.interior.z },
            radius = home.interiorRadius or Config.interiorRadius,
        })
        if zone then interiorZones[home.id] = zone else log("interior zone of %s refused: %s", home.id, tostring(why)) end
    end

    local ok, reason = Open77.database.ready(function() loadFromSql() end)
    if not ok then loadFromKvp(reason) end
    CreateThread(function()
        Wait(20000)
        if not loaded then loadFromKvp("database not answering after 20 s") end
    end)

    spawnProps("agency", Config.agency.props)

    -- Hot reload: the players already in the city get their pins and their doors back.
    -- The auto door search runs first so a door already discovered is claimed at once.
    CreateThread(function()
        while not loaded do Wait(500) end
        for _, home in ipairs(Config.homes) do resolveAutoDoor(home) end
        broadcastState()
        syncAllDoors()
    end)

    -- Rent tick.
    CreateThread(function()
        while true do
            Wait(Config.rentTickSec * 1000)
            rentTick()
        end
    end)

    -- Inside sweep: a player who wandered further than the interior radius (or
    -- died and respawned at the market) is no longer inside.
    CreateThread(function()
        while true do
            Wait(5000)
            for pid, homeId in pairs(inside) do
                local zone = interiorZones[homeId]
                if zone and not moving[pid] then
                    local contained = Open77.zones.containsPlayer(pid, zone)
                    if contained == false then
                        inside[pid] = nil
                        sendState(pid)
                        say(pid, ("You left %s."):format(Config.home(homeId).label))
                    end
                end
            end
        end
    end)

    -- Front doors not found yet (auto door) and doors not discovered yet are
    -- retried every Config.autoDoor.retrySec.
    CreateThread(function()
        while true do
            Wait(Config.autoDoor.retrySec * 1000)
            for _, home in ipairs(Config.homes) do
                if home.doorId == "" then resolveAutoDoor(home) end
                if home.doorId ~= "" and doorState[home.doorId] ~= "ready" then syncDoor(home) end
            end
        end
    end)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    removeProps()
end)
