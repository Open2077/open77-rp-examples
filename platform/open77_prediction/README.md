# open77_prediction: the prediction operator layer (reference copy)

> **This is a platform resource, published here for reading only.** Every Open77 server
> already ships and auto-starts `open77_prediction`. **Do not copy it into your server's
> resources.** The bundled one is the one that runs. This folder mirrors its source so you
> can see exactly what it does.

Full guide: https://open2077.net/docs/prediction

## What "prediction" means in Open77

When you act on something another player's game simulates (their car, an NPC their client
runs, the player themselves), the server has to confirm the result. Waiting for that round
trip feels laggy. Open77 therefore **shows the result on your screen at once**: the struck
car moves, the hit player falls, the door opens. When the server's answer arrives:

- if the server confirms, the real reaction takes over (**adopted**) with no visible seam;
- if the server refuses, the local effect is **refuted**: it blends back smoothly, never snaps.

Predictions are presentation only. They never change who owns what, never send anything
the server would trust, and never decide damage or death.

## What is built in, and what this resource adds

| Part | Where it lives | Needs a resource? |
|---|---|---|
| Car↔car, car↔player and car↔NPC contact, door and blast predictions | Built into the Open77 client (native code) | **No.** Always on, with compiled defaults: every family enabled, no new prediction above 250 ms round trip |
| Melee, Slam and hack predictions | The bundled `open77_cyberware` system resource | **No extra resource**, but your **gamemode must publish its combat policy** (see [`prediction_policy_example`](../prediction_policy_example)). Without it these three stay off (fail closed), because the client must never predict a hit your server will refuse |
| **Operator switches, ping ceiling, telemetry, admin command, gamemode restrictions** | **This resource, `open77_prediction`** | This is the only thing it adds |

So `open77_prediction` is **not** what makes prediction work. It is the control panel on top:

- **Seven switches** (`melee`, `slam`, `hack`, `door`, `blast`, `carContact`, `playerContact`)
  and a **round-trip ceiling** above which a client starts no new prediction. They are server
  tunables: Warden shows them as a form, and `tunable.set open77_prediction <key> <value>`
  sets one from the console. Both persist.
- It **publishes the effective policy** in the global state bag under `open77.prediction`.
  Every client, late joiners included, applies it at once.
- A gamemode can **only narrow** the policy while it runs:
  `exports.open77_prediction:restrict({ families = { blast = false }, maxPingMs = 150 })`,
  withdrawn by `clearRestriction()` or when the gamemode stops.
- **Telemetry**: each client reports its non-zero counters (predicted, adopted, refuted,
  skipped) once a minute. The server logs one aggregated line per window and names clients
  with a high refutation rate.
- **Admin command** (ACL `command.prediction`):
  `prediction [status] | on <family> | off <family> | ping <ms> | telemetry <seconds>`.

**Without this resource** (for example, a `resources.load` allowlist that does not list it),
clients keep their compiled defaults and prediction still works. You only lose the
switches, the admin command and the telemetry. If your server uses a `resources.load` list,
add `open77_prediction` to keep them.

## Files

| File | Role |
|---|---|
| `open77.lua` | Manifest: permissions (`state.write`, `network.events`, `network.client`, `prediction.policy`) |
| `shared/policy.lua` | The policy shape, families and bounds shared by server and client |
| `server/main.lua` | Tunables, restrictions, state-bag publication, telemetry aggregation, the `prediction` command |
| `client/main.lua` | Reads the state bag, hands it to `Open77.prediction.setPolicy`, reports counters |

MIT, like the rest of this repository. The copy follows the platform build it was taken
from. If it differs from what your server runs, the bundled resource is the reference.
