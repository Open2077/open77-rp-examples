resource "rp_medic"
version "1.0.0"
open77_version "*"
auto_start true

-- Server-only medic service: /heal, /revive, /911, /medic.
-- Every permission below is the one the card of a native this resource calls requires:
--   players.stats.read   Open77.stats.get             (is the patient already at full health?)
--   players.stats.apply  Open77.stats.restoreHealth   (/heal)
--   players.life.read    Open77.players.isDead        (alive / dead gate of both commands)
--   players.life.revive  Open77.players.revive        (/revive)
--   network.events       RegisterNetEvent("chat:ready") (chat suggestions)
--   acl.read             Open77.acl.isAllowed         (fallback when rp_jobs has no export)
--   players.animations.control  Open77.animations.play / stop (the medic's kneel, MEDIC_STAGE)
--   world.props          Open77.props.create / attach / remove (the injector in the medic's hand)
permissions {
    "players.stats.read",
    "players.stats.apply",
    "players.life.read",
    "players.life.revive",
    "network.events",
    "acl.read",
    "players.animations.control",
    "world.props",
}

-- Exports called synchronously: rp_jobs (hasJob / getJob), rp_economy (remove / add).
-- open77_uikit draws the intervention bar, open77_props the injector in the hand.
dependencies { "rp_economy", "rp_jobs", "open77_uikit", "open77_props" }

server_script "server/main.lua"
