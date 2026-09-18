-- eval_taxi / client
-- /taxi reads the player's manual map waypoint and asks the server for a ride.
-- /taxi cancel asks the server to end the current ride.
-- The client only *requests*: the server owns the vehicle, the driver and the trip.

RegisterCommand("taxi", function(_, args)
    local first = args and args[1]
    if type(first) == "string" and first:lower() == "cancel" then
        local ok, sendReason = TriggerServerEvent("eval_taxi:cancel")
        if not ok then
            print(("[eval_taxi] could not send cancel request: %s"):format(tostring(sendReason)))
        end
        return
    end

    local waypoint, reason = Open77.map.getWaypoint()

    -- nil + reason: the map snapshot is missing/stale (map_unavailable).
    -- nil alone:    the player simply has no waypoint placed.
    if not waypoint then
        print(("[eval_taxi] /taxi: no waypoint (%s)"):format(tostring(reason or "none placed")))
        TriggerServerEvent("eval_taxi:request", { reason = reason or "no_waypoint" })
        return
    end

    print(("[eval_taxi] /taxi: waypoint at %.1f,%.1f,%.1f"):format(
        waypoint.position.x, waypoint.position.y, waypoint.position.z))
    local ok, sendReason = TriggerServerEvent("eval_taxi:request", { position = waypoint.position })
    if not ok then
        print(("[eval_taxi] could not send taxi request: %s"):format(tostring(sendReason)))
    end
end, false, {
    help = "Appelle un taxi qui vous conduit a votre waypoint (/taxi cancel pour annuler)",
    parameters = { { name = "cancel", help = "optionnel : annule la course en cours" } },
})
