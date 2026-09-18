-- SG2-1-workarea_installer_spec_test.lua
--
-- The captured work-area pointer installer. This is mechanism 1 of the four
-- dispatch mechanisms, and it is the one where the instance copy is DEAD, so the
-- bench models the engine's three-copy chain rather than calling the installer and
-- checking a flag. A test that asserted "something was assigned" would pass
-- against the broken build too, which is exactly how this class of defect shipped
-- three times in SoilFertilizer.
--
--   class table -> instance copy (copyTypeFunctionsInto) -> workArea capture
--   then dispatch the way WorkArea.lua:182-183 does.
--
--!load: src/core/SGValues.lua, src/native/SGWorkAreaInstaller.lua

local I = SGWorkAreaInstaller

g_server = g_server or {}

-- ── the engine's chain, modelled ─────────────────────────────────────────────

--- Build a vehicle the way the engine does. `areas` is { functionName, fn }.
local function buildVehicle(specField, areas)
    local vehicle = { [specField] = {}, spec_workArea = { workAreas = {} } }
    for _, a in ipairs(areas) do
        vehicle[a.functionName] = a.fn          -- copyTypeFunctionsInto
    end
    for _, a in ipairs(areas) do
        local wa = { functionName = a.functionName }
        wa.processingFunction = vehicle[a.functionName]   -- WorkArea:onLoad capture
        table.insert(vehicle.spec_workArea.workAreas, wa)
    end
    return vehicle
end

--- Dispatch exactly as WorkArea.lua:183 does.
local function engineCall(vehicle, index, dt)
    local wa = vehicle.spec_workArea.workAreas[index]
    return wa.processingFunction(vehicle, wa, dt or 16)
end

-- ── A: the bracket is reached through the engine's own dispatch ──────────────
do
    local opened, closed, realRan = 0, 0, 0
    local real = function(_self, _wa, _dt) realRan = realRan + 1 return 250, 3 end
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = real } })

    local mk = I.bracketFactory(
        function() opened = opened + 1 return "tok" end,
        function(token, ok) closed = closed + 1 return token, ok end)

    T.eq("A1 one work area bracketed", I.install(v, "spec_sg", "processThing", mk), 1)

    local a, b = engineCall(v, 1)
    T.eq("A2 THE BRACKET RAN through the engine's dispatch", opened, 1)
    T.eq("A3 and closed", closed, 1)
    T.eq("A4 the native call ran exactly once", realRan, 1)
    T.eq("A5 the first return survives, which WorkArea compares against zero", a, 250)
    T.eq("A6 the second return survives too", b, 3)
end

-- ── B: THE DEFECT. The instance copy is dead for this mechanism. ─────────────
do
    local ran = 0
    local real = function() return 5 end
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = real } })

    -- What a mechanism-2 habit would do here, and it is inert.
    v.processThing = function() ran = ran + 1 return 0 end

    T.eq("B1 patching the instance copy does NOT reach the engine's pointer", engineCall(v, 1), 5)
    T.eq("B2 so that wrapper never ran", ran, 0)
end

-- ── C: a throw in the native call still closes the bracket, then propagates ──
-- WorkArea.lua:183 has no pcall, so without this the operation would be left open
-- for the life of the session.
do
    local opened, closed, sawOk = 0, 0, nil
    local real = function() error("native exploded", 0) end
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = real } })

    local mk = I.bracketFactory(
        function() opened = opened + 1 return "tok" end,
        function(_token, ok) closed = closed + 1 sawOk = ok end)
    I.install(v, "spec_sg", "processThing", mk)

    local ok, err = pcall(engineCall, v, 1)
    T.eq("C1 the bracket opened", opened, 1)
    T.eq("C2 AND CLOSED even though the native call threw", closed, 1)
    T.eq("C3 close was told the native call failed", sawOk, false)
    T.eq("C4 the error still propagates to the engine", ok, false)
    T.eq("C5 unchanged, so the engine sees what it would have seen", err, "native exploded")
end

-- ── D: a fault in OUR bracket must not become a fault in the game ────────────
do
    local realRan = 0
    local real = function() realRan = realRan + 1 return 9, 1 end
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = real } })

    local mk = I.bracketFactory(
        function() error("open blew up", 0) end,
        function() error("close blew up", 0) end)
    I.install(v, "spec_sg", "processThing", mk)

    local ok, a = pcall(engineCall, v, 1)
    T.eq("D1 a throwing open and close do not break the native call", ok, true)
    T.eq("D2 the native call still ran", realRan, 1)
    T.eq("D3 and its return still reaches the engine", a, 9)
end

-- ── E: returns are carried with their exact count ────────────────────────────
do
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = function() return 1, nil, 3 end } })
    local seen
    local mk = I.bracketFactory(nil, function(_t, _ok, _s, _w, _d, ...) seen = select("#", ...) end)
    I.install(v, "spec_sg", "processThing", mk)
    local a, b, c = engineCall(v, 1)
    T.eq("E1 a trailing-nil gap is not collapsed on the way to close", seen, 3)
    T.eq("E2 first return", a, 1)
    T.eq("E3 the nil in the middle survives", b, nil)
    T.eq("E4 third return", c, 3)
