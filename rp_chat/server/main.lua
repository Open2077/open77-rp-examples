-- rp_chat: roleplay chat commands (/me, /do, /ooc, /w, /dice, /showid).
-- Server-only. The server decides the audience (proximity), reads names, jobs
-- and balances, and pushes chat lines through the Open77.chat facade.

local RESOURCE = GetCurrentResourceName()

-- Radii in metres.
local RADIUS_ME = 30.0
local RADIUS_DO = 30.0
local RADIUS_DICE = 30.0
local RADIUS_WHISPER = 10.0
local RADIUS_SHOWID = 5.0

-- Text limit (bytes). Chat accepts up to 4,096; RP lines are kept short.
local MAX_TEXT_BYTES = 512

-- Dice bounds.
local DICE_DEFAULT = 6
local DICE_MIN = 2
local DICE_MAX = 1000

-- Colours: positional { r, g, b } arrays, never keyed tables (the chat UI
-- silently ignores a keyed { r = ..., g = ..., b = ... } table).
local COLOR_ME = { 194, 122, 255 }
local COLOR_DO = { 170, 140, 255 }
local COLOR_OOC = { 160, 160, 160 }
local COLOR_WHISPER = { 120, 120, 140 }
local COLOR_DICE = { 255, 200, 80 }
local COLOR_INFO = { 0, 229, 255 }
local COLOR_ERROR = { 255, 96, 96 }

-- Message formats (player-facing, English).
local FORMAT_ME = "* %s %s"
local FORMAT_DO = "** %s ((%s))"
local FORMAT_OOC = "(( OOC ) %s: %s"
local FORMAT_WHISPER_TO_TARGET = "(whisper) %s: %s"
local FORMAT_WHISPER_TO_SENDER = "(whisper to %s) %s: %s"
local FORMAT_DICE = "%s rolls a die (%d): %d"

-- Slash-command suggestions published on chat:ready and on start.
local SUGGESTIONS = {
    { command = "/me", help = "Describe an action of your character (30 m)",
      parameters = { { name = "action", help = "The action performed" } } },
    { command = "/do", help = "Describe a situation or the surroundings (30 m)",
      parameters = { { name = "description", help = "What the others perceive" } } },
    { command = "/ooc", help = "Out-of-character message, visible to the whole server",
      parameters = { { name = "text", help = "Your message" } } },
    { command = "/w", help = "Whisper to a nearby player (10 m)",
      parameters = { { name = "playerId", help = "Player id (/id)" },
                     { name = "text", help = "Your message" } } },
    { command = "/dice", help = "Roll a die (6 sides by default, 30 m)",
      parameters = { { name = "sides", help = "Number of sides, optional (2 to 1000)" } } },
    { command = "/showid", help = "Show your ID card, or a nearby player's (5 m)",
      parameters = { { name = "playerId", help = "Target player, optional" } } },
}

-- Player-facing wording for the reasons the natives return.
local REASON_TEXT = {
    player_not_found = "Player not found.",
    invalid_player_id = "Invalid player id.",
    invalid_argument = "Invalid player id.",
    position_unknown = "Position unknown: the player is not in the world yet.",
    sessions_unavailable = "Player sessions unavailable right now.",
    invalid_chat_target = "Invalid chat recipient.",
    invalid_chat_message = "Invalid chat message.",
    event_queue_limit = "Message queue full, try again.",
    resource_preparing = "The resource is not ready yet.",
    resource_stopping = "The resource is stopping.",
}

local function reasonText(reason)
    return REASON_TEXT[reason] or ("Error: " .. tostring(reason))
end

-- Log helper: every line carries the resource name.
local function log(fmt, ...)
    print(("[%s] " .. fmt):format(RESOURCE, ...))
end

-- One chat line to one player (or -1 for everyone), in the documented table shape.
local function sendLine(target, author, text, color)
    local ok, reason = Open77.chat.send(target, {
        type = "system",
        author = author,
        text = text,
        color = color,
    })
    if not ok then
        log("chat.send to %s failed: %s", tostring(target), tostring(reason))
    end
    return ok, reason
end

-- A short error or notice to the caller only.
local function tell(source, text, color)
    return sendLine(source, "RP", text, color or COLOR_ERROR)
end

-- Refuses the console politely; commands here need a body in the world.
local function requirePlayer(source, command)
    if type(source) ~= "number" or source <= 0 then
        log("/%s refused: run it from the game, not the console", command)
        return false
    end
    return true
end

-- The caller's display name, or a fallback that never crashes.
local function nameOf(playerId)
    local name = Open77.players.name(playerId)
    if type(name) ~= "string" or name == "" then
        return ("Player %s"):format(tostring(playerId))
    end
    return name
end

