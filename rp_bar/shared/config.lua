-- rp_bar: the Afterlife bar counter -- configuration shared by the server and the client.
-- Every position, price, recipe and threshold lives here so the owner can move the bar,
-- change the card or tune the buzz without touching the scripts.
RpBarConfig = {}

-- The job that may work the counter (rp_jobs v2) and its society in rp_bank: the till.
RpBarConfig.job = "barman"
RpBarConfig.society = "barman"

-- The bar counter: the end of the real bar counter inside The Afterlife (Little China,
-- Watson) -- a bot stood on this exact spot on 2026-09-18, so `z` is the walked floor
-- height. The point lies inside the `afterlife` zone of rp_zones (centre -1453, 1017,
-- 16.5, radius 25). The Afterlife is about 1 km south of the Kabuki Market spawn.
-- The config knows ONE counter: Lizzie's Bar (-1188.9, 1566.2, 22.9) would need a second
-- counter table, a second ambience sweep and a second POI, so the Afterlife is the bar.
RpBarConfig.counter = {
    position = { x = -1451.5, y = 1012.5, z = 17.8 },
    label = "The Afterlife - bar counter",
    description = "Recipes, restock and the till. Barman on duty only.",
    promptDistance = 4.0,   -- the E prompt is pressable within this distance (metres)
    radius = 3.5,           -- ground ring radius: the counter's end, not a single spot
    maxDistance = 60.0,     -- ring visibility
    -- The server re-checks the distance before opening the counter menu (E prompt and /bar).
    -- 0 = the barman may open the counter menu from anywhere.
    reach = 8.0,
}

-- The map/ring/prompt of the counter is shown to the on-duty barman only.
-- Customers use /bar for the card.
RpBarConfig.showCounterToCustomers = false

-- Decoration spawned by the server at start (Open77.props.create, permission `world.props`)
-- and removed at stop. The bar itself exists: no counter prop, only a small neon frame on
-- the wall behind the counter's end, 1.4 m off the ring so the ring stays readable. Raw
-- depot `.mesh` paths from the props catalogue. A refused prop is logged, never fatal.
-- Empty the table for no decoration.
RpBarConfig.props = {
    {
        model = "electronics.jukebox",
        position = { x = -1450.3, y = 1013.5, z = 18.9 },
        yaw = -138.5,           -- the bar's own heading (AMM)
    },
}

