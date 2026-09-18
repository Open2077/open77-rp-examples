-- rp_housing / client: presentation only. Rings and E prompts through
-- open77_worldui, map pins through Open77.blips, the ALT+click "Give a key"
-- action through open77_contextmenu. Every press becomes a minimal request to
-- the server, which re-checks distance, ownership and keys before anything moves.

local TAG = "[rp_housing]"

local state = { mine = false, owned = {}, keys = {}, inside = false } -- last server snapshot
local blips = {}          -- [homeId | "agency"] = blip id
local sideAHandles = {}   -- [homeId] = worldui handle of the door ring on side A (moved by the auto door)
local sideBHandles = {}   -- [homeId] = worldui handle of the door ring on side B (moved by the auto door)
local stashHandles = {}   -- [homeId] = worldui handle of the stash ring (moved by the auto door)
local generations = {}    -- ["<kind>:<homeId>"] = n, the last worldui id suffix used (never reused in a session)
local poisCreated = false
local actionRegistered = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function worldui(name, ...)
    local pending, reason = Open77.exports.call("open77_worldui", name, ...)
    if not pending then return nil, reason end
    return pending:await()
end

local function menu(name, ...)
    local pending, reason = Open77.exports.call("open77_contextmenu", name, ...)
    if not pending then return nil, reason end
    return pending:await()
end

local function pos(p)
    return { x = p.x, y = p.y, z = p.z }
end

-- ---------------------------------------------------------------------------
-- Rings and prompts: two door rings (one per side) and a stash per home, plus
-- the agency. Every worldui id carries a generation suffix (`door_a:<id>:<n>`):
-- a ring re-created under an id already used this session kept a frozen
-- distance and never fired (measured 2026-09-18), so an id is never reused.
-- ---------------------------------------------------------------------------

local function nextPoiId(kind, homeId)
    local key = homeId and (kind .. ":" .. homeId) or kind
    generations[key] = (generations[key] or 0) + 1
    return key .. ":" .. tostring(generations[key])
end

local function createPoi(definition)
    local result, err = worldui("create", definition)
    if not result or not result.ok then
        print(("%s poi %s refused: %s"):format(TAG, definition.id, tostring(err or (result and result.error))))
        return nil
    end
    return result.handle
end

-- Both sides of the door share the label, the description and the intent: the
-- server tells from the nearer ring which side the player stands on.
local function doorDefinition(home, kind, field)
    return {
        id = nextPoiId(kind, home.id),
        position = pos(home[field]),
        radius = 1.0,
        style = "interaction",
        label = Config.text.door,
        description = home.label .. " - " .. Config.text.doorDescription,
        key = "E",
        icon = "H",
        marker = "door",
        promptDistance = Config.promptDistance,
        event = "rp_housing:poi:door:" .. home.id,
    }
end

local function sideADefinition(home) return doorDefinition(home, "door_a", "sideA") end
local function sideBDefinition(home) return doorDefinition(home, "door_b", "sideB") end

local function stashDefinition(home)
    return {
        id = nextPoiId("stash", home.id),
        position = pos(home.stash),
        radius = 0.6,
        style = "objective",
        maxDistance = 40.0,
        label = Config.text.stash,
        description = Config.text.stashDescription,
        key = "E",
        icon = "S",
        promptDistance = Config.promptDistance,
        event = "rp_housing:poi:stash:" .. home.id,
    }
end

-- The three ring kinds the server can move at runtime (auto door): the field
-- of the home / snapshot that carries the position, the handle table and the
-- POI definition.
local RINGS = {
    { field = "sideA", snapshotField = "sideA", handles = sideAHandles, definition = sideADefinition, name = "door_a" },
    { field = "sideB", snapshotField = "sideB", handles = sideBHandles, definition = sideBDefinition, name = "door_b" },
    { field = "stash", snapshotField = "stashes", handles = stashHandles, definition = stashDefinition, name = "stash" },
}

-- The server moved a ring (auto door): drop the old POI, create the new one
-- under a fresh id (generation suffix), never the same id twice in a session.
local function recreatePoi(ring, home)
    if ring.handles[home.id] then
        worldui("remove", ring.handles[home.id])
        ring.handles[home.id] = nil
    end
    local definition = ring.definition(home)
    ring.handles[home.id] = createPoi(definition)
    if ring.handles[home.id] then
        print(("%s %s ring of %s recreated as %s"):format(TAG, ring.name, home.id, definition.id))
    end
end

local function createPois()
    if poisCreated then return end
    poisCreated = true
    local created = 0

    if createPoi({
        id = nextPoiId("agency"),
        position = pos(Config.agency.position),
        radius = Config.agency.radius or 1.5,
        style = "interaction",
        label = Config.agency.label,
        description = Config.agency.description,
        key = "E",
        icon = "H",
        marker = "shop",
        promptDistance = Config.promptDistance,
        event = "rp_housing:poi:agency",
    }) then created = created + 1 end

    for _, home in ipairs(Config.homes) do
        for _, ring in ipairs(RINGS) do
            ring.handles[home.id] = createPoi(ring.definition(home))
            if ring.handles[home.id] then created = created + 1 end
        end
    end
    print(("%s %d world prompts created"):format(TAG, created))
end

