-- rp_inventory / client: the /inv panel page and the ALT+click actions.
--
-- The client decides nothing. The panel is a WebUI page (web/index.html)
-- created hidden at start, shown when the server pushes a state through
-- rp_inventory:panel and hidden when that state says open = false or the page
-- asks to close. Every click on the page becomes a rp_inventory:intent the
-- server re-validates and answers with a fresh state. The ALT+click actions
-- send the canonical target id to the server, which re-checks distance, life,
-- weight and ownership before moving anything.

local RESOURCE = GetCurrentResourceName()

local page = nil          -- the WebUI surface, or nil when it could not be created
local pageReason = nil    -- why create() refused, for the chat fallback
local pageReady = false   -- the page raised "ready"
local isOpen = false
local pendingState = nil  -- a state that arrived before the page was ready

local function doClose()
    if not page or not isOpen then return end
    isOpen = false
    page:send("close", {})
    page:setFocus(false, false)
    page:hide()
end

local function doOpen(state)
    if not page then return end
    if not pageReady then
        pendingState = state
        return
    end
    if not isOpen then
        isOpen = true
        page:show()
        -- Keyboard + cursor: count fields and Escape live on the page.
        page:setFocus(true, true)
    end
    page:send("state", state)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    -- Created hidden, far ahead of the first /inv, so show() never races create().
    local surface, reason = Open77.webui.create({
        entry = "web/index.html",
        layer = "menu",
        transparent = true,
        visible = false,
    })
    if not surface then
        pageReason = tostring(reason or "webui_unavailable")
        print("[rp_inventory] webui unavailable: " .. pageReason)
    else
        page = surface
        page:on("ready", function()
            pageReady = true
            if pendingState then
                local s = pendingState
                pendingState = nil
                doOpen(s)
            end
        end)
        -- Every page action: forwarded as-is, the server re-checks and answers.
        page:on("intent", function(payload)
            if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
            TriggerServerEvent("rp_inventory:intent", payload)
        end)
        -- The X button or Escape on the page.
        page:on("close", function()
            doClose()
            TriggerServerEvent("rp_inventory:intent", { action = "close" })
        end)
    end
    -- A fresh VM has no open panel: tell the server so it forgets any stale one.
    TriggerServerEvent("rp_inventory:intent", { action = "close" })
end)

-- Server -> page. { open = false } closes; anything else is the full state.
RegisterNetEvent("rp_inventory:panel", function(state)
    if type(state) ~= "table" then return end
    if state.open == false then
        doClose()
        return
    end
    if not page then
        -- No WebUI on this client: the server lists the pockets in chat instead.
        TriggerServerEvent("rp_inventory:intent", { action = "unavailable", reason = pageReason or "webui_unavailable" })
        return
    end
    doOpen(state)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    if page then
        if isOpen then page:setFocus(false, false) end
        page:destroy()
        page = nil
    end
    isOpen = false
end)

---------------------------------------------------------------------------
-- ALT+click actions on other players (open77_contextmenu)
---------------------------------------------------------------------------

local function menu(method, ...)
    local promise, dispatchError = Open77.exports.call("open77_contextmenu", method, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

-- Only another network player: never yourself, never an NPC.
exports("rpInventoryIsOtherPlayer", function(ctx)
    local target = ctx and ctx.target
    if type(target) ~= "table" then return false end
    if target.playerId == nil then return false end
    if target.isLocalPlayer == true then return false end
    return true
end)

exports("rpInventoryGive", function(ctx)
    local target = ctx and ctx.target
    if type(target) ~= "table" or target.playerId == nil then return false end
    TriggerServerEvent("rp_inventory:giveMenu", target.playerId)
    return true
end)

exports("rpInventorySearch", function(ctx)
    local target = ctx and ctx.target
    if type(target) ~= "table" or target.playerId == nil then return false end
    TriggerServerEvent("rp_inventory:search", target.playerId)
    return true
end)

local function registerActions()
    local tokens, err = menu("registerPlayers", {
        {
            id = "rp_inventory_give",
            label = "Give item",
            description = "Hand something from your pockets. The server checks the 3 m and their weight.",
            group = "Inventory",
            icon = "interact",
            networked = true,
            distance = 3.0,
            order = 20,
            canInteract = "rpInventoryIsOtherPlayer",
            onSelect = "rpInventoryGive",
        },
        {
            id = "rp_inventory_search",
            label = "Search pockets",
            description = "Frisk a cuffed or surrendering player.",
            group = "Inventory",
            icon = "person",
            networked = true,
            distance = 3.0,
            order = 21,
            canInteract = "rpInventoryIsOtherPlayer",
            onSelect = "rpInventorySearch",
        },
    })
    if not tokens then
        print("[rp_inventory] context menu registration failed: " .. tostring(err))
        return
    end
    print("[rp_inventory] context menu actions registered")
end

-- Register on our own start and again when the context menu package restarts:
-- a stopped provider loses its registrations.
AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE or name == "open77_contextmenu" then
        CreateThread(registerActions)
    end
end)
