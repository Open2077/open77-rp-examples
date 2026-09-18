-- rp_identity: client side.
--
-- Three jobs, none of them authoritative:
--   1. the registration form (open77_uikit `input`), whose answers go to the server as-is;
--   2. the ALT+click "Show ID" action on another player (open77_contextmenu), which only
--      asks the server to show the card - range and identity are checked there;
--   3. the RP name over every remote body (Open77.nameplates.set) from the server's directory.

local RESOURCE = "rp_identity"
local REAPPLY_EVERY_MS = 15000 -- overrides are re-applied for bodies that streamed in late

-- playerId (string) -> label, as the server last told us.
local labels = {}
local formOpen = false

-- ---------------------------------------------------------------------------------------
-- Nameplates
-- ---------------------------------------------------------------------------------------

local function applyPlate(playerId, label)
    local id = tonumber(playerId)
    if not id then return end
    if id == Open77.players.localId() then return end -- our own body has no remote plate
    if label then
        Open77.nameplates.set(id, { label = label })
    else
        Open77.nameplates.remove(id)
    end
end

RegisterNetEvent("rp_identity:nameplate", function(playerId, label)
    local key = tostring(playerId)
    if type(label) == "string" and label ~= "" then
        labels[key] = label
        applyPlate(playerId, label)
    else
        labels[key] = nil
        applyPlate(playerId, false)
    end
end)

RegisterNetEvent("rp_identity:directory", function(directory)
    if type(directory) ~= "table" then return end
    for key in pairs(labels) do
        if directory[key] == nil then applyPlate(key, false) end
    end
    labels = {}
    for key, label in pairs(directory) do
        if type(label) == "string" and label ~= "" then
            labels[key] = label
            applyPlate(key, label)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(REAPPLY_EVERY_MS)
        for key, label in pairs(labels) do
            applyPlate(key, label)
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Registration form
-- ---------------------------------------------------------------------------------------

local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local FORM = {
    title = "Night City citizen registration",
    description = "NCID needs your civil details. Birth date as YYYY-MM-DD; citizens are 18 to 90 years old.",
    fields = {
        { id = "firstName", type = "text", label = "First name", max = 24, required = true },
        { id = "lastName", type = "text", label = "Last name", max = 24, required = true },
        { id = "birth", type = "text", label = "Birth date (YYYY-MM-DD)", max = 10, required = true },
        { id = "sex", type = "select", label = "Sex", required = true, options = {
            { value = "m", label = "Male" },
            { value = "f", label = "Female" },
            { value = "x", label = "Other" },
        } },
        { id = "origin", type = "select", label = "Origin", required = true, options = {
            { value = "night_city", label = "Night City native" },
            { value = "badlands", label = "Badlands" },
            { value = "corpo", label = "Corpo" },
            { value = "nomad", label = "Nomad" },
            { value = "offworld", label = "Off-world" },
        } },
    },
    confirm = "Register",
    cancel = "Later",
    timeoutMs = 120000,
}

local function openRegistration()
    if formOpen then return end
    formOpen = true
    CreateThread(function()
        local answer, reason = uikit("input", FORM)
        formOpen = false
        if answer == nil then
            -- Never opened: another dialog holds the screen, the surface is not ready...
            print(("[%s] registration form refused: %s"):format(RESOURCE, tostring(reason)))
            TriggerServerEvent("rp_identity:formRefused", tostring(reason))
            return
        end
        if not answer.ok then
            TriggerServerEvent("rp_identity:formClosed", tostring(answer.outcome))
            return
        end
        local v = answer.value or {}
        TriggerServerEvent("rp_identity:register", {
            firstName = v.firstName,
            lastName = v.lastName,
            birth = v.birth,
            sex = v.sex,
            origin = v.origin,
        })
    end)
end

RegisterNetEvent("rp_identity:openRegistration", function()
    openRegistration()
end)

-- ---------------------------------------------------------------------------------------
-- ALT+click > Show ID on another player
-- ---------------------------------------------------------------------------------------

-- canInteract: a remote player only. UX filter, not an authorization; the server rechecks.
exports("rp_identity_can_show_id", function(ctx)
    local target = ctx and ctx.target
    return (target ~= nil and target.playerId ~= nil and target.isLocalPlayer ~= true) == true
end)

-- onSelect: ask the server; it validates range, identity and registration.
exports("rp_identity_show_id", function(ctx)
    local target = ctx and ctx.target
    if not target or target.playerId == nil or target.isLocalPlayer then return false end
    TriggerServerEvent("rp_identity:showTo", target.playerId)
    return true
end)

local function registerContextAction()
    CreateThread(function()
        local promise, reason = Open77.exports.call("open77_contextmenu", "register", {
            id = "rp_identity_show_id",
            label = "Show ID",
            description = "Show your Night City ID card to this person.",
            group = "Citizen",
            icon = "person",
            types = { "player" },
            networked = true,
            distance = 5.0,
            order = 20,
            canInteract = "rp_identity_can_show_id",
            onSelect = "rp_identity_show_id",
        })
        if not promise then
            print(("[%s] context menu unavailable: %s"):format(RESOURCE, tostring(reason)))
            return
        end
        local token, err = promise:await()
        if not token then
            print(("[%s] context action refused: %s"):format(RESOURCE, tostring(err)))
        end
    end)
end

-- ---------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then
        TriggerServerEvent("rp_identity:clientReady")
        registerContextAction()
    elseif name == "open77_contextmenu" then
        registerContextAction() -- the menu restarted alone: registrations were dropped
    end
end)
