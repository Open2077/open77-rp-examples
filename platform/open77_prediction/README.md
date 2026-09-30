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

## Do I need it? No. It is optional.

**Prediction works without this resource.** Here is why:

1. **The predictions themselves are in the game client, not in a resource.** Deciding to
   show a hit early, playing it, then adopting or rolling it back is native Open77 client
   code. It runs whether or not any resource is loaded.
2. **The client ships safe defaults.** With no `open77_prediction`, every prediction family
   is on, and a client stops starting new predictions above 250 ms of round trip, where
   they would be wrong too often. That is the right setting for almost every server.
3. **The server still decides everything.** A prediction is only a local preview. Hits,
   damage, pushes and deaths are always decided by the server, so no resource is needed for
   the game to stay correct and fair.

**What you lose without it:** only control and visibility. You cannot switch a family off,
change the ping ceiling, let a gamemode restrict predictions, or read the telemetry.

**When to keep it:** if you want to turn a prediction off (for example `blast` in a
gamemode where it feels wrong), tune the ping ceiling for your players, or watch how often
predictions get refuted. It is loaded by default. It only goes missing when your server uses
a `resources.load` allowlist that does not list it.

## What it adds: the control panel

`open77_prediction` is **not** what makes prediction work. It is the control panel on top:

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

If your server uses a `resources.load` list, add `open77_prediction` to keep these controls.

## Files

| File | Role |
|---|---|
| `open77.lua` | Manifest: permissions (`state.write`, `network.events`, `network.client`, `prediction.policy`) |
| `shared/policy.lua` | The policy shape, families and bounds shared by server and client |
| `server/main.lua` | Tunables, restrictions, state-bag publication, telemetry aggregation, the `prediction` command |
| `client/main.lua` | Reads the state bag, hands it to `Open77.prediction.setPolicy`, reports counters |

MIT, like the rest of this repository. The copy follows the platform build it was taken
from. If it differs from what your server runs, the bundled resource is the reference.
