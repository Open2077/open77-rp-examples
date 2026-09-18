-- rp_phone: values both runtimes read. Data only: no natives here.
-- Every position is in world metres; the freeroam spawn is -1191.30, 2006.88, 7.82 (Kabuki Market Centre, Watson).
RpPhoneConfig = {
    -- The pockets must hold this rp_inventory item to open the phone. With
    -- requireItem = false (or rp_inventory not running) the phone always opens.
    item = "phone",
    requireItem = true,

    -- Phone numbers: "555-" followed by the NCID citizen id zero-padded to 4 digits.
    numberPrefix = "555-",
    -- Without a database the resource hands out numbers from this range instead
    -- (kvp counter), so the phone still works on a dev box.
    fallbackFirstNumber = 9001,

    -- RP animation profiles (rp-animation-catalogue): played on the player by the
    -- server while the phone is open / while a call is active, looped until the phone
    -- closes or the call ends. Each entry is a list tried in order through
    -- Open77.animations.get -- the best FUTURE name first (`phonecheck`, `call` of the
    -- 76-profile catalogue), then what today's 18-profile eval catalogue has (`phone`, the
    -- only phone pose, which ships its own holo prop). Set an entry to nil to disable it.
    -- The platform cancels the pose when the player walks (> 0.5 m); it is replayed on the
    -- next state push, so the phone is back in the hand as soon as they stop.
    anim = {
        open = { "phonecheck", "phone" },   -- menu open: "Check phone" / "Use a phone" (tap phone)
        call = { "call", "phone" },         -- call active: "Phone call" / the same tap pose today
    },

    -- Calls
    call = {
        ringSeconds = 30,        -- unanswered after this: "no answer"
        voiceMode = "phone",     -- Open77.voice.createChannel mode
        -- Effect applied to the private call channel (voice guide, effect table).
        effect = {
            gain = 1.0,
            highPassHz = 300.0,
            lowPassHz = 3400.0,
            distortion = 0.03,
            radioNoise = 0.0,
            spatialBlend = 0.0,
            reverbWet = 0.0,
        },
        chatTag = "[CALL]",      -- text-mode tag (/tel <text> while in a call)
    },

    -- Messages
    sms = {
        maxLength = 200,         -- characters per message
        threadsInState = 20,     -- thread summaries pushed to the page
        messagesInState = 25,    -- messages of the open thread pushed to the page
        keepPerPlayer = 300,     -- rows loaded per player at login (newest first)
    },

    contacts = {
        max = 60,
        nearbyRadius = 8.0,      -- "add nearby player": players within this range
        nameMaxLength = 24,
    },

    -- Location sharing: the contact gets a temporary map pin on their client.
    location = {
        blipSeconds = 120,
        blipSprite = "objective",
    },

    -- Ads board
    ads = {
        price = 50,              -- eddies, cash first then bank account
        minutes = 60,            -- an ad expires after this
        maxLength = 140,
        maxListed = 30,
        maxPerPlayer = 3,        -- live ads per citizen
    },

    -- Services tab
    services = {
        ncpdAlertKind = "phone", -- rp_ncpd:alert kind for the NCPD contact
        traumaAlertKind = "911", -- rp_ncpd:alert kind for the Trauma contact
        mecanoJob = "mecano",    -- rp_jobs job paged by the Mechanic contact
        traumaJob = "trauma",    -- rp_jobs job paged by the Trauma contact
    },

    -- Server -> client state pushes are coalesced: at most one per player per window.
    pushThrottleMs = 250,
    -- Client -> server intents: more than this many per second are dropped.
    intentsPerSecond = 12,

    -- Chat colours (positional r, g, b as the chat UI wants them)
    color = {
        phone = { 0, 229, 255 },
        call = { 255, 200, 60 },
        service = { 255, 120, 0 },
        sms = { 170, 255, 170 },
    },
}
