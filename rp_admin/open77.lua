-- rp_admin: the moderation kit of a Night City RP server.
-- Admin panel (/rpadmin), restricted slash equivalents, admin mode ([ADMIN] tag + god mode),
-- player reports (/report) and the ticket queue (/tickets). Every action is journaled.
resource "rp_admin"
version "1.0.0"
open77_version "*"
auto_start true

-- Both ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit         : the admin panel (server twins `context` and `input`)
--   open77_notifications : toasts (Open77.notifications.send on the server)
dependency "open77_uikit >=1.0.0"
dependency "open77_notifications"

-- rp_jobs, rp_economy, rp_bank, rp_inventory, rp_identity, rp_ncpd, rp_trauma, rp_zones and
-- rp_logs are reached through exports inside pcall and are never declared: this manifest is
-- delivered to clients (it ships a client script) and a client-delivered manifest cannot
-- depend on a server-only resource (missing_dependency). A missing one degrades to a chat line.

-- Every permission below is the one the card of a native this resource calls requires.
permissions {
    -- server
    "acl.read",            -- Open77.acl.isAllowed: isAdmin = ACL right command.rpadmin
    "database.access",     -- Open77.database.* (rp_admin_tickets, rp_admin_actions)
    "network.events",      -- RegisterNetEvent / TriggerClientEvent / Open77.notifications.send (server),
                           -- RegisterNetEvent / TriggerServerEvent (client)
    "players.life.read",   -- Open77.players.isFrozen / isDead / spectating
    "players.life.freeze", -- Open77.players.setFrozen (Freeze / Thaw)
    "players.life.revive", -- Open77.players.revive (fallback when rp_trauma is not running)
    "players.stats.apply", -- Open77.players.setGodMode (admin mode)
    "players.spectate",    -- Open77.players.spectate (Spectate)
    "players.teleport",    -- Open77.players.teleport (Teleport to / Bring / follow the spectated player)
    -- client
    "ui.nameplates",       -- Open77.nameplates.set / remove / clear: the [ADMIN] tag over an admin in admin mode
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
