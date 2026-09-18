-- rp_netrunner: hacking contracts for the netrunner job of a Night City RP server
-- (ping, short circuit, overheat, NCPD radio jam, access-point breach).
resource "rp_netrunner"
version "1.0.0"
open77_version "*"
auto_start true

-- All of these ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit       : the "Breaching..." bar (server twin `progress`)
--   open77_worldui     : the access-point ring + map pin + E prompt (client)
--   open77_contextmenu : ALT+click Ping / Short Circuit / Overheat on a player (client)
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_contextmenu"
--   open77_props       : the client projection that draws the deck held during a breach
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_inventory, rp_ncpd, rp_economy, rp_bank and rp_zones are reached through
-- exports inside pcall and never declared: a missing kit degrades to a chat line, not to
-- missing_dependency. open77_doors is optional too (Open77.exports.call answers
-- export_resource_unavailable when it is not loaded) and open77_hacking is the platform's
-- presentation package for the Open77.hacking.* host natives (system, auto-start).

permissions {
    -- server
    "network.events",            -- RegisterNetEvent / TriggerClientEvent (client relay of pings, duty, doors)
    "database.access",           -- Open77.database.* (rp_netrunner_log)
    "players.hacking.define",    -- Open77.hacking.define (the deck's Short Circuit / Overheat grades)
    "players.hacking.read",      -- Open77.hacking.state (cooldown / status read for /netrun)
    "players.hacking.activate",  -- Open77.hacking.start (the warned, interruptible upload)
    "players.cyberware.define",  -- Open77.cyberware.define (the operating_system implant)
    "players.cyberware.read",    -- Open77.cyberware.current (is the deck installed, which grade)
    "players.cyberware.manage",  -- Open77.cyberware.install / newOperationId (loading a grade)
    "players.life.read",         -- Open77.players.isDead (never hack or pay a dead player)
    "world.props",               -- Open77.props.create / remove (the access-point terminal); create / attach / remove (the deck held during a breach)
    "players.animations.control", -- Open77.animations.play / stop (the typing pose of a breach, the ping / jam taps; Config.Stage)
    -- client
    "ui.vanilla.map",            -- Open77.blips.create / setPosition / remove (the ping blip)
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
