-- rp_config: the central catalogue of tunables, one section per rp_* resource.
--
-- Every leaf below is a scalar (number, boolean or string) and becomes one dotted key:
--   RpConfigDefaults.rp_bank.transferFeePercent          -> "rp_bank.transferFeePercent"
--   RpConfigDefaults.rp_jobs.salary.ncpd[3]              -> "rp_jobs.salary.ncpd.3"
--   RpConfigDefaults.rp_zones.kabuki_market.centre.x     -> "rp_zones.kabuki_market.centre.x"
-- A branch (a table) is also addressable: get("rp_bank.atms.atm_kabuki.position") answers
-- { x, y, z } assembled from its leaves, and set() with a table writes every leaf.
--
-- The values are the CURRENT values of each resource's own shared/config.lua (or README when
-- the resource has no config file), copied on 2026-09-18 and re-synced the same day after the
-- move from the eval plateau to the real Night City map (hub = Kabuki Market, Watson; the
-- Afterlife, Lizzie's, Vik's clinic and Megabuilding H10 a few hundred metres south; the
-- nomads and the junkyard out in the Badlands; the dealership in Westbrook; the NCPD in its
-- city-centre building). They are documentation as much as defaults: an override only exists
-- in SQL, this file is never rewritten by the resource. tools/migrate-configs.md maps every
-- key back to the field it mirrors.
--
-- Type rules enforced by set(): an integer default only accepts integral numbers, a float
-- default accepts any number, a boolean only a boolean, a string only a string (<= 1024 bytes).
-- Write floats with a decimal point (3.0) when the consuming resource expects a float.
--
-- Loaded on the server only (see open77.lua). Nothing here is secret.

