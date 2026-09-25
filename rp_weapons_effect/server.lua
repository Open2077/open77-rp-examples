local Config = WeaponEffectsConfig
local profiles, profileVersion = {}, 0
local watchedMotions = {}
local function diagnosticReason(reason)
    if type(reason)=="string" and #reason<=48 and reason:match("^[a-z_]+$") then return reason end
    return "unknown"
end
AddEventHandler("onPlayerMotionChanged", function(player,id,phase,reason)
    local watched=watchedMotions[id]
    if not watched then return end
    if Open77.time.monotonic()<=watched.expires then
        local life=Open77.players.getLifeState(player)
        print(("[weapon-blast-target] sequence=%s player=%s distance=%.2f phase=%s reason=%s life=%s")
            :format(watched.sequence,player,watched.distance,diagnosticReason(phase),
                diagnosticReason(reason),life and diagnosticReason(life.phase) or "unavailable"))
    end
    if phase=="ended" then watchedMotions[id]=nil end
end)
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
        profileVersion = profileVersion + 1
        value.version = profileVersion
        profiles[tonumber(player)] = {record=value.record, tuning=tuning, version=profileVersion, sequence=0, at=-100}
    elseif action == "equip" then
        if not record(value.record) then return end
        value = {action=action, record=value.record}
    elseif action == "ammo" or action == "holster" or action == "grenades" or action == "reset" or action == "state" or action == "measure" or action == "open" then
        value = {action=action}
        if action == "reset" then profiles[tonumber(player)] = nil end
    else return end
    TriggerClientEvent("rp_weapons_effect:approved", player, value)
end
RegisterNetEvent("rp_weapons_effect:request", function(value) dispatch(source, value) end)
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<1000000 end
RegisterNetEvent("rp_weapons_effect:blast", function(value)
    local player = tonumber(source)
    local profile = profiles[player]
    if not allowed(player) or not profile or type(value)~="table" or value.version~=profile.version
        or value.record~=profile.record or not finite(value.sequence) or value.sequence%1~=0
        or value.sequence<=profile.sequence or not finite(value.x) or not finite(value.y) or not finite(value.z) then return end
    local life = Open77.players.getLifeState(player)
    local origin = Open77.players.position(player)
    if not life or life.phase~="alive" or not origin then return end
    local dx,dy,dz=origin.x-value.x,origin.y-value.y,origin.z-value.z
    -- This is an explicitly ACL-gated test tool, not a trusted damage receipt.
    -- Bound reported shot range and derive all targets/strength on the server.
    if dx*dx+dy*dy+dz*dz>250*250 then return end
    local now,tuning=Open77.time.monotonic(),profile.tuning
    if tuning.blastRadius<=0 or now-profile.at < tuning.blastCooldown*.8 then return end
    profile.sequence,profile.at=value.sequence,now
    local targets={}
    for _,target in ipairs(GetPlayers()) do
        local p=tonumber(target)~=player and Open77.players.position(target)
        if p and p.bucket==origin.bucket then
            local x,y,z=p.x-value.x,p.y-value.y,p.z-value.z
            if x*x+y*y+z*z<tuning.blastRadius*tuning.blastRadius and #targets<256 then
                targets[#targets+1]=target
            end
        end
    end
    if #targets>0 and Open77.exports and type(Open77.exports.call)=="function" then
        local pending,reason=Open77.exports.call("open77_crowd_ambient","stopForBlastTargets",targets)
        if pending then
            local ok,stopped=pcall(function() return pending:await() end)
            if not ok or stopped~=true then return end
        elseif reason~="export_resource_unavailable" then return end
    end
    -- The export yields: revoked settings/death/bucket changes cannot authorize
    -- a later launch, and late hits never become delayed surprise impulses.
    life=Open77.players.getLifeState(player)
    local currentOrigin=Open77.players.position(player)
    if profiles[player]~=profile or not allowed(player) or not life or life.phase~="alive"
        or not currentOrigin or currentOrigin.bucket~=origin.bucket or Open77.time.monotonic()-now>.75 then return end
    -- Diagnostics are bounded independently of crowd size. Keep nearest bodies
    -- so a direct-hit victim can be compared with the surrounding blast victims.
    table.sort(targets,function(a,b)
        local pa,pb=Open77.players.position(a),Open77.players.position(b)
        local function squared(p)
            if not p then return math.huge end
            return (p.x-value.x)^2+(p.y-value.y)^2+(p.z-value.z)^2
        end
        return squared(pa)<squared(pb)
    end)
    local watchCount=0
    for id,watched in pairs(watchedMotions) do
        if watched.expires<now then watchedMotions[id]=nil else watchCount=watchCount+1 end
    end
    local accepted,rejected,reasons,details=0,0,{},{}
    for _,target in ipairs(targets) do
        if tonumber(target)~=player then
            local p=Open77.players.position(target)
            if p and p.bucket==origin.bucket then
                local x,y,z=p.x-value.x,p.y-value.y,p.z-value.z
                local distance=math.sqrt(x*x+y*y+z*z)
                if distance<tuning.blastRadius then
                    local weight=(1-distance/tuning.blastRadius)^tuning.blastFalloff
                    local push,lift=math.min(20,tuning.blastPush*weight),math.min(14,tuning.blastLift*weight)
                    if push+lift>0 then
                        if x*x+y*y<.000001 then x,y=0,1 end
                        local targetLife=#details<8 and Open77.players.getLifeState(target)
                        local previous=#details<8 and Open77.motion.current and Open77.motion.current(target)
                        local result,reason=Open77.motion.launch(target,{x=x,y=y,push=push,lift=lift})
                        reason=result and "granted" or diagnosticReason(reason)
                        if result then accepted=accepted+1 else rejected=rejected+1; reasons[reason]=(reasons[reason] or 0)+1 end
                        if #details<8 then
                            local detail={player=tonumber(target),distance=distance,reason=reason,
                                life=targetLife and diagnosticReason(targetLife.phase) or "unavailable",
                                lifeRevision=targetLife and targetLife.revision or 0,
                                previous=previous and diagnosticReason(previous.phase) or "none",push=push,lift=lift}
                            details[#details+1]=detail
                            print(("[weapon-blast-target] sequence=%s player=%s distance=%.2f request=%s life=%s previous=%s push=%.2f lift=%.2f")
                                :format(value.sequence,target,distance,reason,detail.life,detail.previous,push,lift))
                            if result and type(result.id)=="string" and watchCount<256 then
                                watchedMotions[result.id]={sequence=value.sequence,distance=distance,expires=now+10}
                                watchCount=watchCount+1
                            end
                        end
                    end
                end
            end
        end
    end
    local histogram={}
    for reason,count in pairs(reasons) do histogram[#histogram+1]=reason..":"..count end
    table.sort(histogram)
    print(("[weapon-blast] source=%s sequence=%s accepted=%d rejected=%d position=%.2f,%.2f,%.2f reasons=%s")
        :format(player,value.sequence,accepted,rejected,value.x,value.y,value.z,table.concat(histogram,",")))
    TriggerClientEvent("rp_weapons_effect:blastResult",player,{sequence=value.sequence,accepted=accepted,rejected=rejected,
        reasons=reasons,closest=details})
end)
AddEventHandler("onPlayerDisconnected", function(player) profiles[tonumber(player)]=nil end)
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
