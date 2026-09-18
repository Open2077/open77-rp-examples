-- rp_shop: server-authoritative shop for an RP server.
--
-- /shop            lists the catalogue, grouped by family
-- /buy <item>      charges the price through rp_economy, then delivers
-- /sell <item>     sells back the last shop-bought vehicle of that model (50 %)
--
-- Money is never touched here: every charge and refund goes through the
-- rp_economy server exports. Vehicles bought here are remembered per durable
-- player identifier in this resource's KVP store, so /sell survives a reload.

local RESOURCE = GetCurrentResourceName()
local LOG = "[" .. RESOURCE .. "]"

-- Catalogue: `id` is what the player types. Families are listed in this
-- order by /shop. Prices are eurodollars.
local CATALOGUE = {
    { id = "soin",     family = "consommable", label = "Medkit (full health)",              price = 50,    kind = "restore", pool = "health" },
    { id = "stim",     family = "consommable", label = "Stim (full stamina)",               price = 30,    kind = "restore", pool = "stamina" },
    { id = "armure",   family = "consommable", label = "Ballistic vest (armor 100)",        price = 150,   kind = "armor",   amount = 100 },
    { id = "pistolet", family = "arme",        label = "M-10AF Lexington pistol",           price = 400,   kind = "weapon",  record = "Items.Preset_Lexington_Default", slot = 1 },
    { id = "fusil",    family = "arme",        label = "Carnage shotgun",                   price = 1200,  kind = "weapon",  record = "Items.Preset_Carnage_Default",   slot = 2 },
    { id = "katana",   family = "arme",        label = "Katana",                             price = 900,   kind = "weapon",  record = "Items.Preset_Katana_Default",    slot = 3 },
    { id = "hella",    family = "vehicule",    label = "Archer Hella (sedan)",              price = 15000, kind = "vehicle", record = "Vehicle.v_standard2_archer_hella_player" },
    { id = "quadra",   family = "vehicule",    label = "Quadra Turbo-R (hypercar)",          price = 60000, kind = "vehicle", record = "Vehicle.v_sport1_quadra_turbo_r_player" },
}

local FAMILIES = {
    { key = "consommable", title = "Consumables" },
    { key = "arme",        title = "Weapons" },
    { key = "vehicule",    title = "Vehicles" },
}

local SELL_RATIO = 0.5            -- refund on /sell
local VEHICLE_SIDE_OFFSET = 3.5   -- metres to the player's right
local POSITION_MAX_AGE_MS = 5000  -- reject a stale player snapshot
local WEAPON_FALLBACK_MS = 15000  -- refund if the weapon relay never answers

local byId = {}
for _, item in ipairs(CATALOGUE) do
    byId[item.id] = item
end

-- Vehicles bought and not yet sold, keyed by durable identifier:
-- garages[identifier] = { { id, record, item, price, at }, ... } (oldest first).
local garages = {}

-- Weapon deliveries waiting for open77:weapons:completed, keyed by request id.
local pendingWeapons = {}

