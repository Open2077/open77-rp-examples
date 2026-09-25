resource "rp_weapons_effect"
version "0.1.0"
auto_start false
reload_policy "local"
shared_script "config.lua"
shared_script "extras-config.lua"
server_script "server.lua"
client_script "client.lua"
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
permissions { "network.events", "local.events", "acl.read", "player.weapons.read", "player.weapons.edit",
    "players.life.read", "players.motion.control", "players.motion.read" }
