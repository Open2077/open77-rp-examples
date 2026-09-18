-- rp_vigile: private security contracts (zone guarding, bodyguards, camera log)
-- for a Night City RP server. Server-authoritative: the client only registers the
-- ALT+click "Escort out" action and renders what the server pushes.
resource "rp_vigile"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events  : RegisterNetEvent / TriggerClientEvent (server), RegisterNetEvent /
--                   TriggerServerEvent (client)
-- database.access : Open77.database.* (rp_vigile_contracts)
-- players.teleport: Open77.players.teleport (/expulser) -- named by the native's card
-- world.query     : Open77.world.groundZ (the ground under the expulsion point)
permissions { "network.events", "database.access", "players.teleport", "world.query" }

-- Both ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit       : the contract board (server twin `context`)
--   open77_contextmenu : ALT+click "Escort out" / "Release" on a player in a guarded zone
dependency "open77_uikit >=1.0.0"
dependency "open77_contextmenu"

-- rp_jobs, rp_zones, rp_bank and rp_identity ship a client script too, so this
-- manifest may depend on them (they are not server-only). Their exports are still
-- reached through pcall: a synchronous export raises when the provider is away.
dependency "rp_jobs"
dependency "rp_zones"
dependency "rp_bank"
dependency "rp_identity"

-- rp_economy is server-only (no client script): a client-delivered manifest cannot
-- depend on it, so it is reached through pcall only. open77_rp_basics (auto_start
-- false), rp_ncpd and rp_fixer are optional and reached the same way.

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
