# Walking RP actions and native items

This contract requires the base server build with compiled animation-item
ownership (`RpAnimationItems`) and the matching client/resources. Check your
installed base version before using `options.item`; older builds reject it.

```lua
-- Server resource manifest:
-- permissions { "players.animations.control", "world.props" }
local action, reason = Open77.animations.play(playerId, 'drink_walk', {
    item = 'Items.crowd_soda_can_a', loop = false,
})
if not action then print(reason); return end
```

Omit `item` to use the profile's default. `item=false` suppresses its default.
A custom item requires `world.props`, must be a native `Items.*` record with a
compatible grip, and is available from the server API only. No manual offset or
rotation is required. The server manages replication and lifetime; C++ handles
the arm layer and native attachment. Lua decides whether the inventory item may
be used and when its hunger/thirst or other gameplay effect should apply.
The animation API never grants or consumes inventory.

## Hold, drink, hold

From the same server resource, call `play(playerId, 'hold_item_walk', options)`,
then `play(playerId, 'drink_walk', options)`, then `play(playerId,
'hold_item_walk', options)` in response to your gameplay inputs. Keeping the same
item record preserves the prop ID. Each call returns a new `playbackId`; update
your stored ID so a late callback cannot stop the replacement action.
These calls do not schedule an automatic return. For a finite timed chain, use
`Open77.animations.sequence` and set `item` on every step. Completion removes the
animation-owned item.

`Open77.animations.stop(playerId, action.playbackId)` removes the action's item.
Cancellation, death, disconnect, bucket changes and resource shutdown also clean
it up. You need no separate `heldItems.release` for animation-owned objects.

Use `Open77.heldItems.hold` separately only when an item should outlive the
animation. An item already owned by that resource suppresses the animation's
default and remains that resource's responsibility. Stop the previous action
before taking independent ownership of an occupied hand.

## Optional mouth contact

With matching client, server and animation assets, the experimental native
adapter estimates mouth contact from the item's geometry for `drink_walk`,
`bottle_walk`, `smoke_walk` and `cigar_walk`. Omit `itemContact` for this automatic
behavior. `hold_item_walk` only holds the item; it does not fit it to the mouth.
Container contact uses the end along the item's authored local up direction
(the can rim), keeping that end as it tilts. Smoking uses the nearest end.

An unusual inventory model can supply a measured contact point without moving
its authored grip:

```lua
-- Server permissions: players.animations.control, world.props
local action, reason = Open77.animations.play(playerId, 'bottle_walk', {
    item = itemDefinition.record,
    itemContact = itemDefinition.mouthPoint,
})
if not action then print(reason); return end
-- mouthPoint: nil for automatic contact, or {x=..., y=..., z=...} for this model.
```

The point uses metres in the native item's local frame. Missing axes are zero;
supplied coordinates must be finite and within ±2 metres. `itemContact=false`
disables fitting. This option is server-only, requires `world.props` even when
false, and may be set on each sequence step. Omit it on a later action or step
to restore automatic contact. Invalid points return `invalid_item_contact`
before replacing the action. The same record keeps its animation-owned prop ID.

This adjusts the arm, not inventory or grip placement. Independently held items
keep their own settings; their owner can set `contact` on the native item's
`Open77.props.attach` binding. Broader visual validation remains incomplete.
See [item size and mouth contact](https://open2077.net/docs/rp-animations#item-size-and-mouth-contact)
for compatibility and failure details.

## Existing examples and visual limits

`rp_needs` continues to own inventory/needs policy and action timing; `rp_bar`
owns bar gameplay; `rp_phone` owns call state. All use the shared animation API.
No new per-job attachment lifecycle is necessary. Their existing stock walking
profiles continue working without `options.item` or configuration changes.

The experimental first-person adapter shows hands/items for the can, bottle,
cigarette, cigar and hold profiles on the tested female and male bodies. It keeps
the item visible at the lower right between sips and follows the camera during contact.
Hold → drink → hold preserves the item; completion removes it. Punching cancels
the layer and item, and replay creates a fresh presentation. Ground sprinting
preserves `hold_item_walk` and its item. Third-person can contact reaches the lips
on both tested bodies; other third-person combinations, appearances and custom
shapes remain under validation. A successful server call
does not prove that every phase renders correctly. Phone and other gestures do
not have the new first-person adapter.

For full options, errors and lifecycle rules see the public
[RP animation guide](https://open2077.net/docs/rp-animations#animation-owned-items-one-server-call).

A sequence controls one player's successive actions. Coordinating a handover or
another interaction between players remains the RP resource's responsibility;
this API does not implement a synchronized multi-player interaction protocol.
