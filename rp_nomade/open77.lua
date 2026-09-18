-- rp_nomade: Badlands convoys and crate deliveries for the `nomade` job (replaces the v1 courier run).
resource "rp_nomade"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events  : RegisterNetEvent / TriggerClientEvent (server), TriggerServerEvent / RegisterNetEvent
--                   (client), Open77.notifications.send, Open77.heldItems.hold / release
-- database.access : Open77.database.* (rp_nomade_contracts)
-- world.vehicles  : Open77.vehicles.create / get / getPosition / remove (the rented truck)
-- world.props     : Open77.props.create / attach / detach / update / setTransform / remove (the crates, carried then in the truck bed)
-- world.npcs      : Open77.npcs.create / setAttitude / tasks.attack / remove (the ambush)
-- players.animations.control : Open77.animations.play / stop (the two-hand carry pose while a crate is held)
-- ui.vanilla.map  : Open77.blips.create / setDescription / remove / setWaypoint / clearWaypoint (client: destination and camp pins + GPS route)
permissions { "network.events", "database.access", "world.vehicles", "world.props", "world.npcs", "players.animations.control", "ui.vanilla.map" }

-- Every dependency below ships a client half, so a manifest delivered to clients may depend on it.
--   open77_uikit         : contracts menu (server twin `context`) and the unloading bar (server twin `progress`)
--   open77_worldui       : the contracts board ring + E prompt, one ring + E prompt per crate, the destination ring
--   open77_interactions  : the E prompts on the rented truck (a globalVehicle target: load / unload / return)
--   open77_props         : the client projection that draws the crates and their hand attachment
--   open77_notifications : the payout toast
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_interactions >=0.1.0"
dependency "open77_props >=0.1.0"
dependency "open77_notifications"

-- rp_jobs, rp_zones, rp_inventory, rp_economy and rp_bank are reached through pcall'd exports:
-- rp_jobs and rp_zones ship a client half of their own and the others are server-only, and a
-- manifest delivered to clients cannot depend on a server-only resource (missing_dependency).

shared_script "shared/config.lua"
client_script "client/main.lua"
server_script "server/main.lua"
