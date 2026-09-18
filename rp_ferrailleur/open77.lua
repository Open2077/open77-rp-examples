-- rp_ferrailleur: the scrapper job of Night City -- wrecks to pry open, a scrap dealer, a crowbar that wears.
resource "rp_ferrailleur"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events              : RegisterNetEvent / TriggerClientEvent / Open77.notifications.send (server),
--                               RegisterNetEvent / TriggerServerEvent (client)
-- database.access             : Open77.database.* (rp_ferrailleur_tools)
-- world.npcs                  : Open77.npcs.create / remove (the scrap dealer)
-- players.animations.control  : Open77.animations.play / stop (the kneel while searching, the hand-overs; Config.Stage)
-- world.props                 : Open77.props.create / remove (the yard's decoration); create / attach / remove
--                               (the crowbar and the scrap shown in the scrapper's hand)
permissions {
    "network.events",
    "database.access",
    "world.npcs",
    "players.animations.control",
    "world.props",
}

-- All three ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit         : server twins `progress` (the 8 s search) and `context` (the dealer menu)
--   open77_worldui       : one ring + map pin + E prompt per wreck and on the dealer (client)
--   open77_notifications : loot / sale toasts (Open77.notifications.send)
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_notifications"
--   open77_props         : the client projection that draws the crowbar / scrap in the hand
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_zones, rp_inventory, rp_economy and rp_bank are reached through pcall'd
-- exports and are NOT declared: this manifest is delivered to clients and a client
-- session fails with missing_dependency on a server-only dependency.

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
