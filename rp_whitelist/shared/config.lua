-- rp_whitelist - operator settings.
-- Every text a refused player reads is here. The host trims a refusal to 127 bytes of
-- UTF-8, so keep the sentences short. Player-facing text is English.

Config = {}

-- Master switch of the whitelist / queue. The eval server ships with it OFF so the test
-- bot and the owner keep connecting; `/wl activer` flips it at runtime and the choice is
-- persisted in this resource's KVP store (it survives a restart and overrides this value).
Config.enabled = false

-- "allowlist": only listed identities may connect; everybody else reads refusalText.
-- "queue":     everybody may connect, but when the server is at maxPlayers the listed
--              identities go first (priority queue); unlisted players queue behind them.
Config.mode = "allowlist"

-- Soft player cap the priority queue enforces. No native exposes the server's own
-- `network.maximumPlayers` on this build, and the host refuses `server_full` BEFORE the
-- resource gate runs, so this value MUST be strictly below `network.maximumPlayers` in
-- server.jsonc: the difference is the pool of slots only the queue hands out.
-- 0 disables the queue entirely (the whitelist / bans still apply).
Config.maxPlayers = 0

-- Optional convar override of maxPlayers, read from the `convars` block of server.jsonc
-- through GetConvarInt each time the gate runs. Leave the name as is, or set it to
-- "sv_maxPlayers" if you already mirror your slot count there. A missing or non-integer
-- convar falls back to Config.maxPlayers above.
Config.maxPlayersConvar = "rp_whitelist_max_players"

-- Where an unlisted player is told to apply.
Config.discordLink = "https://discord.open2077.net"

-- Refusal sentences. %s / %d are filled in by the resource.
Config.refusalText = "This server is whitelisted. Apply on the Discord: %s"          -- %s = discordLink
Config.banText     = "Banned from Night City %s: %s"                                 -- %s = "for 12 min" | "permanently", %s = reason
Config.fullText    = "Night City is full (%d/%d). Queue #%d - reconnect to keep your place." -- online, cap, position
Config.errorText   = "The gate cannot verify your access right now. Try again in a minute."

-- Priority queue tuning.
Config.queue = {
    -- How long a connecting player is held at the gate while a slot is awaited. The host
    -- refuses a hold that outlives `simulation.connectGateTimeoutSeconds` (default 8,
    -- maximum 9) with `connection_gate_timeout`, so keep this below that value.
    holdSeconds = 6.5,
    -- Slot poll interval while held.
    pollMs = 500,
    -- A log line `connecting '<name>': queue #N` every this often while held (the host
    -- writes deferrals.update to the server log only: the player never sees it).
    positionEveryMs = 10000,
    -- A refused player keeps their queue position for this long without knocking again.
    ttlSeconds = 120,
    -- A slot handed to a player at the gate is counted as taken for this long, or until
    -- the player shows up in onPlayerConnected, whichever comes first.
    reserveSeconds = 10,
}

-- When the whitelist is enabled and the gate itself errors (storage down, bug), refuse
-- (true) rather than admit (false). The host's own default is to admit on a handler error.
Config.failClosed = true

-- How long the gate waits for the entries / bans to be loaded from storage after a
-- start before deciding (seconds). Below the gate deadline on purpose.
Config.loadWaitSeconds = 5

-- How long the resource waits for the database bridge after a start before it falls back to
-- its Open77.kvp store for the whole boot (a bridge stuck in "connecting" never answers).
Config.storageWaitSeconds = 15

-- Bans are enforced even while the whitelist is disabled (a ban is a ban). Set to false
-- to make `/wl desactiver` switch the bans off as well.
Config.bansWhenDisabled = true

-- How many recent refusals `/wl statut` keeps in memory.
Config.recentRefusals = 10
