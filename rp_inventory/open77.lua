resource "rp_inventory"
version "1.0.0"
auto_start true

-- Client-delivered packages this resource drives. All three ship a client half,
-- so a manifest that reaches the players may depend on them.
dependency "open77_uikit"
dependency "open77_contextmenu"
dependency "open77_loot"

-- rp_needs, open77_fuel, open77_rp_basics and rp_jobs are server-only (or not
-- guaranteed to run): they are reached through pcall'd exports, never declared.

permissions {
    "network.events",            -- RegisterNetEvent / TriggerServerEvent / TriggerClientEvent
    "database.access",           -- Open77.database / MySQL (rp_inventory_items, rp_inventory_stashes)
    "world.loot",                -- Open77.loot.create/get/all/remove + onLootPickup/onLootRemoved
    "world.vehicles",            -- Open77.vehicles.getPlayerSeat (CHOOH2 can refuels the seated vehicle)
    "players.stats.read",        -- Open77.stats.get (full-health check before a heal)
    "players.stats.apply",       -- Open77.players.heal / restoreStamina
    "players.animations.read",   -- Open77.animations.current (hands-up check for /fouiller)
}

shared_script "shared/items.lua"
client_script "client/main.lua"
server_script "server/main.lua"

-- The /inv panel: a WebUI page created by client/main.lua (no permission needed,
-- as rp_mdt / rp_phone prove); the server pushes its state, the page sends intents.
web_files { "web/**" }
