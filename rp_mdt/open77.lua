-- rp_mdt: the NCPD / Trauma Team mobile data terminal for a Night City RP server.
-- A WebUI tablet opened by /mdt while on duty. The SERVER decides the mode (ncpd or
-- trauma) from rp_jobs, answers every page action after re-checking duty, and owns
-- the report table; the client only shows the page and relays intents.
resource "rp_mdt"
version "1.0.0"
open77_version "*"
auto_start true

-- No dependency on purpose: this manifest ships a client script, so it must not depend on
-- a server-only resource (the session would fail with missing_dependency). rp_jobs,
-- rp_identity, rp_ncpd, rp_trauma, rp_garage and rp_logs are reached through pcall'd
-- exports and every one of them degrades to an "offline" line on the tablet.

-- network.events  : RegisterNetEvent / TriggerClientEvent (server), RegisterNetEvent /
--                   TriggerServerEvent (client)
-- database.access : Open77.database.* (rp_mdt_reports, plus read-only SELECTs on
--                   rp_identity_citizens, rp_ncpd_records / _warrants / _fines,
--                   rp_garage_vehicles, rp_shops_licences, rp_trauma_contracts / _bills)
permissions { "network.events", "database.access" }

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
web_files { "web/**" }
