-- rp_identity: the civil registry of Night City (server side).
--
-- Server-authoritative. The client only renders the registration form and forwards the
-- answers; every rule (names, dates, ages, enums, distance, ACL) is applied here, and the
-- exports answer from a per-session cache so they never yield (synchronous export calls
-- from other resources fail with export_yielded if the callee touches the database).

local RESOURCE = "rp_identity"
local TABLE = "rp_identity_citizens"

local NAME_MIN, NAME_MAX = 2, 24        -- characters, letters / spaces / hyphens
local AGE_MIN, AGE_MAX = 18, 90         -- years, on the day of the check
local SHOW_RANGE = 5.0                  -- metres, showing a card to another player
local REMIND_EVERY_MS = 60000           -- unregistered players are reminded this often

local SEXES = { m = "Male", f = "Female", x = "Other" }
local ORIGINS = {
    night_city = "Night City native",
    badlands = "Badlands",
    corpo = "Corpo",
    nomad = "Nomad",
    offworld = "Off-world",
}

-- /civil field spellings -> SQL column (the whitelist that keeps the UPDATE injection-free).
local FIELDS = {
    first_name = "first_name", firstname = "first_name",
    last_name = "last_name", lastname = "last_name",
    birth = "birth", sex = "sex", origin = "origin",
}
-- SQL column -> key of the in-memory record.
local COLUMN_KEY = {
    first_name = "firstName", last_name = "lastName",
    birth = "birth", sex = "sex", origin = "origin",
}

local NCID_COLOR = { 0, 229, 255 }
local WARN_COLOR = { 255, 170, 0 }

-- Session cache: playerId (number) -> record { id, identifier, firstName, lastName, birth, sex, origin }.
local citizens = {}
-- playerId -> true while the player is connected and still unregistered (reminder loop runs).
local pending = {}
-- playerId -> true while a registration submit is being written (double-submit guard).
local registering = {}
-- The kvp fallback is announced once in the log.
local kvpNoticed = false

local SUGGESTIONS = {
    { command = "/carte", help = "Show your Night City ID card" },
    { command = "/montrercarte", help = "Show your ID card to a player within 5 m (ALT+click > Show ID works too)",
      parameters = { { name = "playerId", help = "The player who will see your card" } } },
    { command = "/civil", help = "Admin: edit one field of a citizen record",
      parameters = {
          { name = "playerId", help = "The citizen's player id" },
          { name = "field", help = "first_name | last_name | birth | sex | origin" },
          { name = "value", help = "New value (YYYY-MM-DD for birth, m/f/x for sex)" },
      } },
}

-- ---------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------

local function log(text)
    print(("[%s] %s"):format(RESOURCE, text))
end

local function say(playerId, text)
    if type(playerId) ~= "number" or playerId < 1 then return end
    Open77.chat.send(playerId, { author = "NCID", color = NCID_COLOR, text = text })
end

local function warn(playerId, text)
    if type(playerId) ~= "number" or playerId < 1 then return end
    Open77.chat.send(playerId, { author = "NCID", color = WARN_COLOR, text = text })
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fullNameOf(record)
    return record.firstName .. " " .. record.lastName
end

-- ---------------------------------------------------------------------------------------
-- Dates without os.date: the sandbox only has Open77.time.unix()
-- ---------------------------------------------------------------------------------------

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function daysInMonth(y, m)
    if m == 2 and isLeap(y) then return 29 end
    return DAYS_IN_MONTH[m]
end

-- Civil date (UTC) from unix seconds; Howard Hinnant's days-to-civil algorithm.
local function civilFromUnix(seconds)
    local z = math.floor(seconds / 86400) + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

-- "YYYY-MM-DD" -> y, m, d or nil when the text is not a real calendar date.
local function parseDate(text)
    if type(text) ~= "string" then return nil end
    local y, m, d = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m) then return nil end
    return y, m, d
end

local function ageOn(y, m, d, ty, tm, td)
    local age = ty - y
    if tm < m or (tm == m and td < d) then age = age - 1 end
    return age
end

local function ageToday(birth)
    local y, m, d = parseDate(birth)
    if not y then return nil end
    local ty, tm, td = civilFromUnix(Open77.time.unix())
    return ageOn(y, m, d, ty, tm, td)
