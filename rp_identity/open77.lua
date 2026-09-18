resource "rp_identity"
version "1.0.0"
auto_start true

-- open77_uikit          the registration form (client export `input`)
-- open77_contextmenu    the ALT+click "Show ID" action on another player
-- open77_notifications  the ID card toast (server Open77.notifications.send)
dependency "open77_uikit"
dependency "open77_contextmenu"
dependency "open77_notifications"

permissions {
    "database.access", -- Open77.database.* / MySQL (server): the citizen table
    "network.events",  -- RegisterNetEvent, TriggerClientEvent, TriggerServerEvent, notifications
    "ui.nameplates",   -- Open77.nameplates.set / remove (client): the RP name over the body
}

server_script "server/main.lua"
client_script "client/main.lua"