-- Drinks: the items this resource defines through rp_inventory:define (label, weight,
-- usable, illegal, effect) plus the fields only rp_bar reads: `price` (what a customer
-- pays, in eddies), `alcohol` (0..3, added to the drinker's buzz per glass) and
-- `recipe` (ingredient id -> units taken from the barman's pockets).
-- `effect.needs` is applied by rp_inventory through rp_needs:apply on /use; `effect.text`
-- is the line the drinker reads. Ids must match ^[a-z0-9_]+$.
RpBarConfig.drinks = {
    beer = {
        label = "Beer", weight = 0.5, usable = true, illegal = false,
        effect = { needs = { thirst = 25 }, text = "Cold and bitter. Good." },
        price = 30, alcohol = 1,
        recipe = { ingredient_mixer = 1 },
        flavour = "A Broseph from the tap. Cold, cheap, honest.",
    },
    whisky = {
        label = "Whisky", weight = 0.4, usable = true, illegal = false,
        effect = { needs = { thirst = 10 }, text = "Smoky. It burns all the way down." },
        price = 60, alcohol = 2,
        recipe = { ingredient_spirits = 1, ingredient_ice = 1 },
        flavour = "Centzon on the rocks. The bottle has seen better decades.",
    },
    johnny_silverhand = {
        label = "Johnny Silverhand", weight = 0.4, usable = true, illegal = false,
        effect = { needs = { thirst = 15 }, text = "Tequila, beer, lime and a shot of bad decisions." },
        price = 120, alcohol = 3,
        recipe = { ingredient_spirits = 1, ingredient_mixer = 1, ingredient_ice = 1 },
        flavour = "The house cocktail. Wake up, samurai.",
    },
    synth_soda = {
        label = "Synth soda", weight = 0.4, usable = true, illegal = false,
        effect = { needs = { thirst = 30 }, text = "Sweet, fizzy, zero eddies of regret." },
        price = 20, alcohol = 0,
        recipe = { ingredient_ice = 1 },
        flavour = "NiCola's poor cousin. No buzz, no hangover.",
    },
}

-- The order the card, the recipes menu and the serve menu list the drinks in.
RpBarConfig.drinkOrder = { "beer", "synth_soda", "whisky", "johnny_silverhand" }

-- Ingredients: also defined through rp_inventory:define. `cost` is what the till pays
-- per unit at Restock (rp_bank:societyRemove on the barman society).
RpBarConfig.ingredients = {
    ingredient_spirits = { label = "Spirits (bottle)", weight = 1.0, usable = false, illegal = false, cost = 40 },
    ingredient_mixer   = { label = "Mixer (keg)",      weight = 1.0, usable = false, illegal = false, cost = 15 },
    ingredient_ice     = { label = "Ice (bag)",        weight = 0.5, usable = false, illegal = false, cost = 10 },
}
RpBarConfig.ingredientOrder = { "ingredient_spirits", "ingredient_mixer", "ingredient_ice" }

-- Mixing a drink: a UI-kit progress bar, staged with the pose and the bottle in the hand
-- of RpBarConfig.Stage.mix below.
RpBarConfig.craft = {
    durationMs = 4000,
}

-- Staging (2026-09-18 pass): every action behind the counter plays a pose, shows a prop and
-- takes its time behind a UI-kit bar, so the customers see the bartender work. Same rules as
-- rp_mecano / rp_nomade: `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first, then what today's 18-profile eval catalogue
-- has); `loop = true` is held for the bar and stopped by the server, `loop = false` is a
-- one-shot of `durationMs`. Props are curated aliases (see `prop.catalog`) tried in order,
-- attached to a rig slot ("RightHand", "LeftHand") or to the body root (`bone = ""`); hand-slot
-- axes are not measured on 2.31, start from zero and move one axis at a time. The `drink`
-- profile ships its own can, so the customer's sip needs no extra prop.
RpBarConfig.Stage = {
    enabled = true,
    color = "#FF4FA3",
    -- Mixing: the bottle in the right hand for the whole bar (`give` = the arm held out).
    mix = {
        durationMs = 4000,
        label = "Mixing",
        pose = { profiles = { { profile = "rubhands" }, { profile = "give" } }, loop = true },
        prop = { models = { "food.bottle", "food.bourbon" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- Restock from the till: a keg lifted onto the counter (one-shot, no bar).
    restock = {
        durationMs = 2500,
        pose = { profiles = { { profile = "carry" }, { profile = "give" } }, loop = false },
        prop = { models = { "container.keg" }, bone = "", offset = { x = 0.0, y = 0.45, z = 0.85 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- Serving: the platform's `give` interaction animates both players; this entry only puts
    -- the bottle in the bartender's hand from the offer to the hand-over (no pose of its own,
    -- a second pose would answer animation_busy to the interaction).
    serve = {
        prop = { models = { "food.bottle", "food.bourbon" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- The customer drinks what they were served (one-shot, the profile's own can).
    sip = {
        durationMs = 4000,
        pose = { profiles = { { profile = "bottle_walk" }, { profile = "bottle" }, { profile = "drink" } }, loop = false },
    },
}

-- Selling: the customer pays `price` in cash; `tillShare` of it goes to the barman
-- society (the till), the rest is the barman's tip, in cash.
RpBarConfig.sale = {
    tillShare = 0.70,
    distance = 3.0,         -- barman <-> customer, checked by the server (metres)
    inviteTimeoutMs = 20000, -- how long the customer has to accept the offer
    durationMs = 4000,      -- the synchronized `give` interaction
    breakDistance = 5.0,    -- walking away further than this cancels the hand-over
}

-- Drinking: the buzz. 0..10 per player, +`alcohol` per glass, -1 every `tickMs`.
RpBarConfig.drunk = {
    max = 10,
    tickMs = 60000,          -- one point sobers up every minute
    screenAbove = 3,         -- above this level the screen wobbles (Open77.effects.screen "drunk")
    stumbleAbove = 7,        -- above this level the player stumbles (Open77.players.ragdoll)
    stumbleDurationMs = 2000,
    -- the wobble tier per level: strength 0..1 picks among the authored drunk.light /
    -- drunk.medium / drunk.heavy overlays
    tiers = {
        { above = 7, strength = 1.0 },
        { above = 5, strength = 0.5 },
        { above = 3, strength = 0.2 },
    },
    -- Profile candidates after /use; a single string still works, false disables.
    -- The selected profile supplies its native hand item; no extra wrist mesh.
    profile = { "bottle_walk", "bottle", "drink" },
    profileDurationMs = 4000,
    labels = {
        { above = 7, text = "wasted" },
        { above = 3, text = "drunk" },
        { above = 0, text = "buzzed" },
        { above = -1, text = "sober" },
    },
}

-- Ambience: a looping, synthesized club bed (sfx/afterlife_ambience.wav, generated by
-- tools/make-ambience.mjs -- royalty free, no sample inside) played at the counter for
-- every player within `radius` metres, through Open77.sound.play(playerId, ...).
-- The server sweeps positions every `sweepMs`. `file = false` disables it.
RpBarConfig.ambience = {
    file = "sfx/afterlife_ambience.wav",
    id = "afterlife_ambience",
    radius = 30.0,          -- start playing within this distance of the counter
    stopRadius = 34.0,      -- stop beyond this distance (hysteresis)
    maxDistance = 32.0,     -- silent at and beyond this distance (linear falloff)
    refDistance = 4.0,      -- full volume within this distance
    volume = 0.5,
    sweepMs = 5000,
}

-- Where the sales ledger goes: SQL (`rp_bar_sales`) when the database answers, the
-- resource KVP store otherwise. `dbWaitMs` is how long a connecting database may take
-- before the resource gives up on it for this boot.
RpBarConfig.persistence = {
    dbWaitMs = 15000,
}