end

-- ── F: idempotency, so one pass never opens two operations ───────────────────
do
    local opened = 0
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = function() return 1 end } })
    local mk = I.bracketFactory(function() opened = opened + 1 end, nil)
    T.eq("F1 first install takes it", I.install(v, "spec_sg", "processThing", mk), 1)
    T.eq("F2 a second install adds nothing", I.install(v, "spec_sg", "processThing", mk), 0)
    T.eq("F3 a third adds nothing either", I.install(v, "spec_sg", "processThing", mk), 0)
    engineCall(v, 1)
    T.eq("F4 so exactly ONE operation opens for one pass", opened, 1)
end

-- ── G: selection takes the spec and the name together ────────────────────────
do
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = function() return 1 end } })
    local mk = I.bracketFactory(nil, nil)
    T.eq("G1 a vehicle without the owning spec is untouched",
         I.install(v, "spec_other", "processThing", mk), 0)
    T.eq("G2 a name that is not present is untouched",
         I.install(v, "spec_sg", "processMissing", mk), 0)
    T.eq("G3 the matching pair installs", I.install(v, "spec_sg", "processThing", mk), 1)

    -- The name collision that makes spec-only or name-only selection wrong.
    local two = buildVehicle("spec_other", {
        { functionName = "processDropArea", fn = function() return 2 end },
    })
    T.eq("G4 our install does not reach another spec's identically named area",
         I.install(two, "spec_sg", "processDropArea", mk), 0)
end

-- ── H: teardown restores only what is still ours ─────────────────────────────
do
    local real = function() return 7 end
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = real } })
    I.install(v, "spec_sg", "processThing", I.bracketFactory(nil, nil))

    local restored, left = I.uninstall(v, "spec_sg", "processThing")
    T.eq("H1 our own bracket is restored", restored, 1)
    T.eq("H2 nothing left in place", left, 0)
    T.eq("H3 the engine pointer is the original again", engineCall(v, 1), 7)

    -- Someone else wraps us afterwards: restoring would delete THEIR hook.
    local v2 = buildVehicle("spec_sg", { { functionName = "processThing", fn = real } })
    I.install(v2, "spec_sg", "processThing", I.bracketFactory(nil, nil))
    local foreignRan = 0
    local ours = v2.spec_workArea.workAreas[1].processingFunction
    v2.spec_workArea.workAreas[1].processingFunction = function(s, w, d)
        foreignRan = foreignRan + 1 return ours(s, w, d)
    end

    local r2, l2 = I.uninstall(v2, "spec_sg", "processThing")
    T.eq("H4 a pointer another mod has since wrapped is NOT restored", r2, 0)
    T.eq("H5 it is reported as left in place", l2, 1)
    engineCall(v2, 1)
    T.eq("H6 and their hook still runs rather than being silently deleted", foreignRan, 1)

    -- The record is KEPT on that branch, so a later sweep cannot stack a second
    -- bracket over the foreign one and open two operations per pass.
    T.eq("H7 a re-install does NOT stack over the foreign wrapper",
         I.install(v2, "spec_sg", "processThing", I.bracketFactory(nil, nil)), 0)
end

-- ── I: server only, gated at install ─────────────────────────────────────────
do
    local saved = g_server
    g_server = nil
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = function() return 1 end } })
    T.eq("I1 a client installs nothing", I.install(v, "spec_sg", "processThing", I.bracketFactory(nil, nil)), 0)
    T.eq("I2 and the engine pointer is untouched", engineCall(v, 1), 1)
    g_server = saved
    T.eq("I3 the server does install", I.install(v, "spec_sg", "processThing", I.bracketFactory(nil, nil)), 1)
end

-- ── J: shapes that must not throw ────────────────────────────────────────────
do
    local mk = I.bracketFactory(nil, nil)
    T.eq("J1 a nil vehicle installs nothing", I.install(nil, "spec_sg", "processThing", mk), 0)
    T.eq("J2 no work-area spec installs nothing", I.install({ spec_sg = {} }, "spec_sg", "processThing", mk), 0)
    T.eq("J3 an empty work-area spec installs nothing",
         I.install({ spec_sg = {}, spec_workArea = {} }, "spec_sg", "processThing", mk), 0)
    local v = buildVehicle("spec_sg", { { functionName = "processThing", fn = function() return 1 end } })
    T.eq("J4 a factory returning a non-function installs nothing",
         I.install(v, "spec_sg", "processThing", function() return nil end), 0)
    T.eq("J5 and leaves the engine pointer working", engineCall(v, 1), 1)
    T.eq("J6 uninstalling something never installed is a no-op",
         (I.uninstall(v, "spec_sg", "processThing")), 0)
end