-- Joins the command arguments from index `from`, trimmed; nil when empty.
local function joinArgs(args, from)
    local parts = {}
    for i = from, (args.n or #args) do
        local value = args[i]
        if value ~= nil then
            parts[#parts + 1] = tostring(value)
        end
    end
    local text = table.concat(parts, " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

-- Validates a free-text argument; tells the caller why when it is refused.
local function requireText(source, text, usage)
    if not text then
        tell(source, "Usage: " .. usage)
        return false
    end
    if #text > MAX_TEXT_BYTES then
        tell(source, ("Message too long (%d bytes max)."):format(MAX_TEXT_BYTES))
        return false
    end
    return true
end

-- Parses a player id argument (a string from chat) into a positive integer.
local function parsePlayerId(raw)
    if raw == nil then
        return nil
    end
    local id = tonumber(raw)
    if not id or id <= 0 or id % 1 ~= 0 then
        return nil
    end
    return math.tointeger(id) or id
end

-- Sends one line to every player within `radius` of the caller, caller included.
-- Returns the number of recipients, or nil, reason when the audience is unknown.
local function sendNearby(source, radius, author, text, color)
    local entries, reason = Open77.players.nearby(source, radius, { includeSelf = true })
    if not entries then
        return nil, reason
    end
    local delivered = 0
    for _, entry in ipairs(entries) do
        local playerId = tonumber(entry.playerId) or entry.playerId
        if sendLine(playerId, author, text, color) then
            delivered = delivered + 1
        end
    end
    return delivered
end

-- A proximity command's shared tail: send, or explain why nobody heard it.
local function announceNearby(source, command, radius, author, text, color)
    local delivered, reason = sendNearby(source, radius, author, text, color)
    if not delivered then
        tell(source, "Message not sent. " .. reasonText(reason))
        log("/%s by %d not delivered: %s", command, source, tostring(reason))
        return
    end
    log("/%s by %d -> %d recipient(s): %s", command, source, delivered, text)
end

-- Distance check between two players; tells the caller why when it fails.
local function withinRange(source, target, radius)
    local metres, reason = Open77.players.distance(source, target)
    if not metres then
        tell(source, reasonText(reason))
        return false
    end
    if metres > radius then
        tell(source, ("Too far: %s is %.0f m away (%.0f m max)."):format(
            nameOf(target), metres, radius))
        return false
    end
    return true
end

-- Cross-resource reads. Synchronous exports raise on failure (missing
-- resource, missing export, callee error), so every call is wrapped in pcall
-- and a failure degrades to "unknown" instead of crashing the command.
local function getJob(playerId)
    local ok, job = pcall(function()
        return exports.rp_jobs:getJob(playerId)
    end)
    if not ok then
        log("rp_jobs:getJob unavailable: %s", tostring(job))
        return nil
    end
    if type(job) ~= "string" or job == "" then
        return nil
    end
    return job
end

local function getBalance(playerId)
    local ok, balance = pcall(function()
        return exports.rp_economy:getBalance(playerId)
    end)
    if not ok then
        log("rp_economy:getBalance unavailable: %s", tostring(balance))
        return nil
    end
    if type(balance) ~= "number" or balance ~= balance or math.abs(balance) == math.huge then
        return nil
    end
    return math.floor(balance)
end

-- Whether the server notifications API can actually reach a client: the
-- native must exist and the official package must be running, otherwise a
-- toast is dropped without a word and the card falls back to chat.
local function notificationsAvailable()
    if type(Open77.notifications) ~= "table" or type(Open77.notifications.send) ~= "function" then
        return false
    end
    if type(Open77.resource) == "table" and type(Open77.resource.state) == "function" then
        return Open77.resource.state("open77_notifications") == "running"
    end
    return true
end

-- Builds the identity card lines. The balance is only shown on the owner's card.
local function buildCard(viewer, target)
    local lines = {
        "Name: " .. nameOf(target),
        "Job: " .. (getJob(target) or "unemployed"),
    }
    if viewer == target then
        local balance = getBalance(target)
        if balance then
            lines[#lines + 1] = ("Balance: %d €$"):format(balance)
        else
            lines[#lines + 1] = "Balance: unavailable"
        end
    end
    return lines
end

-- Delivers a card: a toast when the notifications API exists, else chat lines.
local function deliverCard(viewer, target, lines)
    local title = "ID card"
    if viewer ~= target then
        title = title .. " of " .. nameOf(target)
    end
    if notificationsAvailable() then
        local id, reason = Open77.notifications.send(viewer, {
            type = "info",
            title = title,
            message = table.concat(lines, " | "),
            icon = "ID",
            durationMs = 8000,
        })
        if id then
            return "notification"
        end
        log("notifications.send to %d failed (%s), falling back to chat", viewer, tostring(reason))
    end
    -- Chat: one line per tick so they read in order (same-tick sends arrive reversed).
    sendLine(viewer, "ID", "--- " .. title .. " ---", COLOR_INFO)
    for _, line in ipairs(lines) do
        Wait(0)
        sendLine(viewer, "ID", line, COLOR_INFO)
    end
    return "chat"
end

-- /me <action>
RegisterCommand("me", function(source, args)
    if not requirePlayer(source, "me") then return end
    local action = joinArgs(args, 1)
    if not requireText(source, action, "/me <action>") then return end
    local text = FORMAT_ME:format(nameOf(source), action)
    announceNearby(source, "me", RADIUS_ME, "RP", text, COLOR_ME)
end, false)

-- /do <description>
RegisterCommand("do", function(source, args)
    if not requirePlayer(source, "do") then return end
    local description = joinArgs(args, 1)
    if not requireText(source, description, "/do <description>") then return end
    local text = FORMAT_DO:format(description, nameOf(source))
    announceNearby(source, "do", RADIUS_DO, "RP", text, COLOR_DO)
end, false)

-- /ooc <text>
RegisterCommand("ooc", function(source, args)
    if not requirePlayer(source, "ooc") then return end
    local message = joinArgs(args, 1)
    if not requireText(source, message, "/ooc <text>") then return end
    local text = FORMAT_OOC:format(nameOf(source), message)
    local ok, reason = sendLine(-1, "OOC", text, COLOR_OOC)
    if not ok then
        tell(source, "Message not sent. " .. reasonText(reason))
        return
    end
    log("/ooc by %d: %s", source, message)
end, false)

-- /w <playerId> <text>
RegisterCommand("w", function(source, args)
    if not requirePlayer(source, "w") then return end
    local target = parsePlayerId(args[1])
    if not target then
        tell(source, "Usage: /w <playerId> <text>")
        return
    end
    local message = joinArgs(args, 2)
    if not requireText(source, message, "/w <playerId> <text>") then return end
    if target == source then
        tell(source, "You can't whisper to yourself.")
        return
    end
    if not Open77.players.name(target) then
        tell(source, reasonText("player_not_found"))
        return
    end
    if not withinRange(source, target, RADIUS_WHISPER) then return end

    local senderName, targetName = nameOf(source), nameOf(target)
    local ok, reason = sendLine(target, "Whisper",
        FORMAT_WHISPER_TO_TARGET:format(senderName, message), COLOR_WHISPER)
    if not ok then
        tell(source, "Whisper not sent. " .. reasonText(reason))
        return
    end
    sendLine(source, "Whisper",
        FORMAT_WHISPER_TO_SENDER:format(targetName, senderName, message), COLOR_WHISPER)
    log("/w %d -> %d: %s", source, target, message)
end, false)

-- /dice [faces]
RegisterCommand("dice", function(source, args)
    if not requirePlayer(source, "dice") then return end
    local faces = DICE_DEFAULT
    if args.n and args.n >= 1 and args[1] ~= nil then
        local wanted = tonumber(args[1])
        if not wanted or wanted % 1 ~= 0 or wanted < DICE_MIN or wanted > DICE_MAX then
            tell(source, ("Invalid number of sides (%d to %d)."):format(DICE_MIN, DICE_MAX))
            return
        end
        faces = math.tointeger(wanted) or DICE_DEFAULT
    end
    local roll = math.random(1, faces)
    local text = FORMAT_DICE:format(nameOf(source), faces, roll)
    announceNearby(source, "dice", RADIUS_DICE, "Dice", text, COLOR_DICE)
end, false)

-- /showid [playerId]
RegisterCommand("showid", function(source, args)
    if not requirePlayer(source, "showid") then return end
    local target = source
    if args.n and args.n >= 1 and args[1] ~= nil then
        target = parsePlayerId(args[1])
        if not target then
            tell(source, "Usage: /showid [playerId]")
            return
        end
        if target ~= source then
            if not Open77.players.name(target) then
                tell(source, reasonText("player_not_found"))
                return
            end
            if not withinRange(source, target, RADIUS_SHOWID) then return end
        end
    end
    local lines = buildCard(source, target)
    local channel = deliverCard(source, target, lines)
    log("/showid by %d for %d via %s", source, target, channel)
end, false)

-- Suggestions: per player when their chat comes up, and once for everyone on start.
RegisterNetEvent("chat:ready", function()
    -- Bus events can reach this handler too: only answer an authenticated player.
    if type(source) ~= "number" or source <= 0 then return end
    local ok, reason = Open77.chat.addSuggestions(source, SUGGESTIONS)
    if not ok then
        log("addSuggestions for %d failed: %s", source, tostring(reason))
    end
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    local ok, reason = Open77.chat.addSuggestions(-1, SUGGESTIONS)
    if not ok then
        log("addSuggestions for everyone failed: %s", tostring(reason))
    end
    log("started: /me /do /ooc /w /dice /showid (notifications: %s)",
        notificationsAvailable() and "toast" or "chat fallback")
end)
