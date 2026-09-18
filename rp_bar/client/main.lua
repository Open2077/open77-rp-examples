-- rp_bar client: renders and requests, decides nothing.
--  * the counter POI (ring + map pin + E prompt) for the on-duty barman (open77_worldui)
--  * the ALT+click "Serve a drink" action on another player (open77_contextmenu)
-- Every choice is sent to the server, which re-checks the job, the duty, the distance
-- and the pockets before anything happens.

local RESOURCE = GetCurrentResourceName()
local onDuty = false          -- the server says whether this client is a barman on duty
local counterHandle = nil     -- open77_worldui handle of the counter POI
local counterBusy = false     -- a create/remove round trip is in flight
local counterDirty = false    -- the duty flag changed while a round trip was in flight

local function call(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- ---------------------------------------------------------------------------
-- The counter POI
-- ---------------------------------------------------------------------------

local function removeCounter()
    if not counterHandle then return end
    local handle = counterHandle
    counterHandle = nil
    local result, reason = call("open77_worldui", "remove", handle)
    if not result or not result.ok then
        print(("[rp_bar] counter POI remove refused: %s"):format(tostring(reason or (result and result.error))))
    end
end

local function createCounter()
    if counterHandle then return end
    local counter = RpBarConfig.counter
    local result, reason = call("open77_worldui", "create", {
        id = "rp_bar_counter",
        position = counter.position,
        radius = counter.radius or 1.5,
        style = "interaction",
        maxDistance = counter.maxDistance or 60.0,
        label = counter.label or "Bar counter",
        description = counter.description or "",
        key = "E",
        promptDistance = counter.promptDistance or 3.0,
        color = "#FF5FA2",
        event = "rp_bar:counterPrompt",
    })
    if not result or not result.ok then
        print(("[rp_bar] counter POI refused: %s"):format(tostring(reason or (result and result.error))))
        return
    end
    counterHandle = result.handle
end

-- Keep the POI in step with the duty flag; one round trip at a time.
local function syncCounter()
    -- A change that lands mid-flight is not dropped: the worker re-checks once the round trip ends.
    if counterBusy then counterDirty = true; return end
    counterBusy = true
    CreateThread(function()
        repeat
            counterDirty = false
            local wanted = onDuty or RpBarConfig.showCounterToCustomers == true
            if wanted and not counterHandle then
                createCounter()
            elseif not wanted and counterHandle then
                removeCounter()
            end
        until not counterDirty
        counterBusy = false
    end)
end

-- The E prompt was pressed: ask the server to open the counter menu.
AddEventHandler("rp_bar:counterPrompt", function()
    TriggerServerEvent("rp_bar:counter")
end)

-- ---------------------------------------------------------------------------
-- The ALT+click action
-- ---------------------------------------------------------------------------

-- Shown only while the server told us we are a barman on duty. The server checks again.
exports("rpBarCanServe", function(context)
    if not onDuty then return false end
    return context and context.target and context.target.playerId ~= nil and context.target.isLocalPlayer ~= true
end)

exports("rpBarServe", function(context)
    local target = context and context.target and context.target.playerId
    if target == nil then return false end
    TriggerServerEvent("rp_bar:serve", target)
    return true
end)

local function registerActions()
    CreateThread(function()
        local token, reason = call("open77_contextmenu", "registerPlayers", {
            id = "rp_bar_serve",
            label = "Serve a drink",
            description = "Offer this customer a drink from your pockets. They see the price and accept.",
            group = "Bar",
            icon = "interact",
            networked = true,
            distance = (RpBarConfig.sale and RpBarConfig.sale.distance) or 3.0,
            order = 40,
            canInteract = "rpBarCanServe",
            onSelect = "rpBarServe",
        })
        if not token then
            print(("[rp_bar] context-menu registration refused: %s"):format(tostring(reason)))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Duty state from the server
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_bar:duty", function(isOnDuty)
    onDuty = isOnDuty == true
    syncCounter()
end)

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE then
        registerActions()
        -- Ask where we stand: the server answers with rp_bar:duty.
        TriggerServerEvent("rp_bar:clientReady")
        if RpBarConfig.showCounterToCustomers == true then syncCounter() end
    elseif name == "open77_contextmenu" then
        registerActions()
    elseif name == "open77_worldui" then
        -- The POI service restarted underneath us: our handle is gone with its generation.
        counterHandle = nil
        syncCounter()
    end
end)
