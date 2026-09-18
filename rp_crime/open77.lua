-- rp_crime: the NCPD's workload -- shop robberies, vehicle theft, street deals,
-- contraband (nomad crates) and a night-time fence at the junkyard.
-- Server-only: every check, every eddie and every item is decided on the server.
-- The player sees chat lines, toasts, a UI-kit progress bar and one E prompt on the
-- fence (declared from the server through open77_interactions, no client half needed).
resource "rp_crime"
version "1.0.0"
open77_version "*"
auto_start true

-- Platform packages driven from the server (all ship a client half):
--   open77_uikit               : `progress` server twin (till, lock, crate bars)
--   open77_player_interactions : the buyer's consent to a street deal (Open77.playerInteractions)
--   open77_interactions        : the "Sell stolen goods" E prompt on the fence NPC (server define)
--   open77_notifications       : toasts (Open77.notifications.send)
dependency "open77_uikit >=1.0.0"
dependency "open77_player_interactions >=1.0.0"
dependency "open77_interactions >=0.1.0"  -- the eval server ships 0.1.0 (a >=0.2.0 pin is refused at start)
dependency "open77_notifications"
--   open77_props               : the client projection that draws the props attached to the hands
dependency "open77_props >=0.1.0"

-- RP resources whose exports this resource calls (always inside pcall). This manifest has
-- no client_script, so it MAY depend on server-only resources; the dependency guarantees
-- start order, the pcall keeps a refusal from becoming a Lua error.
dependency "rp_economy"
dependency "rp_inventory"
dependency "rp_identity"
dependency "rp_zones"
dependency "rp_ncpd"
dependency "rp_shops"
dependency "rp_garage"
dependency "rp_gangs"
dependency "rp_nomade"

permissions {
    "network.events",               -- RegisterNetEvent (chat:ready), Open77.notifications.send
    "database.access",              -- Open77.database.* (rp_crime_log)
    "world.vehicles",               -- Open77.vehicles.nearby / get / getPosition / isLockedForPlayer / setLocked / triggerHorn / getPlayerSeat
    "world.props",                  -- Open77.props.all / get (the nomad crates, read only); create / remove (the fence's crates);
                                    -- create / attach / remove (the loot bag, the pack and the parts shown in the hands)
    "players.animations.control",   -- Open77.animations.play / stop (the lockpick crouch, the hand-overs; RpCrimeConfig.stage)
    "world.npcs",                   -- Open77.npcs.create / remove / speak / templates (the fence)
    "world.environment",            -- Open77.environment.getState (the fence's opening hours)
    "players.life.read",            -- Open77.players.isDead
    "player.weapons.read",          -- Open77.weapons.get (weapon drawn before a robbery)
    "players.interactions.read",    -- Open77.playerInteractions.current
    "players.interactions.control", -- Open77.playerInteractions.request / cancel (the deal consent)
}

-- Loaded as a SERVER script on purpose: a shared_script makes the client validate this
-- manifest, and its rp_* dependencies (rp_economy, rp_ncpd ...) have no client half, so the
-- client rejected the whole resource set ("rp_crime:missing_dependency:rp_economy", 18 Sept).
server_script "shared/config.lua"
server_script "server/main.lua"
