-- =========================================================
-- FS25_StockGuard - material store, observed operations, property settlement
-- and server reads (SG-1 4.4)
-- =========================================================
-- One authoritative material record writer. Carriers are bound through a
-- registered adapter; a stock is the current contents of a carrier with an
-- opaque StockRef {stockId, contentsGeneration, dataRevision}. Emptying ends
-- a generation, a later fill starts another; ownership, site or capacity
-- changes alone never cleanse or recreate contents. Quantities are observed
-- native amounts and are never invented, rolled back or balanced.
--
-- captureOperation / settleOperation / abandonOperation bracket a native
-- action: capture before facts, let native work happen, report actual
-- results; pure property interpretation (combine/transform) runs on
-- detached candidates and the accepted record set is replaced once, with
-- no external callback inside the final replacement. Reentrant mutation is
-- refused. A metadata failure qualifies facts; it never touches goods.
--
-- publishProperties is the producer's atomic absolute batch bound to the
-- exact expected StockRef and property revision; causal schemas need cause
-- evidence and answer ALREADY_APPLIED for an equal accepted cause, STALE for
-- a lower sequence, REFUSED for conflicting reuse.
-- =========================================================

SGOperations = SGOperations or {}
local O = SGOperations
local SGOperations_mt = { __index = O }

local copy = SGValues.copy
local isFinite = SGValues.isFinite
local isInteger = SGValues.isInteger
local nonempty = SGRecords.nonemptyString

O.OUTCOME_COMMITTED = "COMMITTED"
O.OUTCOME_NO_OP = "NO_OP"
O.OUTCOME_UNRESOLVED = "UNRESOLVED"
O.PUBLISH = { APPLIED = "APPLIED", ALREADY_APPLIED = "ALREADY_APPLIED", STALE = "STALE", UNAVAILABLE = "UNAVAILABLE", REFUSED = "REFUSED" }

function O.new(registry, loadEpoch)
    local self = setmetatable({}, SGOperations_mt)
    self.registry = registry
    self.loadEpoch = loadEpoch or "1"
    self.revision = "1"            -- store revision, bumped on every accepted change
    self.carriers = {}             -- carrierId -> carrier record
    self.stocks = {}               -- stockId -> StockRecord
    self.nextStock = 0
    self.nextOperation = 0
    self.busy = false
    self.openHandles = {}
    self.retiredStocks = {}        -- stockId -> retired StockRecord (historical, bounded)
    self.retiredLimit = 256
    self.onChanged = nil           -- function(kind, id)
    return self
end

local function bump(self)
    self.revision = SGValues.incrementDecimal(self.revision)
    return self.revision
end

local function notify(self, kind, id)
    if type(self.onChanged) == "function" then pcall(self.onChanged, kind, id) end
end

-- ---------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------
function O:newStockId()
    self.nextStock = self.nextStock + 1
    return "st:" .. self.loadEpoch .. ":" .. tostring(self.nextStock)
end

function O:carrierIdOf(binding)
    return SGRecords.carrierKeyString(binding and binding.carrierKey)
end

function O:stockRef(stock)
    return { stockId = stock.stockId, contentsGeneration = stock.contentsGeneration, dataRevision = stock.dataRevision }
end

local function sameRef(a, b)
    return type(a) == "table" and type(b) == "table" and a.stockId == b.stockId and a.contentsGeneration == b.contentsGeneration
        and a.dataRevision == b.dataRevision
end
O.sameRef = sameRef

--- Validate a native state report from an adapter.
function O.validateNativeState(ns)
    if type(ns) ~= "table" then return nil, "NATIVE_STATE" end
    if ns.materialRef ~= nil and not SGRecords.isMaterialRef(ns.materialRef) then return nil, "MATERIAL_REF" end
    if not SGRecords.isAmount(ns.amount) then return nil, "AMOUNT" end
    if ns.amount > 0 and ns.materialRef == nil then return nil, "MATERIAL_REF" end
    if not nonempty(ns.unit, 32) then return nil, "UNIT" end
    if ns.capacity ~= nil and not SGRecords.isAmount(ns.capacity) then return nil, "CAPACITY" end
    if ns.x ~= nil and (not isFinite(ns.x) or not isFinite(ns.z)) then return nil, "POSITION" end
    return {
        materialRef = ns.materialRef and copy(ns.materialRef) or nil, amount = ns.amount, unit = ns.unit,
        capacity = ns.capacity, x = ns.x, z = ns.z, ownerFarmId = ns.ownerFarmId, storeKind = ns.storeKind,
        stationAccess = ns.stationAccess, label = ns.label, nativeUniqueId = ns.nativeUniqueId,
    }
end

-- ---------------------------------------------------------
-- Stocks
-- ---------------------------------------------------------
local function newStock(self, carrier, ns, generation, knowledge, reason)
    local stock = {
        stockId = self:newStockId(),
        contentsGeneration = generation,
        dataRevision = bump(self),
        carrierKey = copy(carrier.binding.carrierKey),
        carrierId = carrier.carrierId,
        quantityBasisKey = carrier.binding.quantityBasisKey,
        materialRef = copy(ns.materialRef),
        observedAmount = ns.amount,
        amountUnit = ns.unit,
        readiness = "READY",
        knowledge = knowledge or "UNKNOWN",
        reason = reason,
        properties = {},
        acceptedCauses = {},
        pending = {},
    }
    self.stocks[stock.stockId] = stock
    carrier.stockId = stock.stockId
    return stock
end

local function retireStock(self, stock, reason)
    stock.readiness = "UNAVAILABLE"
    stock.retired = true
    stock.retireReason = reason
    stock.dataRevision = bump(self)
    self.stocks[stock.stockId] = nil
    local carrier = self.carriers[stock.carrierId]
    if carrier ~= nil and carrier.stockId == stock.stockId then carrier.stockId = nil end
    self.retiredStocks[stock.stockId] = stock
    local n = 0
    for _ in pairs(self.retiredStocks) do n = n + 1 end
    if n > self.retiredLimit then
        local oldest, oldestRev = nil, nil
        for id, s in pairs(self.retiredStocks) do
            if oldestRev == nil or SGValues.compareDecimal(s.dataRevision, oldestRev) < 0 then oldest, oldestRev = id, s.dataRevision end
        end
        self.retiredStocks[oldest] = nil
    end
end

--- Qualify every property of a stock with a knowledge state and reason.
local function qualifyProperties(stock, knowledge, reason)
    for _, p in pairs(stock.properties) do
        p.knowledge = knowledge
        p.reason = reason
        p.propertyRevision = p.propertyRevision + 1
    end
end

