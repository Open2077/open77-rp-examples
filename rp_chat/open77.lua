resource "rp_chat"
version "1.0.0"
auto_start true

-- network.events: RegisterNetEvent("chat:ready") and Open77.notifications.send
permissions { "network.events" }

-- Server exports this resource calls (exports.rp_jobs:getJob, exports.rp_economy:getBalance)
dependency "rp_jobs"
dependency "rp_economy"

server_script "server/main.lua"
