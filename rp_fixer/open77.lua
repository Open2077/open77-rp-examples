-- rp_fixer: the fixer's gig board for a Night City RP server.
-- Server-authoritative: gigs, phases, pay, commission, reputation and NPCs are decided
-- on the server; the client only draws the board prompt, the current objective
-- (ring + E prompt + map pin + GPS waypoint) and relays what the player pressed.
resource "rp_fixer"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events  : RegisterNetEvent / TriggerClientEvent (server), RegisterNetEvent / TriggerServerEvent (client)
-- database.access : Open77.database.* (rp_fixer_gigs, rp_fixer_reputation)
-- world.npcs      : Open77.npcs.create / remove / get / setAttitude / setGroup / tasks.* (guards, escorts, targets)
-- ui.vanilla.map  : Open77.blips.create / remove / setWaypoint / clearWaypoint (client objective pin + GPS)
-- world.props     : Open77.props.create / remove (the board's data terminal at the booth); create / attach / remove (the case in the merc's hand)
-- players.animations.control : Open77.animations.play / stop (the pickup / hand-over poses, the board tap; Config.Stage)
permissions { "network.events", "database.access", "world.npcs", "ui.vanilla.map", "world.props", "players.animations.control" }

-- Both ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit   : the board (server twin `context`) and the accept dialog (server twin `alert`)
--   open77_worldui : the board ring + E prompt at the office, the objective ring + E prompt (client)
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
--   open77_props   : the client projection that draws the case in the merc's hand
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_zones, rp_inventory, rp_economy and rp_bank are server-only: a manifest
-- delivered to clients cannot depend on them (missing_dependency), so their exports are
-- reached through pcall and every failure degrades to a chat line.

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
