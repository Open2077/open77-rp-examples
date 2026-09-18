-- rp_mecano / client: ALT+click entries for the garage job, plus two bare rings
-- (open77_worldui, nothing to press) at the workshop and the CHOOH2 pump.
-- Nothing is decided here. Every entry sends a request to the server, which
-- checks the job, the duty state, the distance and the money again.

local mechanicOnDuty = false -- pushed by the server (rp_mecano:duty); a UX hint only

RegisterNetEvent("rp_mecano:duty", function(onDuty)
    mechanicOnDuty = onDuty == true
end)

-- canInteract predicate: hide the garage entries from everybody but an on-duty mechanic.
exports("rpMecanoCanInteract", function()
    return mechanicOnDuty == true
end)

exports("rpMecanoBill", function(ctx)
    local target = ctx and ctx.target and ctx.target.playerId
    if target == nil then return false end
    TriggerServerEvent("rp_mecano:billMenu", target)
    return true
end)

local function vehicleAction(action)
    return function(ctx)
        local vehicleId = ctx and ctx.target and ctx.target.vehicleId
        if vehicleId == nil then return false end
        TriggerServerEvent("rp_mecano:action", action, vehicleId)
        return true
    end
end

exports("rpMecanoRepair", vehicleAction("repair"))
exports("rpMecanoTow", vehicleAction("tow"))
exports("rpMecanoPaint", vehicleAction("paint"))
exports("rpMecanoImpound", vehicleAction("impound"))
exports("rpMecanoRefuel", vehicleAction("refuel"))

local function menu(method, ...)
    local promise, dispatchError = Open77.exports.call("open77_contextmenu", method, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

local function registerActions()
    local player, perr = menu("registerPlayers", {
        id = "rp_mecano_bill",
        label = "Hand an invoice (garage)",
        description = "Bill this citizen for garage work. They accept or decline.",
        group = "Garage",
        icon = "tool",
        networked = true,
        distance = 6.0,
        order = 40,
        canInteract = "rpMecanoCanInteract",
        onSelect = "rpMecanoBill",
    })
    if not player then print("[rp_mecano] context menu (players): " .. tostring(perr)) end

    local vehicles, verr = menu("registerVehicles", {
        {
            id = "rp_mecano_repair", label = "Repair (garage)", group = "Garage", icon = "tool",
            description = "15 s, two components.", networked = true, distance = 4.0, order = 40,
            canInteract = "rpMecanoCanInteract", onSelect = "rpMecanoRepair",
        },
        {
            id = "rp_mecano_paint", label = "Paint job (garage)", group = "Garage", icon = "tool",
            description = "Pick a colour; the driver is billed.", networked = true, distance = 6.0, order = 41,
            canInteract = "rpMecanoCanInteract", onSelect = "rpMecanoPaint",
        },
        {
            id = "rp_mecano_tow", label = "Hook / release tow (garage)", group = "Garage", icon = "vehicle",
            description = "From the driver's seat of your truck.", networked = true, distance = 8.0, order = 42,
            canInteract = "rpMecanoCanInteract", onSelect = "rpMecanoTow",
        },
        {
            id = "rp_mecano_refuel", label = "Refuel (garage)", group = "Garage", icon = "vehicle",
            description = "One CHOOH2 can.", networked = true, distance = 4.0, order = 43,
            canInteract = "rpMecanoCanInteract", onSelect = "rpMecanoRefuel",
        },
        {
            id = "rp_mecano_impound", label = "Impound (garage)", group = "Garage", icon = "lock",
            description = "At the junkyard (impound zone), empty vehicles only.", networked = true, distance = 8.0, order = 44,
            danger = true, canInteract = "rpMecanoCanInteract", onSelect = "rpMecanoImpound",
        },
    })
    if not vehicles then print("[rp_mecano] context menu (vehicles): " .. tostring(verr)) end
end

-- The workshop and pump rings: bare markers (no prompt, nothing to press).
local poiHandles = {}

local function worldui(method, ...)
    local promise, dispatchError = Open77.exports.call("open77_worldui", method, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

local function placeRings()
    for _, entry in ipairs({ { id = "rp_mecano_workshop", spot = Config.workshop }, { id = "rp_mecano_pump", spot = Config.pump } }) do
        local spot = entry.spot
        if type(spot) == "table" and type(spot.position) == "table" then
            local result, err = worldui("create", {
                id = entry.id,
                position = { x = spot.position.x, y = spot.position.y, z = spot.position.z },
                radius = spot.radius or 2.0,
                style = "interaction",
                maxDistance = 120.0,
                color = "#F5A623",
            })
            if result and result.ok then
                poiHandles[#poiHandles + 1] = result.handle
            else
                print(("[rp_mecano] ring %s refused: %s"):format(entry.id, tostring(err or (result and result.error))))
            end
        end
    end
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() and name ~= "open77_contextmenu" then return end
    CreateThread(function()
        registerActions()
        if name == GetCurrentResourceName() then
            placeRings()
            TriggerServerEvent("rp_mecano:whoami")
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, handle in ipairs(poiHandles) do worldui("remove", handle) end
    poiHandles = {}
end)
