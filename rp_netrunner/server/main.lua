-- rp_netrunner server: the authority for every netrunning contract.
-- Job + duty come from rp_jobs, quickhacks from rp_inventory, traces go to rp_ncpd,
-- the data bounty to rp_economy / rp_bank; the hacks themselves are the platform's
-- Open77.hacking.* kit (the netrunner needs the rp_netrunner.deck operating system).

local RESOURCE = GetCurrentResourceName()
local HACK_KINDS = { "short_circuit", "overheat" }

local state = {
    deckDefined = false,      -- Open77.hacking.define + Open77.cyberware.define accepted
    deckReason = "not_started",
    terminalProp = nil,       -- prop id of the access-point terminal (decimal string)
    jam = nil,                -- { deadline, by, byName } while the NCPD radio is jammed
}

local cooldowns = {}          -- player -> kind -> monotonic deadline (seconds)
local pings = {}              -- player -> target -> token (the running relay threads)
local pendingDeck = {}        -- player -> { ticket, grade }
local breaching = {}          -- player -> true while the bar runs
local actions = {}            -- actionId -> { player, kind, target } for the transition ledger
local claimedDoors = {}       -- doorId -> bucket, doors this resource had to claim
local identifiers = {}        -- player -> durable identifier (cached at ready)
local logs = {}               -- identifier -> { { kind, target, at }, ... } newest first (max 50)
local counts = {}             -- identifier -> contracts done (all time)

local store = { mode = "pending", reason = nil }   -- "pending" | "sql" | "kvp"
local LOG_CACHE = 50

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function now() return Open77.time.monotonic() end

local function say(player, text, color)
    if not player or player <= 0 then print("[rp_netrunner] " .. text); return end
    Open77.chat.send(player, { type = "system", author = "NET", text = text, color = color or Config.colors.net })
end

local function warn(player, text) say(player, text, Config.colors.warn) end

-- Synchronous cross-resource export inside pcall: nil, reason when the resource is missing.
local function rp(resource, name, ...)
    local args = table.pack(...)
    -- Dot form: the proxy only strips the `self` a colon inserts, so nothing is prepended here.
    local ok, a, b = pcall(function() return exports[resource][name](table.unpack(args, 1, args.n)) end)
    if not ok then return nil, "unavailable:" .. resource end
    return a, b
end