--- Scale coverage of every property for an observed amount change.
local function scaleCoverage(stock, oldAmount, newAmount)
    for _, p in pairs(stock.properties) do
        if p.basisAmount ~= nil then
            if newAmount > oldAmount then
                p.basisAmount = newAmount
                if p.knowledge == "KNOWN" then p.knowledge = "PARTIAL" end
            elseif oldAmount > 0 then
                local share = newAmount / oldAmount
                p.knownAmount = p.knownAmount * share
                p.basisAmount = newAmount
            end
        end
    end
end

--- Reconcile a carrier's stock against an observed native state (no
--- operation context): the bar's reconcile rule at record level.
function O:reconcileCarrier(carrierId, ns, reason)
    local carrier = self.carriers[carrierId]
    if carrier == nil then return nil, "UNKNOWN_CARRIER" end
    local state, why = O.validateNativeState(ns)
    if state == nil then return nil, why end
    carrier.native = state
    local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
    if stock == nil then
        if state.amount > 0 then
            local generation = (carrier.lastGeneration or 0) + 1
            local s = newStock(self, carrier, state, generation, "UNKNOWN", reason or "UNEXPLAINED_FILL")
            carrier.lastGeneration = generation
            notify(self, "STOCK", s.stockId)
            return s
        end
        return nil
    end
    local sameMaterial = state.materialRef ~= nil and SGValues.equal(state.materialRef, stock.materialRef)
    if state.amount == 0 then
        carrier.lastGeneration = stock.contentsGeneration
        retireStock(self, stock, reason or "EMPTIED")
        notify(self, "STOCK", stock.stockId)
        return nil
    end
    if not sameMaterial then
        carrier.lastGeneration = stock.contentsGeneration
        retireStock(self, stock, reason or "MATERIAL_CHANGED")
        local s = newStock(self, carrier, state, stock.contentsGeneration + 1, "UNKNOWN", reason or "MATERIAL_CHANGED")
        carrier.lastGeneration = s.contentsGeneration
        notify(self, "STOCK", s.stockId)
        return s
    end
    if state.amount ~= stock.observedAmount then
        scaleCoverage(stock, stock.observedAmount, state.amount)
        stock.observedAmount = state.amount
        stock.dataRevision = bump(self)
        if stock.knowledge == "KNOWN" then stock.knowledge = "PARTIAL" end
        notify(self, "STOCK", stock.stockId)
    end
    return stock
end

-- ---------------------------------------------------------
-- Carriers
-- ---------------------------------------------------------
--- Bind (or rebind) a carrier from a registered adapter. A rebind of the
--- same proved carrier keeps its stock and generation.
function O:bindCarrier(adapterLease, binding, ns)
    if not self.registry:isLive(adapterLease, SGRegistry.KIND_CARRIER_ADAPTER) then return nil, "LEASE" end
    if not SGRecords.isCarrierBinding(binding) then return nil, "BINDING" end
    if binding.carrierKey.adapterId ~= adapterLease.ownerId then return nil, "ADAPTER_MISMATCH" end
    local carrierId = self:carrierIdOf(binding)
    local state, why = O.validateNativeState(ns)
    if state == nil then return nil, why end
    local carrier = self.carriers[carrierId]
    if carrier == nil then
        carrier = { carrierId = carrierId, adapterId = adapterLease.ownerId, binding = copy(binding), native = state, state = "READY", stockId = nil, lastGeneration = 0, revision = bump(self) }
        self.carriers[carrierId] = carrier
    else
        carrier.binding = copy(binding)
        carrier.native = state
        carrier.state = "READY"
        carrier.revision = bump(self)
    end
    self:reconcileCarrier(carrierId, state, "INITIAL_OBSERVATION")
    notify(self, "CARRIER", carrierId)
    self:notifyBinding(carrier, "READY")
    return carrier
end

function O:notifyBinding(carrier, state, reasonCode)
    local lease = self.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, carrier.adapterId)
    if lease ~= nil and type(lease.spec.onCarrierBindingChanged) == "function" then
        pcall(lease.spec.onCarrierBindingChanged, copy(carrier.binding), state, state == "READY" and carrier.carrierId or nil, reasonCode)
    end
end

--- Withdraw a carrier (delete, sale, adapter unregister): its stock retires
--- as historical, native goods untouched.
function O:withdrawCarrier(carrierId, reason)
    local carrier = self.carriers[carrierId]
    if carrier == nil then return false end
    local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
    if stock ~= nil then retireStock(self, stock, reason or "CARRIER_WITHDRAWN") end
    carrier.state = "UNAVAILABLE"
    carrier.reason = reason
    self.carriers[carrierId] = nil
    notify(self, "CARRIER", carrierId)
    self:notifyBinding(carrier, "UNAVAILABLE", reason)
    return true
end

function O:withdrawAdapter(adapterId, reason)
    local ids = {}
    for id, c in pairs(self.carriers) do
        if c.adapterId == adapterId then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do self:withdrawCarrier(id, reason) end
end

-- ---------------------------------------------------------
-- Detached snapshots
-- ---------------------------------------------------------
function O:snapshotStock(stock, propertyIds)
    local out = {
        stockRef = self:stockRef(stock), carrierKey = copy(stock.carrierKey), carrierId = stock.carrierId,
        quantityBasisKey = stock.quantityBasisKey, materialRef = copy(stock.materialRef), observedAmount = stock.observedAmount,
        amountUnit = stock.amountUnit, readiness = stock.readiness, knowledge = stock.knowledge, reason = stock.reason, properties = {},
    }
    for pid, p in pairs(stock.properties) do
        if propertyIds == nil or propertyIds[pid] then out.properties[pid] = copy(p) end
    end
    return out
end

function O:snapshotCarrier(carrier)
    return { carrierId = carrier.carrierId, adapterId = carrier.adapterId, binding = copy(carrier.binding), native = copy(carrier.native), state = carrier.state, stockId = carrier.stockId, revision = carrier.revision }
end

-- ---------------------------------------------------------
-- Property installation (single writer)
-- ---------------------------------------------------------
local function installProperty(self, stock, record)
    local current = stock.properties[record.propertyId]
    local rev = (current and current.propertyRevision or 0) + 1
    local installed = copy(record)
    installed.propertyRevision = rev
    installed.materialRevision = stock.dataRevision
    stock.properties[record.propertyId] = installed
    return installed
end

--- Validate a property result through the registered owner. Returns the
--- record or nil, reason.
function O:validateResult(record, expectedProducer)
    local ok, why = SGRecords.isPropertyRecord(record)
    if not ok then return nil, why end
    local reg = self.registry:property(record.propertyId)
    if reg == nil then return nil, "UNREGISTERED_PROPERTY" end
    if expectedProducer ~= nil and reg.spec.producerId ~= expectedProducer then return nil, "NOT_OWNER" end
    if record.producerId ~= reg.spec.producerId then return nil, "PRODUCER_MISMATCH" end
    if record.schemaVersion ~= reg.spec.schemaVersion then return nil, "SCHEMA_MISMATCH" end
    local okV, valid, reason = pcall(reg.spec.validate, copy(record))
    if not okV then return nil, "VALIDATE_ERROR" end
    if valid ~= true then return nil, "INVALID:" .. tostring(reason) end
    return record
