-- rp_radio: shared configuration (loaded on both runtimes).
-- Edit here; a live server may also override a few keys through rp_config
-- (`exports.rp_config:get("rp_radio.<key>")`, read in pcall, see server/main.lua).

Config = {}

-- The band a handheld radio can tune. Frequencies are snapped to `step`.
Config.band = { min = 87.5, max = 108.0, step = 0.1 }

-- A player must hold this rp_inventory item to tune (set false to let anyone in).
Config.requireItem = true
Config.itemId = "radio"

-- Reserved frequencies: the matching rp_jobs job, on duty, is required.
-- `external` marks a slot another resource runs itself: rp_radio never creates
-- a channel for it. 100.0 is the "NCPD dispatch" voice channel rp_ncpd owns and
-- fills with its on-duty officers; the voice API is not name-addressable across
-- resources (a channel belongs to the resource that created it), so this slot
-- only documents the dial position and routes `broadcast(100.0, text)` to the
-- on-duty NCPD roster (rp_jobs:listOnDuty).
Config.reserved = {
    ["100.0"] = { job = "ncpd",   label = "NCPD dispatch", external = "rp_ncpd" },
    ["101.0"] = { job = "trauma", label = "Trauma Team" },
    ["102.0"] = { job = "mecano", label = "Mechanics" },
    ["103.0"] = { job = "nomade", label = "Nomad convoy" },
}

-- Voice effect of every radio channel (Open77.voice.createChannel `effect`).
Config.effect = {
    gain = 1.0,
    highPassHz = 220.0,
    lowPassHz = 4800.0,
    distortion = 0.08,
    radioNoise = 0.04,
    spatialBlend = 0.0,
    reverbWet = 0.0,
}

-- While rp_netrunner:jammed(true) is live.
Config.jam = {
    -- Server side: the channel effect is patched (Open77.voice.updateChannel).
    effect = { gain = 0.6, distortion = 0.35, radioNoise = 0.6 },
    -- Client side: every tuned client lowers its local channel gain
    -- (Open77.voice.setChannelVolume, a client-only native), restored to 1.0 after.
    localGain = 0.5,
    -- One static line to everyone tuned, every N ms.
    staticIntervalMs = 15000,
    -- `/radio dire` lines are garbled instead of delivered clean.
    garbleText = true,
    garbleRatio = 0.45,
}

-- Badlands cut: entering `cutZone` (rp_zones) silences the radio, leaving restores it.
-- On the eval server the whole spawn plaza sits inside the `badlands` zone (r900),
-- so the cut is OFF by default there; set it to true on a real map.
Config.badlandsCut = false
Config.cutZone = "badlands"

-- Remember the dial: a returning player is put back on their last frequency
-- (SQL table rp_radio_tuning, kvp fallback) once their inventory has loaded.
Config.rememberFrequency = true
Config.rememberDelayMs = 4000

-- `/radio dire <text>` length cap.
Config.maxTextLength = 200

-- Client push-to-talk key for the radio (rebindable in Pause > Settings > KEY BINDINGS).
-- It transmits only into the tuned radio channel (`channel:<id>` intent); the
-- platform's own PTT key (open77_voice, N by default) keeps driving proximity voice.
Config.ptt = { id = "rp_radio_ptt", name = "Radio push-to-talk", key = "CAPSLOCK" }

-- Chat colours (positional { r, g, b }).
Config.colors = {
    radio  = { 255, 170, 0 },
    static = { 140, 140, 140 },
    info   = { 0, 229, 255 },
    warn   = { 255, 80, 80 },
}

-- Static lines during a jam (one is picked at random).
Config.staticLines = {
    "kzzzt--- ...t--- ---kzzt",
    "---ssshhhk--- ...carrier lost... ---kzzt",
    "kzzt--- ...s--omeb--dy jamm--ng the b--nd... ---sshh",
    "---kzzzzt--- [no carrier] ---kzt",
}
