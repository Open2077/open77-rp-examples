resource "rp_shop"
version "1.0.0"
auto_start true

-- Money goes through rp_economy's server exports; weapons through the
-- official open77_weapons client relay (Open77.weapons.assign).
dependency "rp_economy"
dependency "open77_weapons >=0.1.0"
dependency "open77_props >=0.1.0"  -- the client projection that draws the bag / case handed over

permissions {
    "network.events",      -- Open77.weapons.assign, RegisterNetEvent (chat:ready)
    "world.vehicles",      -- Open77.vehicles.create / get / remove
    "players.stats.apply", -- Open77.players.restoreHealth / setArmor, Open77.stats.restore
    "players.life.read",   -- Open77.players.isDead
    "players.animations.control", -- Open77.animations.play / stop (the hand-over gesture, SHOP_STAGE)
    "world.props",         -- Open77.props.create / attach / remove (the bag / case in the hand)
}

server_script "server/main.lua"
