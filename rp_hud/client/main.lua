-- rp_hud: client half.
--
-- Owns one transparent WebUI surface on the hud layer and forwards to it what
-- the server pushes (rp_hud:state). It decides nothing about the numbers; the
-- only local state is the /interface flag and the visibility policy:
--   * hidden while the vanilla HUD is hidden by a resource (Open77.hud.state),
--   * hidden in photo mode (Open77.photoMode.isActive),
--   * hidden while the UI kit holds a cinematic claim (cinematicState),
--   * hidden when the player turned it off with /interface (session memory).
-- The world clock is read from open77_weather's client export and the page
-- keeps it ticking between two readings.

local Config = RpHudConfig
local RESOURCE = GetCurrentResourceName()

local page                 -- the WebUI surface, or nil when it could not be created
local pageReady = false    -- the page raised "ready"
local lastState            -- the last snapshot, replayed to the page when it (re)loads

local enabled = true       -- the /interface flag; lives as long as this VM
local policyHidden = false -- photo mode / vanilla HUD hidden / cinematic
local policyReason = ""
local shownState = nil     -- what the page was last told (true / false / nil = never)

local function log(fmt, ...)
    print(("[rp_hud] " .. fmt):format(...))
end

-- Tells the page whether to draw itself. The surface itself stays created
-- and visible: Open77.webui.create warns that a show() racing the creation
-- never paints, so the page hides its own content instead.
local function applyVisibility(force)
    if not page or not pageReady then return end
    local want = enabled and not policyHidden
    if want == shownState and not force then return end
    shownState = want
    local reason = ""
    if not want then
        reason = (not enabled) and "interface" or policyReason
    end
    page:send("visible", { visible = want, reason = reason })
end

local function requestSnapshot()
    local ok, reason = TriggerServerEvent("rp_hud:request")
    if ok == false then
        log("snapshot request refused: %s", tostring(reason))
    end
end

local function toast(text)
    -- A native five-second popup; hidden with the vanilla notification stack, which is fine.
    local ok, reason = Open77.hud.notify(text, { replace = true })
    if not ok then log("notify refused: %s", tostring(reason)) end
end

-- --------------------------------------------------------------------------
-- Server -> page
-- --------------------------------------------------------------------------

RegisterNetEvent("rp_hud:state", function(state)
    if type(state) ~= "table" then return end
    lastState = state
    if page and pageReady then
        page:send("state", state)
    end
end)

-- --------------------------------------------------------------------------
-- /interface : toggle the panel (client-side flag, remembered for the session)
-- --------------------------------------------------------------------------

RegisterCommand("interface", function(_, args)
    local arg = tostring(args and args[1] or ""):lower()
    if arg == "refresh" then
        requestSnapshot()
        toast("RP INTERFACE: REFRESHED")
        return
    end
    if arg == "on" then
        enabled = true
    elseif arg == "off" then
        enabled = false
    else
        enabled = not enabled
    end
    applyVisibility(true)
    if not page then
        toast("RP INTERFACE: NO PAGE (see the client log)")
        return
    end
    toast(enabled and "RP INTERFACE: ON" or "RP INTERFACE: OFF")
end, false, {
    help = "Toggle the RP panel (cash, job, needs, zone, clock)",
    parameters = { { name = "on|off|refresh", help = "optional: force a state, or ask the server for a fresh snapshot" } },
})

-- --------------------------------------------------------------------------
-- Visibility policy
-- --------------------------------------------------------------------------

-- True when every component listed in Config.hideWithComponents is hidden by
-- some resource. Open77.hud.state reports claims, not the multiplayer policy,
-- so the fixed multiplayer hides (hub, phone, scanner) never count.
local function vanillaHudHidden()
    local state = Open77.hud.state()
    if type(state) ~= "table" then return false end
    local anyKnown = false
    for _, name in ipairs(Config.hideWithComponents) do
        local visible = state[name]
        if visible == true then return false end
        if visible == false then anyKnown = true end
    end
    return anyKnown
end

local cinematicActive = false
local cinematicRetryAt = 0   -- monotonic ms; back off when open77_uikit is not running

