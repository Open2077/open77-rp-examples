resource "eval_taxi"
version "1.1.0"
auto_start true

-- network.events    client: TriggerServerEvent   server: RegisterNetEvent
-- map.read          client: Open77.map.getWaypoint
-- world.vehicles    server: Open77.vehicles.create / remove / get / owner / getPlayerSeat /
--                           taskPlayerEnter / forcePlayerOutOfVehicle /
--                           ai.attachDriver / ai.driveTo / ai.state / ai.stop / ai.removeDriver
-- world.npcs        server: Open77.npcs.create / whenReady / remove  (the visible driver)
-- world.query       server: Open77.world.groundZ (puts the destination on the road)
-- players.life.read server: Open77.players.isDead (guard before seating a player)
permissions { "network.events", "map.read", "world.vehicles", "world.npcs", "world.query", "players.life.read" }

client_script "client/main.lua"
server_script "server/main.lua"
