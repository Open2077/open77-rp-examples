-- rp_trauma - client: renders the "down" state and the medic tools. No authority here.
--
-- * While the server holds this player down: the whole gameplay input stream is taken
--   (Open77.input.blockAll - chat keeps working so /respawn can be typed) and a UI-kit
--   hint shows the countdown.
-- * For an on-duty medic: one map pin per down citizen (Open77.blips) whose title
--   carries the live distance, and two ALT+click actions on another player's body,
--   Stabilise and Revive (open77_contextmenu). Both only send a request; the server
--   re-checks duty, range and the patient's state before anything happens.

local RESOURCE = GetCurrentResourceName()

local held = false
local heldUntil = 0        -- Open77.time.monotonic() when /respawn opens; 0 = open or unknown
local isMedic = false
local downPins = {}        -- [playerId] = { blip, position, name, contract }
local downSet = {}         -- [playerId] = true, for the context-menu predicates

local function log(fmt, ...)
    print(("[rp_trauma] " .. fmt):format(...))
end

-- Exports of the official packages are called asynchronously (they may wait).
local function uikit(method, ...)
    local promise, reason = Open77.exports.call("open77_uikit", method, ...)
    if not promise then
        return nil, reason
    end
    return promise:await()
end

local function menu(method, ...)
    local promise, reason = Open77.exports.call("open77_contextmenu", method, ...)
    if not promise then
        return nil, reason
    end
    return promise:await()
end

local function localPosition()
    local state = Open77.character.state()
    return state and state.position or nil
end

local function distanceTo(pos)
    local me = localPosition()
    if not me or not pos then
        return nil
    end
    local dx, dy, dz = pos.x - me.x, pos.y - me.y, pos.z - me.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------------------------------------------------------------------------
-- The hold (this player is down)
-- ---------------------------------------------------------------------------

local function holdText()
    local left = 0
    if heldUntil > 0 then
        left = math.max(0, math.ceil(heldUntil - Open77.time.monotonic()))
    end
    if left > 0 then
        return ("DOWN - Trauma Team notified - /respawn opens in %d s"):format(left)
    end
    return "DOWN - /respawn wakes you up at Vik's clinic, or wait for Trauma Team"
end

local function applyHold(seconds)
    if not held then
        local ok, reason = Open77.input.blockAll()
        if not ok then
            log("blockAll refused: %s", tostring(reason))
        end
    end
    held = true
    heldUntil = seconds > 0 and (Open77.time.monotonic() + seconds) or 0
end

local function releaseHold()
    if held then
        Open77.input.blockAll(false)
    end
    held = false
    heldUntil = 0
    CreateThread(function()
        uikit("hideTextUI")
    end)
end