end

-- ---------------------------------------------------------
-- captureOperation / settleOperation / abandonOperation
-- ---------------------------------------------------------
function O:captureOperation(adapterLease, kind, participants)
    if not self.registry:isLive(adapterLease, SGRegistry.KIND_CARRIER_ADAPTER) then return nil, "LEASE" end
    if not SGRegistry.OPERATION_KINDS[kind] then return nil, "KIND" end
    if type(participants) ~= "table" then return nil, "PARTICIPANTS" end
    local before = { carriers = {}, slots = {} }
    for _, p in ipairs(participants) do
        if type(p) ~= "table" then return nil, "PARTICIPANT" end
        if p.slotId ~= nil then
            if not nonempty(p.slotId, 128) or not nonempty(p.nativeCreatorKey, 512) then return nil, "SLOT" end
            before.slots[p.slotId] = { slotId = p.slotId, nativeCreatorKey = p.nativeCreatorKey }
        elseif p.carrierId ~= nil then
            local carrier = self.carriers[p.carrierId]
            if carrier == nil then return nil, "UNKNOWN_CARRIER" end
            local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
            if p.expectedStockRef ~= nil then
                if stock == nil or not sameRef(p.expectedStockRef, self:stockRef(stock)) then return nil, "STALE" end
            end
            before.carriers[p.carrierId] = {
                carrier = self:snapshotCarrier(carrier),
                stock = stock and self:snapshotStock(stock) or nil,
                amount = carrier.native and carrier.native.amount or 0,
                materialRef = carrier.native and copy(carrier.native.materialRef) or nil,
            }
        else
            return nil, "PARTICIPANT"
        end
    end
    self.nextOperation = self.nextOperation + 1
    local operationId = "op:" .. self.loadEpoch .. ":" .. tostring(self.nextOperation)
    local handle = { operationId = operationId, kind = kind, adapterId = adapterLease.ownerId, open = true, before = before }
    self.openHandles[operationId] = handle
    return { handle = handle, before = copy(before), operationId = operationId }
end

local function closeHandle(self, handle)
    handle.open = false
    self.openHandles[handle.operationId] = nil
end

--- Property interpretation for a destination stock from contributions.
--- Runs the registered pure combine per property present in any source;
--- a failed or invalid result leaves that property UNAVAILABLE.
local function interpretDestination(self, context, contributions, destinationBefore, target)
    local propertyIds = {}
    for _, c in ipairs(contributions) do
        for pid in pairs(c.properties or {}) do propertyIds[pid] = true end
    end
    if destinationBefore ~= nil then
        for pid in pairs(destinationBefore.properties or {}) do propertyIds[pid] = true end
    end
    local results = {}
    for pid in pairs(propertyIds) do
        local reg = self.registry:property(pid)
        if reg == nil then
            results[pid] = SGRecords.unavailableProperty(pid, 1, "unknown", "UNREGISTERED_PROPERTY")
        else
            local ok, result, reason = pcall(reg.spec.combine, copy(context), copy(contributions), destinationBefore and copy(destinationBefore) or nil)
            if not ok then
                results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "COMBINE_ERROR")
            elseif result == nil then
                results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, tostring(reason or "UNKNOWN"))
            else
                local rec = result
                if type(result) == "table" and result.propertyId == nil and result[pid] ~= nil then rec = result[pid] end
                local valid, why = self:validateResult(rec, reg.spec.producerId)
                if valid == nil then
                    results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "INVALID_RESULT:" .. tostring(why))
                else
                    if valid.basisAmount ~= nil and target.amount ~= nil and valid.basisAmount > target.amount then
                        results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "COVERAGE_EXCEEDS_BASIS")
                    else
                        results[pid] = valid
                    end
                end
            end
        end
    end
    return results
end

local function validateAllocation(a)
    if type(a) ~= "table" then return nil, "ALLOCATION" end
    if type(a.source) ~= "table" or type(a.destination) ~= "table" then return nil, "ALLOCATION_ENDS" end
    if not SGRecords.isAmount(a.sourceAmount) or not nonempty(a.sourceUnit, 32) then return nil, "SOURCE_AMOUNT" end
    if a.destination.retire ~= true then
        if not SGRecords.isAmount(a.destinationAmount) or not nonempty(a.destinationUnit, 32) then return nil, "DESTINATION_AMOUNT" end
    end
    if a.source.carrierId == nil and a.source.slotId == nil then return nil, "SOURCE" end
    if a.destination.carrierId == nil and a.destination.slotId == nil and a.destination.retire ~= true then return nil, "DESTINATION" end
    return a
end

function O:settleOperation(handle, report)
    if type(handle) ~= "table" or self.openHandles[handle.operationId] ~= handle or not handle.open then return O.OUTCOME_UNRESOLVED, "HANDLE_CLOSED" end
    if self.busy then return O.OUTCOME_UNRESOLVED, "REENTRANT" end
    if type(report) ~= "table" then
        closeHandle(self, handle)
        return O.OUTCOME_UNRESOLVED, "REPORT"
    end
    self.busy = true
    -- A protected settle: adapter-supplied report data drives a long branch
    -- and an unexpected error must never leave the store locked for the
    -- mission. On an error the captured participants are qualified (native
    -- goods are untouched) and the handle is consumed like any terminal path.
    local ok, outcome, reason = pcall(self._settle, self, handle, report)
    self.busy = false
    closeHandle(self, handle)
    if not ok then
        local err = tostring(outcome)
        pcall(self._qualifyCaptured, self, handle.before, "SETTLE_ERROR", type(report) == "table" and report.participantsAfter or nil)
        print("[StockGuard] settleOperation " .. tostring(handle.operationId) .. " failed: " .. err)
        return O.OUTCOME_UNRESOLVED, "SETTLE_ERROR"
    end
    return outcome, reason
end

