-- rp_mecano / server: the garage job.
-- Everything is decided here: who is a mechanic, which vehicle is meant, what an
-- invoice costs and where the eddies go. Clients only render and request.

local RES = GetCurrentResourceName()
local C = Config

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_mecano] " .. fmt):format(...))
end

-- One line of chat to a player; the console gets a print.
local function say(playerId, text)
    if playerId == nil or playerId == 0 then
        print("[rp_mecano] " .. text)
        return
    end
    Open77.chat.send(playerId, text)
end

-- Calls exports.<res>:<name>(...) inside pcall. Returns ok, r1, r2:
-- ok = false means the resource or export is missing (r1 carries the reason).
local function ex(res, name, ...)
    local args = table.pack(...)
    local ok, r1, r2 = pcall(function()
        return exports[res][name](table.unpack(args, 1, args.n))
    end)
    if not ok then
        return false, "unavailable:" .. res, tostring(r1)
    end
    return true, r1, r2
end

local function playerName(playerId)
    local ok, full = ex("rp_identity", "fullName", playerId)
    if ok and type(full) == "string" and full ~= "" then
        return full
    end
    return Open77.players.name(playerId) or ("#" .. tostring(playerId))
end

local function isInteger(n)
    return type(n) == "number" and n == math.floor(n)
end

