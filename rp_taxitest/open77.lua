resource "rp_taxitest"
version "0.1.0"
auto_start true

-- Diagnostic only: measures whether the vehicle AI drives from where a player
-- stands, and how the destination's z decides it. Never ship on a public server.
permissions { "world.vehicles", "world.query", "world.npcs", "network.events" }

server_script "server/main.lua"
