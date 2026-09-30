# prediction_policy_example: enable melee, Slam and hack prediction in your gamemode

Open77 predicts a melee hit, a Slam or a hack on the attacker's screen before the
server answers. Those three predictions run in the bundled `open77_cyberware` resource and
are **off until your gamemode publishes its combat policy**. The client must know your
rules before it shows a hit early, or it would show hits your server refuses.

This resource is the complete contract, about 40 lines of client Lua:

- On start, it fires the **local** client event `open77_prediction:policy` with the rules.
- It **re-sends** them on `open77_prediction:requestPolicy`, whenever the prediction code restarts.
- On stop, it sends `{ enabled = false }`, and the three predictions switch off again.

Nothing goes over the network and no permission is needed.

## The fields

| Field | Meaning |
|---|---|
| `owner` | Your resource name. If that resource stops, the policy is dropped automatically |
| `enabled` | `true` when PvP is on. `false` or a missing policy means no melee/Slam/hack prediction |
| `bucket` | The routing bucket these rules cover. Players in other buckets are not predicted |
| `safeZoneRadius`, `safeZones` | No prediction when the attacker or the victim is inside one of these spheres |
| `damageMultiplier`, `meleeMultiplier`, `explosionMultiplier`, `headshotMultiplier` | Your damage scales. A contact that might be lethal after them is not predicted: a death is always the server's call |

**Keep these values equal to what your server enforces.** They only decide whether to
*show* a hit early. The server still decides every hit.

## Use it

Copy `client/main.lua` into your gamemode's client scripts, and set the values from your
own config. Freeroam ships exactly this code, filled from its combat settings.

Car, door and blast predictions need none of this: they are built into the client.
The operator switches and telemetry come from the bundled
[`open77_prediction`](../open77_prediction) resource.

Guide: https://open2077.net/docs/prediction
