resource "rp_zones"
version "1.0.0"
auto_start true

-- Toasts on zone entry/exit render through the official notifications package;
-- the ground rings around small zones are native markers owned by open77_worldui.
dependency "open77_notifications"
dependency "open77_worldui"

-- network.events : Open77.notifications.send, RegisterNetEvent("chat:ready")
-- combat.config  : Open77.combat.onDamage / offDamage (safe-zone damage arbiter)
-- ui.vanilla.map : Open77.blips.create (one map pin per zone, client side)
permissions { "network.events", "combat.config", "ui.vanilla.map" }

shared_script "shared/config.lua"
client_script "client/main.lua"
server_script "server/main.lua"
