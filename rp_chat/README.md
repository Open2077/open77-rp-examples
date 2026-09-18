# rp_chat — roleplay chat commands

**Server-only** resource for Open77 (build `2.31.13+op77.76`). It adds the classic chat
commands of an RP server: the server decides the audience (proximity), reads names, jobs
and balances, and pushes the lines through `Open77.chat`.

## Commands

| Command | Effect | Audience |
|---|---|---|
| `/me <action>` | `* <Name> <action>` in purple | every player within **30 m** (you included) |
| `/do <description>` | `** <description> ((<Name>))` in light purple | 30 m |
| `/ooc <text>` | `(( OOC ) <Name>: <text>` in grey | **the whole server** |
| `/w <playerId> <text>` | whisper: the target sees `(whisper) <Name>: <text>`, you see `(whisper to <Target>) <Name>: <text>`, in dark grey | you and the target, who must be within **10 m** |
| `/dice [sides]` | `<Name> rolls a die (6): 4` in gold; 6 sides by default, 2 to 1000 | 30 m |
| `/showid [playerId]` | ID card: name, job, and **your balance only on your own card** | you only; the target must be within **5 m** |

The `playerId`s are session ids (`/id` in chat). The name comes from
`Open77.players.name`. Any command run from the server console is politely refused
(log only): they need a character in the world.

Every refusal is explained to the player in English: player not found, too far
(distance shown), position unknown, empty or too long message (512 bytes), invalid number
of sides, etc.

## Data sources

- **Proximity audience**: `Open77.players.nearby(player, radius, { includeSelf = true })`
  (documented by the MCP, available since op77.67). It honours the player's routing bucket.
  If the player's position is unknown (not in the world yet), the message is not sent and
  the player is told — there is no fallback to "everyone", which would be a false
  positive in RP.
- **Distance** (`/w`, `/showid`): `Open77.players.distance(a, b)`, in 3D.
- **Job**: `exports.rp_jobs:getJob(playerId)`; `unemployed` when the export is missing,
  fails or returns `nil`.
- **Balance**: `exports.rp_economy:getBalance(playerId)`; `unavailable` when the export is
  missing or fails. Synchronous exports raise on failure: every call is wrapped in
  `pcall`, nothing crashes.
- **ID card**: sent as a **notification** (`Open77.notifications.send`) when the native
  exists **and** the `open77_notifications` resource is `running`
  (`Open77.resource.state`); otherwise, or when sending fails, as chat lines (one per
  tick to keep the order). The manifest does not declare `open77_notifications` as a hard
  dependency: without the package, the chat commands stay available and the card shows
  up in chat.

## Manifest

- `permissions { "network.events" }`: required by `RegisterNetEvent("chat:ready")` and
  `Open77.notifications.send`.
- `dependency "rp_jobs"`, `dependency "rp_economy"`: the two resources whose exports are
  called (start order; a missing export is still handled).
- No persistence: this resource stores nothing, the KVP is not needed.

## Test it in two minutes

1. Drop `rp_chat/` in the resource root, with `rp_jobs` and `rp_economy`.
   Start the server; the log shows
   `[rp_chat] started: /me /do /ooc /w /dice /showid (notifications: toast|chat fallback)`.
2. Connect with **two clients** (A and B), note their `/id`.
3. A and B side by side: `/me looks around` → both see
   `* A looks around`. `/do It is raining.` → `** It is raining. ((A))`.
4. B walks more than 30 m away: `/me coughs` from A no longer reaches B (A still sees it).
5. `/ooc hi` → the whole server sees `(( OOC ) A: hi` in grey.
6. Within 10 m: `/w <idB> psst` → B sees `(whisper) A: psst`, A sees
   `(whisper to B) A: psst`. Beyond 10 m: `Too far: B is 14 m away (10 m max).`
7. `/dice` → `A rolls a die (6): n`; `/dice 20` → `(20)`; `/dice 1` → refused.
8. `/showid` → card with name, job and balance. `/showid <idB>` within 5 m → B's card
   **without** balance; beyond 5 m → refused with the distance.
9. From the server console, `me test` → nothing in chat, a refusal line in the log.
10. Open the chat and type `/`: the six commands show up in the completion.
