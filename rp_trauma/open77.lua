-- rp_trauma: Trauma Team and RP death for a Night City RP server.
-- Absorbs rp_medic (/soin /reanimer /911 /medic) and adds the "down" state, the
-- hospital respawn with its bill, the medic ALT+click actions, the Trauma Team AV
-- and the Trauma Team contract.
resource "rp_trauma"
version "1.0.0"
open77_version "*"
auto_start true

-- All three ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit         : progress bars on the medic and the /contrat menu (server twins)
--   open77_contextmenu   : ALT+click "Stabilise" / "Revive" on another player (client)
--   open77_notifications : toasts (Open77.notifications.send on the server)
dependency "open77_uikit >=1.0.0"
dependency "open77_contextmenu"
dependency "open77_notifications"
--   open77_props         : the client projection that draws the injector / kit while a medic works
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_zones, rp_bank, rp_economy and rp_identity are reached through pcall:
-- their READMEs ask a resource that ships a client script not to declare them, and
-- rp_economy is server-only (a client-delivered manifest cannot depend on it).

-- Every permission below is the one the card of a native this resource calls requires:
--   players.stats.read    Open77.stats.get (server: fees / client: the Stabilise predicate)
--   players.stats.apply   Open77.stats.setHealth / restoreHealth / setHealthRegenEnabled
--   players.life.read     Open77.players.isDead / getLifeState (both sides)
--   players.life.revive   Open77.players.revive (medic revive of a dead player)
--   players.life.respawn  Open77.players.respawn (/respawn while the body is still dead)
--   players.life.freeze   Open77.players.setFrozen (the "down" hold)
--   players.teleport      Open77.players.teleport (back to the death spot, to the hospital)
--   world.vehicles        Open77.vehicles.create / remove / warpPlayerIntoVehicle (the AV)
--   network.events        RegisterNetEvent / TriggerClientEvent / Open77.notifications.send,
--                         TriggerServerEvent on the client
--   database.access       Open77.database.* (rp_trauma_contracts, rp_trauma_bills)
--   input.blockAll        Open77.input.blockAll (client: a down player cannot act)
--   ui.vanilla.map        Open77.blips.* (client: the down-player pin on a medic's map)
--   players.animations.control  Open77.animations.play / stop (the medic's kneel, the wounded pose of a
--                         down player, the /911 dial; Config.Stage)
--   world.props           Open77.props.create / attach / remove (the injector and kit shown while treating)
permissions {
    "players.animations.control",
    "world.props",
    "players.stats.read",
    "players.stats.apply",
    "players.life.read",
    "players.life.revive",
    "players.life.respawn",
    "players.life.freeze",
    "players.teleport",
    "world.vehicles",
    "network.events",
    "database.access",
    "input.blockAll",
    "ui.vanilla.map",
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
