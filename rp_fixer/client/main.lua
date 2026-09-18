-- rp_fixer client: presentation only.
--
-- Draws the board ring + E prompt at the fixer's office and, while a gig runs, the
-- current objective: a ring (with an E prompt when the phase needs one), a vanilla map
-- pin and the GPS waypoint. Every press is relayed to the server, which re-measures
-- the distance itself; nothing here grants anything.

local boardPoi = nil
local boardBlip = nil

local objective = { key = nil, poi = nil, blip = nil, waypoint = false }

local function log(fmt, ...)
    print("[rp_fixer] " .. fmt:format(...))
end

-- Awaits: only from a CreateThread body.
local function worldui(name, ...)
    local promise, reason = Open77.exports.call("open77_worldui", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Dispatches the removal without waiting for it, so it is safe from any handler.
local function worlduiRemove(handle)
    local promise, reason = Open77.exports.call("open77_worldui", "remove", handle)
    if not promise then log("ring removal refused: %s", tostring(reason)) end
end

-- Never yields.
local function clearObjective()
    if objective.poi then
        worlduiRemove(objective.poi)
        objective.poi = nil
    end
    if objective.blip then
        Open77.blips.remove(objective.blip)
        objective.blip = nil
    end
    if objective.waypoint then
        Open77.blips.clearWaypoint()
        objective.waypoint = false
    end
    objective.key = nil
end

-- o = { key, position, label, prompt (string|false), style, title }
local function showObjective(o)
    local definition = {
        id = "rp_fixer_objective",
        position = o.position,
        radius = 1.5,
        style = o.style or "objective",
        maxDistance = 150.0,
        groundOffset = 0.06,
    }
    if o.prompt then
        definition.label = o.prompt
        definition.description = o.title
        definition.key = "E"
        definition.promptDistance = Config.promptDistance
        definition.event = "rp_fixer:objectivePressed"
        definition.color = "#22D8E2"
    end
    local result, err = worldui("create", definition)
    if not result or not result.ok then
        log("objective ring refused: %s", tostring(err or (result and result.error)))
    else
        objective.poi = result.handle
    end

    local blip, reason = Open77.blips.create({
        position = o.position,
        sprite = "objective",
        title = o.title,
        description = o.label,
    })
    if blip then
        objective.blip = blip
    else
        log("objective pin refused: %s", tostring(reason))
    end

    local ok, why = Open77.blips.setWaypoint(o.position)
    if ok then
        objective.waypoint = true
    else
        log("waypoint refused: %s", tostring(why))
    end
    objective.key = o.key
end

RegisterNetEvent("rp_fixer:objective", function(o)
    CreateThread(function()
        clearObjective()
        if type(o) == "table" and type(o.position) == "table" then
            showObjective(o)
        end
    end)
end)

AddEventHandler("rp_fixer:objectivePressed", function()
    if objective.key then
        TriggerServerEvent("rp_fixer:interact", objective.key)
    end
end)

AddEventHandler("rp_fixer:boardPressed", function()
    TriggerServerEvent("rp_fixer:board")
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    CreateThread(function()
        local result, err = worldui("create", {
            id = "rp_fixer_board",
            position = Config.office,
            radius = 1.5,
            style = "interaction",
            maxDistance = 120.0,
            groundOffset = 0.06,
            label = Config.text.boardLabel,
            description = Config.text.boardDescription,
            key = "E",
            promptDistance = Config.promptDistance,
            color = "#22D8E2",
            event = "rp_fixer:boardPressed",
        })
        if not result or not result.ok then
            log("board ring refused: %s", tostring(err or (result and result.error)))
        else
            boardPoi = result.handle
        end

        local blip, reason = Open77.blips.create({
            position = Config.office,
            sprite = "fixer",
            title = Config.text.officeBlip,
            description = "Gigs on the board. Bring your rep.",
        })
        if blip then
            boardBlip = blip
        else
            log("office pin refused: %s", tostring(reason))
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    clearObjective()
    if boardPoi then
        worlduiRemove(boardPoi)
        boardPoi = nil
    end
    if boardBlip then
        Open77.blips.remove(boardBlip)
        boardBlip = nil
    end
end)