RpConfigDefaults = {

    -- rp_config itself.
    rp_config = {
        chatListMax = 30,          -- /config list from chat prints at most this many lines
    },

    -- rp_economy (README: no config file). Cash wallet.
    rp_economy = {
        startingBalance = 500,             -- a new wallet
        payday = { amount = 200, intervalMinutes = 10 },
    },

    -- rp_bank/config.lua (Config.*)
    rp_bank = {
        transferFeePercent = 1,            -- Config.TransferFeePercent (/virement fee, %)
        transferFeeMin = 1,                -- Config.TransferFeeMin
        historyLimit = 10,                 -- Config.HistoryLimit
        atmRange = 3.0,                    -- Config.AtmRange
        atmPromptRange = 5.0,              -- Config.AtmPromptRange
        atmHeightTolerance = 4.0,          -- Config.AtmHeightTolerance
        maxAmount = 1000000000,            -- Config.MaxAmount
        atms = {                           -- Config.Atms[i].position (the ring + E prompt), by id
            atm_kabuki    = { position = { x = -1188.30, y = 2006.88, z = 7.82 } },   -- Kabuki Market Centre, 3 m east
            atm_southgate = { position = { x = -1218.13, y = 1950.17, z = 7.98 } },   -- Kabuki South Gate
            atm_noodle    = { position = { x = -1178.66, y = 2028.45, z = 7.95 } },   -- Kabuki, Noodle Row
            atm_afterlife = { position = { x = -1447.00, y = 1022.00, z = 16.60 } },  -- Afterlife floor, entrance stairs
            atm_viktor    = { position = { x = -1545.00, y = 1233.00, z = 11.60 } },  -- inside Vik's clinic entrance
        },
    },

    -- rp_needs (README: no config file). Per-minute decay and the clock.
    rp_needs = {
        decayPerMinute = { hunger = 0.8, thirst = 1.2, fatigue = 0.4 },
        fatigueRecoveryPerMinute = 2.0,    -- seated in a vehicle, still
        tickSeconds = 10,
        saveSeconds = 60,
    },

    -- rp_inventory/shared/items.lua (RpInventoryConfig.*)
    rp_inventory = {
        maxCarryWeight = 40.0,
        defaultStashCapacity = 100.0,
        interactDistance = 3.0,
        dropTtlMs = 1800000,
        useDurationMs = 3000,
    },

    -- rp_jobs/shared/config.lua (RpJobsConfig.*)
    rp_jobs = {
        salary = {                         -- RpJobsConfig.Jobs[i].salary[grade], by job name
            ncpd        = { [0] = 300, [1] = 450, [2] = 600, [3] = 800 },
            trauma      = { [0] = 300, [1] = 450, [2] = 600, [3] = 800 },
            delamain    = { [0] = 200, [1] = 300, [2] = 400, [3] = 550 },
            mecano      = { [0] = 200, [1] = 300, [2] = 400, [3] = 550 },
            ripper      = { [0] = 250, [1] = 400, [2] = 550, [3] = 750 },
            nomade      = { [0] = 180, [1] = 260, [2] = 360, [3] = 500 },
            ferrailleur = { [0] = 150, [1] = 220, [2] = 300, [3] = 420 },
            barman      = { [0] = 150, [1] = 220, [2] = 300, [3] = 420 },
            fixer       = { [0] = 250, [1] = 400, [2] = 550, [3] = 750 },
            netrunner   = { [0] = 250, [1] = 400, [2] = 550, [3] = 750 },
            vigile      = { [0] = 180, [1] = 260, [2] = 360, [3] = 500 },
        },
        payrollIntervalMs = 600000,        -- RpJobsConfig.PayrollIntervalMs
        societyStartingFund = 50000,       -- RpJobsConfig.SocietyStartingFund
        hireDistance = 5.0,                -- RpJobsConfig.HireDistance
        nameplateMaxDistance = 40,         -- RpJobsConfig.NameplateMaxDistance
        agency = {                         -- RpJobsConfig.Agency: The Gallery, Kabuki Market (elevated walkway)
            position = { x = -1173.12, y = 2087.44, z = 11.94 },
            radius = 1.5,
            promptDistance = 3.0,
            reach = 12.0,
        },
    },

    -- rp_zones/shared/config.lua (Config.zones[i] by name, Config.tickMs, Config.hysteresis).
    -- Every zone is a circle: centre, radius and maxHeight (metres either side of centre.z).
    rp_zones = {
        tickMs = 500,
        hysteresis = 1.0,
        kabuki_market    = { centre = { x = -1191.30, y = 2006.88,  z = 7.82 },   radius = 70.0,   maxHeight = 15.0 },  -- safe hub
        kabuki           = { centre = { x = -1200.00, y = 1900.00,  z = 10.00 },  radius = 420.0,  maxHeight = 200.0 }, -- district
        afterlife        = { centre = { x = -1453.00, y = 1017.00,  z = 16.60 },  radius = 25.0,   maxHeight = 15.0 },  -- bar
        lizzies          = { centre = { x = -1188.90, y = 1566.20,  z = 23.00 },  radius = 18.0,   maxHeight = 15.0 },  -- bar
        h10              = { centre = { x = -1391.90, y = 1271.70,  z = 123.10 }, radius = 45.0,   maxHeight = 15.0 },  -- residential
        viktor_clinic    = { centre = { x = -1548.00, y = 1230.00,  z = 11.60 },  radius = 12.0,   maxHeight = 15.0 },  -- clinic
        ncpd_hq          = { centre = { x = -1761.50, y = -1010.80, z = 94.30 },  radius = 30.0,   maxHeight = 15.0 },  -- ncpd
        junkyard         = { centre = { x = 1374.90,  y = -1674.90, z = 49.30 },  radius = 90.0,   maxHeight = 30.0 },  -- industrial
        nomad_camp       = { centre = { x = 1792.90,  y = 2248.90,  z = 180.20 }, radius = 120.0,  maxHeight = 30.0 },  -- camp
        westbrook_dealer = { centre = { x = -1442.20, y = 127.40,   z = 18.00 },  radius = 40.0,   maxHeight = 15.0 },  -- dealership
        badlands         = { centre = { x = 1800.00,  y = -400.00,  z = 100.00 }, radius = 2700.0, maxHeight = 900.0 }, -- no NCPD coverage
    },

    -- rp_ncpd/shared/config.lua (Config.*). The precinct is the real NCPD building (city
    -- centre): cell 6 m east of the conference room, desk (entrance) 4 m north of it; the
    -- patrol outpost ring stands on the Afterlife street (Watson).
    rp_ncpd = {
        cell = { x = -1755.5, y = -1010.8, z = 94.3, heading = 270.0, radius = 6.0 },
        entrance = { x = -1761.5, y = -1006.8, z = 94.3, heading = 90.7 },
        outpost = { x = -1408.0, y = 960.0, z = 23.6, radius = 3.0 },
        actionDistance = 3.0,
        menuDistance = 3.5,
        vehicle = { range = 5.0, lockExit = true, preferRear = true },
        prison = { minMinutes = 1, maxMinutes = 120, notifyEverySeconds = 60, leashCheckMs = 5000, persistEverySeconds = 60 },
        fine = { min = 1, max = 100000, inviteTimeoutMs = 30000, autoWarrantLevel = 1 },
        warrant = { nativeHeat = false },
        alert = { blipMs = 60000 },
        grantKitRights = false,
    },

    -- rp_trauma/shared/config.lua (Config.*)
    rp_trauma = {
        downSeconds = 60,                  -- production: 600
        countdownWithoutMedics = true,     -- production: false
        hospitalBill = 500,
        healFee = 100,
        reviveFee = 300,
        stabiliseMs = 5000,
        reviveMs = 8000,
        actionRange = 3.0,
        commandRange = 5.0,
        downHealthFraction = 0.05,
        reviveHealthFraction = 0.5,
        reviveGraceMs = 5000,
        medicCooldownSeconds = 10,
        downReminderSeconds = 30,
        contractPrice = 1000,
        contractMinutes = 30,
        contractMaxFailures = 2,
        hospital = {                       -- "you wake up at Vik's": Viktor's clinic, 2 m off the chair
            respawn = { x = -1546.0, y = 1231.0, z = 11.6 },
            heading = 180.0,
        },
        av = {
            spawnDistance = 8.0, spawnUp = 1.0, ttlMs = 1800000,
            pad = { x = -1408.0, y = 960.0, z = 23.5, radius = 15.0 },   -- Config.av.pad: the Afterlife street
        },
    },

    -- rp_delamain/shared/config.lua (RpDelamainConfig.*)
    rp_delamain = {
        baseFare = 50,
        perHundredMetres = 15,
        driverShare = 0.80,
        autoEndMetres = 100,
        sampleMs = 2000,
        waitTimeoutSec = 180,
        pickupTimeoutSec = 900,
        ratingWindowSec = 900,
        blipTtlSec = 180,
        waypointRefreshM = 8,
        presets = {                        -- RpDelamainConfig.Presets[i].position, by id (street points a cab can stop at)
            afterlife     = { position = { x = -1408.0, y = 960.0,  z = 23.5 } },
            afterlife_lot = { position = { x = -1440.0, y = 1035.0, z = 22.7 } },
            dealer        = { position = { x = -1442.2, y = 127.4,  z = 18.0 } },
            lizzies       = { position = { x = -1188.9, y = 1566.2, z = 22.9 } },
        },
    },

    -- rp_mecano/shared/config.lua (Config.*)
    rp_mecano = {
        workshop = { position = { x = -1396.0, y = 966.0, z = 23.5 }, radius = 3.0 },   -- the Afterlife street garage
        pump = { position = { x = -1390.0, y = 972.0, z = 23.5 }, radius = 1.5 },       -- CHOOH2 pump, 6 m along the street
        repair = { reach = 4.0, durationMs = 15000, components = 2, requireToolkit = true },
        tow = { reach = 8.0, tickMs = 2000, distance = 6.0, minMove = 0.3 },
        paint = { reach = 6.0, price = 250 },
        bill = { reach = 10.0, timeoutMs = 60000, max = 50000, mechanicShare = 0.7 },
        impound = {
            reach = 8.0, fee = 100, testingReach = 6.0,
            fallbackCenter = { x = 1370.0, y = -1680.0, z = 49.3 },   -- the junkyard, when rp_zones is not running
            fallbackRadius = 90.0,
        },
        impoundAnywhereForTesting = false,
        fuel = { reach = 4.0 },
    },

    -- rp_ferrailleur/shared/config.lua (RpFerrailleurConfig.*). The yard is the Rancho Coronado
    -- junkyard (rp_zones `junkyard`).
    rp_ferrailleur = {
        searchReach = 3.5,
        heightTolerance = 4.0,
        searchMs = 8000,
        regenMs = 300000,
        crowbar = { durability = 20, price = 250 },
        basePrices = { scrap = 15, component = 60, chip = 200 },
        priceVariation = 0.20,
        priceIntervalMs = 600000,
        societyShare = 0.10,
        dealer = { position = { x = 1368.0, y = -1676.0, z = 49.4 }, yaw = -173.0, reach = 5.0 },
        points = {                         -- Config.points[i] (wreck collection points)
            [1] = { x = 1380.0, y = -1682.0, z = 49.4 },
            [2] = { x = 1386.0, y = -1676.0, z = 49.4 },
            [3] = { x = 1388.0, y = -1664.0, z = 49.4 },
            [4] = { x = 1376.0, y = -1660.0, z = 49.4 },
            [5] = { x = 1366.0, y = -1664.0, z = 49.4 },
            [6] = { x = 1362.0, y = -1686.0, z = 49.4 },
            [7] = { x = 1372.0, y = -1690.0, z = 49.4 },
        },
        ringRadius = 1.2,
        promptDistance = 3.0,
    },

    -- rp_nomade/shared/config.lua (RpNomadeConfig.*). The camp is the Aldecaldos camp
    -- (rp_zones `nomad_camp`); the ambush circle sits on the road between the camp and the junkyard.
    rp_nomade = {
        camp = {
            position = { x = 1792.9, y = 2248.9, z = 180.2 },
            board = { position = { x = 1790.0, y = 2252.0, z = 180.3 }, radius = 1.0, promptDistance = 3.0, reach = 5.0 },
            truckSpawn = { x = 1800.0, y = 2240.0, z = 180.2, yaw = 58.6 },
        },
        destinations = {                   -- RpNomadeConfig.Destinations[key].position / .radius
            junkyard         = { position = { x = 1374.9,  y = -1674.9, z = 49.4 },  radius = 30.0 },
            afterlife_street = { position = { x = -1408.0, y = 960.0,   z = 23.5 },  radius = 25.0 },
            drive_in         = { position = { x = -81.2,   y = 1963.3,  z = 100.8 }, radius = 40.0 },
        },
        contract = {
            payPerCrate = 150,
            convoyBonus = 0.25,
            convoyRadius = 30.0,
            convoyMinimum = 2,
            societyShare = 0.15,
            timeLimitMs = 1200000,
            unloadMs = 6000,
            historyRows = 10,
        },
        truck = { rental = 100, reach = 4.0, ttlMs = 2400000 },
        crate = { pickupDistance = 3.5, promptDistance = 3.0 },
        ambush = {
            enabled = true,
            center = { x = 1600.0, y = 600.0, z = 100.0 },
            radius = 60.0,
            minTravel = 10.0,
            count = 3,
            spawnDistance = 15.0,
            lifetimeMs = 180000,
        },
    },

    -- rp_bar/shared/config.lua (RpBarConfig.*). The counter is the real Afterlife bar counter.
    rp_bar = {
        counter = { position = { x = -1451.5, y = 1012.5, z = 17.8 }, promptDistance = 4.0, radius = 3.5, reach = 8.0 },
        drinks = {                         -- RpBarConfig.drinks[id].price / .alcohol
            beer              = { price = 30,  alcohol = 1 },
            whisky            = { price = 60,  alcohol = 2 },
            johnny_silverhand = { price = 120, alcohol = 3 },
            synth_soda        = { price = 20,  alcohol = 0 },
        },
        ingredients = {                    -- RpBarConfig.ingredients[id].cost
            ingredient_spirits = { cost = 40 },
            ingredient_mixer   = { cost = 15 },
            ingredient_ice     = { cost = 10 },
        },
        craft = { durationMs = 4000 },
        sale = { tillShare = 0.70, distance = 3.0, inviteTimeoutMs = 20000, durationMs = 4000, breakDistance = 5.0 },
        drunk = { max = 10, tickMs = 60000, screenAbove = 3, stumbleAbove = 7, stumbleDurationMs = 2000 },
        ambience = { radius = 30.0, stopRadius = 34.0, volume = 0.5, sweepMs = 5000 },
    },

    -- rp_ripperdoc/shared/config.lua (RpRipperConfig.*). The chair is Vik's own chair room.
    rp_ripperdoc = {
        chair = { position = { x = -1548.0, y = 1230.0, z = 11.6 }, yaw = -89.5, promptDistance = 4.0, reach = 4.5, radius = 4.0 },
        operateDistance = 4.0,
        quoteTimeoutMs = 30000,
        removalPriceFactor = 0.5,
        restockPriceFactor = 0.6,
        restockMaxCount = 5,
        cyberpsychosisThreshold = 4,
        cyberpsychosisDurationSeconds = 60,
        grades = {                         -- RpRipperConfig.catalogue[key].grades[id].price / .durationMs
            arms  = { street = { price = 1500, durationMs = 15000 }, industrial = { price = 3200, durationMs = 22000 } },
            legs  = { training = { price = 1200, durationMs = 12000 }, athlete = { price = 2500, durationMs = 18000 } },
            deck  = { street = { price = 2000, durationMs = 20000 } },
            ice   = { street = { price = 1800, durationMs = 14000 } },
            purge = { street = { price = 1600, durationMs = 14000 } },
        },
    },

    -- rp_fixer/shared/config.lua (Config.*). The office is Rogue's meeting room at the Afterlife.
    rp_fixer = {
        openBoardWithoutFixer = true,
        office = { x = -1436.8, y = 977.0, z = 17.0 },
        points = {                         -- Config.points[name] (gig objectives; `office` aliases Config.office)
            kabuki_market     = { x = -1191.30, y = 2006.88, z = 7.82 },
            kabuki_noodle_row = { x = -1178.66, y = 2028.45, z = 7.95 },
            lizzies           = { x = -1188.9,  y = 1566.2,  z = 23.0 },
            h10               = { x = -1391.9,  y = 1271.7,  z = 123.2 },
            junkyard          = { x = 1374.9,   y = -1674.9, z = 49.4 },
        },
        boardReach = 15.0,
        promptDistance = 3.0,
        interactReach = 4.5,
        arrivalDistance = 5.0,
        commissionRate = 0.15,
        reputation = { success = 1, abandoned = -1, timeout = -1, floor = 0 },
        maxOpenGigs = 20,
        autoPublish = true,
        republishDelaySec = 60,
        warnBeforeDeadlineSec = 60,
        guards = { count = 2, health = 150, postRadius = 3.0, guardRadius = 8, engageDistance = 25.0 },
        templates = {                      -- Config.templates[id].pay / .timeLimitSec
            delivery_meds     = { pay = 600,  timeLimitSec = 1200 },
            escort_witness    = { pay = 800,  timeLimitSec = 900 },
            retrieval_shard   = { pay = 1000, timeLimitSec = 1500 },
            extraction_techie = { pay = 1500, timeLimitSec = 1200 },
            delivery_hot      = { pay = 1200, timeLimitSec = 600 },
            extraction_vip    = { pay = 3000, timeLimitSec = 1800 },
        },
    },

    -- rp_netrunner/shared/config.lua (Config.*). The access point is the Afterlife's back room.
    rp_netrunner = {
        cooldownMs = 30000,
        traceChance = 0.5,
        deck = { price = 0 },
        hacks = {
            short_circuit = { range = 25, uploadMs = 2000, staminaCost = 20, damage = 25, statusMs = 750, recoveryMs = 4000 },
            overheat      = { range = 25, uploadMs = 2500, staminaCost = 20, damage = 10, statusMs = 750, recoveryMs = 4000 },
        },
        ping = { range = 50, durationMs = 60000, refreshMs = 2000, warnTarget = false },
        jam = { durationMs = 60000, noiseEveryMs = 15000 },
        accessPoint = { position = { x = -1419.9, y = 989.4, z = 16.6 }, radius = 1.2, promptDistance = 3.0, reach = 4.0 },
        breach = { durationMs = 10000, doorRadius = 15.0, doorHoldMs = 30000, bounty = 200, societyBounty = 100 },
    },

    -- rp_vigile/shared/config.lua (VigileConfig.*)
    rp_vigile = {
        ratePerMinute = 20,
        societyShare = 0.20,
        minMinutes = 1,
        maxMinutes = 240,
        bodyguardRange = 15.0,
        minuteCoverage = 0.75,
        tickMs = 5000,
        unpaidWarnAfter = 2,
        offerTimeoutSec = 180,
        zoneOfferTimeoutSec = 1800,
        escortRange = 3.0,
        escortHoldMs = 120000,
        expelDistance = 20.0,
        journalSize = 50,
        templates = {                      -- VigileConfig.templates[i].minutes, by zone
            afterlife     = { minutes = 30 },
            lizzies       = { minutes = 30 },
            kabuki_market = { minutes = 20 },
        },
    },

    -- rp_garage/shared/config.lua (Config.*). The garages sit on the Afterlife street (Watson),
    -- the dealership in Westbrook (showroom bay = the race grid), the impound at the junkyard.
    rp_garage = {
        garages = {                        -- Config.garages[i], by id
            public = {
                position = { x = -1408.0, y = 960.0, z = 23.5 },
                spawnPoint = { x = -1412.0, y = 968.0, z = 23.5, yaw = 0.0 },
            },
            mecano = {
                position = { x = -1396.0, y = 966.0, z = 23.5 },
                spawnPoint = { x = -1390.0, y = 968.0, z = 23.5, yaw = 0.0 },
            },
        },
        dealership = {
            position = { x = -1442.2, y = 127.4, z = 18.1 },
            spawnPoint = { x = -1450.2, y = 119.9, z = 14.8, yaw = 0.0 },
        },
        vehicles = {                       -- Config.vehicles[i].price, keyed by a slug of the label
            archer_hella              = { price = 15000 },  -- Vehicle.v_standard2_archer_hella_player
            arch_nazare               = { price = 12000 },  -- Vehicle.v_sportbike2_arch_player
            thorton_mackinaw          = { price = 28000 },  -- Vehicle.v_standard3_thorton_mackinaw_player
            villefort_cortes_delamain = { price = 45000 },  -- Vehicle.v_standard2_villefort_cortes_delamain_player
            quadra_turbo_r            = { price = 60000 },  -- Vehicle.v_sport1_quadra_turbo_player
        },
        impound = { fee = 500, lotPosition = { x = 1370.0, y = -1680.0, z = 49.3 } },
        reach = { prompt = 3.0, garage = 6.0, store = 8.0, lock = 6.0, plate = 8.0, key = 5.0, keyVehicle = 8.0, height = 4.0 },
        spawnTries = 3,
        spawnStep = 6.0,
        spawnClearance = 3.0,
        minHealthOnTakeOut = 0.2,
        snapshotIntervalMs = 30000,
        stolenCooldownS = 300,
        menuTimeoutMs = 60000,
        confirmTimeoutMs = 30000,
    },

    -- rp_shops/shared/config.lua (RpShopsConfig.*). The five shops are real Kabuki Market stalls.
    rp_shops = {
        reach = 3.5,
        promptDistance = 3.0,
        societyShare = 0.70,
        restockCostRatio = 0.5,
        gunLicenceFee = 500,
        stylingFee = 200,
        blackmarket = { openHour = 22, closeHour = 6 },
        robLoot = { min = 200, max = 600 },
        robCooldownSeconds = 1200,
        robDistance = 5.0,
        robHandsUpMs = 20000,
        robTakesFromSociety = true,
        maxCountPerPurchase = 20,
        weaponFallbackMs = 15000,
        shops = {                          -- RpShopsConfig.shops[i], by id; prices by catalogue id
            supermarket = {                                                    -- Noodle Row
                position = { x = -1178.66, y = 2028.45, z = 7.95 }, yaw = 149.6,
                prices = { water = 10, burrito = 25, nicola = 15, chooh2 = 60, cigarettes = 20 },
            },
            pharmacy = {                                                       -- The Stalls
                position = { x = -1223.91, y = 1989.45, z = 7.98 }, yaw = 298.1,
                restockTo = 10,
                prices = { bandage = 40, maxdoc = 120, bounceback = 90 },
            },
            gunshop = {                                                        -- East Row
                position = { x = -1160.50, y = 2019.06, z = 7.76 }, yaw = 111.6,
                prices = { pistol = 400, rifle = 1200, katana = 900 },
            },
            clothes = {                                                        -- Vendor Lane
                position = { x = -1212.26, y = 1978.53, z = 7.98 }, yaw = 323.5,
                prices = { styling = 200 },
            },
            blackmarket = {                                                    -- Lower Walkway, under the market
                position = { x = -1201.07, y = 2035.60, z = 5.60 }, yaw = 198.8,
                prices = { synthcoke = 150, lockpick = 80, qh_ping = 120 },
            },
        },
    },

    -- rp_housing/shared/config.lua (Config.*). Five real flats (AMM interior points); the ids are
    -- kept from the plateau so deeds, stashes and overrides survive. There is no `entrance` key
    -- any more: the front door is found at runtime (Config.autoDoor) with a static fallback of
    -- interior + `autoDoor.fallback` metres along x.
    rp_housing = {
        rent = 500,
        rentIntervalSec = 600,
        rentTickSec = 60,
        evictAfter = 2,
        sellBackRatio = 0.70,
        promptDistance = 3.0,
        serverTolerance = 2.5,
        agencyRadius = 4.0,
        keyDistance = 3.0,
        interiorRadius = 8.0,
        enterFade = 400,
        spawnWaitSec = 30,
        stashCapacity = 200,
        autoDoor = { radius = 6.0, outside = 1.5, fallback = 3.0, retrySec = 60 },
        agency = { position = { x = -1218.65, y = 2022.93, z = 7.82 }, radius = 1.5 },   -- Kabuki Market, The Crossing
        homes = {                          -- Config.homes[i], by id
            northside_container = { price = 9000,  interior = { x = -1503.8, y = 2224.9, z = 22.2 } },   -- Northside Apartment
            badlands_hideout    = { price = 15000, interior = { x = -1524.0, y = -992.6, z = 9.1 } },    -- Glen Apartment (Heywood)
            h10_studio          = { price = 25000, interior = { x = -1391.9, y = 1271.7, z = 123.1 } },  -- Megabuilding H10, V's Apartment
            kabuki_flat         = { price = 30000, interior = { x = -906.3,  y = 1868.7, z = 42.4 } },   -- Judy's Apartment
            japantown_loft      = { price = 40000, interior = { x = -785.3,  y = 992.6,  z = 12.0 } },   -- Japantown Apartment
        },
    },

    -- rp_hud/shared/config.lua (RpHudConfig.*)
    rp_hud = {
        minPushIntervalMs = 250,
        refreshMs = 30000,
        joinRepushMs = 6000,
        dependencyRepushMs = 4000,
        needsWarnAt = 25,
        panelWidthPx = 300,
    },

    -- rp_phone/shared/config.lua (RpPhoneConfig.*)
    rp_phone = {
        requireItem = true,
        call = { ringSeconds = 30 },
        sms = { maxLength = 200, keepPerPlayer = 300 },
        contacts = { max = 60, nearbyRadius = 8.0 },
        location = { blipSeconds = 120 },
        ads = { price = 50, minutes = 60, maxLength = 140, maxListed = 30, maxPerPlayer = 3 },
        pushThrottleMs = 250,
        intentsPerSecond = 12,
    },

    -- rp_radio/shared/config.lua (Config.*). requireItem, badlandsCut and rememberFrequency are
    -- the three keys rp_radio ALREADY reads through rp_config (its README, "Configuration").
    rp_radio = {
        requireItem = true,
        badlandsCut = false,
        rememberFrequency = true,
        rememberDelayMs = 4000,
        maxTextLength = 200,
        band = { min = 87.5, max = 108.0, step = 0.1 },
        jam = { localGain = 0.5, staticIntervalMs = 15000, garbleText = true, garbleRatio = 0.45 },
    },

    -- rp_gangs/shared/config.lua (RpGangsConfig.*). Territories are rp_zones names; `position`
    -- is the zone centre (NCPD alerts), `buyer` the street buyer NPC (the Afterlife has none).
    rp_gangs = {
        openFounding = true,
        dropOnJob = true,
        showTag = true,
        tagMaxDistance = 40.0,
        recruitReach = 5.0,
        dealInfluence = 1,
        gigInfluence = 2,
        arrestInfluence = -5,
        tributePerZone = 50,
        tributeIntervalMs = 600000,
        buyer = { reach = 4.0, promptDistance = 2.5 },
        dealPrice = 80,
        dealCooldownMs = 60000,
        robShare = 0.30,
        robReach = 3.0,
        robCooldownMs = 120000,
        warMinutes = 5,                    -- production: 20
        warTickMs = 30000,
        warInfluence = 10,
        warCooldownMs = 600000,
        racketAmount = 100,
        racketReach = 5.0,
        racketCooldownMs = 60000,
        territories = {                    -- Config.territories[i].position / .buyer, by zone name
            kabuki_market = { position = { x = -1191.30, y = 2006.88,  z = 7.82 },
                              buyer = { x = -1149.22, y = 2054.84, z = 7.76, yaw = 225.0 } },   -- Far Corner
            lizzies       = { position = { x = -1188.90, y = 1566.20,  z = 22.90 },
                              buyer = { x = -1185.00, y = 1568.00, z = 23.00, yaw = 200.0 } },  -- inside Lizzie's
            junkyard      = { position = { x = 1374.90,  y = -1674.90, z = 49.30 },
                              buyer = { x = 1370.00, y = -1670.00, z = 49.40, yaw = 135.0 } },
            afterlife     = { position = { x = -1453.00, y = 1017.00,  z = 16.50 } },
        },
    },

    -- rp_ambiance/shared/config.lua. The first eight keys are the ones rp_ambiance ALREADY
    -- reads through rp_config (Config.overrides); keep their names exactly.
    rp_ambiance = {
        realHoursPerDay = 3,               -- Config.cycle.realHoursPerDay
        weatherMinMinutes = 12,            -- Config.cycle.weatherMinMinutes
        weatherMaxMinutes = 25,            -- Config.cycle.weatherMaxMinutes
        badlands = true,                   -- Config.cycle.badlands
        noticeIntervalMinutes = 15,        -- Config.notices.intervalMinutes
        figurantsEnabled = true,           -- Config.figurants.enabled
        musicVolume = 0.35,                -- Config.music.volume
        alertsEnabled = true,              -- Config.alerts.enabled
        -- Not read by rp_ambiance yet (candidates for its Config.overrides list).
        weatherTransitionSeconds = 45,     -- Config.cycle.weatherTransitionSeconds
        announceWeather = true,            -- Config.cycle.announceWeather
        figurants = { sweepSeconds = 300, wanderRadius = 6.0, speakRadius = 8.0, speakMinSeconds = 60, speakMaxSeconds = 120 },
        zones = {                          -- Config.figurants.zones[name].centre (mirrors rp_zones)
            kabuki_market = { centre = { x = -1191.30, y = 2006.88, z = 7.82 } },
            afterlife     = { centre = { x = -1453.0,  y = 1017.0,  z = 16.5 } },
            lizzies       = { centre = { x = -1188.9,  y = 1566.2,  z = 22.9 } },
            junkyard      = { centre = { x = 1374.9,   y = -1674.9, z = 49.3 } },
        },
        notices = { enabled = true, durationMs = 10000 },
        alerts = { range = 60.0, flashes = 3, flashIntervalMs = 1200, cooldownSeconds = 8 },
    },

    -- rp_admin/shared/config.lua (RpAdminConfig.*)
    rp_admin = {
        godModeInAdminMode = true,
        maxGrade = 3,
        maxMoney = 1000000000,
        warnMaxBytes = 200,
        reportMaxBytes = 300,
        answerMaxBytes = 300,
        ticketListLimit = 20,
        recordLines = 10,
        panelTimeoutMs = 60000,
        teleportOffset = 1.5,
        spectate = { distance = 5.0, height = 2.0, blendMs = 400 },
        spawn = { x = -1191.30, y = 2006.88, z = 7.82 },   -- RpAdminConfig.Spawn: Kabuki Market Centre, the freeroam spawn
    },

    -- rp_logs/shared/config.lua (RpLogsConfig.*). Never the webhook URL: that is a secret and
    -- stays in the server convars / the resource's own tunable.
    rp_logs = {
        flushIntervalMs = 2000,
        flushBatchSize = 10,               -- 10 rows x 6 params: the database bridge caps a statement at 64 parameters
        pendingMax = 2000,
        cacheSize = 500,
        webhookMinIntervalMs = 1000,
        webhookQueueMax = 100,
        webhookBackoffSeconds = 5,
        defaultListCount = 10,
        maxListCount = 50,
    },

    -- rp_whitelist/shared/config.lua (Config.*). `enabled` is also persisted by rp_whitelist in
    -- its own KVP store (/wl activer), which wins over the file: see tools/migrate-configs.md.
    rp_whitelist = {
        enabled = false,
        mode = "allowlist",
        maxPlayers = 0,
        discordLink = "https://discord.open2077.net",
        queue = { holdSeconds = 6.5, pollMs = 500, ttlSeconds = 120, reserveSeconds = 10 },
        failClosed = true,
        loadWaitSeconds = 5,
        bansWhenDisabled = true,
        recentRefusals = 10,
    },
}
