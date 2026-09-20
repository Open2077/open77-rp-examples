-- rp_drones: a server-authoritative drone light show.
--
-- Two dozen lights hang in the night sky and morph between a ring, a heart and
-- the 77, the way a modern drone display does. Every drone is a server-owned
-- entity and every position it holds is written by the server, so two players
-- standing side by side watch the same picture at the same instant. There is
-- no client code at all, which is the point.
--
-- READ THE README BEFORE FLYING IT. Two in-game runs failed -- one invisible,
-- one that disconnected the player with send_failed:LimitExceeded -- and the
-- shape of this resource is mostly the consequence.
resource "rp_drones"
version "1.0.0"
open77_version "*"
auto_start true

-- world.population : Open77.world.setPopulation
--                 -- the vehicle-sweep guard, npc style only and off by
--                 default. `Open77.world.getPopulation` needs no grant; only
--                 the write does. See `drone.npc.vehicleSweepGuard`.
-- world.npcs    : Open77.npcs.create / remove / get / owner / setTransform /
--                 setAttitude / setAiMode / setAIEnabled
--                 -- the `npcprobe` and `npcmove` instruments: ONE drone NPC,
--                 spawned next to you and measured. A whole npc show is still
--                 refused; the README says what is proven and what is not.
-- world.effects : Open77.effects.create / update / remove
--                 -- the "effect" drone style (the default), one looping world
--                 VFX per drone
-- world.props   : Open77.props.create / setTransform / update / remove / clear
--                 -- the "light" drone style, one `kind = "light"` prop per
--                 drone, plus the props.clear() sweep on start
--
-- Nothing else. Open77.chat.send needs no grant (the facade publishes on the
-- host bus and never reaches a client itself), Open77.players.all and
-- Open77.players.position need none, and Open77.time.monotonic needs none.
permissions { "world.effects", "world.props", "world.npcs", "world.population" }

-- The two data tables are `shared_scripts` rather than server-only for the
-- same reason rp_fireworks' config is: this resource is meant to be read, and
-- a client half added later (a "watch the show" camera, a spectator HUD) wants
-- the formations without a second copy. Eight kilobytes per client, once.
shared_scripts { "shared/formations.lua", "shared/config.lua" }
server_script "server/main.lua"
