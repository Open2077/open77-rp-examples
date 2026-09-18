-- rp_delamain / shared config. Loaded on both runtimes; the owner tunes everything here.
RpDelamainConfig = {
    Job              = "delamain",   -- rp_jobs job name of the drivers (alias "taxi" accepted by rp_jobs)
    Society          = "delamain",   -- rp_bank society that receives the commission

    BaseFare         = 50,           -- eddies, charged on every completed ride
    PerHundredMetres = 15,           -- eddies per 100 m driven with the client on board
    DriverShare      = 0.80,         -- the driver's cut of the fare; the rest goes to the society

    AutoEndMetres    = 100,          -- the ride ends by itself when the client gets out after this many metres
    SampleMs         = 2000,         -- the meter samples server positions this often

    WaitTimeoutSec   = 180,          -- a call nobody accepted is dropped after this
    PickupTimeoutSec = 900,          -- an accepted call whose client never boarded is dropped after this
    RatingWindowSec  = 900,          -- how long after the ride the client may /note it

    -- The temporary map pin every on-duty driver gets when a client calls. `vehicle` renders on
    -- the HUD, the minimap and the world map; `Zzz19_DelamainTaxiVariant` is the vanilla
    -- Delamain icon but its map profile is not guaranteed (see the blips guide).
    BlipSprite       = "vehicle",
    BlipTtlSec       = 180,          -- a stale call pin removes itself after this
    WaypointRefreshM = 8,            -- the driver's GPS follows the waiting client when they move this far

    ChatAuthor       = "Delamain",
    ChatColor        = { 255, 200, 0 },   -- positional r, g, b (a keyed table is ignored by the chat UI)

    -- Pickup / drop-off presets: `/delamain <id>` uses the preset as the destination instead of
    -- the map waypoint. Real Night City street points (world metres, 2026-09-18): a cab can stop
    -- at each one. `id` must match ^[a-z0-9_]+$; the label is what the driver reads.
    Presets = {
        { id = "afterlife",  label = "Afterlife street (Little China)",    position = { x = -1408.0, y = 960.0,  z = 23.5 } },
        { id = "afterlife_lot", label = "The Afterlife lot (South Approach)", position = { x = -1440.0, y = 1035.0, z = 22.7 } },
        { id = "dealer",     label = "Westbrook vehicle dealership",       position = { x = -1442.2, y = 127.4,  z = 18.0 } },
        { id = "lizzies",    label = "Lizzie's Bar (Kabuki)",              position = { x = -1188.9, y = 1566.2, z = 22.9 } },
    },

    -- Staging (2026-09-18 pass): nothing to hold in a cab, but a call is a gesture. Same rules
    -- as rp_mecano / rp_nomade: `pose.profiles` are open77_animations profiles tried in order
    -- through Open77.animations.get (best FUTURE name first, then today's 18-profile eval
    -- catalogue); `loop = false` is a one-shot of `durationMs`. A driver already at the wheel
    -- is refused by the platform (player_in_vehicle): logged once, the ride goes on.
    Stage = {
        enabled = true,
        -- /delamain: the client dials Delamain on the holo.
        call = {
            durationMs = 4000,
            pose = { profiles = { { profile = "call" }, { profile = "phone" } }, loop = false },
        },
        -- /accepter: the driver answers the dispatch (on foot only).
        accept = {
            durationMs = 3000,
            pose = { profiles = { { profile = "call" }, { profile = "phone" } }, loop = false },
        },
    },
}
