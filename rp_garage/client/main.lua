-- rp_garage client: places the three POIs (two garages, the dealership) through open77_worldui
-- and adds ALT+click entries through open77_contextmenu. Nothing is decided here: every prompt
-- and every menu entry only sends a request, the server re-checks distance and ownership.

local function call(resource, name, ...)
    local promise, dispatchError = Open77.exports.call(resource, name, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

-- ---------------------------------------------------------------------------------------------
-- POIs
-- ---------------------------------------------------------------------------------------------

local pois = {}

local function poiDefinition(id, label, description, position, color, event)
    return {
        id = id,
        position = { x = position.x, y = position.y, z = position.z },
        radius = 2.0,
        style = "interaction",
        maxDistance = 90.0,
        label = label,
        description = description,
        key = "E",
        color = color,
        promptDistance = Config.reach.prompt,
        event = event,
    }
end

local function createPois()
    -- Remove ours first: a re-create under the same id after a worldui restart must not double.
    for _, handle in pairs(pois) do
        call("open77_worldui", "remove", handle)
    end
    pois = {}
    local definitions = {}
    for _, g in ipairs(Config.garages) do
        definitions[#definitions + 1] = poiDefinition("rp_garage_" .. g.id, g.label,
            g.kind == "society" and ("Store or take out a vehicle (%s crew)."):format(g.society) or "Store or take out your vehicle.",
            g.position, g.color or "#00E5FF", "rp_garage:poi:" .. g.id)
    end
    definitions[#definitions + 1] = poiDefinition("rp_garage_dealer", Config.dealership.label,
        "Buy a vehicle: plate and keys included.", Config.dealership.position, Config.dealership.color or "#F5D90A", "rp_garage:poi:dealer")
    for _, definition in ipairs(definitions) do
        local result, err = call("open77_worldui", "create", definition)
        if result and result.ok then
            pois[definition.id] = result.handle
        else
            print(("[rp_garage] POI %s not created: %s"):format(definition.id, tostring(err or (result and result.error) or "unknown")))
        end
    end
end

for _, g in ipairs(Config.garages) do
    AddEventHandler("rp_garage:poi:" .. g.id, function()
        TriggerServerEvent("rp_garage:open", g.id)
    end)
end

AddEventHandler("rp_garage:poi:dealer", function()
    TriggerServerEvent("rp_garage:dealer")
end)

-- ---------------------------------------------------------------------------------------------
-- ALT+click entries (open77_contextmenu). The callbacks are exports of THIS resource.
-- ---------------------------------------------------------------------------------------------

exports("rpGarageCanGiveKey", function(context)
    return context and context.target and context.target.playerId ~= nil and context.kind ~= "self"
end)

exports("rpGarageGiveKey", function(context)
    if not context or not context.target or context.target.playerId == nil then return false end
    TriggerServerEvent("rp_garage:giveKey", context.target.playerId)
    return true
end)

exports("rpGarageCanVehicle", function(context)
    return context and context.target and context.target.vehicleId ~= nil
end)

exports("rpGarageLock", function(context)
    if not context or not context.target or context.target.vehicleId == nil then return false end
    TriggerServerEvent("rp_garage:action", "lock", context.target.vehicleId)
    return true
end)

exports("rpGaragePlate", function(context)
    if not context or not context.target or context.target.vehicleId == nil then return false end
    TriggerServerEvent("rp_garage:action", "plate", context.target.vehicleId)
    return true
end)

local function registerActions()
    local token, err = call("open77_contextmenu", "registerPlayers", {
        id = "rp_garage_give_key",
        label = "Give a key",
        description = "Hand this citizen a duplicate key of your vehicle (the one you sit in, or the nearest one).",
        group = "Garage",
        icon = "lock",
        distance = Config.reach.key,
        order = 40,
        canInteract = "rpGarageCanGiveKey",
        onSelect = "rpGarageGiveKey",
    })
    if not token then print("[rp_garage] contextmenu give_key: " .. tostring(err)) end
    local tokens, err2 = call("open77_contextmenu", "registerVehicles", {
        {
            id = "rp_garage_lock",
            label = "Lock / unlock",
            description = "Toggle the lock of a vehicle you hold a key for.",
            group = "Garage",
            icon = "lock",
            networked = true,
            distance = Config.reach.lock,
            order = 30,
            canInteract = "rpGarageCanVehicle",
            onSelect = "rpGarageLock",
        },
        {
            id = "rp_garage_plate",
            label = "Read the plate",
            description = "Plate, owner and wanted flag.",
            group = "Garage",
            icon = "info",
            networked = true,
            distance = Config.reach.plate,
            order = 31,
            canInteract = "rpGarageCanVehicle",
            onSelect = "rpGaragePlate",
        },
    })
    if not tokens then print("[rp_garage] contextmenu vehicles: " .. tostring(err2)) end
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle: register on our own start, and again when a provider restarts underneath us.
-- ---------------------------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    local me = GetCurrentResourceName()
    if name == me or name == "open77_worldui" then
        CreateThread(function()
            Wait(500)
            createPois()
        end)
    end
    if name == me or name == "open77_contextmenu" then
        CreateThread(function()
            Wait(500)
            registerActions()
        end)
    end
end)