end

-- ---------------------------------------------------------------------------------------
-- Validation (the same rules for the registration form and /civil)
-- ---------------------------------------------------------------------------------------

-- Letters (ASCII or any UTF-8 multibyte sequence), spaces and hyphens, 2..24 characters.
local function validName(raw)
    if type(raw) ~= "string" then return nil, "a name must be text" end
    local s = trim(raw):gsub("%s+", " ")
    if s == "" then return nil, "a name cannot be empty" end
    if s:find("[^%a%s%-\128-\255]") then return nil, "letters, spaces and hyphens only" end
    if s:find("^%-") or s:find("%-$") then return nil, "a name cannot start or end with a hyphen" end
    local count = select(2, s:gsub("[^\128-\191]", "")) -- code points, not bytes
    if count < NAME_MIN or count > NAME_MAX then
        return nil, ("%d to %d characters"):format(NAME_MIN, NAME_MAX)
    end
    return s
end

-- "YYYY-MM-DD", a real date, age 18..90 today.
local function validBirth(raw)
    if type(raw) ~= "string" then return nil, "birth date must be text" end
    local s = trim(raw)
    local y, m, d = parseDate(s)
    if not y then return nil, "birth date must be a real date written YYYY-MM-DD" end
    local ty, tm, td = civilFromUnix(Open77.time.unix())
    local age = ageOn(y, m, d, ty, tm, td)
    if age < AGE_MIN or age > AGE_MAX then
        return nil, ("citizens are %d to %d years old (that date makes %d)"):format(AGE_MIN, AGE_MAX, age)
    end
    return s
end

