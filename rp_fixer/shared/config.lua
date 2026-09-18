-- rp_fixer configuration. Shared by the server (rules, pay, NPCs) and the client
-- (office position, prompt copy). Nothing here is a secret.
--
-- Every position is a real Night City place (world metres, measured 2026-09-18 with
-- AMM / walked by a bot): the office is Rogue's meeting room at The Afterlife, the gig
-- points are Kabuki Market, Lizzie's Bar, the Megabuilding H10 floor and the Rancho
-- Coronado junkyard. Move them by editing this table only.

Config = {}

-- The shipped config lets anyone open the board. Set it to false and the board only
-- answers while a fixer is clocked in (rp_jobs `listOnDuty("fixer")`), or to the
-- on-duty fixer themselves.
Config.openBoardWithoutFixer = true

-- The fixer's office: Rogue's meeting room at the back of The Afterlife (inside the
-- `afterlife` zone of rp_zones, centre -1453, 1017, 16.5, radius 25). The board ring + E
-- prompt sit here; retrieval and extraction gigs end here. z = measured floor + 0.1.
Config.office = { x = -1436.8, y = 977.0, z = 17.0 }

-- Decoration spawned by the server at start (Open77.props.create, permission `world.props`)
-- and removed at stop: the board's data terminal at the booth, 1.3 m off the ring. Raw depot
-- `.mesh` paths from the props catalogue; a refused prop is logged, never fatal.
Config.props = {
    {
        model = "electronics.monitor.device",
        position = { x = -1435.6, y = 978.0, z = 16.9 },
        yaw = 83.0,             -- the meeting room's heading (AMM)
    },
}

-- How far from the office `/gigs` and the E prompt still open the board (metres, 3D).
-- 0 = anywhere.
Config.boardReach = 15.0

-- The E prompt on an objective is pressable within promptDistance (client side); the
-- server re-checks the player's distance to the point against interactReach.
Config.promptDistance = 3.0
Config.interactReach = 4.5

-- Escort / extraction: the gig succeeds when the NPC stands within this many metres
-- (planar) of the destination.
Config.arrivalDistance = 5.0

-- Gig points (name -> position). Walked points are used exactly; AMM points carry +0.1 m.
-- Guarded points (retrieval / extraction) must stand OUTSIDE the `kabuki_market` safe zone
-- (Market Centre, r 70): inside it the guards shoot without doing damage.
Config.points = {
    office           = Config.office,
    kabuki_market    = { x = -1191.30, y = 2006.88, z = 7.82 },   -- Kabuki Market Centre (walked)
    kabuki_noodle_row = { x = -1178.66, y = 2028.45, z = 7.95 },  -- Kabuki, Noodle Row (walked)
    lizzies          = { x = -1188.9, y = 1566.2, z = 23.0 },    -- Lizzie's Bar, inside (AMM)
    h10              = { x = -1391.9, y = 1271.7, z = 123.2 },   -- V's apartment floor, Megabuilding H10 (AMM)
    junkyard         = { x = 1374.9, y = -1674.9, z = 49.4 },    -- Rancho Coronado junkyard (AMM)
}

-- Reputation tiers, ascending. A template's `minTier` names one of them.
Config.tiers = {
    { name = "street",  min = 0 },
    { name = "known",   min = 3 },
    { name = "trusted", min = 6 },
}

-- Reputation delta per outcome. A disconnect ("dropped") costs nothing.
Config.reputation = {
    success   = 1,
    abandoned = -1,
    timeout   = -1,
    floor     = 0,     -- the score never goes below this
}

-- The fixer's cut of every gig's gross pay (0..1). The player receives the rest in cash.
Config.commissionRate = 0.15

-- The society (rp_bank) that receives the commission: the lower-case job name.
Config.society = "fixer"

-- Board behaviour.
Config.maxOpenGigs = 20            -- the UI kit context menu takes 64 options; keep it readable
Config.autoPublish = true          -- publish one instance of every `auto` template at start
Config.republishDelaySec = 60      -- ...and again this long after an instance ends
Config.warnBeforeDeadlineSec = 60  -- one chat warning when this much time is left

-- Items registered in rp_inventory through `exports.rp_inventory:define`.
Config.items = {
    gig_package   = { label = "Sealed package",  weight = 1.0,  usable = false, illegal = true },
    gig_datashard = { label = "Encrypted shard", weight = 0.05, usable = false, illegal = true },
}

-- Guards on retrieval / extraction gigs.
Config.guards = {
    -- The one Maelstrom gang record the devkit documents as a spawnable ranged hostile
    -- ("hostile_female_ranged_lab" resolves to it). Any Character.* record works here.
    record = "Character.cpz_maelstrom_grunt1_ranged1_lexington_wa",
    count = 2,
    health = 150,
    damagePolicy = 0,          -- numeric: 0 = mortal, they can be killed
    postRadius = 3.0,          -- metres from the gig point where the guards stand
    guardRadius = 8,           -- the leash of Open77.npcs.tasks.guard (2..100)
    engageDistance = 25.0,     -- the guards are ordered to attack the merc inside this distance
    group = "rp_fixer_guards", -- relationship group: the two guards are allies
}

