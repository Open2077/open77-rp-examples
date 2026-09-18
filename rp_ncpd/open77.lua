-- rp_ncpd: the police for a Night City RP server (cuff, escort, search, fines,
-- vehicle seating, jail, criminal records, warrants, dispatch radio and alerts).
resource "rp_ncpd"
version "1.0.0"
open77_version "*"
auto_start true

-- All five ship a client half, so a manifest delivered to clients may depend on them.
--   open77_contextmenu         : ALT+click actions on a player (client `registerPlayers`)
--   open77_uikit               : amount / minutes dialogs (server twins `input` and `alert`), the outpost label (client drawText3D)
--   open77_player_interactions : the citizen accepts or declines a fine (Open77.playerInteractions)
--   open77_notifications       : toasts (Open77.notifications.send)
--   open77_worldui             : the Kabuki-side outpost ring on the Afterlife street (client)
dependency "open77_contextmenu"
dependency "open77_uikit >=1.0.0"
dependency "open77_player_interactions >=1.0.0"
dependency "open77_notifications"
dependency "open77_worldui >=0.1.0"

-- open77_rp_basics (auto_start false on a fresh install), rp_jobs, rp_zones, rp_inventory,
-- rp_bank, rp_economy and rp_identity are reached through exports inside pcall and never
-- declared: a manifest delivered to clients cannot depend on a server-only resource, and
-- a missing kit must degrade to a chat line, not to missing_dependency.

permissions {
    -- server
    "network.events",               -- RegisterNetEvent / TriggerClientEvent / Open77.notifications.send
    "database.access",              -- Open77.database.* (rp_ncpd_records, _warrants, _fines, _sentences)
    "players.teleport",             -- Open77.players.teleport (cell, entrance, leash)
    "players.life.read",            -- Open77.players.isDead (never act on a dead client)
    "players.animations.read",      -- Open77.animations.current (hands-up check before a search)
    "players.animations.control",   -- Open77.animations.play / stop (the cuffing / frisking / booking poses, the cuffed suspect; Config.Stage)
    "players.interactions.read",    -- Open77.playerInteractions.current
    "players.interactions.control", -- Open77.playerInteractions.request / cancel (the fine consent)
    "world.vehicles",               -- Open77.vehicles.closest / getPlayerSeat / freeSeats / warpPlayerIntoVehicle / forcePlayerOutOfVehicle / setPlayerExitLocked
    "players.wanted",               -- Open77.players.setWanted (optional native heat mirror of a warrant)
    "voice.manage",                 -- Open77.voice.createChannel / addPlayer / removePlayer (dispatch channel)
    "world.props",                  -- Open77.props.create / remove (the outpost's sign and barrier)
    -- "acl.grant:rp.*",            -- only with Config.grantKitRights = true: Open77.acl.grant / revoke hand
                                    -- rp.cuff / rp.escort / rp.search to an officer on duty. Documented by the
                                    -- ACL guide, but open77_validate 0.1.x rejects the scoped form as unknown.
    -- client
    "input.actions",                -- Open77.input.setActionBlocked (WeaponWheel / Attack while jailed)
    "ui.vanilla.map",               -- Open77.blips.create / remove (temporary alert pins)
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
