# Walking RP actions and inventory items

Use a base build with upper-body RP profiles, including matching client, server,
system resources and animation archives. See the public
[RP animation guide](https://open2077.net/docs/rp-animations) for compatibility.
The `/anim` implementation stays in the platform's `open77_animations` resource;
do not copy a second animation controller into a job.

| Action | Example | Preferred profile | Platform hand item |
|---|---|---|---|
| Smoke from inventory | `rp_inventory` → `rp_needs` | `smoke_walk` | Native cigarette |
| Drink Nicola | `rp_needs` | `drink_walk` | Native can |
| Drink water / bar drink | `rp_needs` / `rp_bar` | `bottle_walk` | Native bottle |
| Read phone / call | `rp_phone` | `phone_walk` / `call_walk` | Native phone |
| Hold, sip, hold | Custom inventory or job action | `hold_item_walk` ↔ `drink_walk` | Same native can |

Play with `Open77.animations.play(playerId, profile, options)`. The platform supplies
the profile's item with the original native hand attachment. Do not also attach a
wrist mesh for the same action. Older catalogues fall back to stationary profiles.
The `takeout` workspot supplies its own food; the extra food mesh has been removed
from `rp_needs`. Eating still uses a stationary workspot.

The inventory use bar runs before the consumption gesture. Once the walking gesture
starts, locomotion remains available. Punching or drawing a weapon cancels the layer
and its default item; a later play recreates it. Switch directly between hold and
drink profiles without stopping between them to preserve the can. Keep each
playback ID and stop only the action your resource owns.

For a different inventory item, validate ownership on the server and pass its
native `Items.*` record as `options.item` to a compatible profile. The manifest
needs `players.animations.control` and `world.props`. The platform owns the
temporary item's cleanup. Use `Open77.heldItems.hold` separately when an item
must outlive the animation; its resource then owns release. See
[walking actions and native items](held-actions.md) for both lifecycles.

Consumption contact is automatic with the experimental native adapter. For an
unusual model, an optional server-side `itemContact` selects a measured point;
see [mouth contact](held-actions.md#optional-mouth-contact). Existing jobs need
no per-item tuning to request the default behavior.

An arbitrary inventory identifier is not necessarily a native item factory with a
visible model or a matching animation grip. Job tools and the Nomad crate keep their
custom mesh attachments; those still require model-specific bone transforms.

Third-person playback and experimental first-person arms require matching client
code and animation assets. First-person support is profile-dependent; phone and
other gestures do not have the new adapter. Contact, grip and body compatibility
remain under validation. An accepted server request does not prove rendering.
