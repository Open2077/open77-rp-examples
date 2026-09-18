# rp_gangs — territories and criminal life

Gangs for a Night City RP server on Open77 (build `2.31.13+op77.76`): seven gangs, a
membership with three ranks, **influence** per territory (the gang with the most points holds
the zone and its members collect a **tribute**), a street **buyer NPC** per territory who pays
cash for drug packs, the **robbery** of a cuffed or surrendering player, **wars** for a
territory and a **racket** threat that pages the NCPD.

Server-authoritative: membership, influence, holders, tributes, deals, robberies and wars are
decided in `server/main.lua`. The client only draws the `[GANG]` tag over remote members,
offers the ALT+click **Rob** action and keeps the buyer prompt on the buyer NPCs; every request
is re-validated by the server (membership, distance, bucket, target state, cooldowns).

## The seven gangs

| id | label | colour | home territory |
|---|---|---|---|
| `maelstrom` | Maelstrom | red | `junkyard` |
| `tygerclaws` | Tyger Claws | pink | `kabuki_market` |
| `valentinos` | Valentinos | gold | `afterlife` |
| `sixthstreet` | 6th Street | blue | `afterlife` |
| `animals` | Animals | purple | `lizzies` |
| `voodooboys` | Voodoo Boys | green | `lizzies` |
| `scavs` | Scavs | grey | `junkyard` |

Ranks: `0` member, `1` lieutenant, `2` boss. Everything is `shared/config.lua`
(`RpGangsConfig`): gangs, territories and buyer positions, prices, cooldowns, war length.
Commands accept a gang or a territory by id, label or unambiguous prefix (`mael`, `6th`,
`black`).

## Territories

Territories are `rp_zones` zones, real Night City places (measured 2026-09-18). The freeroam
spawn is Kabuki Market Centre `-1191.30, 2006.88, 7.82`. No territory has a default holder.

| Territory | Zone centre | Buyer NPC (+ crate prop) | From spawn |
|---|---|---|---|
| `kabuki_market` — Kabuki Market | -1191.30, 2006.88, 7.82 (r 70) | Far Corner `-1149.22, 2054.84, 7.76` (walked), crate 1.3 m east | 64 m north-east, inside the market |
| `lizzies` — Lizzie's Bar | -1188.9, 1566.2, 22.9 (r 18) | inside, `-1185, 1568, 23`, crate 1.3 m east | 440 m south |
| `junkyard` — Junkyard | 1374.9, -1674.9, 49.3 (r 90) | `1370, -1670, 49.4`, crate 1.3 m north-west | 4.5 km south-east (Rancho Coronado, Badlands) |
| `afterlife` — The Afterlife | -1453, 1017, 16.5 (r 50) | **no buyer** (no street market in the Afterlife: the zone is only fought over) | 1.0 km south-west |

The crate beside each buyer is `Open77.props.create` (the curated prop alias `crate.cargo`, see
`prop.catalog`; `Config.buyerProp`), removed with the buyers on stop; a refusal only logs. If a buyer lands in
the ground, stand on the spot, `/pos`, paste the height into `Config.territories[].buyer`.

**Influence** (`rp_gangs_influence`, per zone and gang):

| Source | Points | Zone |
|---|---|---|
| a drug pack sold to the buyer (`/gang vendre` or the **E** prompt) | +1 (`dealInfluence`) | where the sale happened |
| `rp_crime` or any resource calling `addInfluence` | as given | as given |
| a gig completed by a member (`rp_fixer:gig` phase `success`) | +2 (`gigInfluence`) | the member's last territory, else the gang's home |
| a member jailed (`rp_ncpd:arrest`) | −5 (`arrestInfluence`, never below 0) | same rule |
| a war won | +10 (`warInfluence`) | the disputed zone |

The gang with **strictly** the most points holds the zone; on a tie the current holder keeps
it. A holder change is announced to everyone. Every `tributeIntervalMs` (10 min) each online
member of the holder gets `tributePerZone` (50 €$) cash **per held zone**
(`rp_economy:add`, reason `gang:tribute:<zone>`).

