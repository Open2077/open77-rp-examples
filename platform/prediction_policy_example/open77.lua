-- prediction_policy_example: how a gamemode turns on melee, Slam and hack
-- prediction.
--
-- Those three predictions live in the bundled open77_cyberware resource and
-- fail closed: a client only shows a hit early once the gamemode has told it
-- the combat rules (PvP on, which routing bucket, safe zones, damage
-- multipliers). This is the whole contract: a local client event, sent when
-- the gamemode starts, re-sent when asked, withdrawn when it stops. Freeroam
-- ships the same code.
resource "prediction_policy_example"
version "1.0.0"
open77_version "*"
auto_start true

-- No permission: the policy is a local client event, nothing goes on the wire.
client_script "client/main.lua"
