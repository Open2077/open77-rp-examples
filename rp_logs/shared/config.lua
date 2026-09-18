-- rp_logs configuration. Every value the owner may want to move lives here.
-- Loaded before server/main.lua (see open77.lua). No secret belongs in this
-- file: the Discord webhook URL is read at runtime (see README, "Webhook").

RpLogsConfig = {
    -- SQL batching: a flush happens every flushIntervalMs or as soon as
    -- flushBatchSize rows are waiting, whichever comes first.
    flushIntervalMs = 2000,
    -- 10 rows x 6 parameters = 60: the server's database bridge refuses a statement with
    -- more than 64 positional parameters (LuaResourceRuntime MySqlMaxParameters, measured
    -- 18 Sept: 50-row batches failed three times and were dropped at every start).
    flushBatchSize = 10,
    -- Rows kept in memory while the database is connecting (bounded).
    pendingMax = 2000,
    -- A batch whose INSERT fails is retried this many times, then dropped.
    maxBatchAttempts = 3,

    -- In-memory ring answered by the `query` export (never yields).
    cacheSize = 500,

    -- Column bounds.
    maxTextBytes = 512,
    maxDataBytes = 2048,

    -- Discord webhook. The URL itself is NEVER in this file: it is resolved
    -- through GetConvar(webhookKey) -> server.jsonc "convars" block, then this
    -- resource's tunable of the same key (Warden panel or /logs webhook <url>,
    -- persisted by the host in tunables.json next to server.jsonc).
    webhookKey = "rp_logs_webhook",
    webhookUsername = "Night City Audit",
    webhookMinIntervalMs = 1000, -- rate limit: one POST per second
    webhookQueueMax = 100,       -- embeds waiting for their slot (oldest dropped)
    webhookBackoffSeconds = 5,   -- pause after a 429 from Discord

    -- Kinds mirrored to Discord. Any kind not listed stays SQL-only.
    sensitiveKinds = {
        ["rp_ncpd:arrest"] = true,
        ["rp_crime:robbery"] = true,
        ["rp_admin:action"] = true,
        ["rp_gangs:war"] = true,
        ["admin:ban"] = true,
        ["admin:kick"] = true,
        ["rp_logs:test"] = true,
    },

    -- Embed colours (decimal RGB as Discord wants them).
    embedColors = {
        default = 0x00E5FF,
        ["rp_ncpd:arrest"] = 0xFF4040,
        ["rp_crime:robbery"] = 0xFF8C00,
        ["rp_admin:action"] = 0xB266FF,
        ["rp_gangs:war"] = 0xFF0000,
        ["admin:ban"] = 0x8B0000,
        ["admin:kick"] = 0xC03030,
        ["rp_logs:test"] = 0x00FF7F,
    },

    -- Events that are only counted, never stored (too chatty or private).
    countedOnly = {
        ["rp_zones:entered"] = true,
        ["rp_zones:left"] = true,
        ["rp_phone:sms"] = true, -- count only, the text is never read
    },

    -- rp_needs sampling: a row is written only when hunger/thirst/fatigue
    -- crosses one of these thresholds (either direction).
    needsThresholds = { 25, 0 },

    -- /logs listing.
    defaultListCount = 10,
    maxListCount = 50,

    -- No-database fallback: the newest rows mirrored into Open77.kvp so a
    -- server without a database still keeps a short trail across restarts.
    kvpFallbackRows = 100,
    kvpFallbackMaxBytes = 60000,
}
