-- Load after config.lua. These are native per-weapon multipliers, not changes
-- to the server's damage policy, shared TweakDB records, or projectile assets.
local ranges = {
    damage={0.1,20}, magazineCapacity={1,10}, projectilesPerShot={1,8},
    aimSpeed={0.25,10}, chargeSpeed={0.25,10}, smartProjectileSpeed={0.25,5},
}
for key, range in pairs(ranges) do
    WeaponEffectsConfig.defaults[key] = 1
    WeaponEffectsConfig.ranges[key] = range
end
