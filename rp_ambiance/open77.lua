-- rp_ambiance: the living-city layer of the Night City RP build.
-- Day cycle + weighted weather, civilian figurants in the key zones, rotating
-- server notices, NCPD alert sirens, and an ambience loop per zone.
resource "rp_ambiance"
version "1.0.0"
open77_version "*"
auto_start true

-- network.events    : Open77.notifications.send / broadcast (notices, weather toasts),
--                     Open77.sound.play / stop (zone ambience), RegisterNetEvent("chat:ready")
-- world.environment : Open77.environment.setTimeRate / setTime / setWeather /
--                     setWeatherFrozen / getState (the day cycle and the weather table)
-- world.npcs        : Open77.npcs.create / get / remove / speak / whenReady / tasks.* (figurants)
-- world.effects     : Open77.effects.play (siren + flash at an NCPD alert position)
permissions { "network.events", "world.environment", "world.npcs", "world.effects" }

-- Both ship a client half, so a manifest delivered to clients may depend on them:
--   open77_notifications : the toasts every notice and weather change render through
--   rp_zones             : rp_zones:entered / rp_zones:left drive the zone ambience
-- rp_jobs, rp_bar, rp_config and open77_sound are reached at runtime only
-- (pcall / Open77.resource.state): none of them is required for this resource to run.
dependency "open77_notifications"
dependency "rp_zones"

shared_script "shared/config.lua"
server_script "server/main.lua"

-- The ambience loops are read out of the CLIENT resource image, so the resource
-- needs a client script for its files to be downloaded at all (sound guide).
client_script "client/main.lua"
files { "sfx/*.wav" }
