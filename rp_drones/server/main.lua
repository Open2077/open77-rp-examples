-- rp_drones -- server half, and the whole resource: there is no client code.
--
-- ONE CLOCK, ONE AUTHORITY. Every drone is a server-owned entity and every
-- position it ever holds is written by this file. A client is told where the
-- swarm is; it never decides. That is what makes two players standing side by
-- side watch the same 77 at the same instant, and it is not a stylistic
-- preference: the obvious shortcut -- hand each client the formation list and
-- let it walk its own timers -- drifts within the first morph, because each
-- client's clock is its own.
--
-- THREE MEASURED FACTS SHAPE EVERY DECISION BELOW. All three were read out of
-- the platform's own source rather than guessed, and the README cites them.
--
--   1. THE LINK IS 256 KB/s AND IT DISCONNECTS, IT DOES NOT DEGRADE.
--      GameNetworkingSockets clamps every connection's send rate there and
--      the transport turns the resulting LimitExceeded into a DISCONNECT once
--      512 KB has queued. The first build of this resource sent 415 KB/s of
--      drone traffic and dropped the player it was performing for, eight
--      seconds into the opening morph. Hence `budgetedRate`: the update rate
--      is DERIVED from a byte budget and a show that will not fit is refused
--      before a single drone is spawned.
--
--   2. EVERY UPDATE IS A WHOLE RECORD, TO EVERY VIEWER, IMMEDIATELY. The
--      server does not coalesce, does not diff, and does not skip a write
--      that changed nothing -- 490 bytes to move a point one step. Hence
--      `clock.moveEpsilon` and `snap`: this file does the skipping and the
--      rounding itself, which is why holding a formation costs nothing.
--
--   3. THERE IS NO CLIENT-SIDE INTERPOLATION. A projected prop's position is
--      written with entIPlacedComponent::SetLocalPosition -- a hard jump. So
--      the update rate IS the swarm's frame rate, and since the rate is set
--      by the budget, the SPEED is what has to give: `clock.maxStepMetres`
--      fixes how far a drone may jump and every morph is stretched to obey it.
--
--   4. A LIGHT IS NOT A DRONE. A `kind = "light"` prop is culled by the
--      renderer past 50 m -- its host inherits a loot crate's authored
--      `autoHideDistance` -- and a point light in empty air illuminates
--      nothing and draws no pixels of its own. Both were confirmed only after
--      flying a whole invisible show. The default style is now the VFX, and
--      `farthestDrone` refuses a light show that would be culled.
--
--   5. A LIGHT'S COLOUR CANNOT BE ANIMATED. Writing colour or intensity
--      disables the light component for one frame before re-enabling it, so a
--      per-tick colour blend strobes. Colour therefore changes only on
--      arrival at a pose, where the blink reads as a flash.

local Config = RpDronesConfig
local Formations = RpDronesFormations

-- The chosen style and choreography outlive a reload. See the `style` and
-- `choreo` commands, and the note on why in `style`.
local STYLE_KEY = "droneshow:style"
local CHOREO_KEY = "droneshow:choreography"
local GUARD_KEY = "droneshow:sweepguard"
local FRAME_KEY = "droneshow:framems"

--- Every word the command handler consumes before it looks for a show.
---
--- A show named after one of these is unreachable: the subcommand wins and the
--- operator gets an answer to a question they did not ask. That is not
--- hypothetical -- `droneshow choreo <x> <y> <z>` set the driver and reported
--- "Choreography is cut or sequence" instead of playing the show called
--- `choreo`, from a console, silently. `validate` refuses to arm on a
--- collision, which turns a puzzling non-event into a start-up error naming
--- the show to rename.
local RESERVED = {
    stop = true, style = true, choreo = true, sweepguard = true,
    frame = true, probe = true, npcprobe = true, npcmove = true,
    lightbench = true, status = true,
}

local state = {
    -- SEVERAL SHOWS AT ONCE. Keyed by show name, because that is the handle an
    -- operator already has: `droneshow stop parade` has to mean something.
    --
    -- The stop mechanism is a flag ON THE RUN rather than a global epoch. A
    -- thread still cannot be killed from outside, so it still reads a value
    -- before every beat -- but with several shows in the air a single epoch
    -- would stop all of them, and the run table is already the identity of the
    -- one thread that owns it.
    runs = {},
    lastAt = -math.huge,
    style = nil, -- nil means "whatever the config says"
    choreography = nil, -- ditto, for the npc style's cut vs sequence
    frameMs = nil, -- a bisection override for the sequence driver
    sweepGuard = nil, -- nil = config; otherwise true/false for this session
    guardHeld = nil, -- the bucket policy this resource is currently overriding
    probe = nil,
    probeIndex = 0,
    npcProbe = nil,
    npcProbeIndex = 0,
    npcProbeEpoch = 0,
    npcMove = nil,
    npcMoveEpoch = 0,
    bench = nil,
    ready = false,
}

local function log(fmt, ...)
    print(("[rp_drones] " .. fmt):format(...))
end

local function say(playerId, text)
    if playerId == nil or playerId == 0 then return log("%s", text) end
    -- `Open77.chat.send` grants nothing: the facade publishes on the host bus
    -- and never reaches a client itself, so it needs no `network.events`.
    Open77.chat.send(playerId, { author = "SKY", text = text })
end

