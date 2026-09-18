-- rp_needs: hunger, thirst and fatigue for a Night City RP server.
--
-- Server-authoritative. Three values 0..100 per player (100 = fine), persisted
-- in SQL (table rp_needs_state, keyed by the durable identifier) and saved every
-- 60 s and on disconnect. The KVP store is used only while the database is not
-- ready, and says so in the log.
--
-- Effects: hunger or thirst below 20 halves the stamina pool; at 0 the player
-- loses 1 hp every 10 s down to 10 hp (never killing). Fatigue below 20 puts
-- the native "exhausted" screen overlay on the player's own view. Fatigue
-- recovers while the player sits still in a vehicle.
--
-- Exports (synchronous, never yield): get(playerId), consume(playerId, itemId).
-- Event: rp_needs:changed (playerId, hunger, thirst, fatigue).

local RESOURCE = GetCurrentResourceName()
local LOG_PREFIX = "[rp_needs]"

-- Tuning ---------------------------------------------------------------------

local TICK_MS = 10000                 -- decay + effects tick
local SAVE_INTERVAL_S = 60            -- periodic persistence
local CHANGED_INTERVAL_S = 60         -- rp_needs:changed at most once per minute per player
local STARVE_INTERVAL_S = 10          -- 1 hp lost every 10 s at 0 hunger or thirst
local STARVE_HP_FLOOR = 10            -- never below this, so never lethal
local LOW_THRESHOLD = 20              -- effects start below this value
local STAMINA_PENALTY_FACTOR = 0.5    -- stamina maximum while hungry or thirsty
local IDLE_SPEED = 0.5                -- m/s; slower than this in a seat counts as resting
local SCHEMA_WAIT_STEPS = 10          -- x 500 ms: how long a load waits for CREATE TABLE at boot

local DECAY_PER_MIN = { hunger = 0.8, thirst = 1.2, fatigue = 0.4 }
local FATIGUE_RECOVERY_PER_MIN = 2.0
local WARN_THRESHOLDS = { 30, 10 }
local NEEDS = { "hunger", "thirst", "fatigue" }

-- What rp_inventory hands to consume() on /use. Deltas are added to the need.
-- `after` is a delayed second effect (the synthcoke crash).
-- `stage` names the NEEDS_STAGE gesture played on the body when the item is consumed.
local CONSUMABLES = {
    water      = { label = "Water",      thirst = 30, stage = "drink" },
    nicola     = { label = "Nicola",     thirst = 20, fatigue = 5, stage = "drink" },
    burrito    = { label = "Burrito",    hunger = 35, stage = "eat" },
    cigarettes = { label = "Cigarettes", fatigue = 5, hunger = -2, stage = "smoke" },
    synthcoke  = { label = "Synthcoke",  fatigue = 40, stage = "snort",
                   after = { delayMs = 300000, fatigue = -20 } },
}

