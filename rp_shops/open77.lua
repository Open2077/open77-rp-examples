-- rp_shops v2: shops placed in the world with a talking vendor, an E prompt,
-- a UI-kit catalogue, cash-then-account payment, a gun licence, a night-only
-- black market, player-run (society) shops with stock, and a rob() export.
-- Replaces rp_shop (shop / buy / sell are gone; boutiques / acheter instead).
resource "rp_shops"
version "2.0.0"
open77_version "*"
auto_start true

-- All three ship a client half, so this manifest (delivered to clients) may depend on them.
--   open77_uikit   : the catalogue and quantity dialogs (server twins `context` / `input`)
--   open77_worldui : one ring + map pin + E prompt per vendor (client export `create`)
--   open77_weapons : the server-to-owner weapon relay behind Open77.weapons.assign
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_weapons >=0.1.0"
--   open77_props   : the client projection that draws the bag / case handed over at the counter
dependency "open77_props >=0.1.0"

-- rp_economy, rp_bank, rp_inventory, rp_jobs, rp_ncpd, rp_zones and rp_identity
-- are server-only: a manifest delivered to clients cannot depend on them
-- (missing_dependency), so their exports are reached through pcall.

permissions {
    -- server
    "network.events",     -- RegisterNetEvent / TriggerClientEvent / Open77.weapons.assign (client: TriggerServerEvent / RegisterNetEvent)
    "database.access",    -- Open77.database.* (rp_shops_stock, rp_shops_sales, rp_shops_licences)
    "world.npcs",         -- Open77.npcs.create / speak / tasks / remove (the vendors)
    "players.life.read",  -- Open77.players.isDead (a corpse buys nothing)
    "world.environment",  -- Open77.environment.getState (black market opening hours)
    "world.props",        -- Open77.props.create / remove (one stall prop per vendor, removed on stop); create / attach / remove (the bag handed over)
    "players.animations.control", -- Open77.animations.play / stop (the buyer's hand-over gesture; Config.Stage)
}

shared_script "shared/config.lua"
client_script "client/main.lua"
server_script "server/main.lua"
