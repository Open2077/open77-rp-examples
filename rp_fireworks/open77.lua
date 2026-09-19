-- rp_fireworks: synchronized fireworks and celebration shows.
--
-- The example for "everybody on the street sees the same thing at the same
-- moment". Every shell is fired by the SERVER through Open77.effects.play,
-- which broadcasts it to the players in range -- so the show has one clock and
-- one authority. A client-side effect would be simpler and would drift: each
-- client walks its own timers, and a ten-second sequence is visibly out of step
-- between two players within the first volley.
resource "rp_fireworks"
version "1.0.0"
open77_version "*"
auto_start true

-- world.effects  : Open77.effects.play (every shell of every show)
-- network.events : Open77.chat.send, the command's answer to the operator
permissions { "world.effects", "network.events" }

shared_script "shared/config.lua"
server_script "server/main.lua"
