-- rp_bank / client: presentation only. One map pin, one ground ring + prompt (open77_worldui)
-- and one floating label (open77_uikit drawText3D) per configured ATM. The prompt raises a local
-- event that is forwarded to the server as the minimum intent: "I pressed E at this ATM". The
-- server re-checks the distance and owns the menu; nothing here decides money.

local RESOURCE = GetCurrentResourceName()
local MAX_LABELS = 8   -- the UI kit refuses more than 8 floating texts per owner

local function log(fmt, ...)
    print(("[%s] "):format(RESOURCE) .. fmt:format(...))
end

-- Await one export call, retrying while the service is not up yet (a package can still be
-- preparing when this resource starts).
local function callAwait(resource, name, ...)
    local args = table.pack(...)
    local lastReason
    for _ = 1, 10 do
        local promise, reason = Open77.exports.call(resource, name, table.unpack(args, 1, args.n))
        if promise then
            return promise:await()
        end
        lastReason = reason
        if reason ~= "export_resource_unavailable" and reason ~= "resource_preparing" then
            return nil, reason
        end
        Wait(1000)
    end
    return nil, lastReason
end

local function createBlip(atm)
    local blip, reason
    for _ = 1, 10 do
        blip, reason = Open77.blips.create({
            position = atm.position,
            sprite = Config.BlipSprite,
            title = atm.label,
            description = "Night City Bank ATM. Deposit, withdraw, wire, statement.",
            active = true,
            visibleThroughWalls = false,
        })
        if blip then return blip end
        if reason ~= "blips_backend_unavailable" then break end
        Wait(1000)
    end
    log("blip for %s refused: %s", atm.id, tostring(reason))
    return nil
end

local function createPoi(atm)
    local result, reason = callAwait("open77_worldui", "create", {
        id = atm.id,
        position = atm.position,
        radius = 1.0,
        -- The prompt only becomes pressable within `promptDistance` (worldui defaults to
        -- radius + 0.5 m, too tight for a ring you stand next to): use the /bank range.
        promptDistance = Config.AtmRange,
        style = "interaction",
        maxDistance = Config.MarkerDistance,
        label = "Use the ATM",
        description = atm.label,
        key = "E",
        icon = "E$",
        color = Config.Color,
        event = "rp_bank:atm:" .. atm.id,
    })
    if not result then
        log("POI for %s never created: %s", atm.id, tostring(reason))
        return nil
    end
    if not result.ok then
        log("POI for %s refused: %s", atm.id, tostring(result.error))
        return nil
    end
    return result.handle
end

local function createLabel(atm)
    local result, reason = callAwait("open77_uikit", "drawText3D", {
        position = { x = atm.position.x, y = atm.position.y, z = atm.position.z + 1.4 },
        text = "ATM",
        sublabel = atm.label,
        color = "#F2F6F8",
        accent = Config.Color,
        maxDistance = Config.LabelDistance,
        showDistance = true,
    })
    if result == nil then
        log("label for %s not drawn: %s", atm.id, tostring(reason))
        return nil
    end
    -- drawText3D answers `handle, reason` directly (it is not a dialog): a nil first value is a refusal.
    return result
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    -- One local handler per ATM: the prompt's own payload does not have to be trusted to name it.
    for _, atm in ipairs(Config.Atms) do
        AddEventHandler("rp_bank:atm:" .. atm.id, function()
            local ok, reason = TriggerServerEvent("rp_bank:useAtm", atm.id)
            if not ok then log("useAtm intent refused: %s", tostring(reason)) end
        end)
    end
    CreateThread(function()
        local pins, pois, labels = 0, 0, 0
        for i, atm in ipairs(Config.Atms) do
            if createBlip(atm) then pins = pins + 1 end
            if createPoi(atm) then pois = pois + 1 end
            if i <= MAX_LABELS and createLabel(atm) then labels = labels + 1 end
        end
        log("%d ATMs: %d map pins, %d prompts, %d labels", #Config.Atms, pins, pois, labels)
    end)
end)
