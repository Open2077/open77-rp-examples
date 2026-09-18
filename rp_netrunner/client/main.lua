-- rp_netrunner client: renders what the server decided and forwards requests.
-- Nothing here grants a hack: the ALT+click entries only send a target id, the ping blip
-- follows positions the server relays, the access-point prompt only sends an intent.

local RESOURCE = GetCurrentResourceName()

local state = {
    onDuty = false,     -- the server says this player is an on-duty netrunner
    pings = {},         -- targetPlayerId -> blip id
    poiHandle = nil,    -- open77_worldui handle of the access point
}

local function callExport(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- ---------------------------------------------------------------------------
-- ALT+click actions (open77_contextmenu): shown only while the server said on duty;
-- the server checks job, duty, item, cooldown, distance and target again.
-- ---------------------------------------------------------------------------

exports("canNetrun", function(context)
    if not state.onDuty then return false end
    if not context or not context.target or context.target.playerId == nil then return false end
    if context.target.isLocalPlayer then return false end
    return true
end)

exports("selectPing", function(context)
    TriggerServerEvent("rp_netrunner:action", "ping", context.target.playerId)
    return true
end)

exports("selectShortCircuit", function(context)
    TriggerServerEvent("rp_netrunner:action", "short_circuit", context.target.playerId)
    return true
end)

exports("selectOverheat", function(context)
    TriggerServerEvent("rp_netrunner:action", "overheat", context.target.playerId)
    return true
end)

local function registerActions()
    local hackRange = math.min(50, math.max(Config.hacks.short_circuit.range, Config.hacks.overheat.range))
    local tokens, reason = callExport("open77_contextmenu", "registerPlayers", {
        {
            id = "rp_netrunner_ping", label = "Ping", group = "Netrunner", icon = "info",
            description = "Track this choom on your map for a minute.",
            networked = true, distance = math.min(50, Config.ping.range), order = 40,
            canInteract = "canNetrun", onSelect = "selectPing",
        },
        {
            id = "rp_netrunner_short_circuit", label = "Short Circuit", group = "Netrunner", icon = "tool",
            description = "Upload a Short Circuit quickhack.",
            networked = true, distance = hackRange, order = 41, danger = true,
            canInteract = "canNetrun", onSelect = "selectShortCircuit",
        },
        {
            id = "rp_netrunner_overheat", label = "Overheat", group = "Netrunner", icon = "tool",
            description = "Upload an Overheat quickhack.",
            networked = true, distance = hackRange, order = 42, danger = true,
            canInteract = "canNetrun", onSelect = "selectOverheat",
        },
    })
    if not tokens then
        print(("[rp_netrunner] context menu registration failed: %s"):format(tostring(reason)))
    end
end

-- ---------------------------------------------------------------------------
-- The access point: a ring, a map pin and an E prompt (open77_worldui).
-- ---------------------------------------------------------------------------

local function registerAccessPoint()
    local ap = Config.accessPoint
    local result, reason = callExport("open77_worldui", "create", {
        id = "rp_netrunner_access_point",
        position = ap.position,
        radius = ap.radius,
        style = "interaction",
        maxDistance = 90.0,
        label = ap.label,
        description = ap.description,
        key = "E",
        holdSeconds = 0.5,
        color = "#00E5FF",
        promptDistance = ap.promptDistance,
        event = "rp_netrunner:breachPrompt",
    })
    if not result or not result.ok then
        print(("[rp_netrunner] access point POI failed: %s"):format(tostring(reason or (result and result.error))))
        return
    end
    state.poiHandle = result.handle
end

AddEventHandler("rp_netrunner:breachPrompt", function()
    -- Only an intent: the server checks job, duty, distance and the data chip.
    TriggerServerEvent("rp_netrunner:breach")
end)

-- ---------------------------------------------------------------------------
-- Ping blips: created, moved and removed on the server's word.
-- ---------------------------------------------------------------------------

local function dropPing(targetId)
    local blip = state.pings[targetId]
    if blip then
        Open77.blips.remove(blip)
        state.pings[targetId] = nil
    end
end

RegisterNetEvent("rp_netrunner:ping", function(targetId, targetName, position)
    dropPing(targetId)
    local blip, reason = Open77.blips.create({
        position = position,
        sprite = Config.ping.sprite,
        title = ("Ping: %s"):format(tostring(targetName)),
        description = "Netrunner trace. Fades in a minute.",
        active = true,
        visibleThroughWalls = true,
    })
    if not blip then
        print(("[rp_netrunner] ping blip refused: %s"):format(tostring(reason)))
        return
    end
    state.pings[targetId] = blip
end)

RegisterNetEvent("rp_netrunner:pingUpdate", function(targetId, position)
    local blip = state.pings[targetId]
    if blip then Open77.blips.setPosition(blip, position) end
end)

RegisterNetEvent("rp_netrunner:pingEnd", function(targetId)
    dropPing(targetId)
end)

-- ---------------------------------------------------------------------------
-- Duty state and the door fallback (the player's own open77_doors request).
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_netrunner:self", function(onDuty)
    state.onDuty = onDuty == true
end)

-- The server could not open the door with its own authority: queue the player's
-- own request and report what the door service answered.
RegisterNetEvent("rp_netrunner:requestDoor", function(doorId)
    CreateThread(function()
        local ok, reason = callExport("open77_doors", "requestOpen", doorId, true)
        if not ok then
            TriggerServerEvent("rp_netrunner:doorResult", doorId, false, tostring(reason or "request_refused"))
        end
    end)
end)

RegisterNetEvent("open77:doors:requestResult", function(id, accepted, reason)
    TriggerServerEvent("rp_netrunner:doorResult", id, accepted == true, tostring(reason or ""))
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE or name == "open77_contextmenu" or name == "open77_worldui" then
        CreateThread(function()
            if name == RESOURCE or name == "open77_contextmenu" then registerActions() end
            if name == RESOURCE or name == "open77_worldui" then registerAccessPoint() end
            if name == RESOURCE then TriggerServerEvent("rp_netrunner:clientReady") end
        end)
    end
end)
