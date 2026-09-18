-- rp_economy: server-authoritative wallet for an RP server.
-- Server only: no client script, every decision and every message comes from the server.
resource "rp_economy"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events : required by RegisterNetEvent (the chat:ready suggestion hook)
--                  and by Open77.notifications.send (the toast that accompanies /money).
-- database.access: Open77.database.* (table rp_economy_wallets; readiness included).
--                  Without a database the wallets fall back to the resource's KVP store.
permissions { "network.events", "database.access" }

server_script "server/main.lua"
