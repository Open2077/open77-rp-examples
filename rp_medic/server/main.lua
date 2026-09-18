-- rp_medic - server-only medic service for an RP server.
--
-- /soin <playerId>   medic only, target alive within 5 m, full health, 100 eddies
-- /reanimer <playerId> medic only, target dead within 5 m, revived where it fell, 300 eddies
-- /911 <message>     anyone: message + rounded position sent to every medic and cop
-- /medic             connected medics with their distance to the caller
--
-- Authority: everything is decided here. Money goes through rp_economy, jobs through
-- rp_jobs; when rp_jobs publishes no export the ACL right of a restricted command
-- (command.soin / command.reanimer) decides instead. Persistence (per-medic counters)
-- goes through Open77.kvp keyed by the durable identifier, never the session id.

-- The platform already owns /heal (open77_admin) and /revive (freeroam), and a
-- command name registered twice across resources is served by the first one:
-- the medic verbs are /soin and /reanimer.

local RESOURCE = GetCurrentResourceName()

local HEAL_FEE = 100
local REVIVE_FEE = 300
local RANGE_M = 5.0
local COOLDOWN_S = 30
local MEDIC_JOB = "medecin"
local POLICE_JOB = "police"
local REVIVE_HEALTH = 1.0   -- fraction of the maximum after a paid revive
local REVIVE_GRACE_MS = 5000

-- [medicId] = Open77.time.monotonic() of the medic's last paid act (heal or revive).
local cooldowns = {}

local COLOR_MEDIC = { 80, 220, 160 }
local COLOR_ALERT = { 255, 90, 90 }

local function log(fmt, ...)
    print(("[rp_medic] " .. fmt):format(...))
end

-- Chat to one player. `playerId` is always a number here (command / net-event source).
local function say(playerId, text)
    local ok, reason = Open77.chat.send(playerId, { author = "MEDIC", text = text, color = COLOR_MEDIC })
    if not ok then
        log("chat.send to %s failed: %s", tostring(playerId), tostring(reason))
    end
end

local function round(value)
    return math.floor(value + 0.5)
end

-- ---------------------------------------------------------------------------
-- rp_jobs (synchronous exports raise when the export or the resource is missing)
-- ---------------------------------------------------------------------------

-- Returns `job, true` when rp_jobs answered, `nil, false` when its export is unavailable.
local function jobOf(playerId)
    local ok, job = pcall(function()
        return exports.rp_jobs:getJob(playerId)
    end)
    if not ok then
        log("rp_jobs getJob unavailable: %s", tostring(job))
        return nil, false
    end
    return job, true
end

-- Returns true / false when rp_jobs answered, nil when its export is unavailable.
local function hasJob(playerId, jobName)
    local ok, result = pcall(function()
        return exports.rp_jobs:hasJob(playerId, jobName)
    end)
    if not ok then
        log("rp_jobs hasJob unavailable: %s", tostring(result))
        return nil
    end
    return result == true
end

-- ACL fallback: the same right a restricted command of that name would require.
local function aclAllows(playerId, right)
    local allowed, reason = Open77.acl.isAllowed(playerId, right)
    if allowed ~= true and reason then
        log("acl.isAllowed(%s, %s) refused: %s", tostring(playerId), right, tostring(reason))
    end
    return allowed == true
end

-- May this player use the medic command `commandName`? Returns allowed, mode.
local function isMedic(playerId, commandName)
    local viaJobs = hasJob(playerId, MEDIC_JOB)
    if viaJobs ~= nil then
        return viaJobs, "jobs"
    end
    return aclAllows(playerId, "command." .. commandName), "acl"
end

-- Roles of a connected player for the roster commands. Without rp_jobs a medic is
-- whoever holds command.heal; the police cannot be identified and is left out.
local function rolesOf(playerId)
    local job, available = jobOf(playerId)
    if available then
        return { medic = job == MEDIC_JOB, police = job == POLICE_JOB }, "jobs"
    end
    return { medic = aclAllows(playerId, "command.soin"), police = false }, "acl"
end

-- ---------------------------------------------------------------------------
-- rp_economy
-- ---------------------------------------------------------------------------

