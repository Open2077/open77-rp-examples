-- rp_mecano: the garage job for a Night City RP server.
-- Repairs, towing, paint jobs, invoices, the impound lot and refuelling,
-- all decided on the server; the client only adds ALT+click entries.
resource "rp_mecano"
version "1.0.0"
open77_version "*"
auto_start true

-- world.vehicles               : Open77.vehicles.closest / nearby / get / repair / setHealth / setPaint /
--                                setTransform / getPosition / getHeading / getVelocity / remove / getPlayerSeat
-- database.access              : Open77.database.* (rp_mecano_impound, rp_mecano_invoices)
-- network.events               : RegisterNetEvent / TriggerClientEvent / Open77.notifications.send (server),
--                                RegisterNetEvent / TriggerServerEvent (client)
-- players.interactions.control : Open77.playerInteractions.request / cancel (the bill consent flow)
-- players.interactions.read    : Open77.playerInteractions.current
-- world.props                  : Open77.props.create / remove (the garage sign, tyre blockers, the pump);
--                                create / attach / remove (the welder, toolbox and CHOOH2 can shown while working)
-- players.animations.control   : Open77.animations.play / stop (the repair, spray, refuel, holo poses; Config.Stage)
permissions {
    "world.vehicles",
    "database.access",
    "network.events",
    "players.interactions.control",
    "players.interactions.read",
    "world.props",
    "players.animations.control",
}

-- Every declared dependency ships a client half, so a manifest delivered to
-- clients may depend on it:
--   open77_uikit               : progress bar (/reparer) and input forms, through the server twins
--   open77_worldui             : the workshop and pump rings (client)
--   open77_contextmenu         : ALT+click actions on players and vehicles (client)
--   open77_player_interactions : the accept / decline prompt of an invoice
--   open77_notifications       : the toast that accompanies an invoice
--   open77_props               : the client projection that draws the staged tools in the mechanic's hands
--   rp_jobs                    : job + duty checks (ships client/main.lua)
--   rp_inventory               : components, spray cans, CHOOH2 cans, toolkit (ships client/main.lua)
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_contextmenu"
dependency "open77_player_interactions >=1.0.0"
dependency "open77_notifications"
dependency "open77_props >=0.1.0"
dependency "rp_jobs"
dependency "rp_inventory"

-- rp_economy, rp_bank, rp_zones, rp_identity and open77_fuel are reached through
-- pcall'd exports: rp_economy / rp_bank / rp_identity are server-only (a manifest
-- delivered to clients cannot depend on them), rp_zones and open77_fuel are optional.

shared_script "shared/config.lua"
shared_script "shared/items.lua"
client_script "client/main.lua"
server_script "server/main.lua"
