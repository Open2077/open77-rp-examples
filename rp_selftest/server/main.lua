-- rp_selftest: server-only checks of the RP round's cross-resource contracts.
-- Runs once at start; every line is "[rp_selftest] PASS|FAIL <check> -- detail".

local passed, failed = 0, 0

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        print(("[rp_selftest] PASS %s -- %s"):format(name, tostring(detail or "")))
    else
        failed = failed + 1
        print(("[rp_selftest] FAIL %s -- %s"):format(name, tostring(detail or "")))
    end
end

local function call(resource, name, ...)
    local ok, a, b = pcall(function(...)
        return exports[resource][name](exports[resource], ...)
    end, ...)
    if not ok then return nil, "error: " .. tostring(a) end
    return a, b
end

local changed = {}
AddEventHandler("rp_economy:changed", function(playerId, balance, delta, reason)
    changed[#changed + 1] = { playerId = playerId, balance = balance, delta = delta, reason = reason }
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(500)
        -- economy: argument validation must refuse without touching anything
        local v, r = call("rp_economy", "add", "x", 10, "test")
        check("economy.add refuses a non-numeric id", v == nil and type(r) == "string", r)
        v, r = call("rp_economy", "add", 999999, -5, "test")
        check("economy.add refuses a negative amount", v == nil and type(r) == "string", r)
        v, r = call("rp_economy", "getBalance", 999999)
        check("economy.getBalance answers a number for an unknown player", type(v) == "number", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_economy", "remove", 999999, 1, "test")
        check("economy.remove refuses when the player is unknown or has no funds", v == nil and type(r) == "string", r)

        -- jobs
        v, r = call("rp_jobs", "getJob", 999999)
        check("jobs.getJob answers nil for an unknown player", v == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_jobs", "hasJob", 999999, "livreur")
        check("jobs.hasJob answers false for an unknown player", v == false, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_jobs", "hasJob", "abc", "livreur")
        check("jobs.hasJob survives a bad id", v == false or v == nil, tostring(v) .. " " .. tostring(r))

        -- phase 1: identity, inventory, bank, needs (refusal paths only: no player is needed)
        v, r = call("rp_identity", "isRegistered", 999999)
        check("identity.isRegistered answers false for an unknown player", v == false or v == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_identity", "get", 999999)
        check("identity.get answers nil for an unknown player", v == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_inventory", "has", 999999, "water", 1)
        check("inventory.has answers false for an unknown player", v == false, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_inventory", "add", 999999, "water", 1)
        check("inventory.add refuses an unknown player", v == nil and type(r) == "string", r)
        v, r = call("rp_inventory", "define", { crowbar_test = { label = "Crowbar (selftest)", weight = 1.5 }, ["BAD ID"] = { label = "x", weight = 1 } })
        check("inventory.define registers one item and rejects one", v == 1 and r == 1, tostring(v) .. "/" .. tostring(r))
        v, r = call("rp_bank", "getAccount", 999999)
        check("bank.getAccount refuses an unknown player", v == nil and type(r) == "string", r)
        v, r = call("rp_bank", "society", "selftest")
        check("bank.society creates and answers a society", type(v) == "table" and v.name == "selftest", tostring(v and v.balance) .. " " .. tostring(r))
        v, r = call("rp_bank", "societyAdd", "selftest", 100, "selftest")
        check("bank.societyAdd credits", v == 100 or (type(v) == "number" and v >= 100), tostring(v) .. " " .. tostring(r))
        v, r = call("rp_bank", "societyRemove", "selftest", 100, "selftest")
        check("bank.societyRemove debits", type(v) == "number", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_bank", "charge", 999999, 10, "selftest", "selftest")
        check("bank.charge refuses an unknown player", v == nil and type(r) == "string", r)
        v, r = call("rp_needs", "get", 999999)
        check("needs.get answers nil for an unknown player", v == nil, tostring(v) .. " " .. tostring(r))

        Wait(200)
        check("economy.changed was not raised by refused calls", #changed == 0, #changed .. " event(s)")

        -- phases 3-5: read-only exports, no player and no side effect. These resources are not
        -- dependencies (some are optional on a given server), so give them a moment to start.
        local later = { "rp_config", "rp_logs", "rp_whitelist", "rp_admin", "rp_garage", "rp_housing",
            "rp_gangs", "rp_crime", "rp_phone", "rp_radio", "rp_shops" }
        for _ = 1, 40 do
            local pending = false
            for _, name in ipairs(later) do
                local state = GetResourceState(name)
                if state == "starting" then pending = true end
            end
            if not pending then break end
            Wait(250)
        end
        v, r = call("rp_config", "get", "rp_config.chatListMax")
        check("config.get answers a number for a catalogue key", type(v) == "number", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_config", "get", "rp_selftest.no_such_key", 42)
        check("config.get answers the default for an unknown key", v == 42, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_logs", "query", { limit = 1 })
        check("logs.query answers a table", type(v) == "table", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_whitelist", "isAllowed", "selftest:nobody")
        check("whitelist.isAllowed answers a boolean for an unknown identifier", type(v) == "boolean", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_whitelist", "isAllowed", 42)
        check("whitelist.isAllowed refuses a non-string identifier", v == false and type(r) == "string", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_admin", "isAdmin", 999999)
        check("admin.isAdmin answers false for an unknown player", v == false, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_admin", "isAdmin", "abc")
        check("admin.isAdmin survives a bad id", v == false, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_garage", "vehiclesOf", 999999)
        check("garage.vehiclesOf answers an empty table for an unknown player", type(v) == "table" and #v == 0, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_housing", "homeOf", 999999)
        check("housing.homeOf answers nil for an unknown player", v == nil and r == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_gangs", "gangOf", 999999)
        check("gangs.gangOf answers nil for an unknown player", v == nil and r == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_crime", "wantedVehicles")
        check("crime.wantedVehicles answers a table", type(v) == "table", tostring(v) .. " " .. tostring(r))
        v, r = call("rp_phone", "numberOf", 999999)
        check("phone.numberOf answers nil for an unknown player", v == nil and r == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_radio", "channelOf", 999999)
        check("radio.channelOf answers nil for an unknown player", v == nil and r == nil, tostring(v) .. " " .. tostring(r))
        v, r = call("rp_shops", "stock", "selftest_no_such_shop")
        check("shops.stock refuses an unknown shop", v == nil and r == "unknown_shop", tostring(v) .. " " .. tostring(r))

        print(("[rp_selftest] done: %d passed, %d failed"):format(passed, failed))
    end)
end)
