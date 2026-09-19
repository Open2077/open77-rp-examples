# Walking RP actions and inventory items

Use a base build containing [base PR #56](https://github.com/Open2077/open77-base/pull/56),
including its client, server, system resources and both updated animation archives.
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

For a different inventory item, validate ownership on the server, call
`Open77.heldItems.hold(playerId, record)` from the owning resource, then play a
compatible grip. That resource must release its item on completion or interruption.
The asynchronous request does not prove the mesh rendered: observe
`open77:helditem:completed`. The manifest needs `network.events`, `world.props`,
`players.life.read` and `players.animations.control`.
See the [native hand item contract](https://github.com/Open2077/open77-base/blob/main/wiki/attachments.md#native-hand-items-and-walking-rp-actions).

An arbitrary inventory identifier is not necessarily a native item factory with a
visible model or a matching animation grip. Job tools and the Nomad crate keep their
custom mesh attachments; those still require model-specific bone transforms.

These are third-person body animations. Native hand props are hidden on the owner's
first-person view; first-person RP arm playback is not implemented. Returning to
third person restores the projection.
