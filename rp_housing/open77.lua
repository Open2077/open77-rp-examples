-- rp_housing: apartments and hideouts for a Night City RP server.
-- Server-authoritative: the server owns the deeds, the keys, the rent and the
-- "inside" state; the client only draws rings, prompts and map pins and asks.
resource "rp_housing"
version "1.0.0"
open77_version "*"
auto_start true

-- Client-delivered packages this resource drives; all three ship a client half,
-- so a manifest that reaches the players may depend on them.
--   open77_worldui     : ring + E prompt on every door, stash, exit and the agency
--   open77_uikit       : agency menu and sell confirmation (server twins)
--   open77_contextmenu : ALT+click a player > "Give a key"
--   open77_notifications: the toasts (Open77.notifications.send on the server)
-- rp_inventory, rp_bank, rp_economy, rp_identity and rp_zones are server-only:
-- a manifest delivered to clients may not depend on them, so their exports are
-- reached through pcall. open77_doors is optional: it is reached through
-- Open77.exports.call, which answers nil, reason instead of raising when the
-- package is absent (the "auto door" then keeps the static entrance).
dependency "open77_worldui >=0.1.0"
dependency "open77_uikit >=1.0.0"
dependency "open77_contextmenu"
dependency "open77_notifications"

permissions {
    "network.events",     -- RegisterNetEvent / TriggerClientEvent / TriggerServerEvent, Open77.notifications.send
    "database.access",    -- Open77.database.* (rp_housing_homes, rp_housing_keys)
    "players.teleport",   -- Open77.players.teleport (enter / leave / spawn at home)
    "players.life.read",  -- Open77.players.isDead / getLifeState (never move a dead or not-ready player)
    "ui.vanilla.map",     -- Open77.blips.create / remove (client): agency and home pins
    "world.props",        -- Open77.props.create / remove (server): the agency's listings terminal, removed on stop
    "players.animations.control", -- Open77.animations.play / stop (server): the crouch at the stash (Config.Stage)
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
