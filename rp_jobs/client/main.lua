-- rp_jobs client -- presentation only. Nothing here decides anything.
--
--   * the employment agency ring + map pin + E prompt (open77_worldui),
--     whose press is forwarded to the server as a request;
--   * the ALT+click "Hire into <job>" action on another player
--     (open77_contextmenu), shown only while the server says we are a boss;
--   * the on-duty tag over colleagues' bodies: the server broadcasts who is on
--     duty and in which colour, this script applies Open77.nameplates overrides
--     to the remote players it is told about. A player never sees their own
--     tag: the nameplate API only overrides remote players.

local RESOURCE = GetCurrentResourceName()
local C = RpJobsConfig

local plates = {}                          -- [playerId] = { label, color }
local selfState = { job = false, boss = false, label = false }
local hireToken = nil
local poiHandle = nil

-- Await an export of another client package; nil, reason when it never ran.
local function call(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then
        return nil, reason
    end
    return promise:await()
end

---------------------------------------------------------------------------
-- On-duty nameplates
---------------------------------------------------------------------------

local function applyPlate(playerId, plate)
    local me = Open77.players.localId()
    if me ~= nil and playerId == me then
        return -- the API only overrides remote players
    end
    if plate then
        local ok, reason = Open77.nameplates.set(playerId, {
            label = plate.label,
            color = plate.color,
            maxDistance = C.NameplateMaxDistance,
        })
        if not ok then
            print(("[rp_jobs] nameplate for player %s refused: %s"):format(tostring(playerId), tostring(reason)))
        end
    else
        Open77.nameplates.remove(playerId)
    end
end

-- One player's tag changed (false = no tag any more).
RegisterNetEvent("rp_jobs:plate", function(playerId, plate)
    local id = tonumber(playerId)
    if not id then
        return
    end
    if type(plate) == "table" and type(plate.label) == "string" and type(plate.color) == "string" then
        plates[id] = { label = plate.label, color = plate.color }
    else
        plates[id] = nil
    end
    applyPlate(id, plates[id])
end)

-- The whole duty roster, sent once when this client reports ready.
RegisterNetEvent("rp_jobs:roster", function(entries)
    Open77.nameplates.clear()
    plates = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local id = tonumber(entry.playerId)
        if id and type(entry.label) == "string" and type(entry.color) == "string" then
            plates[id] = { label = entry.label, color = entry.color }
            applyPlate(id, plates[id])
        end
    end
end)

---------------------------------------------------------------------------
-- ALT+click "Hire into <job>" (only while the server says we are a boss)
---------------------------------------------------------------------------

exports("canhire", function(context)
    if not selfState.boss then
        return false
    end
    local target = context and context.target
    if type(target) ~= "table" or target.kind ~= "player" or target.isLocalPlayer or target.playerId == nil then
        return false
    end
    return true
end)

exports("hire", function(context)
    local target = context and context.target
    if type(target) ~= "table" or target.playerId == nil then
        return false
    end
    -- Only the clicked target's id crosses; the server re-checks boss, job, range.
    TriggerServerEvent("rp_jobs:hire", target.playerId)
    return true
end)

-- Register, re-label or remove the action to match what the server told us.
local function syncHireAction()
    if selfState.boss and type(selfState.label) == "string" then
        local token, reason = call("open77_contextmenu", "registerPlayers", {
            id = "rp_jobs_hire",
            label = ("Hire into %s"):format(selfState.label),
            description = "Sign them up as a recruit of your company.",
            group = "Jobs",
            icon = "person",
            networked = true,
            distance = C.HireDistance,
            order = 20,
            canInteract = "canhire",
            onSelect = "hire",
        })
        if token then
            hireToken = token
        else
            print("[rp_jobs] hire action not registered: " .. tostring(reason))
        end
    elseif hireToken then
        call("open77_contextmenu", "unregister", hireToken)
        hireToken = nil
    end
end

RegisterNetEvent("rp_jobs:self", function(state)
    selfState = type(state) == "table" and state or { job = false, boss = false, label = false }
    CreateThread(syncHireAction)
end)

---------------------------------------------------------------------------
-- The employment agency POI
---------------------------------------------------------------------------

local function createPoi()
    local a = C.Agency
    local result, reason = call("open77_worldui", "create", {
        id = "rp_jobs_agency",
        position = { x = a.position.x, y = a.position.y, z = a.position.z },
        radius = a.radius,
        style = "interaction",
        maxDistance = a.maxDistance,
        label = a.label,
        description = a.description,
        key = "E",
        color = a.color,
        promptDistance = a.promptDistance,
        event = "rp_jobs:agencyPrompt",
    })
    if not result then
        print("[rp_jobs] agency POI not created: " .. tostring(reason))
        return
    end
    if not result.ok then
        print("[rp_jobs] agency POI refused: " .. tostring(result.error))
        return
    end
    poiHandle = result.handle
end

-- The prompt was pressed: ask the server, which checks the distance itself.
AddEventHandler("rp_jobs:agencyPrompt", function()
    TriggerServerEvent("rp_jobs:agency")
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE then
        CreateThread(function()
            createPoi()
            syncHireAction()
            TriggerServerEvent("rp_jobs:clientReady")
        end)
    elseif name == "open77_worldui" then
        -- The POI service restarted underneath us: its registry is empty again.
        poiHandle = nil
        CreateThread(createPoi)
    elseif name == "open77_contextmenu" then
        hireToken = nil
        CreateThread(syncHireAction)
    end
end)
