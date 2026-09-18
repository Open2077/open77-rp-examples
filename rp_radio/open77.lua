-- rp_radio: handheld radio channels (voice + text) for a Night City RP server.
resource "rp_radio"
version "1.0.0"
open77_version "*"
auto_start true

-- rp_inventory (the `radio` item), rp_jobs (reserved bands need the job on
-- duty), rp_zones (the Badlands cut) and rp_netrunner (the jam) are reached
-- through synchronous exports inside pcall and their bus events, never
-- declared: this manifest ships a client script, and the delivered RP kits
-- ask not to be a dependency of a client-carrying manifest (a missing kit
-- degrades to a chat line, not to missing_dependency).

permissions {
    -- server
    "voice.manage",     -- Open77.voice.status / createChannel / updateChannel / removeChannel / addPlayer / removePlayer
    "database.access",  -- Open77.database.* (table rp_radio_tuning)
    "network.events",   -- RegisterNetEvent("chat:ready"), Open77.net.emitClient (server); RegisterNetEvent (client)
    -- client
    "voice.client",     -- Open77.voice.setTransmitting (radio PTT), Open77.voice.setChannelVolume (jam gain)
    "input.actions",    -- RegisterKeyMapping (the rebindable radio push-to-talk key)
    "ui.vanilla.hud",   -- Open77.hud.notify (local "no radio tuned" toast on a key press)
}

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