local function number(value, fallback)
    local n = tonumber(value)
    return (n ~= nil and n == n) and n or fallback
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--- Every show currently in the air, newest last.
local function liveRuns()
    local out = {}
    for _, run in pairs(state.runs) do out[#out + 1] = run end
    table.sort(out, function(a, b) return a.startedAt < b.startedAt end)
    return out
end

local function anyRunning()
    return next(state.runs) ~= nil
end

--- How many players are connected. Guarded because `#nil` is a runtime error,
--- and a runtime error inside the show thread is exactly the failure this
--- resource must not have: it would stop the walk and leave the swarm up.
local function audience()
    local roster = Open77.players.all()
    return type(roster) == "table" and #roster or 0
end

-- ---------------------------------------------------------------------------
-- Start-up validation
--
-- Everything that can be wrong about a configuration is wrong before the first
-- show, not during it. A resource that refuses to arm is a five-second fix; a
-- resource that half-flies a show leaves props in the sky.
-- ---------------------------------------------------------------------------

local function validate()
    if type(Formations) ~= "table" or type(Formations.shapes) ~= "table" then
        return false, "shared/formations.lua did not load; run tools/make-formations.py"
    end

    local wanted = math.floor(number(Config.droneCount, 0))
    if wanted < 8 then
        return false, "droneCount must be at least 8 for a shape to read"
    end
    if wanted > math.floor(number(Config.maxDrones, 120)) then
        return false, ("droneCount %d is past maxDrones %d"):format(wanted, math.floor(number(Config.maxDrones, 120)))
    end
    if Formations.count ~= wanted then
        return false, ("droneCount is %d but the formations hold %d points -- "):format(wanted, Formations.count)
            .. ("run: python tools/make-formations.py --count %d"):format(wanted)
    end

    for name, points in pairs(Formations.shapes) do
        if #points ~= wanted then
            return false, ("formation %s holds %d points, expected %d"):format(name, #points, wanted)
        end
    end

    for showName, steps in pairs(Config.shows or {}) do
        if RESERVED[showName] then
            return false, ("show %s collides with the subcommand of the same name and "):format(showName)
                .. "would be unreachable -- rename it"
        end
        if type(steps) ~= "table" or #steps == 0 then
            return false, ("show %s is empty"):format(showName)
        end
        for index, step in ipairs(steps) do
            if Formations.shapes[step.formation] == nil then
                return false, ("show %s step %d names unknown formation %s")
                    :format(showName, index, tostring(step.formation))
            end
            if step.place ~= "stage" and step.place ~= "pad" then
                return false, ("show %s step %d: place must be stage or pad"):format(showName, index)
            end
            if step.color ~= nil and (Config.palette or {})[step.color] == nil then
                return false, ("show %s step %d names unknown colour %s")
                    :format(showName, index, tostring(step.color))
            end
            if step.lit ~= nil and type(step.lit) ~= "boolean" then
                return false, ("show %s step %d: lit must be true or false"):format(showName, index)
            end
            if step.blackout ~= nil and number(step.blackout, nil) == nil then
                return false, ("show %s step %d: blackout must be a number of milliseconds")
                    :format(showName, index)
            end
        end
    end

    if (Config.shows or {})[Config.defaultShow] == nil then
        return false, ("defaultShow %s is not a show"):format(tostring(Config.defaultShow))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

--- The plane the picture is drawn on.
---
--- THE PICTURE ALWAYS FACES THE ANCHOR. `facing` chooses which way the show is
--- from the operator; the plane's normal is then taken from the anchor to the
--- stage centre, so the audience never gets the picture edge-on. That is
--- deliberate insurance: if the yaw convention here is a quarter-turn out, the
--- show appears in the wrong compass direction and still reads correctly,
--- instead of becoming an invisible line of lights.
--- The stage a show is drawn on: its own, falling back to the global one field
--- by field.
---
--- A sign is not a ring. `OPEN//77` needs to be wider than it is tall and to
--- hang further back to fit in the frame, and forcing the global stage to suit
--- it would ruin every other show. So a show may carry a `stage` table and
--- override only what it cares about.
local function stageOf(steps)
    local base = Config.stage or {}
    local own = type(steps) == "table" and type(steps.stage) == "table" and steps.stage or nil
    if own == nil then return base end
    return {
        facing = number(own.facing, base.facing),
        standoff = number(own.standoff, base.standoff),
        altitude = number(own.altitude, base.altitude),
        width = number(own.width, base.width),
        height = number(own.height, base.height),
    }
end

local function stageBasis(anchor, facingDeg, standoffOverride, stageOverride)
    local radians = math.rad(number(facingDeg, 0.0))
    -- REDengine yaw: 0 looks along +Y, positive turns counter-clockwise.
    local forwardX, forwardY = -math.sin(radians), math.cos(radians)

    local stage = stageOverride or Config.stage or {}
    local standoff = number(standoffOverride, number(stage.standoff, 24.0))
    local centreX = anchor.x + forwardX * standoff
    local centreY = anchor.y + forwardY * standoff

    -- Normal: from the stage centre back to the anchor.
    local normalX, normalY = anchor.x - centreX, anchor.y - centreY
    local length = math.sqrt(normalX * normalX + normalY * normalY)
    if length < 0.001 then
        normalX, normalY, length = -forwardX, -forwardY, 1.0
    end
    normalX, normalY = normalX / length, normalY / length

    -- right = up x normal, with up = +Z. The stage rides on the basis so that
    -- every point of a show is placed against the SAME geometry -- a sign with
    -- its own stage must not have half its letters drawn on the global one.
    return {
        centreX = centreX,
        centreY = centreY,
        groundZ = anchor.z,
        rightX = -normalY,
        rightY = normalX,
        normalX = normalX,
        normalY = normalY,
        stage = stage,
    }
end

--- One normalised formation point placed in the world.
---
--- "stage" is a plane standing up in the sky: u across, v up, w toward the
--- audience. "pad" is the same plane laid flat on the ground: u across,
--- v along the ground away from the audience, w up.
local function worldPoint(basis, place, point)
    local u, v, w = number(point[1], 0.0), number(point[2], 0.0), number(point[3], 0.0)
    if place == "pad" then
        local pad = Config.pad or {}
        local halfWidth = number(pad.width, 22.0) * 0.5
        local halfDepth = number(pad.depth, 16.0) * 0.5
        return {
            x = basis.centreX + basis.rightX * u * halfWidth - basis.normalX * v * halfDepth,
            y = basis.centreY + basis.rightY * u * halfWidth - basis.normalY * v * halfDepth,
            z = basis.groundZ + number((Config.pad or {}).altitude, 2.0) + w * halfDepth,
        }
    end
    local stage = basis.stage or Config.stage or {}
    local halfWidth = number(stage.width, 22.0) * 0.5
    local halfHeight = number(stage.height, 22.0) * 0.5
    return {
        x = basis.centreX + basis.rightX * u * halfWidth + basis.normalX * w * halfWidth,
        y = basis.centreY + basis.rightY * u * halfWidth + basis.normalY * w * halfWidth,
        z = basis.groundZ + number(stage.altitude, 16.0) + v * halfHeight,
    }
end

--- Rounds a position to the configured precision BEFORE it is ever sent.
---
--- A full round-trip double is up to 19 characters and three of them ride in
--- every update; two decimals is 1 cm, which is invisible at any distance this
--- show is watched from, and it takes 7% off every message. Rounding here
--- rather than at the send call also keeps the dead band honest: the position
--- compared is the position transmitted.
local snapScale = 10 ^ math.floor(clamp(number((Config.clock or {}).positionDecimals, 2), 0, 6))
local function snap(position)
    return {
        x = math.floor(position.x * snapScale + 0.5) / snapScale,
        y = math.floor(position.y * snapScale + 0.5) / snapScale,
        z = math.floor(position.z * snapScale + 0.5) / snapScale,
    }
end

local function poseFor(basis, step)
    local shape = Formations.shapes[step.formation]
    local pose = {}
    for index = 1, #shape do
        pose[index] = snap(worldPoint(basis, step.place, shape[index]))
    end
    return pose
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- How far the farthest drone of a whole show will sit from the anchor.
---
--- This exists for one reason. The `light` style's host entity is cloned from
--- a loot crate and inherits its authored `autoHideDistance = 50`, so the
--- renderer culls a light drone past fifty metres -- silently, with the prop
--- still spawned, still projected, still logged as created. That is exactly
--- how the first build of this resource flew a whole show that nobody could
--- see. Measuring the geometry up front turns it into a refusal.
local function farthestDrone(basis, anchor, steps)
    local worst = 0.0
    for _, step in ipairs(steps) do
        local shape = Formations.shapes[step.formation]
        for index = 1, #shape do
            local span = distance(anchor, worldPoint(basis, step.place, shape[index]))
            if span > worst then worst = span end
        end
    end
    return worst
end

--- Which drone flies to which point.
---
--- GLOBALLY greedy: score every drone-target pair, sort, and take them
--- shortest first, skipping any pair whose drone or target is already spoken
--- for. It is not the optimal assignment -- that wants a Hungarian solver, and
--- this is a light show -- but it is worth the six extra lines over the naive
--- version, which walks the targets in order and leaves the last ones to
--- whichever drones happen to be left. Measured on the shipped show, going
--- global cuts the AVERAGE distance flown per morph from 15.4 m to 9.6 m: the
--- swarm rearranges instead of churning.
---
--- It runs ONCE per morph, never per tick. 2,304 pairs at 48 drones.
local function assign(from, to)
    local pairs_ = {}
    for droneIndex = 1, #from do
        for targetIndex = 1, #to do
            pairs_[#pairs_ + 1] = {
                d = distance(from[droneIndex], to[targetIndex]),
                i = droneIndex,
                j = targetIndex,
            }
        end
    end
    table.sort(pairs_, function(a, b) return a.d < b.d end)

    local usedDrone, usedTarget, targets, matched = {}, {}, {}, 0
    for index = 1, #pairs_ do
        local pair = pairs_[index]
        if not usedDrone[pair.i] and not usedTarget[pair.j] then
            usedDrone[pair.i] = true
            usedTarget[pair.j] = true
            targets[pair.i] = to[pair.j]
            matched = matched + 1
            if matched == #from then break end
        end
    end
    -- Belt and braces: a drone the loop somehow missed holds its ground rather
    -- than flying to nil.
    for droneIndex = 1, #from do
        if targets[droneIndex] == nil then targets[droneIndex] = from[droneIndex] end
    end
    return targets
end

-- ---------------------------------------------------------------------------
-- What a drone is made of
--
-- Two styles, one interface: create at a point, move to a point, remove. The
-- rest of this file does not know which is running.
-- ---------------------------------------------------------------------------

local function activeStyle()
    local style = state.style or (Config.drone or {}).style or "effect"
    if style == "npc" or style == "effect" or style == "light" then return style end
    return "effect"
end

--- How far a drone of this style may jump between two updates.
---
--- Per style because it depends on whether the CLIENT interpolates. A prop and
--- an effect do not: the position is a hard engine write, so the step is what
--- the eye sees. An NPC does, which is why its limit is coarser.
local function stepLimit(style)
    local configured = (Config.clock or {}).maxStepMetres
    if type(configured) == "table" then
        return math.max(0.01, number(configured[style], 0.6))
    end
    return math.max(0.01, number(configured, 0.6))
end

--- How a style gets its drones from one figure to the next.
---
---   "stream"  write a position several times a second and let the drone walk
---             the interpolation. Props and effects, and the only thing they
---             can do.
---   "cut"     despawn the swarm, black the sky out, and respawn it already in
---             the next formation. The npc style, and the only thing IT can
---             do: a server transform write reaches an NPC's canonical record
---             and never reaches the rendered body. Measured on screen
---             2026-09-20 -- 58 accepted writes, steps up to 7.79 m, and four
---             captures with the camera unmoved showing the drone on the same
---             pixel. Not the 2 m deadband, not the lease: it simply does not
---             arrive.
---   "task"    hand out destinations and let the engine fly them. Wired, never
---             worked: every movement task ends in `AI::MoveToCommand` with
---             `ignoreNavigation = false` hard-coded and a walk/run/sprint
---             movement type. Kept so a probe can demonstrate it rather than
---             a comment assert it.
local function driverFor(style)
    if style ~= "npc" then return "stream" end
    local npc = (Config.drone or {}).npc or {}
    if npc.movement == "task" then return "task" end
    -- `flipbook` is the name; `sequence` is accepted as a synonym because it
    -- was called that for an afternoon, while a measurement that later turned
    -- out to be an artefact of this resource's own defect said it was a
    -- slideshow. The internal driver id stays `sequence` deliberately -- a
    -- blanket rename through this file is exactly what put a budget log inside
    -- `walk` once already, and the identifier is not what anybody reads.
    local choreography = state.choreography or npc.choreography
    if choreography == "hybrid" then return "hybrid" end
    if choreography == "flipbook" or choreography == "sequence" then return "sequence" end
    return "cut"
end

local function taskDriven(style)
    return driverFor(style) == "task"
end

--- The complete light table for a colour key.
---
--- COMPLETE, always: the server carries the light through as opaque JSON and
--- replaces it wholesale, so a patch naming only `color` would hand the client
--- an intensity of zero and turn the swarm off.
---
--- Memoised so that two steps sharing a colour hand the client bit-identical
--- numbers. The client only rewrites the component when the table differs, and
--- a rewrite blinks the lamp for a frame -- a colour that "changes" to the
--- same value would be a flicker nobody asked for.
local lightCache = {}
local function lightFor(colorName, lit)
    local name = colorName or Config.defaultColor or "white"
    local key = name .. (lit == false and ":off" or ":on")
    if lightCache[key] ~= nil then return lightCache[key] end
    local rgb = (Config.palette or {})[name] or { 1.0, 1.0, 1.0 }
    local settings = (Config.drone or {}).light or {}
    lightCache[key] = {
        -- The keys are x/y/z and not r/g/b: the field goes through the shared
        -- vector reader and an { r, g, b } table is refused as invalid_color.
        color = {
            x = clamp(number(rgb[1], 1.0), 0.0, 1.0),
            y = clamp(number(rgb[2], 1.0), 0.0, 1.0),
            z = clamp(number(rgb[3], 1.0), 0.0, 1.0),
        },
        intensity = clamp(number(settings.intensity, 6000.0), 0.0, 10000.0),
        radius = clamp(number(settings.radius, 120.0), 0.1, 500.0),
        spot = settings.spot == true,
        enabled = lit ~= false,
    }
    return lightCache[key]
end

--- Spawn one drone. Answers its id, or nil and a reason.
---
--- `lit` false spawns it dark, which is how a show reveals itself: the swarm
--- appears already in formation and then ignites. That replaced a launch from
--- a pad on the ground, which looked better and cost two 75 m morphs -- about
--- 60% of the show's whole bandwidth bill -- for the privilege.
local function spawnDrone(style, position, bucket, colorName, lit, ttlMs, effectOverride)
    local radius = clamp(number(Config.streamingRadius, 900.0), 10.0, 2000.0)
    local hysteresis = clamp(number(Config.streamingHysteresis, 150.0), 0.0, radius)

    if style == "npc" then
        local npc = (Config.drone or {}).npc or {}
        -- HARMLESS BY CONSTRUCTION, and in that order: the record is chosen
        -- from the non-combat family first, then every switch the API exposes
        -- is thrown against it. A drone show must not be able to shoot its
        -- audience even if the record it was pointed at turns out to be a
        -- gunship.
        --
        -- `aiMode = frozen` is the one that matters for a formation: it
        -- revokes the simulation lease and suspends every task channel, so
        -- nothing drives the body but this resource's own transforms. There
        -- is no autonomous flight to fight with, and nothing to make it
        -- wander off mid-figure.
        --
        -- `despawnWhenUnobserved = false` because a show is watched from one
        -- side: the far half of the picture must not evaporate.
        local id, reason = Open77.npcs.create({
            record = effectOverride or npc.record or "Character.Drone_Bombus_Base",
            -- nil keeps the template's own default. A named variant is the
            -- cheapest possible answer to "the light should come from the
            -- drone": four of the nine this rig authors are surveillance
            -- variants, and a surveillance drone is the one the base game
            -- flies with a lit sensor head.
            appearance = npc.appearance,
            position = position,
            yaw = 0.0,
            bucket = bucket,
            aiMode = taskDriven(style) and Open77.npcs.ai.tasks or Open77.npcs.ai.frozen,
            damagePolicy = Open77.npcs.damage.invulnerable,
            behavior = {
                aiEnabled = taskDriven(style),
                combatEnabled = false,
                perceptionEnabled = false,
                voiceEnabled = false,
            },
            streamingRadius = radius,
            streamingHysteresis = hysteresis,
            despawnWhenUnobserved = false,
            persistent = false,
        })
        if id == nil then return nil, reason end
        -- Friendly to everyone with no `towards` row: the default that covers
        -- every target which has no row of its own. Belt on top of the braces
        -- of combatEnabled = false.
        Open77.npcs.setAttitude(id, "friendly")
        return id
    end

    if style == "effect" then
        return Open77.effects.create({
            effect = effectOverride or (Config.drone or {}).effect or "race.firework.burst",
            position = position,
            bucket = bucket,
            visible = lit ~= false,
            streamingRadius = radius,
            streamingHysteresis = hysteresis,
            ttlMs = ttlMs,
        })
    end
    return Open77.props.create({
        model = (Config.drone or {}).model or "light.candle",
        kind = "light",
        position = position,
        yaw = 0.0,
        bucket = bucket,
        light = lightFor(colorName, lit),
        streamingRadius = radius,
        streamingHysteresis = hysteresis,
        ttlMs = ttlMs,
    })
end

local function moveDrone(style, id, position)
    if style == "npc" then
        -- A teleport, deliberately: `setTransform` writes the canonical
        -- position and every non-owner client INTERPOLATES toward it, which
        -- is the one thing a prop never does. That is why this style can be
        -- flown at a rate a prop would strobe at.
        return Open77.npcs.setTransform(id, { position = position })
    end
    if style == "effect" then
        return Open77.effects.update(id, { position = position })
    end
    return Open77.props.setTransform(id, { position = position })
end

--- Hand one drone a destination and let the engine fly it there.
local function sendDroneTo(id, position, seconds)
    local task = ((Config.drone or {}).npc or {}).task or {}
    return Open77.npcs.tasks.moveTo(id, position, {
        speed = task.speed or "walk",
        acceptanceRadius = number(task.acceptanceRadius, 2.0),
        -- The task must outlive the figure it belongs to, or the engine gives
        -- up half way and the drone stops in mid-air where nobody put it.
        timeoutMs = math.max(math.floor(seconds * 1000) + 5000,
            math.floor(number(task.timeoutMs, 60000))),
    })
end

--- Colour and on/off ride together, because both live in the same light table
--- and sending it twice would blink the lamp twice.
---
--- The effect style has no colour -- a looping VFX is whatever it was authored
--- as -- so there it is only the on/off, through `visible`.
local function restyleDrone(style, id, colorName, lit)
    if style == "npc" then
        -- A drone NPC has neither a palette nor a lamp switch: its lights are
        -- the rig's own. So a `lit = false` step is simply a pause for this
        -- style, which is honest -- the alternative would be to remove and
        -- respawn the swarm, and a respawn is not an ignition.
        return true
    end
    if style == "effect" then
        return Open77.effects.update(id, { visible = lit ~= false })
    end
    return Open77.props.update(id, { light = lightFor(colorName, lit) })
end

local function removeDrone(style, id)
    if style == "npc" then return Open77.npcs.remove(id) end
    if style == "effect" then return Open77.effects.remove(id) end
    return Open77.props.remove(id)
end

--- The drone's landing light: a looping effect sitting on its point.
---
--- This exists because a drone rig's own emissives are a couple of small lamps
--- meant to be seen from a few metres, and the hull is dark -- measured, by
--- somebody looking at eight of them in the sky and reporting they were not
--- impressive. A co-located effect fixes it for nothing, and "for nothing" is
--- literal: the drones DO NOT MOVE, so the light never needs an update either.
--- It is spawned with the figure and retired with it.
---
--- `Open77.effects.attach` would bind the effect to the body instead, and is
--- the right answer the day these can move. It is not used here because it
--- buys following, and nothing follows.
---
--- Colour comes from the ASSET -- a VFX is whatever it was authored as -- so a
--- palette name is mapped to whichever cooked effect is nearest it.
--- Which named light a step asks for: its own `light`, or the one its `color`
--- maps to, or the default.
local function lightNameFor(step, colorName)
    local lights = ((Config.drone or {}).npc or {}).lights or {}
    if type(step) == "table" and type(step.light) == "string" then return step.light end
    local byColor = lights.byColor or {}
    return byColor[colorName or ""] or lights.default or "blue"
end

--- One named light's definition: the effect it plays and how far above the
--- drone's own point it sits.
---
--- The offset is PER LIGHT, and that is the point. A vehicle entity's origin
--- is not its visual centre, and every candidate effect is a different size,
--- so one global number could never sit right for all of them. The owner's
--- complaint about the sign was that the glow sat below and beside the hull --
--- two objects rather than a lit aircraft -- and half of that fix lives here.
local function lightDefinition(name)
    local lights = ((Config.drone or {}).npc or {}).lights or {}
    local entry = (lights.set or {})[name or ""]
    if type(entry) ~= "table" then
        entry = (lights.set or {})[lights.default or "blue"]
    end
    if type(entry) ~= "table" then
        return { effect = "neon.loot_drop", offset = 0.6 }
    end
    return entry
end

local function spawnLight(position, bucket, lightName)
    local lights = ((Config.drone or {}).npc or {}).lights or {}
    if lights.enabled == false then return nil end
    local definition = lightDefinition(lightName)
    local radius = clamp(number(lights.streamingRadius, 600.0), 10.0, 2000.0)
    return Open77.effects.create({
        effect = definition.effect or "neon.loot_drop",
        position = {
            x = position.x, y = position.y,
            z = position.z + number(definition.offset, number(lights.offset, 0.6)),
        },
        bucket = bucket,
        streamingRadius = radius,
        streamingHysteresis = clamp(number(Config.streamingHysteresis, 150.0), 0.0, radius),
        ttlMs = 0,
    })
end

-- ---------------------------------------------------------------------------
-- The vehicle-sweep guard
--
-- THE CANDIDATE CAUSE OF THE BLINK, and a workaround for it that a server
-- owner can switch on and off without editing anything.
--
-- A drone record resolves to an `av_*.ent`, so its spawned body is a
-- `vehicleBaseObject`. Open77 sweeps everything the entity spawner publishes
-- and removes vehicles it cannot find in `EntityService` -- and a server-owned
-- NPC only lands in `EntityService` at the END of its spawn, while the sweep
-- sees it at the START. The sibling sweep, `WorldSanitizer`, closes that window
-- with a second check against the dynamic-entity table and a 500 ms grace;
-- this one has neither. A race, not a cull, which is why it blinks.
--
-- The sweep's vehicle branch is armed whenever ambient traffic is off, which is
-- the default for any bucket nobody has configured. Telling the bucket that
-- traffic is allowed makes the whole branch skip.
--
-- The bucket's existing crowd and police settings are read first and put back
-- afterwards: this resource borrows one field of somebody else's policy and
-- gives it back, rather than stamping its own over the top.
-- ---------------------------------------------------------------------------

--- The sequence driver's frame length as currently chosen: the session's
--- override if one was set, otherwise the measured default from the config.
--- The budget can still stretch it; this is the floor it starts from.
--- The floor below which a flip-book frame cannot work, whatever anybody types.
---
--- Decomposed from the platform's source, not guessed: one server tick before
--- the create is sent, a client frame to drain it, another for the off-thread
--- stub callback, a HARD 250 ms readiness settle that is not a tick and not
--- tunable, one more server tick for this resource's poll, and two network
--- polls. About 350 ms before the engine has streamed a byte of a vehicle
--- mesh -- and that streaming has no deadline in the code at all.
---
--- Asking for less is not merely useless. A spawn already in flight is NOT
--- cancelled when the next frame despawns it: the engine still streams,
--- instantiates and then destroys the body.
local function sequenceFloorMs()
    return math.max(1, math.floor(number(
        (((Config.drone or {}).npc or {}).sequence or {}).absoluteFloorMs, 300)))
end

local function currentFrameMs()
    local sequence = ((Config.drone or {}).npc or {}).sequence or {}
    return math.max(sequenceFloorMs(),
        math.floor(number(state.frameMs, number(sequence.frameMs, 400))))
end

local function guardWanted()
    if state.sweepGuard ~= nil then return state.sweepGuard end
    return ((Config.drone or {}).npc or {}).vehicleSweepGuard ~= nil
        and ((Config.drone or {}).npc or {}).vehicleSweepGuard.enabled == true
end

local function releaseSweepGuard()
    local held = state.guardHeld
    if held == nil then return false end
    state.guardHeld = nil
    local ok, reason = Open77.world.setPopulation(held.bucket, {
        crowd = held.crowd, traffic = held.traffic, police = held.police,
    })
    if not ok then
        log("WARNING: could not restore the population policy of bucket %d: %s -- "
            .. "vanilla traffic may be left on there", held.bucket, tostring(reason))
    end
    return true
end

local function applySweepGuard(bucket, style)
    if style ~= "npc" or not guardWanted() then return end
    releaseSweepGuard()

    local before = Open77.world.getPopulation(bucket)
    if type(before) ~= "table" then
        log("sweep guard: bucket %d has no readable population policy, not touching it", bucket)
        return
    end
    -- Remembered BEFORE the write, so the restore puts back what was there and
    -- not what this resource assumed was there.
    state.guardHeld = {
        bucket = bucket,
        crowd = number(before.crowd, 0.0),
        traffic = number(before.traffic, 0.0),
        police = before.police == true,
    }

    local wanted = number(((Config.drone or {}).npc or {}).vehicleSweepGuard.traffic, 1)
    local ok, reason = Open77.world.setPopulation(bucket, {
        crowd = state.guardHeld.crowd,
        traffic = wanted,
        police = state.guardHeld.police,
    })
    if not ok then
        state.guardHeld = nil
        return log("sweep guard: refused on bucket %d: %s", bucket, tostring(reason))
    end
    log("sweep guard ON for bucket %d -- vanilla traffic allowed so the identity "
        .. "sweep skips the drones. Traffic was %.2f and goes back after the show.",
        bucket, state.guardHeld.traffic)
end

-- ---------------------------------------------------------------------------
-- Teardown
--
-- THE SKY MUST END EMPTY. Five different things can end a show -- the command,
-- the last player leaving, a world that went away, a resource stop, and the
-- show simply finishing -- and every one of them lands here. On top of that
-- every drone is spawned with a TTL longer than the show it belongs to, so
-- even a Lua runtime error that kills the thread outright leaves a sky that
-- clears itself.
-- ---------------------------------------------------------------------------

--- Takes down whatever drones the run currently holds, and nothing else.
---
--- Separate from `removeSwarm` because the cut driver despawns the swarm on
--- every figure and the run carries on; only a teardown latches.
local function despawnAll(run)
    local removed = 0
    for index = 1, #run.ids do
        local id = run.ids[index]
        if id ~= nil and removeDrone(run.style, id) then removed = removed + 1 end
    end
    -- The lights go with the bodies, always and in the same call. A light left
    -- behind is a bright point hanging where a drone used to be, which is the
    -- most conspicuous way this resource could fail to clean up after itself.
    for index = 1, #(run.lightIds or {}) do
        local id = run.lightIds[index]
        if id ~= nil then Open77.effects.remove(id) end
    end
    run.ids = {}
    run.lightIds = {}
    return removed
end

--- Put one whole figure in the sky: a body and a light per point.
---
--- Takes the STEP rather than a colour or a light name, because the two styles
--- want different things out of it and conflating them was a bug waiting to
--- happen: the light style paints its props from the palette `color`, while
--- the npc style picks a named light from `light` or from what that colour
--- maps to. One argument, two readings, decided here instead of at five call
--- sites.
local function spawnFigure(run, pose, step, lit, withLight)
    local colorName = type(step) == "table" and step.color or step
    local lightName = lightNameFor(step, colorName)
    run.ids = {}
    run.lightIds = {}
    for index = 1, #pose do
        -- The BODY takes the palette colour (the light style paints its props
        -- from it); the LIGHT takes the named light. Passing one for the other
        -- is exactly the bug this signature was reshaped to prevent.
        local id, reason = spawnDrone(run.style, pose[index], run.bucket,
            colorName, lit, run.ttl, run.record)
        if id == nil then
            despawnAll(run)
            return false, ("drone %d of %d: %s"):format(index, #pose, tostring(reason))
        end
        run.ids[index] = id
        run.positions[index] = pose[index]
        run.sent[index] = pose[index]
        if run.style == "npc" and withLight ~= false then
            run.lightIds[index] = spawnLight(pose[index], run.bucket, lightName)
        end
    end
    return true
end

-- Forward declaration: `sequenceFrameMs` below calls it and `availableBytes`
-- is defined further down, where the run registry it reads lives. Without
-- this line that call resolves as a GLOBAL and is nil at runtime -- which is
-- exactly what it did on the first 88-drone sign: `attempt to call a nil
-- value (global 'availableBytes')`, and luac cannot see it.
local availableBytes

--- How many drones may be moving AT ONCE, derived from the byte budget.
---
--- This is the whole answer to "live motion is unaffordable". It is not: the
--- assumption that the whole swarm moves at once is. An effect drone that is
--- not moving costs NOTHING -- nothing is written for it -- so the bill is
--- `drones in flight x rate x bytes`, and the swarm size never enters it.
---
--- At the measured 555 bytes an update against the 64 KB/s slice that is
--- about 14 movers at 8 Hz, or 29 at 4 Hz, whether the swarm is eight drones
--- or eighty-eight. A sign that draws itself has a moving front and a static
--- tail, and only the front is paid for.
local function moverBudget(rateHz)
    local motion = Config.motion or {}
    local rate = math.max(0.1, number(rateHz, number(motion.rateHz, 8)))
    local perUpdate = math.max(1, number((((Config.clock or {}).bytesPerUpdate) or {}).effect, 555))
    local affordable = math.floor(availableBytes() / (perUpdate * rate))
    return math.max(0, math.min(affordable, math.floor(number(motion.maxMovers, 16)))), rate
end

--- Change the lights of the figure that is already up, WITHOUT respawning it.
---
--- This is the cheap half of a light-cycling show, and the difference is not
--- small. A full figure is a body and a light per drone, and the body is the
--- expensive one -- it costs a spawn that takes about 400 ms to become
--- anything and carries the whole vehicle entity behind it. A relight touches
--- only the effects: the bodies never move, never blink and never restream.
---
--- Measured in bytes, for a show that runs indefinitely, that is the
--- difference between two entity round trips per drone per cycle and one.
local function relightFigure(run, lightName)
    if run.style ~= "npc" then return 0 end
    local swapped = 0
    for index = 1, #run.ids do
        local old = run.lightIds[index]
        if old ~= nil then Open77.effects.remove(old) end
        run.lightIds[index] = spawnLight(run.positions[index], run.bucket, lightName)
        if run.lightIds[index] ~= nil then swapped = swapped + 1 end
    end
    run.light = lightName
    return swapped
end

--- How many drones of the current figure have a body on some client.
local function readyCount(run)
    if run.style ~= "npc" then return #run.ids end
    local ready = 0
    for index = 1, #run.ids do
        local owner = Open77.npcs.owner(run.ids[index])
        if type(owner) == "table" and number(owner.readyClients, 0) >= 1 then
            ready = ready + 1
        end
    end
    return ready
end

local function removeSwarm(run)
    if run == nil or run.removed then return 0 end
    run.removed = true
    return despawnAll(run)
end

--- Ends ONE show. Safe to call on a show that has already ended.
---
--- The borrowed population policy goes back only when the LAST show ends:
--- releasing it while another show is still flying would re-arm the vanilla
--- sweep underneath it.
local function haltRun(run, reason)
    if run == nil then return 0 end
    run.alive = false
    if state.runs[run.show] == run then state.runs[run.show] = nil end
    local removed = removeSwarm(run)
    log("show %s ended (%s), %d drones recalled", run.show, reason, removed)
    if not anyRunning() then releaseSweepGuard() end
    return removed
end

--- Ends every show. The teardown path, and what a bare `stop` does.
local function haltAll(reason)
    local removed = 0
    for _, run in ipairs(liveRuns()) do removed = removed + haltRun(run, reason) end
    state.runs = {}
    releaseSweepGuard()
    return removed
end

-- ---------------------------------------------------------------------------
-- The show
-- ---------------------------------------------------------------------------

local function smoothstep(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

--- THE BUDGET. How fast the swarm may be updated, in Hz per drone, derived
--- from bytes per second and never from a configured rate.
---
--- This function exists because the first build of this resource trusted its
--- config to be sane and disconnected the player it was performing for:
--- GameNetworkingSockets clamps a connection to 256 KB/s and DISCONNECTS once
--- 512 KB has queued behind the clamp. 48 drones at 15 Hz is 369 KB/s of prop
--- traffic alone, so the link had about eight seconds to live. The rate is
--- now an output, not an input.
---
--- Answers the rate, and the reason it is not flyable when it is too low.
--- How long a sequence frame has to be held, in milliseconds.
---
--- Derived, never configured, for the same reason the streaming rate is: the
--- driver redraws a whole figure every frame, so its cost IS a sustained rate
--- -- `frames per second x drones x bytes per figure` -- out of the same slice
--- of the link as everything else. The configured `frameMs` is a FLOOR.
---
--- AND THE BANDWIDTH IS NOT WHAT BINDS. Measured 2026-09-20: a frame of 300 ms
--- left 0 of 8 bodies ready and stayed there for fifty frames, while 1200 ms
--- reached 8 of 8. The spawn latency binds about four times harder than the
--- byte budget ever did. This function still exists because the budget must
--- also be respected -- but the number it usually returns is the measured
--- floor, not an affordability calculation.

local function sequenceFrameMs(droneCount)
    local npc = (Config.drone or {}).npc or {}
    local flip = npc.sequence or {}
    local perFigure = math.max(1, number(npc.bytesPerFigure, 300))
    local budget = math.max(1, (availableBytes()))

    local wanted = math.max(1.0, currentFrameMs())
    local affordable = droneCount * perFigure / budget * 1000.0
    local frameMs = math.ceil(math.max(wanted, affordable))

    local ceiling = math.max(wanted, number(flip.maxFrameMs, 3000))
    if frameMs > ceiling then
        return nil, ("%d drones can only be redrawn every %d ms inside %.0f KB/s, and past %d ms it is not a show -- ")
            :format(droneCount, frameMs, budget / 1024, math.floor(ceiling))
            .. ("at most %d drones sequence, or raise clock.maxBytesPerSecondPerViewer")
                :format(math.max(1, math.floor(budget * ceiling / 1000.0 / perFigure)))
    end
    return frameMs
end

--- The worst-case sustained cost of one live show, bytes per second per viewer.
---
--- Worst case, not average, because the budget exists to stop a client being
--- disconnected and a client is disconnected by a peak. A cut show at rest
--- costs nothing -- its whole bill is two bursts per figure -- so it is
--- counted at zero here and gated on its burst instead.
local function runCost(run)
    local clock = Config.clock or {}
    local drones = #run.ids
    if drones == 0 then drones = run.droneCount or 0 end
    if run.driver == "stream" then
        return number(run.hz, 0) * drones
            * number((clock.bytesPerUpdate or {})[run.style], 555)
    end
    if run.driver == "hybrid" then
        return number(run.hz, 0) * drones
            * number((clock.bytesPerUpdate or {}).effect, 555)
    end
    if run.driver == "sequence" then
        local perFigure = number(((Config.drone or {}).npc or {}).bytesPerFigure, 300)
        return 1000.0 / math.max(1, number(run.frameMs, 400)) * drones * perFigure
    end
    return 0.0
end

--- What is left of the per-viewer slice once everything already in the air has
--- been paid for.
---
--- THIS is the limit on how many shows may run at once -- not a count. Two
--- shows are fine if between them they fit the link, and one is too many if it
--- does not. The clamp that disconnects a client does not care how many
--- resources were talking to it.
function availableBytes()
    local budget = math.max(0, number((Config.clock or {}).maxBytesPerSecondPerViewer, 65536))
    local committed = 0.0
    for _, run in ipairs(liveRuns()) do committed = committed + runCost(run) end
    return budget - committed, committed
end

--- What is already flying, for a refusal that says something useful.
local function flyingSummary()
    local parts = {}
    for _, run in ipairs(liveRuns()) do
        parts[#parts + 1] = ("%s (%d %s drones, %.0f KB/s)"):format(
            run.show, #run.ids, run.style, runCost(run) / 1024)
    end
    if #parts == 0 then return "nothing" end
    return table.concat(parts, " and ")
end

local function budgetedRate(droneCount, style)
    local clock = Config.clock or {}
    local driver = driverFor(style)

    -- The sequence driver is priced per FRAME, not per update, so it has no
    -- rate either -- but it does have a sustained cost, and `sequenceFrameMs`
    -- is where that is checked. This only has to say "not streamed".
    if driver == "sequence" then
        local frameMs, refusal = sequenceFrameMs(droneCount)
        if frameMs == nil then return nil, refusal end
        return 0.0
    end

    -- NEITHER OF THE NON-STREAMING DRIVERS HAS A RATE. The cut driver spends
    -- its whole budget in two bursts per figure -- a spawn and a despawn --
    -- and nothing at all in between, so what has to be checked is the BURST
    -- against the link, not a sustained rate against a slice of it.
    --
    -- The arithmetic: a figure costs `droneCount x bytesPerFigure` to each
    -- viewer, delivered as fast as the server can push it. The transport
    -- clamps a connection at 256 KB/s and disconnects once 512 KB has queued
    -- behind that clamp, so the burst is refused if it would fill more than a
    -- quarter of that queue on its own. At the measured 300 bytes a drone per
    -- figure that allows about four hundred drones, which is far past every
    -- other ceiling in this file -- the point is that the gate exists and is
    -- computed, not that it binds.
    -- The hybrid pays BOTH bills, one at a time: a cut's burst when a figure
    -- lands, and the effect style's sustained stream while one is moving. The
    -- stream is the larger of the two and the one that can disconnect a
    -- client, so that is what is checked.
    if driver == "hybrid" then
        local rate, refusal = budgetedRate(droneCount, "effect")
        if rate == nil then return nil, refusal end
        return rate
    end

    if driver == "cut" then
        local perFigure = math.max(1, number(((Config.drone or {}).npc or {}).bytesPerFigure, 300))
        local live = 0
        for _, run in ipairs(liveRuns()) do live = live + #run.ids end
        -- Other shows' figures land in the same send queue, so the burst that
        -- matters is everything that could arrive together.
        local burst = (droneCount + live) * perFigure
        local allowed = 512 * 1024 * 0.25
        if burst > allowed then
            return nil, ("%d drones plus the %d already flying would push %.0f KB in one figure "
                .. "and the send queue is 512 KB -- "):format(droneCount, live, burst / 1024)
                .. ("at most %d drones fit a cut"):format(math.floor(allowed / perFigure))
        end
        return 0.0
    end

    if driver == "task" then return 0.0 end
    local perUpdate = math.max(1, number((clock.bytesPerUpdate or {})[style], 555))
    local budget, committed = availableBytes()
    local wanted = clamp(number(clock.updateHz, 8), 0.1, 30.0)
    if droneCount < 1 then return wanted end
    if budget <= 0 then
        return nil, ("there is no bandwidth left: %s already in the air uses the whole %.0f KB/s slice")
            :format(flyingSummary(), committed / 1024)
    end

    local affordable = budget / (perUpdate * droneCount)
    local rate = math.min(wanted, affordable)
    local floorHz = math.max(0.1, number(clock.minUpdateHz, 3.0))
    if rate < floorHz then
        local fits = math.floor(budget / (perUpdate * floorHz))
        return nil, ("%d %s drones need %.0f KB/s to fly at %.1f Hz and only %.0f KB/s is free (%s flying) -- "):format(
            droneCount, style, droneCount * floorHz * perUpdate / 1024, floorHz,
            budget / 1024, flyingSummary())
            .. ("at most %d drones fit, or raise clock.maxBytesPerSecondPerViewer"):format(math.max(0, fits))
    end
    return rate
end

--- Sleep through a hold, in slices, so a stop lands promptly and an emptied
--- server is noticed. A held formation sends NOTHING: this is where the
--- bandwidth budget is won back.
local function holdFor(run, holdMs)
    local remaining = math.max(0, math.floor(number(holdMs, 0)))
    while remaining > 0 do
        local slice = math.min(250, remaining)
        Wait(slice)
        remaining = remaining - slice
        if not run.alive then return false end
        if audience() == 0 then
            haltAll("nobody left to watch it")
            return false
        end
    end
    return true
end

--- Fly the swarm from where it is to `targets` over `morphMs`, then hold.
---
--- Returns false when the run was cancelled or gave up; the caller stops.
local function flyTo(run, targets, morphMs)
    local clock = Config.clock or {}
    local origins = {}
    local longest = 0.0
    for index = 1, #run.positions do
        origins[index] = run.positions[index]
        local span = distance(origins[index], targets[index])
        if span > longest then longest = span end
    end

    local seconds = math.max(0.0, morphMs / 1000.0)

    -- THE DESTINATION DRIVER. The server names a point per drone, once, and
    -- the engine flies it there: one message per drone per figure instead of
    -- several a second. Two orders of magnitude cheaper than streaming
    -- positions, and the motion is the engine's own rather than a staircase.
    --
    -- The speed limit below does not apply here, because this resource is no
    -- longer choosing the speed. Neither does the dead band: there is nothing
    -- being streamed to skip.
    if run.driver == "task" then
        local issued, refused = 0, 0
        for index = 1, #run.ids do
            if sendDroneTo(run.ids[index], targets[index], seconds) then
                issued = issued + 1
            else
                refused = refused + 1
            end
            -- Recorded as arrived: the engine owns the journey, so this is
            -- the only position the resource can honestly claim to know, and
            -- the next figure's assignment is measured from it.
            run.positions[index] = targets[index]
            run.sent[index] = targets[index]
        end
        if issued == 0 then
            log("every moveTo into %s was refused -- the task driver does not work on this rig",
                run.stepName)
            haltRun(run, "task driver refused")
            return false
        end
        if refused > 0 then
            log("%d of %d moveTo tasks into %s were refused", refused, #run.ids, run.stepName)
        end
        return holdFor(run, math.floor(seconds * 1000))
    end

    local epsilon = math.max(0.0, number(clock.moveEpsilon, 0.05))
    -- The rate was decided by the byte budget when the show was accepted, and
    -- is not revisited per morph: a rate that drifted mid-show would put the
    -- link back over the clamp exactly where the traffic is heaviest.
    local interval = math.max(1, math.floor(1000.0 / run.hz + 0.5))

    -- THE SPEED LIMIT IS THE STEP SIZE. There is no client-side interpolation,
    -- so a drone teleports from one update to the next and the step is what
    -- the eye sees. The rate is fixed by the budget, so the only way to keep
    -- the step small is to keep the speed down -- and a morph that would
    -- exceed it is stretched, never run. Easing puts the peak at 1.5x the
    -- average, and that is what gets compared.
    local maxSpeed = stepLimit(run.style) * run.hz
    if seconds > 0.0 and longest > 0.0 then
        local required = 1.5 * longest / maxSpeed
        if required > seconds then
            log("morph into %s stretched from %.1fs to %.1fs: %.0f m at %.1f m/s would step %.2f m",
                run.stepName, seconds, required, longest, 1.5 * longest / seconds,
                1.5 * longest / seconds / run.hz)
            seconds = required
        end
    end

    -- A zero-length morph still has to land the pose exactly, in one write.
    if seconds <= 0.0 then
        for index = 1, #run.ids do
            if distance(run.sent[index], targets[index]) > 0.0 then
                if moveDrone(run.style, run.ids[index], targets[index]) then
                    run.sent[index] = targets[index]
                end
            end
            run.positions[index] = targets[index]
        end
        return true
    end

    local budget = math.max(1, math.floor(number(clock.failureBudget, 24)))
    local startedAt = Open77.time.monotonic()
    while true do
        Wait(interval)
        if not run.alive then return false end
        if audience() == 0 then
            haltAll("nobody left to watch it")
            return false
        end

        -- Driven by the clock, not by the sum of the sleeps: a late tick
        -- shortens the next step instead of stretching the whole morph.
        local elapsed = Open77.time.monotonic() - startedAt
        local phase = smoothstep(elapsed / seconds)
        local finished = elapsed >= seconds
        local exhausted = false

        for index = 1, #run.ids do
            local origin, target = origins[index], targets[index]
            local place = finished and target or snap({
                x = origin.x + (target.x - origin.x) * phase,
                y = origin.y + (target.y - origin.y) * phase,
                z = origin.z + (target.z - origin.z) * phase,
            })
            -- Measured against the last position SENT, not the last computed
            -- one, so a drone creeping below the dead band still arrives: the
            -- skipped centimetres accumulate until they are worth a message.
            if finished or distance(run.sent[index], place) >= epsilon then
                if moveDrone(run.style, run.ids[index], place) then
                    run.sent[index] = place
                    run.failures = 0
                else
                    run.failures = run.failures + 1
                    if run.failures >= budget then
                        exhausted = true
                        break
                    end
                end
            end
            run.positions[index] = place
        end

        if exhausted then
            log("giving up: %d transform writes in a row were refused", run.failures)
            haltRun(run, "write failures")
            return false
        end
        if finished then return true end
    end
end

--- Wait until every drone has a body somewhere before the show starts.
---
--- Only the npc style needs this. `Open77.npcs.create` answers an id at once
--- and the body arrives later, asynchronously, per client -- so a show that
--- started on the id would fly a formation half of which is not in the world.
--- Props and effects have no such gap.
local function awaitReady(run)
    if run.style ~= "npc" then return true end
    local timeout = number(((Config.drone or {}).npc or {}).readyTimeoutMs, 20000) / 1000.0
    local deadline = Open77.time.monotonic() + timeout
    while true do
        local pending = 0
        for index = 1, #run.ids do
            local owner = Open77.npcs.owner(run.ids[index])
            if type(owner) ~= "table" or number(owner.readyClients, 0) < 1 then
                pending = pending + 1
            end
        end
        if pending == 0 then return true end
        if Open77.time.monotonic() >= deadline then
            -- Loud, and then on with it: the drones exist server-side and will
            -- project when a client is ready, and blocking the show forever on
            -- one slow machine is the worse failure.
            log("%d of %d drones had no body after %.0f s -- starting anyway",
                pending, #run.ids, timeout)
            return true
        end
        Wait(250)
        if not run.alive then return false end
        if audience() == 0 then
            haltAll("nobody left to watch it")
            return false
        end
    end
end

--- Cut from whatever is in the sky to the next figure.
---
--- Despawn, black the sky out, respawn already in formation. This is the npc
--- style's only way from one figure to the next, and it is a legitimate look:
--- real drone displays cut through blackout too. It costs one spawn and one
--- despawn per drone per figure and NOTHING in between -- no tick, no stream,
--- no budget burning while a figure is held.
---
--- The blackout is taken FIRST and in full, so the sky is empty before the
--- next figure starts arriving. Spawning over the top of a despawn would read
--- as a stutter rather than as a cut, and would also be the one moment the
--- client's entity budget carries two figures at once.
--- Put a figure up ONE DRONE AT A TIME, along the stroke.
---
--- The cheap half of live motion, and the half that works whatever the answer
--- to the smoothness question turns out to be: nothing moves here. Each drone
--- is created once, where it belongs, and the order is the formation's own
--- point order -- which for a generated shape IS stroke order, because the
--- generator walks each stroke end to end. So a sign writes itself.
---
--- The rate is bounded by the same slice as everything else. 88 drones over
--- eight seconds is eleven creates a second, about 6 KB/s -- a tenth of the
--- budget, against the 26 KB burst the same figure costs when it appears all
--- at once. Drawing it is CHEAPER than showing it.
local function revealFigure(run, pose, step, revealMs)
    local total = #pose
    if total == 0 then return true end
    local seconds = math.max(0.05, revealMs / 1000.0)

    run.ids = {}
    run.lightIds = {}
    local colorName = type(step) == "table" and step.color or step
    local lightName = lightNameFor(step, colorName)

    local startedAt = Open77.time.monotonic()
    local placed = 0
    while placed < total do
        if not run.alive then return false end
        if audience() == 0 then
            haltAll("nobody left to watch it")
            return false
        end

        -- How far along the stroke the front should be by now. Driven by the
        -- clock rather than by a count, so a slow tick shortens the next slice
        -- instead of stretching the whole reveal.
        local elapsed = Open77.time.monotonic() - startedAt
        local wanted = math.min(total, math.ceil(total * math.min(1.0, elapsed / seconds)))
        while placed < wanted do
            placed = placed + 1
            local id, reason = spawnDrone(run.style, pose[placed], run.bucket,
                colorName, step.lit ~= false, run.ttl, run.record)
            if id == nil then
                despawnAll(run)
                log("reveal of %s refused at drone %d of %d: %s",
                    step.formation, placed, total, tostring(reason))
                haltRun(run, "spawn refused mid-reveal")
                return false
            end
            run.ids[placed] = id
            run.positions[placed] = pose[placed]
            run.sent[placed] = pose[placed]
            if run.style == "npc" then
                run.lightIds[placed] = spawnLight(pose[placed], run.bucket, lightName)
            end
        end
        if placed < total then Wait(50) end
    end

    run.formation, run.place, run.light = step.formation, step.place, lightName
    local perUpdate = number((((Config.clock or {}).bytesPerUpdate) or {}).effect, 555)
    log("revealed %s over %.1fs: %d drones, about %.0f KB/s while drawing",
        step.formation, seconds, total, total / seconds * perUpdate / 1024)
    return true
end

local function cutTo(run, step)
    -- THE CHEAP PATH. When the figure is not changing -- same formation, same
    -- place -- only the light is, and a light is an effect: it can be swapped
    -- without touching the bodies at all. No blackout, no despawn, no 400 ms
    -- of spawn latency, half the entity churn.
    --
    -- This is what makes a light-cycling show affordable to leave running: a
    -- cycle costs one entity round trip per drone instead of two, and the
    -- bodies never blink.
    local wantedLight = lightNameFor(step, step.color)
    if run.style == "npc" and run.formation == step.formation
        and run.place == step.place and #run.ids > 0 then
        local swapped = relightFigure(run, wantedLight)
        log("relit %s to %s: %d lights swapped, bodies untouched",
            step.formation, wantedLight, swapped)
        return true
    end

    despawnAll(run)

    local revealMs = number(step.reveal, nil)
    local blackout = math.floor(number(step.blackout,
        number(((Config.drone or {}).npc or {}).blackoutMs, 1200)))
    if not holdFor(run, blackout) then return false end
    if not run.alive then return false end

    local pose = poseFor(run.basis, step)
    if revealMs ~= nil and revealMs > 0 then
        if not revealFigure(run, pose, step, revealMs) then return false end
        return awaitReady(run)
    end

    local ok, reason = spawnFigure(run, pose, step, step.lit ~= false)
    if not ok then
        log("cut into %s refused at %s", step.formation, reason)
        haltRun(run, "spawn refused mid-cut")
        return false
    end
    run.formation, run.place, run.light = step.formation, step.place, wantedLight
    log("cut into %s lit %s: %d bodies and %d lights spawned",
        step.formation, wantedLight, #run.ids, #run.lightIds)

    -- A spawn is an id at once and a body later, per client. Waiting bounds
    -- how ragged the figure fades in; it cannot make it simultaneous.
    return awaitReady(run)
end

--- THE SEQUENCE. A pose at a time, for a drone that cannot be moved.
---
--- Built as a flip-book: a drone NPC ignores a transform write -- measured on
--- camera -- but a whole FIGURE costs only 300 bytes a drone, so motion could
--- be REDRAWN rather than written. Interpolate between two formations, cut
--- each intermediate pose, hold it just long enough for the next to replace
--- it.
---
--- THE MEASUREMENT SAID NO, and it is named for what it turned out to be. A
--- frame of 300 ms left 0 of 8 bodies ready and stayed there for fifty frames;
--- 1200 ms reached 8 of 8. A pose every 1.2 s is a sequence, not motion, and
--- calling it choreography would be a claim the numbers do not support.
---
--- There is no blackout between frames. The blackout is what makes a CUT read
--- as deliberate; inside a movement it would read as a strobe.
---
--- The driver counts what it is doing and abandons a movement that finds
--- nothing ready, because redrawing faster than a spawn can land is not merely
--- useless -- it issues a spawn per drone that the previous frame had not
--- finished, against a bounded client-side request table.
local function sequenceTo(run, step, frameMs)
    frameMs = math.max(1, math.floor(number(frameMs, 300)))
    local flip = ((Config.drone or {}).npc or {}).sequence or {}
    -- Lights on the pose it lands on, not on every frame of the movement:
    -- halves the entity churn, and the swarm going dark to move and lighting
    -- up when it arrives is a deliberate look rather than a compromise.
    local lightWhileMoving = flip.lightsWhileMoving == true
    local origins = {}
    for index = 1, #run.positions do origins[index] = run.positions[index] end
    local targets = assign(origins, poseFor(run.basis, step))

    local seconds = math.max(0.0, number(step.morph, 0) / 1000.0)
    local frames = math.max(1, math.floor(seconds * 1000.0 / frameMs + 0.5))
    local worstReady, framesDrawn, emptyFrames = #run.ids, 0, 0

    for frame = 1, frames do
        if not run.alive then return false end
        if audience() == 0 then
            haltAll("nobody left to watch it")
            return false
        end

        -- Eased, so the movement starts and stops rather than sliding at a
        -- constant rate -- the same smoothstep the streaming driver uses.
        local phase = smoothstep(frame / frames)
        local pose = {}
        for index = 1, #origins do
            local a, b = origins[index], targets[index]
            pose[index] = snap({
                x = a.x + (b.x - a.x) * phase,
                y = a.y + (b.y - a.y) * phase,
                z = a.z + (b.z - a.z) * phase,
            })
        end

        despawnAll(run)
        local lastFrame = (frame == frames)
        local ok, reason = spawnFigure(run, pose, step, step.lit ~= false,
            lightWhileMoving or lastFrame)
        if not ok then
            log("sequence frame %d of %d into %s refused at %s",
                frame, frames, step.formation, reason)
            haltRun(run, "spawn refused mid-sequence")
            return false
        end

        Wait(frameMs)
        framesDrawn = framesDrawn + 1
        local ready = readyCount(run)
        if ready < worstReady then worstReady = ready end

        -- SELF-LIMITING. Redrawing faster than a spawn can land is not merely
        -- useless, it is harmful: every frame issues a spawn per drone that
        -- the previous frame's spawn had not finished, against a bounded
        -- client-side request table. So the driver reads its own counter and
        -- gives up rather than hammering -- which is also what makes a
        -- bisection run safe to type.
        emptyFrames = (ready == 0) and (emptyFrames + 1) or 0
        if emptyFrames >= math.max(1, math.floor(number(flip.abortAfterEmptyFrames, 4))) then
            log("sequence into %s ABANDONED after %d frames of %d ms: nothing was ready, "
                .. "so the frame is shorter than a spawn takes to land. Raise frameMs.",
                step.formation, framesDrawn, frameMs)
            haltRun(run, "frame shorter than the spawn latency")
            return false
        end
    end

    -- THE NUMBER TO WATCH, and what it means.
    --
    -- Low from the first movement: the frame is shorter than a spawn takes to
    -- land on a client, so the sequence is being drawn faster than it can be
    -- drawn. Raise `frameMs`.
    --
    -- Fine at first and DEGRADING over successive movements: that is not the
    -- frame rate, that is the client's dynamic-entity request table filling up
    -- -- the driver creates and destroys two entities per drone per frame,
    -- and the table is a shared 1,024. Fewer drones, or slower frames.
    if flip.reportReadiness ~= false then
        log("sequence into %s: %d frames of %d ms, worst frame had %d of %d bodies ready%s",
            step.formation, framesDrawn, frameMs, worstReady, #run.ids,
            worstReady < #run.ids and " -- raise frameMs, or watch for it degrading run to run" or "")
    end
    return true
end

--- THE HYBRID. Lights fly the movement, bodies hold the figure.
---
--- Each half does the thing the other cannot. A drone NPC has a real body and
--- ignores a transform write, so it can hold a shape and never travel. A
--- looping effect has no body but CAN be moved -- the client repositions a
--- live particle graph in place, keeping the same handle and its trails,
--- rather than restarting it -- so it can travel and never convince anybody it
--- is a machine.
---
--- So the swarm changes hands twice per figure:
---
---   bodies at A  ->  lights up at A  ->  bodies down  ->  lights fly A to B
---                ->  bodies up at B  ->  lights down  ->  hold
---
--- The overlap at each end is what keeps the seam invisible. A hard swap would
--- leave the sky empty for however long a body takes to stream, which is the
--- 400 ms the rest of this file is about.
---
--- `flyTo` is reused unchanged by handing it a FLIGHT: a table carrying the
--- fields it actually touches. It shares the run's epoch, so a stop still
--- lands mid-flight, and it calls the same `halt` on failure.
local function hybridTo(run, step)
    local targets = assign(run.positions, poseFor(run.basis, step))
    local overlap = math.floor(number(
        (((Config.drone or {}).npc or {}).hybrid or {}).overlapMs, 500))

    -- The flying half, spawned where the bodies already are.
    local flight = {
        -- Shares the run's liveness rather than copying it: a stop lands
        -- mid-flight because `flyTo` reads this same table.
        alive = true,
        style = "effect",
        stepName = step.formation,
        failures = 0,
        ids = {}, positions = {}, sent = {}, lightIds = {},
        bucket = run.bucket, ttl = run.ttl, record = nil,
    }
    local hz, refusal = budgetedRate(#run.positions, "effect")
    if hz == nil then
        log("hybrid: the flying half does not fit the budget: %s", tostring(refusal))
        haltRun(run, "hybrid flight over budget")
        return false
    end
    flight.hz = hz

    local ok, reason = spawnFigure(flight, run.positions, step, true)
    if not ok then
        log("hybrid: could not light the movement into %s: %s", step.formation, reason)
        haltRun(run, "hybrid flight refused")
        return false
    end

    -- Both halves up: the handover.
    if not holdFor(run, overlap) then despawnAll(flight); return false end
    despawnAll(run)
    flight.alive = run.alive

    if not flyTo(flight, targets, number(step.morph, 0)) then
        despawnAll(flight)
        return false
    end

    -- The bodies come back at the far end, under the lights, then the lights
    -- go out. Order matters: a body that arrives after its light has gone is a
    -- figure that appears out of nothing.
    local landed, landReason = spawnFigure(run, targets, step, step.lit ~= false)
    if not landed then
        despawnAll(flight)
        log("hybrid: could not land %s: %s", step.formation, landReason)
        haltRun(run, "hybrid landing refused")
        return false
    end
    local ready = awaitReady(run)
    if not holdFor(run, overlap) then despawnAll(flight); return false end
    despawnAll(flight)
    return ready
end

local function walk(run, steps)
    CreateThread(function()
        -- A reveal on the opening step is drawn HERE rather than in `play`,
        -- because it takes seconds and `play` must answer its caller at once.
        if run.openingReveal ~= nil and run.openingReveal > 0 then
            if not revealFigure(run, poseFor(run.basis, steps[1]), steps[1], run.openingReveal) then
                return
            end
        end
        if not awaitReady(run) then return end
        -- The swarm was spawned standing in the first pose, so that step owes
        -- no flight -- only its hold, which is the beat before the launch.
        if not holdFor(run, steps[1].hold) then return end

        -- A LOOP IS A CIRCULAR STEP LIST, and nothing more. After the last
        -- step it comes back round to the first, which for a light-cycling
        -- show is the cheap relight above rather than a respawn -- so a show
        -- left running for an evening does not accumulate anything.
        --
        -- It is bounded by the same things everything else is: the run's own
        -- `alive` flag, which `stop <show>` and the resource teardown both
        -- clear, and the audience check inside every hold.
        -- The advance happens at the TOP so that `::continue::` stays the last
        -- statement in the block. Lua forbids a goto that jumps into a local's
        -- scope, and every driver branch below declares one -- so putting the
        -- bookkeeping after the label does not compile.
        local index = 1
        while run.alive do
            index = index + 1
            if index > #steps then
                if steps.loop ~= true then break end
                index = 1
                run.cycles = (run.cycles or 0) + 1
            end
            local step = steps[index]
            run.stepName = step.formation

            if run.driver == "hybrid" then
                if not hybridTo(run, step) then return end
                run.color, run.lit = step.color or run.color, step.lit ~= false
                if not holdFor(run, step.hold) then return end
                goto continue
            end

            if run.driver == "sequence" then
                -- `morph` is the movement's duration here, exactly as it is
                -- for the streaming styles -- so every shipped show is already
                -- a sequence, it just gets redrawn pose by pose instead of
                -- interpolated.
                if not sequenceTo(run, step, run.frameMs) then return end
                run.color, run.lit = step.color or run.color, step.lit ~= false
                if not holdFor(run, step.hold) then return end
                goto continue
            end

            if run.driver == "cut" then
                -- No morph exists for this style, so `morph` is ignored and
                -- the figure is cut to instead. Colour and `lit` ride on the
                -- spawn rather than on a later write.
                if not cutTo(run, step) then return end
                run.color, run.lit = step.color or run.color, step.lit ~= false
                if not holdFor(run, step.hold) then return end
                goto continue
            end

            local targets = assign(run.positions, poseFor(run.basis, step))
            if not flyTo(run, targets, number(step.morph, 0)) then return end
            if not run.alive then return end

            -- Colour and on/off land on arrival, which is the only place they
            -- can: writing a light blinks its component for one frame, so an
            -- animated colour strobes. At a pose boundary that blink is the
            -- flash you want.
            local wantedColor = step.color or run.color
            local wantedLit = step.lit ~= false
            if wantedColor ~= run.color or wantedLit ~= run.lit then
                run.color, run.lit = wantedColor, wantedLit
                for droneIndex = 1, #run.ids do
                    restyleDrone(run.style, run.ids[droneIndex], wantedColor, wantedLit)
                end
            end

            if not holdFor(run, step.hold) then return end
            ::continue::
        end

        if run.alive then haltRun(run, "finished") end
    end)
end

--- Start a show at a world point. Answers `true`, or `false` and a reason in
--- plain English -- this is the export, so the reason is what another resource
--- will put in front of a player.
local function play(showName, position, bucket, facing)
    if not state.ready then return false, "the drone show is not configured correctly" end

    local name = showName or Config.defaultShow
    local steps = (Config.shows or {})[name]
    if type(steps) ~= "table" or #steps == 0 then
        return false, "there is no show called " .. tostring(name)
    end
    if type(position) ~= "table" or position.x == nil then
        return false, "the show needs a position"
    end
    if state.runs[name] ~= nil then
        return false, ("%s is already in the air"):format(name)
    end

    -- `Open77.time.monotonic` answers SECONDS; the cooldown is written in
    -- milliseconds because that is the unit the steps are written in.
    local now = Open77.time.monotonic() * 1000.0
    -- Per show, not global: two DIFFERENT shows must not block each other just
    -- because one of them started recently. The cooldown is there to stop the
    -- same show being spammed, and the budget gate above is what stops the sky
    -- filling up.
    state.lastPlayed = state.lastPlayed or {}
    if now - number(state.lastPlayed[name], -math.huge) < number(Config.cooldownMs, 15000) then
        return false, name .. " was played too recently"
    end
    if audience() == 0 then
        return false, "nobody is connected to watch it"
    end

    local anchor = {
        x = number(position.x, 0.0),
        y = number(position.y, 0.0),
        z = number(position.z, 0.0),
    }
    -- The bucket is stated, never guessed: a drone created into a routing
    -- bucket nobody occupies is invisible while every call reports success.
    local routing = math.floor(number(bucket, 0))
    local stage = stageOf(steps)
    local basis = stageBasis(anchor, number(facing, stage.facing), nil, stage)
    local style = activeStyle()

    -- THE SWARM GATE, across every show in the air rather than just this one.
    --
    -- The server's own ceiling is 512 NPCs a resource and the byte budget
    -- below is the one that disconnects people, but the ceiling that bites
    -- first and silently is the CLIENT's: about a thousand dynamic-entity
    -- slots, shared with everything else, and no diagnostics at all when it
    -- fills -- spawns simply stop arriving, forever, with a clean log. Two
    -- lit npc shows are four entities per drone between them.
    local wantedDrones = #Formations.shapes[steps[1].formation]
    local liveDrones = 0
    for _, other in ipairs(liveRuns()) do
        liveDrones = liveDrones + math.max(#other.ids, other.droneCount or 0)
    end
    local ceiling = math.floor(number(Config.maxDrones, 64))
    if liveDrones + wantedDrones > ceiling then
        return false, ("%d drones plus the %d already flying is past the %d ceiling -- %s is up")
            :format(wantedDrones, liveDrones, ceiling, flyingSummary())
    end

    -- THE BUDGET GATE. Nothing is spawned until the show is known to fit
    -- inside the link -- and inside what is LEFT of it, because every show in
    -- the air is spending from the same per-viewer slice. The alternative,
    -- discovering it does not eight seconds in, costs the audience its
    -- session.
    local hz, refusal = budgetedRate(wantedDrones, style)
    if hz == nil then return false, refusal end

    -- THE NPC GATE. The style is proven now -- a parade flew in front of the
    -- owner with 8 of 8 bodies ready on every frame of every movement -- so
    -- this is no longer a warning, only a switch. It stays because the style
    -- spawns real NPCs against a client entity table that gives no warning
    -- when it fills, and a server owner should have to say yes once.
    if style == "npc" and ((Config.drone or {}).npc or {}).allowShow ~= true then
        return false, "the npc style is switched off -- set drone.npc.allowShow, "
            .. "or fly the effect style"
    end

    -- THE VISIBILITY GATE, for the light style only. See `farthestDrone`.
    if style == "light" then
        local limit = number(((Config.drone or {}).light or {}).maxVisibleDistance, 45.0)
        local worst = farthestDrone(basis, anchor, steps)
        if worst > limit then
            return false, ("light drones are culled past %.0f m and this show puts one at %.0f m -- ")
                :format(limit, worst)
                .. "bring stage.standoff and stage.altitude in, or fly the effect style"
        end
    end

    -- The dead-man switch. Every drone carries a TTL well past the show's own
    -- length, so a Lua error that kills the walking thread still leaves a sky
    -- that clears itself. Generous rather than tight, because the speed limit
    -- can stretch a morph and a TTL that expired mid-show would delete the
    -- swarm in front of the audience.
    local declared = 0
    for _, step in ipairs(steps) do
        declared = declared + number(step.morph, 0) + number(step.hold, 0)
    end
    local ttl = math.floor(declared * 3 + 120000)

    local first = steps[1]
    local pose = poseFor(basis, first)
    local run = {
        alive = true,
        startedAt = now,
        -- Kept alongside `#ids` because a cut show has no drones during its
        -- blackout, and a budget that forgot it then would let a second show
        -- in through the gap.
        droneCount = #pose,
        show = name,
        style = style,
        basis = basis,
        ids = {},
        positions = {},
        sent = {},
        color = first.color,
        lit = first.lit ~= false,
        hz = hz,
        -- "stream" writes a position several times a second; "task" hands out
        -- one destination per figure and lets the engine fly it. Only the npc
        -- style can be task-driven, and only then when somebody has flipped
        -- `allowShow` after measuring that it works.
        driver = driverFor(style),
        frameMs = driverFor(style) == "sequence" and sequenceFrameMs(wantedDrones) or nil,
        -- The cut driver respawns the swarm on every figure, so it has to
        -- remember how.
        bucket = routing,
        record = ((Config.drone or {}).npc or {}).record,
        ttl = ttl,
        stepName = first.formation,
        failures = 0,
    }

    -- Before the first body exists, so the sweep's vehicle branch is already
    -- disarmed when the spawner publishes it.
    applySweepGuard(routing, style)

    -- A one-step show's opening figure is spawned here, so a reveal has to be
    -- honoured here too or `signdraw` would appear all at once and only the
    -- SECOND figure of a longer show would draw itself.
    run.openingReveal = number(first.reveal, nil)
    local spawned, spawnReason = true, nil
    if run.openingReveal == nil or run.openingReveal <= 0 then
        spawned, spawnReason = spawnFigure(run, pose, first, run.lit)
    end
    if not spawned then
        if not anyRunning() then releaseSweepGuard() end
        return false, "the registry refused " .. spawnReason
    end

    state.runs[name] = run
    state.lastPlayed[name] = now

    log("show %s: %d %s drones, bucket %d, stage %.0f m out, %.0f m up, %.0f x %.0f m, from %.1f %.1f %.1f",
        name, #run.ids, style, routing,
        number(stage.standoff, 24.0), number(stage.altitude, 16.0),
        number(stage.width, 22.0), number(stage.height, 22.0),
        anchor.x, anchor.y, anchor.z)

    -- The budget, stated out loud on every show. If a client is ever dropped
    -- again, this line is the first evidence and it is already in the log.
    if run.driver == "hybrid" then
        local perFigure = number(((Config.drone or {}).npc or {}).bytesPerFigure, 300)
        local perUpdate = number(((Config.clock or {}).bytesPerUpdate or {}).effect, 555)
        log("budget: hybrid -- lights fly at %.1f Hz (%.0f KB/s per viewer), bodies land at %.1f KB a figure",
            run.hz, run.hz * #run.ids * perUpdate / 1024, #run.ids * perFigure / 1024)
    elseif run.driver == "sequence" then
        local perFigure = number(((Config.drone or {}).npc or {}).bytesPerFigure, 300)
        log("budget: sequence -- a figure every %d ms, %.1f KB each, %.0f KB/s per viewer while moving",
            run.frameMs, #run.ids * perFigure / 1024,
            1000.0 / run.frameMs * #run.ids * perFigure / 1024)
    elseif run.driver == "cut" then
        local perFigure = number(((Config.drone or {}).npc or {}).bytesPerFigure, 300)
        log("budget: cut to shape -- %.1f KB per figure per viewer, nothing between figures, %d ms of blackout",
            #run.ids * perFigure / 1024,
            math.floor(number(((Config.drone or {}).npc or {}).blackoutMs, 1200)))
    elseif run.driver == "task" then
        log("budget: destination-driven -- %d messages per figure and nothing between them",
            #run.ids)
    else
        local perUpdate = number(((Config.clock or {}).bytesPerUpdate or {})[style], 555)
        log("budget: %.1f Hz per drone, %.0f updates/s, %.0f KB/s per viewer, step at most %.2f m",
            run.hz, run.hz * #run.ids, run.hz * #run.ids * perUpdate / 1024,
            stepLimit(style))
    end

    -- The formation's own spacing, so that "the drones are inside each other"
    -- is a number before it is a screenshot. Only the npc style has a body
    -- with a size worth comparing it against.
    if style == "npc" then
        local closest = math.huge
        for a = 1, #pose do
            for b = a + 1, #pose do
                local span = distance(pose[a], pose[b])
                if span < closest then closest = span end
            end
        end
        local body = number(((Config.drone or {}).npc or {}).bodyMetres, 2.5)
        log("formation spacing: %.1f m between the two nearest drones, rig is about %.1f m wide -- %s",
            closest, body,
            closest >= body and "clear"
                or "UNDER THE RIG: hulls overlap at stroke junctions, which for a sign is by design "
                .. "(the light is the mark, and it is smaller than the body)")
    end

    walk(run, steps)
    return true
end

--- Fly a show over a player -- the form every other resource actually wants.
local function playFor(playerId, showName, facing)
    local id = math.floor(number(playerId, 0))
    if id < 1 then return false, "that is not a player id" end
    local position = Open77.players.position(id)
    if type(position) ~= "table" then return false, "that player has no position yet" end
    return play(showName, position, position.bucket, facing)
end

--- Stop one show by name, or every show when none is named.
local function stop(showName)
    if showName ~= nil and showName ~= "" and showName ~= "all" then
        local run = state.runs[showName]
        if run == nil then return false, showName .. " is not in the air" end
        haltRun(run, "stopped")
        return true
    end
    if not anyRunning() then return false, "nothing is in the air" end
    local names = {}
    for _, run in ipairs(liveRuns()) do names[#names + 1] = run.show end
    haltAll("stopped")
    return true, table.concat(names, ", ")
end

-- ---------------------------------------------------------------------------
-- The probe
--
-- ONE drone, hanging at the centre of the stage, not moving. It exists because
-- the hardest question about this resource cannot be answered by reading code:
-- which VFX in the catalogue actually reads as a point of light at 45 m
-- against a night sky. Every candidate was authored for something else -- a
-- laser mine, a loot beacon, a parade shell -- and the only two distance
-- measurements that exist in this platform's research disagree with each other.
--
-- So: hang one up and look at it. It costs a single entity and no bandwidth,
-- it cannot disconnect anybody, and `probe next` walks the whole list.
-- ---------------------------------------------------------------------------

local function probeOff()
    if state.probe == nil then return false end
    removeDrone(state.probe.style, state.probe.id)
    state.probe = nil
    return true
end

-- ---------------------------------------------------------------------------
-- The NPC probe
--
-- ONE drone NPC, spawned next to you, passive and unkillable, and then
-- MEASURED: where the server asked for it, where the engine actually put it,
-- whether anybody is simulating it, and how far it has drifted after thirty
-- seconds. That is the whole experiment, and it settles a question the source
-- cannot: every drone record resolves to an `av_*.ent` VEHICLE template rather
-- than a humanoid puppet, so the body may hover under vehicle physics instead
-- of falling to the navmesh like a person.
--
-- Two outcomes, both useful and both cheap:
--
--   drift stays near zero and it hangs there
--       the vehicle rig does not take the navmesh projection, and the npc
--       style is worth re-opening properly.
--
--   it lands, walks away, or never gets a body
--       the answer is final. Watch the client log for
--       `no_ai_agent_on_puppet`, which is the definitive negative in one
--       spawn: a body with no AI agent cannot be given any task at all.
-- ---------------------------------------------------------------------------

local function npcProbeOff()
    if state.npcProbe == nil then
        -- A guard taken for a probe is still released, so `npcprobe off` after
        -- a refused spawn does not leave a bucket with traffic switched on.
        if not anyRunning() then releaseSweepGuard() end
        return false
    end
    state.npcProbe.epoch = -1
    -- The movement instrument works on whichever style is active, so the
    -- drone it left behind is not always an NPC.
    removeDrone(state.npcProbe.style or "npc", state.npcProbe.id)
    state.npcProbe = nil
    if not anyRunning() then releaseSweepGuard() end
    return true
end

--- One drone, at a stated distance.
---
--- The distance is the whole point of the second argument. The drones BLINK --
--- reported in game, holding still, with the server sending nothing at all,
--- which rules out anything this resource does and leaves the client streaming
--- or culling the body on a cycle. A cull has a DISTANCE, so the way to find
--- one is to park a single drone at a series of them and watch:
---
---   droneshow npcprobe <record> 20    ... 30 ... 40 ... 50 ... 60
---
--- If the flicker starts somewhere between two of those, that is the boundary,
--- and the fix is geometry rather than code. If it blinks at every distance
--- including ten metres, it is not a cull and the cause is in the projection
--- path instead.
local function npcProbe(playerId, wanted, standoffOverride)
    if wanted == "off" then
        return npcProbeOff() and "Drone recalled." or "No drone probe is up."
    end

    local npc = (Config.drone or {}).npc or {}
    local list = npc.records or {}
    local index = state.npcProbeIndex or 0
    local record
    if wanted == "next" or wanted == nil then
        if #list == 0 then return "No drone records are configured." end
        index = (index % #list) + 1
        record = list[index]
    else
        record = wanted
    end

    local position = Open77.players.position(playerId)
    if type(position) ~= "table" then return "You have no position yet." end

    -- Eight metres in front and two up by default: close enough to walk
    -- around, high enough that a fall is unmistakable. A distance overrides
    -- it, which is how a cull boundary gets bisected.
    local standoff = number(standoffOverride, number(npc.probeStandoff, 8.0))
    local basis = stageBasis(position, number((Config.stage or {}).facing, 0.0), standoff)
    local asked = snap({
        x = basis.centreX,
        y = basis.centreY,
        z = position.z + number(npc.probeHeight, 2.0),
    })

    npcProbeOff()
    -- The probe is the instrument the guard is meant to be A/B'd with, so it
    -- gets the same treatment a show would.
    applySweepGuard(position.bucket, "npc")
    local id, reason = spawnDrone("npc", asked, position.bucket, nil, true, 0, record)
    if id == nil then
        return ("Drone %s refused: %s"):format(record, tostring(reason))
    end
    state.npcProbeIndex = index

    local epoch = (state.npcProbeEpoch or 0) + 1
    state.npcProbeEpoch = epoch
    state.npcProbe = { id = id, record = record, asked = asked, epoch = epoch, style = "npc" }

    -- The report. Reading `Open77.npcs.get` back is the measurement: the
    -- server adopts whatever point the engine settled the body at, so the
    -- difference between what was asked and what comes back IS the navmesh
    -- projection, in metres.
    CreateThread(function()
        local startedAt = Open77.time.monotonic()
        local schedule = npc.probeReportsAt or { 1.0, 3.0, 10.0, 30.0 }
        for _, at in ipairs(schedule) do
            local wait = math.floor((at - (Open77.time.monotonic() - startedAt)) * 1000)
            if wait > 0 then Wait(wait) end
            if state.npcProbe == nil or state.npcProbe.epoch ~= epoch then return end

            local snapshot = Open77.npcs.get(id)
            local owner = Open77.npcs.owner(id)
            if type(snapshot) ~= "table" then
                log("npcprobe %s: gone from the registry after %.0f s", record, at)
                return
            end
            local where = type(snapshot.position) == "table" and snapshot.position or snapshot
            local here = { x = number(where.x, asked.x), y = number(where.y, asked.y),
                           z = number(where.z, asked.z) }
            local authority = math.floor(number(type(owner) == "table" and owner.authorityPlayerId or 0, 0))
            -- THE CAVEAT THAT MATTERS. With no authority nothing is
            -- simulating the body, so nothing reports its position back and
            -- the canonical record is simply the number this resource wrote.
            -- "drift 0.00 m" then means "the server did not change its mind",
            -- NOT "the drone is still up there". Only a leased body reports,
            -- which is what `npcmove ... tasks` is for.
            local line = ("npcprobe %s t+%.0fs: asked z=%.2f, is z=%.2f, drift %.2f m, ready %d, authority %d%s")
                :format(record, at, asked.z, here.z, distance(asked, here),
                    math.floor(number(type(owner) == "table" and owner.readyClients or 0, 0)),
                    authority, authority == 0 and " (INERT: unobserved, this is the value we wrote)" or "")
            log("%s", line)
            say(playerId, line)
        end
    end)

    return ("Drone up: %s, %.0f m in front, %.1f m up. Watch it for a flicker, and the chat for the drift."):format(
        record, standoff, number(npc.probeHeight, 2.0))
end

-- ---------------------------------------------------------------------------
-- The light bench
--
-- ONE PHOTOGRAPH, every candidate. A row of drones at a comfortable distance,
-- each carrying a different light, evenly spaced, with the order printed to
-- the log so a single screenshot identifies all of them.
--
-- This exists because of what one photograph already did. Four rounds of logs
-- said the sign worked; the owner's picture of it said the blue glow sat below
-- and beside the hull and read as two objects. The picture settled in one pass
-- what the numbers could not settle at all -- so the right instrument for a
-- question about appearance is one that produces a comparable picture, not
-- more numbers.
-- ---------------------------------------------------------------------------

local function benchOff()
    if state.bench == nil then return false end
    local removed = 0
    for _, entry in ipairs(state.bench.drones) do
        if entry.body ~= nil then Open77.npcs.remove(entry.body) end
        if entry.light ~= nil then Open77.effects.remove(entry.light) end
        removed = removed + 1
    end
    state.bench = nil
    return removed > 0
end

--- A row of drones, one per candidate, and the order printed to the log.
---
--- `kind` picks what varies along the row: "light" walks the light set, and
--- "appearance" walks the drone's own appearance variants -- which is the
--- cheaper question, because an appearance that is already emissive makes
--- every fake light in this resource unnecessary.
local function lightBench(playerId, kind)
    local npcConfig = (Config.drone or {}).npc or {}
    local lights = npcConfig.lights or {}
    local appearanceRow = (kind == "appearance")
    local names = appearanceRow and (npcConfig.appearances or {}) or (lights.bench or {})
    if #names == 0 then return "No bench candidates are configured." end

    local position = Open77.players.position(playerId)
    if type(position) ~= "table" then return "You have no position yet." end

    benchOff()
    local spacing = number(lights.benchSpacing, 6.0)
    local basis = stageBasis(position, number((Config.stage or {}).facing, 0.0),
        number(lights.benchStandoff, 18.0))

    -- Centred on the viewer, so the row is symmetrical in frame.
    local first = -(#names - 1) * spacing * 0.5
    local drones, failed = {}, 0
    for index, name in ipairs(names) do
        local along = first + (index - 1) * spacing
        local spot = snap({
            x = basis.centreX + basis.rightX * along,
            y = basis.centreY + basis.rightY * along,
            z = position.z + number(lights.benchHeight, 3.0),
        })
        -- An appearance row varies the BODY and carries no fake light at all,
        -- because the whole question it asks is whether the body lights itself.
        --
        -- The config is borrowed for the length of one call and given straight
        -- back. That is safe HERE and only here: there is no `Wait` between
        -- the two lines, so no other coroutine can observe it. The same trick
        -- in `probe` was replaced with an explicit parameter precisely because
        -- that one could yield.
        local saved = npcConfig.appearance
        if appearanceRow then npcConfig.appearance = name end
        local body = spawnDrone("npc", spot, position.bucket, nil, true, 0, npcConfig.record)
        npcConfig.appearance = saved

        if body == nil then
            failed = failed + 1
        else
            drones[#drones + 1] = {
                name = name,
                body = body,
                light = (not appearanceRow) and spawnLight(spot, position.bucket, name) or nil,
            }
        end
    end

    if #drones == 0 then
        return "Every bench drone was refused; nothing is up."
    end
    state.bench = { drones = drones }

    -- The order, left to right as the viewer sees it, so one screenshot
    -- identifies every candidate without a second round trip.
    local order = {}
    for index, entry in ipairs(drones) do
        order[#order + 1] = ("%d:%s"):format(index, entry.name)
        if appearanceRow then
            log("bench %d (left to right): appearance %s, no added light", index, entry.name)
        else
            local definition = lightDefinition(entry.name)
            log("bench %d (left to right): %s -- %s", index, entry.name,
                tostring(definition.note or definition.effect))
        end
    end
    log("bench up: %s%s", table.concat(order, "  "),
        failed > 0 and (" (%d refused)"):format(failed) or "")
    return ("Bench up, left to right: %s. `lightbench off` when you have the picture."):format(
        table.concat(order, "  "))
end

-- ---------------------------------------------------------------------------
-- The movement instrument
--
-- ONE drone, flown back and forth between two points, and MEASURED. It exists
-- because the static half is now proven -- a frozen drone NPC hangs exactly
-- where the server puts it, thirty metres up, for thirty seconds -- and
-- movement is the only thing between that and a show.
--
-- WHAT IT FOUND, 2026-09-20: nothing moves. 58 writes sent, 58 accepted,
-- steps up to 7.79 m, the canonical position changing on 9 reads out of 10 --
-- and four screen captures with the camera unmoved, building edges aligning
-- pixel for pixel, showing the drone on the same pixel throughout. Re-run with
-- a simulation lease and steps up to 13.79 m: the same. It is not the deadband
-- and it is not the lease; a server transform write reaches the canonical
-- record and never reaches the rendered body.
--
-- The instrument stays because one axis is still unrun -- the console path
-- shifted its arguments by one and silently ran horizontal when vertical was
-- asked for -- and because it is the thing that would notice if a future
-- build changed its mind.
--
-- WHAT IT WAS TESTING, and the prediction it tested against. A server
-- `setTransform` bumps the NPC's revision; the client compares the new
-- canonical point against where the body is and arms a placement ONLY IF THEY
-- DIFFER BY MORE THAN TWO METRES, then issues an `AI::TeleportCommand` every
-- 300 ms until the body is within two metres, twelve attempts at most. So:
--
--   commanded step under 2 m   the deadband swallows it, nothing moves
--   commanded step over 2 m    coarse teleports, 300 ms apart at best
--
-- `step at most` in the report is the number to read against that 2 m line,
-- and the defaults sweep both sides of it.
--
-- AND THE TRAP IN THE MEASUREMENT. `Open77.npcs.get` returns the CANONICAL
-- record. With no authority lease nothing simulates the body and nothing
-- reports its position back, so the canonical record is only ever what this
-- resource last wrote: the error reads as a perfect zero whatever the body is
-- really doing. Every report therefore prints the authority and labels itself
-- INERT when there is none. `mode = "tasks"` grants a lease, and is the only
-- way the number becomes an observation rather than an echo.
-- ---------------------------------------------------------------------------

local function npcMoveOff()
    if state.npcMove == nil then return false end
    state.npcMove.epoch = -1
    state.npcMove = nil
    return true
end

--- Pulls a sweep's arguments out of a command line, by KIND rather than by
--- position.
---
--- Positional parsing shifted by one on the console path and silently ran a
--- horizontal sweep when a vertical one was asked for -- which is the worst
--- kind of defect in an instrument, because the log looked plausible and the
--- experiment simply never happened. `horizontal`/`vertical` and
--- `frozen`/`tasks` are now recognised wherever they appear, and the numbers
--- are taken in the order they are written, so the same call works from chat
--- and from the console and tolerates a missing argument in the middle.
local function sweepArguments(args, from)
    local numbers, axis, mode = {}, nil, nil
    for index = from, #args do
        local token = args[index]
        if token == "horizontal" or token == "vertical" then
            axis = token
        elseif token == "frozen" or token == "tasks" then
            mode = token
        else
            local value = tonumber(token)
            if value ~= nil then numbers[#numbers + 1] = value end
        end
    end
    return numbers[1], numbers[2], axis, mode
end

local function npcMove(playerId, rate, metres, axis, mode)
    local npc = (Config.drone or {}).npc or {}
    local settings = npc.move or {}
    rate = clamp(number(rate, number(settings.rate, 2.0)), 0.1, 30.0)
    metres = clamp(number(metres, number(settings.metres, 10.0)), 0.5, 200.0)
    axis = (axis == "vertical" or axis == "horizontal") and axis or (settings.axis or "horizontal")
    mode = (mode == "tasks" or mode == "frozen") and mode or (settings.mode or "frozen")

    local position = Open77.players.position(playerId)
    if type(position) ~= "table" then return "You have no position yet." end

    -- Reuse the drone already up, so `npcprobe` then `npcmove` is one body and
    -- one teardown. Otherwise put one where the probe would have.
    -- WHICHEVER STYLE IS ACTIVE. The question this instrument was built for
    -- was "does a drone NPC move at all" and the answer was no. The question
    -- it answers NOW is the one the hybrid rests on: does a streamed EFFECT
    -- read as a glide or as a strobe? The client repositions a live particle
    -- graph in place rather than restarting it -- that is confirmed in the
    -- source -- but there is no interpolation either, so smoothness is the
    -- update rate and the step size, and only an eye can judge it.
    local style = activeStyle()
    local id, record
    if state.npcProbe ~= nil then
        id, record = state.npcProbe.id, state.npcProbe.record
    else
        record = (style == "npc") and (npc.record or "Character.Drone_Bombus_Base")
            or ((Config.drone or {}).effect or "neon.loot_drop")
        local spawnBasis = stageBasis(position, number((Config.stage or {}).facing, 0.0),
            number(npc.probeStandoff, 8.0))
        local spot = snap({
            x = spawnBasis.centreX, y = spawnBasis.centreY,
            z = position.z + number(npc.probeHeight, 2.0),
        })
        local reason
        id, reason = spawnDrone(style, spot, position.bucket, Config.defaultColor, true,
            style == "npc" and 0 or 600000, record)
        if id == nil then return ("Drone %s refused: %s"):format(record, tostring(reason)) end
        state.npcProbeEpoch = (state.npcProbeEpoch or 0) + 1
        state.npcProbe = { id = id, record = record, asked = spot, epoch = state.npcProbeEpoch,
                           style = style }
    end

    -- A lease is what turns the reported position into an observation.
    -- Meaningless for an effect, which has no AI to lease.
    if style == "effect" then
        -- nothing to do
    elseif mode == "tasks" then
        Open77.npcs.setAiMode(id, Open77.npcs.ai.tasks)
        Open77.npcs.setAIEnabled(id, true)
    else
        Open77.npcs.setAiMode(id, Open77.npcs.ai.frozen)
    end

    npcMoveOff()
    local centre = state.npcProbe.asked
    local basis = stageBasis(position, number((Config.stage or {}).facing, 0.0), 1.0)
    -- Horizontal sweeps ACROSS the viewer, which is the direction a drone show
    -- actually moves in and the one an observer is most likely to see at all.
    local along = (axis == "vertical")
        and { x = 0.0, y = 0.0, z = 1.0 }
        or { x = basis.rightX, y = basis.rightY, z = 0.0 }

    local epoch = (state.npcMoveEpoch or 0) + 1
    state.npcMoveEpoch = epoch
    state.npcMove = { epoch = epoch, id = id }

    local interval = math.max(1, math.floor(1000.0 / rate + 0.5))
    local bytes = number(npc.bytesPerState, 94)

    CreateThread(function()
        local startedAt = Open77.time.monotonic()
        local reports = settings.reportsAt or { 1.0, 3.0, 10.0, 30.0 }
        local nextReport = 1
        local sent, accepted, samples, moved = 0, 0, 0, 0
        local errorSum, errorMax, stepMax = 0.0, 0.0, 0.0
        local commanded, previousActual = centre, nil

        while true do
            Wait(interval)
            if state.npcMove == nil or state.npcMove.epoch ~= epoch then return end
            -- `npcprobe off`, or `npcprobe next`, takes the body away under
            -- us. Driving transforms at a dead id would loop forever on a
            -- refusal, so the sweep follows the drone it was given.
            if state.npcProbe == nil or state.npcProbe.id ~= id then
                log("npcmove: the drone went away, stopping")
                state.npcMove = nil
                return
            end

            local elapsed = Open77.time.monotonic() - startedAt
            -- A sinusoid rather than a ramp: it sweeps every step size from
            -- nearly zero at the ends to the maximum in the middle, so one run
            -- shows WHERE the deadband starts biting instead of testing a
            -- single step length and reporting one bit of information.
            --
            -- Six seconds for a full there-and-back, chosen so the defaults
            -- straddle the 2 m line: 10 m at 2 Hz peaks at 2.6 m per update,
            -- so if the deadband is real the drone should sit still near the
            -- ends of the sweep and jump through the middle of it.
            local phase = math.sin(elapsed * math.pi / 3.0)
            local half = metres * 0.5
            local target = snap({
                x = centre.x + along.x * phase * half,
                y = centre.y + along.y * phase * half,
                z = centre.z + along.z * phase * half,
            })
            local step = distance(commanded, target)
            if step > stepMax then stepMax = step end

            sent = sent + 1
            if moveDrone(style, id, target) then
                accepted = accepted + 1
                commanded = target
            end

            -- Only an NPC has a canonical record to read back. An effect's
            -- position is not queryable, so the error columns are blank for
            -- it and the answer is the one in front of you.
            local snapshot = (style == "npc") and Open77.npcs.get(id) or nil
            if type(snapshot) == "table" then
                -- Nested or flattened: the bundled projection client accepts
                -- both rather than trusting one, and so does this.
                local where = type(snapshot.position) == "table" and snapshot.position or snapshot
                local actual = { x = number(where.x, commanded.x),
                                 y = number(where.y, commanded.y),
                                 z = number(where.z, commanded.z) }
                local err = distance(commanded, actual)
                samples = samples + 1
                errorSum = errorSum + err
                if err > errorMax then errorMax = err end
                -- How often the reported position actually changed. Under a
                -- deadband this stays far below the sample count.
                if previousActual ~= nil and distance(previousActual, actual) > 0.01 then
                    moved = moved + 1
                end
                previousActual = actual
            end

            if nextReport <= #reports and elapsed >= reports[nextReport] then
                local owner = Open77.npcs.owner(id)
                local ready = math.floor(number(type(owner) == "table" and owner.readyClients or 0, 0))
                local authority = math.floor(number(type(owner) == "table" and owner.authorityPlayerId or 0, 0))
                local one = ("npcmove t+%.0fs: %.1f Hz %s %s | sent %d, accepted %d | step at most %.2f m")
                    :format(reports[nextReport], rate, axis, mode, sent, accepted, stepMax)
                local two = ("npcmove t+%.0fs: error mean %.2f max %.2f m | position changed %d of %d reads | %.0f B/s per viewer | ready %d, authority %d%s")
                    :format(reports[nextReport],
                        samples > 0 and errorSum / samples or 0.0, errorMax,
                        moved, samples,
                        accepted / math.max(0.001, elapsed) * bytes, ready, authority,
                        authority == 0 and " (INERT: unobserved, error is an echo)" or "")
                log("%s", one)
                log("%s", two)
                say(playerId, one)
                say(playerId, two)
                nextReport = nextReport + 1
            end
        end
    end)

    -- Say up front what this run can and cannot show. The peak step of a
    -- sinusoid is `half x (pi / period) x dt`, and whether that lands above or
    -- below two metres decides the whole experiment -- so the instrument
    -- states its own prediction rather than letting the numbers surprise
    -- somebody afterwards.
    --
    -- The consequence is worth reading twice: a HIGHER rate makes each step
    -- SMALLER and therefore more likely to be swallowed. If drone NPCs move at
    -- all, they will move on slow updates with big steps, which is the exact
    -- opposite of every other style in this resource.
    local peakStep = metres * 0.5 * (math.pi / 3.0) / rate
    log("npcmove: %s at %.1f Hz over %.0f m %s (%s), peak step %.2f m -- %s",
        record, rate, metres, axis, mode, peakStep,
        peakStep > 2.0 and "crosses the 2 m placement deadband"
                        or "STAYS UNDER the 2 m deadband, so nothing may move at all")
    return ("Flying %s: %.1f Hz, %.0f m %s, %s. Peak step %.2f m, %s. Watch the chat."):format(
        record, rate, metres, axis, mode, peakStep,
        peakStep > 2.0 and "crosses the 2 m deadband" or "under the 2 m deadband")
end

local function probe(playerId, wanted, standoffOverride)
    if wanted == "off" then
        return probeOff() and "Probe taken down." or "No probe is up."
    end

    local list = (Config.drone or {}).probes or {}
    local index = state.probeIndex or 0
    local alias
    if wanted == "next" or wanted == nil then
        if #list == 0 then return "No probe candidates are configured." end
        index = (index % #list) + 1
        alias = list[index]
    else
        alias = wanted
    end

    local style = activeStyle()
    if style == "npc" then
        -- Different question, different tool: an NPC is not hung at the stage
        -- centre and looked at, it is stood next to and measured.
        return "The style is npc -- use `droneshow npcprobe` instead."
    end

    local position = Open77.players.position(playerId)
    if type(position) ~= "table" then return "You have no position yet." end

    -- The probe hangs exactly where the middle of the picture will be, because
    -- anywhere else answers a different question. A distance can be passed to
    -- walk it in and out and find where a candidate stops reading.
    local standoff = number(standoffOverride, number((Config.stage or {}).standoff, 45.0))
    local basis = stageBasis(position, number((Config.stage or {}).facing, 0.0), standoff)
    local spot = snap(worldPoint(basis, "stage", { 0.0, 0.0, 0.0 }))
    probeOff()

    -- Ten minutes of TTL: a probe is meant to be looked at and forgotten, and
    -- forgetting it should not leave something in the sky.
    --
    -- Advanced before the spawn, not after: a candidate the registry refuses
    -- must not be the one `probe next` offers again.
    state.probeIndex = index
    local id, reason = spawnDrone(style, spot, position.bucket, Config.defaultColor, true, 600000, alias)
    if id == nil then
        return ("Probe %s refused: %s"):format(alias, tostring(reason))
    end
    state.probe = { id = id, style = style, alias = alias }
    return ("Probe up: %s, %.0f m out and %.0f m up. `probe next`, or `probe off`."):format(
        alias, standoff, number((Config.stage or {}).altitude, 30.0))
end

-- ---------------------------------------------------------------------------
-- Ways in
-- ---------------------------------------------------------------------------

--   exports.rp_drones:playFor(playerId, "open77")
--   exports.rp_drones:play("heart", { x = -1426.0, y = 974.0, z = 23.6 }, 0, 180.0)
--   exports.rp_drones:stop()
exports("play", play)
exports("playFor", playFor)
exports("stop", stop)

-- Restricted (`RegisterCommand(..., true)`): the platform refuses a caller
-- without `command.<name>` before this handler runs, and the dedicated console
-- (source 0) is always allowed. There is no rights check in this file, because
-- a check here would be a rights system enforced by the thing it grants.
RegisterCommand(Config.command or "droneshow", function(source, args)
    args = type(args) == "table" and args or {}
    local first = args[1]

    if first == "stop" then
        -- `stop` alone takes everything down; `stop <show>` takes one.
        local ok, detail = stop(args[2])
        if not ok then return say(source, "Nothing to stop: " .. tostring(detail)) end
        if args[2] ~= nil and args[2] ~= "" and args[2] ~= "all" then
            return say(source, args[2] .. " recalled.")
        end
        return say(source, "Recalled: " .. tostring(detail) .. ".")
    end

    if first == "style" then
        local wanted = args[2]
        if wanted ~= "light" and wanted ~= "effect" and wanted ~= "npc" then
            return say(source, "Style is npc, effect or light. Now: " .. activeStyle())
        end
        state.style = wanted
        -- PERSISTED, because in-memory was a trap: a `reload` silently reverted
        -- the style and a whole run went out as effect drones with nobody
        -- noticing until the log was read afterwards. `Open77.kvp` needs no
        -- permission and survives the generation swap.
        Open77.kvp.set(STYLE_KEY, wanted)
        log("style set to %s (persisted)", wanted)
        return say(source, "Next show flies " .. wanted .. " drones.")
    end

    if first == "frame" then
        -- The bisection tool, and it earned its keep: it is how 400 ms was
        -- found after a flooded counter had reported 1200. The frame length is
        -- measured rather than reasoned about, so it is settable from the
        -- command line -- and the driver abandons a movement that finds
        -- nothing ready rather than hammering a bounded request table, which
        -- is what makes a bisection run safe to type.
        --
        -- 400 ms is loopback. On a real server, add the round trip.
        local wanted = tonumber(args[2])
        if wanted == nil then
            return say(source, ("Usage: %s frame <milliseconds>. Now %d ms. "
                .. "400 is measured on loopback; add your round trip on a real server."):format(
                Config.command or "droneshow", currentFrameMs()))
        end
        local floor = sequenceFloorMs()
        local asked = math.floor(wanted)
        wanted = math.floor(clamp(wanted, floor, 10000))
        state.frameMs = wanted
        Open77.kvp.set(FRAME_KEY, tostring(wanted))
        log("flip-book frame set to %d ms (persisted)", wanted)
        if asked < floor then
            return say(source, ("%d ms is under the %d ms floor, so %d it is. About 350 ms of a "
                .. "frame is fixed cost -- a 250 ms readiness settle plus two server ticks -- "
                .. "before the engine streams any of the vehicle mesh."):format(asked, floor, wanted))
        end
        return say(source, ("Frame %d ms. Run a flip-book show and read the `worst frame` line."):format(wanted))
    end

    if first == "sweepguard" then
        local wanted = args[2]
        if wanted ~= "on" and wanted ~= "off" then
            return say(source, ("Sweep guard is on or off. Now: %s. It allows vanilla "
                .. "traffic in the show's bucket so the identity sweep stops removing "
                .. "the drones -- see the README."):format(guardWanted() and "on" or "off"))
        end
        state.sweepGuard = (wanted == "on")
        Open77.kvp.set(GUARD_KEY, wanted)
        if wanted == "off" then releaseSweepGuard() end
        log("sweep guard %s (persisted)", wanted)
        return say(source, wanted == "on"
            and "Sweep guard on. Vanilla traffic returns in the bucket while a show runs."
            or "Sweep guard off.")
    end

    if first == "choreo" then
        local wanted = args[2]
        if wanted == "sequence" then wanted = "flipbook" end
        if wanted ~= "cut" and wanted ~= "flipbook" and wanted ~= "hybrid" then
            return say(source, ("Usage: %s choreo cut|flipbook|hybrid. Now: %s"):format(
                Config.command or "droneshow",
                driverFor("npc") == "sequence" and "flipbook" or driverFor("npc")))
        end
        state.choreography = wanted
        Open77.kvp.set(CHOREO_KEY, wanted)
        log("choreography set to %s (persisted)", wanted)
        return say(source, "The npc style will " ..
            (wanted == "hybrid" and "fly lights between figures and land bodies on them."
                or wanted == "flipbook" and "redraw its way between figures."
                or "cut between figures."))
    end

    if first == "lightbench" then
        if args[2] == "off" then
            local taken = benchOff()
            return say(source, taken and "Bench taken down." or "No bench is up.")
        end
        if source == 0 then
            return log("lightbench needs a player: it builds the row in front of you")
        end
        return say(source, lightBench(source, args[2]))
    end

    if first == "status" then
        -- Cheap insurance, now that shows can loop and several can run at
        -- once: a looping show left behind is otherwise invisible until
        -- somebody notices drones in the sky.
        local runs = liveRuns()
        if #runs == 0 then
            local movers, rate = moverBudget(nil)
            return say(source, ("Nothing in the air -- room for %d drones moving at %.0f Hz.%s"):format(
                movers, rate, state.bench ~= nil and " Light bench is up." or ""))
        end
        local free = availableBytes()
        for _, run in ipairs(runs) do
            say(source, ("%s: %d %s drones, %s driver%s, %.0f KB/s"):format(
                run.show, #run.ids, run.style, run.driver,
                run.cycles ~= nil and (", looping, cycle " .. run.cycles) or "",
                runCost(run) / 1024))
        end
        local movers, rate = moverBudget(nil)
        return say(source, ("%.0f KB/s free of the slice -- room for %d drones moving at %.0f Hz%s"):format(
            free / 1024, movers, rate,
            state.bench ~= nil and ", light bench up" or ""))
    end

    if first == "npcmove" then
        if args[2] == "off" then
            local stopped = npcMoveOff()
            return say(source, stopped and "Drone stopped." or "Nothing is flying.")
        end
        if source == 0 then
            -- The console has no body, so it names the player whose viewpoint
            -- the sweep is built around:
            --   droneshow npcmove <playerId> [rate] [metres] [axis] [mode]
            local who = math.floor(number(args[2], 0))
            if who < 1 then
                return log("usage from the console: %s npcmove <playerId> [rate] [metres] [axis] [mode]",
                    Config.command or "droneshow")
            end
            return log("%s", npcMove(who, sweepArguments(args, 3)))
        end
        return say(source, npcMove(source, sweepArguments(args, 2)))
    end

    if first == "npcprobe" then
        if source == 0 then
            if args[2] == "off" then
                return log("%s", npcProbeOff() and "drone probe recalled" or "no drone probe is up")
            end
            -- The console has no body, but it can name one: the probe measures
            -- a drone against a PLAYER's position, so an operator driving this
            -- from outside the game says whose. Same rule as the show naming
            -- its own point: stated, never guessed.
            local playerId = tonumber(args[2])
            if playerId == nil then
                return log("npcprobe needs a player: %s npcprobe <playerId> [record]",
                    Config.command or "droneshow")
            end
            return log("%s", npcProbe(playerId, args[3], tonumber(args[4])))
        end
        return say(source, npcProbe(source, args[2], tonumber(args[3])))
    end

    if first == "probe" then
        if source == 0 then
            -- The probe is a "stand here and look at it" tool, so it needs a
            -- body. The console can still take one down.
            if args[2] == "off" then
                return log("%s", probeOff() and "probe taken down" or "no probe is up")
            end
            return log("probe needs a player: it hangs a candidate where you are looking from")
        end
        return say(source, probe(source, args[2], tonumber(args[3])))
    end

    if source == 0 then
        -- The console has no body, so it names the point, the heading and the
        -- routing bucket itself:
        --   droneshow <show> <x> <y> <z> [yaw] [bucket]
        -- The bucket is stated rather than guessed, because a swarm created
        -- into a bucket nobody occupies is invisible while every call reports
        -- success.
        local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
        if x == nil or y == nil or z == nil then
            return log("usage from the console: %s <show> <x> <y> <z> [yaw] [bucket]",
                Config.command or "droneshow")
        end
        local ok, reason = play(first, { x = x, y = y, z = z }, tonumber(args[6]) or 0, tonumber(args[5]))
        return log("%s", ok and "show started" or ("no show: " .. tostring(reason)))
    end

    local ok, reason = playFor(source, first, tonumber(args[2]))
    if not ok then return say(source, "No show: " .. reason) end
    say(source, "Look up.")
end, true)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Insurance, not housekeeping: the platform already clears a stopped
    -- resource's props, and this costs one call to prove it.
    Open77.props.clear()

    local ok, reason = validate()
    state.ready = ok
    if not ok then
        return log("REFUSING TO ARM: %s", reason)
    end

    -- Restore the style before anything reads it, so a reload does not
    -- silently revert to the config default mid-session.
    local saved = Open77.kvp.get(STYLE_KEY)
    if saved == "npc" or saved == "effect" or saved == "light" then
        state.style = saved
    end
    local savedChoreo = Open77.kvp.get(CHOREO_KEY)
    if savedChoreo == "cut" or savedChoreo == "flipbook"
        or savedChoreo == "sequence" or savedChoreo == "hybrid" then
        state.choreography = savedChoreo
    end
    local savedGuard = Open77.kvp.get(GUARD_KEY)
    if savedGuard == "on" or savedGuard == "off" then
        state.sweepGuard = (savedGuard == "on")
    end
    local savedFrame = tonumber(Open77.kvp.get(FRAME_KEY))
    if savedFrame ~= nil then state.frameMs = math.floor(clamp(savedFrame, 1, 10000)) end

    local shows = {}
    for showName in pairs(Config.shows or {}) do shows[#shows + 1] = showName end
    table.sort(shows)

    -- Loud on its own line, and it says where the style came from. The style
    -- is the single most consequential thing about a run and the easiest to
    -- lose track of across a reload.
    local style = activeStyle()
    log("=== STYLE: %s (%s)%s%s ===", string.upper(style),
        state.style ~= nil and "persisted" or "from config",
        style == "npc" and (", " .. driverFor(style) .. " driver") or "",
        style == "npc" and (", sweep guard " .. (guardWanted() and "ON" or "off")
            .. (driverFor(style) == "sequence" and (", flip-book at " .. currentFrameMs() .. " ms") or ""))
            or "")
    log("ready -- %d drones, shows: %s", Config.droneCount, table.concat(shows, ", "))
end)

AddEventHandler("onResourceStop", function(name, reason)
    if name ~= GetCurrentResourceName() then return end
    -- The outgoing VM still runs, so this is the last chance to empty the sky
    -- deliberately rather than relying on the platform's own sweep.
    haltAll("resource " .. tostring(reason))
    probeOff()
    npcMoveOff()
    npcProbeOff()
    benchOff()
    -- Last, and unconditionally: a borrowed population policy must not outlive
    -- the resource that borrowed it.
    releaseSweepGuard()
end)