-- The prompt events. One name per POI so the handler knows which home without
-- trusting anything but its own closure; the server re-checks everything.
AddEventHandler("rp_housing:poi:agency", function()
    TriggerServerEvent("rp_housing:agency")
end)

for _, home in ipairs(Config.homes) do
    local id = home.id
    AddEventHandler("rp_housing:poi:door:" .. id, function()
        TriggerServerEvent("rp_housing:door", id)
    end)
    AddEventHandler("rp_housing:poi:stash:" .. id, function()
        TriggerServerEvent("rp_housing:stash", id)
    end)
    -- No ring raises it any more (the door is the same pass-through from both
    -- sides); kept so nothing that still fires the old name breaks.
    AddEventHandler("rp_housing:poi:exit:" .. id, function()
        TriggerServerEvent("rp_housing:door", id)
    end)
end

-- ---------------------------------------------------------------------------
-- Map pins: the agency, and one pin per home whose sprite follows ownership
-- ---------------------------------------------------------------------------

local function homeSprite(homeId)
    if state.mine == homeId then return "apartment", "Your place" end
    for _, id in ipairs(state.keys or {}) do
        if id == homeId then return "apartment", "You hold a key" end
    end
    local owner = state.owned and state.owned[homeId]
    if owner then return "ApartmentVariant", "Owned by " .. tostring(owner) end
    return "Zzz05_ApartmentToPurchaseVariant", "For sale"
end

local function refreshBlips()
    if not blips.agency then
        local id, reason = Open77.blips.create({
            position = pos(Config.agency.position),
            sprite = "vendor",
            title = Config.agency.label,
            description = Config.agency.description,
        })
        if id then blips.agency = id else print(TAG .. " agency pin refused: " .. tostring(reason)) end
    end
    for _, home in ipairs(Config.homes) do
        local sprite, status = homeSprite(home.id)
        local title = ("%s - %s"):format(home.label, status)
        local description = ("%s €$, rent %s €$ per payday. %s"):format(
            tostring(home.price), tostring(home.rent), home.district or "")
        if blips[home.id] then
            Open77.blips.remove(blips[home.id])
            blips[home.id] = nil
        end
        local id, reason = Open77.blips.create({
            position = pos(home.sideB),
            sprite = sprite,
            title = title,
            description = description,
        })
        if id then blips[home.id] = id else print(TAG .. " pin for " .. home.id .. " refused: " .. tostring(reason)) end
    end
end

-- Rings resolved by the server (auto door): the two door rings and the stash
-- move together, along the interior -> door axis. Move ours when they differ
-- from what we drew.
local function applyRings(snapshot)
    for _, ring in ipairs(RINGS) do
        local positions = snapshot[ring.snapshotField]
        if type(positions) == "table" then
            for _, home in ipairs(Config.homes) do
                local e = positions[home.id]
                if type(e) == "table" and type(e.x) == "number" and type(e.y) == "number" and type(e.z) == "number" then
                    local cur = home[ring.field]
                    if math.abs(cur.x - e.x) > 0.05 or math.abs(cur.y - e.y) > 0.05 or math.abs(cur.z - e.z) > 0.05 then
                        home[ring.field] = { x = e.x, y = e.y, z = e.z }
                        print(("%s %s ring of %s moved to %.1f, %.1f, %.1f (auto door)"):format(TAG, ring.name, home.id, e.x, e.y, e.z))
                        if poisCreated then CreateThread(function() recreatePoi(ring, home) end) end
                    end
                end
            end
        end
    end
end

RegisterNetEvent("rp_housing:state", function(snapshot)
    if type(snapshot) ~= "table" then return end
    state.mine = snapshot.mine or false
    state.owned = snapshot.owned or {}
    state.keys = snapshot.keys or {}
    state.inside = snapshot.inside or false
    applyRings(snapshot)
    refreshBlips()
end)

-- ---------------------------------------------------------------------------
-- ALT+click a player > "Give a key" (owners only; the server re-checks)
-- ---------------------------------------------------------------------------

exports("canGiveKey", function(context)
    if state.mine == false or state.mine == nil then return false end
    return context ~= nil and context.target ~= nil and context.target.playerId ~= nil
end)

exports("giveKey", function(context)
    local target = context and context.target and context.target.playerId
    if target == nil then return false end
    TriggerServerEvent("rp_housing:giveKey", target)
    return true
end)

local function registerAction()
    local token, err = menu("registerPlayers", {
        id = "give_key",
        label = "Give a key",
        description = "Hand this choom a key to your place.",
        group = "Housing",
        icon = "lock",
        networked = true,
        distance = Config.keyDistance,
        order = 40,
        canInteract = "canGiveKey",
        onSelect = "giveKey",
    })
    if not token then
        print(TAG .. " context action refused: " .. tostring(err))
        return
    end
    actionRegistered = true
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then
        CreateThread(function()
            createPois()
            registerAction()
            refreshBlips()
            TriggerServerEvent("rp_housing:clientReady")
        end)
    elseif name == "open77_worldui" then
        -- The facade restarted: its generation dropped our handles. Recreate.
        poisCreated = false
        CreateThread(createPois)
    elseif name == "open77_contextmenu" then
        actionRegistered = false
        CreateThread(registerAction)
    end
end)