-- Staging (2026-09-18 pass): eating and drinking are one-shot gestures everybody sees, played
-- once rp_inventory's "Using ..." bar is through. Same rules as rp_mecano / rp_nomade (this
-- resource has no shared config, so the table lives here): `pose.profiles` are
-- open77_animations profiles tried in order through Open77.animations.get (best FUTURE name
-- first -- `bottle`, `takeout` of the 76-profile catalogue, which ship their own bottle / box --
-- then today's 18-profile eval catalogue); `loop = false` is a one-shot of `durationMs`.
-- `drink` and `smoke` ship their own can / cigarette, so only the food needs a prop today:
-- a curated alias attached to the right hand (hand-slot axes are not measured on 2.31, start
-- from zero and move one axis at a time). Once `takeout` exists, drop the `eat.prop` line.
local NEEDS_STAGE = {
    enabled = true,
    drink = {
        durationMs = 4000,
        pose = { profiles = { { profile = "bottle" }, { profile = "drink" } }, loop = false },
    },
    eat = {
        durationMs = 4000,
        pose = { profiles = { { profile = "takeout" }, { profile = "think" } }, loop = false },
        prop = { models = { "food.street_food" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    smoke = {
        durationMs = 6000,
        pose = { profiles = { { profile = "smoke" } }, loop = false },
    },
    snort = {
        durationMs = 3000,
        pose = { profiles = { { profile = "rubhands" }, { profile = "think" } }, loop = false },
    },
}

local WARNINGS = {
    hunger = {
        [30] = "Stomach's growling, choom. Grab a burrito before you start seeing double.",
        [10] = "You're starving. Eat now, or your body starts eating itself.",
    },
    thirst = {
        [30] = "Throat's dry as the Badlands. Find water or a Nicola.",
        [10] = "Dehydrated. Drink now -- your stamina is tanking.",
    },
    fatigue = {
        [30] = "Running on fumes. Park the car and close your eyes for a while.",
        [10] = "Your eyes are shutting on their own. Rest, or you'll drop mid-street.",
    },
}

local ICONS = { hunger = "FOOD", thirst = "H2O", fatigue = "ZZZ" }

local SUGGESTIONS = {
    { command = "/needs", help = "Biomonitor: your hunger, thirst and fatigue" },
    {
        command = "/setneeds",
        help = "Admin: set a player's hunger, thirst and fatigue (0..100)",
        parameters = {
            { name = "playerId", help = "Target session id" },
            { name = "hunger",   help = "0..100" },
            { name = "thirst",   help = "0..100" },
            { name = "fatigue",  help = "0..100" },
        },
    },
}

-- State ----------------------------------------------------------------------

local players = {}        -- playerId (number) -> state
local seated = {}         -- playerId (number) -> true while in a canonical vehicle seat
local schemaReady = false -- true once CREATE TABLE ran inside Open77.database.ready

local function log(fmt, ...)
    print((LOG_PREFIX .. " " .. fmt):format(...))
end

local function clamp(value)
    if value < 0 then return 0 end
    if value > 100 then return 100 end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

local function newState(identifier)
    return {
        identifier = identifier,
        hunger = 100, thirst = 100, fatigue = 100,
        dirty = false,
        warned = { hunger = {}, thirst = {}, fatigue = {} }, -- threshold -> true once warned
        staminaBase = nil,          -- stamina maximum before our penalty; nil = no penalty applied
        fxActive = false,           -- "exhausted" overlay currently held on the client
        lastChangedAt = -math.huge, -- monotonic seconds of the last rp_needs:changed
        lastStarveAt = 0,
        lastTickAt = Open77.time.monotonic(),
    }
end

-- Persistence ----------------------------------------------------------------

local SQL_CREATE = [[
CREATE TABLE IF NOT EXISTS rp_needs_state (
    identifier VARCHAR(128) NOT NULL PRIMARY KEY,
    hunger     FLOAT  NOT NULL DEFAULT 100,
    thirst     FLOAT  NOT NULL DEFAULT 100,
    fatigue    FLOAT  NOT NULL DEFAULT 100,
    updated_at BIGINT NOT NULL DEFAULT 0
)
]]

local SQL_LOAD = "SELECT hunger, thirst, fatigue FROM rp_needs_state WHERE identifier = ?"

local SQL_SAVE = [[
INSERT INTO rp_needs_state (identifier, hunger, thirst, fatigue, updated_at)
VALUES (?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE hunger = ?, thirst = ?, fatigue = ?, updated_at = ?
]]

local function kvpKey(identifier)
    return "needs:" .. identifier
end

local function encodeKvp(st)
    return ("%.2f|%.2f|%.2f"):format(st.hunger, st.thirst, st.fatigue)
end

local function decodeKvp(raw)
    if type(raw) ~= "string" then return nil end
    local h, t, f = raw:match("^([%d%.]+)|([%d%.]+)|([%d%.]+)$")
    h, t, f = tonumber(h), tonumber(t), tonumber(f)
    if not h or not t or not f then return nil end
    return clamp(h), clamp(t), clamp(f)
end

-- true when SQL can be used right now, else false and why.
local function dbUsable()
    local ready, reason = Open77.database.isReady()
    if not ready then return false, reason or "database_not_ready" end
    if not schemaReady then return false, "schema_not_ready" end
    return true
end

-- At boot the CREATE TABLE inside Open77.database.ready lands a tick or two after the
-- database answers; give it a moment rather than sending the first player to KVP.
local function waitForSchema()
    for _ = 1, SCHEMA_WAIT_STEPS do
        if schemaReady then return true end
        if not Open77.database.isReady() then return false end -- no database: nothing to wait for
        Wait(500)
    end
    return schemaReady
end

-- Runs inside a handler (may yield). Returns the state and where it came from.
local function loadState(identifier)
    local st = newState(identifier)
    waitForSchema()
    local usable, reason = dbUsable()
    if usable then
        local ok, row = pcall(Open77.database.single.await, SQL_LOAD, { identifier })
        if ok then
            if row then
                st.hunger = clamp(tonumber(row.hunger) or 100)
                st.thirst = clamp(tonumber(row.thirst) or 100)
                st.fatigue = clamp(tonumber(row.fatigue) or 100)
            end
            return st, "sql"
        end
        log("sql load failed for %s: %s -- using KVP fallback", identifier, tostring(row))
    else
        log("database not ready (%s) -- using KVP fallback to load %s", tostring(reason), identifier)
    end
    local h, t, f = decodeKvp(Open77.kvp.get(kvpKey(identifier)))
    if h then st.hunger, st.thirst, st.fatigue = h, t, f end
    return st, "kvp"
end

-- sync = true never yields (disconnect and resource stop): the callback form
-- submits the statement and returns at once.
local function saveState(st, sync)
    local usable, reason = dbUsable()
    if usable then
        local now = math.floor(Open77.time.unix())
        local params = {
            st.identifier, st.hunger, st.thirst, st.fatigue, now,
            st.hunger, st.thirst, st.fatigue, now,
        }
        local ok, err
        if sync then
            ok, err = pcall(Open77.database.update, SQL_SAVE, params, function() end)
        else
            ok, err = pcall(Open77.database.update.await, SQL_SAVE, params)
        end
        if ok then
            st.dirty = false
            return true
        end
        log("sql save failed for %s: %s -- using KVP fallback", st.identifier, tostring(err))
    else
        log("database not ready (%s) -- using KVP fallback to save %s", tostring(reason), st.identifier)
    end
    local ok, err = Open77.kvp.set(kvpKey(st.identifier), encodeKvp(st))
    if ok then
        st.dirty = false
        return true
    end
    log("kvp save failed for %s: %s", st.identifier, tostring(err))
    return false
end

-- Event + log -----------------------------------------------------------------

local function emitChanged(playerId, st, now)
    st.lastChangedAt = now
    local h, t, f = round(st.hunger), round(st.thirst), round(st.fatigue)
    -- The event fires every tick; the log line only when a value crosses a ten-point step,
    -- otherwise a full server writes one line per player per minute.
    local step = (h // 10) .. ":" .. (t // 10) .. ":" .. (f // 10)
    if st.lastLoggedStep ~= step then
        st.lastLoggedStep = step
        log("player %d hunger=%d thirst=%d fatigue=%d", playerId, h, t, f)
    end
    local ok, reason = TriggerEvent("rp_needs:changed", playerId, h, t, f)
    if not ok then
        log("rp_needs:changed not published for player %d: %s", playerId, tostring(reason))
    end
end

local function notify(playerId, definition)
    local id, reason = Open77.notifications.send(playerId, definition)
    if not id then
        log("notification to player %d refused: %s", playerId, tostring(reason))
    end
end

-- Effects --------------------------------------------------------------------

local function checkWarnings(playerId, st)
    for _, need in ipairs(NEEDS) do
        local value = st[need]
        for _, threshold in ipairs(WARN_THRESHOLDS) do
            if value < threshold then
                if not st.warned[need][threshold] then
                    st.warned[need][threshold] = true
                    notify(playerId, {
                        type = threshold <= 10 and "error" or "warning",
                        title = ("Biomonitor: %s %d%%"):format(need, round(value)),
                        message = WARNINGS[need][threshold],
                        icon = ICONS[need],
                        durationMs = 8000,
                    })
                end
            else
                -- Back above the line: the next crossing warns again.
                st.warned[need][threshold] = nil
            end
        end
    end
end

-- Halves the stamina pool while hungry or thirsty; restores it afterwards.
local function applyStaminaPenalty(playerId, st)
    local low = st.hunger < LOW_THRESHOLD or st.thirst < LOW_THRESHOLD
    local stats = Open77.stats.get(playerId)
    if not stats or not stats.stamina then return end -- not replicated yet
    local maximum = stats.stamina.maximum
    if type(maximum) ~= "number" or maximum <= 0 then return end

    if low then
        if not st.staminaBase then
            local penalised = math.max(1, math.floor(maximum * STAMINA_PENALTY_FACTOR))
            local ok, reason = Open77.stats.setStaminaMax(playerId, penalised)
            if ok then
                st.staminaBase = maximum
            else
                log("stamina penalty refused for player %d: %s", playerId, tostring(reason))
            end
        else
            -- Re-assert after a respawn or another reset restored the pool.
            local penalised = math.max(1, math.floor(st.staminaBase * STAMINA_PENALTY_FACTOR))
            if maximum > penalised then
                Open77.stats.setStaminaMax(playerId, penalised)
            end
        end
    elseif st.staminaBase then
        local ok, reason = Open77.stats.setStaminaMax(playerId, st.staminaBase)
        if ok then
            st.staminaBase = nil
        else
            log("stamina restore refused for player %d: %s", playerId, tostring(reason))
        end
    end
end

local function restoreStamina(playerId, st)
    if not st.staminaBase then return end
    Open77.stats.setStaminaMax(playerId, st.staminaBase)
    st.staminaBase = nil
end

-- At 0 hunger or thirst: 1 hp every 10 s, floor at 10 hp, never through life authority.
local function applyStarvation(playerId, st, now)
    if st.hunger > 0 and st.thirst > 0 then return end
    if now - st.lastStarveAt < STARVE_INTERVAL_S then return end
    st.lastStarveAt = now
    local stats = Open77.stats.get(playerId)
    if not stats or not stats.health then return end
    local hp = stats.health.value
    if type(hp) ~= "number" or hp <= STARVE_HP_FLOOR then return end
    local target = math.max(STARVE_HP_FLOOR, hp - 1)
    local ok, reason = Open77.stats.setHealth(playerId, target)
    if not ok then
        log("starvation damage refused for player %d: %s", playerId, tostring(reason))
    end
end

-- Fatigue below 20: the native stamina-exhaustion overlay, held until cleared.
local function applyFatigueFx(playerId, st)
    local tired = st.fatigue < LOW_THRESHOLD
    if tired and not st.fxActive then
        local ok, reason = Open77.effects.screen(playerId, "exhausted", { duration = 0 })
        if ok then
            st.fxActive = true
        else
            log("exhausted overlay refused for player %d: %s", playerId, tostring(reason))
        end
    elseif not tired and st.fxActive then
        Open77.effects.clearScreen(playerId)
        st.fxActive = false
    end
end

local function clearFatigueFx(playerId, st)
    if not st.fxActive then return end
    Open77.effects.clearScreen(playerId)
    st.fxActive = false
end

local function applyEffects(playerId, st, now)
    checkWarnings(playerId, st)
    applyStaminaPenalty(playerId, st)
    applyStarvation(playerId, st, now)
    applyFatigueFx(playerId, st)
end

-- Sitting still in a vehicle seat counts as rest. Seat state comes from the
-- host's onPlayerEnteredVehicle / onPlayerLeftVehicle events (no permission),
-- speed from the rich read.
local function isResting(playerId)
    if not seated[playerId] then return false end
    local read = Open77.players.get(playerId)
    if not read or type(read.speed) ~= "number" then return false end
    return read.speed < IDLE_SPEED
end

-- Tick -----------------------------------------------------------------------

local function tickPlayer(playerId, st, now)
    local dt = now - st.lastTickAt
    st.lastTickAt = now
    if dt <= 0 then return end
    -- A dead body neither hungers nor starves further.
    if Open77.players.isDead(playerId) then return end

    local minutes = dt / 60
    st.hunger = clamp(st.hunger - DECAY_PER_MIN.hunger * minutes)
    st.thirst = clamp(st.thirst - DECAY_PER_MIN.thirst * minutes)
    if isResting(playerId) then
        st.fatigue = clamp(st.fatigue + FATIGUE_RECOVERY_PER_MIN * minutes)
    else
        st.fatigue = clamp(st.fatigue - DECAY_PER_MIN.fatigue * minutes)
    end
    st.dirty = true

    applyEffects(playerId, st, now)
    if now - st.lastChangedAt >= CHANGED_INTERVAL_S then
        emitChanged(playerId, st, now)
    end
end

local function startLoops()
    CreateThread(function()
        while true do
            Wait(TICK_MS)
            local now = Open77.time.monotonic()
            for _, id in ipairs(Open77.players.all()) do
                local playerId = tonumber(id)
                local st = playerId and players[playerId]
                if st then
                    local ok, err = pcall(tickPlayer, playerId, st, now)
                    if not ok then log("tick failed for player %d: %s", playerId, tostring(err)) end
                end
            end
        end
    end)

    CreateThread(function()
        while true do
            Wait(SAVE_INTERVAL_S * 1000)
            -- Snapshot first: saveState yields, and players may join or leave meanwhile.
            local pending = {}
            for _, st in pairs(players) do
                if st.dirty then pending[#pending + 1] = st end
            end
            for _, st in ipairs(pending) do
                saveState(st, false)
            end
        end
    end)
end

-- Load / unload --------------------------------------------------------------

local function loadPlayer(playerId)
    if players[playerId] then return end
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        log("player %d has no identifier; needs not loaded", playerId)
        return
    end
    local st, from = loadState(identifier)
    -- The load yielded: make sure the same player still owns this seat.
    if players[playerId] then return end
    if Open77.players.identifier(playerId) ~= identifier then
        log("player %d left while loading; discarding", playerId)
        return
    end
    players[playerId] = st
    log("player %d loaded from %s hunger=%d thirst=%d fatigue=%d",
        playerId, from, round(st.hunger), round(st.thirst), round(st.fatigue))
    emitChanged(playerId, st, Open77.time.monotonic())
end

local function unloadPlayer(playerId)
    local st = players[playerId]
    players[playerId] = nil
    seated[playerId] = nil
    if not st then return end
    if st.dirty then saveState(st, true) end
    -- Disconnect already drops the host's temporary stat overrides and the
    -- screen effects; nothing else to release.
end

-- Exports (synchronous: must never yield) ------------------------------------

function get(playerId)
    playerId = tonumber(playerId)
    local st = playerId and players[playerId]
    if not st then return nil end
    return { hunger = round(st.hunger), thirst = round(st.thirst), fatigue = round(st.fatigue) }
end

local function describeDelta(def)
    local parts = {}
    for _, need in ipairs(NEEDS) do
        local delta = def[need]
        if delta and delta ~= 0 then
            parts[#parts + 1] = ("%s %s%d"):format(need, delta > 0 and "+" or "", delta)
        end
    end
    return table.concat(parts, ", ")
end

local function applyDelta(st, def)
    for _, need in ipairs(NEEDS) do
        local delta = def[need]
        if delta then st[need] = clamp(st[need] + delta) end
    end
    st.dirty = true
end

-- ---------------------------------------------------------------------------
-- Staging: a pose, a prop in the hand (or at the feet) and a progress bar for
-- every action that manipulates something, so nothing completes instantly and
-- everybody around sees it. Pattern of rp_nomade's carry pose: profiles tried
-- in order through Open77.animations.get, every native call inside pcall, a
-- refusal logged once and never fatal. RP animations are workspots: the
-- platform cancels one when the player moves more than 0.5 m, so the UI-kit bar
-- keeps the player still (disable.move, client side); the server never freezes
-- anyone. Everything comes from Config.Stage (shared/config.lua).
-- ---------------------------------------------------------------------------

local STAGE = NEEDS_STAGE or {}
local STAGE_TAG = "[" .. GetCurrentResourceName() .. "]"
local stageWarned = {}          -- "<what>" -> true once logged
local stageResolved = {}        -- key -> { profile, clip } | false
local stageActive = {}          -- playerId -> { key, playbackId, props = { ids } } while staged

local function stageLog(fmt, ...)
    print((STAGE_TAG .. " " .. fmt):format(...))
end

local function stageWarnOnce(what, fmt, ...)
    if stageWarned[what] then return end
    stageWarned[what] = true
    stageLog(fmt, ...)
end

local function stageAnimationsApi()
    return type(Open77.animations) == "table" and type(Open77.animations.play) == "function"
end

local function stagePropsApi()
    return type(Open77.props) == "table" and type(Open77.props.attach) == "function"
end

-- First profile of `pose.profiles` the server's catalogue knows (memoised per key).
local function stageResolvePose(key, pose)
    if stageResolved[key] ~= nil then return stageResolved[key] or nil end
    local found = false
    if type(pose) == "table" and stageAnimationsApi() then
        for _, candidate in ipairs(pose.profiles or {}) do
            local ok, profile = pcall(Open77.animations.get, candidate.profile)
            if ok and type(profile) == "table" then
                local clip = candidate.clip
                if clip then
                    local known = false
                    for _, name in ipairs(profile.clips or {}) do
                        if name == clip then known = true break end
                    end
                    if not known then
                        stageLog("stage %s: clip %s is not in profile %s, using %s", key, clip, candidate.profile, tostring(profile.clip))
                        clip = nil
                    end
                end
                found = { profile = candidate.profile, clip = clip or profile.clip }
                break
            end
        end
    end
    stageResolved[key] = found
    if not found then
        local names = {}
        for _, candidate in ipairs(type(pose) == "table" and pose.profiles or {}) do names[#names + 1] = tostring(candidate.profile) end
        stageWarnOnce("pose:" .. key, "stage %s: no known profile among [%s], the action runs without a pose", key, table.concat(names, ", "))
    end
    return found or nil
end

local function stagePoseWord(key)
    local r = stageResolved[key]
    if not r then return "none" end
    return r.profile .. "/" .. tostring(r.clip)
end

-- Start a pose on a player. A `loop` pose runs until stagePoseStop; a one-shot uses
-- `durationMs` (the platform accepts 1 000..600 000 ms). Returns the playback id or nil.
local function stagePoseStart(playerId, key, pose, durationMs)
    if type(pose) ~= "table" then return nil end
    local resolved = stageResolvePose(key, pose)
    if not resolved then return nil end
    local options = {}
    if pose.loop == false then
        options.loop = false
        options.durationMs = math.floor(math.max(1000, math.min(600000, tonumber(durationMs) or tonumber(pose.durationMs) or 5000)))
    else
        options.loop = true
    end
    if resolved.clip then options.clip = resolved.clip end
    local ok, playback, reason = pcall(Open77.animations.play, playerId, resolved.profile, options)
    if ok and type(playback) == "table" and playback.playbackId then
        return playback.playbackId
    end
    if not ok then reason = playback end
    stageWarnOnce("play:" .. key .. ":" .. tostring(reason), "stage %s: pose %s refused for player %d: %s (the action runs without it)",
        key, resolved.profile, playerId, tostring(reason))
    return nil
end

local function stagePoseStop(playerId, playbackId)
    if not playbackId or not stageAnimationsApi() then return end
    local ok, stopped, why = pcall(Open77.animations.stop, playerId, playbackId)
    if ok and not stopped and why ~= "stale_playback" then
        stageLog("stage: pose stop refused for player %d: %s", playerId, tostring(why))
    end
end

-- Spawn a curated prop and make it follow the player (a hand slot, or the root frame:
-- +y where the player faces, +x their right, +z up, origin at the feet). Returns the
-- prop id and the model, or nil.
local function stagePropHold(playerId, key, prop)
    if type(prop) ~= "table" or not stagePropsApi() then return nil end
    local ok0, pos = pcall(Open77.players.position, playerId)
    if not ok0 or type(pos) ~= "table" or type(pos.x) ~= "number" then return nil end
    for _, model in ipairs(prop.models or {}) do
        local okC, id, reason = pcall(Open77.props.create, {
            model = model,
            position = { x = pos.x, y = pos.y, z = pos.z or 0.0 },
            yaw = 0.0,
            bucket = pos.bucket or 0,
        })
        if not okC then id, reason = nil, id end
        if id then
            local okA, attached, why = pcall(Open77.props.attach, id, {
                parentType = "player",
                parentId = playerId,
                bone = prop.bone or "",
                offset = prop.offset or { x = 0.0, y = 0.0, z = 0.0 },
                rotation = prop.rotation or { x = 0.0, y = 0.0, z = 0.0 },
            })
            if okA and attached then return id, model end
            if not okA then why = attached end
            pcall(Open77.props.remove, id)
            stageWarnOnce("attach:" .. key .. ":" .. model, "stage %s: attach of %s to player %d refused: %s (no prop shown)",
                key, model, playerId, tostring(why))
            return nil
        end
        stageWarnOnce("prop:" .. key .. ":" .. model, "stage %s: prop %s refused: %s", key, model, tostring(reason))
    end
    return nil
end

local function stagePropDrop(propId)
    if propId and stagePropsApi() then pcall(Open77.props.remove, propId) end
end

local function stageSlotWord(prop)
    if type(prop) ~= "table" then return "root" end
    return (prop.bone and prop.bone ~= "") and prop.bone or "root"
end

-- Everything a staged action put on a player is taken back.
local function stageFinish(playerId, entry)
    if not entry then return end
    if stageActive[playerId] == entry then stageActive[playerId] = nil end
    stagePoseStop(playerId, entry.playbackId)
    entry.playbackId = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
    entry.props = {}
end

-- Pose + props of `def` on a player, returned as an entry for stageFinish.
local function stageBegin(playerId, key, def, durationMs)
    local entry = { key = key, props = {}, words = {} }
    stageActive[playerId] = entry
    if STAGE.enabled == false or type(def) ~= "table" then return entry end
    entry.playbackId = stagePoseStart(playerId, key, def.pose, durationMs)
    if def.prop then
        local id, model = stagePropHold(playerId, key .. ".prop", def.prop)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.prop = model .. "@" .. stageSlotWord(def.prop)
        end
    end
    if def.place then
        local id, model = stagePropHold(playerId, key .. ".place", def.place)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.place = model
        end
    end
    return entry
end

-- The UI-kit bar (server twin). A plain wait keeps the beat when the kit is missing.
local function stageBar(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, definition)
    if not promise then
        if reason == "progress_active" or reason == "dialog_active" then return nil, reason end
        stageWarnOnce("uikit:" .. tostring(reason), "stage: uikit progress unavailable (%s), plain wait instead", tostring(reason))
        Wait(definition.duration)
        return { ok = true, outcome = "ok", fallback = true }
    end
    local answer, err = promise:await()
    if not answer then return nil, err end
    return answer
end

-- Run a staged action on `playerId`: pose + props + bar, then everything is cleaned up.
-- `key` names a Config.Stage entry; opts.label / opts.durationMs / opts.cancellable override
-- it. Returns the bar's answer ({ ok, outcome }) or nil, reason when the bar never showed.
-- Yields: capture `source` before calling.
local function stage(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 5000)
    local entry = stageBegin(playerId, key, def, durationMs)
    local answer, err = stageBar(playerId, {
        label = opts.label or def.label or key,
        duration = durationMs,
        position = "bottom",
        style = "bar",
        color = def.color or STAGE.color,
        cancellable = opts.cancellable ~= false,
        cancelKey = "X",
        disable = { move = true, combat = true },
    })
    stageFinish(playerId, entry)
    stageLog("player %d stage %s: pose=%s prop=%s place=%s %d ms -> %s", playerId, key, stagePoseWord(key),
        entry.words.prop or "none", entry.words.place or "none", durationMs,
        answer and (answer.ok and "ok" or tostring(answer.outcome or "cancelled")) or ("failed:" .. tostring(err)))
    return answer, err
end

-- A gesture without a bar (a hand-over, a wave, a sip): pose + props for `durationMs`,
-- taken back by a timer. Never yields. Returns the entry.
local function gesture(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 3000)
    local entry = stageBegin(playerId, key, def, durationMs)
    SetTimeout(durationMs, function() stageFinish(playerId, entry) end)
    stageLog("player %d gesture %s: pose=%s prop=%s %d ms", playerId, key, stagePoseWord(key), entry.words.prop or "none", durationMs)
    return entry
end

-- A pose held until stageRelease (a cuffed suspect, a patient on the ground). Never yields.
local function stageHold(playerId, key)
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local entry = stageBegin(playerId, key, def, nil)
    stageLog("player %d hold %s: pose=%s prop=%s", playerId, key, stagePoseWord(key), entry.words.prop or "none")
    return entry
end

local function stageRelease(playerId, entry)
    stageFinish(playerId, entry or stageActive[playerId])
end

-- Disconnect: the pose died with the player, the props must not survive them.
local function stageClear(playerId)
    local entry = stageActive[playerId]
    if not entry then return end
    stageActive[playerId] = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
end

function consume(playerId, itemId)
    playerId = tonumber(playerId)
    if not playerId then return nil, "invalid_player" end
    local st = players[playerId]
    if not st then return nil, "player_not_found" end
    local def = type(itemId) == "string" and CONSUMABLES[itemId:lower()] or nil
    if not def then return nil, "not_consumable" end

    local now = Open77.time.monotonic()
    applyDelta(st, def)
    if def.stage then gesture(playerId, def.stage) end
    notify(playerId, {
        type = "success",
        title = def.label,
        message = describeDelta(def) .. ".",
        icon = "USE",
        durationMs = 5000,
    })
    applyEffects(playerId, st, now)
    emitChanged(playerId, st, now)

    if def.after then
        local identifier = st.identifier
        SetTimeout(def.after.delayMs, function()
            local later = players[playerId]
            if not later or later.identifier ~= identifier then return end
            local at = Open77.time.monotonic()
            applyDelta(later, def.after)
            notify(playerId, {
                type = "warning",
                title = def.label .. " crash",
                message = "The high wears off. Your body wants that sleep back (" .. describeDelta(def.after) .. ").",
                icon = "USE",
                durationMs = 6000,
            })
            applyEffects(playerId, later, at)
            emitChanged(playerId, later, at)
        end)
    end
    return true
end

-- apply(playerId, delta, label) -> true | nil, reason
-- Generic restore/drain for other resources' consumables (a bar drink, a ripper's sedative):
-- delta = { hunger = +n, thirst = +n, fatigue = +n } (each optional, -100..100), label shown in
-- the toast. Declared in the manifest through server_exports.
function apply(playerId, delta, label)
    playerId = tonumber(playerId)
    if not playerId then return nil, "invalid_player" end
    local st = players[playerId]
    if not st then return nil, "player_not_found" end
    if type(delta) ~= "table" then return nil, "invalid_delta" end
    local def = { label = type(label) == "string" and label or "Consumed" }
    local any = false
    for _, need in ipairs(NEEDS) do
        local v = tonumber(delta[need])
        if v then
            if v < -100 or v > 100 then return nil, "invalid_delta" end
            def[need] = math.floor(v); any = true
        end
    end
    if not any then return nil, "invalid_delta" end
    local now = Open77.time.monotonic()
    applyDelta(st, def)
    notify(playerId, { type = "success", title = def.label, message = describeDelta(def) .. ".", icon = "USE", durationMs = 5000 })
    applyEffects(playerId, st, now)
    emitChanged(playerId, st, now)
    return true
end

-- Commands -------------------------------------------------------------------

RegisterCommand("needs", function(source)
    if source == 0 then
        return print(LOG_PREFIX .. " /needs: run this from the game, not the console")
    end
    local st = players[source]
    if not st then
        return Open77.chat.send(source, "Biomonitor offline: your needs are not loaded yet, choom.")
    end
    Open77.chat.send(source, {
        author = "BIOMONITOR",
        text = ("Hunger %d%%  |  Thirst %d%%  |  Fatigue %d%%"):format(
            round(st.hunger), round(st.thirst), round(st.fatigue)),
        color = { 0, 229, 255 },
    })
end, false)

-- Restricted: needs ACL command.setneeds; the server console is always allowed.
RegisterCommand("setneeds", function(source, args)
    local function reply(text)
        if source == 0 then print(LOG_PREFIX .. " " .. text) else Open77.chat.send(source, text) end
    end
    local target = tonumber(args[1])
    local h, t, f = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not target or not h or not t or not f then
        return reply("Usage: /setneeds <playerId> <hunger> <thirst> <fatigue> (0..100)")
    end
    local st = players[target]
    if not st then
        return reply(("Player %d has no needs loaded."):format(target))
    end
    st.hunger, st.thirst, st.fatigue = clamp(h), clamp(t), clamp(f)
    st.dirty = true
    local now = Open77.time.monotonic()
    applyEffects(target, st, now)
    emitChanged(target, st, now)
    reply(("Needs of player %d set: hunger %d, thirst %d, fatigue %d."):format(
        target, round(st.hunger), round(st.thirst), round(st.fatigue)))
end, true)

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then log("chat suggestions not published: %s", tostring(reason)) end
end

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source <= 0 then return end
    publishSuggestions(source)
end)

-- Lifecycle ------------------------------------------------------------------

local readyOk, readyReason = Open77.database.ready(function()
    local ok, err = pcall(Open77.database.update.await, SQL_CREATE)
    if ok then
        schemaReady = true
        log("schema ready (rp_needs_state)")
    else
        log("schema creation failed: %s -- KVP fallback stays active", tostring(err))
    end
end)
if not readyOk then
    log("database not available (%s) -- KVP fallback active for every player", tostring(readyReason))
end

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    startLoops()
    publishSuggestions(-1)
    -- Players already in the world when this resource (re)started.
    for _, id in ipairs(Open77.players.all()) do
        local playerId = tonumber(id)
        if playerId then loadPlayer(playerId) end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    for playerId, st in pairs(players) do
        if st.dirty then saveState(st, true) end
        restoreStamina(playerId, st)
        clearFatigueFx(playerId, st)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if playerId then loadPlayer(playerId) end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if playerId then unloadPlayer(playerId); stageClear(playerId) end
end)

AddEventHandler("onPlayerEnteredVehicle", function(playerId)
    playerId = tonumber(playerId)
    if playerId then seated[playerId] = true end
end)

AddEventHandler("onPlayerLeftVehicle", function(playerId)
    playerId = tonumber(playerId)
    if playerId then seated[playerId] = nil end
end)

-- A respawned body starts with a clean view: re-arm the overlay on the next tick.
AddEventHandler("onPlayerLifeStateChanged", function(playerId, _, phase)
    if phase ~= "alive" then return end
    playerId = tonumber(playerId)
    local st = playerId and players[playerId]
    if st then st.fxActive = false end
end)
