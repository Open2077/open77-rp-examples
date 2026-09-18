-- rp_ambiance -- client half.
--
-- This script exists so the resource is part of the client image: the ambience loops
-- declared in the manifest `files` entry are read out of THIS resource on the client by
-- open77_sound (a server-only resource is never downloaded and its audio is unreachable).
-- Nothing is decided here: the server names a file and an audience; the client only logs.

local RESOURCE = GetCurrentResourceName()

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    print("[rp_ambiance] client image ready: zone ambience files available to open77_sound")
end)

-- open77_sound reports a loop it could not start (undeclared file, unsupported format,
-- surface not up, audio blocked...) on this local event; keep the reason visible.
AddEventHandler("open77:soundFailed", function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    print("[rp_ambiance] sound failed: " .. table.concat(parts, " "))
end)
