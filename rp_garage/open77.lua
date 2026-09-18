-- rp_garage: owned vehicles for a Night City RP server.
-- Plates, garages, the dealership, keys, locks and the impound lot are all decided on the
-- server; the client only places the three POIs and adds ALT+click entries that send a request.
resource "rp_garage"
version "1.0.0"
open77_version "*"
auto_start true

-- world.vehicles  : Open77.vehicles.create / remove / get / getProperties / setProperties / nearby /
--                   getPlayerSeat / setLocked / isLocked / setLockedForPlayer / triggerHorn (server)
-- database.access : Open77.database.* (rp_garage_vehicles, rp_garage_keys)
-- world.props     : Open77.props.create / remove (the garage sign, the dealership neon; removed on stop)
-- network.events  : RegisterNetEvent / Open77.notifications.send (server), RegisterNetEvent /
--                   TriggerServerEvent (client)
-- (state bag)     : Open77.state.entity("vehicle", id):set("plate", ...) -- the state-bags guide and
--                   the Open77.state.entity card say it needs `state.write`, but that name is not a
--                   permission the op77.76 runtime enforces (open77_permissions / open77_validate
--                   refuse it), so it is not declared; the write is guarded at runtime and the plate
--                   always stays in SQL and in the exports (see writePlate in server/main.lua).
permissions { "state.write", "world.vehicles", "database.access", "network.events", "world.props" }  -- state.write: the plate state-bag key (measured: permission_denied without it); world.props: the garage sign and the showroom neon (Open77.props.create / remove)

-- Every declared dependency ships a client half, so a manifest delivered to clients may
-- depend on it:
--   open77_uikit         : the garage / dealership menus and confirmations (server twins)
--   open77_worldui       : the three POIs (ring + map pin + E prompt), client side
--   open77_contextmenu   : ALT+click "Give a key" on a player, "Lock / unlock" and "Read the plate"
--                          on a vehicle (client)
--   open77_notifications : the toasts that accompany a purchase, a store and a take-out
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_contextmenu"
dependency "open77_notifications"

-- rp_bank, rp_economy, rp_jobs, rp_identity, rp_mecano and open77_fuel are reached through
-- pcall'd exports: rp_bank / rp_economy / rp_identity are server-only (a manifest delivered to
-- clients cannot depend on them), the others are optional and degrade to a chat line.

shared_script "shared/config.lua"
client_script "client/main.lua"
server_script "server/main.lua"