Note: `kabuki_market` **is** the safe zone of `rp_zones`, so nobody takes damage there — a war
over the market is decided by presence, not by kills. Lizzie's, the junkyard and the Afterlife
are not safe zones.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/gang` | anyone | Your gang, rank, members (total / online, with ranks), territories held, the running war, the hideout (the boss's `rp_housing` home when the boss is online and owns one). Without a gang: the seven gangs and their head counts. |
| `/gang creer <gang>` | jobless, gang-less | Founds the gang and makes you its **boss** — only while the gang has **no member at all** (`Config.openFounding = true`, the admin-free bootstrap; set it to false and use `/setgang` on a production server). Refused with a day job (`rp_jobs:getJob` not nil). |
| `/gang recruter <playerId>` | boss / lieutenant | Recruits a jobless, gang-less player standing **within 5 m** as a member. |
| `/gang virer <playerId>` | boss / lieutenant | Kicks a member of a lower rank. |
| `/gang promouvoir <playerId>` | boss | member → lieutenant; lieutenant → **boss** (you step down to lieutenant). |
| `/gang quitter` | member | Leaves. A boss with a crew must hand over the seat first; the last member leaving **dissolves** the gang (its influence is cleared). |
| `/gang vendre` | member | Sells **one** `drug_pack` to the buyer of the territory you stand in (within 4 m of the NPC): +80 €$ cash (`dealPrice`), +1 influence, 60 s cooldown. The **E** prompt **Street deal** on the buyer does the same. |
| `/gang depouiller <playerId>` | member | Robs a player within 3 m who is **cuffed by the RP kit** (`open77_rp_basics:state`) **or has hands up** (`handsup` RP profile): 30 % of their cash (`rp_economy:remove` → `add`) and every **illegal** item (`rp_inventory:list` / `remove` / `add`; what you cannot carry stays on them). Pages the NCPD (`rp_ncpd:alert("robbery", ...)`). The same victim cannot be robbed twice in 2 min. ALT+click a player > **Rob** does the same. |
| `/territoire` | anyone (console too) | Every territory with its holder, a running war and the **top-3** influence. |
| `/guerre <zone>` | boss | Declares war on a territory **another** gang holds. Refused when you hold it, when nobody holds it ("deal there and take it"), when the zone is at war or cooling down (10 min), when your gang already fights elsewhere, or when the holder has nobody online. The holder's boss is told, both crews get a toast, the NCPD is paged (`gang_war`). The war lasts `warMinutes` (5 on the eval, 20 in production): **every 30 s the gang with more members inside the zone scores 1**; at the end the higher score wins **+10 influence** (a tie changes nothing). |
| `/racket <playerId>` | member | A **chat threat**: the target (within 5 m) reads that you want 100 €$ protection money and how to pay (`/pay`), gets a toast, and the NCPD is paged (`racket`). 60 s cooldown per victim. **Deliberately not implemented**: the society-payment version (charging a `rp_shops` society member through `rp_bank` with an `open77_player_interactions` consent flow) — the plan allowed skipping it, so this is the threat + alert only, and whether the victim pays is their call. |
| `/setgang <playerId> <gang\|none> [rank 0-2]` | admin (ACL `command.setgang`) or the console | Puts a player in a gang at a rank, or removes them. The escape hatch for a boss-less gang. |

Every refusal is a chat line from `GANG`: no gang, not the boss, too far (with the distance),
has a day job, already in a gang, unknown player, not cuffed nor surrendering, nothing to sell,
wallet / pockets offline, zone at war, and so on. From the server console `/gang`, `/guerre`
and `/racket` answer `run it from the game`; `/territoire` and `setgang` answer in the console.

Jobs and gangs are exclusive both ways: a member who takes a job (`rp_jobs:changed` with a job
name) is cut loose (`Config.dropOnJob`); if that was the boss, the highest-ranked online member
inherits the seat.

Nothing here collides with a platform or delivered command (`gang`, `territoire`, `guerre`,
`racket`, `setgang`).

## ALT+click and the buyer prompt

- **Rob** (`open77_contextmenu`, `registerPlayers`): shown to gang members only (the server
  tells each client its own membership), 3 m; the server re-measures the distance and checks
  the target's hold/hands-up state before touching anything.
- **Street deal** (`open77_interactions`): a server-declared `globalNpc` target with the
  client predicate `rpGangsIsBuyer`, so the card appears on this resource's buyer NPCs only
  (the server pushes their ids to every client). The press comes back as `onNpcInteracted`,
  measured by the server; `Config.buyer.reach` (4 m) is applied on that number.
- **Tag**: while `Config.showTag`, every other client draws a member's nameplate as
  `[MAELSTROM] Vince Rocker` in the gang colour (`Open77.nameplates.set`, 40 m). The nameplate
  API only overrides remote players, so you never see your own tag.

## Exports (server, synchronous — never yield; call inside `pcall`)

```lua
exports.rp_gangs:gangOf(playerId)                        -- "maelstrom" | nil
exports.rp_gangs:isBoss(playerId)                        -- boolean
exports.rp_gangs:rankOf(playerId)                        -- { level = 1, label = "lieutenant" } | nil   (extra)
exports.rp_gangs:influence("kabuki_market")              -- { maelstrom = 12, scavs = 3 } | nil, "unknown_zone"
exports.rp_gangs:holderOf("kabuki_market")               -- "maelstrom" | nil                          (extra)
exports.rp_gangs:addInfluence("kabuki_market", "maelstrom", 1, "deal")  -- newPoints | nil, reason
```

`addInfluence` reasons: `unknown_zone` (not a territory), `unknown_gang`, `invalid_points`
(not a non-zero integer). Negative points floor at 0. When `reason` is omitted the invoking
resource's name is logged. A resource **with** a client script must not declare
`dependency "rp_gangs"` (this manifest is delivered to clients).

## Events (host bus)

```lua
AddEventHandler("rp_gangs:changed", function(playerId, gang) end)      -- gang is nil when the player left
AddEventHandler("rp_gangs:war", function(zone, attacker, defender, phase, detail) end)
-- phase: "start" | "tick" | "end"
-- detail (tick): { attackerScore, defenderScore, attackerInside, defenderInside, secondsLeft }
-- detail (end):  { attackerScore, defenderScore, winner | nil, reason = "time" | "resource_stopping" }
```

Raised **to** other resources: `rp_ncpd:alert (kind, position, text, byPlayerId)` with kinds
`robbery`, `gang_war`, `racket`. Consumed: `rp_zones:entered`, `rp_ncpd:arrest`,
`rp_fixer:gig`, `rp_jobs:changed`, `onNpcInteracted`.

Internal net events (`rp_gangs:clientReady`, `rp_gangs:self`, `rp_gangs:roster`,
`rp_gangs:buyers`, `rp_gangs:rob`) are this resource's transport, not an API.

## Items

`drug_pack` (Drug pack, 0.2 kg, **illegal**, not usable) is declared in `rp_inventory` through
`exports.rp_inventory:define` from this resource's `onResourceStart` and again whenever
`rp_inventory` restarts. `synthcoke` and `implant_box_*` are `rp_inventory` / `rp_ripperdoc`
items and count as contraband in a robbery because `rp_inventory` flags them `illegal`.

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`, rows keyed by `Open77.players.identifier` (never the session id):

