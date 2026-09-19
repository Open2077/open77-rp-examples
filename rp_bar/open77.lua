-- rp_bar: the Afterlife bar counter -- recipes, restock, till, serving with consent,
-- the buzz and a club ambience, for a Night City RP server (build 2.31.13+op77.76).
resource "rp_bar"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events              : RegisterNetEvent / TriggerClientEvent / TriggerServerEvent,
--                               Open77.notifications.send, Open77.sound.play / stop
-- database.access             : Open77.database.* (rp_bar_sales)
-- players.animations.control  : Open77.animations.play / stop (the mixing pose, the customer's sip, the
--                               drinking profile; RpBarConfig.Stage)
-- world.props (also)          : Open77.props.create / attach / remove (the bottle and keg in the bartender's hand)
-- players.interactions.control: Open77.playerInteractions.request / cancel (serve with consent)
-- players.interactions.read   : Open77.playerInteractions.current (is the customer busy?)
-- players.screenfx            : Open77.effects.screen (the drunk wobble)
-- world.props                 : Open77.props.create / remove (the neon sign by the counter)
-- Open77.players.ragdoll (the stumble) checks no permission on op77.76 (its card names
-- `players.motion.control`, a permission the platform does not define).
permissions {
    "network.events",
    "database.access",
    "players.animations.control",
    "players.interactions.control",
    "players.interactions.read",
    "players.screenfx",
    "world.props",
}

-- Every dependency below ships a client half, so a manifest delivered to clients may
-- depend on it:
--   open77_uikit               : counter / serve menus and the mixing bar (server twins)
--   open77_worldui             : the counter ring + map pin + E prompt (client)
--   open77_contextmenu         : ALT+click "Serve a drink" on a customer (client)
--   open77_player_interactions : the consent + synchronized hand-over (server API)
--   open77_notifications       : toasts (server)
--   open77_sound               : the ambience loop (server twin, file shipped below)
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_contextmenu"
dependency "open77_player_interactions >=1.0.0"
dependency "open77_notifications"
dependency "open77_animations"
dependency "open77_sound"
--   open77_props               : the client projection that draws the bottle / keg in the hand
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_zones, rp_inventory, rp_bank, rp_economy and rp_needs are reached through
-- pcall'd server exports and never declared: this manifest reaches the players (it has a
-- client script) and a client-delivered manifest must not depend on a server-only
-- resource (the session would end with missing_dependency).

-- The ambience loop: synthesized by tools/make-ambience.mjs, royalty free. Declaring it
-- here is what lets open77_sound play it.
files { "sfx/afterlife_ambience.wav" }

shared_script "shared/config.lua"
client_script "client/main.lua"
server_script "server/main.lua"
