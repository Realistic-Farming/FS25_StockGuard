-- =========================================================
-- FS25_StockGuard - the non-stop Baler's buffer overload (SG2 non-stop framing)
-- =========================================================
-- SG-2 v2.3 :471 ("The main chamber, non-stop buffer and native fillUnitOverflowFillLevel are distinct
-- actual representations"), with :181, :183, :249, :469 and :477, and RSF-F211 :76, :88, :94, :96, :100
-- and :153, on Bob's intake (Desk Office/Drafts/BOB-INTAKE-SG2-NONSTOP-BALER-FRAMING-2026-10-09.md, PR 2).
--
-- The pickup into the buffer is SGGroundObserver's: balerFramed admits a non-stop Baler while this module
-- is loaded, and the pickup tick's add settles on whichever unit native chose (Baler.lua:1979-1987). This
-- file holds what the pickup tick cannot see: the overload, Baler:onUpdateTick moving the buffer into the
-- main chamber (:996-1062), and the pad marker.
--
-- THE SCOPE. SGGroundObserver.balerUpdateTick opens it, outermost, around the class original for a framed
-- non-stop Baler on the server whose buffer holds anything (the overload's own outer test, :997-998; no
-- other part of the engine's start test is re-derived). It is a ground frame with no unit, so every report
-- inside it is held and, unless the overload settles it, replays at its close: outside the overload the
-- tick behaves as before (C3). The buffer's and the chamber's records are read first when dirty.
--
-- THE ARM. The overload's buffer debit (:1017) reports a negative accepted delta on the buffer unit, after
-- its listener. That report arms the scope, Ub being its accepted litres, unless a pad is running (below).
-- The additive debit at overload (:1040) is the additive unit's generic decrease and replays at the close
-- (SG-2 :249, C3). Native moves at most once per tick, so the scope arms at most once.
--
-- THE OVERLOAD (F211 :100, :94). The main add (:1052) reaches the Baler's fill listener, wrapped by
-- SGGroundObserver's balerFill. BEFORE the original listener, which may finish a bale, ONE TRANSFER
-- (M.settleOverload): the buffer's accepted debit Ub, whole, is its source; its destinations are the
-- chamber at the event's A and the transient (the balerPickup carrier, one per Baler) at D - A, D being the
-- add's request, the overloaded litres after any gain. The sources split Ub x A / D and Ub x (D - A) / D.
-- The gain (D above Ub, appliedByBufferOverloading) is declared in the evidence (nativeGain), with no
-- basis: Soil's combine scales the buffer record's account to the destination litres, so the chamber's
-- percent is the buffer's ("the native output gain retains that condition"). A main add of a type other
-- than the buffer's record (:1018-1021: the main's type wins), or into a chamber holding another type, is
-- COALESCE_UNPROVED: abandoned against the actual after-states, the material unknown (SG-2 :181).
--
-- AFTER THE ORIGINAL (M.afterOverload). The full branch (:1170-1177): an old overflow it overwrote is
-- retired first as LOSS (F211 :96); then the overflow O, read from spec.fillUnitOverflowFillLevel after
-- it (never D - A), is a TRANSFER transient to balerOverflow. Not full with an old overflow: the nested
-- re-add (:1178-1182) settles inside the original as SGGroundObserver.balerSettleReAdd does under a pickup
-- tick, under this scope instead. What the transient still holds is LOSS "only when the completed native
-- path actually discarded them" (F211 :100): a refused or short main add, never an overflow assignment.
-- Then the transient is withdrawn.
--
-- THE PAD MARKER. The partial-bale pad (setIsUnloadingBale, :1324-1347) debits the buffer and adds to the
-- chamber, and can run inside onUpdateTick (the automatic unload, :960). An instance-copy wrap of
-- setIsUnloadingBale (a registered function, :155), installed with the finish wraps on a non-stop Baler,
-- marks it; inside it nothing arms. Until 5e-d the pad's buffer debit reconciles as an unexplained
-- decrease, its add logs through balerPadOutsideTick, and the partial bale carries no StockGuard record
-- (SG-2 :475).
--
-- THE HANDOVER. The tick that drops a round bale runs no overload (:929 sets unloadingStarted false, and a
-- start needs UNLOADING_CLOSED), so 5e-c's REBIND frame never meets one; it closes inside this scope.
--
-- No save field: the buffer is a native saved fill unit with its own SG-1 record, and a non-stop overflow
-- saves through 5e-a's participant. Server only: balerFramed needs vehicle.isServer.

SGBalerNonStop = SGBalerNonStop or {}
local M = SGBalerNonStop
local A = SGNativeAdapters

M.OVERLOAD = "BALER_OVERLOAD"
M.scopes = M.scopes or setmetatable({}, { __mode = "k" })     -- vehicle -> its open overload scope
M.padDepth = M.padDepth or setmetatable({}, { __mode = "k" })  -- vehicle -> setIsUnloadingBale nesting

local function packn(...) return select("#", ...), { ... } end
local function count(t, key)
    key = tostring(key)
    t[key] = (t[key] or 0) + 1
end
local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function fillTypeNameOf(index)
    if index == nil or g_fillTypeManager == nil then return nil end
    local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, index)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

