-- =========================================================
-- FS25_StockGuard - harvest capture (SG2-3a)
-- =========================================================
-- A standing crop becomes grain and straw in a combine's own buffers, and the grain
-- reaches the hopper later. SG-2 (:118-155) asks for each of those steps to be ONE
-- operation over what the native actually did, never a guess from the requested
-- amounts. This module brackets the three native places it happens:
--
--   THE CUT WITNESS. Cutter:processCutterArea (Cutter.lua:584-668, the CAPTURED
--   work-area pointer, mechanism 1) cuts per work area per frame and adds to the
--   cutter's lastMultiplierArea; Cutter:onEndWorkAreaProcessing (:770-840, a class
--   event, mechanism 3) hands the whole frame to the combine ONCE through
--   combine:addCutterArea. So the witness is per cutter per frame: one entry per
--   cutter call, weighed by what that call added to lastMultiplierArea AFTER every
--   wrapper on the pointer (SF's zone yield rescales a call's own delta). The weight
--   is read as the difference between successive entries' opening totals, the last
--   one closed by the total when the combine is called, so it is the post-chain
--   weight whichever wrapper sits outside the other.
--
--   THE CUT. Combine:addCutterArea (Combine.lua:956-1057, the INSTANCE copy called
--   as combine:addCutterArea, mechanism 2) puts straw into the input buffer's
--   current slot, then grain into the hopper, the buffer fill unit, or the first
--   free delay slot. That is ONE BIRTH: every place the call can put material is
--   captured beforehand (empty ones refreshed so SG-1 can capture them, SG-1 :277),
--   and after the call each one's actual gain is born from the witness entries by
--   their weights. Grain and straw each take the whole split: they are distinct
--   outputs of one cut, and neither copies the other's litres (SG-2 :150). The
--   bracket is observation only and changes no argument, so another mod's wrapper
--   in the same slot (SF's harvest hook, RSF-741's token) sees exactly what native
--   would have.
--
--   THE DRAINS. Combine:onUpdateTick (:407-488, a class event) moves a due delay
--   slot into the hopper (:463-471, the slot cleared BEFORE the hopper add), the
--   buffer fill unit into the hopper (:459-462), and rotates the straw input buffer
--   (:442-458). Each is a TRANSFER settled by SG2-1b's settleTransfer: the net of
--   each participant, a full hopper's refusal a LOSS leg (SG-2 :142). Grain and
--   straw are separate operations, so a leg never joins two materials.
--
--   THE SOURCE PORTIONS (SG2-3b). Inside a cutter call, each direct cutFruitArea call
--   is read by SGCutState (CUT_STATE_VOLUME_V1): the pixels that actually made their
--   harvest transition, grouped by growth state and Soil cell. An admitted call's
--   weight is split across those groups by w = pixels x yieldScale, each one KNOWN
--   portion with its state, count, scale and Soil snapshot; a call the profile could
--   not admit stays one UNKNOWN portion that says why (SG-2 :505-511).
--
-- NOT HERE (said on the PR): the save extension for delay and straw slots (SG2-3c);
-- the straw drop to ground or chopper (SG2-4, tipToGroundAroundLine); a pickup
-- cutter's ground material (no witness, so an UNKNOWN portion until SG2-4).

SGHarvestCapture = SGHarvestCapture or {}
local HC = SGHarvestCapture

HC.WITNESS_KEY = "_sgCutWitness"
HC.COMBINE_MARKER = "_sgCutBracket"
HC.CUT_FRAME = "COMBINE_CUT"
HC.DRAIN_FRAME = "COMBINE_DRAIN"
HC.PATH_CUT = "COMBINE_CUT"
HC.PATH_DRAIN = "COMBINE_DRAIN"
HC.PATH_STRAW = "COMBINE_STRAW_ROTATION"
HC.CLASS_MARKER = "_sgHarvestHooked"
HC.currentCutter = nil   -- the cutter whose end-of-processing is calling its combine
HC.activeEntry = nil     -- the witness entry of the cutter call now running (SG2-3b)

local function packn(...)
    return select("#", ...), { ... }
end

local function log(msg) print("[StockGuard] harvest: " .. tostring(msg)) end

-- ---------------------------------------------------------
-- The cut witness (cutter side)
-- ---------------------------------------------------------
local function cutterParams(cutter)
    local spec = type(cutter) == "table" and cutter.spec_cutter or nil
    return spec ~= nil and spec.workAreaParameters or nil
end

