-- rp_ripperdoc client: the chair prompt (open77_worldui) and the ALT+click
-- "Operate" action (open77_contextmenu). Everything here is a request; the
-- server decides who may operate, on whom, and what it costs.
local RESOURCE = GetCurrentResourceName()
local cfg = RpRipperConfig

local onDuty = false        -- pushed by the server (rp_ripperdoc:duty)
local chairHandle = nil     -- open77_worldui POI handle
local operateToken = nil    -- open77_contextmenu action token

local function call(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Context-menu predicates and callbacks must be exports of THIS resource.
exports("rpRipperCanOperate", function(context)
    local target = context and context.target
    if not target or target.kind ~= "player" or target.isLocalPlayer then return false end
    if target.playerId == nil then return false end
    return onDuty == true
end)

exports("rpRipperOperate", function(context)
    local target = context and context.target
    if not target or target.playerId == nil then return false end
    -- Only the canonical target id crosses to the server; it re-checks everything.
    TriggerServerEvent("rp_ripperdoc:operate", target.playerId)
    return true
end)

-- The chair prompt was pressed: ask the server to lie down (or to get up).
AddEventHandler("rp_ripperdoc:chairPrompt", function()
    TriggerServerEvent("rp_ripperdoc:chair")
end)

local function registerChair()
    if chairHandle then
        call("open77_worldui", "remove", chairHandle)
        chairHandle = nil
    end
    local result, reason = call("open77_worldui", "create", {
        id = "ripper_chair",
        position = cfg.chair.position,
        radius = cfg.chair.radius,
        style = "interaction",
        maxDistance = 80.0,
        label = cfg.chair.label,
        description = cfg.chair.description,
        key = "E",
        color = "#B57BFF",
        promptDistance = cfg.chair.promptDistance,
        event = "rp_ripperdoc:chairPrompt",
    })
    if not result then
        print("[rp_ripperdoc] chair POI refused: " .. tostring(reason))
    elseif not result.ok then
        print("[rp_ripperdoc] chair POI failed: " .. tostring(result.error))
    else
        chairHandle = result.handle
    end
end

local function registerOperate()
    local token, reason = call("open77_contextmenu", "registerPlayers", {
        id = "rp_ripperdoc_operate",
        label = "Operate",
        description = "Open the ripperdoc catalogue for this patient.",
        group = "Ripperdoc",
        icon = "tool",
        networked = true,
        distance = cfg.operateDistance,
        order = 40,
        canInteract = "rpRipperCanOperate",
        onSelect = "rpRipperOperate",
    })
    if not token then
        print("[rp_ripperdoc] context-menu action refused: " .. tostring(reason))
    else
        operateToken = token
    end
end

RegisterNetEvent("rp_ripperdoc:duty", function(flag)
    onDuty = (flag == true or flag == "true" or flag == 1)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE then
        CreateThread(function()
            registerChair()
            registerOperate()
            TriggerServerEvent("rp_ripperdoc:clientReady")
        end)
    elseif name == "open77_worldui" then
        CreateThread(registerChair)
    elseif name == "open77_contextmenu" then
        CreateThread(registerOperate)
    end
end)
