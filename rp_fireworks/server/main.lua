-- rp_fireworks -- server half, and the whole resource: there is no client code
-- at all, which is the point of the example.
--
-- ONE CLOCK, ONE AUTHORITY. Every shell goes out through Open77.effects.play,
-- which broadcasts it to the players in range. So a show is the same show for
-- everybody: same shell, same world point, same moment. The tempting shortcut
-- -- tell each client "play the show" and let it run its own timers -- drifts
-- within the first volley and gives every player a different spectacle.
--
-- A CUE WITH A `ttlMs` IS NOT A ONE-SHOT. A burst plays out and vanishes; a
-- flare burns and a smoke column pours until something retires them. Fired as
-- one-shots those are still in the world after the show, which is how a
-- celebration leaves a smoking crater behind it. The looping registry owns
-- that lifetime instead (`Open77.effects.create` + `ttlMs`).

local Config = RpFireworksConfig

local state = { running = false, epoch = 0, lastAt = -math.huge, lastShell = nil, lastPoint = nil }

local function log(fmt, ...)
    print(("[rp_fireworks] " .. fmt):format(...))
end

local function say(playerId, text)
    if playerId == nil or playerId == 0 then return log("%s", text) end
    Open77.chat.send(playerId, { author = "SHOW", text = text })
end

local function number(value, fallback)
    local n = tonumber(value)
    return (n ~= nil and n == n) and n or fallback
end

-- ---------------------------------------------------------------------------
-- Placement
-- ---------------------------------------------------------------------------

