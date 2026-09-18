# rp_shop — server-side shop

**Server-only** resource: a shop for an RP server. Money always goes through the
`rp_economy` exports, never through this resource.

## Commands

| Command | Effect |
|---|---|
| `/shop` | Shows the catalogue (one line per item, grouped by family) and your balance. |
| `/buy <item>` | Charges the price through `rp_economy`, then delivers the item. Insufficient funds or money system offline: nothing is delivered. If the delivery fails (native refused), you are refunded and the reason is shown. |
| `/sell <item>` | Only for vehicles bought here: removes your last vehicle of that model still on the road and refunds 50% of the price. Without an argument: your last vehicle bought here, whatever the model. |

A dead player can neither buy nor sell. The server console is refused
(`/shop` from the console only prints the catalogue to the log).

## Catalogue

| Item | Family | Price | Delivery |
|---|---|---|---|
| `soin` | consumable | 50 $ | full health (`Open77.stats.restore` health) |
| `stim` | consumable | 30 $ | full stamina (`Open77.stats.restore` stamina) |
| `armure` | consumable | 150 $ | armor 100 (`Open77.players.setArmor`) |
| `pistolet` | weapon | 400 $ | `Items.Preset_Lexington_Default`, slot 1 |
| `fusil` | weapon | 1,200 $ | `Items.Preset_Carnage_Default`, slot 2 |
| `katana` | weapon | 900 $ | `Items.Preset_Katana_Default`, slot 3 |
| `hella` | vehicle | 15,000 $ | `Vehicle.v_standard2_archer_hella_player`, 3.5 m to your right, same heading |
| `quadra` | vehicle | 60,000 $ | `Vehicle.v_sport1_quadra_turbo_r_player`, same |

Weapons are delivered by the `open77_weapons` client relay: the command
answers "delivery in progress", then "Delivered" (or a refund) once the client
has confirmed. Vehicles are created `persistent = true`: only `/sell` (or an
admin) removes them.

## Persistence

Vehicles bought here are remembered in the resource's KVP store under the key
`garage:<durable identifier>` (JSON), so `/sell` survives a resource reload.
An entry whose vehicle no longer exists (or whose id was recycled for another
model) is ignored and then purged.

## Dependencies and permissions

- `dependency "rp_economy"` — exports `getBalance`, `add`, `remove`.
- `dependency "open77_weapons >=0.1.0"` — weapon relay.
- `network.events` (weapons, `chat:ready`), `world.vehicles`, `players.stats.apply`,
  `players.life.read`.

If `rp_economy` is not loaded, the shop stays usable read-only
(`/shop`) and refuses purchases with a clear message.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``SHOP_STAGE` at the top of `server/main.lua` (this legacy resource has no shared config)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/buy soin|stim|armure` | `give` one-shot (`carry_pickup`) | `crate.cardboard` in the right hand | 2.5 s |
| `/buy pistolet|fusil|katana` | same | `military.case` in the right hand | 2.5 s |
| `/buy hella|quadra` | `phone` one-shot: the keys over the holo (`phonecheck`) | the profile's holo | 3 s |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_shop] player 3 gesture purchase: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=crate.cardboard@RightHand 2500 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Test it in 2 minutes

1. Start the server with `rp_economy`, `open77_weapons` and `rp_shop`; connect
   and be alive.
2. `/shop` — the catalogue shows up in three families, then your balance.
3. `/buy soin` — the server log shows `[rp_shop] player <id> bought soin for 50`
   and health is full. Without money: "Insufficient funds".
4. `/buy katana` — "delivery in progress…" then "Delivered: Katana (slot 3)".
5. `/buy hella` — an Archer Hella appears to your right, facing the same way as you.
6. `/sell hella` — the car disappears, 7,500 $ are credited back.
7. `/sell hella` again — "You have no Archer Hella (sedan) bought here still on
   the road."