--- A fill unit's binding and carrier id.
local function unitOf(vehicle, index)
    if type(index) ~= "number" then return nil end
    local binding = A.fillUnitBindingFor(vehicle, index)
    if binding == nil then return nil end
    return binding, SGRecords.carrierKeyString(binding.carrierKey)
end

--- The native state of a carrier, read now.
local function unitState(host, binding)
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(binding)
    return native ~= nil and spec.readNativeState(binding, native) or nil
end

local function beforeOf(cap, cid) return cap.before.carriers[cid] end

local function levelOf(vehicle, index)
    if type(index) ~= "number" or type(vehicle.getFillUnitFillLevel) ~= "function" then return nil end
    local ok, l = pcall(vehicle.getFillUnitFillLevel, vehicle, index)
    return ok and finite(l) and l or nil
end

--- One settled (or abandoned) operation into the scope's record.
local function record(host, ov, result)
    ov.operations[#ov.operations + 1] = result
    host.lastSettlement = { callRef = result.callRef, outcome = result.outcome, reason = result.reason, report = result.report or { outcomeEvidence = result.evidence } }
end

--- The buffer's fill unit index of a non-stop Baler, or nil.
function M.bufferIndex(vehicle)
    local spec = type(vehicle) == "table" and vehicle.spec_baler or nil
    if type(spec) ~= "table" or spec.nonStopBaling ~= true or type(spec.buffer) ~= "table" then return nil end
    local index = spec.buffer.fillUnitIndex
    return type(index) == "number" and index or nil
end

--- This Baler's open overload scope, or nil.
function M.scopeOf(vehicle)
    local ov = M.scopes[vehicle]
    if ov ~= nil and ov.frame ~= nil and not ov.frame.closed then return ov end
    return nil
end

--- Is one of this Baler's setIsUnloadingBale calls running?
function M.inPad(vehicle) return (M.padDepth[vehicle] or 0) > 0 end

--- Open the scope around Baler:onUpdateTick's original, or nil to let the tick pass as before.
function M.open(host, vehicle)
    local G = SGGroundObserver
    if host == nil or not host.ready or host.nativeLease == nil or G == nil or not G.balerFramed(vehicle) then return nil end
    local index = M.bufferIndex(vehicle)
    if index == nil then return nil end
    local level = levelOf(vehicle, index)
    if level == nil or level <= 0 then return nil end
    local spec = vehicle.spec_baler
    local _, mainId = unitOf(vehicle, spec.fillUnitIndex)
    local _, bufferId = unitOf(vehicle, index)
    if mainId == nil or bufferId == nil then return nil end
    -- The capture reads SG-1's records, so a dirty one is read first, as the live finish does.
    for _, cid in ipairs({ bufferId, mainId }) do
        if host.dirty[cid] ~= nil then
            host.dirty[cid] = nil
            host.handle.observeCarrier(host.nativeLease, cid, nil)
        end
    end
    local ov = { host = host, vehicle = vehicle, bufferIndex = index, armed = false, addArmed = false, settled = false,
                 expected = {}, refused = {}, operations = {} }
    local frame = G.openFrame(host, vehicle, { kind = M.OVERLOAD, units = {}, overload = ov })
    if frame == nil then return nil end
    ov.frame, ov.callRef = frame, frame.ground.callRef
    M.scopes[vehicle] = ov
    return ov
end

--- A fill-unit report inside the scope (SGGroundObserver.onUnitObserved). The overload's buffer debit
--- arms it; the chamber's report of a settled add or re-add is consumed when its accepted delta is the
--- event's A (C2); everything else replays at the close (C3).
function M.observe(host, gf, obs)
    local ov = gf.overload
    if ov == nil or obs.vehicle ~= ov.vehicle or type(obs.accepted) ~= "number" then return end
    local G = SGGroundObserver
    if obs.fillUnitIndex == ov.bufferIndex then
        if obs.accepted < -G.EPSILON and not ov.armed and not M.inPad(ov.vehicle) then
            ov.armed, ov.addArmed, ov.bufferDebit, ov.bufferObs = true, true, -obs.accepted, obs
        end
        return
    end
    if obs.fillUnitIndex == ov.vehicle.spec_baler.fillUnitIndex and G.balerConsume(ov, obs) then obs.groundConsumed = true end
end

--- The transient: the balerPickup carrier, bound empty. A stale pickup tick (one a throw left open)
--- holds the same carrier, so it is closed first, as the Baler's next onStart would close it.
local function bindTransient(host, ov, name)
    local G = SGGroundObserver
    local stale = G.balerTicks[ov.vehicle]
    if stale ~= nil then G.balerTickClose(host, stale, "BALER_TICK_ABANDONED") end
    local binding = A.balerPickupBinding(ov.vehicle)
    if binding == nil then return nil, "PICKUP_BINDING" end
    local cid = SGRecords.carrierKeyString(binding.carrierKey)
    local live = { vehicle = ov.vehicle, amount = 0, fillTypeName = name }
    A.balerPickups[cid] = live
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(binding)
    local ns = native ~= nil and spec.readNativeState(binding, native) or nil
    local c, why = nil, "PICKUP_STATE"
    if ns ~= nil then c, why = host.handle.bindCarrier(host.nativeLease, binding, ns) end
    if c == nil then
        A.balerPickups[cid] = nil
        return nil, why
    end
    ov.transient = { binding = binding, carrierId = cid, live = live }
    return ov.transient
end

--- The overload's main add, before the original listener (F211 :94): ONE TRANSFER of the buffer's
--- accepted debit to the chamber at A and to the transient at D - A.
function M.settleOverload(host, ov, fillTypeIndex, D, Aapplied)
    local G = SGGroundObserver
    ov.addArmed = false
    local vehicle = ov.vehicle
    local spec = vehicle.spec_baler
    local Ub = ov.bufferDebit
    if not finite(D) or D <= G.EPSILON or not finite(Aapplied) or Aapplied < 0 or not finite(Ub) or Ub <= G.EPSILON then
        count(ov.refused, "OVERLOAD_AMOUNTS")
        return
    end
    local mainBinding, mainId = unitOf(vehicle, spec.fillUnitIndex)
    local bufferBinding, bufferId = unitOf(vehicle, ov.bufferIndex)
    if mainBinding == nil or bufferBinding == nil then count(ov.refused, "OVERLOAD_BINDING") return end
    local name = fillTypeNameOf(fillTypeIndex)
    local t, whyT = bindTransient(host, ov, name)
    if t == nil then count(ov.refused, "TRANSIENT_BIND:" .. tostring(whyT)) return end
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "TRANSFER",
        { { carrierId = bufferId }, { carrierId = mainId }, { carrierId = t.carrierId } })
    if cap == nil then count(ov.refused, "OVERLOAD_CAPTURE:" .. tostring(whyC)) return end
    local bb, mb = beforeOf(cap, bufferId), beforeOf(cap, mainId)
    local bufferName = bb ~= nil and bb.materialRef ~= nil and bb.materialRef.fillTypeName or nil
    local spill = math.max(0, D - Aapplied)
    t.live.amount = spill
    ov.fillTypeName = name
    local after = { [bufferId] = unitState(host, bufferBinding), [mainId] = unitState(host, mainBinding), [t.carrierId] = unitState(host, t.binding) }
    local evidence = { nativePath = "GROUND_BALER_OVERLOAD", callRef = ov.callRef .. ":overload", fillTypeName = name, bufferDebit = Ub,
                       requestedAmount = D, appliedAmount = Aapplied, nativeGain = { source = Ub, destination = D, factor = D / Ub } }
    -- This operation's own reports: the buffer debit that armed it, and the chamber add's (C2).
    ov.settled = true
    if ov.bufferObs ~= nil then ov.bufferObs.groundConsumed = true end
    ov.expected[#ov.expected + 1] = { fillUnitIndex = spec.fillUnitIndex, accepted = Aapplied }
    local held = mb ~= nil and mb.amount > G.EPSILON and mb.materialRef ~= nil and mb.materialRef.fillTypeName ~= name
    if name == nil or bufferName == nil or name ~= bufferName or held then
        host.handle.abandonOperation(cap.handle, G.BALER_COALESCE, after)
        record(host, ov, { callRef = evidence.callRef, outcome = "ABANDONED", reason = G.BALER_COALESCE, evidence = evidence })
        return
    end
    local legs = {}
    if Aapplied > G.EPSILON then
        legs[#legs + 1] = { source = { carrierId = bufferId }, sourceAmount = Ub * Aapplied / D, sourceUnit = A.UNIT,
                            destination = { carrierId = mainId }, destinationAmount = Aapplied, destinationUnit = A.UNIT, result = "TRANSFERRED" }
    end
    if spill > G.EPSILON then
        legs[#legs + 1] = { source = { carrierId = bufferId }, sourceAmount = Ub * spill / D, sourceUnit = A.UNIT,
                            destination = { carrierId = t.carrierId }, destinationAmount = spill, destinationUnit = A.UNIT, result = "TRANSFERRED" }
    end
    local report = { participantsAfter = after, allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    record(host, ov, { callRef = evidence.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report })
end

--- The full branch's overflow (:1175), read after the original: an old overflow it overwrote is retired
--- first as LOSS (F211 :96), then O is a TRANSFER transient to balerOverflow.
function M.settleOverflow(host, ov)
    local G = SGGroundObserver
    local vehicle = ov.vehicle
    local O = vehicle.spec_baler.fillUnitOverflowFillLevel
    local obinding = A.balerOverflowBinding(vehicle)
    if obinding == nil then return end
    local oid = SGRecords.carrierKeyString(obinding.carrierKey)
    if A.balerOverflows[oid] ~= nil then
        local outcome, reason, report = G.balerRetireOverflow(host, vehicle, oid, "BALER_OVERFLOW_OVERWRITTEN", "LOSS", { callRef = ov.callRef .. ":overwritten" })
        record(host, ov, { callRef = ov.callRef .. ":overwritten", outcome = outcome, reason = reason, evidence = report and report.outcomeEvidence, report = report })
        pcall(host.handle.withdrawCarrier, host.nativeLease, oid, "BALER_OVERFLOW_OVERWRITTEN")
        A.balerOverflows[oid] = nil
    end
    local t = ov.transient
    if not finite(O) or O <= G.EPSILON or t == nil or t.live.amount <= G.EPSILON then return end
    local src = math.min(t.live.amount, O)
    A.balerOverflows[oid] = { vehicle = vehicle, producedAs = ov.fillTypeName }
    local c, whyB = host.handle.bindCarrier(host.nativeLease, obinding, A.balerOverflowState(vehicle, 0))
    if c == nil then A.balerOverflows[oid] = nil count(ov.refused, "OVERFLOW_BIND:" .. tostring(whyB)) return end
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "TRANSFER", { { carrierId = t.carrierId }, { carrierId = oid } })
    if cap == nil then count(ov.refused, "OVERFLOW_CAPTURE:" .. tostring(whyC)) return end
    t.live.amount = math.max(0, t.live.amount - src)
    local evidence = { nativePath = "GROUND_BALER_OVERLOAD_OVERFLOW", callRef = ov.callRef .. ":overflow", fillTypeName = ov.fillTypeName, overflowAmount = O }
    local legs = { { source = { carrierId = t.carrierId }, sourceAmount = src, sourceUnit = A.UNIT,
                     destination = { carrierId = oid }, destinationAmount = O, destinationUnit = A.UNIT, result = "TRANSFERRED" } }
    local report = { participantsAfter = { [t.carrierId] = unitState(host, t.binding), [oid] = A.balerOverflowState(vehicle, O) },
                     allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    record(host, ov, { callRef = evidence.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report })
end

--- What the transient still holds is native loss (F211 :100); then it is withdrawn.
function M.releaseTransient(host, ov, reason)
    local t = ov.transient
    if t == nil then return end
    ov.transient = nil
    local remainder = t.live.amount or 0
    if remainder > SGGroundObserver.EPSILON then
        local cap, why = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = t.carrierId } })
        if cap ~= nil then
            t.live.amount = 0
            local evidence = { nativePath = "GROUND_BALER_OVERLOAD_REMAINDER", callRef = ov.callRef .. ":remainder", fillTypeName = ov.fillTypeName,
                               remainder = remainder, loss = remainder }
            local report = { participantsAfter = { [t.carrierId] = unitState(host, t.binding) }, outcomeEvidence = evidence,
                             allocations = { { source = { carrierId = t.carrierId }, sourceAmount = remainder, sourceUnit = A.UNIT,
                                               destination = { retire = true }, result = "LOSS", reason = reason } } }
            local outcome, reasonOut = host.handle.settleOperation(cap.handle, report)
            record(host, ov, { callRef = evidence.callRef, outcome = outcome, reason = reasonOut, evidence = evidence, report = report })
        else
            count(ov.refused, "REMAINDER_CAPTURE:" .. tostring(why))
        end
    end
    pcall(host.handle.withdrawCarrier, host.nativeLease, t.carrierId, "BALER_OVERLOAD_CLOSED")
    if A.balerPickups[t.carrierId] == t.live then A.balerPickups[t.carrierId] = nil end
