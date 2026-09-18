# rp_medic — medical service (server-only)

> The verbs are `/soin` and `/reanimer`: `/heal` already belongs to the admin menu (`open77_admin`) and `/revive` to freeroam, and a command name registered twice is served by the first resource.

Open77 Lua resource (build `2.31.13+op77.76`) that gives players whose job is
`medecin` the means to heal and revive, and everyone an emergency call.
Everything is decided server-side: no client script.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/soin <playerId>` | medic | Fully heals a **living** patient within 5 m (`Open77.stats.restoreHealth`). The patient pays **100 €$** to the medic; if they cannot pay, the heal happens anyway and is announced as free. |
| `/reanimer <playerId>` | medic | Revives a **dead** patient within 5 m, where they fell, at full health with 5 s of invulnerability (`Open77.players.revive`). **300 €$**, same payment rules. |
| `/911 <message>` | everyone | Sends the message and the caller's rounded position to every connected medic and cop. The caller learns how many responders were notified. |
| `/medic` | everyone | Lists the connected medics, nearest first, with their distance. A medic also sees their counters (heals, revives, €$ earned). |

Rules shared by `/soin` and `/reanimer`:

- a single **30 s cooldown** per medic, shared between the two commands;
- no intervention on yourself, on a player not yet in the world, or beyond 5 m;
- `/soin` on a dead player points to `/reanimer`, `/reanimer` on a living one points to `/soin`;
- `/soin` on a patient already at full health charges nothing;
- from the server console (`source = 0`) all four commands politely refuse.

A player's id is obtained with `/id` (built-in chat command).

## Job, ACL and money

- The job comes from `rp_jobs`: `exports.rp_jobs:hasJob(id, "medecin")` for `/soin` and
  `/reanimer`, `exports.rp_jobs:getJob(id)` to build the list of medics and cops.
- **ACL fallback**: if the `rp_jobs` export is missing (resource stopped, reloading,
  export not published), the resource applies the semantics of a restricted command: only a
  player holding the ACL right `command.soin` may heal, `command.reanimer` revive
  (`Open77.acl.isAllowed`). In that mode, `/medic` and `/911` treat as a medic
  whoever holds `command.soin`, and the police cannot be reached (no right designates
  it) — the `/911` message says so.
- Money comes from `rp_economy`: `remove` on the patient then `add` on the medic. If
  `remove` answers `nil` (`insufficient_funds` or other), the act is free; if `add` fails
  after a successful `remove`, the patient is refunded. Without `rp_economy`, the act is free and
  announced as such.
- Both resources are declared in `dependencies`: the server refuses to start
  `rp_medic` if they are not in its `load` list (see the *server-resources* guide). The
  fallback above covers a missing export or a dependency stopped at run time, not a
  dependency never loaded.

## Persistence

Per-medic counters (`heal:<id>`, `revive:<id>`, `earned:<id>`) are stored with
`Open77.kvp.increment`, key = durable identifier `Open77.players.identifier`, never the session
id. An identifier that cannot be found (player gone) simply skips the write.

## Manifest permissions

`players.stats.read` (health read), `players.stats.apply` (`restoreHealth`),
`players.life.read` (`isDead`), `players.life.revive` (`revive`), `network.events`
(`RegisterNetEvent("chat:ready")` for the suggestions), `acl.read` (`acl.isAllowed`).

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``MEDIC_STAGE` at the top of `server/main.lua` (this resource has no shared config)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/soin` | `examine` kneel over the patient, looped (`medical`) | `medical.device` in the right hand (`medical.injector` once it exists) | 5 s bar |
| `/reanimer` | same kneel, looped | same injector | 8 s bar |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_medic] player 3 stage heal: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=medical.device@RightHand place=none 5000 ms -> ok
[rp_medic] player 3 stage revive: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=medical.device@RightHand place=none 8000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Test it in 2 minutes

1. Load `rp_economy`, `rp_jobs` and `rp_medic` in `server.jsonc` (`resources.load`) and
   start the server. The log shows `[rp_medic] started: fees heal=100 revive=300 ...`.
2. Connect two clients A and B. Give A the job through `rp_jobs` (for instance `/job medecin`
   with that resource) and B some money through `rp_economy` (`/givemoney`). Note the ids with `/id`.
3. B types `/911 I got shot`: A receives the "911" alert with the rounded position, B reads
   "Call relayed to 1 responder(s)".
4. B types `/medic`: the list shows A and their distance.
5. A stands within 5 m of B, B loses health, A types `/soin <idB>`: B is at full
   health, B has 100 €$ less, A 100 €$ more, log `[rp_medic] player A healed player B fee=100`.
   Type it again right away: "Wait another N s". From more than 5 m: "Too far: x m".
6. Kill B (test `/kill`, a fall…), A types `/reanimer <idB>` after 30 s: B gets up on the spot,
   300 €$ transferred, log `... revived ... fee=300`. Empty B's account and do it again:
   the act goes through and is announced as free.
7. B (not a medic) types `/soin <idA>`: "Medics only.". Stop `rp_jobs` and type it again:
   the message cites the right `command.soin` (ACL mode).
