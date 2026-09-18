resource "rp_selftest"
version "0.1.0"
auto_start true

-- Exercises the cross-resource contracts of the RP round from the server
-- alone (no player): the economy and jobs exports, their events, and the
-- refusals each must give. Prints one PASS/FAIL line per check.
dependency "rp_economy"
dependency "rp_jobs"
dependency "rp_identity"
dependency "rp_inventory"
dependency "rp_bank"
dependency "rp_needs"

server_script "server/main.lua"
