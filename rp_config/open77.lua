resource "rp_config"
version "1.0.0"
auto_start true

-- network.events : RegisterNetEvent("chat:ready") to publish the /config suggestions
-- database.access: the rp_config_values table (Open77.database.*)
permissions { "network.events", "database.access" }

-- The catalogue lives in shared/ by convention but is loaded as a SERVER script on
-- purpose: this resource has no client half, so nothing of it is ever delivered to a
-- client, and a resource that ships a client_script may still read it through
-- pcall(exports.rp_config:get, ...) without declaring a dependency.
server_script "shared/defaults.lua"
server_script "server/main.lua"
