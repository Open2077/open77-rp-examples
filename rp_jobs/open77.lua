-- rp_jobs v2: grades, bosses, duty, societies and payroll for a Night City RP server.
resource "rp_jobs"
version "2.0.0"
open77_version "*"
auto_start true

-- network.events  : RegisterNetEvent / TriggerClientEvent (server), RegisterNetEvent / TriggerServerEvent (client)
-- database.access : Open77.database.* (rp_jobs_employees)
-- ui.nameplates   : Open77.nameplates.set / remove / clear (client): the on-duty tag over a colleague's body
-- world.props     : Open77.props.create / remove (server): the job-board terminal behind the agency ring
permissions { "network.events", "database.access", "ui.nameplates", "world.props" }

-- All three ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit       : the agency menu (server twin `context`)
--   open77_worldui     : the agency ring + map pin + E prompt (client)
--   open77_contextmenu : ALT+click "Hire into <job>" on another player (client)
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_contextmenu"

-- rp_bank, rp_economy and rp_identity are server-only: a manifest delivered to
-- clients cannot depend on them (the session would end with missing_dependency),
-- so their exports are reached through pcall and degrade to a chat line.

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
