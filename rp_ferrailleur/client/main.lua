-- rp_ferrailleur (client): draws one ring + E prompt per wreck and on the scrap dealer, and
-- forwards a pressed prompt to the server as a bare intent. Nothing here decides anything:
-- the server re-checks the distance, the job, the crowbar and the wreck's state.

local Config = RpFerrailleurConfig

local handles = {}   -- point index -> open77_worldui handle currently placed
local applied = {}   -- point index -> state the placed ring shows
local desired = {}   -- point index -> state the server last announced
local working = {}   -- point index -> true while a rebuild thread runs

local function log(fmt, ...)
    print(("[rp_ferrailleur] " .. fmt):format(...))
end

-- One awaited call to the world-UI facade; nil, reason when it could not be dispatched.
local function worldui(name, ...)
    local promise, reason = Open77.exports.call("open77_worldui", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function wreckDefinition(index, state)
    local point = Config.points[index]
    local look = Config.ring[state] or Config.ring.ready
    local def = {
        id = ("wreck_%d"):format(index),
        position = { x = point.x, y = point.y, z = point.z },
        radius = Config.ringRadius,
        style = look.style,
        maxDistance = 80.0,
    }
    if state == "ready" then
        -- Only a ready wreck carries the prompt; a busy or picked-clean one is a bare ring.
        def.label = "Search the wreck"
        def.description = point.label or "Pry it open with your crowbar"
        def.key = "E"
        def.promptDistance = Config.promptDistance
        def.event = ("rp_ferrailleur:prompt_%d"):format(index)
    end
    return def
end

-- Rebuilds the ring of one wreck until it shows the desired state. There is no `update`
-- export: remove and recreate under the same id, serialised per point.
local function apply(index)
    if working[index] then return end
    working[index] = true
    CreateThread(function()
        while desired[index] ~= applied[index] do
            local want = desired[index]
            if handles[index] then
                local removed, reason = worldui("remove", handles[index])
                if not removed or not removed.ok then
                    log("wreck %d ring removal failed: %s", index, tostring(reason or (removed and removed.error)))
                end
                handles[index] = nil
            end
            local result, reason = worldui("create", wreckDefinition(index, want))
            if result and result.ok then
                handles[index] = result.handle
            else
                log("wreck %d ring (%s) not created: %s", index, tostring(want), tostring(reason or (result and result.error)))
            end
            applied[index] = want
        end
        working[index] = false
    end)
end

local function placeDealer()
    CreateThread(function()
        local d = Config.dealer
        local result, reason = worldui("create", {
            id = "dealer",
            position = { x = d.position.x, y = d.position.y, z = d.position.z },
            radius = 1.5,
            style = "interaction",
            maxDistance = 80.0,
            label = "Talk to the scrap dealer",
            description = ("%s buys scrap, components and chips, sells crowbars"):format(d.name or "The dealer"),
            key = "E",
            promptDistance = Config.promptDistance,
            event = "rp_ferrailleur:prompt_dealer",
        })
        if not (result and result.ok) then
            log("dealer ring not created: %s", tostring(reason or (result and result.error)))
        end
    end)
end

-- One local event per wreck: the facade fires the event name with no payload we rely on.
for index = 1, #Config.points do
    AddEventHandler(("rp_ferrailleur:prompt_%d"):format(index), function()
        TriggerServerEvent("rp_ferrailleur:search", index)
    end)
end

AddEventHandler("rp_ferrailleur:prompt_dealer", function()
    TriggerServerEvent("rp_ferrailleur:dealer")
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    for index = 1, #Config.points do
        desired[index] = "ready"
        apply(index)
    end
    placeDealer()
    -- Ask the server for the real state of every wreck (some may be picked clean already).
    TriggerServerEvent("rp_ferrailleur:clientReady")
end)

-- The server announces one wreck's state: ready | busy | depleted.
RegisterNetEvent("rp_ferrailleur:pointState", function(index, state)
    index = tonumber(index)
    if not index or not Config.points[index] then return end
    if type(state) ~= "string" or not Config.ring[state] then return end
    desired[index] = state
    apply(index)
end)

-- The full picture, answered to rp_ferrailleur:clientReady: { { index, state, readyAt }, ... }.
RegisterNetEvent("rp_ferrailleur:allState", function(states)
    if type(states) ~= "table" then return end
    for _, entry in pairs(states) do
        local index = tonumber(entry.index)
        local state = entry.state
        if index and Config.points[index] and type(state) == "string" and Config.ring[state] then
            desired[index] = state
            apply(index)
        end
    end
end)
