-- rp_radio client: the radio push-to-talk key and the local jam gain.
--
-- The server owns everything that matters (membership, effects, who hears
-- what). This side only (1) transmits into the tuned radio channel while the
-- radio key is held, (2) mirrors the tuned/jam state the server pushes, and
-- (3) lowers the local channel gain during a jam (Open77.voice.setChannelVolume
-- is a client-only native, so the server asks every tuned client to do it).

local state = { key = nil, channelId = nil, jammed = false, holding = false }

local function applyLocalGain()
    if not state.channelId then return end
    local gain = state.jammed and Config.jam.localGain or 1.0
    local ok, reason = Open77.voice.setChannelVolume(state.channelId, gain)
    if not ok then print(("[rp_radio] setChannelVolume: %s"):format(tostring(reason))) end
end

-- (kind, key, channelId, jammed): "tuned" (channelId nil = tuned without a voice route), "off", "jam".
RegisterNetEvent("rp_radio:client", function(kind, key, channelId, jammed)
    if key == false then key = nil end
    if channelId == false then channelId = nil end
    if kind == "off" then
        if state.holding then
            Open77.voice.setTransmitting(false)
            state.holding = false
        end
        state.key, state.channelId, state.jammed = nil, nil, false
        return
    end
    if kind == "tuned" then
        if state.holding and state.channelId ~= channelId then
            Open77.voice.setTransmitting(false)
            state.holding = false
        end
        state.key, state.channelId, state.jammed = key, channelId, jammed == true
        applyLocalGain()
        return
    end
    if kind == "jam" then
        state.jammed = jammed == true
        if channelId then state.channelId = channelId end
        applyLocalGain()
    end
end)

local function onRadioPressed()
    if not state.key then
        Open77.hud.notify("No radio tuned. Type /radio <frequency>.")
        return
    end
    if not state.channelId then
        Open77.hud.notify(("Radio %s: no signal, text only (/radio dire)."):format(state.key))
        return
    end
    local ok, reason = Open77.voice.setTransmitting(true, "channel:" .. tostring(state.channelId))
    if not ok then
        Open77.hud.notify(("Radio: cannot transmit (%s)."):format(tostring(reason)))
        return
    end
    state.holding = true
end

local function onRadioReleased()
    if not state.holding then return end
    state.holding = false
    Open77.voice.setTransmitting(false)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Positional form with a release callback = hold mode.
    local ok, key = RegisterKeyMapping(Config.ptt.id, Config.ptt.name, Config.ptt.key, onRadioPressed, onRadioReleased)
    if ok then
        print(("[rp_radio] push-to-talk on %s"):format(tostring(key)))
    else
        print(("[rp_radio] push-to-talk key refused: %s"):format(tostring(key)))
    end
end)