-- Asks the UI kit whether a cinematic claim stands. The export answers
-- { active, hudHidden, mine, holders, heightPct, color }; a dispatch failure
-- (kit not loaded) is nil, reason and counts as "not cinematic".
local function refreshCinematic(nowMs)
    if nowMs < cinematicRetryAt then return end
    local pending, reason = Open77.exports.call("open77_uikit", "cinematicState")
    if not pending then
        cinematicActive = false
        if reason == "export_resource_unavailable" or reason == "export_not_found" then
            cinematicRetryAt = nowMs + 30000
        end
        return
    end
    local result = pending:await()
    if type(result) ~= "table" then
        cinematicActive = false
        return
    end
    if result.active ~= nil then
        cinematicActive = result.active == true
    elseif type(result.value) == "table" then
        cinematicActive = result.value.active == true
    else
        cinematicActive = false
    end
end

CreateThread(function()
    local elapsedMs = 0
    local sinceCinematicMs = Config.cinematicPollMs
    while true do
        Wait(Config.visibilityPollMs)
        elapsedMs = elapsedMs + Config.visibilityPollMs
        if page and pageReady then
            -- pcall: a raise in any probe would retire this loop for the whole session.
            local ok, err = pcall(function()
                local hidden, reason = false, ""

                if Open77.photoMode.isActive() == true then
                    hidden, reason = true, "photo_mode"
                end

                if not hidden and vanillaHudHidden() then
                    hidden, reason = true, "vanilla_hud_hidden"
                end

                sinceCinematicMs = sinceCinematicMs + Config.visibilityPollMs
                if sinceCinematicMs >= Config.cinematicPollMs then
                    sinceCinematicMs = 0
                    refreshCinematic(elapsedMs)
                end
                if not hidden and cinematicActive then
                    hidden, reason = true, "cinematic"
                end

                policyHidden, policyReason = hidden, reason
                applyVisibility(false)
            end)
            if not ok then log("visibility poll failed: %s", tostring(err)) end
        end
    end
end)

-- --------------------------------------------------------------------------
-- World clock (open77_weather)
-- --------------------------------------------------------------------------

local clockAvailable = nil   -- nil = unknown, true / false = last known

local function sendClock(state)
    if not page or not pageReady or type(state) ~= "table" then return end
    if clockAvailable ~= true then
        clockAvailable = true
    end
    page:send("clock", {
        available = true,
        hour = tonumber(state.hour),
        minute = tonumber(state.minute),
        second = tonumber(state.second),
        secondsOfDay = tonumber(state.secondsOfDay),
        rate = tonumber(state.rate),
        frozen = (state.frozen == true) or (state.timeFrozen == true),
        weather = type(state.weather) == "string" and state.weather or nil,
    })
end

-- Pushed by the weather client on every real change (no dependency needed);
-- the poll below is the reliable path when this never fires.
AddEventHandler("open77:weather:updated", function(state)
    sendClock(state)
end)

CreateThread(function()
    while true do
        local delay = Config.clockPollMs
        if page and pageReady then
            -- pcall: a raise here would retire the clock loop for the whole session.
            local ok, err = pcall(function()
                local pending, reason = Open77.exports.call("open77_weather", "getState")
                if pending then
                    local state = pending:await()
                    if type(state) == "table" then
                        sendClock(state)
                    end
                else
                    if clockAvailable ~= false then
                        clockAvailable = false
                        log("world clock unavailable: %s", tostring(reason))
                        page:send("clock", { available = false, reason = tostring(reason) })
                    end
                    delay = Config.clockRetryMs
                end
            end)
            if not ok then log("clock poll failed: %s", tostring(err)) end
        end
        Wait(delay)
    end
end)

-- --------------------------------------------------------------------------
-- Lifecycle
-- --------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end

    -- Created visible on purpose (see applyVisibility); the page draws nothing
    -- until the first snapshot arrives.
    local surface, reason = Open77.webui.create({
        entry = "html/index.html",
        layer = "hud",
        transparent = true,
        visible = true,
    })
    if not surface then
        log("webui unavailable: %s", tostring(reason))
        return
    end
    page = surface

    -- The page raises "ready" once its script runs (and again after a reload
    -- of the surface): configure it, replay the last snapshot, ask for a
    -- fresh one.
    page:on("ready", function()
        pageReady = true
        page:send("config", {
            warnAt = Config.needsWarnAt,
            panelWidthPx = Config.panelWidthPx,
        })
        if lastState then
            page:send("state", lastState)
        end
        shownState = nil
        applyVisibility(true)
        requestSnapshot()
    end)

    log("client started, page created")
end)
