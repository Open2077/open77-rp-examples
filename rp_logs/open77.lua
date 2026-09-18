resource "rp_logs"
version "1.0.0"
auto_start true

-- Audit trail: listens to every rp_*:... event, keeps the last events in
-- memory, batches them into SQL and mirrors the sensitive kinds to Discord.
-- No dependency on purpose: an audit trail must outlive every other resource.
-- The two optional export lookups (rp_identity:fullName, rp_needs:get) run
-- through pcall and degrade silently when the resource is absent.

permissions {
    "database.access",   -- Open77.database.* (rp_logs_events)
    "http.request",      -- PerformHttpRequest (Discord webhook)
    "players.life.read", -- Open77.players.getLifeState (death rows)
    "network.events",    -- RegisterNetEvent("chat:ready") for command suggestions
}

-- Loaded as server scripts on purpose: rp_logs ships nothing to clients.
server_scripts {
    "shared/config.lua",
    "server/main.lua",
}
