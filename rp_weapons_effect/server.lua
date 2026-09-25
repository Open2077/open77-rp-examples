local Config = WeaponEffectsConfig
local function allowed(player)
    return tonumber(player) and tonumber(player) > 0 and Open77.acl.isAllowed(player, "command.weaponeffects") == true
end
local function record(value)
    for _, weapon in ipairs(Config.weapons) do if weapon.record == value then return true end end
    return false
end
local function dispatch(player, value)
    if not allowed(player) or type(value) ~= "table" then return end
    local action = value.action
    if action == "apply" then
        if not record(value.record) or type(value.tuning) ~= "table" then return end
        local tuning = {}
        for key, range in pairs(Config.ranges) do
            local n = value.tuning[key]
            if type(n) ~= "number" or n ~= n or n < range[1] or n > range[2] then return end
            tuning[key] = n
        end
        value = {action=action, record=value.record, tuning=tuning}
    elseif action == "equip" then
        if not record(value.record) then return end
        value = {action=action, record=value.record}
    elseif action == "ammo" or action == "holster" or action == "grenades" or action == "reset" or action == "state" or action == "measure" or action == "open" then
        value = {action=action}
    else return end
    TriggerClientEvent("rp_weapons_effect:approved", player, value)
end
RegisterNetEvent("rp_weapons_effect:request", function(value) dispatch(source, value) end)
RegisterCommand("weaponeffects", function(player, args)
    local action = args[1] or "open"
    if action == "set" and Config.ranges[args[2]] then
        local tuning = {}
        for key, value in pairs(Config.defaults) do tuning[key] = value end
        tuning[args[2]] = tonumber(args[3])
        return dispatch(player, {action="apply", record=args[4] or Config.weapons[1].record, tuning=tuning})
    elseif action == "preset" then
        for _, preset in ipairs(Config.presets) do
            if preset.id == args[2] then
                local tuning = {}
                for key, value in pairs(Config.defaults) do tuning[key] = preset.values[key] or value end
                return dispatch(player, {action="apply", record=args[3] or Config.weapons[1].record, tuning=tuning})
            end
        end
    else dispatch(player, {action=action, record=args[2] or Config.weapons[1].record}) end
end, true)