function O:_settle(handle, report)
    local before = handle.before
    local after = type(report.participantsAfter) == "table" and report.participantsAfter or {}
    local allocations = type(report.allocations) == "table" and report.allocations or {}
    local created = type(report.createdBindings) == "table" and report.createdBindings or {}
    local adapterLease = self.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, handle.adapterId)
    if adapterLease == nil then return O.OUTCOME_UNRESOLVED, "ADAPTER_GONE" end

    -- Validate the report before touching anything.
    for _, a in ipairs(allocations) do
        local ok, why = validateAllocation(a)
        if ok == nil then
            self:_qualifyCaptured(before, "UNRESOLVED_SETTLEMENT:" .. why, after)
            return O.OUTCOME_UNRESOLVED, why
        end
        if a.source.carrierId ~= nil and before.carriers[a.source.carrierId] == nil then
            self:_qualifyCaptured(before, "UNRESOLVED_SETTLEMENT:SOURCE_NOT_CAPTURED", after)
            return O.OUTCOME_UNRESOLVED, "SOURCE_NOT_CAPTURED"
        end
        if a.source.slotId ~= nil and before.slots[a.source.slotId] == nil then
            self:_qualifyCaptured(before, "UNRESOLVED_SETTLEMENT:SLOT_NOT_CAPTURED", after)
            return O.OUTCOME_UNRESOLVED, "SLOT_NOT_CAPTURED"
        end
        if a.destination.slotId ~= nil and created[a.destination.slotId] == nil then
            self:_qualifyCaptured(before, "UNRESOLVED_SETTLEMENT:CREATED_BINDING_MISSING", after)
            return O.OUTCOME_UNRESOLVED, "CREATED_BINDING_MISSING"
        end
    end
    for slotId, cb in pairs(created) do
        if before.slots[slotId] == nil or type(cb) ~= "table" or not SGRecords.isCarrierBinding(cb.binding) or O.validateNativeState(cb.nativeState) == nil then
            self:_qualifyCaptured(before, "UNRESOLVED_SETTLEMENT:CREATED_BINDING", after)
            return O.OUTCOME_UNRESOLVED, "CREATED_BINDING"
        end
    end

    -- Captured baselines must still be current (changed baseline invalidates).
    for carrierId, b in pairs(before.carriers) do
        local carrier = self.carriers[carrierId]
        local stock = carrier and carrier.stockId and self.stocks[carrier.stockId] or nil
        local refNow = stock and self:stockRef(stock) or nil
        local refThen = b.stock and b.stock.stockRef or nil
        if (refNow == nil) ~= (refThen == nil) or (refNow ~= nil and not sameRef(refNow, refThen)) then
            self:_qualifyCaptured(before, "BASELINE_CHANGED", after)
            return O.OUTCOME_UNRESOLVED, "BASELINE_CHANGED"
        end
    end

    if #allocations == 0 then
        local changed = false
        for carrierId, ns in pairs(after) do
            local b = before.carriers[carrierId]
            if b ~= nil and (ns.amount ~= b.amount or not SGValues.equal(ns.materialRef, b.materialRef)) then changed = true end
        end
        if not changed then return O.OUTCOME_NO_OP, nil end
        for carrierId, ns in pairs(after) do self:reconcileCarrier(carrierId, ns, "UNEXPLAINED_CHANGE") end
        return O.OUTCOME_COMMITTED, "UNEXPLAINED_CHANGE"
    end

    -- Stage: create bindings for birth slots.
    local slotCarrier = {}
    for slotId, cb in pairs(created) do
        local carrierId = self:carrierIdOf(cb.binding)
        local carrier = self.carriers[carrierId]
        if carrier == nil then
            carrier = { carrierId = carrierId, adapterId = handle.adapterId, binding = copy(cb.binding), native = O.validateNativeState(cb.nativeState), state = "READY", lastGeneration = 0, revision = bump(self) }
            self.carriers[carrierId] = carrier
        end
        slotCarrier[slotId] = carrier
    end

    -- Source debits (candidate amounts) and contribution portions.
    local candidateAmount = {}
    local contributionsTo = {}
    local function sourceOf(a)
        if a.source.carrierId ~= nil then
            local b = before.carriers[a.source.carrierId]
            return b.stock, b.amount
        end
        return nil, 0
    end
    for _, a in ipairs(allocations) do
        local srcStock, srcAmount = sourceOf(a)
        local portion = { amount = a.destinationAmount or 0, unit = a.destinationUnit or a.sourceUnit, sourceAmount = a.sourceAmount, sourceUnit = a.sourceUnit, conversionBasisId = a.conversionBasisId }
        if srcStock ~= nil then
            portion.sourceStockRef = copy(srcStock.stockRef)
            portion.materialRef = copy(srcStock.materialRef)
            portion.properties = copy(srcStock.properties)
            portion.knowledge = srcStock.knowledge
            local share = srcAmount > 0 and math.min(1, a.sourceAmount / srcAmount) or 0
            portion.sourceShare = share
            -- Coverage that travels with the portion scales by the share.
            for _, p in pairs(portion.properties) do
                if p.basisAmount ~= nil then
                    p.knownAmount = p.knownAmount * share
                    p.basisAmount = p.basisAmount * share
                end
            end
        else
            portion.slotId = a.source.slotId
            portion.nativeCreatorKey = before.slots[a.source.slotId].nativeCreatorKey
            portion.knowledge = "UNKNOWN"
            portion.properties = {}
        end
        local destKey = a.destination.retire and "RETIRE" or (a.destination.carrierId or ("slot:" .. a.destination.slotId))
        contributionsTo[destKey] = contributionsTo[destKey] or {}
        table.insert(contributionsTo[destKey], portion)
        if a.source.carrierId ~= nil then
            candidateAmount[a.source.carrierId] = (candidateAmount[a.source.carrierId] or before.carriers[a.source.carrierId].amount) - a.sourceAmount
        end
        if a.destination.carrierId ~= nil then
            local b = before.carriers[a.destination.carrierId]
            local base = candidateAmount[a.destination.carrierId] or (b and b.amount or 0)
            candidateAmount[a.destination.carrierId] = base + (a.destinationAmount or 0)
        end
    end

    -- Apply source debits.
    for carrierId, b in pairs(before.carriers) do
        local debit = candidateAmount[carrierId]
        local stock = b.stock and self.stocks[b.stock.stockRef.stockId] or nil
        if debit ~= nil and stock ~= nil and contributionsTo[carrierId] == nil then
            local newAmount = math.max(0, debit)
            if newAmount == 0 then
                local carrier = self.carriers[carrierId]
                carrier.lastGeneration = stock.contentsGeneration
                retireStock(self, stock, "TRANSFERRED_OUT")
            else
                scaleCoverage(stock, stock.observedAmount, newAmount)
                stock.observedAmount = newAmount
                stock.dataRevision = bump(self)
            end
        end
    end

    -- Destinations: births, additions, retirements.
    local context = { operationId = handle.operationId, operationKind = handle.kind, before = copy(before), report = { outcomeEvidence = copy(report.outcomeEvidence) } }
    for destKey, contributions in pairs(contributionsTo) do
        if destKey ~= "RETIRE" then
            local carrier
            if destKey:sub(1, 5) == "slot:" then carrier = slotCarrier[destKey:sub(6)] else carrier = self.carriers[destKey] end
            if carrier ~= nil then
                local total = 0
                local unit, materialRef = nil, nil
                for _, c in ipairs(contributions) do total = total + c.amount unit = unit or c.unit materialRef = materialRef or c.materialRef end
                local ns = after[carrier.carrierId]
                local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
                local destinationBefore = stock and self:snapshotStock(stock) or nil
                local targetAmount = ns and ns.amount or ((stock and stock.observedAmount or 0) + total)
                local targetMaterial = ns and ns.materialRef or (stock and stock.materialRef) or materialRef
                if stock == nil or stock.retired then
                    if targetAmount > 0 and targetMaterial ~= nil then
                        local generation = (carrier.lastGeneration or 0) + 1
                        stock = newStock(self, carrier, { materialRef = targetMaterial, amount = targetAmount, unit = ns and ns.unit or unit }, generation, "UNKNOWN")
                        carrier.lastGeneration = generation
                        -- Candidate baseline supplied to pure callbacks before validation.
                        context.candidate = { stockRef = self:stockRef(stock), carrierId = carrier.carrierId }
                        stock.properties = interpretDestination(self, context, contributions, nil, { amount = targetAmount })
                        for _, p in pairs(stock.properties) do p.propertyRevision = 1 p.materialRevision = stock.dataRevision end
                        stock.knowledge = O.knowledgeOf(stock)
                    end
                else
                    context.candidate = { stockRef = self:stockRef(stock), carrierId = carrier.carrierId }
                    local results = interpretDestination(self, context, contributions, destinationBefore, { amount = targetAmount })
                    stock.observedAmount = targetAmount
                    if targetMaterial ~= nil and not SGValues.equal(targetMaterial, stock.materialRef) then
                        stock.materialRef = copy(targetMaterial)
                    end
                    stock.dataRevision = bump(self)
                    for pid, rec in pairs(results) do installProperty(self, stock, rec) end
                    stock.knowledge = O.knowledgeOf(stock)
                end
                if stock ~= nil then notify(self, "STOCK", stock.stockId) end
            end
        end
    end

    -- Sources that are also destinations (mix in place) and every reported
    -- after-state: reconcile the actual native amount; unexplained deltas
    -- are unknown, never balanced.
    for carrierId, ns in pairs(after) do
        if self.carriers[carrierId] ~= nil then
            local carrier = self.carriers[carrierId]
            local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
            if stock == nil or stock.observedAmount ~= ns.amount or not SGValues.equal(stock.materialRef, ns.materialRef) then
                self:reconcileCarrier(carrierId, ns, "UNEXPLAINED_CHANGE")
            else
                carrier.native = O.validateNativeState(ns) or carrier.native
            end
        end
    end
    for slotId, carrier in pairs(slotCarrier) do
        notify(self, "CARRIER", carrier.carrierId)
        self:notifyBinding(carrier, "READY")
    end
    return O.OUTCOME_COMMITTED, nil
