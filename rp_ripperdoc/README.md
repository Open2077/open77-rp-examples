# rp_ripperdoc — the ripperdoc clinic

Server-authoritative ripperdoc for a Night City RP server on Open77 (build `2.31.13+op77.76`).
The on-duty **ripper** (`rp_jobs` job `ripper`) installs and removes implants on a **patient lying
on the clinic chair**, through the platform's cyberware framework (`open77_cyberware`): the server
owns the catalogue, the quote, the fee, the boxed stock, the durable implant record and the log.

The catalogue is exactly the five implant slots the cyberware guide documents on this build —
`arms/gorilla_arms`, `legs/double_jump`, `operating_system/cyberdeck`, `self_ice/self_ice`,
`purge/active_purge` — with grades defined by this resource (`shared/config.lua`). Nothing is
guessed: the three hacking implants are registered through `Open77.hacking.define/defineIce/
definePurge` plus `Open77.cyberware.define`, exactly as the hacking guide prescribes.

## What the player sees

1. **The chair.** A purple ring, a map pin and an `E` prompt **Vik's chair** (`open77_worldui`,
   `promptDistance = 4.0`, ring radius 4) at `-1548.0, 1230.0, 11.6` — **Viktor Vektor's real
   chair room**, under the Misty's Esoterica alley in Little China (Watson), inside the `rp_zones`
   **`viktor_clinic`** zone (centre `-1548, 1230, 11.5`, radius 12). Press **E**: the server checks
   you stand within 4.5 m and plays the RP `lie` posture on you **at the chair**
   (`Open77.animations.playAt(player, "lie", position, yaw)`, permission
   `players.animations.control` — the server native that places a posture at a pose; its portable
   `lie` workspot is the invisible bed under you). You are now "on the chair". Press **E** again
   (or walk more than 0.5 m) to get up. The clinic already has its chair, so no prop is spawned.
   The owner moves the chair and the zone by editing `RpRipperConfig.chair` / `clinicZone`.
2. **The ripper operates.** On duty (`/service`), within 4 m, inside the clinic zone: hold **ALT**,
   click the patient, pick **Operate** (`open77_contextmenu`) — or type `/operer <playerId>`. A UI-kit
   **context menu** lists the catalogue: one row per grade with **price**, **grade**, **stock** (a
   boxed implant in the ripper's pockets first, else the patient's own) and **duration**; a slot that
   is already filled shows **Remove …** at half price instead. Rows without a box, or whose provider
   is offline, are greyed out with the reason.
3. **The quote.** The patient reads the quote in chat and as a toast — implant, grade, price,
   duration, cyberpsychosis risk — and consents through **`open77_player_interactions`**
   (`Open77.playerInteractions.request(ripper, patient, "custom", …)` with `consent = true`,
   30 s to answer): the platform's own invitation prompt, or `/interaction accept` /
   `/interaction decline`. Declining, letting it expire, walking away, dying, a vehicle or a
   disconnect cancels the whole thing; both players are told why.
4. **Under the knife.** On acceptance the interaction plays `examine` on the ripper and `lie` on the
   patient, and a UI-kit **progress bar** runs on **both** screens for the configured duration
   (10–25 s per implant, `grades[].durationMs`). **X** on either side aborts: nothing is charged.
5. **The chrome.** When the bar completes the server re-checks duty, the record, the box and the
   money, takes the box (`rp_inventory:remove`), charges the fee — `rp_bank:charge(patient, price,
   "ripper", "implant:<key>")`, cash fallback through `rp_economy:remove` + `rp_bank:societyAdd` —
   then stages `Open77.cyberware.install` / `.remove` with a fresh `newOperationId` and the record's
   `expectedRevision`. The result arrives on `onCyberwareOperationCompleted`: on `ok` the row is
   logged and both players are told; on failure the box and the eddies come back (the refund lands
   in **cash**: `rp_bank` has no society-to-account move). **100 % of the fee goes to the `ripper`
   society**; the ripper is paid by the `rp_jobs` payroll.
