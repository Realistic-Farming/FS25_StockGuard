-- SG2-1-kernel_spec_test.lua
--
-- The rest of the SG2-1 kernel: the call-scoped operation context, the Storage
-- brackets, the generic FillUnit observer and the two carrier adapters.
--
-- Every refusal case here is PAIRED with a positive twin that proves the fixture
-- reaches the code. A fixture that falls out early reports "refused" exactly like
-- a working guard, so a negative assertion is worth only what its twin proves.
--
--!load: src/core/SGValues.lua, src/native/SGOperationContext.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua

local C  = SGOperationContext
local SB = SGStorageBracket
local FO = SGFillUnitObserver
local NA = SGNativeAdapters

g_server = g_server or {}

-- ── A: the operation context is call-scoped and nests ───────────────────────
do
    local s = C.new()
    T.eq("A1 a fresh stack is at rest", C.isAtRest(s), true)
    T.eq("A2 and has no current frame", C.current(s), nil)

    local outer = C.open(s, { id = "veh1" }, "PROCESS")
    T.ok("A3 opening returns a frame", outer ~= nil)
    T.eq("A4 the stack is no longer at rest", C.isAtRest(s), false)
    T.eq("A5 the frame knows its depth", outer.depth, 1)

    T.eq("A6 an observation lands on the open frame", C.observe(s, { litres = 10 }), true)
    T.eq("A7 and is held there", #outer.observations, 1)

    local inner = C.open(s, { id = "veh1" }, "FILLUNIT")
    T.eq("A8 a nested frame opens at depth 2", inner.depth, 2)
    C.observe(s, { litres = 3 })
    T.eq("A9 the inner observation lands on the INNER frame", #inner.observations, 1)
    T.eq("A10 and NOT on the outer one, which did not cause it", #outer.observations, 1)

    C.publish(s, { accepted = 3 })
    C.close(s, inner)
    T.eq("A11 the inner frame's OUTPUT merges upward", #outer.outputs, 1)
    T.eq("A12 but its raw observations do not", #outer.observations, 1)
    T.eq("A13 the stack returns to the outer frame", C.current(s), outer)

    C.close(s, outer)
    T.eq("A14 and to rest once the outer closes", C.isAtRest(s), true)
    T.eq("A15 every frame has a distinct ordinal", outer.ordinal ~= inner.ordinal, true)
end

do
    -- Observing outside a bracket is refused rather than attributed to whatever
    -- happens to be open, because a mutation we did not bracket is one whose
    -- operation we cannot name.
    local s = C.new()
    T.eq("A16 observing with nothing open is refused", C.observe(s, { litres = 1 }), false)
    T.eq("A17 publishing with nothing open is refused", C.publish(s, {}), false)
    local f = C.open(s, {}, "K")
    T.eq("A18 but observing works once a frame is open", C.observe(s, { litres = 1 }), true)
    C.close(s, f)
    T.eq("A19 and is refused again after it closes", C.observe(s, { litres = 1 }), false)
end

do
    -- An out-of-order close unwinds what is above it and marks those abandoned,
    -- because their brackets can no longer settle them coherently. This is the
    -- native-call-threw path.
    local s = C.new()
    local outer = C.open(s, {}, "OUTER")
    local inner = C.open(s, {}, "INNER")
    local _, unwound = C.close(s, outer)
    T.eq("A20 closing the outer frame unwinds the inner one", unwound, 1)
    T.eq("A21 the abandoned frame is marked as such", inner.abandoned, true)
    T.eq("A22 and the stack is back at rest", C.isAtRest(s), true)
end

do
    -- Depth is bounded. A refusal to observe is not a refusal to let the native
    -- work happen.
    local s = C.new()
    local frames = {}
    for i = 1, C.MAX_DEPTH do frames[i] = C.open(s, {}, "K") end
    T.eq("A23 the stack fills to its bound", s.depth, C.MAX_DEPTH)
    T.eq("A24 the next open is refused", C.open(s, {}, "K"), nil)
    T.eq("A25 and the refusal is counted rather than hidden", s.overflows, 1)
    C.close(s, frames[1])
    T.eq("A26 closing the root unwinds everything", C.isAtRest(s), true)
end

-- ── B: the Storage brackets see what a listener would miss ──────────────────
local function newStorageClass()
    local S = {}
    S.__index = S
    function S.new(levels, capacity)
        return setmetatable({ fillLevels = levels or {}, capacity = capacity or 1000,
                              capacities = {}, isServer = true,
                              fillLevelChangedListeners = {}, fillLevelsLastPublished = {} }, S)
    end
    -- Faithful to the control flow at Storage.lua:287-303: clamp, early return when
    -- unchanged or unknown, then notify ONLY past the 0.1 threshold.
    function S:setFillLevel(fillLevel, fillType)
        local capacity = self.capacities[fillType] or self.capacity
        local clamped = math.max(0, math.min(fillLevel, capacity))
        if self.fillLevels[fillType] == nil or clamped == self.fillLevels[fillType] then return end
        local previous = self.fillLevels[fillType]
        self.fillLevels[fillType] = clamped
        local delta = clamped - previous
        local rounded = math.floor(clamped + 0.5)
        if math.abs(delta) > 0.1 or self.fillLevelsLastPublished[fillType] ~= rounded then
            for _, fn in ipairs(self.fillLevelChangedListeners) do fn(fillType, delta) end
            self.fillLevelsLastPublished[fillType] = rounded
        end
    end
    function S:empty()
        for fillType in pairs(self.fillLevels) do self.fillLevels[fillType] = 0 end
    end
    return S
end

do
    local S = newStorageClass()
    local seen = {}
    T.eq("B1 the brackets install on the class table", SB.install(S, function(_st, ft, before, after, cause)
        seen[#seen + 1] = { ft = ft, before = before, after = after, cause = cause }
    end), true)

    -- A storage constructed BEFORE the install is still reached, because a
    -- metatable class method has no per-instance copy.
    local st = S.new({ [1] = 100 })
    st:setFillLevel(140, 1)
    T.eq("B2 a normal change is observed", #seen, 1)
    T.eq("B3 with the level BEFORE, not the request", seen[1].before, 100)
    T.eq("B4 and the level AFTER, which is what actually landed", seen[1].after, 140)

    -- THE CASE A LISTENER MISSES. A run of sub-0.1 changes that never crosses a
    -- rounding boundary notifies nobody, and for material continuity that is a
    -- leak with no symptom.
    local listenerSaw = 0
    st.fillLevelChangedListeners[1] = function() listenerSaw = listenerSaw + 1 end
    local n = #seen
    st:setFillLevel(140.04, 1)
    st:setFillLevel(140.08, 1)
    T.eq("B5 the native listener never fired for sub-threshold changes", listenerSaw, 0)
    T.eq("B6 BUT THE BRACKET SAW BOTH, which is why we do not subscribe", #seen - n, 2)

    -- empty is a separate path a listener never sees at all.
    local m = #seen
    st:setFillLevel(200, 1)
    st.fillLevels[2] = 50
    local k = #seen
    st:empty()
    T.ok("B7 empty is observed, which addFillLevelChangedListeners never sees", #seen > k)
    local emptied = 0
    for i = k + 1, #seen do
        if seen[i].cause == SB.CAUSE_EMPTY and seen[i].after == 0 then emptied = emptied + 1 end
    end
    T.eq("B8 every type held before the call is reported as emptied", emptied, 2)
    T.ok("B9 and the set cause is distinct from the empty cause", seen[m + 1].cause == SB.CAUSE_SET)
end

do
    local S = newStorageClass()
    SB.install(S, nil)
    T.eq("B10 a second install is refused rather than stacking", (SB.install(S, nil)), false)

    T.eq("B11 teardown restores our own brackets", (SB.uninstall(S)), true)
    T.eq("B12 and a second teardown reports nothing to do", (SB.uninstall(S)), false)

    -- Wrapped by another mod afterwards: restoring would delete their hook.
    SB.install(S, nil)
    local ours = S.setFillLevel
    S.setFillLevel = function(self, ...) return ours(self, ...) end
    local ok, why = SB.uninstall(S)
    T.eq("B13 a class wrapped by another mod is NOT torn down", ok, false)
    T.eq("B14 and says why", why, "WRAPPED_BY_ANOTHER")
end

do
    local saved = g_server
    g_server = nil
    local S = newStorageClass()
    T.eq("B15 a client does not install the brackets", (SB.install(S, nil)), false)
    g_server = saved
    T.eq("B16 the server does", (SB.install(S, nil)), true)
end

-- ── C: the FillUnit observer records the ACCEPTED delta ─────────────────────
local function newVehicle(accepted)
    local v = { spec_fillUnit = { fillUnits = { [1] = { fillLevel = 0, capacity = 500 } } } }
    v.addFillUnitFillLevel = function(_self, _farmId, _index, delta, _ft, _tt, _fp)
        -- The engine returns what it ACCEPTED, which is not what was asked for.
        return accepted == nil and delta or accepted
    end
    v.setFillUnitFillType = function() return true end
    v.emptyAllFillUnits = function() return true end
    return v
end

do
    local moves = {}
    local v = newVehicle(40)     -- asked for more than the engine will take
    T.eq("C1 the observer installs on the instance copy", (FO.install(v, function(_veh, idx, acc, ft, cause)
        moves[#moves + 1] = { idx = idx, acc = acc, ft = ft, cause = cause }
    end)), true)

    local returned = v:addFillUnitFillLevel(1, 1, 100, 7, nil, nil)
    T.eq("C2 the engine's return reaches the caller unchanged", returned, 40)
    T.eq("C3 one movement observed", #moves, 1)
    T.eq("C4 RECORDED AS THE ACCEPTED 40, NOT THE REQUESTED 100", moves[1].acc, 40)
    T.eq("C5 with the fill type", moves[1].ft, 7)
    T.eq("C6 and the cause", moves[1].cause, FO.CAUSE_ADD)
end

do
    -- A refusal returns 0 and is not movement. Recording it would invent a
    -- transfer the engine declined.
    local moves = 0
    local v = newVehicle(0)
    FO.install(v, function() moves = moves + 1 end)
    T.eq("C7 a refused add returns zero", v:addFillUnitFillLevel(1, 1, 100, 7), 0)
    T.eq("C8 AND IS NOT RECORDED AS MOVEMENT", moves, 0)
end

do
    local causes = {}
    local v = newVehicle(10)
    FO.install(v, function(_veh, _idx, _acc, _ft, cause) causes[#causes + 1] = cause end)
    v:addFillUnitFillLevel(1, 1, 10, 7)
    v:setFillUnitFillType(1, 9)
    v:emptyAllFillUnits(false)
    T.eq("C9 three distinct causes are reported", #causes, 3)
    T.eq("C10 add", causes[1], FO.CAUSE_ADD)
    T.eq("C11 a fill-type change ends one occupancy and begins another", causes[2], FO.CAUSE_TYPE)
    T.eq("C12 emptyAllFillUnits is its own path", causes[3], FO.CAUSE_EMPTY_ALL)
end

do
    local v = newVehicle(10)
    FO.install(v, nil)
    T.eq("C13 a second install is refused rather than double-counting", (FO.install(v, nil)), false)
    T.eq("C14 teardown restores", (FO.uninstall(v)), true)
    T.eq("C15 and a second teardown has nothing to do", (FO.uninstall(v)), false)

    FO.install(v, nil)
    local ours = v.addFillUnitFillLevel
    v.addFillUnitFillLevel = function(self, ...) return ours(self, ...) end
    local ok, why = FO.uninstall(v)
    T.eq("C16 a vehicle wrapped by another mod is NOT torn down", ok, false)
    T.eq("C17 and says why", why, "WRAPPED_BY_ANOTHER")
end

do
    local saved = g_server
    g_server = nil
    local v = newVehicle(10)
    T.eq("C18 a client does not install the observer", (FO.install(v, nil)), false)
    g_server = saved
    T.eq("C19 the server does", (FO.install(v, nil)), true)
    T.eq("C20 a vehicle with no fill-unit spec is refused",
         (FO.install({ }, nil)), false)
end

-- ── D: the carrier adapters read the engine, and own nothing ────────────────
do
    local storeA = { fillLevels = { [1] = 60, [2] = 0 }, capacity = 900,
                     getUniqueId = function() return "placeable:A" end }
    local storeB = { fillLevels = { [3] = 10 }, capacity = 500,
                     getUniqueId = function() return "placeable:B" end }
    local spec = NA.storageAdapterSpec(function() return { storeA, storeB } end)

    T.eq("D1 the spec declares its version", spec.version, 1)
    T.eq("D2 and its carrier kind", spec.carrierKinds[1], "storage")

    local list = spec.enumerateCarriers()
    T.eq("D3 both storages enumerate", #list, 2)
    T.eq("D4 keyed by the engine's own persistent id, not a table address",
         list[1].carrierKey.nativeOwnerKey, "placeable:A")

    local resolved = spec.resolveCarrier({ carrierKey = { nativeOwnerKey = "placeable:B" } })
    T.eq("D5 a binding resolves by that id", resolved, storeB)
    T.eq("D6 an unknown id resolves to nothing rather than the nearest match",
         spec.resolveCarrier({ carrierKey = { nativeOwnerKey = "placeable:ZZZ" } }), nil)

    local state = spec.readNativeState(storeA)
    T.eq("D7 native state reports the live total", state.amount, 60)
    T.eq("D8 zero-level types are not reported as held material", state.levels[2], nil)
    T.eq("D9 and the held one is", state.levels[1], 60)
end

do
    local veh = { getUniqueId = function() return "vehicle:7" end,
                  spec_fillUnit = { fillUnits = { [1] = { fillLevel = 120, capacity = 400, fillType = 5 } } } }
    local spec = NA.fillUnitAdapterSpec(function() return { veh } end)

    local list = spec.enumerateCarriers()
    T.eq("D10 one fill unit is one carrier", #list, 1)
    T.eq("D11 owner key is the vehicle", list[1].carrierKey.nativeOwnerKey, "vehicle:7")
    T.eq("D12 component key is the unit index", list[1].carrierKey.componentKey, "1")

    local carrier = spec.resolveCarrier({ carrierKey = { nativeOwnerKey = "vehicle:7", componentKey = "1" } })
    T.ok("D13 a binding resolves to that vehicle and index",
         carrier ~= nil and carrier.vehicle == veh and carrier.fillUnitIndex == 1)
    T.eq("D14 an index the vehicle does not have resolves to nothing",
         spec.resolveCarrier({ carrierKey = { nativeOwnerKey = "vehicle:7", componentKey = "9" } }), nil)

    local state = spec.readNativeState(carrier)
    T.eq("D15 native state is the live level", state.amount, 120)
    T.eq("D16 with its single fill type", state.fillType, 5)
end

do
    -- An object the engine cannot name stably is not bound, because the binding
    -- would not survive a reload.
    local anon = { fillLevels = { [1] = 10 } }
    local spec = NA.storageAdapterSpec(function() return { anon } end)
    T.eq("D17 an object with no persistent id is not enumerated", #spec.enumerateCarriers(), 0)
end

do
    local saved = g_server
    local st = { fillLevels = { [1] = 5 }, getUniqueId = function() return "s" end }
    local spec = NA.storageAdapterSpec(function() return { st } end)
    T.eq("D18 the server enumerates", #spec.enumerateCarriers(), 1)
    g_server = nil
    T.eq("D19 a client enumerates nothing", #spec.enumerateCarriers(), 0)
    T.eq("D20 a client resolves nothing", spec.resolveCarrier({ carrierKey = { nativeOwnerKey = "s" } }), nil)
    T.eq("D21 and reads no native state", spec.readNativeState(st), nil)
    T.eq("D22 access is refused on a client", spec.hasAccess(1, st), false)
    g_server = saved
end

do
    -- Access refuses when it cannot check, rather than opening up.
    local saved = g_currentMission
    g_currentMission = nil
    local spec = NA.storageAdapterSpec(function() return {} end)
    T.eq("D23 no access handler means no access", spec.hasAccess(1, {}), false)
    g_currentMission = { accessHandler = { canFarmAccess = function() return true end } }
    T.eq("D24 and a working handler is honoured", spec.hasAccess(1, {}), true)
    g_currentMission = saved
end