-- Charges `amount` to the patient and credits the medic.
-- Returns "paid", "free" (patient cannot pay) or "unavailable" (no economy service).
local function charge(patient, medic, amount, reason)
    local ok, newBalance, why = pcall(function()
        return exports.rp_economy:remove(patient, amount, reason)
    end)
    if not ok then
        log("rp_economy remove unavailable: %s", tostring(newBalance))
        return "unavailable"
    end
    if newBalance == nil then
        log("player %d cannot pay %d (%s): free", patient, amount, tostring(why))
        return "free"
    end

    local okAdd, credited, addWhy = pcall(function()
        return exports.rp_economy:add(medic, amount, reason)
    end)
    if not okAdd or credited == nil then
        -- The patient paid but the medic could not be credited: give the money back.
        log("crediting medic %d failed (%s), refunding player %d", medic,
            tostring(okAdd and addWhy or credited), patient)
        pcall(function()
            return exports.rp_economy:add(patient, amount, reason .. "_refund")
        end)
        return "free"
    end
    return "paid"
end

-- ---------------------------------------------------------------------------
-- Persistence: per-medic counters keyed by the durable identifier
-- ---------------------------------------------------------------------------

local function recordAct(medic, kind, fee)
    local identifier = Open77.players.identifier(medic)
    if not identifier then
        return
    end
    local _, reason = Open77.kvp.increment(kind .. ":" .. identifier, 1)
    if reason then
        log("kvp increment %s failed: %s", kind, tostring(reason))
    end
    if fee > 0 then
        Open77.kvp.increment("earned:" .. identifier, fee)
    end
end

local function statsLine(medic)
    local identifier = Open77.players.identifier(medic)
    if not identifier then
        return nil
    end
    local heals = Open77.kvp.get("heal:" .. identifier, 0) or 0
    local revives = Open77.kvp.get("revive:" .. identifier, 0) or 0
    local earned = Open77.kvp.get("earned:" .. identifier, 0) or 0
    return ("Your interventions: %d heal(s), %d revive(s), %d €$ earned."):format(heals, revives, earned)
end

-- ---------------------------------------------------------------------------
-- Shared checks
-- ---------------------------------------------------------------------------

local function cooldownLeft(medic)
    local last = cooldowns[medic]
    if not last then
        return 0
    end
    local left = COOLDOWN_S - (Open77.time.monotonic() - last)
    if left > 0 then
        return left
    end
    return 0
end

-- Common gate of /heal and /revive: a player, a medic, no cooldown, a valid patient
-- within range. Returns the patient id, or nil after telling the caller why.
local function medicGate(source, args, commandName, usage)
    if source == 0 then
        print(("[rp_medic] /%s must be used by a player in game, not from the console"):format(commandName))
        return nil
    end

    local allowed, mode = isMedic(source, commandName)
    if not allowed then
        if mode == "acl" then
            say(source, "Medics only (rp_jobs service unavailable: right command." .. commandName .. " required).")
        else
            say(source, "Medics only.")
        end
        return nil
    end

    local left = cooldownLeft(source)
    if left > 0 then
        say(source, ("Wait another %d s before your next intervention."):format(math.ceil(left)))
        return nil
    end

    local target = tonumber(args[1])
    if not target or target < 1 or target % 1 ~= 0 then
        say(source, usage)
        return nil
    end
    target = math.tointeger(target)
    if target == source then
        say(source, "You can't treat yourself.")
        return nil
    end

    local read, reason = Open77.players.get(target)
    if not read then
        say(source, ("Player %d not found (%s)."):format(target, tostring(reason)))
        return nil
    end
    if not read.ready then
        say(source, "This player is not in the world yet.")
        return nil
    end

    local metres, dreason = Open77.players.distance(source, target)
    if not metres then
        say(source, "Patient position unknown (" .. tostring(dreason) .. ").")
        return nil
    end
    if metres > RANGE_M then
        say(source, ("Too far: %.1f m (5 m max)."):format(metres))
        return nil
    end
    return target
end

local function feeSentence(outcome, fee)
    if outcome == "paid" then
        return ("%d €$ collected."):format(fee)
    elseif outcome == "free" then
        return "The patient can't pay: free intervention."
    end
    return "Economy service unavailable: free intervention."
end

-- ---------------------------------------------------------------------------
-- /soin <playerId>
-- ---------------------------------------------------------------------------

