-- rp_admin - client half. It renders exactly one thing: the [ADMIN] nameplate over an admin
-- who switched admin mode on. Every decision is the server's; this file only draws what the
-- server relays (rp_admin:tag / rp_admin:roster) and asks for the roster when it starts.

local Config = RpAdminConfig

-- playerId -> true while this client holds a plate override for that player
local tagged = {}

local function applyTag(playerId, enabled, name)
    local id = tonumber(playerId) or playerId
    if id == nil then return end
    if enabled then
        tagged[id] = true
        -- The nameplate API only overrides remote players: an admin never sees their own tag.
        Open77.nameplates.set(id, {
            label = ("%s %s"):format(Config.Tag.prefix, tostring(name or "")),
            color = Config.Tag.color,
            maxDistance = Config.Tag.maxDistance,
        })
    else
        if tagged[id] then
            tagged[id] = nil
            Open77.nameplates.remove(id)
        end
    end
end

-- One admin toggled admin mode (or disconnected while in it).
RegisterNetEvent("rp_admin:tag", function(playerId, enabled, name)
    applyTag(playerId, enabled == true, name)
end)

-- The full list of admins currently in admin mode: sent when this client asks for it.
RegisterNetEvent("rp_admin:roster", function(list)
    Open77.nameplates.clear()
    tagged = {}
    for _, entry in ipairs(list or {}) do
        applyTag(entry.id, true, entry.name)
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    TriggerServerEvent("rp_admin:clientReady")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.nameplates.clear()
    tagged = {}
end)
