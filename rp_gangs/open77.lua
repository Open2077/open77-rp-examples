-- rp_gangs: territories and criminal life for a Night City RP server.
-- Server-authoritative: membership, influence, tributes, street deals, robberies
-- and wars are decided on the server; the client only draws the gang tag over
-- remote members, offers the ALT+click "Rob" action and relays what was pressed.
resource "rp_gangs"
version "1.0.0"
open77_version "*"
auto_start true

-- All three ship a client half, so a manifest delivered to clients may depend on them.
--   open77_contextmenu   : ALT+click "Rob" on another player (client registerPlayers)
--   open77_interactions  : the "Street deal" E prompt on the buyer NPCs (server define)
--   open77_notifications : toasts (Open77.notifications.send)
dependency "open77_contextmenu"
dependency "open77_interactions"
dependency "open77_notifications"
--   open77_props         : the client projection that draws the pack in the seller's hand
dependency "open77_props >=0.1.0"

-- rp_zones, rp_jobs, rp_inventory, rp_economy, rp_ncpd, rp_housing, rp_identity,
-- rp_fixer and open77_rp_basics are server-only (or not guaranteed to run): they are
-- reached through exports inside pcall and never declared, because a manifest delivered
-- to clients cannot depend on a server-only resource (missing_dependency).

permissions {
    "network.events",           -- RegisterNetEvent / TriggerClientEvent / Open77.notifications.send (server), RegisterNetEvent / TriggerServerEvent (client)
    "database.access",          -- Open77.database.* (rp_gangs_members, rp_gangs_influence)
    "world.npcs",               -- Open77.npcs.create / remove / get / tasks.hold (the buyer NPC per territory)
    "world.props",              -- Open77.props.create / remove (the crate beside every buyer); create / attach / remove (the pack in the seller's hand)
    "players.animations.read",  -- Open77.animations.current (hands-up check before a robbery)
    "players.animations.control", -- Open77.animations.play / stop (the deal hand-over and the frisk poses; Config.Stage)
    "ui.nameplates",            -- Open77.nameplates.set / remove / clear (client): the [GANG] tag over a member's body
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
