-- rp_ripperdoc: a ripperdoc clinic for a Night City RP server.
-- The on-duty ripper installs and removes the implants this resource defines
-- through the platform's cyberware framework (open77_cyberware); the server owns
-- the catalogue, the quote, the money and the record.
resource "rp_ripperdoc"
version "1.0.0"
open77_version "*"
auto_start true

-- Platform packages this resource drives. Every one of them ships a client
-- half, so a manifest delivered to clients may depend on them.
--   open77_cyberware           : Open77.cyberware.* (definitions, install, remove)
--   open77_player_interactions : the consent flow of the quote (Open77.playerInteractions)
--   open77_uikit               : server twins `context` (catalogue), `progress` (surgery), `close`
--   open77_worldui             : the chair ring + map pin + E prompt (client)
--   open77_contextmenu         : ALT+click "Operate" on a patient (client)
--   open77_notifications       : Open77.notifications.send (toasts)
dependency "open77_cyberware >=0.1.0"
dependency "open77_player_interactions >=1.0.0"
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_contextmenu"
dependency "open77_notifications"
--   open77_props               : the client projection that draws the injector in the hand
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_inventory, rp_bank, rp_economy and rp_zones are reached through
-- pcall'd synchronous exports and never declared: their READMEs ask a resource
-- with a client script not to depend on them (missing_dependency on the client).

permissions {
    "network.events",              -- RegisterNetEvent / TriggerClientEvent / Open77.notifications.send (server), TriggerServerEvent / RegisterNetEvent (client)
    "database.access",             -- Open77.database.* (rp_ripperdoc_operations)
    "players.cyberware.define",    -- Open77.cyberware.define
    "players.cyberware.read",      -- Open77.cyberware.current
    "players.cyberware.manage",    -- Open77.cyberware.install / remove / newOperationId
    "players.hacking.define",      -- Open77.hacking.define / defineIce / definePurge (the three hacking implants)
    "players.animations.control",  -- Open77.animations.playAt / stopAt (the `lie` posture on the chair), play / stop (the restock gesture)
    "world.props",                 -- Open77.props.create / attach / remove (the injector in the ripper's hand during surgery)
    "players.interactions.control",-- Open77.playerInteractions.request / cancel (the quote)
    "players.interactions.read",   -- Open77.playerInteractions.current (patient already reserved?)
    "players.screenfx",            -- Open77.effects.screen (the cyberpsychosis overlay)
}

shared_script "shared/config.lua"
client_script "client/main.lua"
server_script "server/main.lua"
