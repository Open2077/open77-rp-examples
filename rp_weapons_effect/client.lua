local Config = WeaponEffectsConfig
local menu, opened, authorized = nil, false, false
local pending = {}
local measureUntil, measureId = 0, nil
local profile, profileRevision = nil, 0
local function supportsTuning()
    return type(Open77.weapons.setTuning) == "function" and type(Open77.weapons.tuning) == "function"
        and type(Open77.weapons.clearTuning) == "function"
end
local function send(event, value)
    if not menu then return end
    local ok, reason = menu:send(event, value)
    if not ok then print("[rp_weapons_effect] UI delivery failed: " .. tostring(reason)) end
end
local function sendConfig()
    send("weapons:config", {defaults=Config.defaults, ranges=Config.ranges, presets=Config.presets})
    -- The WebUI bridge bounds each payload to 1024 values, including table keys.
    for first=1,#Config.weapons,32 do
        local page={}
        for i=first,math.min(first+31,#Config.weapons) do page[#page+1]=Config.weapons[i] end
        send("weapons:catalog", {offset=first, items=page})
    end
end
local function result(ok, message)
    send("weapons:result", {ok=ok == true, message=tostring(message or "")})
    print("[rp_weapons_effect] " .. tostring(ok) .. " " .. tostring(message))
end
local function state()
    if not supportsTuning() then
        local value={status="unsupported_client",active=false}
        send("weapons:state",value)
        return value
    end
    local value, reason = Open77.weapons.tuning()
    if value then value.profile=profile; value.profileRevision=profileRevision; send("weapons:state", value) else result(false, reason) end
    return value
end
local function close()
    opened = false
    if menu then menu:setFocus(false, false); send("weapons:closed", {}) end
end
local function request(action, id, reason)
    if not id then return result(false, reason) end
    pending[tostring(id)] = {action=action, at=Open77.time.monotonic()}
    result(true, "Request pending…")
end
RegisterNetEvent("rp_weapons_effect:approved", function(value)
    authorized = true
    if value.action == "open" then
        if not menu then return result(false, "UI unavailable") end
        opened = true
        sendConfig(); state()
        menu:setFocus(true, true); send("weapons:open", {})
    elseif value.action == "apply" then
        if not supportsTuning() then return result(false,"This client needs native weapon tuning support. Please update it.") end
        local ok, reason = Open77.weapons.setTuning(value.record, value.tuning)
        if ok then profileRevision=profileRevision+1; profile={record=value.record, tuning=value.tuning} end
        result(ok, reason or "Settings saved. Draw this weapon to apply them."); state()
    elseif value.action == "reset" then
        if not supportsTuning() then return result(false,"This client needs native weapon tuning support. Please update it.") end
        local ok, reason = Open77.weapons.clearTuning()
        if ok then profileRevision=profileRevision+1; profile=nil end
        result(ok, reason or "Reset requested. Holstered weapons will finish restoring when drawn."); state()
    elseif value.action == "equip" then
        request("equip", Open77.weapons.assign(value.record, 1, {active=true}))
    elseif value.action == "ammo" then
        request("ammo", Open77.weapons.setAmmo(1, {reserve=100, activate=true}))
    elseif value.action == "holster" then
        request("holster", Open77.weapons.holster())
    elseif value.action == "grenades" then
        request("grenades", Open77.weapons.giveGadget("Items.GrenadeFragRegular", 50, {equip=true}))
    elseif value.action == "measure" then
        measureUntil = Open77.time.monotonic()+8
        print("[rp_weapons_effect] measurement started")
    elseif value.action == "state" then
        print("[rp_weapons_effect] state=" .. json.encode(state() or {}))
    end
end)
AddEventHandler("open77:weapons:completed", function(id, operation, ok, reason)
    if tostring(id) == measureId then measureId=nil end
    ok = ok == true or ok == "true"
    local item = pending[tostring(id)]
    if not item then return end
    pending[tostring(id)] = nil
    result(ok == true, ok == true and "Equipment verified." or reason)
    if ok == true and item.action == "equip" then
        request("ammo", Open77.weapons.setAmmo(1, {reserve=100, activate=true}))
    end
end)
AddEventHandler("open77:weapons:state", function(id,slot,record,_tid,active,drawn,_locked,_ammo,_ammoId,_total,reserve,magazine,capacity)
    if tostring(id) ~= measureId or tonumber(slot) ~= 1 then return end
    print("[rp_weapons_effect] ammo=" .. json.encode({seconds=Open77.time.monotonic(),
        record=record,magazine=tonumber(magazine),capacity=tonumber(capacity),reserve=tonumber(reserve),
        active=active==true or active=="true",drawn=drawn==true or drawn=="true"}))
end)
AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    menu, reason = WebUI.create({entry="web/index.html",layer="menu",width=1920,height=1080,
        fps=30,transparent=true,visible=true})
    if not menu then return result(false, reason) end
    menu:on("weapons:ready", function() sendConfig() end)
    menu:on("weapons:close", close)
    menu:on("weapons:action", function(value)
        if authorized and opened and type(value) == "table" then TriggerServerEvent("rp_weapons_effect:request", value) end
    end)
    CreateThread(function()
        while true do
            Wait(100)
            if Open77.time.monotonic() < measureUntil and not measureId then
                local id = Open77.weapons.snapshot()
                if id then measureId=tostring(id) end
            end
        end
    end)
    CreateThread(function()
        while true do
            Wait(500)
            if opened then state() end
            for id, item in pairs(pending) do
                if Open77.time.monotonic()-item.at > 10 then pending[id]=nil; result(false,"Verification timed out.") end
            end
        end
    end)
end)
AddEventHandler("open77:pauseKey", close)
AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    close(); if supportsTuning() then Open77.weapons.clearTuning() end
    if menu then menu:destroy(); menu=nil end
end)
