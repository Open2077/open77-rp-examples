-- rp_mdt: values both runtimes read. Data only, no natives (this file reaches clients).
Config = {
    -- Which rp_jobs job opens which tablet. The legacy aliases of rp_jobs are listed too.
    jobModes = {
        ncpd = "ncpd", police = "ncpd",
        trauma = "trauma", medecin = "trauma",
    },

    modes = {
        ncpd = {
            label = "NCPD",
            title = "NCPD // MOBILE DATA TERMINAL",
            tabs = { "citizens", "vehicles", "reports", "dispatch", "nettrace" },
            chatColor = { 60, 160, 255 },
            dispatchKinds = nil,                 -- nil = every rp_ncpd:alert kind
        },
        trauma = {
            label = "Trauma Team",
            title = "TRAUMA TEAM // MEDICAL DATA TERMINAL",
            tabs = { "citizens", "medical", "reports", "dispatch" },
            chatColor = { 230, 60, 70 },
            dispatchKinds = { ["911"] = true },  -- medics only see the 911 calls
        },
    },

    -- The 900x600 panel; the page reads these to size itself.
    panel = { width = 900, height = 600 },

    -- How many rp_ncpd:alert events are kept in memory for the Dispatch tab.
    dispatch = { keep = 20 },

    -- Row caps: every answer travels in one network event (48 KiB envelope).
    limits = {
        results = 15,       -- citizen / vehicle search hits
        records = 20,       -- criminal record entries on a card
        reports = 30,       -- MDT reports per listing
        logs = 30,          -- rp_logs rows (net traces, last revives)
        vehicles = 20,      -- plates on a citizen card
        query = 48,         -- search string length
        title = 80,
        text = 2000,
        reason = 64,
        kvpReports = 100,   -- reports kept without a database (Open77.kvp fallback)
    },

    -- NCPD warrant levels accepted by the "Set warrant" form (rp_ncpd accepts 0..5, 0 lifts).
    warrant = { minLevel = 1, maxLevel = 5 },

    -- rp_ncpd:addRecord kinds offered by the "Add to record" form (^[a-z_]+$).
    recordKinds = { "report", "warning", "arrest", "seizure", "note" },

    -- Seconds without a database answer before the tablet falls back to Open77.kvp.
    databaseGraceSeconds = 15,
}