--- A random shell, minus the one just used. A strict rotation is picked out by
--- eye within two volleys; a straight random draw repeats, and a shell fired
--- twice in a row is the one repetition that reads as a bug rather than chance.
local function nextShell()
    local shells = Config.shells or {}
    if #shells == 0 then return nil end
    if #shells == 1 then return shells[1] end
    local pick
    repeat pick = shells[math.random(#shells)] until pick ~= state.lastShell
    state.lastShell = pick
    return pick
end

--- One beat lands on a disc around `centre`, inside the height band.
---
--- Two details that are not decoration. `math.sqrt` on the radius roll: without
--- it the points crowd the middle, because a uniform roll on the radius is not
--- a uniform distribution on a disc. And the redraw: independent points clump,
--- and two shells thirty metres apart read as one smeared burst, so a point is
--- redrawn until it clears the previous one -- a handful of tries, then take
--- what comes, because a show must never stall on geometry.
local function pointFor(cue, centre)
    local radius = number(cue.radius, number(Config.radius, 40.0))
    local minHeight = number(cue.minHeight, number(Config.minHeight, 25.0))
    local maxHeight = number(cue.maxHeight, number(Config.maxHeight, 45.0))
    local separation = number(Config.minSeparation, 26.0)
    local point
    for _ = 1, 8 do
        local angle = math.random() * math.pi * 2.0
        local distance = math.sqrt(math.random()) * radius
        point = {
            x = centre.x + math.cos(angle) * distance,
            y = centre.y + math.sin(angle) * distance,
            z = centre.z + minHeight + math.random() * math.max(0.0, maxHeight - minHeight),
        }
        local last = state.lastPoint
        if last == nil then break end
        local dx, dy, dz = point.x - last.x, point.y - last.y, point.z - last.z
        if (dx * dx + dy * dy + dz * dz) >= separation * separation then break end
    end
    state.lastPoint = point
    return point
end

--- Fire one copy of a cue. Returns what the registry returned, so the caller
--- can refuse a whole show on its opening beat instead of starting a thread
--- that will fail silently sixty times.
local function fire(cue, centre, bucket, withSound)
    local named = type(cue.effect) == "string" and (Config.effects or {})[cue.effect] or nil
    local effect = named or cue.effect or nextShell()
    if effect == nil then return nil, "no shells configured" end
    local point = pointFor(cue, centre)
    local ttl = math.floor(number(cue.ttlMs, 0))
    if ttl > 0 then
        return Open77.effects.create({
            effect = effect,
            position = point,
            bucket = bucket,
            ttlMs = ttl,
            -- A looping effect is streamed, not broadcast: its visibility is
            -- `streamingRadius`, and the 90 m default would hide it from a
            -- player standing across the square.
            streamingRadius = 400.0,
        })
    end
    return Open77.effects.play(effect, {
        position = point,
        bucket = bucket,
        range = number(Config.range, 500.0),
        sound = withSound and Config.sound or nil,
    })
end

-- ---------------------------------------------------------------------------
-- The show
-- ---------------------------------------------------------------------------

--- Walk the cue list on the server's clock. The epoch is read before every
--- beat, so `stop` lands within one effect -- a thread cannot be killed from
--- outside, and a boolean read at the top of the loop is the whole mechanism.
local function run(cues, centre, bucket, epoch)
    CreateThread(function()
        local elapsed, failures = 0, 0
        for index, cue in ipairs(cues) do
            local at = math.max(0, math.floor(number(cue.at, elapsed)))
            if at > elapsed then
                Wait(at - elapsed)
                elapsed = at
            end
            local count = math.max(1, math.floor(number(cue.count, 1)))
            local spread = math.max(0, math.floor(number(cue.spreadMs, 0)))
            for copy = 1, count do
                if epoch ~= state.epoch then return end
                -- The opening beat was fired by the caller, synchronously, so
                -- that a bad effect name reached whoever asked for the show.
                if index > 1 or copy > 1 then
                    if not fire(cue, centre, bucket, copy == 1) then failures = failures + 1 end
                end
                if copy < count and spread > 0 then
                    Wait(spread)
                    elapsed = elapsed + spread
                end
            end
        end
        if epoch == state.epoch then
            state.running = false
            if failures > 0 then log("%d beat(s) refused by the effect registry", failures) end
        end
    end)
end

--- Start a show at a world point. Answers `true`, or `false` and a reason in
--- plain English -- this is the export, so the reason is what another resource
--- will put in front of a player.
local function play(showName, position, bucket)
    local cues = (Config.shows or {})[showName or Config.defaultShow]
    if type(cues) ~= "table" or #cues == 0 then
        return false, "no show called " .. tostring(showName)
    end
    if type(position) ~= "table" or position.x == nil then
        return false, "the show needs a position"
    end
    -- `Open77.time.monotonic` answers SECONDS, like everywhere else in this
    -- repository; the cooldown is configured in milliseconds because that is
    -- the unit the cues are written in, so one of the two has to convert.
    local now = Open77.time.monotonic() * 1000.0
    if state.running then return false, "a show is already running" end
    if now - state.lastAt < number(Config.cooldownMs, 20000) then
        return false, "the last show was too recent"
    end

    local centre = { x = number(position.x, 0.0), y = number(position.y, 0.0), z = number(position.z, 0.0) }
    -- The bucket is stated, never guessed: a show fired into a routing bucket
    -- nobody occupies is invisible while every call still reports success.
    local ok, reason = fire(cues[1], centre, math.floor(number(bucket, 0)), true)
    if not ok then return false, "the effect registry refused it: " .. tostring(reason) end

    state.epoch = state.epoch + 1
    state.running = true
    state.lastAt = now
    run(cues, centre, math.floor(number(bucket, 0)), state.epoch)
    log("show %s at %.1f %.1f %.1f (bucket %d), %d cues",
        showName or Config.defaultShow, centre.x, centre.y, centre.z,
        math.floor(number(bucket, 0)), #cues)
    return true
end

--- Fire a show over a player -- the form every other resource actually wants.
local function playFor(playerId, showName)
    local position = Open77.players.position(playerId)
    if type(position) ~= "table" then return false, "that player has no position yet" end
    return play(showName, position, position.bucket)
end

local function stop()
    if not state.running then return false, "no show is running" end
    state.epoch = state.epoch + 1
    state.running = false
    return true
end

-- ---------------------------------------------------------------------------
-- Ways in
-- ---------------------------------------------------------------------------

-- Exports, for the resources that have the reason to celebrate: rp_jobs when a
-- convoy lands, rp_race at a finish line, a wedding script at the kiss.
--
--   exports.rp_fireworks:playFor(playerId, "celebration")
--   exports.rp_fireworks:play("burst", { x = ..., y = ..., z = ... }, 0)
exports("play", play)
exports("playFor", playFor)
exports("stop", stop)

-- Restricted (`RegisterCommand(..., true)`): the platform refuses a player
-- without `command.<name>` before this handler runs, and the dedicated console
-- (source 0) is always allowed. There is no rights check in this file, because
-- a check here would be a rights system enforced by the thing it grants.
RegisterCommand(Config.command or "fireworks", function(source, args)
    local wanted = args[1]
    if wanted == "stop" then
        local ok, reason = stop()
        return say(source, ok and "Show ended." or ("Nothing to stop: " .. reason))
    end
    if source == 0 then
        -- The console has no body, so it names the point and the routing
        -- bucket itself: `fireworks <show> <x> <y> <z> [bucket]`. The bucket is
        -- stated rather than guessed, because a show fired into a bucket
        -- nobody occupies is invisible while every call still reports success.
        local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
        if x == nil or y == nil or z == nil then
            return log("usage from the console: %s <show> <x> <y> <z> [bucket]", Config.command or "fireworks")
        end
        local okConsole, reasonConsole = play(wanted, { x = x, y = y, z = z }, tonumber(args[5]) or 0)
        return log("%s", okConsole and "show started" or ("no show: " .. tostring(reasonConsole)))
    end
    local ok, reason = playFor(source, wanted)
    if not ok then return say(source, "No show: " .. reason) end
    say(source, "Lighting up the sky.")
end, true)

log("ready -- %d shells, shows: %s", #(Config.shells or {}), (function()
    local names = {}
    for name in pairs(Config.shows or {}) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ", ")
end)())
