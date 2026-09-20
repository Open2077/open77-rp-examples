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

## Existing examples and visual limits

`rp_needs` continues to own inventory/needs policy and action timing; `rp_bar`
owns bar gameplay; `rp_phone` owns call state. All use the shared animation API.
No new per-job attachment lifecycle is necessary. Their existing stock walking
profiles continue working without `options.item` or configuration changes.

First-person hands/can have been observed in the experimental base client.
Drink-to-mouth alignment, cigarette visibility, combat cleanup and female body
coverage remain under validation. Do not treat a successful server call as proof
that every animation phase renders correctly. Phone and other gestures do not
yet have the new first-person adapter.

For full options, errors and lifecycle rules see the matching base checkout's
`wiki/rp-animations.md`, section "Animation-owned items: one server call".

A sequence controls one player's successive actions. Coordinating a handover or
another interaction between players remains the RP resource's responsibility;
this API does not implement a synchronized multi-player interaction protocol.
