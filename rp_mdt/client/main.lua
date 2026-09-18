-- rp_mdt: client side. Shows the tablet page and relays what the page asks to the
-- server; decides nothing. The page opens only when the server says so
-- (rp_mdt:open carries the mode) and every click becomes a rp_mdt:intent the
-- server answers with rp_mdt:data.

local page = nil        -- the WebUI surface, created hidden at start
local pageReady = false -- the page raised "ready"
local isOpen = false
local pendingOpen = nil -- an open that arrived before the page was ready

local function doClose()
    if not page or not isOpen then return end
    isOpen = false
    page:send("close", {})
    page:setFocus(false, false)
    page:hide()
end

local function doOpen(payload)
    if not page then return end
    if not pageReady then
        pendingOpen = payload
        return
    end
    isOpen = true
    page:show()
    -- Keyboard + cursor: the tablet has search fields. Escape on the page emits "close".
    page:setFocus(true, true)
    page:send("open", payload)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Created hidden, far ahead of the first /mdt, so show() never races create().
    local surface, reason = Open77.webui.create({
        entry = "web/index.html",
        layer = "menu",
        transparent = true,
        visible = false,
    })
    if not surface then
        print("[rp_mdt] webui unavailable: " .. tostring(reason))
        return
    end
    page = surface

    page:on("ready", function()
        pageReady = true
        if pendingOpen then
            local p = pendingOpen
            pendingOpen = nil
            doOpen(p)
        end
    end)

    -- Every page action: forwarded as-is, the server re-checks duty and answers.
    page:on("intent", function(payload)
        if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
        TriggerServerEvent("rp_mdt:intent", payload)
    end)

    -- The X button or Escape on the page.
    page:on("close", function()
        doClose()
        TriggerServerEvent("rp_mdt:intent", { action = "close" })
    end)
end)

RegisterNetEvent("rp_mdt:open", function(payload)
    if type(payload) ~= "table" then return end
    doOpen(payload)
end)

RegisterNetEvent("rp_mdt:close", function()
    doClose()
end)

RegisterNetEvent("rp_mdt:data", function(payload)
    if page and isOpen and type(payload) == "table" then
        page:send("data", payload)
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if page then
        if isOpen then page:setFocus(false, false) end
        page:destroy()
        page = nil
    end
end)