```sql
rp_gangs_members (
    identifier VARCHAR(64) PRIMARY KEY,
    gang       VARCHAR(32) NOT NULL,
    `rank`     TINYINT     NOT NULL DEFAULT 0,   -- 0 member, 1 lieutenant, 2 boss
    joined_at  BIGINT      NOT NULL DEFAULT 0,   -- unix seconds
    INDEX (gang)
)
rp_gangs_influence (
    zone   VARCHAR(32) NOT NULL,
    gang   VARCHAR(32) NOT NULL,
    points INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (zone, gang)
)
```

A member's row is read on `onPlayerReady` (`.await`, in the handler) and for everyone
connected on a hot start; the influence table and the per-gang head counts are read once at
boot. Every change is written through with the callback forms, so the exports never touch the
database. A failed SQL read is never treated as "no gang": the player is told to reconnect.

**No database** (`ready` answers `database_unavailable`, or nothing answers within 15 s):
`Open77.kvp` (`member:<identifier>` = `gang|rank`, `count:<gang>`, `inf:<zone>:<gang>`), and
the log says `[rp_gangs] store=kvp reason=...`.

Wars, cooldowns and the buyer NPCs are in memory only: a resource stop ends every war
(`reason = "resource_stopping"`, the score decides) and removes the buyers.

