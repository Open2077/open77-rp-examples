-- rp_ncpd client: ALT+click actions on a player (open77_contextmenu), the jail input block and
-- the temporary alert pins. Nothing here decides anything: every action is a request the
-- server re-checks (job, duty, distance, life, holds).

local onDuty = false
local jailed = false
local JAIL_BLOCKS = { "WeaponWheel", "Attack" }   -- EnterVehicle is not blockable on 2.31; the server ejects instead

local function callAwait(resource, method, ...)
    local promise, dispatchError = Open77.exports.call(resource, method, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

local function menu(method, ...)
    return callAwait("open77_contextmenu", method, ...)
end

-- The Kabuki-side patrol outpost (Config.outpost): a ground ring (open77_worldui, no label =
-- no prompt) and a floating label (open77_uikit drawText3D). Presentation only: a radio /
-- status point for patrols, nothing to press.
local outpostRing = nil
local outpostLabel = nil

local function createOutpost()
    local o = Config.outpost
    if not o then return end
    if not outpostRing then
        local result, reason = callAwait("open77_worldui", "create", {
            id = "rp_ncpd_outpost",
            position = { x = o.x, y = o.y, z = o.z },
            radius = o.radius or 3.0,
            shape = "ring",
            style = "objective",
            color = o.color,
            maxDistance = o.maxDistance or 120.0,
            groundOffset = 0.06,
        })
        if result and result.ok then
            outpostRing = result.handle
        else
            print("[rp_ncpd] outpost ring not created: " .. tostring(reason or (result and result.error) or "unknown"))
        end
    end
    if not outpostLabel then
        local handle, reason = callAwait("open77_uikit", "drawText3D", {
            position = { x = o.x, y = o.y, z = o.z + 1.6 },
            text = "NCPD",
            sublabel = o.label,
            color = "#F2F6F8",
            accent = o.color,
            maxDistance = o.labelDistance or 40.0,
            showDistance = false,
        })
        if handle then
            outpostLabel = handle
        else
            print("[rp_ncpd] outpost label not drawn: " .. tostring(reason))
        end
    end
end

local function request(action, ctx)
    local target = ctx and ctx.target or nil
    if not target or target.playerId == nil or target.isLocalPlayer then return false end
    TriggerServerEvent("rp_ncpd:action", action, target.playerId)
    return true
end

-- canInteract: the server pushes the duty flag; the menu only hides entries, it authorises nothing.
exports("ncpdIsOfficer", function()
    return onDuty == true
end)

exports("ncpdCuff", function(ctx) return request("cuff", ctx) end)
exports("ncpdUncuff", function(ctx) return request("uncuff", ctx) end)
exports("ncpdEscort", function(ctx) return request("escort", ctx) end)
exports("ncpdSearch", function(ctx) return request("search", ctx) end)
exports("ncpdSeize", function(ctx) return request("seize", ctx) end)
exports("ncpdFine", function(ctx) return request("fine", ctx) end)
exports("ncpdVehicle", function(ctx) return request("vehicle", ctx) end)
exports("ncpdJail", function(ctx) return request("jail", ctx) end)
exports("ncpdRelease", function(ctx) return request("release", ctx) end)
exports("ncpdRecord", function(ctx) return request("record", ctx) end)

local ACTIONS = {
    { id = "ncpd_cuff", label = "Cuff", description = "Freeze the suspect, hands up (RP kit).", icon = "lock", order = 10, onSelect = "ncpdCuff" },
    { id = "ncpd_uncuff", label = "Uncuff", description = "Release a cuffed or escorted suspect.", icon = "lock", order = 11, onSelect = "ncpdUncuff" },
    { id = "ncpd_escort", label = "Escort / stop escorting", description = "Walk them with you on a leash.", icon = "person", order = 12, onSelect = "ncpdEscort" },
    { id = "ncpd_search", label = "Search", description = "List their pockets (cuffed or hands up).", icon = "info", order = 20, onSelect = "ncpdSearch" },
    { id = "ncpd_seize", label = "Seize contraband", description = "Every illegal item goes into your pockets.", icon = "tool", order = 21, onSelect = "ncpdSeize" },
    { id = "ncpd_fine", label = "Fine", description = "Amount and reason; the citizen accepts or refuses.", icon = "interact", order = 30, onSelect = "ncpdFine" },
    { id = "ncpd_vehicle", label = "Put in / take out of vehicle", description = "Your cruiser must be within 5 m.", icon = "vehicle", order = 40, distance = Config.vehicle.range, onSelect = "ncpdVehicle" },
    { id = "ncpd_jail", label = "Jail", description = "Minutes in the NCPD cell; contraband destroyed at booking.", icon = "location", order = 50, danger = true, onSelect = "ncpdJail" },
    { id = "ncpd_release", label = "Release from cell", description = "End their sentence now.", icon = "location", order = 51, onSelect = "ncpdRelease" },
    { id = "ncpd_record", label = "Criminal record", description = "Fines, arrests, warrants, seizures.", icon = "info", order = 60, distance = 10.0, onSelect = "ncpdRecord" },
}

local function registerActions()
    local definitions = {}
    for _, a in ipairs(ACTIONS) do
        definitions[#definitions + 1] = {
            id = a.id, label = a.label, description = a.description, group = "NCPD", icon = a.icon,
            networked = true, distance = a.distance or Config.menuDistance, order = a.order, danger = a.danger == true,
            canInteract = "ncpdIsOfficer", onSelect = a.onSelect,
        }
    end
    -- awaited batches of at most five, as the context-menu guide asks
    for i = 1, #definitions, 5 do
        local batch = {}
        for j = i, math.min(i + 4, #definitions) do batch[#batch + 1] = definitions[j] end
        local tokens, err = menu("registerPlayers", batch)
        if not tokens then print("[rp_ncpd] context menu registration failed: " .. tostring(err)) end
    end
end

-- Jail: take the weapon wheel and the trigger away; give them back exactly once released.
local function applyJail(flag)
    flag = flag == true
    if flag == jailed then return end
    jailed = flag
    for _, action in ipairs(JAIL_BLOCKS) do
        local ok, reason = Open77.input.setActionBlocked(action, flag)
        if not ok then print(("[rp_ncpd] input block %s=%s refused: %s"):format(action, tostring(flag), tostring(reason))) end
    end
end

RegisterNetEvent("rp_ncpd:self", function(duty)
    onDuty = duty == true
end)

RegisterNetEvent("rp_ncpd:jailed", function(flag)
    applyJail(flag)
end)

-- Temporary map pin for a dispatch alert (server blips do not exist on this build: client relay).
RegisterNetEvent("rp_ncpd:alertBlip", function(position, label, ttlMs)
    if type(position) ~= "table" or not tonumber(position.x) then return end
    local blip, reason = Open77.blips.create({
        position = { x = tonumber(position.x), y = tonumber(position.y), z = tonumber(position.z) },
        sprite = Config.alert.sprite,
        title = tostring(label or "NCPD alert"),
        description = "Dispatch call. The pin fades on its own.",
        active = true,
        visibleThroughWalls = true,
    })
    if not blip then
        print("[rp_ncpd] alert blip refused: " .. tostring(reason))
        return
    end
    SetTimeout(math.max(1000, tonumber(ttlMs) or Config.alert.blipMs), function()
        Open77.blips.remove(blip)
    end)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() or name == "open77_contextmenu" then
        CreateThread(registerActions)
    end
    if name == GetCurrentResourceName() then
        CreateThread(createOutpost)
        -- ask the server for the duty flag and whether a sentence is standing (a client reload
        -- drops the input claims while the server still holds the prisoner)
        TriggerServerEvent("rp_ncpd:clientReady")
    elseif name == "open77_worldui" then
        -- the POI service restarted underneath us: its registry is empty again
        outpostRing = nil
        CreateThread(createOutpost)
    elseif name == "open77_uikit" then
        outpostLabel = nil
        CreateThread(createOutpost)
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- claims are dropped by the platform on stop; releasing unconditionally is not an error
    applyJail(false)
end)
