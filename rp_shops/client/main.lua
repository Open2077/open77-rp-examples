-- rp_shops v2, client half: presentation only.
--
-- One world POI (ring + map pin + E prompt) per vendor, through open77_worldui.
-- Pressing E sends the shop id to the server, which re-checks the distance,
-- the hours and the money before anything opens. Nothing here decides a sale.
--
-- The clothes shop asks this client to open the platform wardrobe once the
-- styling fee is paid: the wardrobe is the platform's own `/wardrobe` command,
-- run against the local command registry.

local RESOURCE = GetCurrentResourceName()
local LOG = "[" .. RESOURCE .. "]"
local Config = RpShopsConfig

local handles = {} -- shopId -> worldui handle

local function createPoi(shop)
    local promise, callError = Open77.exports.call("open77_worldui", "create", {
        id = "rp_shops_" .. shop.id,
        position = shop.position,
        radius = 1.2,
        style = "interaction",
        maxDistance = 90.0,
        label = shop.label,
        description = "Talk to " .. ((shop.vendor and shop.vendor.name) or "the vendor") .. ".",
        key = "E",
        marker = "shop",
        promptDistance = Config.promptDistance,
        event = "rp_shops:poi:" .. shop.id,
    })
    if not promise then
        print(LOG .. " POI of " .. shop.id .. " refused: " .. tostring(callError))
        return
    end
    local result, awaitError = promise:await()
    if not result or not result.ok then
        print(LOG .. " POI of " .. shop.id .. " failed: " .. tostring(awaitError or (result and result.error)))
        return
    end
    handles[shop.id] = result.handle
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    CreateThread(function()
        for _, shop in ipairs(Config.shops) do
            -- One local event per shop: the prompt's event carries no payload we can rely on.
            AddEventHandler("rp_shops:poi:" .. shop.id, function()
                TriggerServerEvent("rp_shops:open", shop.id)
            end)
            createPoi(shop)
        end
        print(LOG .. " " .. #Config.shops .. " vendor prompts placed")
    end)
end)

-- The styling fee is paid: open the platform wardrobe on this client.
RegisterNetEvent("rp_shops:wardrobe", function()
    -- Open77.runtime.executeCommand only has a server card on op77.76: on the client the
    -- table may be absent, and an unguarded index would raise in this handler.
    local called, ok, reason = pcall(function()
        local runtime = Open77.runtime
        if type(runtime) ~= "table" or type(runtime.executeCommand) ~= "function" then
            return false, "unknown_command"
        end
        return runtime.executeCommand("wardrobe")
    end)
    if not called then ok, reason = false, ok end
    if not ok then
        -- `unknown_command` = the wardrobe is not a client command on this build; the
        -- server already told the player to type /wardrobe themselves.
        print(LOG .. " wardrobe command not claimed locally: " .. tostring(reason))
    end
end)
