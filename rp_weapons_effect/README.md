# rp_weapons_effect — weapon workshop

An opt-in administrator weapon workshop with an English WebUI and the bundled Freeroam theme. Browse 137 firearm records, equip a weapon, adjust native tuning, refill ammunition and test impact blasts on nearby vehicles and network characters.

**Requires a compatible development client containing `Open77.weapons.setTuning`, `clearTuning`, `tuning` and the inventory-instance restoration fix.** The resource checks native availability and reports an unsupported client when the functions are missing. Function availability alone does not distinguish older experimental builds. Installing Lua files does not upgrade the client DLL.

Ground-contact blasts and character launches also require matching updated client/server builds and the corresponding `open77_cyberware` system resource. Headless victims need the updated bot executable. The earlier vehicle-only workshop does not supply these extensions. Motion leases do not require the implant database; canonical body readiness, alive state, incarnation and routing-bucket checks still apply.

**Experimental controls:** projectile count and smart-projectile speed expose native statistics, but their actual projectile multiplicity and flight-speed effects remain unverified. Aim speed supplies native animation timings, without a frame-accurate visual duration guarantee. Verify actual weapon behavior and cleanup state; native stat readback alone is not a gameplay result.

Cleanup can be deferred while a weapon is holstered. The corrected client tracks the exact inventory item across replacement engine entities and finishes removing its modifiers when that item is drawn again. Read `pendingModifiers` before reporting cleanup complete.

## Install and open

1. Copy `rp_weapons_effect` into your server's resources directory.
2. Add `rp_weapons_effect` to the server profile's `resources.load` list.
3. Give authorized administrators `command.weaponeffects` in the server ACL.
4. Start it with `ensure rp_weapons_effect`, then type `/weaponeffects` in game.

Select a weapon, equip it in slot 1, choose a preset or adjust the sliders, then click **Apply settings**. Close the interface to shoot. **Restore stock** removes this resource's stat modifiers while preserving other bonuses and granted weapons/ammunition.

For projection tests, equip **Comrade's Hammer**, apply **Big blast**, close the workshop and shoot a nearby vehicle. Vehicles need physics ownership on the shooting client; character launches use their own server-authorized motion lease. A server-authorized vehicle spawn alone does not guarantee physics ownership.

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

-- Restore while this weapon is drawn, before switching weapons.
Open77.weapons.clearTuning()
```

Each `setTuning` call replaces the full profile; omitted fields reset to defaults. It does not equip the weapon or rewrite its shared TweakDB record. One resource owns tuning at a time. Stop/reset releases that profile, but a holstered weapon can require deferred cleanup. `restoring`, `waiting_for_restore` and `pendingModifiers` report that queue. Exact handles are retained even after the old engine entity disappears and removed when the same inventory item is drawn again. A different copy of the same weapon record does not complete that cleanup. The queue is bounded to 32 pending bindings.

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

- The added blast consumes bound-weapon entity hits, actual native hit positions from `GameEffectExecutor_StimOnHit`, and supported tracked-projectile collision/explosion callbacks. It does not substitute a crosshair raycast. Bare-terrain Comrade coverage remains unverified; do not assume every ground shot produces a blast. Projectile disappearance without contact does not trigger it. Grenades without a bound weapon object retain vanilla behavior.
- Impulses affect streamed, unfrozen vehicles owned by this client. For the platform bot-fleet runner, use `--fleet-mode passenger` with `-HostPhysics`. Bumper-mode bots publish synthetic trajectories and do not simulate these forces. The resource never transfers vehicle ownership.
- Impulse counters report queued events, not measured vehicle movement. No extra explosion VFX is generated.
- Character launches exclude the shooter. The server derives targets in the same routing bucket and within the three-dimensional blast radius, capped at 256 candidates. Targets must be ready, alive and unmounted; existing motion and recovery protection can refuse another launch. Character strengths are capped at 20 m/s horizontally and 14 m/s upward.
- Real victims apply one native player impulse on their own client. Updated headless bots instead publish a bounded ballistic trajectory with gravity and a horizontal ground plane at their initial height. Headless bots do not simulate terrain or world collisions. Observers follow owner snapshots and display a reaction pose; they do not independently move the victim's proxy.
- The native `open77:weaponBlast(owner, record, sequence, x, y, z)` event supplies string arguments. The workshop forwards a profile-versioned request; the server rechecks ACL, record, sequence, cooldown, shooter life and reported impact distance (at most 250 meters), then chooses targets itself. This administrator lab request is not a trusted competitive hit or damage receipt.
- When the optional platform helper `open77_crowd_ambient` is running, its workspots are stopped through an awaited batch export before motion is admitted. The helper is not bundled in this public example. Profiles, life state, bucket and target range are rechecked after the wait.
- `projectileContacts` and `trackedProjectiles` diagnose the tracked-projectile path only. Native entity hits and `GameEffectExecutor_StimOnHit` can produce blasts with `projectileContacts` still zero. Character authorization/refusal counts are separate from queued car impulses. Neither counter proves visible flight; verify actual owner snapshots and motion.
- The real-owner adapter and headless bot paths have been exercised separately. Weapon-hit behavior between two real clients remains unverified.
- Character diagnostics include refusal counts and the eight nearest targets' life state, previous motion and grant or refusal reason. The UI summarizes the nearest target; nearby granted leases also log owner acknowledgement or termination. The manifest includes `players.motion.read` for these diagnostics. A direct hit that kills its victim cannot launch that corpse, and an existing reaction or recovery can refuse another lease while nearby characters launch.
- Advanced native stats are weapon-dependent. Readback does not prove that each weapon's animation or projectile code uses the value. Power/tech weapons do not gain smart behavior; projectile types cannot be replaced.
- Magazine capacity and projectile count increases are rounded and capped at 512 rounds and 64 projectiles, preserving any higher pre-existing count. Increasing capacity does not add ammunition; inspect the real magazine before filling it.
- Perform a real reload after changing magazine capacity or restoring stock: the loaded magazine can retain its previous capacity until reloaded. Read `snapshot()` again before using `setAmmo()`.
- Native damage can increase vehicle health loss, but final damage also depends on hit location and vanilla rules; the multiplier does not guarantee the same ratio in final health loss.
- Charge speed changes the time to the weapon's existing firing threshold. It does not raise its authored charge ceiling or guarantee an exact timing ratio across weapons.
- Server damage policy remains authoritative. Raw player-hit damage reports above 300 are rejected; the native damage multiplier does not bypass that cap.
- Weapon assignments and ammunition remain in the inventory after reset/stop. Only tuning modifiers are restored.

The UI assets are local; the resource makes no external web requests and contains no credentials or machine-specific paths.
