-- SG2-1-kernel_spec_test.lua
--
-- The rest of the SG2-1 kernel: the call-scoped operation context, the Storage
-- brackets, the generic FillUnit observer and the two carrier adapters.
--
-- Every refusal case here is PAIRED with a positive twin that proves the fixture
-- reaches the code. A fixture that falls out early reports "refused" exactly like
-- a working guard, so a negative assertion is worth only what its twin proves.
--
--!load: src/core/SGValues.lua, src/native/SGOperationContext.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua

local C  = SGOperationContext
local SB = SGStorageBracket
local FO = SGFillUnitObserver

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

-- ── D: moved ─────────────────────────────────────────────────────────────────
-- The carrier adapters are tested through the route the game uses (the mission
-- handle, the restore-complete barrier, observe and restore) in
-- SG2-1-native_join_spec_test.lua groups N and H. Calling the adapter functions
-- directly with invented keys is how six contract defects stayed green here
-- (ledger d4b7216), so those cases, and E15-E24, now live there.

-- ── E: rules nothing checked until a mutation said so ───────────────────────
-- Every case below exists because a mutation SURVIVED the suite above. The
-- suite was green at 86 assertions before any of these were written, and green
-- was not evidence: six rules these modules claim in their own header comments
-- were unpinned, including the one the Storage bracket exists for. Each block
-- names the mutation it kills.

do
    -- M5. The wrapper must forward the native return EXACTLY, count included.
    -- addFillUnitFillLevel returns a single value today, so collapsing the list
    -- looks harmless. It is the same defect class as WorkArea.lua:183, where a
    -- second return IS read and a wrapper returning fewer values throws inside
    -- the per-frame loop with no pcall around it.
    local v = { spec_fillUnit = { fillUnits = { [1] = { fillLevel = 0, capacity = 500 } } } }
    v.addFillUnitFillLevel = function() return 40, "reason", nil end
    T.eq("E1 the observer installs", (FO.install(v, function() end)), true)
    local a, b = v:addFillUnitFillLevel(1, 1, 40, 2)
    T.eq("E2 the first return survives the wrapper", a, 40)
    T.eq("E3 and so does the second", b, "reason")
    T.eq("E4 and a TRAILING NIL is still a return, so the count is preserved",
         select("#", v:addFillUnitFillLevel(1, 1, 40, 2)), 3)
end

do
    -- M7. A setFillLevel that changes nothing is not a change. Without the
    -- before-equals-after skip the bracket invents a movement on every no-op
    -- write, and the record then settles quantities that never moved. The
    -- native function early-returns on an unchanged value, so the bracket sees
    -- the call and must decide for itself that nothing happened.
    local S = newStorageClass()
    local seen = {}
    SB.install(S, function() seen[#seen + 1] = true end)
    local st = S.new({ [1] = 100 })
    st:setFillLevel(100, 1)
    T.eq("E5 writing the level it already holds reports nothing", #seen, 0)
    st:setFillLevel(101, 1)
    T.eq("E6 and the twin proves the fixture reaches the bracket at all", #seen, 1)
    SB.uninstall(S)
end

do
    -- M8. THE CENTRAL CLAIM OF THIS BRACKET, and it was unchecked. The clamp to
    -- capacity lives inside the native function, so the requested level is not
    -- what landed. Reading the level back out of fillLevels is the entire reason
    -- this is a bracket rather than a listener on the request. B3 and B4 above
    -- pass either way because their request happens to fit under the capacity.
    local S = newStorageClass()
    local seen = {}
    SB.install(S, function(_st, _ft, before, after) seen[#seen + 1] = { before = before, after = after } end)
    local st = S.new({ [1] = 100 }, 1000)
    st:setFillLevel(5000, 1)
    T.eq("E7 one change is observed", #seen, 1)
    T.eq("E8 the level before is the real one", seen[1].before, 100)
    T.eq("E9 and the level AFTER is what the clamp left", seen[1].after, 1000)
    T.ok("E10 which is emphatically not what was requested", seen[1].after ~= 5000)
    SB.uninstall(S)
end

do
    -- M16 and M25. A closed frame accepts nothing further.
    -- SAID PLAINLY: the public API cannot produce a closed frame as the CURRENT
    -- frame, because close pops what it closes and unwinds what sits above it.
    -- This state is therefore built directly. That means these two assertions
    -- prove the guard holds, NOT that the situation arises in play. The guard is
    -- defence in depth against a future caller that reaches into the stack, and
    -- is worth keeping on those terms rather than on invented ones.
    local stack = C.new()
    local frame = C.open(stack, { id = "x" }, "PRIMITIVE")
    T.eq("E11 a live frame accepts observations", C.observe(stack, { n = 1 }), true)
    frame.closed = true
    T.eq("E12 a closed frame refuses them", C.observe(stack, { n = 2 }), false)
    T.eq("E13 and refuses published outputs too", C.publish(stack, { n = 3 }), false)
    T.eq("E14 nothing was appended", #frame.observations, 1)
end
