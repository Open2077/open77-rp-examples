-- rp_gangs configuration. Shared by both runtimes: keep it free of secrets and of
-- anything the client must not know. Every position is in world metres.
RpGangsConfig = {}
local Config = RpGangsConfig

-- The seven gangs. `id` is what the commands, the SQL rows and the exports use;
-- `label` is what players read; `color` is the nameplate / chat colour; `home` is
-- the territory the gang is associated with (informative, and the fallback zone
-- for an influence loss when the member's last territory is unknown).
Config.gangs = {
    maelstrom   = { label = "Maelstrom",   color = "#D7263D", rgb = { 215, 38, 61 },   home = "junkyard" },
    tygerclaws  = { label = "Tyger Claws", color = "#FF3CAC", rgb = { 255, 60, 172 },  home = "kabuki_market" },
    valentinos  = { label = "Valentinos",  color = "#F2C14E", rgb = { 242, 193, 78 },  home = "afterlife" },
    sixthstreet = { label = "6th Street",  color = "#2E86DE", rgb = { 46, 134, 222 },  home = "afterlife" },
    animals     = { label = "Animals",     color = "#8E44AD", rgb = { 142, 68, 173 },  home = "lizzies" },
    voodooboys  = { label = "Voodoo Boys", color = "#27AE60", rgb = { 39, 174, 96 },   home = "lizzies" },
    scavs       = { label = "Scavs",       color = "#7F8C8D", rgb = { 127, 140, 141 }, home = "junkyard" },
}

-- Display order of the gangs in lists.
Config.gangOrder = { "maelstrom", "tygerclaws", "valentinos", "sixthstreet", "animals", "voodooboys", "scavs" }

-- Ranks 0..2.
Config.ranks = { [0] = "member", [1] = "lieutenant", [2] = "boss" }

-- Territories = rp_zones zone names (real Night City places, measured 2026-09-18). `label`
-- mirrors rp_zones; `position` is the zone centre (used for NCPD alerts); `buyer` is where
-- the street buyer NPC stands (inside the zone, off the centre so it does not overlap the
-- other resources' NPCs / POIs) - a territory without `buyer` has no street market (the
-- Afterlife: deals happen elsewhere, the zone is only fought over). `buyer.prop` is the
-- crate the server drops beside the buyer (Open77.props.create, removed on stop; a refusal
-- only logs). No default holder: every territory starts unheld. If a buyer lands in the
-- ground, stand on the spot, /pos, and paste the height.
Config.territories = {
    { name = "kabuki_market", label = "Kabuki Market",  position = { x = -1191.30, y = 2006.88, z = 7.82 },
      buyer = { x = -1149.22, y = 2054.84, z = 7.76, yaw = 225.0,                 -- Far Corner (walked)
                prop = { x = -1148.10, y = 2055.60, z = 7.76, yaw = 20.0 } } },
    { name = "lizzies",       label = "Lizzie's Bar",   position = { x = -1188.90, y = 1566.20, z = 22.90 },
      buyer = { x = -1185.00, y = 1568.00, z = 23.00, yaw = 200.0,                -- inside, off the floor centre
                prop = { x = -1183.90, y = 1568.80, z = 22.90, yaw = 0.0 } } },
    { name = "junkyard",      label = "Junkyard",       position = { x = 1374.90, y = -1674.90, z = 49.30 },
      buyer = { x = 1370.00, y = -1670.00, z = 49.40, yaw = 135.0,
                prop = { x = 1368.90, y = -1669.20, z = 49.30, yaw = 40.0 } } },
    { name = "afterlife",     label = "The Afterlife",  position = { x = -1453.00, y = 1017.00, z = 16.50 } },
}

-- The crate dropped beside every buyer (raw depot mesh of the props catalogue); false = none.
Config.buyerProp = {
    model = "crate.cargo",
}

-- Founding: with `openFounding` the first member of a gang founds it and becomes its
-- boss (`/gang creer`), no admin needed. Set it to false on a server where an admin
-- hands out the boss seats with /setgang.
Config.openFounding = true

-- When a member takes a job (rp_jobs:changed with a job name) they are cut loose from
-- the gang: membership requires being jobless, on both sides of the door.
Config.dropOnJob = true

-- Nameplate tag `[GANG] Name` over a member's body, drawn by every other client.
Config.showTag = true
Config.tagMaxDistance = 40.0

-- Recruiting / firing: the target must stand within this many metres.
Config.recruitReach = 5.0

-- Influence points.
Config.dealInfluence = 1       -- per drug pack sold in the zone (/gang vendre, the buyer prompt, rp_crime)
Config.gigInfluence = 2        -- per rp_fixer gig completed by a member
Config.arrestInfluence = -5    -- per rp_ncpd:arrest of a member (never below 0)

-- Tribute: every online member of the gang holding a zone is paid this much per held
-- zone, every interval.
Config.tributePerZone = 50
Config.tributeIntervalMs = 600000

-- Street deals: the buyer NPC per territory.
Config.buyer = {
    -- nativePrompt: the E prompt on the NPC goes through open77_interactions (a 250 ms world
    -- query on the client). Kept switchable: it was turned off on 2026-09-18 to isolate the
    -- Northside flat crash, which reproduced without it (platform loot bug, not this).
    nativePrompt = false,
    record = "Character.cpz_maelstrom_grunt1_ranged1_lexington_wa", -- proven on 2.31; passive + silent below
    damagePolicy = 2,          -- numeric: 2 = invulnerable
    reach = 4.0,               -- server-measured distance to the buyer for a deal
    promptDistance = 2.5,      -- E prompt activation radius (open77_interactions)
    markerDistance = 15.0,     -- how far the marker is drawn
}
Config.dealItem = "drug_pack"
Config.dealPrice = 80          -- cash per pack
Config.dealCooldownMs = 60000  -- per seller

-- Items this resource declares in rp_inventory (rp_inventory `define` shape).
Config.items = {
    drug_pack = { label = "Drug pack", weight = 0.2, usable = false, illegal = true },
}

-- Robbery of a held player (cuffed by the RP kit, or hands up).
Config.robShare = 0.30         -- share of the victim's cash taken
Config.robReach = 3.0
Config.robCooldownMs = 120000  -- per victim: the same choom is not robbed twice in two minutes

-- War.
Config.warMinutes = 5          -- eval; 20 on production
Config.warTickMs = 30000       -- every tick the gang with more members inside the zone scores 1
Config.warInfluence = 10       -- what the winner gets
Config.warCooldownMs = 600000  -- per zone, after a war ends

-- Racket: a chat threat plus an NCPD alert (see README: the society-payment version is
-- deliberately not implemented).
Config.racketAmount = 100
Config.racketReach = 5.0
Config.racketCooldownMs = 60000

-- Where the wars, deals and robberies are reported: rp_ncpd:alert kinds.
Config.alertKinds = { robbery = "robbery", war = "gang_war", racket = "racket" }

-- Chat author and colour of this resource's lines.
Config.chatAuthor = "GANG"
Config.chatColor = { 255, 128, 48 }

-- Staging (2026-09-18 pass): a street deal and a robbery play a pose, show the goods and take
-- their time behind a UI-kit bar, so the block sees it. Same rules as rp_mecano / rp_nomade:
-- `pose.profiles` are open77_animations profiles tried in order through Open77.animations.get
-- (best FUTURE name first, then what today's 18-profile eval catalogue has); `loop = true` is
-- held for the bar and stopped by the server. Props are curated aliases (see `prop.catalog`)
-- tried in order (future alias first), attached to a rig slot ("RightHand"); hand-slot axes
-- are not measured on 2.31, start from zero and move one axis at a time. A workspot is
-- cancelled when the player moves > 0.5 m; the bar keeps them still (client side).
Config.Stage = {
    enabled = true,
    color = "#FF8030",
    -- Selling to the buyer NPC: the pack held out for the bar's length, then the eddies.
    deal = {
        durationMs = 3000,
        label = "Making the deal",
        pose = { profiles = { { profile = "carry_putdown" }, { profile = "give" } }, loop = true },
        prop = { models = { "crime.drug_pack", "crate.ammo_box" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- Robbing a held player: the robber goes through the pockets (future `frisk`).
    rob = {
        durationMs = 4000,
        label = "Turning the pockets out",
        pose = { profiles = { { profile = "frisk" }, { profile = "examine" } }, loop = true },
    },
}
