-- rp_phone: the holophone of a Night City RP server.
-- Contacts, messages (delivered offline), voice calls on a private channel, city
-- services (NCPD, Trauma Team, Delamain, mechanic), location sharing and paid ads,
-- behind a 360x640 WebUI panel opened with /tel. The SERVER owns everything: the
-- page only sends intents and renders the state the server pushes back.
resource "rp_phone"
version "1.0.0"
open77_version "*"
auto_start true

-- open77_notifications ships a client half, so a manifest delivered to clients may
-- depend on it; the card of Open77.notifications.send asks for the line.
dependency "open77_notifications"

-- rp_inventory, rp_identity, rp_ncpd, rp_trauma, rp_delamain, rp_jobs, rp_bank and
-- rp_economy are reached through exports inside pcall and never declared: this
-- manifest ships a client script, and a client-delivered manifest cannot depend on a
-- server-only resource (rp_economy) without ending the session with missing_dependency.

-- Every permission below is the one the card of a native this resource calls requires:
--   network.events              RegisterNetEvent / TriggerClientEvent / Open77.notifications.send
--                               (server), RegisterNetEvent / TriggerServerEvent (client)
--   database.access             Open77.database.* (rp_phone_sms, rp_phone_contacts, rp_phone_ads,
--                               rp_phone_lines)
--   voice.manage                Open77.voice.createChannel / addPlayer / removePlayer / removeChannel
--                               (one private channel per accepted call)
--   players.animations.control  Open77.animations.play / stop (the phone and call profiles, lists in
--                               RpPhoneConfig.anim resolved through Open77.animations.get)
--   ui.vanilla.map              Open77.blips.create / remove (client: the shared-location pin)
permissions {
    "network.events",
    "database.access",
    "voice.manage",
    "players.animations.control",
    "ui.vanilla.map",
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
web_files { "web/**" }