-- Asynchronous export (yields): nil, reason when dispatch is refused or the call rejects.
local function callExport(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function displayName(player)
    local full = rp("rp_identity", "fullName", player)
    if type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(player) or ("#" .. tostring(player))
end

local function planar(a, b)
    local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

local function fmtSeconds(s)
    s = math.max(0, math.ceil(s))
    if s >= 60 then return ("%d min %02d s"):format(s // 60, s % 60) end
    return ("%d s"):format(s)
end

-- ---------------------------------------------------------------------------
-- Gates: job, duty, cooldown, items, targets
-- ---------------------------------------------------------------------------

local function netrunnerOnDuty(player)
    local has, reason = rp("rp_jobs", "hasJob", player, Config.job)
    if has == nil and reason then return nil, reason end
    if not has then return nil, "not_netrunner" end
    local duty = rp("rp_jobs", "onDuty", player)
    if not duty then return nil, "off_duty" end
    return true
end

local function explainGate(player, reason)
    if reason == "not_netrunner" then warn(player, "You are no netrunner. Find a fixer who trusts you with a deck.")
    elseif reason == "off_duty" then warn(player, "Off duty. /service to jack in first.")
    else warn(player, "The jobs registry is offline (" .. tostring(reason) .. "). No contract can be checked.") end
end

local function gate(player)
    local ok, reason = netrunnerOnDuty(player)
    if not ok then explainGate(player, reason); return false end
    if Open77.players.isDead(player) then warn(player, "You are flatlined, choom. No netrunning from the floor."); return false end
    return true
end

local function cooldownLeft(player, kind)
    local mine = cooldowns[player]
    local deadline = mine and mine[kind]
    if not deadline then return 0 end
    return math.max(0, deadline - now())
end

local function checkCooldown(player, kind, label)
    local left = cooldownLeft(player, kind)
    if left > 0 then
        warn(player, ("%s is cooling down: %s left."):format(label, fmtSeconds(left)))
        return false
    end
    return true
end

local function setCooldown(player, kind)
    cooldowns[player] = cooldowns[player] or {}
    cooldowns[player][kind] = now() + Config.cooldownMs / 1000
end

local function itemLabel(itemId)
    local def = Config.items[itemId]
    return def and def.label or itemId
end

local function hasItem(player, itemId)
    if not itemId then return true end
    local has, reason = rp("rp_inventory", "has", player, itemId, 1)
    if has == nil and reason then
        warn(player, "Your pockets are unreadable (" .. tostring(reason) .. ").")
        return false
    end
    if not has then
        warn(player, ("No %s in your pockets. Buy one on the black market."):format(itemLabel(itemId)))
        return false
    end
    return true
end

local function takeItem(player, itemId)
    if not itemId then return true end
    local ok, reason = rp("rp_inventory", "remove", player, itemId, 1)
    if not ok then
        warn(player, ("Could not burn a %s (%s)."):format(itemLabel(itemId), tostring(reason)))
        return false
    end
    return true
end

-- A living, connected target other than the netrunner, within `range` metres.
local function resolveTarget(player, rawTarget, range)
    -- A positive integer only: Open77.players.* raise on anything else (1e300 passes `% 1 == 0`).
    local target = math.tointeger(tonumber(rawTarget))
    if not target or target <= 0 then
        warn(player, "Give a player id: /players lists them.")
        return nil
    end
    if target == player then warn(player, "Hacking yourself? Your deck refuses."); return nil end
    if not Open77.players.name(target) then warn(player, ("No player #%d on this server."):format(target)); return nil end
    if Open77.players.isDead(target) then warn(player, "That choom is already flatlined."); return nil end
    local metres, reason = Open77.players.distance(player, target)
    if not metres then warn(player, "Cannot place the target (" .. tostring(reason) .. ")."); return nil end
    if metres > range then
        warn(player, ("Out of range (%.0f m). Get within %d m."):format(metres, range))
        return nil
    end
    return target, metres
end

-- ---------------------------------------------------------------------------
-- Persistence: rp_netrunner_log (SQL first, kvp only when the database never answers)
-- ---------------------------------------------------------------------------

local function kvpKey(identifier) return "log:" .. identifier end

local function useKvp(reason)
    if store.mode == "kvp" then return end
    store.mode, store.reason = "kvp", reason
    print(("[rp_netrunner] store=kvp reason=%s"):format(tostring(reason)))
end

local function initStore()
    local queued, reason = Open77.database.ready(function()
        if store.mode == "kvp" then
            print("[rp_netrunner] database answered late: keeping the kvp store for this boot")
            return
        end
        local ok, err = pcall(function()
            Open77.database.update.await([[
                CREATE TABLE IF NOT EXISTS rp_netrunner_log (
                    id        INT AUTO_INCREMENT PRIMARY KEY,
                    netrunner VARCHAR(64) NOT NULL,
                    kind      VARCHAR(32) NOT NULL,
                    target    VARCHAR(64) NOT NULL DEFAULT '',
                    `at`      BIGINT      NOT NULL DEFAULT 0,
                    INDEX rp_netrunner_log_netrunner (netrunner, `at`)
                )
            ]])
        end)
        if not ok then useKvp("create_table_failed:" .. tostring(err)); return end
        store.mode = "sql"
        print("[rp_netrunner] store=sql table=rp_netrunner_log")
    end)
    if not queued then useKvp(reason or "database_unavailable") end
end

-- Wait up to 15 s for a database that is still connecting, then settle on kvp.
local function awaitStore()
    local deadline = now() + 15
    while store.mode == "pending" and now() < deadline do Wait(500) end
    if store.mode == "pending" then useKvp("database_timeout") end
end

local function loadPlayerLog(player)
    local identifier = identifiers[player]
    if not identifier then return end
    awaitStore()
    if store.mode == "sql" then
        local ok, rows = pcall(function()
            return Open77.database.query.await(
                ("SELECT kind, target, `at` FROM rp_netrunner_log WHERE netrunner = ? ORDER BY `at` DESC, id DESC LIMIT %d"):format(LOG_CACHE),
                { identifier })
        end)
        local okCount, total = pcall(function()
            return Open77.database.scalar.await("SELECT COUNT(*) FROM rp_netrunner_log WHERE netrunner = ?", { identifier })
        end)
        if not ok or type(rows) ~= "table" then
            print(("[rp_netrunner] player %d log read failed: %s"):format(player, tostring(rows)))
            logs[identifier] = logs[identifier] or {}
            return
        end
        local entries = {}
        for _, row in ipairs(rows) do
            entries[#entries + 1] = { kind = row.kind, target = row.target, at = tonumber(row.at) or 0 }
        end
        logs[identifier] = entries
        counts[identifier] = (okCount and tonumber(total)) or #entries
    else
        local raw = Open77.kvp.get(kvpKey(identifier), "[]")
        local entries = type(raw) == "string" and json.decode(raw) or nil
        logs[identifier] = type(entries) == "table" and entries or {}
        counts[identifier] = #logs[identifier]
    end
end

local function appendLog(player, kind, targetIdentifier)
    local identifier = identifiers[player] or Open77.players.identifier(player)
    if not identifier then return end
    local entry = { kind = kind, target = targetIdentifier or "", at = math.floor(Open77.time.unix()) }
    local entries = logs[identifier] or {}
    table.insert(entries, 1, entry)
    while #entries > LOG_CACHE do table.remove(entries) end
    logs[identifier] = entries
    counts[identifier] = (counts[identifier] or 0) + 1
    if store.mode == "sql" then
        Open77.database.insert("INSERT INTO rp_netrunner_log (netrunner, kind, target, `at`) VALUES (?, ?, ?, ?)",
            { identifier, kind, entry.target, entry.at }, function() end)
    else
        Open77.kvp.set(kvpKey(identifier), json.encode(entries))
    end
    print(("[rp_netrunner] player %d %s target=%s"):format(player, kind, entry.target ~= "" and entry.target or "-"))
end

-- ---------------------------------------------------------------------------
-- Traces: with Config.traceChance the NCPD gets a record and a dispatch alert
-- ---------------------------------------------------------------------------

local function leaveTrace(player, kind, position)
    if math.random() >= Config.traceChance then return false end
    position = position or Open77.players.position(player) or { x = 0, y = 0, z = 0 }
    local text = ("%s at %.0f, %.0f"):format(kind, position.x, position.y)
    local ok, reason = rp("rp_ncpd", "addRecord", player, "netrunner", text, 0)
    if not ok then print(("[rp_netrunner] rp_ncpd:addRecord refused: %s"):format(tostring(reason))) end
    TriggerEvent("rp_ncpd:alert", "netrunner", { x = position.x, y = position.y, z = position.z },
        "Netrunning activity detected", 0)
    warn(player, "TRACE WARNING: NCPD ICE logged your signature.")
    print(("[rp_netrunner] trace player %d %s"):format(player, text))
    return true
end

-- ---------------------------------------------------------------------------
-- The cyberdeck: definition, state, loading a grade
-- ---------------------------------------------------------------------------

local function defineDeck()
    local hackGrades, implantGrades = {}, {}
    for _, kind in ipairs(HACK_KINDS) do
        local h = Config.hacks[kind]
        local grade = {
            id = kind, kind = kind, range = h.range, uploadMs = h.uploadMs, staminaCost = h.staminaCost,
            cooldownMs = Config.cooldownMs, damage = h.damage, statusMs = h.statusMs,
            recoveryMs = h.recoveryMs, nonlethal = h.nonlethal == true, lockHacking = false,
        }
        if kind == "overheat" and h.burn then grade.burn = h.burn end
        hackGrades[#hackGrades + 1] = grade
        -- The implant schema is shared by every slot: the punch fields must be present and inert.
        implantGrades[#implantGrades + 1] = {
            id = kind, normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
        }
    end
    local ok, reason = Open77.hacking.define({ id = Config.deck.id, version = Config.deck.version, grades = hackGrades })
    if not ok then
        state.deckDefined, state.deckReason = false, "hacking:" .. tostring(reason)
        print("[rp_netrunner] Open77.hacking.define refused: " .. tostring(reason))
        return
    end
    local ok2, reason2 = Open77.cyberware.define({
        id = Config.deck.id, version = Config.deck.version, slot = "operating_system", profile = "cyberdeck",
        grades = implantGrades,
    })
    if not ok2 then
        state.deckDefined, state.deckReason = false, "cyberware:" .. tostring(reason2)
        print("[rp_netrunner] Open77.cyberware.define refused: " .. tostring(reason2))
        return
    end
    state.deckDefined, state.deckReason = true, nil
    print(("[rp_netrunner] deck %s v%d defined: %s"):format(Config.deck.id, Config.deck.version, table.concat(HACK_KINDS, ", ")))
end

-- The implant in the operating_system slot, whatever field name the record uses for it.
local function findImplant(record, slot)
    local direct = record[slot]
    if type(direct) == "table" then return direct end
    for _, value in pairs(record) do
        if type(value) == "table" and value.slot == slot then return value end
    end
    return nil
end

-- "unavailable", reason | "none" | "foreign", definitionId | "loaded", gradeId, record
local function deckState(player)
    if not state.deckDefined then return "unavailable", state.deckReason end
    local record, reason = Open77.cyberware.current(player)
    if not record then return "unavailable", reason or "record_not_ready" end
    local implant = findImplant(record, "operating_system")
    if not implant then return "none", nil, record end
    if implant.definition ~= Config.deck.id then return "foreign", implant.definition, record end
    return "loaded", implant.grade and implant.grade.id or "?", record
end

local function loadDeck(player, gradeId, record)
    if pendingDeck[player] then
        warn(player, ("Your deck is still committing %s. Wait for 'Deck ready'."):format(Config.hacks[pendingDeck[player].grade].label))
        return false
    end
    if Config.deck.price > 0 then
        local paid, why = rp("rp_economy", "remove", player, Config.deck.price, "netrunner:deck")
        if not paid then
            warn(player, ("Loading a grade costs %d eddies (%s)."):format(Config.deck.price, tostring(why)))
            return false
        end
    end
    local operationId, err = Open77.cyberware.newOperationId()
    if not operationId then warn(player, "No operation id (" .. tostring(err) .. ")."); return false end
    local result, reason = Open77.cyberware.install(player, Config.deck.id, gradeId,
        { expectedRevision = record.revision, operationId = operationId })
    if not result then
        warn(player, ("The ripper's chair refused the deck (%s)."):format(tostring(reason)))
        if Config.deck.price > 0 then rp("rp_economy", "add", player, Config.deck.price, "netrunner:deck_refund") end
        return false
    end
    if result.ticket then
        pendingDeck[player] = { ticket = result.ticket, grade = gradeId }
        say(player, ("Loading %s into your deck... run the hack again when it says 'Deck ready'."):format(Config.hacks[gradeId].label))
    else
        say(player, ("Deck ready: %s already loaded."):format(Config.hacks[gradeId].label))
    end
    return true
end

AddEventHandler("onCyberwareOperationCompleted", function(playerId, ticket, encoded)
    local player = tonumber(playerId)
    local pending = player and pendingDeck[player]
    if not pending or pending.ticket ~= ticket then return end
    pendingDeck[player] = nil
    local result = json.decode(encoded) or {}
    if result.ok then
        say(player, ("Deck ready: %s loaded."):format(Config.hacks[pending.grade].label))
        print(("[rp_netrunner] player %d deck grade=%s installed"):format(player, pending.grade))
    else
        warn(player, ("Deck load failed: %s."):format(tostring(result.error)))
        if Config.deck.price > 0 then rp("rp_economy", "add", player, Config.deck.price, "netrunner:deck_refund") end
    end
end)

-- Makes sure the deck holds `kind`; returns true when the hack may start now.
local function ensureDeck(player, kind)
    local st, detail, record = deckState(player)
    if st == "unavailable" then
        if detail == "record_not_ready" then
            warn(player, "Your implant record is not ready: the character adapter (open77_appearance) has not bound you yet, or no database runs. Try again in a moment.")
        else
            warn(player, ("Cyberdeck framework offline (%s): the operating-system implant cannot be read, so the kit refuses every upload."):format(tostring(detail)))
        end
        return false
    end
    if st == "foreign" then
        warn(player, ("Your operating system slot holds %s, not the netrunner deck. /netrun deck %s replaces it."):format(tostring(detail), kind))
        return false
    end
    if st == "loaded" and detail == kind then return true end
    loadDeck(player, kind, record)
    return false
end

-- ---------------------------------------------------------------------------
-- Contract: Ping
-- ---------------------------------------------------------------------------

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

local STAGE = Config.Stage or {}
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

local function doPing(player, rawTarget)
    if not gate(player) then return end
    local target = resolveTarget(player, rawTarget, Config.ping.range)
    if not target then return end
    if not checkCooldown(player, "ping", "Ping") then return end
    if not hasItem(player, Config.ping.item) then return end
    if not takeItem(player, Config.ping.item) then return end
    setCooldown(player, "ping")
    gesture(player, "ping")

    local pos = Open77.players.position(target) or Open77.players.position(player) or { x = 0, y = 0, z = 0 }
    local name = displayName(target)
    TriggerClientEvent("rp_netrunner:ping", player, target, name, { x = pos.x, y = pos.y, z = pos.z })
    say(player, ("Ping on %s: tracked on your map for %d s."):format(name, Config.ping.durationMs // 1000))
    if Config.ping.warnTarget then warn(target, "Your optics flicker for a second.") end

    pings[player] = pings[player] or {}
    local token = {}
    pings[player][target] = token
    CreateThread(function()
        local deadline = now() + Config.ping.durationMs / 1000
        while now() < deadline do
            Wait(Config.ping.refreshMs)
            if not pings[player] or pings[player][target] ~= token then return end
            if not Open77.players.name(player) then return end
            local p = Open77.players.position(target)
            if not p or not Open77.players.name(target) then break end
            TriggerClientEvent("rp_netrunner:pingUpdate", player, target, { x = p.x, y = p.y, z = p.z })
        end
        if pings[player] and pings[player][target] == token then pings[player][target] = nil end
        if Open77.players.name(player) then
            TriggerClientEvent("rp_netrunner:pingEnd", player, target)
            say(player, ("Ping on %s faded."):format(name))
        end
    end)

    appendLog(player, "ping", Open77.players.identifier(target))
    leaveTrace(player, "ping", Open77.players.position(player))
end

-- ---------------------------------------------------------------------------
-- Contract: Short Circuit / Overheat (the platform hacking kit)
-- ---------------------------------------------------------------------------

local function doHack(player, kind, rawTarget)
    local hack = Config.hacks[kind]
    if not hack then return end
    if not gate(player) then return end
    local target, metres = resolveTarget(player, rawTarget, hack.range)
    if not target then return end
    if not checkCooldown(player, kind, hack.label) then return end
    if not hasItem(player, hack.item) then return end
    if not ensureDeck(player, kind) then return end

    local operationId = ("rp_netrunner:%s:%d:%d:%d"):format(kind, player, target, math.floor(Open77.time.unix() * 1000))
    local result, reason = Open77.hacking.start(player, target, Config.deck.id, kind, { operationId = operationId })
    if not result then
        warn(player, ("%s refused: %s."):format(hack.label, tostring(reason)))
        return
    end
    takeItem(player, hack.item)
    setCooldown(player, kind)
    actions[result.actionId] = { player = player, kind = kind, target = target, name = displayName(target) }
    say(player, ("%s uploading on %s (%.0f m). Keep line of sight: the kit warns them."):format(hack.label, displayName(target), metres))
    appendLog(player, kind, Open77.players.identifier(target))
    leaveTrace(player, kind, Open77.players.position(player))
end

-- The hacking ledger: tell the netrunner how the upload ended.
AddEventHandler("onHackingTransition", function(encoded)
    local t = json.decode(encoded)
    if type(t) ~= "table" or t.definition ~= Config.deck.id then return end
    local entry = actions[t.actionId]
    if not entry then return end
    local label = Config.hacks[entry.kind] and Config.hacks[entry.kind].label or tostring(t.kind)
    if t.phase == "impact" then
        say(entry.player, ("%s landed on %s."):format(label, entry.name))
    elseif t.phase == "blocked" or t.phase == "interrupted" then
        warn(entry.player, ("%s %s (%s)."):format(label, t.phase, tostring(t.reason or "?")))
        actions[t.actionId] = nil
    elseif t.phase == "status_expired" or t.phase == "status_purged" or t.phase == "completed" then
        actions[t.actionId] = nil
    end
end)

-- ---------------------------------------------------------------------------
-- Contract: Jam NCPD radio
-- ---------------------------------------------------------------------------

local function officersOnDuty()
    local list = rp("rp_jobs", "listOnDuty", "ncpd")
    return type(list) == "table" and list or {}
end

local function isJamming()
    return state.jam ~= nil and now() < state.jam.deadline
end

local function doJam(player)
    if not gate(player) then return end
    if isJamming() then
        warn(player, ("A jammer is already burning (%s left)."):format(fmtSeconds(state.jam.deadline - now())))
        return
    end
    if not checkCooldown(player, "jam", "Jammer") then return end
    if not hasItem(player, Config.jam.item) then return end
    if not takeItem(player, Config.jam.item) then return end
    setCooldown(player, "jam")

    state.jam = { deadline = now() + Config.jam.durationMs / 1000, by = player, byName = displayName(player) }
    gesture(player, "jam")
    TriggerEvent("rp_netrunner:jammed", true)
    say(player, ("Jammer live: NCPD radio is static for %d s."):format(Config.jam.durationMs // 1000))
    print(("[rp_netrunner] jam started by player %d for %d ms"):format(player, Config.jam.durationMs))
    appendLog(player, "jam", "")
    local origin = Open77.players.position(player)

    CreateThread(function()
        local jam = state.jam
        while state.jam == jam and now() < jam.deadline do
            local line = Config.jam.noise[math.random(#Config.jam.noise)]
            for _, officer in ipairs(officersOnDuty()) do
                Open77.chat.send(officer, { type = "system", author = "NCPD RADIO", text = line, color = Config.colors.static })
            end
            Wait(Config.jam.noiseEveryMs)
        end
        if state.jam ~= jam then return end
        state.jam = nil
        TriggerEvent("rp_netrunner:jammed", false)
        print("[rp_netrunner] jam ended")
        if Open77.players.name(player) then
            say(player, "Jammer burned out. NCPD radio is clear again.")
            -- The trace surfaces once the static clears: dispatch could not read it before.
            leaveTrace(player, "jam", origin)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Contract: Breach the access point
-- ---------------------------------------------------------------------------

-- setLocked(false) then setOpen(true) on a door; returns ok, reason.
local function authoritativeOpen(doorId, bucket)
    local ok, reason = callExport("open77_doors", "setLocked", doorId, bucket, false)
    if not ok then return nil, reason end
    return callExport("open77_doors", "setOpen", doorId, bucket, true)
end

-- Opens the nearest networked door within Config.breach.doorRadius.
-- Returns "opened", door | "requested", door | "none" | "unavailable", reason
local function breachNearestDoor(player, pos, bucket)
    local res, reason = callExport("open77_doors", "near", pos, bucket, Config.breach.doorRadius)
    if type(res) ~= "table" then return "unavailable", reason or "no_answer" end
    local best, bestD
    for _, door in ipairs(res.doors or {}) do
        if not door.lift and door.position then
            local d = planar(pos, door.position)
            if not bestD or d < bestD then best, bestD = door, d end
        end
    end
    if not best then return "none" end
    local ok, why = authoritativeOpen(best.id, bucket)
    if not ok and why == "not_owner" then
        local claimed, claimWhy = callExport("open77_doors", "register", { id = best.id, bucket = bucket, position = best.position })
        if claimed then
            claimedDoors[best.id] = bucket
            SetTimeout(Config.breach.doorHoldMs, function()
                if claimedDoors[best.id] ~= nil then
                    claimedDoors[best.id] = nil
                    callExport("open77_doors", "remove", best.id, bucket)
                end
            end)
            ok, why = authoritativeOpen(best.id, bucket)
        else
            why = claimWhy or why
        end
    end
    if ok then return "opened", best end
    -- The service will not let this resource drive the door: fall back to the player's own request.
    print(("[rp_netrunner] door %s: server open refused (%s), asking the client"):format(tostring(best.id), tostring(why)))
    TriggerClientEvent("rp_netrunner:requestDoor", player, best.id)
    return "requested", best
end

local function payBounty(player)
    local paid, why = rp("rp_economy", "add", player, Config.breach.bounty, "netrunner:breach")
    if paid then
        say(player, ("No networked door on this subnet. You siphon the node's data instead: +%d eddies (data bounty)."):format(Config.breach.bounty))
    else
        warn(player, ("Data siphoned, but the wallet refused the bounty (%s)."):format(tostring(why)))
    end
    if Config.breach.societyBounty > 0 then
        local ok, reason = rp("rp_bank", "societyAdd", Config.job, Config.breach.societyBounty, "breach")
        if not ok then print("[rp_netrunner] societyAdd refused: " .. tostring(reason)) end
    end
end

local function doBreach(player)
    if not gate(player) then return end
    local ap = Config.accessPoint
    local metres, reason = Open77.players.distance(player, ap.position)
    if not metres then warn(player, "Cannot place you (" .. tostring(reason) .. ")."); return end
    if metres > ap.reach then
        warn(player, ("No access point here (%.0f m). The nearest one is at %.0f, %.0f."):format(metres, ap.position.x, ap.position.y))
        return
    end
    if breaching[player] then warn(player, "You are already jacked in."); return end
    if not checkCooldown(player, "breach", "Breach") then return end
    if not hasItem(player, Config.breach.item) then return end

    breaching[player] = true
    say(player, "Jacking in... hold still (X aborts).")
    -- Staged: the typing pose and the deck in front of the chest for the whole bar.
    local answer, why = stage(player, "breach", { label = "Breaching...", durationMs = Config.breach.durationMs })
    breaching[player] = nil
    if not Open77.players.name(player) then return end
    if not answer then warn(player, ("Breach failed: the bar never opened (%s)."):format(tostring(why))); return end
    if not answer.ok then warn(player, "Breach aborted. The ICE never saw you."); return end
    if Open77.players.isDead(player) then return end
    if not takeItem(player, Config.breach.item) then return end
    setCooldown(player, "breach")

    local pos = Open77.players.position(player) or ap.position
    local outcome, door = breachNearestDoor(player, pos, pos.bucket or 0)
    if outcome == "opened" then
        say(player, ("Access granted: door %s unlocked and opened."):format(tostring(door.id)))
        appendLog(player, "breach", "door:" .. tostring(door.id))
    elseif outcome == "requested" then
        say(player, ("Door %s found: your request is queued, the door service answers in a moment."):format(tostring(door.id)))
        appendLog(player, "breach", "door:" .. tostring(door.id))
    else
        if outcome == "unavailable" then
            print(("[rp_netrunner] breach by player %d: door service unavailable (%s), paying the data bounty"):format(player, tostring(door)))
        else
            print(("[rp_netrunner] breach by player %d: no door within %.0f m, paying the data bounty"):format(player, Config.breach.doorRadius))
        end
        payBounty(player)
        appendLog(player, "breach", "bounty")
    end
    leaveTrace(player, "breach", pos)
end

RegisterNetEvent("rp_netrunner:doorResult", function(doorId, accepted, reason)
    if accepted then
        say(source, ("Door %s answered: open."):format(tostring(doorId)))
    else
        warn(source, ("Door %s refused your request (%s)."):format(tostring(doorId), tostring(reason)))
    end
end)

-- ---------------------------------------------------------------------------
-- /netrun status and deck loading
-- ---------------------------------------------------------------------------

local function statusLines(player)
    local lines = {}
    local ok, why = netrunnerOnDuty(player)
    lines[#lines + 1] = ok and "NETRUN - netrunner on duty." or ("NETRUN - " .. (why == "not_netrunner" and "not a netrunner" or why == "off_duty" and "netrunner, off duty" or ("jobs offline: " .. tostring(why))) .. ".")

    local st, detail = deckState(player)
    if st == "unavailable" then lines[#lines + 1] = ("Implant: cyberdeck framework unavailable (%s). Hacks gated on the job only."):format(tostring(detail))
    elseif st == "none" then lines[#lines + 1] = "Implant: no operating system. /netrun deck short_circuit loads one."
    elseif st == "foreign" then lines[#lines + 1] = ("Implant: %s in the OS slot (not the netrunner deck)."):format(tostring(detail))
    else lines[#lines + 1] = ("Implant: netrunner deck loaded with %s.%s"):format(Config.hacks[detail] and Config.hacks[detail].label or tostring(detail), pendingDeck[player] and " (reloading...)" or "") end

    local pockets = {}
    for _, id in ipairs({ "qh_ping", "qh_short_circuit", "qh_overheat", "qh_jammer" }) do
        local n = rp("rp_inventory", "count", player, id)
        pockets[#pockets + 1] = ("%s x%d"):format(itemLabel(id), tonumber(n) or 0)
    end
    if Config.breach.item then
        pockets[#pockets + 1] = ("%s x%d"):format(Config.breach.item, tonumber(rp("rp_inventory", "count", player, Config.breach.item)) or 0)
    end
    lines[#lines + 1] = "Pockets: " .. table.concat(pockets, ", ")

    local cds = {}
    for _, kind in ipairs({ "ping", "short_circuit", "overheat", "jam", "breach" }) do
        local left = cooldownLeft(player, kind)
        if left > 0 then cds[#cds + 1] = ("%s %s"):format(kind, fmtSeconds(left)) end
    end
    lines[#lines + 1] = "Cooldowns: " .. (#cds > 0 and table.concat(cds, ", ") or "all clear")

    -- The platform's own ledger: is somebody's hack still gating this netrunner?
    local kit = Open77.hacking.state(player)
    if type(kit) == "table" then
        local gates = {}
        for _, field in ipairs({ "cyberwareSuspendedMs", "malfunctionMs", "frozenMs", "crippledMs", "blindedMs", "weaponGlitchedMs" }) do
            local ms = tonumber(kit[field]) or 0
            if ms > 0 then gates[#gates + 1] = ("%s %s"):format(field:gsub("Ms$", ""), fmtSeconds(ms / 1000)) end
        end
        if #gates > 0 then lines[#lines + 1] = "Kit: hacked - " .. table.concat(gates, ", ") end
    end

    local identifier = identifiers[player]
    local entries = identifier and logs[identifier] or {}
    local byKind = {}
    for _, e in ipairs(entries) do byKind[e.kind] = (byKind[e.kind] or 0) + 1 end
    local parts = {}
    for _, kind in ipairs({ "ping", "short_circuit", "overheat", "jam", "breach" }) do
        if byKind[kind] then parts[#parts + 1] = ("%s %d"):format(kind, byKind[kind]) end
    end
    lines[#lines + 1] = ("Contracts done: %d%s (store: %s)"):format(identifier and (counts[identifier] or 0) or 0,
        #parts > 0 and (" - " .. table.concat(parts, ", ")) or "", store.mode)
    if isJamming() then
        lines[#lines + 1] = ("NCPD radio jammed by %s: %s left."):format(state.jam.byName, fmtSeconds(state.jam.deadline - now()))
    end
    return lines
end

local function doNetrun(player, args)
    if args[1] == "deck" then
        if not gate(player) then return end
        local kind = args[2] or "short_circuit"
        if not Config.hacks[kind] then
            warn(player, "Grades: /netrun deck short_circuit | overheat")
            return
        end
        local st, detail, record = deckState(player)
        if st == "unavailable" then
            warn(player, ("Cyberdeck framework offline (%s)."):format(tostring(detail)))
            return
        end
        if st == "loaded" and detail == kind then say(player, ("Deck ready: %s already loaded."):format(Config.hacks[kind].label)); return end
        loadDeck(player, kind, record)
        return
    end
    CreateThread(function()
        for _, line in ipairs(statusLines(player)) do
            say(player, line)
            Wait(0)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Commands, net events, ALT+click dispatch
-- ---------------------------------------------------------------------------

local function fromGame(source, name)
    if source == 0 then print(("%s: run it from the game"):format(name)); return false end
    return true
end

RegisterCommand("netrun", function(source, args)
    if not fromGame(source, "netrun") then return end
    doNetrun(source, args)
end, false)

RegisterCommand("ping", function(source, args)
    if not fromGame(source, "ping") then return end
    doPing(source, args[1])
end, false)

RegisterCommand("court_circuit", function(source, args)
    if not fromGame(source, "court_circuit") then return end
    doHack(source, "short_circuit", args[1])
end, false)

RegisterCommand("surchauffe", function(source, args)
    if not fromGame(source, "surchauffe") then return end
    doHack(source, "overheat", args[1])
end, false)

RegisterCommand("brouiller", function(source)
    if not fromGame(source, "brouiller") then return end
    doJam(source)
end, false)

RegisterCommand("breach", function(source)
    if not fromGame(source, "breach") then return end
    doBreach(source)
end, false)

-- ALT+click on a player (client context menu): only the kind and the target id cross.
RegisterNetEvent("rp_netrunner:action", function(kind, targetId)
    if source <= 0 then return end
    if kind == "ping" then doPing(source, targetId)
    elseif kind == "short_circuit" or kind == "overheat" then doHack(source, kind, targetId)
    end
end)

-- The access-point prompt (open77_worldui) and /breach share one path.
RegisterNetEvent("rp_netrunner:breach", function()
    if source <= 0 then return end
    doBreach(source)
end)

-- Duty state pushed to the client so the ALT+click entries only show for an on-duty netrunner.
local function pushSelf(player)
    if not player or player <= 0 or not Open77.players.name(player) then return end
    TriggerClientEvent("rp_netrunner:self", player, netrunnerOnDuty(player) == true)
end

RegisterNetEvent("rp_netrunner:clientReady", function() pushSelf(source) end)
AddEventHandler("rp_jobs:duty", function(playerId) pushSelf(tonumber(playerId)) end)
AddEventHandler("rp_jobs:changed", function(playerId) pushSelf(tonumber(playerId)) end)

-- ---------------------------------------------------------------------------
-- Exports (synchronous: nothing here yields)
-- ---------------------------------------------------------------------------

exports("isJamming", function()
    return isJamming()
end)

exports("trace", function(playerId)
    local player = tonumber(playerId)
    local identifier = player and identifiers[player] or nil
    local entries = {}
    for i, e in ipairs(identifier and logs[identifier] or {}) do
        entries[i] = { kind = e.kind, target = e.target, at = e.at }
    end
    return { entries = entries }
end)

-- ---------------------------------------------------------------------------
-- Chat suggestions, items, the terminal prop, lifecycle
-- ---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/netrun", help = "Netrunner status: implant, quickhacks, cooldowns, contracts", parameters = { { name = "deck [short_circuit|overheat]", help = "load a grade into your deck" } } },
    { command = "/ping", help = "Ping a player: a 60 s tracking blip on your map", parameters = { { name = "playerId", help = "target session id" } } },
    { command = "/court_circuit", help = "Short Circuit a player within 25 m (line of sight)", parameters = { { name = "playerId", help = "target session id" } } },
    { command = "/surchauffe", help = "Overheat a player within 25 m (line of sight)", parameters = { { name = "playerId", help = "target session id" } } },
    { command = "/brouiller", help = "Jam the NCPD radio for 60 s" },
    { command = "/breach", help = "Breach the access point you stand at (10 s)" },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

local function describeDefine(value)
    if type(value) == "table" then return tostring(#value) end
    return tostring(value)
end

local function defineItems()
    local ok, registered, rejected = pcall(function() return exports.rp_inventory:define(Config.items) end)
    if not ok then
        print("[rp_netrunner] rp_inventory not running: quickhacks not registered (" .. tostring(registered) .. ")")
        return
    end
    print(("[rp_netrunner] quickhacks registered=%s rejected=%s"):format(describeDefine(registered), describeDefine(rejected)))
end

local function spawnTerminal()
    local ap = Config.accessPoint
    local prop = ap.prop
    if not prop or prop.model == false then return end
    local offset = prop.offset or {}
    local def = {
        model = prop.model,
        position = { x = ap.position.x + (offset.x or 0), y = ap.position.y + (offset.y or 0), z = ap.position.z + (offset.z or 0) },
        yaw = prop.yaw or 0,
        streamingRadius = 120.0,
    }
    local id, reason = Open77.props.create(def)
    if not id and (reason == "unknown_alias" or reason == "invalid_model") and prop.fallbackModel then
        print(("[rp_netrunner] prop alias %s refused (%s), trying the depot mesh"):format(prop.model, reason))
        def.model = prop.fallbackModel
        id, reason = Open77.props.create(def)
    end
    if id then
        state.terminalProp = id
        print(("[rp_netrunner] access-point terminal prop %s at %.1f %.1f %.1f"):format(id, def.position.x, def.position.y, def.position.z))
    else
        print(("[rp_netrunner] terminal prop not spawned (%s): the ring alone marks the access point"):format(tostring(reason)))
    end
end

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" then defineItems(); return end
    if name ~= RESOURCE then return end
    print(("[rp_netrunner] started: job %s, cooldown %d s, trace chance %.0f%%, access point %.1f %.1f %.1f"):format(
        Config.job, Config.cooldownMs // 1000, Config.traceChance * 100,
        Config.accessPoint.position.x, Config.accessPoint.position.y, Config.accessPoint.position.z))
    initStore()
    defineDeck()
    defineItems()
    spawnTerminal()
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    for _, player in ipairs(Open77.players.all()) do
        identifiers[player] = Open77.players.identifier(player)
        CreateThread(function() loadPlayerLog(player) end)
        pushSelf(player)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    if state.jam then
        state.jam = nil
        TriggerEvent("rp_netrunner:jammed", false)
    end
    if state.terminalProp then
        Open77.props.remove(state.terminalProp)
        state.terminalProp = nil
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    local player = tonumber(playerId)
    if not player then return end
    identifiers[player] = Open77.players.identifier(player)
    loadPlayerLog(player)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local player = tonumber(playerId)
    if not player then return end
    cooldowns[player] = nil
    pings[player] = nil
    pendingDeck[player] = nil
    breaching[player] = nil
    stageClear(player)
    local identifier = identifiers[player]
    identifiers[player] = nil
    if identifier then
        logs[identifier] = nil
        counts[identifier] = nil
    end
    for actionId, entry in pairs(actions) do
        if entry.player == player then actions[actionId] = nil end
    end
end)
