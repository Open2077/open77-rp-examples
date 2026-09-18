-- rp_delamain: player-driven Delamain cabs for a Night City RP server.
-- A client calls a cab (/delamain), every on-duty Delamain driver (rp_jobs) is paged, one of
-- them accepts (/accepter), the meter runs while the client sits in the driver's car, and the
-- fare is settled in cash (rp_economy) with a 20 % commission to the Delamain society (rp_bank).
resource "rp_delamain"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events : server RegisterNetEvent / TriggerClientEvent / Open77.notifications.send,
--                  client RegisterNetEvent / TriggerServerEvent
-- database.access: Open77.database.* (rp_delamain_rides)
-- world.vehicles : Open77.vehicles.getPlayerSeat / getPosition (who sits where, the meter)
-- ui.vanilla.map : Open77.blips.* on the client (call blip, driver GPS, client waypoint read)
-- players.animations.control : Open77.animations.play / stop (the holo call of the client, the driver's answer,
--                  the goodbye wave; RpDelamainConfig.Stage)
-- world.props    : the shared staging helper references Open77.props.create / attach / remove; no prop is
--                  configured here (nothing to hold in a cab), the validator still wants the permission
permissions { "network.events", "database.access", "world.vehicles", "ui.vanilla.map", "players.animations.control", "world.props" }

-- rp_jobs, rp_economy, rp_bank and rp_identity are reached through pcall, never declared:
-- this manifest ships a client script, so it is delivered to clients, and a client-delivered
-- manifest may not depend on a server-only resource (rp_economy, rp_bank, rp_identity).
-- eval_taxi (the NPC cab) exposes no export; the fallback is telling the client to type /taxi.

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