-- Escorted NPCs and extraction targets.
Config.escort = {
    -- Legacy alias "civilian_female_relaxed_01" = Character.Panam: the devkit's documented
    -- non-hostile human with locomotion; natively invulnerable, which matches damagePolicy 2.
    template = "civilian_female_relaxed_01",
    damagePolicy = 2,          -- numeric: 2 = invulnerable
    followDistance = 2.5,
    followSpeed = "run",
}

-- Gig templates. `kind` is delivery | retrieval | escort | extraction.
--   delivery   : pick `item` up at `from` (E), bring it to `to` (E)
--   retrieval  : take `item` at `at` (E, guarded), bring it back to the office (E)
--   escort     : meet `npcName` at `from` (E), walk them to `to` (arrival = NPC within 5 m)
--   extraction : reach `npcName` at `at` (E, guarded), bring them to the office (arrival)
-- `pay` is the gross pay: the player gets pay minus the fixer's cut. `timeLimitSec` starts
-- on accept. `minTier` is a name from Config.tiers. `auto` templates are published by the
-- board itself; the others only through `/fixer publier <template>` or the postGig export.
Config.templates = {
    delivery_meds = {
        kind = "delivery", title = "Meds run",
        description = "A crate of MaxDoc fell off a Noodle Row delivery at Kabuki Market. Take it to the Rancho Coronado junkyard before Trauma Team notices.",
        from = "kabuki_noodle_row", to = "junkyard", item = "gig_package",
        pay = 600, timeLimitSec = 1200, minTier = "street", auto = true,
    },
    escort_witness = {
        kind = "escort", title = "Witness walk",
        description = "A Mox saw something at Lizzie's she should not have. Walk her up to Kabuki Market, quietly.",
        from = "lizzies", to = "kabuki_market", npcName = "Kess",
        pay = 800, timeLimitSec = 900, minTier = "street", auto = true,
    },
    retrieval_shard = {
        kind = "retrieval", title = "Junkyard shard",
        description = "Two Maelstrom goons are sitting on an encrypted shard at the Rancho Coronado junkyard. Bring it back to the Afterlife. How you get it is your business.",
        at = "junkyard", item = "gig_datashard",
        pay = 1000, timeLimitSec = 1500, minTier = "street", auto = true,
    },
    extraction_techie = {
        kind = "extraction", title = "Techie extraction",
        description = "Maelstrom walked into Lizzie's with a techie who owes them. Get him out and bring him to the Afterlife.",
        at = "lizzies", npcName = "Rho the techie",
        pay = 1500, timeLimitSec = 1200, minTier = "street", auto = true,
    },
    delivery_hot = {
        kind = "delivery", title = "Hot package",
        description = "Something walked out of an apartment on V's floor of Megabuilding H10. It needs to be at Lizzie's in ten minutes, no questions.",
        from = "h10", to = "lizzies", item = "gig_package",
        pay = 1200, timeLimitSec = 600, minTier = "known", auto = true,
    },
    extraction_vip = {
        kind = "extraction", title = "VIP extraction",
        description = "A corpo defector is stashed at the Rancho Coronado junkyard with a Maelstrom escort that was paid twice. Bring her to the Afterlife alive.",
        at = "junkyard", npcName = "the defector",
        pay = 3000, timeLimitSec = 1800, minTier = "trusted", auto = true,
    },
}

-- Staging (2026-09-18 pass): a pickup and a hand-over play a pose, show the package and take
-- their time behind a UI-kit bar, so the contact sees the merc work. Same rules as rp_mecano /
-- rp_nomade: `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first, then what today's 18-profile eval catalogue
-- has); `loop = true` is held for the bar and stopped by the server, `loop = false` is a
-- one-shot of `durationMs`. Props are curated aliases (see `prop.catalog`) tried in order
-- (future alias first), attached to a rig slot ("RightHand"); hand-slot axes are not measured
-- on 2.31, start from zero and move one axis at a time. A workspot is cancelled when the
-- player moves > 0.5 m; the bar keeps them still (client side, never a server freeze).
Config.Stage = {
    enabled = true,
    color = "#22D8E2",
    -- E at the pickup point: the case picked up (delivery) or taken (retrieval).
    pickup = {
        durationMs = 3000,
        label = "Picking up the package",
        pose = { profiles = { { profile = "carry_pickup" }, { profile = "give" } }, loop = true },
        prop = { models = { "fixer.case", "military.case" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- E at the drop point / the office: the case handed over.
    handover = {
        durationMs = 3000,
        label = "Handing over the package",
        pose = { profiles = { { profile = "carry_putdown" }, { profile = "give" } }, loop = true },
        prop = { models = { "fixer.case", "military.case" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- E on the board: the merc checks the gig on the holo (one-shot, no bar).
    board = {
        durationMs = 2500,
        pose = { profiles = { { profile = "phonecheck" }, { profile = "phone" } }, loop = false },
    },
}

-- Copy used by both sides.
Config.text = {
    boardLabel = "Fixer's board",
    boardDescription = "Rogue's booth at the Afterlife. Gigs, eddies, reputation. Press E.",
    officeBlip = "The Afterlife - fixer's booth",
}
