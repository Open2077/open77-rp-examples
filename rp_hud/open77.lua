-- rp_hud: a discreet bottom-left WebUI panel for the Night City RP build.
-- The server assembles one snapshot per player from the other RP resources
-- and pushes it through rp_hud:state; the client only renders it.
resource "rp_hud"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events : RegisterNetEvent / TriggerClientEvent (server),
--                  RegisterNetEvent / TriggerServerEvent (client)
-- ui.vanilla.hud : Open77.hud.state (hide with the vanilla HUD) and
--                  Open77.hud.notify (the /interface confirmation), client side
permissions { "network.events", "ui.vanilla.hud" }

-- No dependency line on purpose. rp_economy, rp_bank, rp_jobs, rp_needs,
-- rp_zones and rp_identity are server-only for a manifest that ships a
-- client script (the session would end with missing_dependency), so their
-- exports are reached through pcall. open77_weather (the clock) and
-- open77_uikit (cinematic mode) are reached through Open77.exports.call,
-- which answers nil, reason when they are not running.

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
web_files { "html/**" }
