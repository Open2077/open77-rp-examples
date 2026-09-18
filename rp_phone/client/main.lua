-- rp_phone: client. Presentation only. The WebUI page is created once (visible,
-- transparent, its own content hidden) and shown when the server says so; every
-- button on it becomes TriggerServerEvent("rp_phone:intent", kind, payload) and
-- the page re-renders the state the server pushes (rp_phone:state). Focus follows
-- one rule: it is held only while the phone is open, and a watchdog releases it
-- if anything else left it behind.

local Config = RpPhoneConfig

local page = nil
local pageReady = false
local phoneOpen = false
local pendingState = nil
local blips = {}   -- blipId -> true

local function releaseFocus()
    if not page then return end
    page:setFocus(false, false)
end

-- The single exit: every way the phone closes goes through here.
local function closeLocal(tellServer)
    if page then page:send("close", {}) end
    phoneOpen = false
    releaseFocus()
    if tellServer then
        TriggerServerEvent("rp_phone:intent", "close", {})
    end
end

local function openLocal(state)
    if not page then return end
    phoneOpen = true
    if pageReady then
        page:send("state", state)
        page:send("open", {})
        page:setFocus(true, true)
    else
        pendingState = state
    end
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- A surface meant to stay up is created visible; the page hides its own panel
    -- (Open77.webui.create card: a show() right after create loses the race).
    local created, reason = Open77.webui.create({
        entry = "web/index.html",
        layer = "menu",
        transparent = true,
        visible = true,
    })
    if not created then
        print("[rp_phone] webui unavailable: " .. tostring(reason))
        return
    end
    page = created
    page:on("ready", function()
        pageReady = true
        page:send("config", {
            adPrice = Config.ads.price,
            adMinutes = Config.ads.minutes,
            smsMax = Config.sms.maxLength,
            adMax = Config.ads.maxLength,
            nameMax = Config.contacts.nameMaxLength,
            ringSeconds = Config.call.ringSeconds,
        })
        if phoneOpen and pendingState then
            local state = pendingState
            pendingState = nil
            openLocal(state)
        end
    end)
    -- Every button of the page: { kind = "sms.send", payload = { ... } }
    page:on("intent", function(p)
        if type(p) ~= "table" or type(p.kind) ~= "string" then return end
        TriggerServerEvent("rp_phone:intent", p.kind, type(p.payload) == "table" and p.payload or {})
    end)
    -- Escape / the X button
    page:on("close", function()
        closeLocal(true)
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    closeLocal(false)
    for id in pairs(blips) do Open77.blips.remove(id) end
    blips = {}
    if page then
        page:destroy()
        page = nil
    end
end)

-- Server -> client
RegisterNetEvent("rp_phone:open", function(state)
    openLocal(state)
end)

RegisterNetEvent("rp_phone:state", function(state)
    if not page then return end
    if pageReady then
        page:send("state", state)
    elseif phoneOpen then
        pendingState = state
    end
end)

RegisterNetEvent("rp_phone:close", function()
    closeLocal(false)
end)

-- A contact shared their location: a temporary map pin.
RegisterNetEvent("rp_phone:blip", function(position, label, seconds)
    if type(position) ~= "table" then return end
    local id, reason = Open77.blips.create({
        position = { x = position.x, y = position.y, z = position.z },
        sprite = Config.location.blipSprite,
        title = tostring(label or "Shared location"),
        description = "Shared from a holophone",
        active = true,
        visibleThroughWalls = true,
    })
    if not id then
        print("[rp_phone] blip refused: " .. tostring(reason))
        return
    end
    blips[id] = true
    SetTimeout(math.max(1, tonumber(seconds) or Config.location.blipSeconds) * 1000, function()
        if blips[id] then
            blips[id] = nil
            Open77.blips.remove(id)
        end
    end)
end)

-- Watchdog: focus is held only while the phone is open (ui-kit guide: assert the
-- invariant every tick rather than trust every exit path).
CreateThread(function()
    while true do
        Wait(500)
        if page and not phoneOpen and page:hasFocus() then
            releaseFocus()
        end
    end
end)
