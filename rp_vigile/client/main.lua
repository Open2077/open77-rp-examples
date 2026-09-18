-- rp_vigile client: the ALT+click actions a security guard gets inside a guarded
-- zone. Nothing here decides anything: the server pushes whether this player is
-- guarding a zone, the menu shows the actions, and every click is a request the
-- server re-validates (contract, zone, distance, life, ACL of the RP kit).

local RESOURCE = GetCurrentResourceName()

-- What the server last told us. `guarding` gates the actions; `escorting` maps
-- targetId -> true for the players this guard is currently walking out.
local state = { guarding = false, zone = nil, label = nil, escorting = {} }

local function menu(method, ...)
    local promise, dispatchError = Open77.exports.call("open77_contextmenu", method, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

-- Predicates: must return exactly `true` to show the entry. They are a UX
-- convenience only; the server checks the same facts again.
exports("vigileCanEscortOut", function(ctx)
    if not state.guarding then return false end
    local target = ctx and ctx.target
    if not target or target.kind ~= "player" or target.isLocalPlayer then return false end
    if not target.playerId then return false end
    if state.escorting[target.playerId] then return false end
    return true
end)

exports("vigileCanRelease", function(ctx)
    if not state.guarding then return false end
    local target = ctx and ctx.target
    if not target or target.kind ~= "player" or target.isLocalPlayer then return false end
    if not target.playerId then return false end
    return state.escorting[target.playerId] == true
end)

-- Actions: one request each, carrying only the canonical target id.
exports("vigileEscortOut", function(ctx)
    local target = ctx and ctx.target
    if not target or not target.playerId then return false end
    TriggerServerEvent("rp_vigile:escort", target.playerId)
    return true
end)

exports("vigileRelease", function(ctx)
    local target = ctx and ctx.target
    if not target or not target.playerId then return false end
    TriggerServerEvent("rp_vigile:release", target.playerId)
    return true
end)

local function registerActions()
    local token, err = menu("registerPlayers", {
        id = "rp_vigile_escort_out",
        label = "Escort out (security)",
        description = "Walk this person out of the zone you are guarding.",
        group = "Security",
        icon = "person",
        networked = true,
        distance = VigileConfig.escortRange,
        order = 40,
        canInteract = "vigileCanEscortOut",
        onSelect = "vigileEscortOut",
    })
    if not token then print(("[rp_vigile] context menu registration failed: %s"):format(tostring(err))) end

    local releaseToken, releaseErr = menu("registerPlayers", {
        id = "rp_vigile_release",
        label = "Release (security)",
        description = "Let this person go.",
        group = "Security",
        icon = "person",
        networked = true,
        distance = 10.0,
        order = 41,
        canInteract = "vigileCanRelease",
        onSelect = "vigileRelease",
    })
    if not releaseToken then print(("[rp_vigile] context menu registration failed: %s"):format(tostring(releaseErr))) end
end

-- The server pushes the guard state whenever it changes, and once on request.
RegisterNetEvent("rp_vigile:state", function(pushed)
    if type(pushed) ~= "table" then return end
    state.guarding = pushed.guarding == true
    state.zone = pushed.zone
    state.label = pushed.label
    local escorting = {}
    if type(pushed.escorting) == "table" then
        for _, id in ipairs(pushed.escorting) do
            if type(id) == "number" then escorting[id] = true end
        end
    end
    state.escorting = escorting
end)

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE or name == "open77_contextmenu" then
        CreateThread(function()
            registerActions()
            if name == RESOURCE then
                -- A client-side reload lost the pushed state: ask for it again.
                TriggerServerEvent("rp_vigile:clientReady")
            end
        end)
    end
end)
