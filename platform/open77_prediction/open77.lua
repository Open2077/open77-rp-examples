-- open77_prediction -- the operator's switches and telemetry for every
-- presentation-only prediction family (review items I6 and I9).
--
-- A prediction shows the actor a reaction before the server's verdict (a
-- struck car moving, a hit player falling, a door opening) and is then adopted
-- by the real reaction or refuted. This resource is how an operator controls
-- them without a client release:
--
--   * seven switches -- melee, slam, hack, door, blast, carContact,
--     playerContact -- and a round-trip ceiling above which a client starts no
--     new prediction (one in flight finishes normally). They are server
--     tunables: Warden renders them as a form, `tunable.set open77_prediction
--     <key> <value>` sets one from the console, and both persist.
--   * a gamemode can only RESTRICT them further, for as long as it runs:
--     `exports.open77_prediction:restrict({ families = { blast = false },
--     maxPingMs = 150 })`, withdrawn by `clearRestriction()` or its own stop.
--   * the effective policy is published in the GLOBAL STATE BAG under
--     `open77.prediction`; every client applies it at once, late joiners
--     included, with no event of its own.
--   * each client reports its non-zero counters (predicted, adopted, refuted,
--     skipped) once a minute; the server logs one aggregated line per window
--     and names clients whose refutation rate is high. `prediction` prints it.
--
-- Missing entirely, clients keep their compiled defaults: every family on,
-- 250 ms ceiling. Nothing depends on this resource, so a server may omit it
-- from `resources.load`; it then has no switch and no telemetry.
resource "open77_prediction"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

shared_script "shared/policy.lua"
server_script "server/main.lua"
client_script "client/main.lua"

permissions {
    -- server: publish the policy key of the global bag.
    "state.write",
    -- both: the telemetry report (client -> server) and `Open77.network.status`
    -- (its `ping`), which is gated by `network.client`.
    "network.events",
    "network.client",
    -- client: `Open77.prediction.setPolicy`, the native families' switches.
    "prediction.policy",
}
