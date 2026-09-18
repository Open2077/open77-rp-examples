-- rp_vigile: private security contracts for a Night City RP server.
-- Shared configuration (loaded on both runtimes). Every number the owner may
-- want to tune lives here; the server is the only side that decides anything.

VigileConfig = {
    -- Money ------------------------------------------------------------------
    -- What a guarded minute costs the client (a society, the platform or a
    -- citizen's bank account). The guard gets (1 - societyShare) of it in cash,
    -- the `vigile` society keeps the rest.
    ratePerMinute = 20,
    societyShare = 0.20,          -- 0.0 .. 0.9
    societyName = "vigile",       -- rp_bank society that takes the cut / holds the escrow

    -- Contracts --------------------------------------------------------------
    minMinutes = 1,
    maxMinutes = 240,
    bodyguardRange = 15.0,        -- metres: a bodyguard earns only this close to the client
    minuteCoverage = 0.75,        -- share of the samples of one minute that must be covered for it to be paid
    tickMs = 5000,                -- sampling interval (12 samples per minute)
    unpaidWarnAfter = 2,          -- consecutive unpaid minutes before the guard is told why
    offerTimeoutSec = 180,        -- a posted bodyguard offer nobody took expires (and is refunded)
    zoneOfferTimeoutSec = 1800,   -- a zone contract posted by a business/fixer leaves the board after this
    storeFallbackAfterSec = 15,   -- database still silent this long after start: fall back to kvp

    -- Rights inside a guarded zone ------------------------------------------
    escortRange = 3.0,            -- metres: the same reach as open77_rp_basics
    escortHoldMs = 120000,        -- a security escort never lasts longer than this
    expelDistance = 20.0,         -- metres outside the zone edge
    journalSize = 50,             -- camera log entries kept per guarded zone

    -- Which job pays for a zone. A zone missing here is a "corpo" contract: the
    -- platform pays (rp_economy:add only). Society names are rp_jobs job names.
    zoneSociety = {
        afterlife        = "barman",
        lizzies          = "barman",
        nomad_camp       = "nomade",
        junkyard         = "ferrailleur",
        viktor_clinic    = "ripper",
        ncpd_hq          = "ncpd",
        westbrook_dealer = "mecano",
        -- kabuki_market, kabuki, h10, badlands: corpo
    },

    -- Zone geometry used only to compute the expulsion point (centre + radius,
    -- copied from rp_zones/shared/config.lua, real Night City places). Keep it in
    -- sync when zones move; a zone missing here is still guardable, /expulser then
    -- pushes the player 20 m straight away from the guard instead of past the ring.
    zoneGeometry = {
        kabuki_market    = { x = -1191.30, y = 2006.88,  z = 7.82,  radius = 70 },
        afterlife        = { x = -1453.0,  y = 1017.0,   z = 16.6,  radius = 50 },
        lizzies          = { x = -1188.9,  y = 1566.2,   z = 23.0,  radius = 18 },
        h10              = { x = -1391.9,  y = 1271.7,   z = 123.1, radius = 45 },
        viktor_clinic    = { x = -1548.0,  y = 1230.0,   z = 11.6,  radius = 12 },
        ncpd_hq          = { x = -1761.5,  y = -1010.8,  z = 94.3,  radius = 30 },
        junkyard         = { x = 1374.9,   y = -1674.9,  z = 49.3,  radius = 90 },
        nomad_camp       = { x = 1792.9,   y = 2248.9,   z = 180.2, radius = 120 },
        westbrook_dealer = { x = -1442.2,  y = 127.4,    z = 18.0,  radius = 40 },
    },

    -- The standing zone contracts on the board (always available while nobody
    -- guards that zone). `minutes` is the length of one shift.
    templates = {
        { zone = "afterlife",     minutes = 30 },
        { zone = "lizzies",       minutes = 30 },
        { zone = "kabuki_market", minutes = 20 },
    },

    -- Where a tester stands for the README walkthrough (freeroam spawn = Kabuki
    -- Market Centre, and the Afterlife bar floor, 1.0 km south-west of it).
    testSpots = {
        spawn     = { x = -1191.30, y = 2006.88, z = 7.82 },
        afterlife = { x = -1453.0,  y = 1017.0,  z = 16.6 },
    },

    -- Chat presentation
    chatAuthor = "SECURITY",
    chatColor = { 176, 196, 222 },    -- steel
}
