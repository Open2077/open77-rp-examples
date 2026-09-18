-- rp_gangs / client: presentation only.
--
-- 1. The [GANG] tag over every remote member's body (Open77.nameplates.set), from the
--    roster the server broadcasts. The nameplate API only overrides remote players, so
--    a member never sees their own tag.
-- 2. The ALT+click "Rob" action on another player (open77_contextmenu), shown only
--    while the server says this client is a gang member; the server re-checks
--    everything (membership, distance, whether the target is cuffed or surrendering).
-- 3. The predicate that keeps the "Street deal" prompt (a server-declared
--    open77_interactions target) on the buyer NPCs and off every other NPC.
--
-- Nothing here decides anything: every request is re-validated by server/main.lua.

local Config = RpGangsConfig

local me = { gang = nil, rank = nil, label = nil }
local plated = {}    -- playerId -> true, plates this resource currently sets
local buyers = {}    -- tostring(npcId) -> true

local function menu(method, ...)
    local promise, err = Open77.exports.call("open77_contextmenu", method, ...)
    if not promise then return nil, err end
    return promise:await()
end

-- ---------------------------------------------------------------------------
-- Exports used as callbacks by open77_contextmenu and open77_interactions
-- ---------------------------------------------------------------------------

-- Context menu predicate: the entry is offered to gang members only. Must return
-- exactly true to show the action.
exports("rpGangsCanRob", function(ctx)
    if me.gang == nil then return false end
    if type(ctx) ~= "table" or type(ctx.target) ~= "table" then return false end
    return ctx.target.playerId ~= nil and ctx.target.isLocalPlayer ~= true
end)

-- Context menu action: the minimum intent (the canonical target id) goes to the
-- server, which measures the distance and the target's state itself.
exports("rpGangsRob", function(ctx)
    if type(ctx) ~= "table" or type(ctx.target) ~= "table" or ctx.target.playerId == nil then return false end
    TriggerServerEvent("rp_gangs:rob", ctx.target.playerId)
    return true
end)

-- Interaction predicate (server-declared globalNpc target, resolved against this
-- VM): only the buyer NPCs the server told us about get the "Street deal" card.
-- No wait, no network round trip: a table lookup.
exports("rpGangsIsBuyer", function(payload)
    if type(payload) ~= "table" or payload.npcId == nil then return false end
    return buyers[tostring(payload.npcId)] == true
end)

-- ---------------------------------------------------------------------------
-- Nameplates
-- ---------------------------------------------------------------------------

local function applyRoster(list)
    if not Config.showTag then return end
    local keep = {}
    for _, entry in ipairs(list or {}) do
        local pid = entry.playerId
        if pid ~= nil then
            keep[pid] = true
            local ok, reason = Open77.nameplates.set(pid, {
                label = entry.label,
                color = entry.color,
                maxDistance = Config.tagMaxDistance,
            })
            if ok then plated[pid] = true else print("[rp_gangs] nameplate refused for " .. tostring(pid) .. ": " .. tostring(reason)) end
        end
    end
    for pid in pairs(plated) do
        if not keep[pid] then
            Open77.nameplates.remove(pid)
            plated[pid] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Net events from the server
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_gangs:self", function(gang, rank, label)
    if gang then me.gang, me.rank, me.label = gang, rank, label else me.gang, me.rank, me.label = nil, nil, nil end
end)

RegisterNetEvent("rp_gangs:roster", function(list)
    applyRoster(list)
end)

RegisterNetEvent("rp_gangs:buyers", function(ids)
    buyers = {}
    for _, id in ipairs(ids or {}) do buyers[tostring(id)] = true end
end)

-- ---------------------------------------------------------------------------
-- Context menu registration
-- ---------------------------------------------------------------------------

local function registerActions()
    CreateThread(function()
        local token, err = menu("registerPlayers", {
            id = "rp_gangs_rob",
            label = "Rob",
            description = "Take a cut of their eddies and every illegal item. They must be cuffed or surrendering.",
            group = "Gang",
            icon = "tool",
            networked = true,
            distance = Config.robReach,
            order = 60,
            danger = true,
            canInteract = "rpGangsCanRob",
            onSelect = "rpGangsRob",
        })
        if not token then print("[rp_gangs] context menu registration failed: " .. tostring(err)) end
    end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() or name == "open77_contextmenu" then
        registerActions()
    end
    if name == GetCurrentResourceName() then
        -- Ask the server for our own state, the roster and the buyer ids.
        TriggerServerEvent("rp_gangs:clientReady")
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.nameplates.clear()
    plated = {}
end)
