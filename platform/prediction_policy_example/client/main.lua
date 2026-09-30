-- Publish this gamemode's combat policy to the melee / Slam / hack predictions.
--
-- Keep every value equal to what your SERVER enforces. The client uses them
-- to decide whether a hit is worth predicting: a contact inside a safe zone,
-- in another bucket, with PvP off, or possibly lethal after the multipliers is
-- not predicted and simply waits for the server's verdict.

local Policy = {
    enabled = true,               -- PvP is on in this gamemode
    bucket = 0,                   -- the routing bucket these rules cover
    safeZoneRadius = 30,          -- metres around each safe-zone centre
    safeZones = {                 -- no prediction inside these (spawn points, shops...)
        { x = -1430.26, y = 1257.66, z = 23.09 },
    },
    damageMultiplier = 1,         -- your global damage scale
    meleeMultiplier = 1,          -- extra scale on melee
    explosionMultiplier = 1,      -- extra scale on Slam (ground slam explosion)
    headshotMultiplier = 1,       -- counted conservatively for melee
}

local function publish()
    local value = { owner = GetCurrentResourceName() }
    for key, v in pairs(Policy) do value[key] = v end
    TriggerEvent("open77_prediction:policy", value)
end

-- The prediction code asks again whenever it (re)starts.
AddEventHandler("open77_prediction:requestPolicy", publish)

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then publish() end
end)

-- Withdraw the policy when the gamemode stops: predictions fail closed again.
AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        TriggerEvent("open77_prediction:policy", { enabled = false })
    end
end)