end

--- Qualify captured participants after an unresolved settlement, then
--- reconcile whatever after-state was reported.
function O:_qualifyCaptured(before, reason, after)
    for carrierId, b in pairs(before.carriers) do
        local stock = b.stock and self.stocks[b.stock.stockRef.stockId] or nil
        if stock ~= nil then
            qualifyProperties(stock, "UNAVAILABLE", reason)
            stock.knowledge = "UNAVAILABLE"
            stock.reason = reason
            stock.dataRevision = bump(self)
            notify(self, "STOCK", stock.stockId)
        end
    end
    for carrierId, ns in pairs(after or {}) do
        if self.carriers[carrierId] ~= nil and O.validateNativeState(ns) ~= nil then self:reconcileCarrier(carrierId, ns, reason) end
    end
end

function O:abandonOperation(handle, reason, participantsAfter)
    if type(handle) ~= "table" or self.openHandles[handle.operationId] ~= handle or not handle.open then return false, "HANDLE_CLOSED" end
    closeHandle(self, handle)
    local after = type(participantsAfter) == "table" and participantsAfter or nil
    if after == nil then
        -- Nothing observed after: facts stay, but the affected material is qualified as unproved.
        self:_qualifyCaptured(handle.before, "ABANDONED:" .. tostring(reason), nil)
        return true, "QUALIFIED"
    end
    local changed = false
    for carrierId, ns in pairs(after) do
        local b = handle.before.carriers[carrierId]
        if b ~= nil and (ns.amount ~= b.amount or not SGValues.equal(ns.materialRef, b.materialRef)) then changed = true end
    end
    if not changed then return true, "NO_OP" end
    self:_qualifyCaptured(handle.before, "ABANDONED:" .. tostring(reason), after)
    return true, "QUALIFIED"
end

--- Overall knowledge of a stock from its properties.
function O.knowledgeOf(stock)
    local seen = { KNOWN = 0, PARTIAL = 0, UNKNOWN = 0, HISTORICAL = 0, UNAVAILABLE = 0 }
    local n = 0
    for _, p in pairs(stock.properties) do n = n + 1 seen[p.knowledge] = (seen[p.knowledge] or 0) + 1 end
    if n == 0 then return "UNKNOWN" end
    if seen.KNOWN == n then return "KNOWN" end
    if seen.UNAVAILABLE == n then return "UNAVAILABLE" end
    return "PARTIAL"
end

-- ---------------------------------------------------------
-- publishProperties
-- ---------------------------------------------------------
local function causeKey(cause)
    return tostring(cause.sourceStreamId) .. "/" .. tostring(cause.epoch)
end