function HC.witnessOf(cutter)
    local w = rawget(cutter, HC.WITNESS_KEY)
    if w == nil then
        w = { calls = {} }
        rawset(cutter, HC.WITNESS_KEY, w)
    end
    return w
end

--- A new frame (Cutter:onStartWorkAreaProcessing resets lastMultiplierArea, :736-739):
--- whatever the last frame left unconsumed belongs to no combine call.
function HC.resetWitness(cutter)
    if type(cutter) == "table" and rawget(cutter, HC.WITNESS_KEY) ~= nil then
        rawset(cutter, HC.WITNESS_KEY, { calls = {} })
    end
end

--- The installer bracket's open: note the frame's running total as this call starts.
function HC.cutterOpen(cutter, workArea, _dt)
    local wp = cutterParams(cutter)
    if wp == nil or g_server == nil then return nil end
    local entry = { openTotal = tonumber(wp.lastMultiplierArea) or 0, workAreaIndex = workArea and workArea.index or nil,
                    previousActive = HC.activeEntry }
    local w = HC.witnessOf(cutter)
    w.calls[#w.calls + 1] = entry
    -- The cutFruitArea calls this cutter call makes record onto this entry.
    HC.activeEntry = entry
    return entry
end

--- The bracket's close: the fruit this call cut, if it cut any (Cutter.lua:634).
function HC.cutterClose(entry, ok, cutter, _workArea, _dt)
    if entry == nil then return end
    HC.activeEntry = entry.previousActive
    entry.previousActive = nil
    local wp = cutterParams(cutter)
    entry.ok = ok
    entry.fruitTypeIndex = wp ~= nil and wp.lastFruitType or nil
end

HC.cutterBracket = SGWorkAreaInstaller.bracketFactory(HC.cutterOpen, HC.cutterClose)

--- The frame's witness as weighted entries, consumed. An entry's weight is what its
--- call added to lastMultiplierArea after every wrapper: the next entry's opening
--- total (or the final total) minus its own.
function HC.takeWitness(cutter)
    local wp = cutterParams(cutter)
    local w = type(cutter) == "table" and rawget(cutter, HC.WITNESS_KEY) or nil
    if wp == nil or w == nil then return {}, 0 end
    local finalTotal = tonumber(wp.lastMultiplierArea) or 0
    local out, sum = {}, 0
    for i, entry in ipairs(w.calls) do
        local nextOpen = w.calls[i + 1] and w.calls[i + 1].openTotal or finalTotal
        local weight = nextOpen - entry.openTotal
        if entry.ok ~= false and weight > 0 then
            out[#out + 1] = { weight = weight, fruitTypeIndex = entry.fruitTypeIndex, workAreaIndex = entry.workAreaIndex, call = i,
                              cutStates = entry.cutStates }
            sum = sum + weight
        end
    end
    rawset(cutter, HC.WITNESS_KEY, { calls = {} })
    return out, sum
end

-- ---------------------------------------------------------
-- Where a cut can put material
-- ---------------------------------------------------------
--- The grain places addCutterArea chooses among (:1033-1053): the buffer fill unit
--- when it has room, else the hopper; with a loading delay, the first free delay
--- slot instead. All candidates are captured, so the settle reads which one actually
--- gained, rather than predicting it.
local function grainCandidates(combine)
    local spec = combine.spec_combine
    local list = {}
    local A = SGNativeAdapters
    local function unit(index)
        if index == nil then return end
        list[#list + 1] = { binding = A.fillUnitBindingFor(combine, index), kind = A.KIND_FILL_UNIT, vehicle = combine, fillUnitIndex = index }
    end
    unit(spec.fillUnitIndex)
    if spec.bufferFillUnitIndex ~= nil and spec.bufferFillUnitIndex ~= spec.fillUnitIndex then unit(spec.bufferFillUnitIndex) end
    if (tonumber(spec.loadingDelay) or 0) > 0 and type(spec.loadingDelaySlots) == "table" then
        for index, slot in ipairs(spec.loadingDelaySlots) do
            if not slot.valid then
                list[#list + 1] = { binding = A.combineSlotBinding(combine, A.KIND_DELAY_SLOT, index), kind = A.KIND_DELAY_SLOT, vehicle = combine, slotIndex = index }
                break
            end
        end
    end
    return list
end

--- The straw input buffer's current fill slot (:979).
local function strawCandidate(combine)
    local ib = combine.spec_combine.processing ~= nil and combine.spec_combine.processing.inputBuffer or nil
    if ib == nil or ib.fillIndex == nil then return nil end
    local A = SGNativeAdapters
    return { binding = A.combineSlotBinding(combine, A.KIND_STRAW_SLOT, ib.fillIndex), kind = A.KIND_STRAW_SLOT, vehicle = combine, slotIndex = ib.fillIndex }
end

--- Refresh a list of candidate carriers; unlike a transfer, a candidate that cannot
--- be bound (a straw slot for a fruit with no loose straw, say) is left out rather
--- than failing the whole cut: its gain then reaches SG-1 per side.
local function bindCandidates(host, list)
    local out = {}
    for _, p in ipairs(list) do
        if p.binding ~= nil and host.nativeLease ~= nil then
            local c = host.handle.refreshCarrier(host.nativeLease, p.binding, SGNativeHost.REASON)
            if c ~= nil then
                p.carrierId = SGRecords.carrierKeyString(p.binding.carrierKey)
                out[#out + 1] = p
            end
        end
    end
    return out
end

-- ---------------------------------------------------------
-- The cut (combine side)
-- ---------------------------------------------------------
--- Before the native addCutterArea. Returns the frame, or nil when this cut is not
--- carried (a client, no live host, no cutter in the stack).
function HC.cutOpen(host, combine, area, liters, inputFruitType, outputFillType)
    if not host.ready or host.nativeLease == nil or g_server == nil or not combine.isServer then return nil end
    if combine.spec_combine == nil then return nil end
    local cutter = HC.currentCutter
    local entries, sum = {}, 0
    if cutter ~= nil then entries, sum = HC.takeWitness(cutter) end

    local grain = bindCandidates(host, grainCandidates(combine))
    local strawList = {}
    local s = strawCandidate(combine)
    if s ~= nil then strawList[1] = s end
    local straw = bindCandidates(host, strawList)
    if #grain == 0 and #straw == 0 then return nil end

    host.nextCut = (host.nextCut or 0) + 1
    local callRef = "cut:" .. tostring(host.epoch) .. ":" .. tostring(host.nextCut)
    local owner = SGNativeAdapters.persistentIdOf(cutter or combine) or "?"
    -- The birth slots: per witnessed call, its CUT_STATE_VOLUME_V1 groups when the
    -- profile admitted the call, else one UNKNOWN slot saying why; with no witness at
    -- all, one UNKNOWN slot.
    local portions = {}
    if sum > 0 then
        for i, e in ipairs(entries) do
            local creator = "cutter:" .. owner .. ":" .. tostring(e.workAreaIndex)
            local cs = e.cutStates ~= nil and #e.cutStates == 1 and e.cutStates[1] or nil
            if cs ~= nil and cs.admitted == true and (cs.weightSum or 0) > 0 then
                for k, grp in ipairs(cs.groups) do
                    portions[#portions + 1] = { slotId = callRef .. ":w" .. i .. ":p" .. k, nativeCreatorKey = creator,
                        weight = e.weight * grp.weight / cs.weightSum, fruitTypeIndex = cs.fruitIndex, knowledge = "KNOWN", reason = nil,
                        profile = SGCutState ~= nil and SGCutState.PROFILE or nil, growthState = grp.state, pixels = grp.pixels,
                        yieldScale = grp.yieldScale, soilCell = grp.cell, soil = grp.soil }
                end
            else
                local reason = "CUT_STATE_NOT_OBSERVED"
                if cs ~= nil and cs.reason ~= nil then reason = cs.reason
                elseif e.cutStates ~= nil and #e.cutStates > 1 then reason = "CUT_STATE_SEVERAL_CALLS" end
                portions[#portions + 1] = { slotId = callRef .. ":w" .. i, nativeCreatorKey = creator,
                    weight = e.weight, fruitTypeIndex = e.fruitTypeIndex, knowledge = "UNKNOWN", reason = reason }
            end
        end
    else
        portions[1] = { slotId = callRef .. ":unknown", nativeCreatorKey = "cutter:" .. owner, weight = 1, knowledge = "UNKNOWN",
            reason = cutter == nil and "NO_CUTTER" or "NO_WITNESS" }
        sum = 1
    end

    local captureList, participants = {}, {}
    for _, p in ipairs(portions) do captureList[#captureList + 1] = { slotId = p.slotId, nativeCreatorKey = p.nativeCreatorKey } end
    for _, p in ipairs(grain) do captureList[#captureList + 1] = { carrierId = p.carrierId } participants[p.carrierId] = p end
    for _, p in ipairs(straw) do captureList[#captureList + 1] = { carrierId = p.carrierId } participants[p.carrierId] = p end

    local frame = SGOperationContext.open(host.context, combine, HC.CUT_FRAME)
    if frame == nil then return nil end
    local cap, why = host.handle.captureOperation(host.nativeLease, "BIRTH", captureList)
    frame.cut = {
        capture = cap, captureFailure = why, participants = participants, portions = portions, weightSum = sum,
        grain = grain, straw = straw, callRef = callRef,
        args = { area = area, liters = liters, inputFruitType = inputFruitType, outputFillType = outputFillType },
    }
    return frame
end

--- Read every participant's state now, as SG-1 reads carriers; nil if any is unreadable.
local function readAfter(host, participants)
    local spec = host.nativeLease ~= nil and host.nativeLease.spec or nil
    local after = {}
    for cid, p in pairs(participants) do
        local native = spec ~= nil and spec.resolveCarrier(p.binding) or nil
        local ns = native ~= nil and spec.readNativeState(p.binding, native) or nil
        if ns == nil then return nil end
        after[cid] = ns
    end
    return after
end

--- After the native addCutterArea: settle the BIRTH from what each place gained.
function HC.cutClose(host, frame, ok, returned)
    if frame == nil then return end
    SGOperationContext.close(host.context, frame)
    local t = frame.cut
    local consumed = {}
    if t ~= nil and t.capture ~= nil then
        local after = readAfter(host, t.participants)
        if not ok or after == nil then
            local reason = not ok and "NATIVE_ERROR" or "AFTER_STATE_UNREADABLE"
            host.lastHarvest = { callRef = t.callRef, outcome = "ABANDONED", reason = reason }
            host.handle.abandonOperation(t.capture.handle, reason, after)
        else
            local before = t.capture.before and t.capture.before.carriers or {}
            local allocations, grainBorn, strawBorn = {}, 0, 0
            local function bear(list, tally)
                local born = 0
                for _, p in ipairs(list) do
                    local b = before[p.carrierId]
                    local gained = (after[p.carrierId].amount or 0) - (b ~= nil and b.amount or 0)
                    if gained > SGNativeHost.TRANSFER_EPSILON then
                        born = born + gained
                        for _, portion in ipairs(t.portions) do
                            local amount = gained * portion.weight / t.weightSum
                            if amount > SGNativeHost.TRANSFER_EPSILON then
                                allocations[#allocations + 1] = {
                                    source = { slotId = portion.slotId }, sourceAmount = amount, sourceUnit = SGNativeAdapters.UNIT,
                                    destination = { carrierId = p.carrierId }, destinationAmount = amount, destinationUnit = SGNativeAdapters.UNIT,
                                    result = "BORN", reason = portion.reason,
                                }
                            end
                        end
                    end
                end
                return born
            end
            grainBorn = bear(t.grain, "grain")
            strawBorn = bear(t.straw, "straw")
            local evidencePortions = {}
            for _, portion in ipairs(t.portions) do
                evidencePortions[#evidencePortions + 1] = { slotId = portion.slotId, weight = portion.weight, fruitTypeIndex = portion.fruitTypeIndex,
                    knowledge = portion.knowledge, reason = portion.reason, profile = portion.profile, growthState = portion.growthState,
                    pixels = portion.pixels, yieldScale = portion.yieldScale, soilCell = portion.soilCell, soil = portion.soil }
            end
            local report = {
                participantsAfter = after,
                allocations = allocations,
                outcomeEvidence = { nativePath = HC.PATH_CUT, callRef = t.callRef, area = t.args.area, liters = t.args.liters,
                    inputFruitType = t.args.inputFruitType, outputFillType = t.args.outputFillType, returned = returned,
                    grainBorn = grainBorn, strawBorn = strawBorn, weightSum = t.weightSum, portions = evidencePortions },
            }
            local outcome, reason = host.handle.settleOperation(t.capture.handle, report)
            host.lastHarvest = { callRef = t.callRef, outcome = outcome, reason = reason, report = report }
            if outcome == "COMMITTED" or outcome == "NO_OP" then
                for _, obs in ipairs(frame.observations) do
                    if obs.source == "FILL_UNIT" and obs.vehicle == frame.binding then
                        for _, p in pairs(t.participants) do
                            if p.kind == SGNativeAdapters.KIND_FILL_UNIT and p.fillUnitIndex == obs.fillUnitIndex then consumed[obs] = true break end
                        end
                    end
                end
            end
        end
    end
    for _, obs in ipairs(frame.observations) do
        if not consumed[obs] then host:replayObservation(obs) end
    end
end

--- Wrap one combine's addCutterArea INSTANCE slot, whatever it holds (native, or
--- another mod's wrapper: this bracket only observes). Idempotent per vehicle.
function HC.installCombine(vehicle)
    if g_server == nil or type(vehicle) ~= "table" or vehicle.spec_combine == nil then return false end
    if rawget(vehicle, HC.COMBINE_MARKER) ~= nil then return false end
    local raw = vehicle.addCutterArea
    if type(raw) ~= "function" then return false end
    local wrapper = function(self, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad, ...)
        local host = SGNativeHost.current
        local frame = nil
        if host ~= nil then
            local okOpen, result = pcall(HC.cutOpen, host, self, area, liters, inputFruitType, outputFillType)
            if okOpen then frame = result else log("cut open failed (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(raw, self, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad, ...))
        if frame ~= nil then
            local okClose, err = pcall(HC.cutClose, host, frame, r[1], r[2])
            if not okClose then log("cut close failed (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    rawset(vehicle, "addCutterArea", wrapper)
    rawset(vehicle, HC.COMBINE_MARKER, { raw = raw, wrapper = wrapper })
    return true
end

function HC.isCombineBracketed(vehicle)
    local rec = type(vehicle) == "table" and rawget(vehicle, HC.COMBINE_MARKER) or nil
    return rec ~= nil and vehicle.addCutterArea == rec.wrapper
end

--- Everything one vehicle needs: the cut witness on each captured cutter pointer,
--- and the cut bracket on a combine.
function HC.observeVehicle(vehicle)
    local n = 0
    if type(vehicle) ~= "table" then return 0 end
    if vehicle.spec_cutter ~= nil then
        n = n + SGWorkAreaInstaller.install(vehicle, "spec_cutter", "processCutterArea", HC.cutterBracket)
    end
    if HC.installCombine(vehicle) then n = n + 1 end
    return n
end

-- ---------------------------------------------------------
-- The drains (Combine:onUpdateTick)
-- ---------------------------------------------------------
--- Before the native tick: capture the grain drain (the delay slots due this tick and
--- a draining buffer fill unit, into the hopper) and, when the straw buffer is about to
--- rotate (:442-458), its slots, as two TRANSFERs. Nothing to drain opens nothing.
---
--- ONLY WHAT DRAINS THIS TICK. A two-second loading delay is 121 slots (:520), nearly
--- all valid while harvesting; capturing every one every tick would cost a refresh and
--- a read each for slots native leaves untouched. The participants are chosen by
--- native's own conditions, read not changed: a slot is due when slot.time plus the
--- loading delay is past the mission time (:468), the buffer drains once the cutters
--- have been idle ten ticks and it holds material (:459). A slot native drains that
--- this reading missed is not lost: its gain reaches the hopper's record as
--- unexplained, and the slot is read fresh at its next capture.
function HC.drainOpen(host, combine, dt)
    if not host.ready or host.nativeLease == nil or g_server == nil or not combine.isServer then return nil end
    local spec = combine.spec_combine
    if spec == nil then return nil end
    local A = SGNativeAdapters
    local now = g_currentMission ~= nil and tonumber(g_currentMission.time) or nil
    local grain = {}
    if now ~= nil and (tonumber(spec.loadingDelay) or 0) > 0 and type(spec.loadingDelaySlots) == "table" then
        for index, slot in ipairs(spec.loadingDelaySlots) do
            if slot.valid and type(slot.time) == "number" and slot.time + spec.loadingDelay < now then
                grain[#grain + 1] = { binding = A.combineSlotBinding(combine, A.KIND_DELAY_SLOT, index), kind = A.KIND_DELAY_SLOT, vehicle = combine, slotIndex = index }
            end
        end
    end
    if now ~= nil and spec.bufferFillUnitIndex ~= nil and type(combine.getFillUnitFillLevel) == "function"
       and type(spec.lastCuttersAreaTime) == "number" and spec.lastCuttersAreaTime + (dt or 0) * 10 < now then
        local okB, level = pcall(combine.getFillUnitFillLevel, combine, spec.bufferFillUnitIndex)
        if okB and type(level) == "number" and level > 0 then
            grain[#grain + 1] = { binding = A.fillUnitBindingFor(combine, spec.bufferFillUnitIndex), kind = A.KIND_FILL_UNIT, vehicle = combine, fillUnitIndex = spec.bufferFillUnitIndex }
        end
    end
    local straw = {}
    local ib = spec.processing ~= nil and spec.processing.inputBuffer or nil
    if ib ~= nil and type(ib.buffer) == "table" and type(ib.slotTimer) == "number" and ib.slotTimer - (dt or 0) < 0 then
        for index, slot in ipairs(ib.buffer) do
            if (tonumber(slot.liters) or 0) > 0 or index == ib.dropIndex % #ib.buffer + 1 then
                straw[#straw + 1] = { binding = A.combineSlotBinding(combine, A.KIND_STRAW_SLOT, index), kind = A.KIND_STRAW_SLOT, vehicle = combine, slotIndex = index }
            end
        end
    end
    if #grain == 0 and #straw == 0 then return nil end
    if #grain > 0 then
        grain[#grain + 1] = { binding = A.fillUnitBindingFor(combine, spec.fillUnitIndex), kind = A.KIND_FILL_UNIT, vehicle = combine, fillUnitIndex = spec.fillUnitIndex }
    end

    local frame = SGOperationContext.open(host.context, combine, HC.DRAIN_FRAME)
    if frame == nil then return nil end
    frame.drains = {}
    local function capture(list, path)
        if #list == 0 then return end
        local participants, captureList = host:transferParticipants(list)
        if participants == nil then return end
        host.nextTransfer = host.nextTransfer + 1
        local cap, why = host.handle.captureOperation(host.nativeLease, "TRANSFER", captureList)
        frame.drains[#frame.drains + 1] = { capture = cap, captureFailure = why, participants = participants, nativePath = path,
            callRef = "drain:" .. tostring(host.epoch) .. ":" .. tostring(host.nextTransfer) }
    end
    capture(grain, HC.PATH_DRAIN)
    capture(straw, HC.PATH_STRAW)
    return frame
end

function HC.drainClose(host, frame, ok)
    if frame == nil then return end
    SGOperationContext.close(host.context, frame)
    local consumed = {}
    for _, t in ipairs(frame.drains or {}) do
        local c = host:settleTransfer(frame, ok, t)
        host.lastDrain = host.lastSettlement
        for obs in pairs(c or {}) do consumed[obs] = true end
    end
    for _, obs in ipairs(frame.observations) do
        if not consumed[obs] then host:replayObservation(obs) end
    end
end

-- ---------------------------------------------------------
-- Process-wide class hooks (mechanism 3: raised through the spec class at call time)
-- ---------------------------------------------------------
local function wrapWithSelf(class, name, around)
    if type(class) ~= "table" or type(class[name]) ~= "function" then return false end
    local marks = rawget(class, HC.CLASS_MARKER) or {}
    rawset(class, HC.CLASS_MARKER, marks)
    if marks[name] ~= nil then return false end
    local original = class[name]
    local wrapper = function(self, ...) return around(original, self, ...) end
    class[name] = wrapper
    marks[name] = { original = original, wrapper = wrapper }
    return true
end

--- Install once per process. Cutter and Combine are injected so the bench runs these
--- wrappers against its own engine model.
function HC.installClassHooks(classes)
    if g_server == nil then return false end
    classes = classes or {}
    -- SG2-3b: the source portions of each direct cut (mechanism 4, a table function).
    if SGCutState ~= nil and classes.FSDensityMapUtil ~= nil then SGCutState.installOn(classes.FSDensityMapUtil) end
    -- A new cutter frame starts a new witness (Cutter.lua:729-768).
    wrapWithSelf(classes.Cutter, "onStartWorkAreaProcessing", function(original, self, ...)
        HC.resetWitness(self)
        return original(self, ...)
    end)
    -- The cutter's end hands its frame to the combine (:770-840): name the cutter for
    -- the combine bracket for exactly the length of that call.
    wrapWithSelf(classes.Cutter, "onEndWorkAreaProcessing", function(original, self, ...)
        local previous = HC.currentCutter
        HC.currentCutter = self
        local n, r = packn(pcall(original, self, ...))
        HC.currentCutter = previous
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end)
    -- The drains (Combine.lua:407-488).
    wrapWithSelf(classes.Combine, "onUpdateTick", function(original, self, dt, ...)
        local host = SGNativeHost.current
        local frame = nil
        if host ~= nil then
            local okOpen, result = pcall(HC.drainOpen, host, self, dt)
            if okOpen then frame = result else log("drain open failed (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(original, self, dt, ...))
        if frame ~= nil then
            local okClose, err = pcall(HC.drainClose, host, frame, r[1])
            if not okClose then log("drain close failed (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end)
    return true
end
