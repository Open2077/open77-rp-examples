resource "rp_whitelist"
version "1.0.0"
auto_start true

-- rp_identity  fullName(playerId) for the /wl listings and the default note of an entry
-- rp_logs      log(kind, text, data) audit trail (every call is wrapped in pcall)
-- Both are optional at runtime (pcall), but the platform rule is: declare what you call.
-- If rp_logs is not in this server's load list yet, comment its line out: a missing
-- dependency keeps THIS resource from starting, and a gate that does not start is a
-- gate that lets everyone in.
dependency "rp_identity"
dependency "rp_logs"

permissions {
    "players.gate",    -- onPlayerConnecting + deferrals (the connection gate itself)
    "database.access", -- Open77.database.* : rp_whitelist_entries / rp_whitelist_bans
    "network.events",  -- RegisterNetEvent("chat:ready") to publish the /wl suggestion
}

-- shared/config.lua holds the operator settings. It is loaded server-side only: this
-- resource has no client script, so nothing of it is ever delivered to a player.
server_scripts {
    "shared/config.lua",
    "server/main.lua",
}