function O:publishProperties(producerLease, results, cause)
    if not self.registry:isLive(producerLease, SGRegistry.KIND_PROPERTY) then return O.PUBLISH.REFUSED, { reason = "LEASE" } end
    if self.busy then return O.PUBLISH.REFUSED, { reason = "REENTRANT" } end
    if type(results) ~= "table" or #results == 0 then return O.PUBLISH.REFUSED, { reason = "EMPTY_BATCH" } end
    local reg = producerLease.spec
    local propertyId = producerLease.ownerId
    -- Validate the whole batch first.
    local staged = {}
    for i, r in ipairs(results) do
        if type(r) ~= "table" or not SGRecords.isStockRef(r.stockRef) or type(r.record) ~= "table" then return O.PUBLISH.REFUSED, { reason = "RESULT", index = i } end
        if r.record.propertyId ~= propertyId then return O.PUBLISH.REFUSED, { reason = "NOT_OWNER", index = i } end
        local stock = self.stocks[r.stockRef.stockId]
        if stock == nil then return O.PUBLISH.UNAVAILABLE, { reason = "STOCK_UNAVAILABLE", index = i } end
        if not sameRef(r.stockRef, self:stockRef(stock)) then return O.PUBLISH.STALE, { reason = "STOCK_REVISION", index = i, current = self:stockRef(stock) } end
        local current = stock.properties[propertyId]
        local currentRev = current and current.propertyRevision or 0
        if r.expectedPropertyRevision == nil then
            if currentRev ~= 0 then return O.PUBLISH.REFUSED, { reason = "EXPECTED_REVISION_REQUIRED", index = i } end
        elseif r.expectedPropertyRevision ~= currentRev then
            -- A valid duplicate of an already accepted cause answers ALREADY_APPLIED.
            if reg.causal and cause ~= nil and type(cause) == "table" then
                local acc = stock.acceptedCauses[causeKey(cause)]
                if acc ~= nil and acc.sequence == cause.sequence and acc.fingerprint == cause.fingerprint then
                    return O.PUBLISH.ALREADY_APPLIED, { propertyRevision = currentRev, stockRef = self:stockRef(stock) }
                end
            end
            return O.PUBLISH.STALE, { reason = "PROPERTY_REVISION", index = i, current = currentRev }
        end
        local valid, why = self:validateResult(r.record, reg.producerId)
        if valid == nil then return O.PUBLISH.REFUSED, { reason = why, index = i } end
        if valid.basisAmount ~= nil and valid.basisAmount > stock.observedAmount + 1e-6 then return O.PUBLISH.REFUSED, { reason = "COVERAGE_EXCEEDS_BASIS", index = i } end
        staged[#staged + 1] = { stock = stock, record = valid }
    end
    -- Causal admission.
    if reg.causal then
        if reg.causalUnavailable then return O.PUBLISH.UNAVAILABLE, { reason = "CAUSAL_INTERPRETATION_UNAVAILABLE" } end
        if type(cause) ~= "table" then return O.PUBLISH.REFUSED, { reason = "MISSING_CAUSE" } end
        if not nonempty(cause.sourceStreamId, 128) or not isInteger(cause.epoch) or not isInteger(cause.sequence) or cause.sequence < 1 or not nonempty(cause.fingerprint, 4096) then
            return O.PUBLISH.REFUSED, { reason = "MALFORMED_CAUSE" }
        end
        local okC, accepted, why = pcall(reg.validateCause, copy(cause))
        if not okC or accepted ~= true then return O.PUBLISH.REFUSED, { reason = "CAUSE_REJECTED:" .. tostring(okC and why or "ERROR") } end
        local key = causeKey(cause)
        for _, s in ipairs(staged) do
            local acc = s.stock.acceptedCauses[key]
            if acc ~= nil then
                if acc.sequence == cause.sequence then
                    if acc.fingerprint == cause.fingerprint then return O.PUBLISH.ALREADY_APPLIED, { propertyRevision = (s.stock.properties[propertyId] or {}).propertyRevision or 0 } end
                    return O.PUBLISH.REFUSED, { reason = "CAUSE_CONFLICT" }
                elseif acc.sequence > cause.sequence then
                    return O.PUBLISH.STALE, { reason = "CAUSE_SEQUENCE", current = acc.sequence }
                end
            end
        end
    elseif cause ~= nil and type(cause) ~= "table" then
        return O.PUBLISH.REFUSED, { reason = "MALFORMED_CAUSE" }
    end
    -- Install the whole batch once.
    local installed = {}
    for _, s in ipairs(staged) do
        local rec = installProperty(self, s.stock, s.record)
        s.stock.dataRevision = bump(self)
        rec.materialRevision = s.stock.dataRevision
        if reg.causal then s.stock.acceptedCauses[causeKey(cause)] = { sequence = cause.sequence, fingerprint = cause.fingerprint } end
        s.stock.knowledge = O.knowledgeOf(s.stock)
        installed[#installed + 1] = { stockRef = self:stockRef(s.stock), propertyRevision = rec.propertyRevision }
        notify(self, "STOCK", s.stock.stockId)
    end
    return O.PUBLISH.APPLIED, { installed = installed }
end

-- ---------------------------------------------------------
-- readMaterial / visitOwnedPropertyRecords / readPropertyMix
-- ---------------------------------------------------------
--- Resolve an OWNER_RESOLVED property for a stock at one stable owner
--- revision (before/after check), with cycle detection.
function O:resolveResident(reg, stock, purpose, cycle)
    local key = reg.ownerId .. "|" .. stock.stockId
    if cycle[key] then return SGRecords.unavailableProperty(reg.ownerId, reg.spec.schemaVersion, reg.spec.producerId, "RESOLUTION_CYCLE", stock.dataRevision) end
    cycle[key] = true
    local context = { stockRef = self:stockRef(stock), carrierKey = copy(stock.carrierKey), purpose = purpose, quantityBasisKey = stock.quantityBasisKey, amount = stock.observedAmount, unit = stock.amountUnit }
    local ok1, revBefore = pcall(reg.spec.getResidentRevision, copy(context))
    local ok2, record, reason = pcall(reg.spec.resolveResident, copy(context))
    local ok3, revAfter = pcall(reg.spec.getResidentRevision, copy(context))
    cycle[key] = nil
    if not ok1 or not ok2 or not ok3 or revBefore == nil or revBefore ~= revAfter then
        return SGRecords.unavailableProperty(reg.ownerId, reg.spec.schemaVersion, reg.spec.producerId, "RESIDENT_UNSTABLE", stock.dataRevision)
    end
    if record == nil then return SGRecords.unavailableProperty(reg.ownerId, reg.spec.schemaVersion, reg.spec.producerId, tostring(reason or "RESIDENT_ABSENT"), stock.dataRevision) end
    local valid, why = self:validateResult(record, reg.spec.producerId)
    if valid == nil then return SGRecords.unavailableProperty(reg.ownerId, reg.spec.schemaVersion, reg.spec.producerId, "RESIDENT_INVALID:" .. tostring(why), stock.dataRevision) end
    local out = copy(valid)
    out.materialRevision = stock.dataRevision
    return out
end

function O:readMaterial(consumerLease, query)
    if not self.registry:isLive(consumerLease, SGRegistry.KIND_CONSUMER) then return { state = "DENIED", reason = "LEASE", records = {} } end
    if type(query) ~= "table" then return { state = "REFUSED", reason = "QUERY", records = {} } end
    local spec = consumerLease.spec
    local selected = nil
    if query.propertyIds ~= nil then
        if type(query.propertyIds) ~= "table" then return { state = "REFUSED", reason = "PROPERTY_IDS", records = {} } end
        selected = {}
        for _, pid in ipairs(query.propertyIds) do
            if spec.requiredSchemas[pid] == nil then return { state = "REFUSED", reason = "PROPERTY_NOT_ADMITTED:" .. tostring(pid), records = {} } end
            selected[pid] = true
        end
    else
        selected = {}
        for pid in pairs(spec.requiredSchemas) do selected[pid] = true end
    end
    local ok, ctx, reason = pcall(spec.resolveReadContext, copy(query))
    if not ok then return { state = "ERROR", reason = "RESOLVE_ERROR", records = {} } end
    if type(ctx) ~= "table" or type(ctx.stockRefs) ~= "table" then return { state = "DENIED", reason = tostring(reason or "CONTEXT_DENIED"), records = {} } end
    local kinds = {}
    for _, k in ipairs(spec.materialKinds) do kinds[k] = true end
    local records = {}
    local cycle = {}
    for _, ref in ipairs(ctx.stockRefs) do
        local stock = type(ref) == "table" and self.stocks[ref.stockId] or nil
        if stock == nil then
            records[#records + 1] = { stockRef = copy(ref), state = "UNAVAILABLE", reason = "STOCK_UNAVAILABLE" }
        elseif not kinds[stock.materialRef.kind] then
            records[#records + 1] = { stockRef = self:stockRef(stock), state = "UNAVAILABLE", reason = "MATERIAL_KIND_NOT_ADMITTED" }
        else
            local snap = self:snapshotStock(stock, selected)
            snap.state = sameRef(ref, snap.stockRef) and "READY" or "STALE_REFERENCE"
            for pid in pairs(selected) do
                local reg = self.registry:property(pid)
                if reg == nil then
                    snap.properties[pid] = SGRecords.unavailableProperty(pid, spec.requiredSchemas[pid], "unknown", "PRODUCER_ABSENT", stock.dataRevision)
                elseif reg.spec.schemaVersion ~= spec.requiredSchemas[pid] then
                    snap.properties[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "SCHEMA_INCOMPATIBLE", stock.dataRevision)
                elseif reg.spec.residency == "OWNER_RESOLVED" then
                    snap.properties[pid] = self:resolveResident(reg, stock, ctx.purpose, cycle)
                elseif snap.properties[pid] == nil then
                    snap.properties[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "NOT_RECORDED", stock.dataRevision)
                end
            end
            records[#records + 1] = snap
        end
    end
    return { state = "READY", reason = nil, readRevision = self.revision, purpose = ctx.purpose, records = records }
end

function O:visitOwnedPropertyRecords(producerLease, cursor, limit)
    if not self.registry:isLive(producerLease, SGRegistry.KIND_PROPERTY) then return { state = "DENIED", records = {}, exhausted = true } end
    limit = math.max(1, math.min(64, math.floor(tonumber(limit) or 64)))
    local ids = {}
    for id in pairs(self.stocks) do ids[#ids + 1] = id end
    table.sort(ids)
    local start = 1
    if cursor ~= nil then
        if type(cursor) ~= "table" or cursor.revision ~= self.revision or cursor.epoch ~= self.loadEpoch then return { state = "STALE", reason = "CURSOR", records = {}, exhausted = false } end
        start = cursor.position
    end
    local records = {}
    local i = start
    while i <= #ids and #records < limit do
        local stock = self.stocks[ids[i]]
        local p = stock.properties[producerLease.ownerId]
        records[#records + 1] = { stockRef = self:stockRef(stock), carrierKey = copy(stock.carrierKey), amount = stock.observedAmount, unit = stock.amountUnit, property = p and copy(p) or SGRecords.unavailableProperty(producerLease.ownerId, producerLease.spec.schemaVersion, producerLease.spec.producerId, "NOT_RECORDED", stock.dataRevision) }
        i = i + 1
    end
    local exhausted = i > #ids
    return { state = "READY", records = records, nextCursor = (not exhausted) and { revision = self.revision, epoch = self.loadEpoch, position = i } or nil, exhausted = exhausted }
end

--- Pure mix preview: the owner's combine over named contributions, no store change.
function O:readPropertyMix(consumerLease, contributions, context)
    if not self.registry:isLive(consumerLease, SGRegistry.KIND_CONSUMER) then return { state = "DENIED", reason = "LEASE", properties = {} } end
    if type(contributions) ~= "table" or #contributions == 0 then return { state = "REFUSED", reason = "CONTRIBUTIONS", properties = {} } end
    local spec = consumerLease.spec
    local detached = {}
    local basis = 0
    for i, c in ipairs(contributions) do
        if type(c) ~= "table" or not SGRecords.isAmount(c.amount) or not nonempty(c.unit, 32) then return { state = "REFUSED", reason = "CONTRIBUTION:" .. i, properties = {} } end
        local d = { amount = c.amount, unit = c.unit, properties = {}, knowledge = "UNKNOWN" }
        if c.stockRef ~= nil then
            local stock = self.stocks[c.stockRef.stockId]
            if stock == nil or not sameRef(c.stockRef, self:stockRef(stock)) then return { state = "STALE", reason = "CONTRIBUTION_REFERENCE:" .. i, properties = {} } end
            d.materialRef = copy(stock.materialRef)
            d.properties = copy(stock.properties)
            d.knowledge = stock.knowledge
        elseif c.capturedContribution ~= nil then
            d.captured = copy(c.capturedContribution)
            d.properties = copy(c.capturedContribution.properties or {})
            d.knowledge = c.capturedContribution.knowledge or "UNKNOWN"
            d.materialRef = copy(c.capturedContribution.materialRef)
        else
            return { state = "REFUSED", reason = "CONTRIBUTION_SOURCE:" .. i, properties = {} }
        end
        basis = basis + c.amount
        detached[#detached + 1] = d
    end
    local properties = {}
    for pid in pairs(spec.requiredSchemas) do
        local reg = self.registry:property(pid)
        if reg == nil or reg.spec.schemaVersion ~= spec.requiredSchemas[pid] then
            properties[pid] = SGRecords.unavailableProperty(pid, spec.requiredSchemas[pid], reg and reg.spec.producerId or "unknown", reg and "SCHEMA_INCOMPATIBLE" or "PRODUCER_ABSENT")
        else
            local ok, result, reason = pcall(reg.spec.combine, copy(context or {}), copy(detached), nil)
            if not ok or result == nil then
                properties[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, ok and tostring(reason or "UNKNOWN") or "COMBINE_ERROR")
            else
                local rec = (type(result) == "table" and result.propertyId == nil and result[pid]) or result
                local valid, why = self:validateResult(rec, reg.spec.producerId)
                properties[pid] = valid or SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "INVALID_RESULT:" .. tostring(why))
            end
        end
    end
    return { state = "READY", basis = { amount = basis }, properties = properties }
end

-- ---------------------------------------------------------
-- Serialization of core values (SG_SAVE_2.coreValues)
-- ---------------------------------------------------------
function O:serializeCore()
    local carriers = {}
    local ids = {}
    for id in pairs(self.carriers) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local c = self.carriers[id]
        carriers[#carriers + 1] = { carrierId = id, adapterId = c.adapterId, binding = copy(c.binding), lastGeneration = c.lastGeneration or 0, stockId = c.stockId,
            native = c.native and { materialRef = copy(c.native.materialRef), amount = c.native.amount, unit = c.native.unit, nativeUniqueId = c.native.nativeUniqueId } or nil }
    end
    local stocks = {}
    local sids = {}
    for id in pairs(self.stocks) do sids[#sids + 1] = id end
    table.sort(sids)
    for _, id in ipairs(sids) do
        local s = self.stocks[id]
        local props = {}
        local pids = {}
        for pid in pairs(s.properties) do pids[#pids + 1] = pid end
        table.sort(pids)
        for _, pid in ipairs(pids) do props[#props + 1] = copy(s.properties[pid]) end
        local causes = {}
        local ckeys = {}
        for k in pairs(s.acceptedCauses) do ckeys[#ckeys + 1] = k end
        table.sort(ckeys)
        for _, k in ipairs(ckeys) do causes[#causes + 1] = { key = k, sequence = s.acceptedCauses[k].sequence, fingerprint = s.acceptedCauses[k].fingerprint } end
        stocks[#stocks + 1] = {
            stockId = s.stockId, contentsGeneration = s.contentsGeneration, dataRevision = s.dataRevision, carrierId = s.carrierId, carrierKey = copy(s.carrierKey),
            quantityBasisKey = s.quantityBasisKey, materialRef = copy(s.materialRef), observedAmount = s.observedAmount, amountUnit = s.amountUnit,
            knowledge = s.knowledge, reason = s.reason, properties = props, acceptedCauses = causes,
        }
    end
    return { schemaVersion = 2, revision = self.revision, nextStock = self.nextStock, carriers = carriers, stocks = stocks }
end

--- Validate a saved coreValues table (detached, no store change).
function O.validateCore(core)
    if type(core) ~= "table" or core.schemaVersion ~= 2 then return nil, "CORE_SCHEMA" end
    if type(core.carriers) ~= "table" or type(core.stocks) ~= "table" then return nil, "CORE_SHAPE" end
    if not isInteger(core.nextStock) or core.nextStock < 0 then return nil, "CORE_COUNTER" end
    local carrierIds = {}
    for i, c in ipairs(core.carriers) do
        if type(c) ~= "table" or not nonempty(c.carrierId, 2048) or not SGRecords.isCarrierBinding(c.binding) or carrierIds[c.carrierId] then return nil, "CORE_CARRIER:" .. i end
        if SGRecords.carrierKeyString(c.binding.carrierKey) ~= c.carrierId then return nil, "CORE_CARRIER_KEY:" .. i end
        carrierIds[c.carrierId] = true
    end
    local stockIds = {}
    for i, s in ipairs(core.stocks) do
        if type(s) ~= "table" or not SGRecords.isStockRef({ stockId = s.stockId, contentsGeneration = s.contentsGeneration, dataRevision = s.dataRevision }) then return nil, "CORE_STOCK:" .. i end
        if stockIds[s.stockId] or not carrierIds[s.carrierId] or not SGRecords.isMaterialRef(s.materialRef) or not SGRecords.isAmount(s.observedAmount) or not nonempty(s.amountUnit, 32) then return nil, "CORE_STOCK:" .. i end
        if not SGRecords.KNOWLEDGE[s.knowledge] then return nil, "CORE_STOCK_KNOWLEDGE:" .. i end
        for j, p in ipairs(s.properties or {}) do
            if not SGRecords.isPropertyRecord(p) then return nil, "CORE_PROPERTY:" .. i .. "." .. j end
        end
        stockIds[s.stockId] = true
    end
    return core
end

--- Restore saved core values against the actual enumerated carriers. A
--- saved stock reattaches only when its carrier is present with the same
--- material and native amount (the bar's restore rule); otherwise the
--- native quantity stands with UNKNOWN knowledge and the saved facts are
--- retained as historical. Adapters have already bound live carriers.
function O:restoreCore(core)
    local restored, unknown, historical = 0, 0, 0
    if core.nextStock > self.nextStock then self.nextStock = core.nextStock end
    for _, saved in ipairs(core.stocks) do
        local carrier = self.carriers[saved.carrierId]
        local live = carrier and carrier.stockId and self.stocks[carrier.stockId] or nil
        local nativeAmount = carrier and carrier.native and carrier.native.amount or nil
        local nativeMaterial = carrier and carrier.native and carrier.native.materialRef or nil
        if carrier ~= nil and live ~= nil and nativeAmount == saved.observedAmount and SGValues.equal(nativeMaterial, saved.materialRef) then
            -- Reattach: identity, generation, properties and causes carried; native quantity stands.
            self.stocks[live.stockId] = nil
            live.stockId = saved.stockId
            live.contentsGeneration = saved.contentsGeneration
            live.knowledge = saved.knowledge
            live.reason = saved.reason
            live.properties = {}
            for _, p in ipairs(saved.properties or {}) do live.properties[p.propertyId] = copy(p) end
            live.acceptedCauses = {}
            for _, c in ipairs(saved.acceptedCauses or {}) do live.acceptedCauses[c.key] = { sequence = c.sequence, fingerprint = c.fingerprint } end
            live.dataRevision = bump(self)
            self.stocks[saved.stockId] = live
            carrier.stockId = saved.stockId
            carrier.lastGeneration = math.max(carrier.lastGeneration or 0, saved.contentsGeneration)
            restored = restored + 1
        elseif carrier ~= nil and live ~= nil then
            live.knowledge = "UNKNOWN"
            live.reason = "RESTORE_MISMATCH"
            if saved.contentsGeneration >= live.contentsGeneration then
                live.contentsGeneration = saved.contentsGeneration + 1
                carrier.lastGeneration = live.contentsGeneration
            end
            live.dataRevision = bump(self)
            unknown = unknown + 1
            local h = copy(saved)
            h.retired = true
            h.retireReason = "RESTORE_MISMATCH"
            self.retiredStocks[saved.stockId] = h
        else
            local h = copy(saved)
            h.retired = true
            h.retireReason = "CARRIER_ABSENT"
            self.retiredStocks[saved.stockId] = h
            historical = historical + 1
        end
    end
    for _, sc in ipairs(core.carriers) do
        local carrier = self.carriers[sc.carrierId]
        if carrier ~= nil then carrier.lastGeneration = math.max(carrier.lastGeneration or 0, sc.lastGeneration or 0) end
    end
    return { restored = restored, unknown = unknown, historical = historical }
end

--- Mission teardown.
function O:clear()
    for id, h in pairs(self.openHandles) do h.open = false end
    self.openHandles = {}
    self.carriers = {}
    self.stocks = {}
    self.retiredStocks = {}
end