6. **Cyberpsychosis.** After an install, when the patient carries **more than**
   `cyberpsychosisThreshold` implants (4 on the shipped config, so the fifth implant), the server plays
   the `drugged` full-screen overlay on that patient for 60 s — `Open77.effects.screen(patient,
   "drugged", { strength = 0.5, duration = 60 })`, the server-targeted, non-replicated screen effect
   of the effects guide, permission `players.screenfx` — plus a red toast and a chat warning. Set
   the threshold to `0` to see it on the very first implant.

Every refusal is explained in chat, in English: not a ripper, off duty, patient not on the chair,
too far (with the distance), outside the clinic, no box, patient cannot afford it, record not
ready, provider offline, and every platform reason (`animation_busy`, `player_reserved`, …).

## Where it is

| What | Position | Notes |
|---|---|---|
| Vik's chair (ring + pin + E prompt) | `-1548.0, 1230.0, 11.6`, yaw -89.5 | `RpRipperConfig.chair`; AMM point +0.1 m |
| Clinic entrance (inside) | `-1545.0, 1233.0, 11.6` | where rp_bank's ATM stands |
| `viktor_clinic` zone (rp_zones) | centre `-1548, 1230, 11.5`, r 12 | the ripper must stand inside it to operate |

From the Kabuki Market spawn (`-1191.3, 2006.9, 7.8`) the clinic is about **860 m south-west**
as the crow flies: down through Little China, into the alley by Misty's, down the stairs.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/ripper` | ripper (any grade) | The clinic board: your grade and duty, **patients on the chair** (name, id, distance), the **boxes in your pockets**, the catalogue with retail prices (or `OFFLINE <reason>`), the society balance, and **today's log** (last 24 h: count + the last 5 operations). |
| `/ripper restock <arms\|legs\|deck\|ice\|purge> [count]` | ripper | Buys 1–5 boxed implants at 60 % of the retail price, paid by the `ripper` society (`rp_bank:societyRemove`), else from your cash; the boxes land in your pockets. Refunded if they do not fit. |
| `/ripper` | anyone else | Your installed implants (see `/implants`) and **who is on duty** — or `Rippers on duty: none. Nobody can give you a quote right now`. |
| `/operer <playerId>` | ripper on duty | Operates on the patient lying on the chair: same flow as ALT+click > **Operate**. |
| `/implants` | anyone | Your implants **as the platform reports them** (`Open77.cyberware.current`): one line per slot (`arms`, `legs`, `operating_system`, `self_ice`, `purge`), the count and the cyberpsychosis threshold. |

From the server console all three answer `run it from the game`. Player ids are the session ids
(`/players`). Names come from `rp_identity` (`fullName`) when it runs, else from the account.

## Exports (server, synchronous, never yield)

```lua
exports.rp_ripperdoc:isOnChair(playerId)      -- boolean
exports.rp_ripperdoc:implantCount(playerId)   -- integer | nil, reason (record not ready)
exports.rp_ripperdoc:catalogue()              -- { { key, label, slot, profile, definitionId, box,
                                              --     available, reason, grades = { { id, label, price, durationMs } } }, ... }
```

Call them inside `pcall`. A resource with a client script must not declare `dependency
"rp_ripperdoc"` (this manifest is delivered to clients).

## Events (host bus, `TriggerEvent`)

```lua
AddEventHandler("rp_ripperdoc:operation", function(ripperId, patientId, action, implantKey, gradeId, price) end)
-- raised once per completed operation; action is "install" or "remove"
```

Internal transport, not an API: net events `rp_ripperdoc:chair`, `rp_ripperdoc:operate`,
`rp_ripperdoc:clientReady` (client → server) and `rp_ripperdoc:duty` (server → client).

## Persistence