local function planarDistance(a, b)
    if not a or not b then return math.huge end
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function fmtMoney(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^%s+", "")) .. " €$"
end

-- The display name of a canonical vehicle, from the shipped catalogue.
local function vehicleLabel(snapshot)
    if not snapshot then return "vehicle" end
    local data = Open77.data.vehicle(snapshot.record)
    if data and type(data.displayName) == "string" and data.displayName ~= "" then
        return data.displayName
    end
    local short = tostring(snapshot.record):gsub("^Vehicle%.", "")
    return short
end

-- The plate is a state-bag key (state-bags guide, "Recipe: a number plate").
local function vehiclePlate(vehicleId)
    local bag = Open77.state.entity("vehicle", vehicleId)
    if not bag then return nil end
    local plate = bag:get("plate")
    if type(plate) == "string" and plate ~= "" then
        return plate
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Job gate: an on-duty mechanic, or a chat line saying why not.
-- ---------------------------------------------------------------------------

local function mechanicCheck(playerId)
    local ok, has = ex("rp_jobs", "hasJob", playerId, C.job)
    if not ok then
        return nil, "The job board is offline (rp_jobs). Try again in a moment."
    end
    if not has then
        return nil, "You are no mechanic, choom. /agence to sign with the garage."
    end
    local ok2, duty = ex("rp_jobs", "onDuty", playerId)
    if not ok2 then
        return nil, "The job board is offline (rp_jobs). Try again in a moment."
    end
    if not duty then
        return nil, "Clock in first: /service."
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Finding the vehicle a command means
-- ---------------------------------------------------------------------------

-- The vehicle the player sits in, else the nearest registered one within `reach`.
-- Returns vehicleId, distance, seated | nil, reason.
local function vehicleNear(playerId, reach, options)
    options = options or {}
    if not options.excludeSeated then
        local seat = Open77.vehicles.getPlayerSeat(playerId)
        if seat and seat.vehicleId then
            return seat.vehicleId, 0.0, true
        end
    end
    local entry = Open77.vehicles.closest(playerId, { radius = reach, occupied = options.occupied })
    if not entry then
        return nil, "no_vehicle"
    end
    return entry.id, entry.distance, false
end

-- A vehicle id chosen from the ALT+click menu: must exist and be within reach.
local function vehicleExplicit(playerId, vehicleId, reach)
    if not isInteger(vehicleId) then
        return nil, "invalid_vehicle_id"
    end
    local pos = Open77.vehicles.getPosition(vehicleId)
    if not pos then
        return nil, "vehicle_not_found"
    end
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    if seat and seat.vehicleId == vehicleId then
        return vehicleId, 0.0, true
    end
    local me = Open77.players.position(playerId)
    local d = planarDistance(me, pos)
    if d > reach then
        return nil, "too_far", d
    end
    return vehicleId, d, false
end

local NO_VEHICLE = "No server vehicle within reach. Vanilla traffic does not count: spawn one with /car."

-- ---------------------------------------------------------------------------
-- Persistence: SQL first, kvp only when the database never answers.
-- ---------------------------------------------------------------------------

local store = "pending" -- "sql" | "kvp"

local function useKvp(reason)
    if store ~= "pending" then return end
    store = "kvp"
    log("store=kvp reason=%s (impound / invoice ledger kept in the resource kvp store)", tostring(reason))
end

local function setupDatabase()
    local ok, reason = Open77.database.ready(function()
        Open77.database.update([[
            CREATE TABLE IF NOT EXISTS rp_mecano_impound (
                id            INT AUTO_INCREMENT PRIMARY KEY,
                vehicle_id    BIGINT       NOT NULL,
                record        VARCHAR(256) NOT NULL,
                plate         VARCHAR(16)  NULL,
                x             DOUBLE       NOT NULL DEFAULT 0,
                y             DOUBLE       NOT NULL DEFAULT 0,
                z             DOUBLE       NOT NULL DEFAULT 0,
                by_identifier VARCHAR(64)  NOT NULL,
                by_name       VARCHAR(80)  NOT NULL DEFAULT '',
                fee           INT          NOT NULL DEFAULT 0,
                at            BIGINT       NOT NULL
            )
        ]], {}, function()
            Open77.database.update([[
                CREATE TABLE IF NOT EXISTS rp_mecano_invoices (
                    id              INT AUTO_INCREMENT PRIMARY KEY,
                    from_identifier VARCHAR(64)  NOT NULL,
                    to_identifier   VARCHAR(64)  NOT NULL,
                    amount          INT          NOT NULL,
                    reason          VARCHAR(64)  NOT NULL DEFAULT '',
                    status          VARCHAR(48)  NOT NULL,
                    at              BIGINT       NOT NULL
                )
            ]], {}, function()
                if store == "pending" then
                    store = "sql"
                    log("store=sql tables=rp_mecano_impound,rp_mecano_invoices")
                end
            end)
        end)
    end)
    if not ok then
        useKvp(reason)
        return
    end
    -- A database that is configured but never answers: do not stay pending forever.
    SetTimeout(15000, function()
        if store == "pending" then
            useKvp("database not answering after 15 s")
        end
    end)
end

local function kvpAppend(prefix, line)
    local n = tonumber(Open77.kvp.get(prefix .. ":count", 0)) or 0
    n = n + 1
    Open77.kvp.set(prefix .. ":count", n)
    Open77.kvp.set(prefix .. ":" .. n, line)
    return n
end

local function persistImpound(row)
    if store == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_mecano_impound (vehicle_id, record, plate, x, y, z, by_identifier, by_name, fee, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            { row.vehicleId, row.record, row.plate, row.x, row.y, row.z, row.byIdentifier, row.byName, row.fee, row.at },
            function(insertId)
                log("impound row %s: vehicle %s (%s) plate=%s by %s", tostring(insertId), tostring(row.vehicleId),
                    row.record, tostring(row.plate), row.byIdentifier)
            end)
        return
    end
    local line = table.concat({
        tostring(row.vehicleId), row.record, tostring(row.plate or ""),
        string.format("%.2f", row.x), string.format("%.2f", row.y), string.format("%.2f", row.z),
        row.byIdentifier, row.byName, tostring(row.fee), tostring(row.at),
    }, "|")
    local n = kvpAppend("impound", line)
    log("impound kvp row %d: vehicle %s (%s) plate=%s by %s", n, tostring(row.vehicleId), row.record,
        tostring(row.plate), row.byIdentifier)
end

local function persistInvoice(row)
    if store == "sql" then
        Open77.database.insert(
            "INSERT INTO rp_mecano_invoices (from_identifier, to_identifier, amount, reason, status, at) VALUES (?, ?, ?, ?, ?, ?)",
            { row.fromIdentifier, row.toIdentifier, row.amount, row.reason, row.status, row.at },
            function() end)
        return
    end
    kvpAppend("invoice", table.concat({
        row.fromIdentifier, row.toIdentifier, tostring(row.amount), row.reason, row.status, tostring(row.at),
    }, "|"))
end

-- The last five impound entries, as chat lines (a tester's proof of persistence).
local function impoundRegister(playerId)
    if store == "sql" then
        Open77.database.query(
            "SELECT vehicle_id, record, plate, by_name, at FROM rp_mecano_impound ORDER BY id DESC LIMIT 5",
            {}, function(rows)
                if not rows or #rows == 0 then
                    return say(playerId, "Impound register: empty. The lot is clean.")
                end
                say(playerId, ("Impound register, last %d:"):format(#rows))
                for _, r in ipairs(rows) do
                    say(playerId, ("  #%s %s plate=%s by %s"):format(tostring(r.vehicle_id), tostring(r.record),
                        tostring(r.plate or "none"), tostring(r.by_name)))
                end
            end)
        return
    end
    local n = tonumber(Open77.kvp.get("impound:count", 0)) or 0
    if n == 0 then
        return say(playerId, "Impound register: empty. The lot is clean.")
    end
    say(playerId, ("Impound register (kvp), last %d:"):format(math.min(5, n)))
    for i = n, math.max(1, n - 4), -1 do
        say(playerId, "  " .. tostring(Open77.kvp.get("impound:" .. i, "?")))
    end
end

-- ---------------------------------------------------------------------------
-- Items: register ours with rp_inventory (again whenever it restarts)
-- ---------------------------------------------------------------------------

local function defineItems()
    local ok, registered, rejected = ex("rp_inventory", "define", RpMecanoItems)
    if not ok then
        log("rp_inventory:define unavailable (%s): toolkit / paint_can not registered", tostring(registered))
        return
    end
    local names = {}
    if type(registered) == "table" then
        for _, id in ipairs(registered) do names[#names + 1] = tostring(id) end
    end
    log("items registered: %s (rejected: %s)", table.concat(names, ","),
        type(rejected) == "table" and tostring(#rejected) or tostring(rejected))
end

-- ---------------------------------------------------------------------------
-- The UI kit progress bar, through the server twin
-- ---------------------------------------------------------------------------

-- Returns the { ok, outcome } answer, or a plain wait when the kit is missing.
local function progress(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, definition)
    if not promise then
        log("uikit progress unavailable for player %d: %s", playerId, tostring(reason))
        say(playerId, ("Working... (%d s)"):format(math.floor(definition.duration / 1000)))
        Wait(definition.duration)
        return { ok = true, outcome = "ok", fallback = true }
    end
    local answer, err = promise:await()
    if not answer then
        return nil, err
    end
    return answer
end

-- ---------------------------------------------------------------------------
-- Invoices: the consent flow
-- ---------------------------------------------------------------------------

local bills = {}            -- billId -> bill
local billByTarget = {}     -- customer playerId -> billId
local billByInteraction = {} -- interaction id -> billId
local nextBillId = 0

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

local function recordInvoice(bill, status)
    persistInvoice({
        fromIdentifier = Open77.players.identifier(bill.from) or ("session:" .. tostring(bill.from)),
        toIdentifier = Open77.players.identifier(bill.to) or ("session:" .. tostring(bill.to)),
        amount = bill.amount,
        reason = bill.reason,
        status = status,
        at = math.floor(Open77.time.unix()),
    })
end

local function settle(billId, accepted, why)
    local bill = bills[billId]
    if not bill then return end
    bills[billId] = nil
    if billByTarget[bill.to] == billId then billByTarget[bill.to] = nil end
    if bill.interactionId then billByInteraction[bill.interactionId] = nil end

    local from, to = bill.from, bill.to
    local fromName, toName = playerName(from), playerName(to)
    local status

    if accepted then
        if bill.check then
            local ok, reason = bill.check(bill)
            if not ok then
                status = "void:" .. tostring(reason)
                say(from, ("Invoice #%d void: %s. No eddies moved."):format(billId, tostring(reason)))
                say(to, ("Invoice #%d from %s is void: %s. No eddies moved."):format(billId, fromName, tostring(reason)))
            end
        end
        if not status then
            local okc, newBalance, reason = ex("rp_economy", "remove", to, bill.amount, "mecano:bill:" .. tostring(from))
            if not okc then
                status = "refused:economy_offline"
                say(from, "The wallet service is offline (rp_economy): the invoice could not be cashed.")
                say(to, "The wallet service is offline (rp_economy): nothing was taken.")
            elseif not newBalance then
                status = "refused:" .. tostring(reason)
                if reason == "insufficient_funds" then
                    say(from, ("%s is short on eddies: invoice #%d of %s refused."):format(toName, billId, fmtMoney(bill.amount)))
                    say(to, ("You cannot cover %s in cash, choom. Invoice #%d refused; hit an ATM."):format(fmtMoney(bill.amount), billId))
                else
                    say(from, ("Invoice #%d refused by the wallet: %s."):format(billId, tostring(reason)))
                    say(to, ("Invoice #%d could not be paid: %s."):format(billId, tostring(reason)))
                end
            else
                status = "paid"
                local share = math.floor(bill.amount * C.bill.mechanicShare)
                local societyCut = bill.amount - share
                local oks, newSociety, sreason = true, nil, nil
                if societyCut > 0 then
                    oks, newSociety, sreason = ex("rp_bank", "societyAdd", C.society, societyCut, "bill:" .. tostring(from))
                    if not oks or not newSociety then
                        -- The bank is offline or refused: the garage cut goes to the mechanic
                        -- rather than vanishing.
                        log("societyAdd failed (%s): garage cut %d handed to the mechanic", tostring(newSociety or sreason), societyCut)
                        share = share + societyCut
                        societyCut = 0
                    end
                end
                if share > 0 then
                    local oka, nb, areason = ex("rp_economy", "add", from, share, "mecano:bill:" .. tostring(to))
                    if not oka or not nb then
                        log("rp_economy:add failed for mechanic %d: %s", from, tostring(nb or areason))
                    end
                end
                log("invoice #%d paid: %d from player %d to player %d (mechanic %d, society %d, %s)",
                    billId, bill.amount, to, from, share, societyCut, bill.reason)
                say(from, ("%s paid invoice #%d: %s. Your cut: %s, garage: %s."):format(
                    toName, billId, fmtMoney(bill.amount), fmtMoney(share), fmtMoney(societyCut)))
                say(to, ("Paid %s to %s (invoice #%d: %s). Cash left: %s."):format(
                    fmtMoney(bill.amount), fromName, billId, bill.reason, fmtMoney(newBalance)))
                if bill.apply then
                    local okApply, err = pcall(bill.apply, bill)
                    if not okApply then log("invoice #%d apply hook raised: %s", billId, tostring(err)) end
                end
            end
        end
    else
        status = "declined:" .. tostring(why or "declined")
        local detail = why and (" (" .. tostring(why) .. ")") or ""
        say(from, ("%s declined invoice #%d of %s%s."):format(toName, billId, fmtMoney(bill.amount), detail))
        say(to, ("Invoice #%d from %s declined%s."):format(billId, fromName, detail))
    end

    recordInvoice(bill, status)
    TriggerEvent("rp_mecano:bill", billId, from, to, bill.amount, status)
    if bill.onSettled then
        pcall(bill.onSettled, status == "paid", status)
    end
end

-- Starts an invoice. hooks: { check = fn(bill) -> true|nil,reason, apply = fn(bill), onSettled = fn(paid, status) }.
-- Returns billId | nil, reason. Never yields.
local function startBill(from, to, amount, reason, hooks)
    hooks = hooks or {}
    if not isInteger(from) or from < 1 then return nil, "invalid_from" end
    if not isInteger(to) or to < 1 then return nil, "invalid_to" end
    if from == to then return nil, "self_bill" end
    if not isInteger(amount) or amount < 1 then return nil, "invalid_amount" end
    if amount > C.bill.max then return nil, "amount_too_large" end
    if reason == nil or reason == "" then reason = "garage services" end
    if type(reason) ~= "string" then return nil, "invalid_reason" end
    reason = reason:sub(1, 64)
    if not Open77.players.name(to) then return nil, "player_not_found" end
    if not Open77.players.name(from) then return nil, "mechanic_not_found" end
    if billByTarget[to] then return nil, "target_busy" end

    nextBillId = nextBillId + 1
    local bill = {
        id = nextBillId, from = from, to = to, amount = amount, reason = reason,
        createdAt = Open77.time.unix(), check = hooks.check, apply = hooks.apply, onSettled = hooks.onSettled,
    }
    bills[bill.id] = bill
    billByTarget[to] = bill.id

    -- The mechanic types the bill on the holo (a one-shot gesture, no bar).
    gesture(from, "invoice")

    -- The platform consent prompt: reserves both players and asks the customer.
    local state, why = Open77.playerInteractions.request(from, to, "custom", {
        durationMs = 500,
        startDistance = math.min(10.0, C.bill.reach),
        breakDistance = math.min(20.0, math.max(C.bill.reach, C.bill.reach * 2)),
        inviteTimeoutMs = math.max(1000, math.min(60000, C.bill.timeoutMs)),
        consent = true,
    })
    local fromName = playerName(from)
    if state then
        bill.mode = "interaction"
        bill.interactionId = state.id
        billByInteraction[state.id] = bill.id
        say(to, ("%s hands you invoice #%d: %s (%s). Accept or decline the prompt, or /facture ok | /facture non."):format(
            fromName, bill.id, fmtMoney(amount), reason))
    else
        -- The customer is in a car, too far, or already reserved: the chat answers instead.
        bill.mode = "chat"
        log("invoice #%d: interaction refused (%s), chat consent", bill.id, tostring(why))
        say(to, ("%s sends you invoice #%d: %s (%s). /facture ok to pay, /facture non to refuse (%d s)."):format(
            fromName, bill.id, fmtMoney(amount), reason, math.floor(C.bill.timeoutMs / 1000)))
        local id = bill.id
        SetTimeout(C.bill.timeoutMs, function()
            if bills[id] then settle(id, false, "timeout") end
        end)
    end
    Open77.notifications.send(to, {
        type = "info",
        title = "Garage invoice",
        message = ("%s: %s (%s)"):format(fromName, fmtMoney(amount), reason),
        durationMs = 8000,
    })
    say(from, ("Invoice #%d of %s sent to %s (%s). Waiting for their answer."):format(
        bill.id, fmtMoney(amount), playerName(to), bill.mode == "interaction" and "prompt" or "chat"))
    log("invoice #%d: %d -> player %d, %d eddies, %s, mode=%s", bill.id, from, to, amount, reason, bill.mode)
    return bill.id
end

AddEventHandler("onPlayerInteractionCompleted", function(state)
    if type(state) ~= "table" then return end
    local billId = billByInteraction[state.id]
    if billId then settle(billId, true) end
end)

AddEventHandler("onPlayerInteractionCancelled", function(state)
    if type(state) ~= "table" then return end
    local billId = billByInteraction[state.id]
    if billId then settle(billId, false, state.reason) end
end)

-- The customer answers in chat (works in both modes; cancels the prompt if one is up).
local function answerBill(playerId, accepted)
    local billId = billByTarget[playerId]
    if not billId or not bills[billId] then
        return say(playerId, "No invoice waiting for you.")
    end
    local bill = bills[billId]
    if bill.interactionId then
        local iid = bill.interactionId
        bill.interactionId = nil
        billByInteraction[iid] = nil
        Open77.playerInteractions.cancel(iid, accepted and "paid_in_chat" or "declined_in_chat")
    end
    settle(billId, accepted, accepted and nil or "declined")
end

-- ---------------------------------------------------------------------------
-- /reparer
-- ---------------------------------------------------------------------------

local repairing = {} -- playerId -> vehicleId

local function needsRepair(vehicleId)
    local health = Open77.vehicles.getHealth(vehicleId)
    if health and health < 0.999 then return true end
    local damage = Open77.vehicles.getDamage(vehicleId)
    if not damage then return false end
    if (damage.glass or 0) ~= 0 or (damage.lights or 0) ~= 0 or (damage.tires or 0) ~= 0 then return true end
    if type(damage.body) == "table" then
        for _, cell in ipairs(damage.body) do
            if cell and cell > 0.001 then return true end
        end
    end
    return false
end

local function doRepair(source, explicitVehicleId)
    local okm, why = mechanicCheck(source)
    if not okm then return say(source, why) end
    if repairing[source] then return say(source, "You already have your hands in an engine.") end

    if C.repair.requireToolkit then
        local ok, has = ex("rp_inventory", "has", source, "toolkit", 1)
        if not ok then return say(source, "Your pockets are offline (rp_inventory).") end
        if not has then return say(source, "No Mechanic's toolkit in your pockets. Get one before touching a ride.") end
    end
    local okc, count = ex("rp_inventory", "count", source, "component")
    if not okc then return say(source, "Your pockets are offline (rp_inventory).") end
    if (tonumber(count) or 0) < C.repair.components then
        return say(source, ("You need %d components for a repair (you carry %d)."):format(C.repair.components, tonumber(count) or 0))
    end

    local vehicleId, dist, seated
    if explicitVehicleId then
        vehicleId, dist, seated = vehicleExplicit(source, explicitVehicleId, C.repair.reach)
        if not vehicleId then
            if dist == "too_far" then
                return say(source, ("Too far from that vehicle (%.1f m). Get within %d m."):format(seated or 0, C.repair.reach))
            end
            return say(source, NO_VEHICLE)
        end
    else
        vehicleId, dist, seated = vehicleNear(source, C.repair.reach)
        if not vehicleId then return say(source, NO_VEHICLE) end
    end

    local snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot then return say(source, NO_VEHICLE) end
    local label = vehicleLabel(snapshot)
    if snapshot.destroyed or snapshot.exploded then
        return say(source, ("That %s is a wreck. Nothing to fix, only scrap."):format(label))
    end
    if not needsRepair(vehicleId) then
        return say(source, ("The %s is in mint condition. Nothing to fix."):format(label))
    end

    repairing[source] = vehicleId
    -- Staged: kneel at the wheel, welder in hand, toolbox at the feet, for the whole bar.
    local answer, err = stage(source, "repair", { label = "Fixing the " .. label, durationMs = C.repair.durationMs })
    repairing[source] = nil
    if not answer then
        return say(source, ("The repair could not start (%s)."):format(tostring(err)))
    end
    if not answer.ok then
        return say(source, "Repair cancelled. The ride stays as it is.")
    end

    -- Fifteen seconds passed: check everything again before spending anything.
    local okm2, why2 = mechanicCheck(source)
    if not okm2 then return say(source, why2) end
    local again, dist2 = vehicleExplicit(source, vehicleId, C.repair.reach)
    if not again then
        return say(source, dist2 == "too_far" and "You walked away from the vehicle. Repair aborted." or "The vehicle is gone. Repair aborted.")
    end
    local okr, removed, rreason = ex("rp_inventory", "remove", source, "component", C.repair.components)
    if not okr or not removed then
        return say(source, ("Could not use the components (%s). Repair aborted."):format(tostring(removed or rreason)))
    end
    local done = Open77.vehicles.repair(vehicleId, C.repair.scope)
    if not done then
        ex("rp_inventory", "add", source, "component", C.repair.components)
        return say(source, "The engine refused the repair. Components returned to your pockets.")
    end
    local okh, hreason = Open77.vehicles.setHealth(vehicleId, 1.0)
    if not okh then log("setHealth after repair refused: %s", tostring(hreason)) end
    local damage = Open77.vehicles.getDamage(vehicleId)
    local tornOff = damage and (damage.detachedParts or 0) ~= 0
    say(source, ("%s repaired (%s). %d components used.%s"):format(label, C.repair.scope, C.repair.components,
        tornOff and " Panels already torn off stay off: only a respawn brings them back." or ""))
    log("player %d repaired vehicle %s (%s, scope=%s, %s)", source, tostring(vehicleId), snapshot.record,
        C.repair.scope, seated and "seated" or ("%.1f m"):format(dist or 0))
    TriggerEvent("rp_mecano:repaired", vehicleId, source, C.repair.scope)
end

-- ---------------------------------------------------------------------------
-- /remorquer: no attach native on op77.76, so the towed car is moved behind the
-- truck every tick with Open77.vehicles.setTransform.
-- ---------------------------------------------------------------------------

local tows = {}          -- mechanic playerId -> { truckId, towedId, lastX, lastY, ticks, failures }
local yawSign = C.tow.yawSign
local yawCalibrated = false

local function forwardFromYaw(yawDeg)
    local r = math.rad(yawDeg)
    return yawSign * math.sin(r), math.cos(r)
end

local function stopTow(mechanicId, reason)
    local t = tows[mechanicId]
    if not t then return end
    tows[mechanicId] = nil
    local messages = {
        released = "Tow released. The vehicle stays where it is.",
        left_wheel = "You left the wheel: tow released.",
        vehicle_gone = "The towed vehicle is gone: tow released.",
        truck_gone = "Your truck is gone: tow released.",
        someone_aboard = "Somebody climbed into the towed vehicle: tow released.",
        transform_refused = "The engine refuses to move that vehicle: tow released.",
        off_duty = "Off duty: tow released.",
        disconnected = "",
    }
    if reason ~= "disconnected" then
        say(mechanicId, messages[reason] or ("Tow released (%s)."):format(tostring(reason)))
    end
    log("player %d tow of vehicle %s ended: %s", mechanicId, tostring(t.towedId), tostring(reason))
    TriggerEvent("rp_mecano:tow", t.towedId, mechanicId, false, reason)
end

local function towTick(mechanicId, t)
    local seat = Open77.vehicles.getPlayerSeat(mechanicId)
    if not seat or seat.vehicleId ~= t.truckId or seat.seat ~= "seat_front_left" then
        return stopTow(mechanicId, "left_wheel")
    end
    local towed = Open77.vehicles.get(t.towedId)
    if not towed then return stopTow(mechanicId, "vehicle_gone") end
    if type(towed.occupants) == "table" and #towed.occupants > 0 then
        return stopTow(mechanicId, "someone_aboard")
    end
    local pos = Open77.vehicles.getPosition(t.truckId)
    local yaw = Open77.vehicles.getHeading(t.truckId)
    if not pos or not yaw then return stopTow(mechanicId, "truck_gone") end

    -- Calibrate the yaw sign once against the direction the truck is really going.
    if not yawCalibrated then
        local vel = Open77.vehicles.getVelocity(t.truckId)
        local truck = Open77.vehicles.get(t.truckId)
        if vel and truck then
            local speed2d = math.sqrt(vel.x * vel.x + vel.y * vel.y)
            if speed2d > 1.5 then
                local fx, fy = forwardFromYaw(yaw)
                local dot = (fx * vel.x + fy * vel.y) / speed2d
                local forwardExpected = not truck.reversing
                if (forwardExpected and dot < -0.3) or ((not forwardExpected) and dot > 0.3) then
                    yawSign = -yawSign
                    log("tow: yaw sign flipped to %d (velocity check)", yawSign)
                end
                if math.abs(dot) > 0.3 then yawCalibrated = true end
            end
        end
    end

    local moved = math.sqrt((pos.x - t.lastX) ^ 2 + (pos.y - t.lastY) ^ 2)
    if t.ticks > 0 and moved < C.tow.minMove then
        return -- the truck did not move: leave the towed car alone
    end
    t.lastX, t.lastY = pos.x, pos.y
    t.ticks = t.ticks + 1
    local fx, fy = forwardFromYaw(yaw)
    local x, y, z = pos.x - fx * C.tow.distance, pos.y - fy * C.tow.distance, pos.z
    local ok = Open77.vehicles.setTransform(t.towedId, {
        x = x, y = y, z = z,
        position = { x = x, y = y, z = z },
        yaw = yaw,
    })
    if not ok then
        t.failures = (t.failures or 0) + 1
        if t.failures >= 3 then stopTow(mechanicId, "transform_refused") end
    else
        t.failures = 0
    end
end

local function doTow(source, explicitVehicleId)
    local okm, why = mechanicCheck(source)
    if not okm then return say(source, why) end
    if tows[source] then
        return stopTow(source, "released")
    end
    local seat = Open77.vehicles.getPlayerSeat(source)
    if not seat or seat.seat ~= "seat_front_left" then
        return say(source, "Get behind the wheel of your truck first: the tow runs from the driver's seat.")
    end
    local truckId = seat.vehicleId

    local towedId, dist
    if explicitVehicleId then
        if explicitVehicleId == truckId then return say(source, "That is your own truck, choom.") end
        local id, r, d = vehicleExplicit(source, explicitVehicleId, C.tow.reach)
        if not id then
            if r == "too_far" then
                return say(source, ("Too far from that vehicle (%.1f m). Get within %d m."):format(d or 0, C.tow.reach))
            end
            return say(source, NO_VEHICLE)
        end
        towedId, dist = id, r
    else
        local list = Open77.vehicles.nearby(source, C.tow.reach, { occupied = false, limit = 4 })
        if list then
            for _, entry in ipairs(list) do
                if entry.id ~= truckId then
                    towedId, dist = entry.id, entry.distance
                    break
                end
            end
        end
        if not towedId then
            return say(source, ("No empty server vehicle within %d m of your truck to hook."):format(C.tow.reach))
        end
    end
    local towed = Open77.vehicles.get(towedId)
    if not towed then return say(source, NO_VEHICLE) end
    if type(towed.occupants) == "table" and #towed.occupants > 0 then
        return say(source, "Somebody is sitting in that vehicle. Ask them out first.")
    end
    local pos = Open77.vehicles.getPosition(truckId)
    if not pos then return say(source, "Your truck has no position yet. Try again.") end

    tows[source] = { truckId = truckId, towedId = towedId, lastX = pos.x, lastY = pos.y, ticks = 0, failures = 0 }
    local t = tows[source]
    say(source, ("%s hooked (%.1f m). It follows %d m behind your truck; /remorquer again to release."):format(
        vehicleLabel(towed), dist or 0, C.tow.distance))
    log("player %d tows vehicle %s (%s) behind truck %s", source, tostring(towedId), towed.record, tostring(truckId))
    TriggerEvent("rp_mecano:tow", towedId, source, true, "hooked")
    towTick(source, t)
    CreateThread(function()
        while tows[source] == t do
            Wait(C.tow.tickMs)
            if tows[source] ~= t then break end
            towTick(source, t)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- /peindre
-- ---------------------------------------------------------------------------

-- "red", "Red", "#ff0000" -> "#RRGGBB", name
local function parseColour(text)
    if type(text) ~= "string" or text == "" then return nil end
    local lower = text:lower()
    local hex = C.paint.colours[lower]
    if hex then return hex, lower end
    local h = lower:match("^#?(%x%x%x%x%x%x)$")
    if h then return "#" .. h:upper(), "#" .. h:upper() end
    return nil
end

local function colourList()
    local names = {}
    for name in pairs(C.paint.colours) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ", ")
end

local function applyPaint(mechanicId, vehicleId, primary, secondary, label)
    local okp, has = ex("rp_inventory", "has", mechanicId, "paint_can", 1)
    if not okp or not has then
        return nil, "no_paint_can"
    end
    if not Open77.vehicles.get(vehicleId) then
        return nil, "vehicle_gone"
    end
    local okr, removed, rreason = ex("rp_inventory", "remove", mechanicId, "paint_can", 1)
    if not okr or not removed then
        return nil, "paint_can:" .. tostring(removed or rreason)
    end
    local ok = Open77.vehicles.setPaint(vehicleId, { primary = primary, secondary = secondary or primary })
    if not ok then
        ex("rp_inventory", "add", mechanicId, "paint_can", 1)
        return nil, "paint_refused"
    end
    log("player %d painted vehicle %s %s / %s", mechanicId, tostring(vehicleId), primary, tostring(secondary or primary))
    TriggerEvent("rp_mecano:painted", vehicleId, mechanicId, primary, secondary or primary)
    return true
end

local function doPaint(source, colourArg, secondaryArg, explicitVehicleId)
    local okm, why = mechanicCheck(source)
    if not okm then return say(source, why) end
    local primary, primaryName = parseColour(colourArg)
    if not primary then
        say(source, "Usage: /peindre <colour> [second colour]. Names: " .. colourList() .. " - or #RRGGBB.")
        return
    end
    local secondary, secondaryName
    if secondaryArg and secondaryArg ~= "" then
        secondary, secondaryName = parseColour(secondaryArg)
        if not secondary then
            return say(source, ("Unknown second colour '%s'. Names: %s - or #RRGGBB."):format(tostring(secondaryArg), colourList()))
        end
    end
    local okp, has = ex("rp_inventory", "has", source, "paint_can", 1)
    if not okp then return say(source, "Your pockets are offline (rp_inventory).") end
    if not has then return say(source, "No spray paint can in your pockets.") end

    local vehicleId, dist
    if explicitVehicleId then
        local id, r, d = vehicleExplicit(source, explicitVehicleId, C.paint.reach)
        if not id then
            if r == "too_far" then
                return say(source, ("Too far from that vehicle (%.1f m). Get within %d m."):format(d or 0, C.paint.reach))
            end
            return say(source, NO_VEHICLE)
        end
        vehicleId, dist = id, r
    else
        vehicleId, dist = vehicleNear(source, C.paint.reach)
        if not vehicleId then return say(source, NO_VEHICLE) end
    end
    local snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot then return say(source, NO_VEHICLE) end
    if snapshot.destroyed or snapshot.exploded then
        return say(source, "Paint on a wreck? Not even for a Rayfield.")
    end
    local label = vehicleLabel(snapshot)
    local colourText = secondaryName and (primaryName .. " / " .. secondaryName) or primaryName

    -- Who pays: the driver, else the first occupant. The mechanic never bills themself.
    local payer = tonumber(Open77.vehicles.getDriver(vehicleId))
    if not payer and type(snapshot.occupants) == "table" and snapshot.occupants[1] then
        payer = tonumber(snapshot.occupants[1].playerId)
    end
    if payer == source then payer = nil end

    if not payer then
        -- Staged: the spray can in the hand for the whole bar, then the paint goes on.
        local sprayed = stage(source, "paint", { label = ("Spraying the %s %s"):format(label, colourText) })
        if not sprayed or not sprayed.ok then
            return say(source, "You cap the can. The panels keep their colour.")
        end
        local ok, reason = applyPaint(source, vehicleId, primary, secondary, label)
        if not ok then
            return say(source, ("Paint job failed: %s."):format(tostring(reason)))
        end
        return say(source, ("%s painted %s. Nobody at the wheel to bill: this one is on the house."):format(label, colourText))
    end

    local billId, reason = startBill(source, payer, C.paint.price, ("paint job %s"):format(colourText), {
        check = function()
            local okc, hasCan = ex("rp_inventory", "has", source, "paint_can", 1)
            if not okc or not hasCan then return nil, "the mechanic has no spray can left" end
            local id, r = vehicleExplicit(source, vehicleId, C.paint.reach)
            if not id then return nil, r == "too_far" and "the vehicle drove away from the mechanic" or "the vehicle is gone" end
            return true
        end,
        apply = function()
            -- Paid: the mechanic sprays for the bar's length (own thread, the settlement must
            -- not wait), then the paint goes on. Walking away cancels the bar, not the payment.
            CreateThread(function()
                say(payer, ("%s is spraying your %s %s. Give them a moment."):format(playerName(source), label, colourText))
                local sprayed = stage(source, "paint", { label = ("Spraying the %s %s"):format(label, colourText) })
                if not sprayed or not sprayed.ok then
                    say(source, "You capped the can early: the customer paid, the panels are still yours to finish. Run /peindre again on the house.")
                    return
                end
                local ok, err = applyPaint(source, vehicleId, primary, secondary, label)
                if ok then
                    say(source, ("%s painted %s."):format(label, colourText))
                    say(payer, ("Your %s now wears %s. Enjoy the new look, choom."):format(label, colourText))
                else
                    say(source, ("Paint job failed after payment: %s."):format(tostring(err)))
                end
            end)
        end,
    })
    if not billId then
        local reasons = {
            target_busy = "that customer already has an invoice waiting",
            player_not_found = "the customer is gone",
        }
        return say(source, ("Cannot bill the driver: %s."):format(reasons[reason] or tostring(reason)))
    end
    say(source, ("Paint job %s on the %s: %s invoiced to %s. The paint goes on when they pay."):format(
        colourText, label, fmtMoney(C.paint.price), playerName(payer)))
end

-- ---------------------------------------------------------------------------
-- /fourriere
-- ---------------------------------------------------------------------------

local function atImpoundLot(playerId)
    local ok, inside = ex("rp_zones", "isIn", playerId, C.impound.zone)
    local me = Open77.players.position(playerId)
    if ok then
        if inside then return true, "zone" end
    else
        -- rp_zones is not running: fall back to the shipped circle.
        if me and planarDistance(me, C.impound.fallbackCenter) <= C.impound.fallbackRadius then
            return true, "fallback"
        end
    end
    if C.impoundAnywhereForTesting and me then
        for _, spot in ipairs(C.impound.testingSpots) do
            if planarDistance(me, spot) <= C.impound.testingReach then
                return true, "testing:" .. spot.label
            end
        end
    end
    return false
end

local function doImpound(source, explicitVehicleId)
    local okm, why = mechanicCheck(source)
    if not okm then return say(source, why) end
    local here, how = atImpoundLot(source)
    if not here then
        return say(source, ("The impound lot is the Rancho Coronado junkyard (zone %s, around %.0f, %.0f). Bring the vehicle there first."):format(
            C.impound.zone, C.impound.fallbackCenter.x, C.impound.fallbackCenter.y))
    end

    local vehicleId, dist
    if explicitVehicleId then
        local id, r, d = vehicleExplicit(source, explicitVehicleId, C.impound.reach)
        if not id then
            if r == "too_far" then
                return say(source, ("Too far from that vehicle (%.1f m). Get within %d m."):format(d or 0, C.impound.reach))
            end
            return say(source, NO_VEHICLE)
        end
        vehicleId, dist = id, r
    else
        local entry = Open77.vehicles.closest(source, { radius = C.impound.reach, occupied = false })
        if not entry then
            return say(source, ("No empty server vehicle within %d m to impound."):format(C.impound.reach))
        end
        vehicleId, dist = entry.id, entry.distance
    end
    local snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot then return say(source, NO_VEHICLE) end
    if type(snapshot.occupants) == "table" and #snapshot.occupants > 0 then
        return say(source, "Somebody is still in that vehicle. The lot takes empty rides only.")
    end
    for _, t in pairs(tows) do
        if t.towedId == vehicleId or t.truckId == vehicleId then
            return say(source, "That vehicle is on a tow hook. Release it first.")
        end
    end

    local label = vehicleLabel(snapshot)
    local plate = vehiclePlate(vehicleId)
    -- Staged: the mechanic calls the yard on the holo before the ride is taken away.
    local called = stage(source, "impound", { label = "Calling the impound yard" })
    if not called or not called.ok then
        return say(source, "You hang up. The ride stays on the lot.")
    end
    snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot then return say(source, NO_VEHICLE) end
    if type(snapshot.occupants) == "table" and #snapshot.occupants > 0 then
        return say(source, "Somebody climbed into that vehicle. The lot takes empty rides only.")
    end
    local row = {
        vehicleId = vehicleId, record = snapshot.record, plate = plate,
        x = snapshot.x or 0, y = snapshot.y or 0, z = snapshot.z or 0,
        byIdentifier = Open77.players.identifier(source) or ("session:" .. tostring(source)),
        byName = playerName(source), fee = C.impound.fee, at = math.floor(Open77.time.unix()),
    }
    local removed = Open77.vehicles.remove(vehicleId)
    if not removed then
        return say(source, ("The engine refused to remove the %s. Nothing logged."):format(label))
    end
    local oks, newBalance, sreason = ex("rp_bank", "societyAdd", C.society, C.impound.fee, "impound:" .. tostring(vehicleId))
    local societyText
    if oks and newBalance then
        societyText = ("Garage +%s (society %s)."):format(fmtMoney(C.impound.fee), fmtMoney(newBalance))
    else
        societyText = ("The bank could not credit the garage (%s)."):format(tostring(newBalance or sreason))
    end
    persistImpound(row)
    say(source, ("%s impounded (plate %s, %.1f m). %s"):format(label, plate or "none", dist or 0, societyText))
    log("player %d impounded vehicle %s (%s) plate=%s via %s", source, tostring(vehicleId), snapshot.record, tostring(plate), tostring(how))
    TriggerEvent("rp_mecano:impounded", vehicleId, source, snapshot.record, plate)
end

-- ---------------------------------------------------------------------------
-- /plein
-- ---------------------------------------------------------------------------

local function doRefuel(source, explicitVehicleId)
    local okm, why = mechanicCheck(source)
    if not okm then return say(source, why) end
    local okc, has = ex("rp_inventory", "has", source, "chooh2", 1)
    if not okc then return say(source, "Your pockets are offline (rp_inventory).") end
    if not has then return say(source, "No CHOOH2 can in your pockets.") end

    local vehicleId, dist
    if explicitVehicleId then
        local id, r, d = vehicleExplicit(source, explicitVehicleId, C.fuel.reach)
        if not id then
            if r == "too_far" then
                return say(source, ("Too far from that vehicle (%.1f m). Get within %d m."):format(d or 0, C.fuel.reach))
            end
            return say(source, NO_VEHICLE)
        end
        vehicleId, dist = id, r
    else
        vehicleId, dist = vehicleNear(source, C.fuel.reach)
        if not vehicleId then return say(source, NO_VEHICLE) end
    end
    local snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot then return say(source, NO_VEHICLE) end

    -- Staged: crouched at the tank, the can in hand, for the whole bar; then everything is
    -- checked again (the can, the distance) before the fuel moves.
    local filled = stage(source, "refuel", { label = "Filling the " .. vehicleLabel(snapshot), durationMs = C.fuel.durationMs })
    if not filled or not filled.ok then
        return say(source, "You put the can down. The tank is as it was.")
    end
    local okc2, has2 = ex("rp_inventory", "has", source, "chooh2", 1)
    if not okc2 or not has2 then return say(source, "The CHOOH2 can is gone from your pockets.") end
    local again, dreason = vehicleExplicit(source, vehicleId, C.fuel.reach)
    if not again then
        return say(source, dreason == "too_far" and "You walked away from the tank. Nothing poured." or "The vehicle is gone.")
    end

    local litres = C.fuel.litresPerCan
    local okf, level, freason
    if type(litres) == "number" and litres > 0 then
        okf, level, freason = ex("open77_fuel", "refuel", vehicleId, litres)
    else
        okf, level, freason = ex("open77_fuel", "refuel", vehicleId)
    end
    if not okf then
        return say(source, "No fuel system on this server (open77_fuel is not running). The can stays in your pockets.")
    end
    if level == nil then
        return say(source, ("Refuel refused: %s. The can stays in your pockets."):format(tostring(freason)))
    end
    local okr, removed, rreason = ex("rp_inventory", "remove", source, "chooh2", 1)
    if not okr or not removed then
        log("chooh2 could not be removed from player %d after refuel: %s", source, tostring(removed or rreason))
    end
    say(source, ("%s refuelled: %.0f L in the tank. One CHOOH2 can used."):format(vehicleLabel(snapshot), tonumber(level) or 0))
    log("player %d refuelled vehicle %s to %s L", source, tostring(vehicleId), tostring(level))
    TriggerEvent("rp_mecano:refuelled", vehicleId, source, level)
end

-- ---------------------------------------------------------------------------
-- /facture
-- ---------------------------------------------------------------------------

local function doBillCommand(source, args)
    local first = args[1]
    if first == nil then
        local pending = billByTarget[source]
        if pending and bills[pending] then
            local b = bills[pending]
            return say(source, ("Invoice #%d from %s: %s (%s). /facture ok | /facture non."):format(
                b.id, playerName(b.from), fmtMoney(b.amount), b.reason))
        end
        return say(source, "Usage: /facture <playerId> <amount> [reason] - or /facture ok | non to answer one.")
    end
    local word = tostring(first):lower()
    if word == "ok" or word == "oui" or word == "yes" or word == "accept" then
        return answerBill(source, true)
    end
    if word == "non" or word == "no" or word == "decline" or word == "refuse" then
        return answerBill(source, false)
    end

    local okm, why = mechanicCheck(source)
    if not okm then return say(source, why) end
    local target = tonumber(args[1])
    local amount = tonumber(args[2])
    if not target or not amount or not isInteger(target) or not isInteger(amount) then
        return say(source, "Usage: /facture <playerId> <amount> [reason]")
    end
    local reason = nil
    local n = args.n or #args
    if n >= 3 then reason = table.concat(args, " ", 3, n) end
    if target == source then return say(source, "Billing yourself? Nice try, choom.") end
    local them = Open77.players.position(target)
    local me = Open77.players.position(source)
    if not them or not Open77.players.name(target) then
        return say(source, ("No player with id %d on the server."):format(target))
    end
    local d = planarDistance(me, them)
    if d > C.bill.reach then
        return say(source, ("%s is %.0f m away. Get within %d m to hand an invoice."):format(playerName(target), d, C.bill.reach))
    end
    local billId, err = startBill(source, target, amount, reason)
    if not billId then
        local reasons = {
            invalid_amount = "the amount must be a whole number of eddies above zero",
            amount_too_large = ("the garage caps an invoice at %s"):format(fmtMoney(C.bill.max)),
            target_busy = "that customer already has an invoice waiting",
            player_not_found = "that player is gone",
            self_bill = "you cannot bill yourself",
        }
        return say(source, ("Invoice refused: %s."):format(reasons[err] or tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function fromGame(source, name)
    if source == 0 then
        print(("[rp_mecano] %s: run it from the game, not the console"):format(name))
        return false
    end
    return true
end

RegisterCommand("reparer", function(source)
    if not fromGame(source, "reparer") then return end
    doRepair(source)
end, false)

RegisterCommand("remorquer", function(source)
    if not fromGame(source, "remorquer") then return end
    doTow(source)
end, false)

RegisterCommand("peindre", function(source, args)
    if not fromGame(source, "peindre") then return end
    doPaint(source, args[1], args[2])
end, false)

RegisterCommand("facture", function(source, args)
    if not fromGame(source, "facture") then return end
    doBillCommand(source, args)
end, false)

RegisterCommand("fourriere", function(source, args)
    if not fromGame(source, "fourriere") then return end
    local sub = args[1] and tostring(args[1]):lower() or nil
    if sub == "registre" or sub == "register" or sub == "list" then
        local okm, why = mechanicCheck(source)
        if not okm then return say(source, why) end
        return impoundRegister(source)
    end
    doImpound(source)
end, false)

RegisterCommand("plein", function(source)
    if not fromGame(source, "plein") then return end
    doRefuel(source)
end, false)

local SUGGESTIONS = {
    { command = "/reparer", help = "Mechanic: repair the vehicle you sit in or stand next to (15 s, 2 components)" },
    { command = "/remorquer", help = "Mechanic: hook the nearest empty vehicle behind your truck; again to release" },
    { command = "/peindre", help = "Mechanic: paint the nearest vehicle (250 eddies billed to the driver, 1 spray can)",
      parameters = { { name = "colour", help = "black, white, red, cyan... or #RRGGBB" }, { name = "secondary", help = "optional second colour" } } },
    { command = "/facture", help = "Mechanic: hand an invoice - customers answer with /facture ok | non",
      parameters = { { name = "playerId", help = "customer session id (/players)" }, { name = "amount", help = "eddies" }, { name = "reason", help = "optional" } } },
    { command = "/fourriere", help = "Mechanic: impound the nearest empty vehicle at the garage; 'registre' lists the last entries",
      parameters = { { name = "registre", help = "optional: show the register" } } },
    { command = "/plein", help = "Mechanic: refuel the vehicle you sit in or stand next to (1 CHOOH2 can)" },
}

RegisterNetEvent("chat:ready", function()
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

-- ---------------------------------------------------------------------------
-- ALT+click requests from our own client script
-- ---------------------------------------------------------------------------

local function sendDuty(playerId)
    local on = false
    local ok, has = ex("rp_jobs", "hasJob", playerId, C.job)
    if ok and has then
        local ok2, duty = ex("rp_jobs", "onDuty", playerId)
        on = ok2 and duty == true
    end
    TriggerClientEvent("rp_mecano:duty", playerId, on)
end

RegisterNetEvent("rp_mecano:whoami", function()
    sendDuty(source)
end)

RegisterNetEvent("rp_mecano:action", function(action, vehicleId)
    -- `source` is only valid until the first yield: capture it before the dialog awaits.
    local src = source
    if type(src) ~= "number" or src < 1 then return end
    local id = tonumber(vehicleId)
    if not id or not isInteger(id) then
        return say(src, "That is not a server vehicle.")
    end
    id = math.tointeger(id)
    if action == "repair" then
        doRepair(src, id)
    elseif action == "tow" then
        doTow(src, id)
    elseif action == "impound" then
        doImpound(src, id)
    elseif action == "refuel" then
        doRefuel(src, id)
    elseif action == "paint" then
        local okm, why = mechanicCheck(src)
        if not okm then return say(src, why) end
        local options = {}
        for name in pairs(C.paint.colours) do options[#options + 1] = name end
        table.sort(options)
        local promise, reason = Open77.exports.call("open77_uikit", "input", src, {
            title = "Paint job",
            description = ("%s, billed to the driver. One spray can."):format(fmtMoney(C.paint.price)),
            fields = {
                { id = "colour", type = "select", label = "Colour", options = options, required = true },
                { id = "secondary", type = "text", label = "Second colour (name or #RRGGBB, optional)", max = 16 },
            },
            confirm = "Spray it", cancel = "Not now", timeoutMs = 60000,
        })
        if not promise then
            return say(src, ("The paint form could not open (%s). Use /peindre <colour>."):format(tostring(reason)))
        end
        local answer = promise:await()
        if not answer or not answer.ok or type(answer.value) ~= "table" then return end
        doPaint(src, answer.value.colour, answer.value.secondary, id)
    else
        say(src, "Unknown garage action.")
    end
end)

RegisterNetEvent("rp_mecano:billMenu", function(targetId)
    -- `source` is only valid until the first yield: capture it before the dialog awaits.
    local src = source
    if type(src) ~= "number" or src < 1 then return end
    local target = tonumber(targetId)
    if not target or not isInteger(target) or target < 1 then return say(src, "Pick a player.") end
    target = math.tointeger(target)
    local okm, why = mechanicCheck(src)
    if not okm then return say(src, why) end
    if target == src then return say(src, "Billing yourself? Nice try, choom.") end
    if not Open77.players.name(target) then return say(src, "That player is gone.") end
    local promise, reason = Open77.exports.call("open77_uikit", "input", src, {
        title = ("Invoice for %s"):format(playerName(target)),
        description = ("%d %% to you, the rest to the garage. Cash only."):format(math.floor(C.bill.mechanicShare * 100)),
        fields = {
            { id = "amount", type = "number", label = "Amount (eddies)", min = 1, max = C.bill.max, required = true },
            { id = "reason", type = "text", label = "Reason", max = 64, default = "garage services" },
        },
        confirm = "Send", cancel = "Cancel", timeoutMs = 60000,
    })
    if not promise then
        return say(src, ("The invoice form could not open (%s). Use /facture <playerId> <amount>."):format(tostring(reason)))
    end
    local answer = promise:await()
    if not answer or not answer.ok or type(answer.value) ~= "table" then return end
    local amount = tonumber(answer.value.amount)
    if not amount then return say(src, "That is not an amount.") end
    doBillCommand(src, table.pack(tostring(target), tostring(math.floor(amount)), tostring(answer.value.reason or "")))
end)

-- ---------------------------------------------------------------------------
-- Exports (never yield)
-- ---------------------------------------------------------------------------

exports("repair", function(vehicleId, byPlayerId)
    if not isInteger(vehicleId) then return nil, "invalid_vehicle_id" end
    local snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot then return nil, "vehicle_not_found" end
    if snapshot.destroyed or snapshot.exploded then return nil, "vehicle_destroyed" end
    local ok = Open77.vehicles.repair(vehicleId, "full")
    if not ok then return nil, "repair_failed" end
    Open77.vehicles.setHealth(vehicleId, 1.0)
    local by = tonumber(byPlayerId) or 0
    log("export repair: vehicle %s (%s) by player %d", tostring(vehicleId), snapshot.record, by)
    TriggerEvent("rp_mecano:repaired", vehicleId, by, "full")
    return true
end)

exports("bill", function(fromPlayerId, toPlayerId, amount, reason)
    local from, to = tonumber(fromPlayerId), tonumber(toPlayerId)
    if not from or not to then return nil, "invalid_player_id" end
    if type(amount) == "string" then amount = tonumber(amount) end
    return startBill(from, to, amount, reason)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Decoration: the props of Config.props (sign, tyre blockers, pump), created at start and
-- removed at stop. A refused prop only logs: the garage works without it.
local propIds = {}

local function spawnProps()
    for i, def in ipairs(C.props or {}) do
        local id, reason = Open77.props.create({
            model = def.model,
            position = { x = def.position.x, y = def.position.y, z = def.position.z },
            yaw = def.yaw or 0.0,
            bucket = 0,
        })
        if id then
            propIds[#propIds + 1] = id
        else
            log("prop %d (%s) not spawned: %s", i, tostring(def.model), tostring(reason))
        end
    end
    if #propIds > 0 then log("props spawned: %d", #propIds) end
end

local function removeProps()
    for _, id in ipairs(propIds) do Open77.props.remove(id) end
    propIds = {}
end

AddEventHandler("onResourceStop", function(name)
    if name ~= RES then return end
    removeProps()
end)

AddEventHandler("onResourceStart", function(name)
    if name == RES then
        setupDatabase()
        defineItems()
        spawnProps()
        Open77.chat.addSuggestions(-1, SUGGESTIONS)
        local players = Open77.players.all()
        for _, id in ipairs(players or {}) do sendDuty(id) end
        log("started: job=%s society=%s repair=%d ms / %d components, tow every %d ms at %d m, paint %d, impound zone=%s fee=%d testing=%s",
            C.job, C.society, C.repair.durationMs, C.repair.components, C.tow.tickMs, C.tow.distance, C.paint.price,
            C.impound.zone, C.impound.fee, tostring(C.impoundAnywhereForTesting))
    elseif name == "rp_inventory" then
        defineItems()
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if not id then return end
    if tows[id] then stopTow(id, "disconnected") end
    for mechanicId, t in pairs(tows) do
        if t.towedId == id then stopTow(mechanicId, "vehicle_gone") end
    end
    local pending = billByTarget[id]
    if pending then settle(pending, false, "customer_left") end
    for billId, bill in pairs(bills) do
        if bill.from == id then settle(billId, false, "mechanic_left") end
    end
    repairing[id] = nil
    stageClear(id)
end)

AddEventHandler("onVehicleRemoved", function(vehicleId)
    for mechanicId, t in pairs(tows) do
        if tostring(t.towedId) == tostring(vehicleId) or tostring(t.truckId) == tostring(vehicleId) then
            stopTow(mechanicId, "vehicle_gone")
        end
    end
end)

-- Duty changes: stop a tow of a mechanic who clocks out, and keep the client's
-- ALT+click entries in step with the job board.
AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    local id = tonumber(playerId)
    if not id then return end
    local on = (jobName == C.job) and (onDuty == true or onDuty == "true")
    if not on and tows[id] then stopTow(id, "off_duty") end
    TriggerClientEvent("rp_mecano:duty", id, on)
end)

AddEventHandler("rp_jobs:changed", function(playerId)
    local id = tonumber(playerId)
    if not id then return end
    if tows[id] then stopTow(id, "off_duty") end
    sendDuty(id)
end)