local function validEnum(raw, allowed, what)
    if type(raw) ~= "string" then return nil, what .. " is missing" end
    local s = trim(raw):lower()
    if allowed[s] then return s end
    local keys = {}
    for key in pairs(allowed) do keys[#keys + 1] = key end
    table.sort(keys)
    return nil, ("%s must be one of %s"):format(what, table.concat(keys, ", "))
end

local function validateField(column, value)
    if column == "first_name" or column == "last_name" then return validName(value) end
    if column == "birth" then return validBirth(value) end
    if column == "sex" then return validEnum(value, SEXES, "sex") end
    if column == "origin" then return validEnum(value, ORIGINS, "origin") end
    return nil, "unknown field"
end

-- ---------------------------------------------------------------------------------------
-- Storage: SQL first, Open77.kvp only while the database is not ready
-- ---------------------------------------------------------------------------------------

local DB_TIMEOUT_S = 15 -- a query that never answers must not hang a handler forever

-- Runs one Open77.database method in its callback form and waits for the answer on this
-- resource's scheduler (the callback resumes there, never on the database worker). Every
-- database card documents a `.await` sugar for the same thing; the static validator of the
-- devkit does not know that spelling, so the wait is written out.
local function dbAwait(method, sql, params)
    local done, value = false, nil
    method(sql, params, function(result)
        done = true
        value = result
    end)
    local deadline = Open77.time.monotonic() + DB_TIMEOUT_S
    while not done do
        Wait(0)
        if Open77.time.monotonic() > deadline then
            log("database call timed out: " .. sql:sub(1, 48))
            return nil, "database_timeout"
        end
    end
    return value
end

local function noteKvp(reason)
    if kvpNoticed then return end
    kvpNoticed = true
    log(("database not ready (%s): falling back to Open77.kvp for citizen records"):format(tostring(reason)))
end

local function kvpKey(identifier)
    return "citizen:" .. identifier
end

local function rowToRecord(row)
    if type(row) ~= "table" then return nil end
    return {
        id = tonumber(row.id) or 0,
        identifier = row.identifier,
        firstName = row.first_name,
        lastName = row.last_name,
        birth = tostring(row.birth),
        sex = row.sex,
        origin = row.origin,
    }
end

-- Returns the record, `false` when the identity has none, or nil, reason when the store failed.
local function storeLoad(identifier)
    local ready, reason = Open77.database.isReady()
    if ready then
        -- At boot the CREATE TABLE lands a tick after the bridge answers; a player
        -- already in the world would otherwise hit "table doesn't exist" (measured).
        for _ = 1, 20 do
            if schemaReady then break end
            Wait(250)
        end
        local row, err = dbAwait(Open77.database.single,
            "SELECT id, identifier, first_name, last_name, birth, sex, origin FROM " .. TABLE .. " WHERE identifier = ?",
            { identifier })
        if err then return nil, err end
        return rowToRecord(row) or false
    end
    noteKvp(reason)
    local raw = Open77.kvp.get(kvpKey(identifier))
    if type(raw) ~= "string" then return false end
    local data = json.decode(raw)
    if type(data) ~= "table" or type(data.firstName) ~= "string" then return false end
    return data
end

-- Returns the citizen id (row id), or nil, reason.
local function storeInsert(record)
    local ready, reason = Open77.database.isReady()
    if ready then
        local result, err = dbAwait(Open77.database.insert,
            "INSERT INTO " .. TABLE .. " (identifier, first_name, last_name, birth, sex, origin) VALUES (?, ?, ?, ?, ?, ?)",
            { record.identifier, record.firstName, record.lastName, record.birth, record.sex, record.origin })
        if result == nil then return nil, err or "insert_failed" end
        -- oxmysql answers the insertId as a number; tolerate a result table as well.
        local id = tonumber(result)
        if not id and type(result) == "table" then id = tonumber(result.insertId) end
        if not id then return nil, "insert_failed" end
        return id
    end
    noteKvp(reason)
    local nextId = tonumber(Open77.kvp.get("next_id", 1)) or 1
    record.id = nextId
    local ok, err = Open77.kvp.set(kvpKey(record.identifier), json.encode(record))
    if not ok then return nil, err or "kvp_write_failed" end
    Open77.kvp.set("next_id", nextId + 1)
    return nextId
end

-- Persists one already-validated column of a record; the record is already updated.
local function storeUpdate(record, column, value)
    local ready, reason = Open77.database.isReady()
    if ready then
        local result, err = dbAwait(Open77.database.update,
            "UPDATE " .. TABLE .. " SET " .. column .. " = ? WHERE identifier = ?",
            { value, record.identifier })
        if result == nil or result == false then return nil, err or "update_failed" end
        return true
    end
    noteKvp(reason)
    local ok, err = Open77.kvp.set(kvpKey(record.identifier), json.encode(record))
    if not ok then return nil, err or "kvp_write_failed" end
    return true
end

local schemaReady = false
local schemaQueued, schemaReason = Open77.database.ready(function()
    dbAwait(Open77.database.query, [[
        CREATE TABLE IF NOT EXISTS rp_identity_citizens (
            id INT UNSIGNED NOT NULL AUTO_INCREMENT,
            identifier VARCHAR(64) NOT NULL,
            first_name VARCHAR(24) NOT NULL,
            last_name VARCHAR(24) NOT NULL,
            birth CHAR(10) NOT NULL,
            sex CHAR(1) NOT NULL,
            origin VARCHAR(16) NOT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            UNIQUE KEY uq_rp_identity_identifier (identifier)
        )
    ]])
    schemaReady = true
    log("schema ready: " .. TABLE)
end)
if not schemaQueued then
    log(("Open77.database.ready refused (%s): the registry will use Open77.kvp"):format(tostring(schemaReason)))
end

-- ---------------------------------------------------------------------------------------
-- Nameplates and the ID card
-- ---------------------------------------------------------------------------------------

-- Every client applies (or drops) the override for that remote player.
local function pushNameplate(playerId, record)
    TriggerClientEvent("rp_identity:nameplate", -1, playerId, record and fullNameOf(record) or false)
end

-- One client gets the whole directory (its own resource just started).
local function sendDirectory(playerId)
    local directory = {}
    for id, record in pairs(citizens) do
        directory[tostring(id)] = fullNameOf(record)
    end
    TriggerClientEvent("rp_identity:directory", playerId, directory)
end

local function cardLines(record)
    local age = ageToday(record.birth)
    return {
        ("NCID #%d - %s"):format(record.id, fullNameOf(record)),
        ("Born %s (%s years old), %s"):format(record.birth, age and tostring(age) or "?", SEXES[record.sex] or record.sex),
        ("Origin: %s"):format(ORIGINS[record.origin] or record.origin),
    }
end

-- Shows a citizen's card to one player: a toast plus the same lines in chat.
local function showCard(toPlayerId, record, heading)
    local lines = cardLines(record)
    local id, reason = Open77.notifications.send(toPlayerId, {
        type = "info",
        title = heading,
        icon = "NCID",
        message = table.concat(lines, "  |  "),
        durationMs = 12000,
        position = "middle_left",
    })
    if not id then
        log(("notification to player %d refused: %s"):format(toPlayerId, tostring(reason)))
    end
    say(toPlayerId, heading)
    for _, line in ipairs(lines) do
        Wait(0) -- two sends in one tick arrive reversed; one tick per line keeps the order
        Open77.chat.send(toPlayerId, line)
    end
end

-- ---------------------------------------------------------------------------------------
-- Registration flow
-- ---------------------------------------------------------------------------------------

local function openRegistration(playerId, note)
    TriggerClientEvent("rp_identity:openRegistration", playerId, note or "")
end

local function startReminders(playerId)
    CreateThread(function()
        while pending[playerId] do
            Wait(REMIND_EVERY_MS)
            if not pending[playerId] then return end
            if not Open77.players.name(playerId) then
                pending[playerId] = nil
                return
            end
            warn(playerId, "Still no citizen record on file, choom. Fill in the registration form, or type /carte to reopen it.")
            openRegistration(playerId, "reminder")
        end
    end)
end

local function beginPending(playerId)
    if pending[playerId] then return end
    pending[playerId] = true
    startReminders(playerId)
end

-- Loads (or prompts) one connected player. Idempotent: safe on a second world-ready.
local function admit(playerId)
    if citizens[playerId] or pending[playerId] then return end
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        log(("player %d has no identifier; registry skipped"):format(playerId))
        return
    end
    local record, err = storeLoad(identifier)
    if not Open77.players.name(playerId) then return end -- left while the query ran
    if citizens[playerId] then return end                -- loaded twice concurrently
    if record == nil then
        log(("could not load the record of player %d: %s"):format(playerId, tostring(err)))
        warn(playerId, "NCID cannot reach the registry right now (" .. tostring(err) .. "). Type /carte in a minute.")
        return
    end
    if record then
        citizens[playerId] = record
        pending[playerId] = nil
        pushNameplate(playerId, record)
        say(playerId, ("Welcome back to Night City, %s. /carte shows your ID."):format(fullNameOf(record)))
        return
    end
    beginPending(playerId)
    say(playerId, "No citizen record on file. Fill in the NCID registration form to get your Night City ID.")
    openRegistration(playerId, "first")
end

AddEventHandler("onPlayerReady", function(rawId)
    local playerId = tonumber(rawId)
    if not playerId then return end
    admit(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(rawId)
    local playerId = tonumber(rawId)
    if not playerId then return end
    citizens[playerId] = nil
    pending[playerId] = nil
    registering[playerId] = nil
    TriggerClientEvent("rp_identity:nameplate", -1, playerId, false)
end)

RegisterNetEvent("rp_identity:clientReady", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    sendDirectory(playerId)
end)

RegisterNetEvent("rp_identity:formRefused", function(reason)
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 or citizens[playerId] then return end
    warn(playerId, ("The registration form could not open (%s). Type /carte to retry."):format(tostring(reason)))
end)

RegisterNetEvent("rp_identity:formClosed", function(outcome)
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 or citizens[playerId] then return end
    if outcome == "timeout" then
        warn(playerId, "The registration form timed out. Type /carte to reopen it.")
    else
        warn(playerId, "Registration postponed. Type /carte whenever you are ready; NCID will remind you in a minute.")
    end
end)

RegisterNetEvent("rp_identity:register", function(form)
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    if citizens[playerId] then
        say(playerId, "You already have a citizen record. /carte shows it.")
        return
    end
    if registering[playerId] then return end
    if type(form) ~= "table" then
        warn(playerId, "NCID received an empty form. Type /carte to try again.")
        return
    end

    local firstName, e1 = validName(form.firstName)
    local lastName, e2 = validName(form.lastName)
    local birth, e3 = validBirth(form.birth)
    local sex, e4 = validEnum(form.sex, SEXES, "sex")
    local origin, e5 = validEnum(form.origin, ORIGINS, "origin")
    local problems = {}
    if not firstName then problems[#problems + 1] = "first name: " .. e1 end
    if not lastName then problems[#problems + 1] = "last name: " .. e2 end
    if not birth then problems[#problems + 1] = "birth: " .. e3 end
    if not sex then problems[#problems + 1] = e4 end
    if not origin then problems[#problems + 1] = e5 end
    if #problems > 0 then
        warn(playerId, "NCID refused the form - " .. table.concat(problems, "; ") .. ". Try again.")
        beginPending(playerId)
        openRegistration(playerId, "retry")
        return
    end

    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        warn(playerId, "NCID cannot read your identity. Reconnect and try again.")
        return
    end

    registering[playerId] = true
    -- A record may exist by now (an older session of the same identity, a double submit).
    local existing, loadErr = storeLoad(identifier)
    if not Open77.players.name(playerId) then
        registering[playerId] = nil
        return
    end
    if existing == nil then
        registering[playerId] = nil
        log(("registration lookup failed for player %d: %s"):format(playerId, tostring(loadErr)))
        warn(playerId, "The registry is down (" .. tostring(loadErr) .. "). Try again in a minute.")
        return
    end
    if existing then
        registering[playerId] = nil
        citizens[playerId] = existing
        pending[playerId] = nil
        pushNameplate(playerId, existing)
        say(playerId, ("You are already registered as %s."):format(fullNameOf(existing)))
        return
    end

    local record = {
        identifier = identifier,
        firstName = firstName,
        lastName = lastName,
        birth = birth,
        sex = sex,
        origin = origin,
    }
    local id, err = storeInsert(record)
    registering[playerId] = nil
    if not id then
        log(("registration write failed for player %d: %s"):format(playerId, tostring(err)))
        warn(playerId, "The registry is down (" .. tostring(err) .. "). Try again in a minute.")
        return
    end
    record.id = id
    if not Open77.players.name(playerId) then return end -- left during the write; the row stays
    citizens[playerId] = record
    pending[playerId] = nil
    pushNameplate(playerId, record)

    local name = fullNameOf(record)
    log(('player %d registered id=%d name="%s"'):format(playerId, id, name))
    Open77.chat.send(-1, { author = "NCID", color = NCID_COLOR, text = ("Welcome to Night City, %s."):format(name) })
    Open77.notifications.send(playerId, {
        type = "success",
        title = "Citizen record created",
        icon = "NCID",
        message = ("Welcome to Night City, %s. Citizen #%d. /carte shows your ID."):format(name, id),
        durationMs = 8000,
    })
    TriggerEvent("rp_identity:changed", playerId)
end)

-- ---------------------------------------------------------------------------------------
-- Showing the card to another player (context menu action and /montrercarte)
-- ---------------------------------------------------------------------------------------

local function showCardTo(callerId, targetId)
    local record = citizens[callerId]
    if not record then
        warn(callerId, "You have no ID card to show. /carte opens the registration.")
        return
    end
    if not targetId or targetId < 1 or targetId == callerId then
        warn(callerId, "Pick another player to show your card to.")
        return
    end
    if not Open77.players.name(targetId) then
        warn(callerId, "Nobody with that id in the city.")
        return
    end
    local metres, reason = Open77.players.distance(callerId, targetId)
    if not metres then
        warn(callerId, "Cannot tell how far that player is (" .. tostring(reason) .. ").")
        return
    end
    if metres > SHOW_RANGE then
        warn(callerId, ("Too far away (%.1f m). Get within %d m to show your ID."):format(metres, SHOW_RANGE))
        return
    end
    local targetRecord = citizens[targetId]
    local targetName = targetRecord and fullNameOf(targetRecord) or (Open77.players.name(targetId) or ("player " .. targetId))
    showCard(targetId, record, ("%s shows you their ID"):format(fullNameOf(record)))
    say(callerId, ("You showed your ID to %s."):format(targetName))
end

RegisterNetEvent("rp_identity:showTo", function(target)
    local callerId = source
    if type(callerId) ~= "number" or callerId < 1 then return end
    showCardTo(callerId, tonumber(target))
end)

-- ---------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------

RegisterCommand("carte", function(source)
    if source == 0 then
        log("/carte: run it from the game, the console has no ID card")
        return
    end
    local record = citizens[source]
    if not record then
        warn(source, "No citizen record yet. Opening the NCID registration form...")
        beginPending(source)
        openRegistration(source, "manual")
        return
    end
    showCard(source, record, "Your Night City ID")
end, false)

RegisterCommand("montrercarte", function(source, args)
    if source == 0 then
        log("/montrercarte: run it from the game, the console has no ID card")
        return
    end
    local target = tonumber(args[1])
    if not target then
        warn(source, "Usage: /montrercarte <playerId> (or ALT+click a player > Show ID)")
        return
    end
    showCardTo(source, target)
end, false)

-- Restricted: only a player holding command.civil (or the console) reaches the handler.
RegisterCommand("civil", function(source, args)
    local caller = source
    local function reply(text)
        if caller == 0 then log(text) else say(caller, text) end
    end

    local target = tonumber(args[1])
    local column = args[2] and FIELDS[args[2]:lower()]
    if not target or not column or (args.n or #args) < 3 then
        reply("Usage: /civil <playerId> <first_name|last_name|birth|sex|origin> <value>")
        return
    end
    local value = table.concat(args, " ", 3, args.n or #args)
    local record = citizens[target]
    if not record then
        reply(("Player %d is not a registered citizen (or is not online)."):format(target))
        return
    end
    local clean, why = validateField(column, value)
    if not clean then
        reply("Refused - " .. why .. ".")
        return
    end

    local key = COLUMN_KEY[column]
    local previous = record[key]
    record[key] = clean
    local ok, err = storeUpdate(record, column, clean)
    if not ok then
        record[key] = previous
        reply("Registry write failed (" .. tostring(err) .. "); nothing changed.")
        return
    end

    pushNameplate(target, record)
    local by = caller == 0 and "console" or ("player " .. caller)
    log(('player %d edited id=%d field=%s value="%s" by=%s'):format(target, record.id, column, clean, by))
    reply(("Citizen #%d: %s set to \"%s\" (was \"%s\")."):format(record.id, column, clean, tostring(previous)))
    if Open77.players.name(target) then
        say(target, ("NCID updated your record: %s is now \"%s\"."):format(column, clean))
    end
    TriggerEvent("rp_identity:changed", target)
end, true)

-- ---------------------------------------------------------------------------------------
-- Exports (phase 1 contract) - synchronous-safe, they never yield
-- ---------------------------------------------------------------------------------------

exports("get", function(playerId)
    local record = citizens[tonumber(playerId) or -1]
    if not record then return nil end
    return {
        firstName = record.firstName,
        lastName = record.lastName,
        birth = record.birth,
        sex = record.sex,
        origin = record.origin,
    }
end)

exports("fullName", function(playerId)
    local id = tonumber(playerId)
    local record = id and citizens[id]
    if record then return fullNameOf(record) end
    -- Open77.players.name throws for id <= 0 or a non-integer (console actors arrive
    -- as id 0), and that throw crosses the C boundary and kills this VM before the
    -- caller's pcall can catch it: only look up a real, positive, integer session id.
    if type(id) == "number" and id >= 1 and id % 1 == 0 then
        local name = Open77.players.name(id)
        if name then return name end
    end
    return "Unknown citizen"
end)

exports("isRegistered", function(playerId)
    return citizens[tonumber(playerId) or -1] ~= nil
end)

-- ---------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------

RegisterNetEvent("chat:ready", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId < 1 then return end
    Open77.chat.addSuggestions(playerId, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local ok, reason = Open77.chat.addSuggestions(-1, SUGGESTIONS)
    if not ok then log("chat suggestions refused: " .. tostring(reason)) end
    -- Players already in the world when the resource (re)starts never fire onPlayerReady again.
    for _, playerId in ipairs(Open77.players.all()) do
        local id = tonumber(playerId)
        if id then admit(id) end
    end
    log("civil registry online")
end)
