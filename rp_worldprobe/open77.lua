resource "rp_worldprobe"
version "0.1.0"
auto_start true

-- Lab helper only (never ship on a public server): lists the vanilla objects around a
-- player -- devices (ATMs, vending machines, terminals), doors, props -- with their engine
-- class and world position, so RP resources can bind their prompts to REAL world objects
-- (open77_interactions `class` targets) and stand their POIs on real Night City spots.
--
-- world.query   : Open77.world.nearby on the client
-- world.vehicles: Open77.vehicles.setTransform (console `vwarp`, lab helper)
-- network.events: the console command reaches the client and the rows come back
permissions { "world.query", "world.vehicles", "network.events" }

server_script "server/main.lua"
client_script "client/main.lua"
