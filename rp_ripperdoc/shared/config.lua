-- rp_ripperdoc configuration. Shared: the client reads the chair, the server
-- reads everything. Prices in eddies, durations in milliseconds.
RpRipperConfig = {
    -- rp_jobs job allowed to operate, and the rp_bank society every fee goes to
    -- (100 % of the fee; the ripper is paid by the rp_jobs payroll).
    job = "ripper",
    society = "ripper",

    -- rp_zones zone the ripper must stand in to operate; nil = anywhere.
    -- The clinic is Viktor Vektor's, under the Misty's Esoterica alley in Little China
    -- (Watson), the `viktor_clinic` zone of rp_zones (centre -1548, 1230, 11.5, r 12).
    clinicZone = "viktor_clinic",

    -- The ripperdoc chair: Vik's own chair room (AMM point, bot verified inside on
    -- 2026-09-18; z = measured floor + 0.1). The clinic HAS a chair: no chair prop is
    -- spawned. The ring covers the chair (r 4) so the prompt reads from either side.
    -- If the ring is not visible, stand on the spot, run /pos, and paste the floor height.
    chair = {
        position = { x = -1548.0, y = 1230.0, z = 11.6 },
        yaw = -89.5,                -- degrees about Z, where the lying body faces (AMM)
        promptDistance = 4.0,       -- the E prompt is pressable within this range
        reach = 4.5,                -- server re-check of the prompt distance (m)
        radius = 4.0,               -- ground ring radius (m): the whole chair
        label = "Vik's chair",
        description = "Viktor's clinic. Lie down and let the ripper work.",
    },

    -- The ripper must be within this distance of the patient on the chair (m).
    operateDistance = 4.0,

    -- How long the patient has to accept or decline the quote.
    quoteTimeoutMs = 30000,

    -- A removal costs this share of the install price of the installed grade.
    removalPriceFactor = 0.5,

    -- /ripper restock: wholesale share of the retail price, paid by the society.
    restockPriceFactor = 0.6,
    restockMaxCount = 5,

    -- Cyberpsychosis: a patient carrying MORE implants than this after an install
    -- gets the light overlay below and a warning. Lower it to 0 to see the effect
    -- on the very first implant.
    cyberpsychosisThreshold = 4,
    cyberpsychosis = {
        effect = "drugged",         -- Open77.effects.screen alias (see the effects guide)
        strength = 0.5,             -- picks the authored tier: 0.5 = drugged.medium
        durationSeconds = 60,
    },

    -- RP animation profiles (rp-animation-catalogue): the chair posture on the
    -- patient, and the two profiles the quote interaction plays during surgery
    -- (Open77.playerInteractions actorAnimation / targetAnimation: the patient lies,
    -- the ripper kneels over them for the whole operation).
    animations = {
        chair = "lie",
        surgeryPatient = "lie",
        surgeryRipper = "examine",
    },

    -- Staging (2026-09-18 pass): the surgery already animates both players through the
    -- interaction above; what was missing is the tool. Same rules as rp_mecano / rp_nomade:
    -- props are curated aliases (see `prop.catalog`) tried in order (future alias first),
    -- attached to a rig slot ("RightHand") or to the body root (`bone = ""`); hand-slot axes
    -- are not measured on 2.31, start from zero and move one axis at a time. `pose.profiles`
    -- are open77_animations profiles tried in order (future name first, then today's
    -- 18-profile catalogue); `loop = false` is a one-shot of `durationMs`.
    Stage = {
        enabled = true,
        color = "#B57BFF",
        -- The injector / surgical device in the ripper's right hand from the first cut to
        -- the last stitch (prop only: the interaction owns the pose).
        surgery = {
            prop = { models = { "medical.injector", "medical.device" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        },
        -- /ripper restock: the order typed on the holo (one-shot, no bar).
        restock = {
            durationMs = 3000,
            pose = { profiles = { { profile = "phone" } }, loop = false },
        },
    },

    -- The catalogue. One entry per implant slot the platform knows on this build:
    -- arms/gorilla_arms, legs/double_jump, operating_system/cyberdeck,
    -- self_ice/self_ice, purge/active_purge (cyberware guide). Each entry sells one
    -- boxed item (`box`, defined in rp_inventory), and each grade carries its RP
    -- fields (label, price, durationMs) next to the platform grade fields that
    -- Open77.cyberware.define wants. Hacking entries also carry `hacking`, the
    -- Open77.hacking.define* grade of the same id.
    catalogue = {
        {
            key = "arms", label = "Gorilla Arms",
            slot = "arms", profile = "gorilla_arms",
            definitionId = "rp_ripperdoc.gorilla_arms", version = 1,
            box = "implant_box_arms",
            grades = {
                { id = "street", label = "Street", price = 1500, durationMs = 15000,
                  normalDamage = 15, chargedDamage = 35, knockbackMeters = 2, normalKnockbackMeters = 0.5,
                  cooldownMs = 800, chargeMs = 650, maxChargeMs = 10000,
                  normalStaminaCost = 20, chargedStaminaCost = 35, nonlethal = true, cosmetic = false },
                { id = "industrial", label = "Industrial", price = 3200, durationMs = 22000,
                  normalDamage = 30, chargedDamage = 70, knockbackMeters = 4, normalKnockbackMeters = 1.0,
                  cooldownMs = 650, chargeMs = 650, maxChargeMs = 10000,
                  normalStaminaCost = 20, chargedStaminaCost = 40, nonlethal = false, cosmetic = false },
            },
        },
        {
            key = "legs", label = "Reinforced Tendons (double jump)",
            slot = "legs", profile = "double_jump",
            definitionId = "rp_ripperdoc.double_jump", version = 1,
            box = "implant_box_legs",
            grades = {
                { id = "training", label = "Training", price = 1200, durationMs = 12000,
                  normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 800, chargeMs = 650,
                  jumpStaminaCost = 15, maxAirborneMs = 10000, maxFallSpeed = 30 },
                { id = "athlete", label = "Athlete", price = 2500, durationMs = 18000,
                  normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 400, chargeMs = 650,
                  jumpStaminaCost = 8, maxAirborneMs = 10000, maxFallSpeed = 30 },
            },
        },
        {
            key = "deck", label = "Cyberdeck (Short Circuit)",
            slot = "operating_system", profile = "cyberdeck",
            definitionId = "rp_ripperdoc.cyberdeck", version = 1,
            box = "implant_box_deck", hacking = "hack",
            grades = {
                { id = "street", label = "Street", price = 2000, durationMs = 20000,
                  normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
                  hacking = { range = 20, uploadMs = 2000, staminaCost = 20, cooldownMs = 5000,
                              damage = 25, statusMs = 750, recoveryMs = 4000, nonlethal = true } },
            },
        },
        {
            key = "ice", label = "Self-ICE",
            slot = "self_ice", profile = "self_ice",
            definitionId = "rp_ripperdoc.self_ice", version = 1,
            box = "implant_box_ice", hacking = "ice",
            grades = {
                { id = "street", label = "Street", price = 1800, durationMs = 14000,
                  normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
                  hacking = { charges = 1, rechargeMs = 15000 } },
            },
        },
        {
            key = "purge", label = "Active Purge",
            slot = "purge", profile = "active_purge",
            definitionId = "rp_ripperdoc.purge", version = 1,
            box = "implant_box_purge", hacking = "purge",
            grades = {
                { id = "street", label = "Street", price = 1600, durationMs = 14000,
                  normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
                  hacking = { staminaCost = 15, cooldownMs = 8000, allowSelf = true, allowAlly = true,
                              range = 10, cancelUploads = true, removeStatuses = true } },
            },
        },
    },

    -- Boxed implants sold by the clinic, registered in rp_inventory through
    -- exports.rp_inventory:define. Illegal unless the holder has the `ripper` job
    -- (`permit`). One box is consumed per install; a removal returns nothing.
    items = {
        implant_box_arms  = { label = "Implant box: Gorilla Arms",      weight = 2.0, usable = false, illegal = true, permit = "ripper" },
        implant_box_legs  = { label = "Implant box: Reinforced Tendons", weight = 2.0, usable = false, illegal = true, permit = "ripper" },
        implant_box_deck  = { label = "Implant box: Cyberdeck",          weight = 2.0, usable = false, illegal = true, permit = "ripper" },
        implant_box_ice   = { label = "Implant box: Self-ICE",           weight = 2.0, usable = false, illegal = true, permit = "ripper" },
        implant_box_purge = { label = "Implant box: Active Purge",       weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    },
}
