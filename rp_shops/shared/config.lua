-- rp_shops v2: shops placed in the world, each with a talking vendor.
-- Shared by the server (authority: prices, stock, payment, delivery) and the
-- client (presentation only: one ring + E prompt per vendor).
--
-- The five shops are real stalls of Kabuki Market (Watson), the hub of the RP
-- server: every `position` is a walked market spot (2026-09-18), z exact. The
-- ring + E prompt stands on `position`; the vendor NPC stands 1.2 m behind it
-- (`vendorPosition`) facing it (`yaw`, 0 = +y, counter-clockwise, towards the
-- market centre), and one real prop (`prop`) dresses the stall 0.8 m off the
-- ring, next to the vendor. Move a shop by editing its `position`, then shift
-- `vendorPosition` and `prop.position` by the same amount.

RpShopsConfig = {
    -- Kabuki Market Centre: the freeroam spawn and the point the start log names.
    hub = { x = -1191.30, y = 2006.88, z = 7.82 },

    -- Reach of a vendor, in metres (planar). The E prompt is pressable within
    -- `promptDistance`; the server re-checks every request against `reach`, a
    -- little wider to tolerate a lagging position snapshot.
    reach = 3.5,
    promptDistance = 3.0,
    -- Reject a player position snapshot older than this (ms).
    positionMaxAgeMs = 5000,

    -- Society shops: share of every sale credited to the society (rp_bank).
    societyShare = 0.70,
    -- Restock cost per unit, as a share of the retail price, paid from the society.
    restockCostRatio = 0.5,

    -- Gun licence: one-off fee, paid cash then account, credited to the NCPD society.
    gunLicenceFee = 500,
    gunLicenceSociety = "ncpd",
    -- Jobs whose members buy guns without a licence (aliases accepted by rp_jobs).
    gunLicenceExemptJobs = { "ncpd" },

    -- Clothes shop: flat styling fee charged before the wardrobe opens.
    stylingFee = 200,

    -- Black market opening hours, server-world time (open77_weather), [open, close).
    -- 22 -> 6 means 22:00 to 05:59. Set both to 0 to never close.
    blackmarket = { openHour = 22, closeHour = 6 },

    -- Robbery (rp_crime calls exports.rp_shops:rob): loot range, cooldown per shop,
    -- how close the robber must stand, how long the vendor keeps their hands up.
    robLoot = { min = 200, max = 600 },
    robCooldownSeconds = 20 * 60,
    robDistance = 5.0,
    robHandsUpMs = 20000,
    -- A society shop loses the loot from its society account (as far as it goes).
    robTakesFromSociety = true,

    -- Maximum units per purchase (quantity dialog).
    maxCountPerPurchase = 20,

    -- Weapon delivery: refund if the client never confirms (ms).
    weaponFallbackMs = 15000,

    -- Staging (2026-09-18 pass): a purchase is a short hand-over the bystanders can see: the
    -- buyer reaches out with the bag while the vendor NPC plays the same clip. Same rules as
    -- rp_mecano / rp_nomade: `pose.profiles` are open77_animations profiles tried in order
    -- through Open77.animations.get (best FUTURE name first, then today's 18-profile eval
    -- catalogue); `loop = false` is a one-shot of `durationMs`. Props are curated aliases (see
    -- `prop.catalog`) tried in order (future alias first), attached to a rig slot
    -- ("RightHand"); hand-slot axes are not measured on 2.31, start from zero and move one
    -- axis at a time. `vendorWorkspot` is the profile the vendor NPC plays through
    -- Open77.npcs.tasks.workspot (false = the vendor stays still).
    Stage = {
        enabled = true,
        vendorWorkspot = "give",
        -- Goods bought at a stall: a bag / box in the right hand for a moment.
        purchase = {
            durationMs = 2500,
            pose = { profiles = { { profile = "carry_putdown" }, { profile = "give" } }, loop = false },
            prop = { models = { "shop.bag", "crate.cardboard" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- A weapon: the case handed over (the weapon itself arrives through the relay).
        weapon = {
            durationMs = 2500,
            pose = { profiles = { { profile = "carry_putdown" }, { profile = "give" } }, loop = false },
            prop = { models = { "military.case" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- The gun licence: filed on the holo.
        licence = {
            durationMs = 3000,
            pose = { profiles = { { profile = "phone" } }, loop = false },
        },
    },

    -- Vendor NPC defaults. `record` is a `Character.*` TweakDB id that must exist
    -- on every client; Character.Judy is the record the platform's own docs use
    -- for a shopkeeper. Per-shop `vendor.record` overrides it.
    vendor = {
        record = "Character.Judy",
        streamingRadius = 120,
        greeting = "greeting",     -- voContext name for Open77.npcs.speak
        robbed = "fear_beg",
    },
}

-- Shops. Fields:
--   id        ^[a-z0-9_]+$, unique; also the world POI id and the /acheter target
--   label     shown on the prompt, the menu title and /boutiques
--   kind      "items" (rp_inventory goods) | "weapons" | "clothes" | "blackmarket"
--   position  the ring + E prompt (x, y, z), a walked Kabuki Market spot
--   vendorPosition  where the vendor NPC stands (1.2 m behind the ring); yaw = facing
--   prop      one real stall prop spawned by the server (Open77.props.create, removed
--             on stop): `models` are depot meshes tried in order, first success wins
--   society   optional lower-case job name: 70 % of sales go to that society and
--             the shop keeps a finite stock in rp_shops_stock
--   catalogue list of { id, label, price[, slot][, record][, restockTo] }
--             items: `id` is an rp_inventory item id; weapons: `record` is the
--             TweakDB weapon and `slot` 1..3; clothes: a single service line.
--   restockTo default stock level per item for a society shop (restock fills to it)
--   welcome   the vendor's line in chat when the shop opens
--   closedLine (blackmarket) the line by day
--   zone      optional rp_zones zone the customer must stand in (the black market)
RpShopsConfig.shops = {
    {
        id = "supermarket",
        label = "Kabuki Market - Noodle Row",
        kind = "items",
        position = { x = -1178.66, y = 2028.45, z = 7.95 },       -- Noodle Row (walked)
        vendorPosition = { x = -1178.05, y = 2029.49, z = 7.95 },
        yaw = 149.6,
        prop = {
            models = {
                "market.shelf.chinese",
                "light.lantern.chinese",
            },
            position = { x = -1179.43, y = 2030.30, z = 7.95 }, yaw = 149.6,
        },
        vendor = { name = "Rosa" },
        welcome = "Rosa: Water, burritos, NiCola. Real food's extra, choom.",
        catalogue = {
            { id = "water",      label = "Bottle of water",    price = 10 },
            { id = "burrito",    label = "Burrito",            price = 25 },
            { id = "nicola",     label = "NiCola",             price = 15 },
            { id = "chooh2",     label = "CHOOH2 fuel can",    price = 60 },
            { id = "cigarettes", label = "Pack of cigarettes", price = 20 },
        },
    },
    {
        id = "pharmacy",
        label = "Med-Point - The Stalls",
        kind = "items",
        position = { x = -1223.91, y = 1989.45, z = 7.98 },       -- The Stalls (walked)
        vendorPosition = { x = -1224.97, y = 1988.88, z = 7.98 },
        yaw = 298.1,
        prop = {
            models = {
                "electronics.vending_machine.small",
                "electronics.vending_machine",
            },
            position = { x = -1224.22, y = 1987.47, z = 7.98 }, yaw = 298.1,
        },
        vendor = { name = "Dr. Osei" },
        welcome = "Dr. Osei: No Trauma Team card? Then you pay retail.",
        -- Player-run: Trauma Team owns it. 70 % of every sale lands on the
        -- `trauma` society, the shelves are finite (rp_shops_stock, opening
        -- stock = restockTo, free once) and the Trauma boss restocks them with
        -- /boutiques restock pharmacy, paid from the society.
        society = "trauma",
        restockTo = 10,
        catalogue = {
            { id = "bandage",    label = "Bandage",          price = 40 },
            { id = "maxdoc",     label = "MaxDoc Mk.1",      price = 120 },
            { id = "bounceback", label = "Bounce Back Mk.1", price = 90 },
        },
    },
    {
        id = "gunshop",
        label = "2nd Amendment - East Row",
        kind = "weapons",
        position = { x = -1160.50, y = 2019.06, z = 7.76 },       -- East Row (walked)
        vendorPosition = { x = -1159.38, y = 2019.50, z = 7.76 },
        yaw = 111.6,
        prop = {
            models = {
                "military.weapon_rack",
                "military.case",
            },
            position = { x = -1159.97, y = 2020.99, z = 7.76 }, yaw = 111.6,
        },
        vendor = { name = "Wilson" },
        welcome = "Wilson: Licence first, iron second. NCPD reads my ledger.",
        catalogue = {
            { id = "pistol", label = "M-10AF Lexington (pistol)", price = 400,  record = "Items.Preset_Lexington_Default",  slot = 1 },
            { id = "rifle",  label = "D5 Copperhead (rifle)",     price = 1200, record = "Items.Preset_Copperhead_Default", slot = 2 },
            { id = "katana", label = "Katana",                    price = 900,  record = "Items.Preset_Katana_Default",     slot = 3 },
        },
    },
    {
        id = "clothes",
        label = "Jinguji Threads - Vendor Lane",
        kind = "clothes",
        position = { x = -1212.26, y = 1978.53, z = 7.98 },       -- Vendor Lane (walked)
        vendorPosition = { x = -1212.97, y = 1977.57, z = 7.98 },
        yaw = 323.5,
        prop = {
            models = {
                "market.stand.small",
                "light.spotlight",
            },
            position = { x = -1211.68, y = 1976.62, z = 7.98 }, yaw = 323.5,
        },
        vendor = { name = "Kimiko" },
        welcome = "Kimiko: A styling session, then the racks are yours.",
        catalogue = {
            { id = "styling", label = "Styling session (opens the wardrobe)", price = 200 },
        },
    },
    {
        id = "blackmarket",
        label = "Lower Walkway Dealer",
        kind = "blackmarket",
        position = { x = -1201.07, y = 2035.60, z = 5.60 },       -- Lower Walkway, under the market (walked)
        vendorPosition = { x = -1201.46, y = 2036.74, z = 5.60 },
        yaw = 198.8,
        prop = {
            models = {
                "crate.cargo",
                "electronics.monitor.device",
            },
            position = { x = -1202.97, y = 2036.22, z = 5.60 }, yaw = 198.8,
        },
        vendor = { name = "Dex" },
        welcome = "Dex: Keep your voice down. Eddies first, questions never.",
        closedLine = "Dex: Not in daylight, choom. Come back after 22:00, when the NCPD drones go blind.",
        zone = "kabuki_market",      -- rp_zones: the dealer only trades under the market
        catalogue = {
            { id = "synthcoke", label = "Synthcoke",        price = 150 },
            { id = "lockpick",  label = "Lockpick",         price = 80 },
            { id = "qh_ping",   label = "Ping (quickhack)", price = 120 },
        },
    },
}
