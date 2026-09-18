-- rp_garage configuration. Shared: the client places the POIs from it, the server checks every
-- distance against the same numbers. Every position is here so the owner can move it.
Config = {}

-- The hub of the RP server: Kabuki Market Centre (Watson), the freeroam spawn. The garages sit
-- on the Afterlife street a few hundred metres south, the dealership in Westbrook, the impound
-- lot at the Rancho Coronado junkyard: a car is the point of this resource, so the POIs are on
-- real streets, not on the market's pedestrian alleys.
Config.spawn = { x = -1191.30, y = 2006.88, z = 7.82 }

-- Garages. `kind = "public"` is open to everybody; `kind = "society"` is reserved for the
-- employees of `society` (rp_jobs) and also lists that society's fleet vehicles.
-- `position` is the POI (ring + E prompt); `spawnPoint` is the first bay where a vehicle taken
-- out appears (`yaw` 0 faces +y on this engine); the next bays are `Config.spawnStep` metres
-- further along +x. Stored vehicles can be taken out at any public garage.
-- `props` are real world props spawned by the server next to the ring (Open77.props.create,
-- removed on stop): `models` is a list of depot meshes tried in order, first success wins.
Config.garages = {
    {
        id = "public",
        label = "Afterlife street lot",
        kind = "public",
        -- The street outside the Afterlife's ramp (Watson), probed 2026-09-18: a crosswalk, room for
        -- three cars side by side facing north at x -1412 / -1406 / -1400, y 964..972.
        position = { x = -1408.0, y = 960.0, z = 23.5 },
        spawnPoint = { x = -1398.0, y = 953.0, z = 23.5, yaw = 90.0 },  -- the road lanes east of the crosswalk (y 968 is inside the Ellison building, checked 18 Sept)
        color = "#00E5FF",
        props = {
            -- The garage sign, 1.2 m south of the ring, facing the bays.
            { models = { "sign.street" },
              position = { x = -1408.0, y = 956.8, z = 23.5 }, yaw = 0.0 },
        },
    },
    {
        id = "mecano",
        label = "Mechanic's garage",
        kind = "society",
        society = "mecano",                                    -- rp_jobs job name
        -- Same street, 12 m east of the public lot (the mechanic's workshop, rp_mecano, stands
        -- here too). The bay is derived from the street line (6 m east of the ring, facing
        -- north like the public bays), not probed: move it if a car lands on the kerb.
        position = { x = -1396.0, y = 966.0, z = 23.5 },
        spawnPoint = { x = -1380.0, y = 953.0, z = 23.5, yaw = 90.0 },  -- same road, further east
        color = "#FF9A1F",
    },
}

-- The dealership POI and where a bought vehicle appears.
Config.dealership = {
    label = "Westbrook Motors",
    -- The Westbrook vehicle dealership (freeroam goto list, driven); the showroom bay is the
    -- Westbrook race grid 11 m south-west of the ring. The grid's facing was not measured:
    -- yaw 0 (north) until a drive proves otherwise.
    position = { x = -1442.2, y = 127.4, z = 18.1 },
    spawnPoint = { x = -1450.2, y = 119.9, z = 14.8, yaw = 0.0 },
    color = "#F5D90A",
    props = {
        -- A neon frame 1.3 m off the ring, facing it (the showroom sign).
        { models = {
              "light.spotlight",
              "sign.kiosk_frame",
          },
          position = { x = -1439.6, y = 129.4, z = 18.0 }, yaw = 128.0 },
    },
}

-- Records for sale. Every record was checked against `open77_data vehicles` (game 2.31) and
-- ends in `_player`, the spawnable variants. Prices in eddies.
Config.vehicles = {
    { record = "Vehicle.v_standard2_archer_hella_player",           label = "Archer Hella",              price = 15000 },
    { record = "Vehicle.v_sportbike2_arch_player",                  label = "Arch Nazare",               price = 12000 },
    { record = "Vehicle.v_standard3_thorton_mackinaw_player",       label = "Thorton Mackinaw",          price = 28000 },
    { record = "Vehicle.v_standard2_villefort_cortes_delamain_player", label = "Villefort Cortes Delamain", price = 45000 },
    { record = "Vehicle.v_sport1_quadra_turbo_player",              label = "Quadra Turbo-R",            price = 60000 },
}

-- Money. Purchases and release fees go account -> society through rp_bank:charge; when the
-- account is short the cash wallet (rp_economy) pays and the society is credited afterwards.
Config.society = "garage"          -- rp_bank society that receives the dealership sales
Config.impound = {
    fee = 500,                     -- eddies to get an impounded vehicle back, paid at any garage
    society = "ncpd",              -- rp_bank society that receives the release fee
    lot = "junkyard",              -- rp_zones name of the impound (informative)
    lotPosition = { x = 1370.0, y = -1680.0, z = 49.3 },   -- the Rancho Coronado junkyard (rp_mecano's tow yard)
}

-- Plates: NC-XXXX, four characters from this alphabet (no 0/O, 1/I ambiguity).
Config.plate = { prefix = "NC-", length = 4, alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" }

-- Reaches, in metres.
Config.reach = {
    prompt = 3.0,      -- promptDistance of the three POIs (E only within this distance)
    garage = 6.0,      -- /garage and /concession work within this distance of the POI
    store = 8.0,       -- a vehicle can be stored when it stands within this distance of the player
    lock = 6.0,        -- /verrouiller: nearest keyed vehicle within this distance
    plate = 8.0,       -- /plaque: nearest server vehicle within this distance
    key = 5.0,         -- /cles: the receiving player must be within this distance
    keyVehicle = 8.0,  -- /cles without a plate: nearest owned vehicle within this distance
    height = 4.0,      -- tolerated height error on POI checks (the dealership bay sits 3.3 m below its ring)
}

-- Spawn: a bay is tried up to `spawnTries` times, `spawnStep` metres apart along x, and skipped
-- when another server vehicle stands within `spawnClearance` metres of it. 6 m is the pitch of
-- the three Afterlife street bays (x -1412 / -1406 / -1400).
Config.spawnTries = 3
Config.spawnStep = 6.0
Config.spawnClearance = 3.0

-- Condition. A vehicle that was destroyed or exploded when it was stored or lost comes back
-- rolling: the wreck flags are cleared and the health floor below applies (the body damage,
-- broken glass, lights, tyres and torn-off panels are kept for the mechanic).
Config.minHealthOnTakeOut = 0.2

-- Every `snapshotIntervalMs` the server refreshes, in memory only, the condition and the fuel of
-- every vehicle that is out, so a vehicle removed by something else (admin /dv, an explosion
-- clean-up, a time to live) is put back in the garage in its last known state.
Config.snapshotIntervalMs = 30000

-- The same player entering the driver seat of a vehicle they hold no key for raises
-- rp_garage:stolen at most once per `stolenCooldownS` seconds.
Config.stolenCooldownS = 300

-- Dialog timeouts (ms), within the UI kit's 1 000..120 000.
Config.menuTimeoutMs = 60000
Config.confirmTimeoutMs = 30000