-- The hint is replaced every second while down (textUI replaces the caller's slot).
CreateThread(function()
    while true do
        Wait(1000)
        if held then
            local _, reason = uikit("textUI", {
                text = holdText(),
                eyebrow = "Trauma Team",
                icon = "TT",
                position = "bottom",
                color = "#FF6060",
            })
            if reason then
                log("textUI: %s", tostring(reason))
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Map pins for on-duty medics
-- ---------------------------------------------------------------------------

local function pinTitle(entry, metres)
    local dist = metres and ("%.0f m"):format(metres) or "? m"
    return ("%s%s down - %s"):format(entry.contract and "[CONTRACT] " or "", entry.name, dist)
end

local function removePin(playerId)
    local entry = downPins[playerId]
    if entry then
        if entry.blip then
            Open77.blips.remove(entry.blip)
        end
        downPins[playerId] = nil
    end
    downSet[playerId] = nil
end

local function addPin(playerId, position, name, contract)
    removePin(playerId)
    local entry = { position = position, name = name or ("player " .. tostring(playerId)), contract = contract == true }
    local blip, reason = Open77.blips.create({
        position = position,
        sprite = entry.contract and Config.blip.contractSprite or Config.blip.sprite,
        title = pinTitle(entry, distanceTo(position)),
        description = "Trauma Team dispatch: a citizen is down here. ALT+click the body: Revive.",
        active = true,
        visibleThroughWalls = true,
    })
    if blip then
        entry.blip = blip
    else
        log("blip for player %s refused: %s", tostring(playerId), tostring(reason))
    end
    downPins[playerId] = entry
    downSet[playerId] = true
end

local function clearPins()
    for id in pairs(downPins) do
        removePin(id)
    end
    downSet = {}
end

CreateThread(function()
    while true do
        Wait(Config.blip.refreshMs)
        for _, entry in pairs(downPins) do
            if entry.blip then
                Open77.blips.setTitle(entry.blip, pinTitle(entry, distanceTo(entry.position)))
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Server -> client
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_trauma:hold", function(active, seconds)
    if active then
        applyHold(tonumber(seconds) or 0)
    else
        releaseHold()
    end
end)

RegisterNetEvent("rp_trauma:medic", function(onDuty, list)
    isMedic = onDuty == true
    clearPins()
    if isMedic then
        for _, item in ipairs(list or {}) do
            local id = tonumber(item.playerId)
            if id and item.position then
                addPin(id, item.position, item.name, item.contract)
            end
        end
    end
end)

RegisterNetEvent("rp_trauma:downBlip", function(playerId, position, name, contract)
    local id = tonumber(playerId)
    if isMedic and id and position then
        addPin(id, position, name, contract)
    end
end)

RegisterNetEvent("rp_trauma:downClear", function(playerId)
    local id = tonumber(playerId)
    if id then
        removePin(id)
    end
end)

-- ---------------------------------------------------------------------------
-- ALT+click actions (open77_contextmenu). Predicates are UX only: the server
-- re-validates duty, distance and the patient's state.
-- ---------------------------------------------------------------------------

local function targetPlayer(ctx)
    if not isMedic or not ctx or not ctx.target then
        return nil
    end
    if ctx.target.isLocalPlayer then
        return nil
    end
    return tonumber(ctx.target.playerId)
end

exports("traumaCanStabilise", function(ctx)
    local target = targetPlayer(ctx)
    if not target or downSet[target] then
        return false
    end
    if Open77.players.isDead(target) then
        return false
    end
    local stats = Open77.stats.get(target)
    if stats and stats.health and stats.health.value >= stats.health.maximum then
        return false
    end
    return true
end)

exports("traumaCanRevive", function(ctx)
    local target = targetPlayer(ctx)
    if not target then
        return false
    end
    return downSet[target] == true or Open77.players.isDead(target) == true
end)

exports("traumaStabilise", function(ctx)
    local target = targetPlayer(ctx)
    if not target then
        return false
    end
    TriggerServerEvent("rp_trauma:action", "stabilise", target)
    return true
end)

exports("traumaRevive", function(ctx)
    local target = targetPlayer(ctx)
    if not target then
        return false
    end
    TriggerServerEvent("rp_trauma:action", "revive", target)
    return true
end)

local function registerActions()
    local tokens, err = menu("registerPlayers", {
        {
            id = "trauma_revive",
            label = ("Revive (Trauma Team, %d €$)"):format(Config.reviveFee),
            description = "Bring a down citizen back on their feet. Free for contract holders.",
            group = "Trauma Team",
            icon = "person",
            networked = true,
            distance = Config.actionRange,
            order = 10,
            canInteract = "traumaCanRevive",
            onSelect = "traumaRevive",
        },
        {
            id = "trauma_stabilise",
            label = ("Stabilise (Trauma Team, %d €$)"):format(Config.healFee),
            description = "Patch up a hurt citizen to full health.",
            group = "Trauma Team",
            icon = "interact",
            networked = true,
            distance = Config.actionRange,
            order = 20,
            canInteract = "traumaCanStabilise",
            onSelect = "traumaStabilise",
        },
    })
    if not tokens then
        log("context-menu registration failed: %s", tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function announceReady()
    local sent = TriggerServerEvent("rp_trauma:clientReady")
    if not sent then
        CreateThread(function()
            Wait(2000)
            TriggerServerEvent("rp_trauma:clientReady")
        end)
    end
end

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE then
        registerActions()
        announceReady()
    elseif name == "open77_contextmenu" then
        registerActions()
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then
        return
    end
    releaseHold()
    clearPins()
end)