## Log (grep-able)

```text
[rp_gangs] started: 7 gangs, 4 territories, tribute 50 eddies per zone every 10 min, war 5 min, deal 80 eddies
[rp_gangs] items registered in rp_inventory: 1 (rejected: 0)
[rp_gangs] store=sql tables=rp_gangs_members,rp_gangs_influence
[rp_gangs] territories: kabuki_market=none lizzies=none junkyard=none afterlife=none
[rp_gangs] buyer spawned zone=kabuki_market npc=... at -1149.2 2054.8 7.8
[rp_gangs] buyer prompt declared (Street deal)
[rp_gangs] player 1 gang=maelstrom rank=2 (founded)
[rp_gangs] deal player=1 zone=kabuki_market gang=maelstrom +80 cash=580 via=command
[rp_gangs] influence kabuki_market maelstrom +1 -> 1 (deal by player 1)
[rp_gangs] zone kabuki_market holder=maelstrom (was nil)
[rp_gangs] tribute player=1 gang=maelstrom zone=kabuki_market +50 cash=630
[rp_gangs] robbery robber=1 victim=2 cash=150 items=1
[rp_gangs] war start zone=junkyard attacker=maelstrom defender=scavs by=1 minutes=5
[rp_gangs] war end zone=junkyard attacker=maelstrom defender=scavs score=6-4 winner=maelstrom (time)
```

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``Config.Stage` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| `/gang vendre`, E on the buyer | `give` looped (`carry_putdown`) | `crate.ammo_box` pack in the right hand (`crime.drug_pack` once it exists) | 3 s bar, then the pack moves |
| ALT+click Rob | `examine` over the held victim, looped (`frisk`) | none | 4 s bar; the victim must still be held at the end |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_gangs] player 3 stage deal: pose=give/stand__2h_on_sides__01__to__stand__rh_item__01__turn0__01 prop=crate.ammo_box@RightHand place=none 3000 ms -> ok
[rp_gangs] player 3 stage rob: pose=examine/kneel__rk_on_ground__01__inspect_ground__01 prop=none place=none 4000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.
There is no `/tag` action in this resource (the `[GANG]` tag is the nameplate): nothing to stage there.

## Manifest

Permissions: `network.events`, `database.access`, `world.npcs`, `world.props` (the crate beside
each buyer), `players.animations.read` (the hands-up read; the devkit card lists no permission
check for `Open77.animations.current`, the guide says it needs this one — declared to be safe),
`ui.nameplates` (client).
Dependencies: `open77_contextmenu`, `open77_interactions`, `open77_notifications` (all three
ship a client half). `rp_zones`, `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_ncpd`,
`rp_housing`, `rp_identity`, `rp_fixer` and `open77_rp_basics` are server-only and reached
through `pcall`: each degrades to a chat line or a log line when missing.

## Test in 2 minutes (one player)

At the freeroam spawn, Kabuki Market Centre `-1191.30, 2006.88, 7.82`, id `1`, jobless;
`rp_zones`, `rp_inventory`, `rp_economy` running (`rp_jobs`, `rp_identity`, `rp_ncpd`,
`rp_fixer`, `open77_rp_basics` optional). Log on start: `started: 7 gangs, 4 territories ...`,
`store=sql ...`, three `buyer spawned` lines (the Afterlife has no buyer) and `buyer prompt
declared`.

1. `/gang` → `You run with nobody. /gang creer <gang> to found one...` and the seven gangs
   with `0` members.
2. `/gang creer maelstrom` → `You founded the Maelstrom. You are the boss...`, a toast, and
   everyone reads `Word on the street: <name> now runs the Maelstrom.` `/gang creer scavs` now
   answers `You already run with the Maelstrom.`
3. `/gang` → `Maelstrom - boss. 1 member(s), 1 online: <name> [boss]` then `Territories held:
   none. Tribute 50 €$ per zone every 10 min.`
4. `/territoire` → four lines, every one `held by nobody ... no influence yet`.
5. Console: `giveitem 1 drug_pack 2` → `Drug pack x2` in the pockets (`/inv`, flagged illegal).
6. Walk 64 m north-east across the market to Far Corner (-1149, 2055): a Maelstrom-looking
   NPC stands there beside a cargo crate with a **Street deal** marker. Look at him within
   2.5 m and press **E** (or type `/gang vendre` within 4 m) → `Deal done in Kabuki Market:
   +80 €$ cash (...). Maelstrom influence +1.`, a toast, and everyone reads `Maelstrom now
   runs Kabuki Market.` Press **E** again → `The buyer is counting eddies. Come back in 59 s.`
   Wait a minute, sell the second pack → influence 2. A third press → `Nothing to sell. Bring
   a drug pack.`
7. `/territoire` → `Kabuki Market (kabuki_market): held by Maelstrom. Top: Maelstrom 2`.
   `/gang` → `Territories held: Kabuki Market.`
8. `/guerre kabuki_market` → `You already hold Kabuki Market. Nothing to take.`
   `/guerre junkyard` → `Nobody holds Junkyard: deal there and take it with influence.`
9. Drive 1.0 km south-west into the Afterlife (-1453, 1017) and `/gang vendre` → `No buyer
   around here right now.` (no street market there); walk out of every territory →
   `No street market here. Find a territory (/territoire).`
10. Wait for the tribute tick (10 min, or lower `tributeIntervalMs` in `shared/config.lua`)
    → `Tribute from Kabuki Market: +50 €$ (cash ...)`, log `tribute player=1 ...`.
11. Reconnect → `Welcome back to the Maelstrom, boss.`; `/territoire` still shows the two
    points (SQL).

**Two players** (ids `1` boss, `2` citizen): `/gang recruter 2` from 10 m → `Too far away
(10 m)...`; within 5 m → both told, player 2 sees `[MAELSTROM] <name>` over player 1 and vice
versa. Console `setjob 2 ncpd 0` → player 2 reads `You took a day job (ncpd): the Maelstrom
cut you loose.` For a robbery: player 2 raises hands (`handsup` RP profile) or is cuffed by an
officer with the kit; console `giveitem 2 synthcoke 2`; player 1 holds **ALT**, clicks player
2, **Rob** (or `/gang depouiller 2`) → `You robbed <name>: 150 €$, Synthcoke x2.`, the victim
is told, on-duty officers read `[NCPD DISPATCH] ROBBERY: ...`. Without hands up → `They are
neither cuffed nor surrendering.` For a war: console `setgang 2 scavs 2`, player 2 sells a
pack at the junkyard (Scavs hold it; 4.5 km south-east, the buyer at 1370, -1670), player 1
`/guerre junkyard` → both crews are told, every 30 s the score line, after 5 min `WAR OVER:
the Maelstrom take Junkyard (10 - 0). +10 influence.` when only player 1 stood in the zone.
