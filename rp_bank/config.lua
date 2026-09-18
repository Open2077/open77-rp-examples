-- rp_bank configuration, loaded on both runtimes (shared_script).
-- The client reads Config.Atms to place the pins, rings and prompts; the server reads the same
-- list to check that a player really stands next to an ATM before opening the menu.
Config = {}

-- ATM positions: real Night City points, measured 2026-09-18 (Kabuki points walked, the
-- Afterlife and Viktor's clinic from the AMM interiors). Three in Kabuki Market (the freeroam
-- spawn, Market Centre -1191.30, 2006.88, 7.82), one on the Afterlife floor by the entrance
-- stairs, one just inside Vik's clinic. `position` is the ring + E prompt; `prop` is where the
-- server spawns the terminal (world.props): 1 m off the ring so the ring stays readable, `yaw`
-- turning the machine towards the ring. If a ring is invisible on a point, stand on the spot,
-- run /pos, and paste the ground height (a ring inside the floor renders nothing).
Config.Atms = {
    { id = "atm_kabuki",    label = "ATM - Kabuki Market",     position = { x = -1188.30, y = 2006.88, z = 7.82 },
      prop = { x = -1187.30, y = 2007.40, z = 7.82, yaw = 250.0 } },     -- Market Centre, 3 m east
    { id = "atm_southgate", label = "ATM - Kabuki South Gate", position = { x = -1218.13, y = 1950.17, z = 7.98 },
      prop = { x = -1219.10, y = 1949.60, z = 7.98, yaw = 60.0 } },      -- the market's street side (pedestrian alley)
    { id = "atm_noodle",    label = "ATM - Noodle Row",        position = { x = -1178.66, y = 2028.45, z = 7.95 },
      prop = { x = -1177.70, y = 2029.10, z = 7.95, yaw = 235.0 } },
    { id = "atm_afterlife", label = "ATM - The Afterlife",     position = { x = -1447.00, y = 1022.00, z = 16.60 },
      prop = { x = -1446.20, y = 1022.80, z = 16.50, yaw = 225.0 } },    -- bar floor, by the entrance stairs
    { id = "atm_viktor",    label = "ATM - Vik's Clinic",      position = { x = -1545.00, y = 1233.00, z = 11.60 },
      prop = { x = -1544.20, y = 1233.80, z = 11.50, yaw = 225.0 } },    -- inside the clinic entrance
}

-- The terminal spawned next to every ATM ring (Open77.props.create on the server, removed on
-- stop). A raw depot mesh of the props catalogue; `false` spawns nothing. A refusal only logs.
Config.AtmProp = {
    model = "street.parking_meter",
    streamingRadius = 120.0,
}

-- /bank works within this many metres (horizontal) of an ATM.
Config.AtmRange = 3.0
-- The ATM prompt fires within the prompt's own 2.5 m; the server snapshot can lag a tick behind
-- a moving player, so the intent is accepted with a little more slack.
Config.AtmPromptRange = 5.0
-- Vertical tolerance for the distance check: the configured z is approximate.
Config.AtmHeightTolerance = 4.0

-- /virement fee: 1 % of the amount, at least 1 eddie. The fee leaves circulation.
Config.TransferFeePercent = 1
Config.TransferFeeMin = 1

-- Rows shown by the statement / "last transactions" screen.
Config.HistoryLimit = 10

-- Hard limits (server side).
Config.MaxAmount = 1000000000        -- one operation, 10^9
Config.MaxBalance = 1000000000000    -- an account or a society, 10^12

-- Staging (2026-09-18 pass): the ATM is used, not teleported into. Same rules as rp_mecano /
-- rp_nomade: `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first -- `tablet` -- then what today's 18-profile
-- eval catalogue has); `loop = true` is held until the menu closes and stopped by the server.
-- `process` is a short uncancellable bar (no pose of its own: the typing pose stays) on every
-- deposit, withdrawal and wire. A workspot is cancelled when the player moves > 0.5 m.
Config.Stage = {
    enabled = true,
    color = "#22D8E2",
    atm = {
        pose = { profiles = { { profile = "tablet" }, { profile = "phone" } }, loop = true },
    },
    process = {
        durationMs = 2000,
        label = "Processing",
    },
}

-- Client presentation.
Config.BlipSprite = "drop_point"     -- a map-capable service-point sprite (see the blips guide)
Config.LabelDistance = 40.0          -- metres the floating "ATM" label is readable from
Config.MarkerDistance = 120.0        -- metres the ground ring is visible from
Config.Color = "#22D8E2"
