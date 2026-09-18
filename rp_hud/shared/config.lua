-- rp_hud: values both runtimes read. Data only, no natives.
-- The server reads the push cadence and the job labels; the client reads the
-- polling cadences and the visibility policy, and forwards the thresholds to
-- the page. The owner may override any key through rp_config later
-- (pcall(exports.rp_config:get, key)); nothing here is secret.
RpHudConfig = {
    -- Server: one snapshot at most every minPushIntervalMs per player
    -- (250 ms = 4 pushes per second). Bursts of events are coalesced into
    -- one snapshot sent when the window closes.
    minPushIntervalMs = 250,

    -- Server: a keepalive snapshot for every connected player, so a missed
    -- event (a dependency restarted, a value that decayed without an event)
    -- never leaves a stale panel for long. 0 disables it.
    refreshMs = 30000,

    -- Server: a second snapshot this long after onPlayerReady. The other
    -- resources load their SQL rows asynchronously on the same event, so the
    -- very first snapshot can still read "no job" or "0 eddies".
    joinRepushMs = 6000,

    -- Server: when one of the resources below restarts, wait this long for
    -- it to reload its cache, then push everyone again.
    dependencyRepushMs = 4000,

    -- The resources whose exports feed the snapshot. None is declared as a
    -- manifest dependency: this resource ships a client script, and a
    -- manifest delivered to clients may not depend on a server-only resource.
    dependencies = { "rp_economy", "rp_bank", "rp_jobs", "rp_needs", "rp_zones", "rp_identity" },

    -- Client: how often the visibility policy is evaluated (photo mode,
    -- vanilla HUD claims) and how often the UI kit is asked about cinematic
    -- mode. The clock is re-read from open77_weather every clockPollMs; the
    -- page extrapolates between two readings.
    visibilityPollMs = 500,
    cinematicPollMs = 1000,
    clockPollMs = 2000,
    clockRetryMs = 15000,      -- when open77_weather is not running

    -- Client: the panel hides when EVERY component listed here is hidden by
    -- some resource (Open77.hud.state). Two core widgets, so a gamemode that
    -- only hides the crosshair or the quest tracker keeps the panel.
    hideWithComponents = { "minimap", "health" },

    -- Page: a need under this percentage turns its bar red.
    needsWarnAt = 25,

    -- Page: panel width in pixels (the plan caps it at 320).
    panelWidthPx = 300,

    -- Server: the display label of each rp_jobs job (rp_jobs keeps its own
    -- shared config in its own VM; this copy is for the panel only).
    jobLabels = {
        ncpd = "NCPD",
        trauma = "Trauma Team",
        delamain = "Delamain",
        mecano = "Mechanic",
        ripper = "Ripperdoc",
        nomade = "Nomad",
        ferrailleur = "Scrapper",
        barman = "Bartender",
        fixer = "Fixer",
        netrunner = "Netrunner",
        vigile = "Security",
        gang = "Gang",
        -- legacy aliases rp_jobs still accepts
        police = "NCPD",
        medecin = "Trauma Team",
        taxi = "Delamain",
    },
}
