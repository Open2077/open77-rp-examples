# rp_weapons_effect — weapon workshop

An opt-in administrator weapon workshop with an English WebUI and the bundled Freeroam theme. Browse 137 firearm records, equip a weapon, adjust native tuning, refill ammunition and test vehicle-impact impulses.

**Requires a compatible development client containing `Open77.weapons.setTuning`, `clearTuning` and `tuning`.** The resource checks native availability and reports an unsupported client when the functions are missing. Installing Lua files does not upgrade the client DLL.

**Experimental:** gameplay validation of the six advanced stat controls and restoration after holstering is still in progress. Verify actual weapon behavior and cleanup state; native stat readback alone is not a gameplay result.

## Install and open

1. Copy `rp_weapons_effect` into your server's resources directory.
2. Add `rp_weapons_effect` to the server profile's `resources.load` list.
3. Give authorized administrators `command.weaponeffects` in the server ACL.
4. Start it with `ensure rp_weapons_effect`, then type `/weaponeffects` in game.

Select a weapon, equip it in slot 1, choose a preset or adjust the sliders, then click **Apply settings**. Close the interface to shoot. **Restore stock** removes this resource's stat modifiers while preserving other bonuses and granted weapons/ammunition.

For vehicle projection tests, equip **Comrade's Hammer**, apply **Big blast**, close the workshop and shoot a nearby vehicle whose physics this client owns. A server-authorized spawn alone does not guarantee physics ownership.

## Controls and native API

The workshop exposes reload speed, fire rate, recoil and spread. Advanced controls request native damage, magazine capacity, projectiles per shot, aim speed, charge speed and smart-projectile speed. Vehicle impulse controls are radius, horizontal push, vertical lift, falloff and cooldown.

See [Weapon customization](https://open2077.net/docs/weapon-customization) for the complete option table, Lua examples and ownership rules, and [the native weapon reference](https://open2077.net/docs/api/client/open77-weapons) for signatures and failure values.

```lua
-- Client script; declare player.weapons.edit and player.weapons.read.
if type(Open77.weapons.setTuning) ~= "function" then
    print("A compatible development client is required")
    return
end

local ok, reason = Open77.weapons.setTuning(
    "Items.Preset_Lexington_Default", { reloadSpeed = 2, recoil = 0.5 })
if not ok then print(reason) end

local state = Open77.weapons.tuning()
if state then print(state.status, state.active) end

-- Later, restore only this resource's modifiers.
Open77.weapons.clearTuning()
```

Each `setTuning` call replaces the full profile; omitted fields reset to defaults. It does not equip the weapon or rewrite its shared TweakDB record. One resource owns tuning at a time. Stop/reset releases that profile, but a holstered weapon can require deferred cleanup: inspect `pendingModifiers` and draw the old weapon to allow restoration. `restoring` and `waiting_for_restore` are explicit states.

## Commands

All commands use the same administrator ACL and target the requesting player:

```text
/weaponeffects
/weaponeffects equip Items.Preset_Burya_Comrade
/weaponeffects preset blast Items.Preset_Burya_Comrade
/weaponeffects preset fast Items.Preset_Lexington_Default
/weaponeffects preset stock Items.Preset_Burya_Comrade
/weaponeffects set reloadSpeed 3 Items.Preset_Lexington_Default
/weaponeffects ammo
/weaponeffects holster
/weaponeffects grenades
/weaponeffects state
/weaponeffects measure
/weaponeffects reset
```

`measure` logs the actual magazine readings for eight seconds, useful for comparing reloads and bursts. Space diagnostic commands by at least half a second to respect the server command limiter.

`set <field> <value> [record]` changes one field and resets every other field to its default. The optional record defaults to the catalogue's first weapon.

## Configuration and boundaries

`config.lua` contains the allowed weapon catalogue, presets and baseline bounds. `extras-config.lua` adds the advanced stat controls. Every UI request goes through the server, which rechecks the ACL, record and bounded values, then forwards only to the authenticated sender. There is no automatic tuning persistence or dependency on the other RP resources.

- The added blast starts from an actual vehicle hit by the bound weapon. Ground impacts and grenade explosions without a weapon object do not trigger it. Granted grenades retain vanilla behavior.
- Impulses affect streamed, unfrozen vehicles owned by this client. For the platform bot-fleet runner, use `--fleet-mode passenger` with `-HostPhysics`. Bumper-mode bots publish synthetic trajectories and do not simulate these forces. The resource never transfers vehicle ownership.
- Impulse counters report queued events, not measured vehicle movement. No extra explosion VFX is generated.
- Advanced native stats are weapon-dependent. Readback does not prove that each weapon's animation or projectile code uses the value. Power/tech weapons do not gain smart behavior; projectile types cannot be replaced.
- Magazine capacity and projectile count increases are rounded and capped at 512 rounds and 64 projectiles, preserving any higher pre-existing count. Increasing capacity does not add ammunition; inspect the real magazine before filling it.
- Server damage policy remains authoritative. Raw player-hit damage reports above 300 are rejected; the native damage multiplier does not bypass that cap.
- Weapon assignments and ammunition remain in the inventory after reset/stop. Only tuning modifiers are restored.

The UI assets are local; the resource makes no external web requests and contains no credentials or machine-specific paths.