Created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`, keyed by the durable `Open77.players.identifier`:

```sql
rp_ripperdoc_operations (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    ripper       VARCHAR(64)  NOT NULL,        -- the ripper's identifier
    ripper_name  VARCHAR(64)  NOT NULL,
    patient      VARCHAR(64)  NOT NULL,        -- the patient's identifier
    patient_name VARCHAR(64)  NOT NULL,
    implant      VARCHAR(96)  NOT NULL,        -- the cyberware definition id (rp_ripperdoc.gorilla_arms, ...)
    grade        VARCHAR(32)  NOT NULL,        -- installed grade id ('' for a removal)
    action       VARCHAR(16)  NOT NULL,        -- install | remove
    price        INT          NOT NULL,
    paid_via     VARCHAR(16)  NOT NULL,        -- account | cash | free
    `at`         BIGINT       NOT NULL         -- unix seconds
)
```

Rows are written with the callback form; `/ripper` reads today's log with `.await` inside its
command handler. **No database** (`ready` answers `database_unavailable`, or nothing answers 15 s
after start): the log falls back to `Open77.kvp` (key `operations`, last 100 rows) and the log
says `[rp_ripperdoc] store=kvp reason=...`. The implant record itself is the platform's
(`open77_cyberware_v1`), never this resource's.

## Configuration (`shared/config.lua`)

| Key | Default | Meaning |
|---|---|---|
| `job` / `society` | `ripper` / `ripper` | The `rp_jobs` job that may operate; the `rp_bank` society that receives every fee. |
| `clinicZone` | `viktor_clinic` | `rp_zones` zone the ripper must stand in (`nil` = anywhere; ignored when `rp_zones` is not running). |
| `chair.position` / `yaw` | `-1548, 1230, 11.6` / `-89.5` | Vik's chair; `z` is the floor under the chair (`/pos` on the spot if the ring is invisible). |
| `chair.promptDistance` / `reach` / `radius` | `4.0` / `4.5` / `4.0` | The E prompt range; the server's own re-check; the ring covers the whole chair. |
| `operateDistance` | `4.0` | The ripper must be within this distance of the patient. |
| `quoteTimeoutMs` | `30000` | Time to accept or decline the quote. |
| `removalPriceFactor` | `0.5` | A removal costs half the install price of the installed grade. |
| `restockPriceFactor` / `restockMaxCount` | `0.6` / `5` | `/ripper restock` wholesale price and cap. |
| `cyberpsychosisThreshold` | `4` | More implants than this after an install triggers the effect. |
| `cyberpsychosis` | `drugged`, `0.5`, `60` | Screen-effect alias, tier and seconds. |
| `animations` | `lie` / `lie` / `examine` | Chair posture; surgery postures (patient / ripper). |
| `catalogue` | 5 entries, 7 grades | Per entry: slot, profile, definition id, box item, grades (`label`, `price`, `durationMs` + the platform grade fields; `hacking` block for the three hacking implants). |
| `items` | 5 boxes | `implant_box_arms`, `_legs`, `_deck`, `_ice`, `_purge`: 2.0 kg, not usable, **illegal unless the holder is a `ripper`** (`permit = "ripper"`), registered in `rp_inventory` through `exports.rp_inventory:define` on start and whenever `rp_inventory` restarts. |

Prices at the shipped config: Gorilla Arms 1 500 (Street) / 3 200 €$ (Industrial), Reinforced
Tendons 1 200 / 2 500 €$, Cyberdeck 2 000 €$, Self-ICE 1 800 €$, Active Purge 1 600 €$; a removal is
half the installed grade's price.

## Staging: poses, props and durations (2026-09-18)

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in ``RpRipperConfig.Stage` and `RpRipperConfig.animations` (`shared/config.lua`)` and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| E on the chair | `lie` at the chair (`Open77.animations.playAt`, unchanged) | -- | until E again |
| the surgery | the quote interaction plays `examine` on the ripper and `lie` on the patient (unchanged) | `medical.device` in the ripper's right hand from the first cut to the last stitch (`medical.injector` once it exists) | the grade's `durationMs` (12-22 s) |
| `/ripper restock` | `phone` one-shot: the order on the holo | the profile's holo | 3 s |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_ripperdoc] player 3 hold surgery: pose=none prop=medical.device@RightHand
[rp_ripperdoc] player 3 gesture restock: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none 3000 ms
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Manifest

Dependencies (all ship a client half): `open77_cyberware`, `open77_player_interactions`,
`open77_uikit`, `open77_worldui`, `open77_contextmenu`, `open77_notifications`. Permissions:
`network.events`, `database.access`, `players.cyberware.define/read/manage`,
`players.hacking.define`, `players.animations.control`, `players.interactions.control/read`,
`players.screenfx`. `rp_jobs`, `rp_inventory`, `rp_bank`, `rp_economy`, `rp_zones` and
`rp_identity` are reached through `pcall`'d exports and never declared (their READMEs ask a
resource with a client script not to): without `rp_jobs` nobody can operate; without
`rp_inventory` there is no stock and installs are refused; without `rp_bank` the fee comes from
cash; without both money resources the clinic works for free (logged); without `rp_zones` the
zone check is skipped.

The three hacking implants need the platform's `open77_hacking` resource: when
`Open77.hacking.define` answers `hacking_unavailable` they stay in the menu as **Provider offline**
and are re-defined when `open77_hacking` or `open77_cyberware` (re)starts.

## Log (grep-able)

```text
[rp_ripperdoc] catalogue arms defined (arms/gorilla_arms, 2 grade(s))
[rp_ripperdoc] catalogue deck NOT defined: hacking_unavailable
[rp_ripperdoc] boxed implants registered in rp_inventory: 5 registered, 0 rejected
[rp_ripperdoc] started: 5 implants in the catalogue, chair at -1548.0 1230.0 11.6 (zone viktor_clinic), threshold 4 implants
[rp_ripperdoc] store=sql table=rp_ripperdoc_operations
[rp_ripperdoc] op <id> offered: install arms, 1500 eddies, player 1 -> player 2
[rp_ripperdoc] op <id> done: install arms on player 2 by player 1, 1500 eddies via account
[rp_ripperdoc] op <id> cancelled: declined
[rp_ripperdoc] cyberpsychosis on player 2 (5 implants > 4)
[rp_ripperdoc] player 1 restocked 2 x implant_box_arms for 1800 (society)
```

## Test in 2 minutes

Two clients inside Viktor's clinic (walk from Kabuki Market, ~860 m south-west, or console
`tp <id> -1545 1233 11.6` onto the clinic entrance), ids `1` (the ripper) and `2` (the patient);
`rp_jobs`, `rp_inventory`, `rp_bank`, `rp_economy` and `rp_zones` running. On start the log shows the
`catalogue ... defined` lines (the three hacking ones say `NOT defined: hacking_unavailable` when
`open77_hacking` is not loaded — arms and legs are enough for this walkthrough).

1. **Console:** `setjob 1 ripper 3` (boss; the society is seeded with 50 000 €$ by `rp_jobs`),
   `givemoney 2 5000`. Player 1: `/service` → `Clocked in at Ripperdoc as boss.`
2. Player 1: `/ripper` → `RIPPERDOC <name> - grade boss - ON DUTY.`, `On the chair: nobody.`,
   `Boxes in your pockets: none. /ripper restock ...`, the catalogue with prices, `Society ripper:
   50 000 €$.`, `Last 24 h: 0 operation(s).`
3. Player 1: `/ripper restock arms 1` → `Restocked 1 x Implant box: Gorilla Arms for 900 €$ (paid by
   the ripper society).` (`/inv` shows the box.) `/ripper` now lists `Gorilla Arms x1`.
4. Player 2 walks to the purple ring around Vik's chair (map pin **Vik's chair**), looks at it,
   presses **E** → they lie down on the chair; chat `You lie down on the ripperdoc chair. 1
   ripper(s) on duty can operate. Press E again to get up.` Player 1 reads
   `<name> is lying on the chair. ALT+click them > Operate, or /operer 2.`
5. Player 1 stands 6 m away, at the clinic entrance: `/operer 2` → `Get within 4 m of the patient
   (6.0 m).` (From the alley outside the `viktor_clinic` zone: `Operate inside the clinic
   (viktor_clinic zone).`) Walks next to the chair, holds **ALT**, clicks player 2, picks **Operate** → the menu `Ripperdoc - <name>`:
   `Gorilla Arms - Street` (1 500 €$, stock `yours x1`, 15 s), `Gorilla Arms - Industrial` greyed
   (no box), `Reinforced Tendons - ...` greyed, the hacking rows greyed or `Provider offline`.
   Pick **Gorilla Arms - Street** → player 1 `Quote sent to <name>: install Gorilla Arms [Street]
   for 1 500 €$. Waiting for consent (30 s).`
6. Player 2 reads `QUOTE from <ripper>: install Gorilla Arms [Street] for 1 500 €$. 15 s under the
   knife. Risk: cyberpsychosis past 4 implants (you carry 0). Answer on screen, or /interaction
   accept | /interaction decline (30 s).` plus a toast. Type `/interaction decline` → both read `No
   procedure: the patient declined the quote.`; player 2 is put back on the chair.
7. Repeat step 5; player 2 accepts (`/interaction accept` or the on-screen prompt). Both read
   `... accepted ... Under the knife for 15 s - press X to abort.`; a purple **Installing Gorilla
   Arms** bar runs on both screens, the patient lies, the ripper kneels and examines. Press **X**
   on either side → `No procedure: the ripper stopped.` / `the patient stopped.` Nothing charged.
8. Repeat and let the bar finish → player 1 `Closing up. Waiting for the chrome to settle...` then
   `Done: Gorilla Arms [Street] installed on <name>. 1 500 €$ to the ripper society.`; player 2
   `Done: Gorilla Arms [Street] installed. You paid 1 500 €$ (account).` (or `(cash)` when the
   account was short) and a success toast. `/solde` on player 2 shows the debit; `/inv` on player 1
   shows the box gone; player 1 `/ripper` → `Last 24 h: 1 operation(s).` + the row; log `op ...
   done`. Player 2 draws fists and punches: Gorilla Arms.
9. Player 2: `/implants` → `Implants: 1 installed (cyberpsychosis past 4).`, `arms: Gorilla Arms
   [Street]`, the other slots `-`.
10. Player 1 operates again: the menu now shows **Remove Gorilla Arms** at 750 €$; accept, wait →
    `Done: Gorilla Arms removed.` Native arms are back; `/implants` shows `arms: -`.
11. Cyberpsychosis: set `cyberpsychosisThreshold = 0` in `shared/config.lua`, reload, install any
    implant → the patient's screen smears (`drugged`) for 60 s, red toast **Cyberpsychosis**, chat
    `WARNING - 1 implants: your chrome is fighting your brain...`, ripper told too, log
    `cyberpsychosis on player 2 (1 implants > 0)`.
12. Player 1: `/service` (clock out) then `/operer 2` → `Clock in first: /service.` Player 2:
    `/operer 1` → `You are no ripperdoc. Only a ripper on duty can operate.`

### What a single player can check

- The **chair prompt**: walk to the ring in Vik's chair room, press **E** → you lie down on the
  chair; `E` again → you get up. Walk away while lying → `You left the ripperdoc chair.`
- `/implants` → your record from the platform (`Implants: 0 installed ...`, five slot lines), or
  `Your implant record is not ready (...)` while `open77_appearance` is still binding you.
- **The quote refusal when no ripper is on duty**: `/ripper` (as a citizen) → `Rippers on duty:
  none. Nobody can give you a quote right now - come back later, choom.`; lying on the chair →
  `... No ripper is on duty right now - nobody can give you a quote.`; `/operer 1` on yourself
  without the job → `You are no ripperdoc ...`; with the job but off duty → `Clock in first`.
- As a ripper alone (`setjob 1 ripper 3`, `/service`): `/ripper`, `/ripper restock legs 2`, and
  `/operer 1` → `Operating on yourself? Not even in Night City.`

## Notes and limits

- The chair posture is stopped just before the quote is sent: the interaction coordinator refuses
  a participant in another animation (`animation_busy`), and the quote interaction plays the
  surgery postures itself. After any end of the flow the patient is put back on the chair when
  still next to it (1.5 s later), else told to press **E** again.
- The consent prompt is the platform's (`open77_player_interactions`); the quote text itself is
  this resource's chat line and toast. `/interaction accept` / `/interaction decline` always work.
- Record fields for the three hacking slots are read as `record.operating_system`, `record.self_ice`,
  `record.purge`, and any other implant-shaped field of the record is listed as well; the cyberware
  guide documents only `arms` and `legs`, so if the platform stores the hacking slots under other
  names the menu still offers **install** on a filled slot and the platform's refusal is shown.
- A removal returns no box. A resource stop between the payment and the platform's result loses
  the completion event: the log line `op ... offered` without a `done` is the trace to refund by hand.