local SUGGESTIONS = {
    { command = "/shop", help = "Show the shop catalogue" },
    { command = "/buy",  help = "Buy an item from the shop",
      parameters = { { name = "item", help = "soin, stim, armure, pistolet, fusil, katana, hella, quadra" } } },
    { command = "/sell", help = "Sell back a vehicle bought here (50% of the price)",
      parameters = { { name = "item", help = "hella or quadra (empty = last vehicle)" } } },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function say(playerId, text)
    local ok, reason = Open77.chat.send(playerId, text)
    if not ok then
        print(LOG .. " chat.send refused for player " .. tostring(playerId) .. ": " .. tostring(reason))
    end
end

local function priceLabel(amount)
    return tostring(math.floor(tonumber(amount) or 0)) .. " $"
end

local function identifierOf(playerId)
    local identifier = Open77.players.identifier(playerId)
    if identifier == nil or identifier == "" then
        return nil
    end
    return tostring(identifier)
end

-- Every economy call is synchronous and RAISES when rp_economy is missing or
-- refuses the call, so it is wrapped. Returns: status, value, reason
--   status = "offline"  the export could not be reached (value = error text)
--   status = "refused"  the export answered nil, reason
--   status = "ok"       value is the new balance
local function ecoRemove(playerId, amount, reason)
    local ok, balance, why = pcall(function()
        return exports.rp_economy:remove(playerId, amount, reason)
    end)
    if not ok then
        return "offline", tostring(balance)
    end
    if balance == nil then
        return "refused", nil, tostring(why or "unknown")
    end
    return "ok", balance
end

local function ecoAdd(playerId, amount, reason)
    local ok, balance, why = pcall(function()
        return exports.rp_economy:add(playerId, amount, reason)
    end)
    if not ok then
        return "offline", tostring(balance)
    end
    if balance == nil then
        return "refused", nil, tostring(why or "unknown")
    end
    return "ok", balance
end

local function ecoBalance(playerId)
    local ok, balance = pcall(function()
        return exports.rp_economy:getBalance(playerId)
    end)
    if ok and type(balance) == "number" then
        return balance
    end
    return nil
end

-- Refund after a failed delivery; tells the player either way.
local function refund(playerId, item, why)
    local status, value, reason = ecoAdd(playerId, item.price, "remboursement " .. item.id)
    if status == "ok" then
        say(playerId, ("Delivery failed (%s): %s refunded."):format(tostring(why), priceLabel(item.price)))
        print(LOG .. " player " .. tostring(playerId) .. " refunded " .. item.price .. " for " .. item.id .. " (" .. tostring(why) .. ")")
    else
        say(playerId, ("Delivery failed (%s) and refund failed (%s): contact an admin."):format(tostring(why), tostring(reason or value)))
        print(LOG .. " REFUND FAILED for player " .. tostring(playerId) .. " item " .. item.id .. " amount " .. item.price .. ": " .. tostring(reason or value))
    end
end

-- Refuses the console and dead players; returns true when the caller may trade.
local function canTrade(source)
    if source == 0 then
        print(LOG .. " this command runs from the game, not from the console")
        return false
    end
    local dead, reason = Open77.players.isDead(source)
    if dead == nil then
        say(source, "Can't check your state (" .. tostring(reason or "unknown") .. "), try again in a moment.")
        return false
    end
    if dead then
        say(source, "You're dead: the shop doesn't serve corpses.")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Garage ledger (KVP, keyed by durable identifier)
-- ---------------------------------------------------------------------------

local function garageKey(identifier)
    return "garage:" .. identifier
end

local function loadGarage(identifier)
    if garages[identifier] then
        return garages[identifier]
    end
    local list = {}
    local raw = Open77.kvp.get(garageKey(identifier), nil)
    if type(raw) == "string" and raw ~= "" then
        local decoded = json.decode(raw)
        if type(decoded) == "table" then
            for _, entry in ipairs(decoded) do
                if type(entry) == "table" and entry.id ~= nil and type(entry.item) == "string" then
                    list[#list + 1] = entry
                end
            end
        else
            print(LOG .. " garage ledger of " .. identifier .. " is corrupt, starting empty")
        end
    end
    garages[identifier] = list
    return list
end

local function saveGarage(identifier)
    local list = garages[identifier] or {}
    local ok, reason
    if #list == 0 then
        -- false with no reason just means the key was already absent
        ok, reason = Open77.kvp.delete(garageKey(identifier))
        ok = ok or reason == nil
    else
        local encoded = json.encode(list)
        if not encoded then
            print(LOG .. " could not encode the garage ledger of " .. identifier)
            return
        end
        ok, reason = Open77.kvp.set(garageKey(identifier), encoded)
    end
    if not ok then
        print(LOG .. " kvp write failed for " .. identifier .. ": " .. tostring(reason))
    end
end

-- The ledger entry's vehicle, if it still exists and is still ours.
local function ledgerVehicle(entry)
    local vehicle = Open77.vehicles.get(entry.id)
    if not vehicle then
        return nil
    end
    -- Guard against a recycled id pointing at somebody else's car.
    if vehicle.record ~= entry.record then
        return nil
    end
    if vehicle.resource ~= nil and vehicle.resource ~= RESOURCE then
        return nil
    end
    return vehicle
end

-- Drops entries whose vehicle is gone; returns true when something changed.
local function pruneGarage(identifier)
    local list = garages[identifier]
    if not list then
        return false
    end
    local kept, changed = {}, false
    for _, entry in ipairs(list) do
        if ledgerVehicle(entry) then
            kept[#kept + 1] = entry
        else
            changed = true
        end
    end
    if changed then
        garages[identifier] = kept
        saveGarage(identifier)
    end
    return changed
end

-- ---------------------------------------------------------------------------
-- Delivery
-- ---------------------------------------------------------------------------

local function deliverRestore(playerId, item)
    local ok, reason = Open77.stats.restore(playerId, item.pool)
    if not ok then
        return false, reason or "refused"
    end
    return true
end

local function deliverArmor(playerId, item)
    local ok, reason = Open77.players.setArmor(playerId, item.amount)
    if not ok then
        return false, reason or "refused"
    end
    return true
end

-- Asynchronous: the money is already taken, the answer comes back on
-- open77:weapons:completed (or never, hence the fallback thread).
local function deliverWeapon(playerId, item)
    local requestId, reason = Open77.weapons.assign(playerId, item.record, item.slot, { active = true })
    if not requestId then
        return false, reason or "refused"
    end
    local key = tostring(requestId)
    pendingWeapons[key] = { playerId = playerId, item = item }
    CreateThread(function()
        Wait(WEAPON_FALLBACK_MS)
        local pending = pendingWeapons[key]
        if pending then
            pendingWeapons[key] = nil
            print(LOG .. " weapon request " .. key .. " never completed for player " .. tostring(playerId))
            refund(playerId, item, "no answer from the client")
        end
    end)
    return true, nil, "pending"
end

AddEventHandler("open77:weapons:completed", function(playerId, requestId, operation, accepted, reason, result)
    local pending = pendingWeapons[tostring(requestId)]
    if not pending then
        return
    end
    pendingWeapons[tostring(requestId)] = nil
    local target = tonumber(playerId) or pending.playerId
    local okAccepted = (accepted == true) or (accepted == "true")
    if okAccepted then
        local slot = (type(result) == "table" and result.slot) or pending.item.slot
        say(target, ("Delivered: %s (slot %s)."):format(pending.item.label, tostring(slot)))
        print(LOG .. " player " .. tostring(target) .. " received " .. pending.item.id)
    else
        refund(target, pending.item, tostring(reason or operation or "refused"))
    end
end)

-- Spawns the car beside the player, facing the same way. `me` is a fresh
-- Open77.players.get snapshot validated by the caller.
local function deliverVehicle(playerId, item, me, identifier)
    local yaw = tonumber(me.heading) or tonumber(me.yaw) or 0.0
    -- REDengine: yaw 0 faces +y, +x is the entity's right. A positive yaw is
    -- taken as a counter-clockwise turn seen from above, so the right-hand
    -- unit vector is (cos, sin); a wrong sign only swaps left and right.
    local rad = math.rad(yaw)
    local rx, ry = math.cos(rad), math.sin(rad)
    local vehicleId, reason = Open77.vehicles.create({
        record = item.record,
        position = {
            x = me.position.x + rx * VEHICLE_SIDE_OFFSET,
            y = me.position.y + ry * VEHICLE_SIDE_OFFSET,
            z = me.position.z,
        },
        yaw = yaw,
        bucket = me.bucket,
        persistent = true, -- the player's property: only /sell removes it
    })
    if not vehicleId then
        return false, reason or "refused"
    end
    local list = loadGarage(identifier)
    list[#list + 1] = {
        id = vehicleId,
        record = item.record,
        item = item.id,
        price = item.price,
        at = math.floor(Open77.time.unix()),
    }
    saveGarage(identifier)
    return true, nil, vehicleId
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- Staging (2026-09-18 pass): a purchase is a short hand-over the bystanders can see. Same
-- rules as rp_mecano / rp_nomade (this legacy resource has no shared config, so the table
-- lives here): `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first, then today's 18-profile eval catalogue);
-- `loop = false` is a one-shot of `durationMs`. Props are curated aliases tried in order,
-- attached to a rig slot ("RightHand"); hand-slot axes are not measured on 2.31.
local SHOP_STAGE = {
    enabled = true,
    purchase = {
        durationMs = 2500,
        pose = { profiles = { { profile = "carry_pickup" }, { profile = "give" } }, loop = false },
        prop = { models = { "shop.bag", "crate.cardboard" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    weapon = {
        durationMs = 2500,
        pose = { profiles = { { profile = "carry_pickup" }, { profile = "give" } }, loop = false },
        prop = { models = { "military.case" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- A vehicle: the keys come over the holo.
    vehicle = {
        durationMs = 3000,
        pose = { profiles = { { profile = "phonecheck" }, { profile = "phone" } }, loop = false },
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

local STAGE = SHOP_STAGE or {}
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

RegisterCommand("shop", function(source, args, raw)
    if source == 0 then
        for _, item in ipairs(CATALOGUE) do
            print(LOG .. " " .. item.id .. " - " .. item.label .. " - " .. priceLabel(item.price))
        end
        return
    end
    local lines = { "=== Shop === (/buy <item>, /sell <item>)" }
    for _, family in ipairs(FAMILIES) do
        lines[#lines + 1] = "-- " .. family.title .. " --"
        for _, item in ipairs(CATALOGUE) do
            if item.family == family.key then
                lines[#lines + 1] = ("  %s: %s - %s"):format(item.id, item.label, priceLabel(item.price))
            end
        end
    end
    local balance = ecoBalance(source)
    if balance then
        lines[#lines + 1] = "Your balance: " .. priceLabel(balance)
    else
        lines[#lines + 1] = "Money system offline: purchases are unavailable for now."
    end
    -- Two sends in the same tick arrive in reverse order: one line per tick.
    for _, line in ipairs(lines) do
        say(source, line)
        Wait(0)
    end
end, false)

RegisterCommand("buy", function(source, args, raw)
    if not canTrade(source) then
        return
    end
    local wanted = args[1] and string.lower(args[1]) or nil
    local item = wanted and byId[wanted] or nil
    if not item then
        say(source, "Usage: /buy <item>. Items: soin, stim, armure, pistolet, fusil, katana, hella, quadra (/shop for prices).")
        return
    end

    -- Everything that can refuse for free is checked BEFORE the money moves.
    local me, identifier
    if item.kind == "vehicle" then
        identifier = identifierOf(source)
        if not identifier then
            say(source, "Identity not found: can't register the vehicle in your name.")
            return
        end
        local reason
        me, reason = Open77.players.get(source)
        if not me then
            say(source, "Position unknown (" .. tostring(reason or "unknown") .. "): try again in a moment.")
            return
        end
        if not me.position or (me.ageMs or 0) > POSITION_MAX_AGE_MS then
            say(source, "Position too stale: move a bit and try again.")
            return
        end
    end

    local status, balance, reason = ecoRemove(source, item.price, "achat " .. item.id)
    if status == "offline" then
        say(source, "Money system offline: can't buy right now.")
        print(LOG .. " rp_economy unreachable for player " .. tostring(source) .. ": " .. tostring(balance))
        return
    end
    if status == "refused" then
        if reason == "insufficient_funds" then
            local have = ecoBalance(source)
            say(source, ("Insufficient funds: %s costs %s%s."):format(item.label, priceLabel(item.price),
                have and (", you have " .. priceLabel(have)) or ""))
        else
            say(source, "Payment refused (" .. tostring(reason) .. ").")
        end
        return
    end
    print(LOG .. " player " .. tostring(source) .. " bought " .. item.id .. " for " .. item.price)
    gesture(source, item.kind == "weapon" and "weapon" or item.kind == "vehicle" and "vehicle" or "purchase")

    local ok, why, extra
    if item.kind == "restore" then
        ok, why = deliverRestore(source, item)
    elseif item.kind == "armor" then
        ok, why = deliverArmor(source, item)
    elseif item.kind == "weapon" then
        ok, why, extra = deliverWeapon(source, item)
    elseif item.kind == "vehicle" then
        ok, why, extra = deliverVehicle(source, item, me, identifier)
    else
        ok, why = false, "misconfigured item"
    end

    if not ok then
        refund(source, item, why)
        return
    end
    if item.kind == "weapon" then
        say(source, ("Bought %s for %s, delivery in progress... (balance: %s)"):format(item.label, priceLabel(item.price), priceLabel(balance)))
    elseif item.kind == "vehicle" then
        say(source, ("Bought %s for %s: it's waiting right next to you (balance: %s)."):format(item.label, priceLabel(item.price), priceLabel(balance)))
        print(LOG .. " vehicle " .. tostring(extra) .. " created for player " .. tostring(source))
    else
        say(source, ("Bought %s for %s (balance: %s)."):format(item.label, priceLabel(item.price), priceLabel(balance)))
    end
end, false)

RegisterCommand("sell", function(source, args, raw)
    if not canTrade(source) then
        return
    end
    local wanted = args[1] and string.lower(args[1]) or nil
    local item = wanted and byId[wanted] or nil
    if wanted and not item then
        say(source, "Unknown item. Usage: /sell <hella|quadra> (empty = your last vehicle).")
        return
    end
    if item and item.kind ~= "vehicle" then
        say(source, "Only vehicles bought here can be sold back (hella, quadra).")
        return
    end

    local identifier = identifierOf(source)
    if not identifier then
        say(source, "Identity not found: can't look up your vehicles.")
        return
    end
    local list = loadGarage(identifier)
    pruneGarage(identifier)
    list = garages[identifier]

    -- The last still-existing shop-bought vehicle (of that model, if given).
    local index
    for i = #list, 1, -1 do
        if (not item or list[i].item == item.id) and ledgerVehicle(list[i]) then
            index = i
            break
        end
    end
    if not index then
        if item then
            say(source, "You have no " .. item.label .. " bought here still on the road.")
        else
            say(source, "You have no vehicle bought here still on the road.")
        end
        return
    end
    local entry = list[index]
    local sold = byId[entry.item]
    local refundAmount = math.floor((tonumber(entry.price) or (sold and sold.price) or 0) * SELL_RATIO)
    local label = sold and sold.label or entry.item

    -- Money first: a refund that fails leaves the car with its owner.
    local status, balance, reason = ecoAdd(source, refundAmount, "vente " .. entry.item)
    if status == "offline" then
        say(source, "Money system offline: can't sell right now.")
        print(LOG .. " rp_economy unreachable for player " .. tostring(source) .. ": " .. tostring(balance))
        return
    end
    if status == "refused" then
        say(source, "Refund refused (" .. tostring(reason) .. "): sale cancelled.")
        return
    end

    local removed = Open77.vehicles.remove(entry.id)
    if not removed then
        -- Take the refund back; the player keeps the car.
        local back = ecoRemove(source, refundAmount, "annulation vente " .. entry.item)
        if back ~= "ok" then
            print(LOG .. " could not take back the refund of " .. refundAmount .. " from player " .. tostring(source))
        end
        say(source, "The vehicle could not be removed: sale cancelled.")
        return
    end
    table.remove(list, index)
    saveGarage(identifier)
    say(source, ("%s sold for %s (balance: %s)."):format(label, priceLabel(refundAmount), priceLabel(balance)))
    print(LOG .. " player " .. tostring(source) .. " sold " .. entry.item .. " (vehicle " .. tostring(entry.id) .. ") for " .. refundAmount)
end, false)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Host event: every argument is a string. Keep the ledgers honest when a car
-- disappears for any reason (explosion cleanup, admin removal...).
AddEventHandler("onVehicleRemoved", function(vehicleId, reason)
    local gone = tostring(vehicleId)
    for identifier, list in pairs(garages) do
        for i = #list, 1, -1 do
            if tostring(list[i].id) == gone then
                table.remove(list, i)
                saveGarage(identifier)
            end
        end
    end
end)

-- Forget the in-memory ledger of a departed player; the KVP copy stays.
AddEventHandler("onPlayerDisconnected", function(playerId, reason)
    if tonumber(playerId) then stageClear(tonumber(playerId)) end
    local identifier = Open77.players.identifier(playerId)
    if identifier ~= nil and identifier ~= "" then
        garages[tostring(identifier)] = nil
    end
end)

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source == 0 then
        return
    end
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    print(LOG .. " shop open: " .. #CATALOGUE .. " items, /shop for the catalogue")
end)