-- Staging (2026-09-18 pass): a heal and a revive play a pose, show the injector and take
-- their time behind a UI-kit bar, so the patient sees the medic work. Same rules as
-- rp_mecano / rp_nomade (this resource has no shared config, so the table lives here):
-- `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first, then today's 18-profile eval catalogue);
-- `loop = true` is held for the bar and stopped by the server. Props are curated aliases
-- tried in order, attached to a rig slot ("RightHand"); hand-slot axes are not measured.
local MEDIC_STAGE = {
    enabled = true,
    color = "#50DCA0",
    heal = {
        durationMs = 5000,
        label = "Patching the patient",
        pose = { profiles = { { profile = "medical" }, { profile = "examine" } }, loop = true },
        prop = { models = { "medical.injector", "medical.device" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    revive = {
        durationMs = 8000,
        label = "Reviving the patient",
        pose = { profiles = { { profile = "medical" }, { profile = "examine" } }, loop = true },
        prop = { models = { "medical.injector", "medical.device" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
}

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

local STAGE = MEDIC_STAGE or {}
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

RegisterCommand("soin", function(source, args)
    local patient = medicGate(source, args, "soin", "Usage: /soin <playerId>")
    if not patient then
        return
    end

    local dead = Open77.players.isDead(patient)
    if dead == nil then
        return say(source, "Patient state unknown.")
    end
    if dead then
        return say(source, "This patient is dead: use /reanimer.")
    end

    local stats = Open77.stats.get(patient)
    if stats and stats.health and stats.health.value >= stats.health.maximum then
        return say(source, "This patient is already at full health.")
    end

    -- Staged: the medic kneels over the patient, injector in hand, for the bar's length.
    local done = stage(source, "heal", { label = "Patching " .. (Open77.players.name(patient) or "the patient") })
    if not done or not done.ok then return say(source, "Intervention cancelled.") end
    if Open77.players.isDead(patient) ~= false then return say(source, "The patient is in no state for that any more.") end

    local ok, reason = Open77.stats.restoreHealth(patient)
    if not ok then
        return say(source, "Heal failed: " .. tostring(reason) .. ".")
    end

    cooldowns[source] = Open77.time.monotonic()
    local outcome = charge(patient, source, HEAL_FEE, "medic_heal")
    local fee = outcome == "paid" and HEAL_FEE or 0
    recordAct(source, "heal", fee)

    local medicName = Open77.players.name(source) or ("player " .. source)
    local patientName = Open77.players.name(patient) or ("player " .. patient)
    say(source, ("Patient %s healed. %s"):format(patientName, feeSentence(outcome, HEAL_FEE)))
    if outcome == "paid" then
        say(patient, ("Medic %s healed you: %d €$ charged."):format(medicName, HEAL_FEE))
    else
        say(patient, ("Medic %s healed you for free."):format(medicName))
    end
    log("player %d healed player %d fee=%d", source, patient, fee)
end, false)

-- ---------------------------------------------------------------------------
-- /reanimer <playerId>
-- ---------------------------------------------------------------------------

RegisterCommand("reanimer", function(source, args)
    local patient = medicGate(source, args, "reanimer", "Usage: /reanimer <playerId>")
    if not patient then
        return
    end

    local dead = Open77.players.isDead(patient)
    if dead == nil then
        return say(source, "Patient state unknown.")
    end
    if not dead then
        return say(source, "This patient is alive: use /soin.")
    end

    -- Staged: the medic kneels over the body, injector in hand, for the bar's length.
    local done = stage(source, "revive", { label = "Reviving " .. (Open77.players.name(patient) or "the patient") })
    if not done or not done.ok then return say(source, "Intervention cancelled.") end
    if not Open77.players.isDead(patient) then return say(source, "This patient is alive: use /soin.") end

    -- Documented safe path for a dead player: the server's life authority revives
    -- the body where it fell; the call refuses (false, reason) during a transition.
    local ok, reason = Open77.players.revive(patient, { health = REVIVE_HEALTH, graceMs = REVIVE_GRACE_MS })
    if not ok then
        return say(source, "Revive failed: " .. tostring(reason) .. ".")
    end

    cooldowns[source] = Open77.time.monotonic()
    local outcome = charge(patient, source, REVIVE_FEE, "medic_revive")
    local fee = outcome == "paid" and REVIVE_FEE or 0
    recordAct(source, "revive", fee)

    local medicName = Open77.players.name(source) or ("player " .. source)
    local patientName = Open77.players.name(patient) or ("player " .. patient)
    say(source, ("Patient %s revived. %s"):format(patientName, feeSentence(outcome, REVIVE_FEE)))
    if outcome == "paid" then
        say(patient, ("Medic %s revived you: %d €$ charged."):format(medicName, REVIVE_FEE))
    else
        say(patient, ("Medic %s revived you for free."):format(medicName))
    end
    log("player %d revived player %d fee=%d", source, patient, fee)
end, false)

-- ---------------------------------------------------------------------------
-- /911 <message>
-- ---------------------------------------------------------------------------

RegisterCommand("911", function(source, args)
    if source == 0 then
        return print("[rp_medic] /911 must be used by a player in game, not from the console")
    end

    local message = table.concat(args, " ", 1, args.n or #args)
    message = message:match("^%s*(.-)%s*$")
    if message == "" then
        return say(source, "Usage: /911 <message>")
    end

    local pos = Open77.players.position(source)
    local where = "unknown position"
    if pos then
        where = ("%d, %d, %d"):format(round(pos.x), round(pos.y), round(pos.z))
    end
    local callerName = Open77.players.name(source) or ("player " .. source)
    local alert = {
        author = "911",
        text = ("%s (id %d) at %s: %s"):format(callerName, source, where, message),
        color = COLOR_ALERT,
    }

    local notified = 0
    local mode = "jobs"
    for _, id in ipairs(Open77.players.all()) do
        if id ~= source then
            local roles, m = rolesOf(id)
            mode = m
            if roles.medic or roles.police then
                local ok, reason = Open77.chat.send(id, alert)
                if ok then
                    notified = notified + 1
                else
                    log("911 alert to player %d failed: %s", id, tostring(reason))
                end
            end
        end
    end

    if mode == "acl" then
        say(source, ("Call relayed to %d responder(s) (rp_jobs service unavailable: NCPD unreachable)."):format(notified))
    else
        say(source, ("Call relayed to %d responder(s) (medics and NCPD)."):format(notified))
    end
    log("player %d called 911 at %s notified=%d", source, where, notified)
end, false)

-- ---------------------------------------------------------------------------
-- /medic
-- ---------------------------------------------------------------------------

RegisterCommand("medic", function(source)
    if source == 0 then
        return print("[rp_medic] /medic must be used by a player in game, not from the console")
    end

    local medics = {}
    local callerIsMedic = false
    for _, id in ipairs(Open77.players.all()) do
        local roles = rolesOf(id)
        if roles.medic then
            if id == source then
                callerIsMedic = true
            else
                local metres = Open77.players.distance(source, id)
                medics[#medics + 1] = {
                    id = id,
                    name = Open77.players.name(id) or ("player " .. id),
                    metres = metres,
                }
            end
        end
    end

    table.sort(medics, function(a, b)
        if a.metres and b.metres then
            return a.metres < b.metres
        end
        return a.metres ~= nil and b.metres == nil
    end)

    if #medics == 0 then
        if callerIsMedic then
            say(source, "No other medic online.")
        else
            say(source, "No medic online.")
        end
    else
        say(source, ("%d medic(s) on duty:"):format(#medics))
        for _, medic in ipairs(medics) do
            Wait(0)   -- two sends in the same tick arrive in reverse order
            local dist = medic.metres and ("%.0f m"):format(medic.metres) or "unknown distance"
            say(source, ("- %s (id %d): %s"):format(medic.name, medic.id, dist))
        end
    end

    if callerIsMedic then
        local line = statsLine(source)
        if line then
            Wait(0)
            say(source, line)
        end
    end
end, false)

-- ---------------------------------------------------------------------------
-- Lifecycle and chat suggestions
-- ---------------------------------------------------------------------------

local SUGGESTIONS = {
    {
        command = "/soin",
        help = "Heal a living patient within 5 m (medic, 100 €$)",
        parameters = { { name = "playerId", help = "Patient id (/id)" } },
    },
    {
        command = "/reanimer",
        help = "Revive a dead patient within 5 m (medic, 300 €$)",
        parameters = { { name = "playerId", help = "Patient id (/id)" } },
    },
    {
        command = "/911",
        help = "Alert the medics and the NCPD with your position",
        parameters = { { name = "message", help = "What is happening" } },
    },
    {
        command = "/medic",
        help = "Medics online and their distance",
    },
}

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then
        log("addSuggestions(%s) failed: %s", tostring(target), tostring(reason))
    end
end

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    publishSuggestions(-1)
    log("started: fees heal=%d revive=%d, range=%.0f m, cooldown=%d s", HEAL_FEE, REVIVE_FEE, RANGE_M, COOLDOWN_S)
end)

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source < 1 then
        return
    end
    publishSuggestions(source)
end)

-- Host lifecycle arguments are strings: convert before touching the cooldown table.
AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if id then
        cooldowns[id] = nil
        stageClear(id)
    end
end)