end

--- After the main add's original listener: the full branch's overflow, then the transient's remainder.
function M.afterOverload(host, ov, wasFull)
    if not ov.settled or ov.transient == nil then return end
    if wasFull then M.settleOverflow(host, ov) end
    M.releaseTransient(host, ov, "BALER_OVERLOAD_REMAINDER")
end

--- The scope's close, after the class original, thrown or not: a transient still bound is released, an
--- overflow the scope's re-add emptied is withdrawn, then the frame closes and replays what it held.
function M.close(host, ov, ok)
    local G = SGGroundObserver
    if M.scopes[ov.vehicle] == ov then M.scopes[ov.vehicle] = nil end
    if ov.armed and not ov.settled then count(ov.refused, "OVERLOAD_UNSETTLED") end
    M.releaseTransient(host, ov, ok and "BALER_OVERLOAD_REMAINDER" or "BALER_OVERLOAD_ABANDONED")
    local obinding = A.balerOverflowBinding(ov.vehicle)
    local oid = obinding ~= nil and SGRecords.carrierKeyString(obinding.carrierKey) or nil
    if ov.settled and oid ~= nil and A.balerOverflows[oid] ~= nil then
        local spec = ov.vehicle.spec_baler
        if type(spec) == "table" and (spec.fillUnitOverflowFillLevel or 0) <= 0 then
            host.handle.refreshCarrier(host.nativeLease, obinding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)
            pcall(host.handle.withdrawCarrier, host.nativeLease, oid, "BALER_OVERFLOW_EMPTY")
            A.balerOverflows[oid] = nil
        end
    end
    G.closeFrame(host, ov.frame, ok)
    host.lastBalerOverload = ov
end

--- setIsUnloadingBale (instance copy, a non-stop Baler's): the pad marker. Nothing arms inside it.
function M.aroundUnloading(original, vehicle, ...)
    M.padDepth[vehicle] = (M.padDepth[vehicle] or 0) + 1
    local n, r = packn(pcall(original, vehicle, ...))
    local d = (M.padDepth[vehicle] or 1) - 1
    M.padDepth[vehicle] = d > 0 and d or nil
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end
