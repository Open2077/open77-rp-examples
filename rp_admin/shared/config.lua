-- rp_admin configuration. Shared: the client reads the tag look, the server everything else.
-- Every number and position the owner may want to move lives here.
RpAdminConfig = {
    -- The ACL right that makes a player an admin for this resource: the `isAdmin` export,
    -- the /report toasts and the panel's own re-check. /rpadmin is a restricted command, so
    -- the same right opens the panel. The slash equivalents are restricted too and need
    -- command.<name> each (or command.*), see the README.
    AdminRight = "command.rpadmin",

    -- The [ADMIN] nameplate drawn over an admin in admin mode (client, Open77.nameplates).
    Tag = { prefix = "[ADMIN]", color = "#FF4D4D", maxDistance = 60 },

    -- Admin mode also switches god mode on (Open77.players.setGodMode) when true.
    GodModeInAdminMode = true,

    -- Limits.
    MaxGrade = 3,               -- rp_jobs grades 0..3
    MaxMoney = 1000000000,      -- 1e9 eddies: the cap of /setmoney and /setbank
    WarnMaxBytes = 200,         -- /warn text
    ReportMaxBytes = 300,       -- /report text
    AnswerMaxBytes = 300,       -- /tickets fermer answer
    TicketListLimit = 20,       -- /tickets shows at most this many open tickets
    RecordLines = 10,           -- record entries shown by the Record action
    MenuPlayers = 60,           -- players listed by the panel (UI kit: 64 options per menu)
    PanelTimeoutMs = 60000,     -- a panel left open closes itself after this

    -- Spectate camera (Open77.players.spectate options).
    Spectate = { distance = 5.0, height = 2.0, blendMs = 400 },

    -- Teleport to / Bring: side offset in metres, so two bodies never resolve inside each other.
    TeleportOffset = 1.5,

    -- The freeroam spawn, where the README's test takes place (world metres):
    -- Kabuki Market Centre, Watson (walked point).
    Spawn = { x = -1191.30, y = 2006.88, z = 7.82 },

    -- Persistence: how long to wait for the database before falling back to Open77.kvp.
    DatabaseWaitMs = 15000,
}
