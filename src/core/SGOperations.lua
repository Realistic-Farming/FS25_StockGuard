-- =========================================================
-- FS25_StockGuard - material store, observed operations, property settlement,
-- the carrier-pending collection and server reads (SG-1 4.4)
-- =========================================================
-- One authoritative material record writer. Carriers are bound through a
-- registered adapter; a stock is the current contents of a carrier with an
-- opaque StockRef {stockId, contentsGeneration, dataRevision}. Emptying ends
-- a generation, a later fill starts another; ownership, site or capacity
-- changes alone never cleanse or recreate contents. Quantities are observed
-- native amounts and are never invented, rolled back or balanced.
--
-- captureOperation / settleOperation / abandonOperation bracket a native
-- action. settle builds a DETACHED candidate set first (candidate StockRefs
-- and allocation references, validated after-states, per-destination
-- property results through the owners' pure combine/transform, carried or
-- transformed causal state, the empty-carrier creation join), validates
-- every coupled change, and only then installs the whole set in one pass
-- with no external callback inside the replacement; change notifications
-- are queued and flushed after the install. Any failure before the install
-- leaves the store untouched, qualifies the captured facts and consumes the
-- handle. Reentrant mutation is refused while a replacement runs.
--
-- publishProperties is the producer's atomic absolute batch bound to the
-- exact expected StockRef and property revision; causal schemas need cause
-- evidence and answer ALREADY_APPLIED per entry for an equal accepted cause,
-- STALE for a lower sequence, REFUSED for conflicting reuse.
--
-- The carrier-pending collection (SG_CARRIER_PENDING_1) is the one canonical
-- data-only map of empty-carrier guidance: readCarrierPending and
-- setCarrierPending validate actual emptiness and both tokens; settle joins
-- a LIVE creation on an armed empty carrier through the registered owner's
-- prepareCreationBinding and commits stock, properties and the carrier
-- update as one replacement.
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
O.EPSILON = 1e-6
O.PENDING_SCHEMA = "SG_CARRIER_PENDING_1"

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
    self.openHandles = {}          -- operationId -> handle (public part)
    self.handleState = {}          -- operationId -> { before, lease }
    self.retiredStocks = {}        -- stockId -> retired StockRecord (historical, bounded)
    self.retiredLimit = 256
    self.pending = {}              -- carrierId -> pending record (the canonical collection)
    self.onChanged = nil           -- function(kind, id)
    self._deferred = nil           -- queued notifications during a replacement
    return self
end

local function bump(self)
    self.revision = SGValues.incrementDecimal(self.revision)
    return self.revision
end

-- ---------------------------------------------------------
-- Notifications: queued while a replacement runs, flushed after it.
-- ---------------------------------------------------------
local function notify(self, kind, id)
    if self._deferred ~= nil then
        self._deferred[#self._deferred + 1] = { kind = kind, id = id }
        return
    end
    if type(self.onChanged) == "function" then pcall(self.onChanged, kind, id) end
end

local function notifyBindingNow(self, carrier, state, reasonCode)
    local lease = self.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, carrier.adapterId)
    if lease ~= nil and type(lease.spec.onCarrierBindingChanged) == "function" then
        pcall(lease.spec.onCarrierBindingChanged, copy(carrier.binding), state, state == "READY" and carrier.carrierId or nil, reasonCode)
    end
end

function O:notifyBinding(carrier, state, reasonCode)
    if self._deferred ~= nil then
        self._deferred[#self._deferred + 1] = { binding = true, carrier = carrier, state = state, reason = reasonCode }
        return
    end
    notifyBindingNow(self, carrier, state, reasonCode)
end

local function beginDefer(self)
    if self._deferred ~= nil then return false end
    self._deferred = {}
    return true
end

local function flushDeferred(self)
    local queue = self._deferred
    self._deferred = nil
    for _, n in ipairs(queue or {}) do
        if n.binding then notifyBindingNow(self, n.carrier, n.state, n.reason)
        else notify(self, n.kind, n.id) end
    end
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

local function nearlyEqual(a, b)
    return math.abs(a - b) <= O.EPSILON
end

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
-- Carrier pending records (the canonical empty-carrier collection)
-- ---------------------------------------------------------
local function pendingOf(self, carrier, nativeAmount)
    local p = self.pending[carrier.carrierId]
    if p == nil then
        p = { emptyEpoch = 1, selectionRevision = 1, nativeContentState = (nativeAmount or 0) > 0 and "NONEMPTY" or "EMPTY", pendingTarget = nil, boundStockRef = nil, availability = "READY", reason = nil }
        self.pending[carrier.carrierId] = p
    end
    return p
end

--- Observed nonempty-to-empty (or invalidated binding): the empty epoch
--- advances once, an old target is dropped, a bound stock reference is cleared.
local function advanceEmptyEpoch(self, carrierId, reason)
    local p = self.pending[carrierId]
    if p == nil then return end
    p.emptyEpoch = p.emptyEpoch + 1
    p.nativeContentState = "EMPTY"
    p.pendingTarget = nil
    p.boundStockRef = nil
    p.availability = "READY"
    p.reason = reason
end

-- ---------------------------------------------------------
-- Stocks
-- ---------------------------------------------------------
local function newStock(self, carrier, ns, generation, knowledge, reason, stockId)
    local stock = {
        stockId = stockId or self:newStockId(),
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
    local p = self.pending[carrier.carrierId]
    if p ~= nil then p.nativeContentState = "NONEMPTY" end
    return stock
end

--- Bound the retired table, counting historical stocks SEPARATELY.
-- A historical stock (carrier absent or mismatched at the last load) carries the
-- dataRevision it was SAVED with, so it is always older than every ordinary
-- retirement made this session. Sharing one budget meant the first 256 retirements
-- of a long session evicted every historical stock before touching an ordinary one,
-- which is exactly the data loss B10 was opened for, moved to a longer session.
-- Each set now gets its own budget and each is evicted oldest-first within itself.
local function pruneRetired(self)
    local ordinary, historical = 0, 0
    for _, s in pairs(self.retiredStocks) do
        if s.historical then historical = historical + 1 else ordinary = ordinary + 1 end
    end

    local function evictOldest(wantHistorical)
        local oldest, oldestRev = nil, nil
        for id, s in pairs(self.retiredStocks) do
            if (s.historical == true) == wantHistorical then
                if oldestRev == nil or SGValues.compareDecimal(s.dataRevision, oldestRev) < 0 then
                    oldest, oldestRev = id, s.dataRevision
                end
            end
        end
        if oldest == nil then return false end
        self.retiredStocks[oldest] = nil
        return true
    end

    while ordinary > self.retiredLimit and evictOldest(false) do ordinary = ordinary - 1 end
    while historical > self.retiredLimit and evictOldest(true) do historical = historical - 1 end
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
    pruneRetired(self)
end

--- Qualify every property of a stock with a knowledge state and reason.
local function qualifyProperties(stock, knowledge, reason)
    for _, p in pairs(stock.properties) do
        p.knowledge = knowledge
        p.reason = reason
        p.propertyRevision = p.propertyRevision + 1
    end
end

--- Scale coverage of every property for an observed amount change; every
--- touched record gets a new property revision.
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
            p.propertyRevision = p.propertyRevision + 1
        end
    end
end

--- Overall knowledge of a stock from its properties: uniform states map
--- exactly, mixtures are PARTIAL, no properties is UNKNOWN.
function O.knowledgeOf(stock)
    local first, uniform, n = nil, true, 0
    for _, p in pairs(stock.properties) do
        n = n + 1
        if first == nil then first = p.knowledge elseif p.knowledge ~= first then uniform = false end
    end
    if n == 0 then return "UNKNOWN" end
    if uniform then return first end
    return "PARTIAL"
end

--- Reconcile a carrier's stock against an observed native state (record
--- level, no operation context). Internal: no busy check, used inside a
--- replacement with deferred notifications.
local function reconcile(self, carrierId, state, reason)
    local carrier = self.carriers[carrierId]
    if carrier == nil then return nil, "UNKNOWN_CARRIER" end
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
        advanceEmptyEpoch(self, carrierId, reason or "EMPTIED")
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

function O:reconcileCarrier(carrierId, ns, reason)
    if self.busy then return nil, "REENTRANT" end
    local state, why = O.validateNativeState(ns)
    if state == nil then return nil, why end
    return reconcile(self, carrierId, state, reason)
end

-- ---------------------------------------------------------
-- Carriers
-- ---------------------------------------------------------
--- Bind (or rebind) a carrier from a registered adapter. A rebind of the
--- same proved carrier keeps its stock and generation; a changed
--- quantityBasisKey ends the generation (the quantity means something else
--- now), a changed profile requalifies the stock.
function O:bindCarrier(adapterLease, binding, ns)
    if self.busy then return nil, "REENTRANT" end
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
        pendingOf(self, carrier, state.amount)
    else
        if carrier.adapterId ~= adapterLease.ownerId then return nil, "ADAPTER_MISMATCH" end
        local old = carrier.binding
        local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
        if stock ~= nil and old.quantityBasisKey ~= binding.quantityBasisKey then
            carrier.lastGeneration = stock.contentsGeneration
            retireStock(self, stock, "BASIS_CHANGED")
            advanceEmptyEpoch(self, carrierId, "BASIS_CHANGED")
            notify(self, "STOCK", stock.stockId)
        elseif stock ~= nil and (old.profileId ~= binding.profileId or old.profileVersion ~= binding.profileVersion) then
            qualifyProperties(stock, "PARTIAL", "PROFILE_CHANGED")
            stock.knowledge = O.knowledgeOf(stock)
            stock.reason = "PROFILE_CHANGED"
            stock.dataRevision = bump(self)
            notify(self, "STOCK", stock.stockId)
        end
        carrier.binding = copy(binding)
        carrier.native = state
        carrier.state = "READY"
        carrier.revision = bump(self)
    end
    reconcile(self, carrierId, state, "INITIAL_OBSERVATION")
    notify(self, "CARRIER", carrierId)
    self:notifyBinding(carrier, "READY")
    return carrier
end

--- Withdraw a carrier (delete, sale, adapter unregister): its stock retires
--- as historical, native goods untouched.
function O:withdrawCarrier(carrierId, reason)
    if self.busy then return false, "REENTRANT" end
    local carrier = self.carriers[carrierId]
    if carrier == nil then return false end
    local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
    if stock ~= nil then retireStock(self, stock, reason or "CARRIER_WITHDRAWN") end
    carrier.state = "UNAVAILABLE"
    carrier.reason = reason
    self.carriers[carrierId] = nil
    self.pending[carrierId] = nil
    notify(self, "CARRIER", carrierId)
    self:notifyBinding(carrier, "UNAVAILABLE", reason)
    return true
end

--- Withdraw every carrier of an adapter and close its open handles (their
--- captured stocks are qualified: the adapter is gone before it settled).
function O:withdrawAdapter(adapterId, reason)
    if self.busy then return false, "REENTRANT" end
    for operationId, handle in pairs(self.openHandles) do
        if handle.adapterId == adapterId then
            local st = self.handleState[operationId]
            handle.open = false
            self.openHandles[operationId] = nil
            self.handleState[operationId] = nil
            if st ~= nil then self:_qualifyCaptured(st.before, "ADAPTER_GONE", nil) end
        end
    end
    local ids = {}
    for id, c in pairs(self.carriers) do
        if c.adapterId == adapterId then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do self:withdrawCarrier(id, reason) end
    return true
end

-- ---------------------------------------------------------
-- Detached snapshots
-- ---------------------------------------------------------
function O:snapshotStock(stock, propertyIds)
    local out = {
        stockRef = self:stockRef(stock), carrierKey = copy(stock.carrierKey), carrierId = stock.carrierId,
        quantityBasisKey = stock.quantityBasisKey, materialRef = copy(stock.materialRef), observedAmount = stock.observedAmount,
        amountUnit = stock.amountUnit, readiness = stock.readiness, knowledge = stock.knowledge, reason = stock.reason, properties = {},
        acceptedCauses = copy(stock.acceptedCauses),
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
-- captureOperation
-- ---------------------------------------------------------
function O:captureOperation(adapterLease, kind, participants)
    if self.busy then return nil, "REENTRANT" end
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
            if carrier.adapterId ~= adapterLease.ownerId then return nil, "ADAPTER_MISMATCH" end
            local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
            if p.expectedStockRef ~= nil then
                if stock == nil or not sameRef(p.expectedStockRef, self:stockRef(stock)) then return nil, "STALE" end
            end
            before.carriers[p.carrierId] = {
                carrier = self:snapshotCarrier(carrier),
                stock = stock and self:snapshotStock(stock) or nil,
                amount = carrier.native and carrier.native.amount or 0,
                materialRef = carrier.native and copy(carrier.native.materialRef) or nil,
                unit = carrier.native and carrier.native.unit or nil,
                pending = (stock == nil) and copy(self.pending[p.carrierId]) or nil,
            }
        else
            return nil, "PARTICIPANT"
        end
    end
    self.nextOperation = self.nextOperation + 1
    local operationId = "op:" .. self.loadEpoch .. ":" .. tostring(self.nextOperation)
    local handle = { operationId = operationId, kind = kind, adapterId = adapterLease.ownerId, open = true }
    self.openHandles[operationId] = handle
    self.handleState[operationId] = { before = before, lease = adapterLease }
    return { handle = handle, before = copy(before), operationId = operationId }
end

local function closeHandle(self, handle)
    handle.open = false
    self.openHandles[handle.operationId] = nil
    self.handleState[handle.operationId] = nil
end

-- ---------------------------------------------------------
-- settleOperation
-- ---------------------------------------------------------
local function validateAllocation(a)
    if type(a) ~= "table" then return nil, "ALLOCATION" end
    if type(a.source) ~= "table" or type(a.destination) ~= "table" then return nil, "ALLOCATION_ENDS" end
    if not SGRecords.isAmount(a.sourceAmount) or not nonempty(a.sourceUnit, 32) then return nil, "SOURCE_AMOUNT" end
    if a.destination.retire ~= true then
        if not SGRecords.isAmount(a.destinationAmount) or not nonempty(a.destinationUnit, 32) then return nil, "DESTINATION_AMOUNT" end
    end
    if a.source.carrierId == nil and a.source.slotId == nil then return nil, "SOURCE" end
    if a.destination.carrierId == nil and a.destination.slotId == nil and a.destination.retire ~= true then return nil, "DESTINATION" end
    if a.conversionBasisId ~= nil and not nonempty(a.conversionBasisId, 128) then return nil, "CONVERSION_BASIS" end
    return a
end

--- Accept a callback result as a record for one property: the record itself,
--- or a map keyed by propertyId or by the candidate stockId.
local function pickResult(result, pid, stockId)
    if type(result) ~= "table" then return nil end
    if result.propertyId ~= nil then return result end
    if result[pid] ~= nil then return result[pid] end
    if stockId ~= nil and type(result[stockId]) == "table" then
        local r = result[stockId]
        if r.propertyId ~= nil then return r end
        return r[pid]
    end
    return nil
end

--- Union-floor of accepted causes: the highest accepted sequence per stream.
local function unionCauses(into, from)
    for key, acc in pairs(from or {}) do
        local cur = into[key]
        if cur == nil or acc.sequence > cur.sequence then into[key] = { sequence = acc.sequence, fingerprint = acc.fingerprint } end
    end
end

local function validCauseMap(m)
    if type(m) ~= "table" then return false end
    for key, acc in pairs(m) do
        if type(key) ~= "string" or type(acc) ~= "table" or not isInteger(acc.sequence) or acc.sequence < 1 or not nonempty(acc.fingerprint, 4096) then return false end
    end
    return true
end

--- Property interpretation for one destination candidate over detached
--- inputs. Combine for MIX/TRANSFER, transform for CONVERT (or any portion
--- carrying a conversion basis). Causal state is carried as a floor or
--- transformed by the owner; an owner without causal interpretation leaves
--- that property unavailable while the floor still travels.
local function interpretDestination(self, context, kind, contributions, destinationBefore, cand)
    local propertyIds = {}
    for _, c in ipairs(contributions) do
        for pid in pairs(c.properties or {}) do propertyIds[pid] = true end
    end
    if destinationBefore ~= nil then
        for pid in pairs(destinationBefore.properties or {}) do propertyIds[pid] = true end
    end
    local useTransform = kind == "CONVERT"
    for _, c in ipairs(contributions) do if c.conversionBasisId ~= nil then useTransform = true end end
    local results = {}
    local causes = {}
    -- Which propertyId's transform last claimed each cause key. The cause map is per
    -- STOCK while the loop below is per PROPERTY, so two causal producers on one stock
    -- both write into it and the later pid in sorted order silently overwrote the
    -- earlier one's transformed keys. Ownership is tracked so a genuine collision is
    -- refused rather than decided by sort order.
    local causeOwner = {}
    for _, c in ipairs(contributions) do unionCauses(causes, c.acceptedCauses) end
    if destinationBefore ~= nil then unionCauses(causes, destinationBefore.acceptedCauses) end
    local pids = {}
    for pid in pairs(propertyIds) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do
        local reg = self.registry:property(pid)
        if reg == nil then
            -- No producer: a stored record is kept and qualified on read; a
            -- carried portion record is unavailable, never a placeholder over data.
            local stored = destinationBefore and destinationBefore.properties[pid] or nil
            if stored ~= nil and #contributions == 0 then
                results[pid] = copy(stored)
            elseif stored ~= nil then
                local r = copy(stored)
                r.knowledge = "HISTORICAL"
                r.reason = "PRODUCER_ABSENT"
                results[pid] = r
            else
                results[pid] = SGRecords.unavailableProperty(pid, 1, "unknown", "PRODUCER_ABSENT")
            end
        else
            local ok, result, reason
            if useTransform then
                ok, result, reason = pcall(reg.spec.transform, copy(context), copy(contributions), { { carrierId = cand.carrierId, slotId = cand.slotId, stockRef = copy(cand.stockRef), amount = cand.amount, unit = cand.unit, materialRef = copy(cand.materialRef), destinationBefore = destinationBefore and copy(destinationBefore) or nil } })
            else
                ok, result, reason = pcall(reg.spec.combine, copy(context), copy(contributions), destinationBefore and copy(destinationBefore) or nil)
            end
            if not ok then
                results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, useTransform and "TRANSFORM_ERROR" or "COMBINE_ERROR")
            elseif result == nil then
                results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, tostring(reason or "UNKNOWN"))
            else
                local rec = pickResult(result, pid, cand.stockRef.stockId)
                local valid, why = self:validateResult(rec, reg.spec.producerId)
                if valid == nil then
                    results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "INVALID_RESULT:" .. tostring(why))
                elseif valid.basisAmount ~= nil and cand.amount ~= nil and valid.basisAmount > cand.amount + O.EPSILON then
                    results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "COVERAGE_EXCEEDS_BASIS")
                else
                    results[pid] = valid
                end
            end
            -- Causal continuity: the owner transforms the streams per portion;
            -- without that interpretation the result is unavailable knowledge.
            if reg.spec.causal then
                if reg.spec.causalUnavailable then
                    results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "CAUSAL_INTERPRETATION_UNAVAILABLE")
                else
                    local sources = {}
                    for _, c in ipairs(contributions) do
                        sources[#sources + 1] = { sourceStockRef = c.sourceStockRef, allocationRef = c.allocationRef, share = c.sourceShare, amount = c.amount, acceptedCauses = copy(c.acceptedCauses or {}) }
                    end
                    if destinationBefore ~= nil then
                        sources[#sources + 1] = { sourceStockRef = destinationBefore.stockRef, share = destinationBefore.remainingShare or 1, amount = destinationBefore.observedAmount, acceptedCauses = copy(destinationBefore.acceptedCauses or {}) }
                    end
                    local okC, transformed = pcall(reg.spec.transformCausalState, copy(context), sources, { stockRef = copy(cand.stockRef), amount = cand.amount })
                    if okC and transformed == nil then
                        -- The owner keeps the floor as carried.
                    elseif okC and validCauseMap(transformed) then
                        for key, acc in pairs(transformed) do
                            local owner = causeOwner[key]
                            local prev = causes[key]
                            if owner ~= nil and owner ~= pid and prev ~= nil
                                and (prev.sequence ~= acc.sequence or prev.fingerprint ~= acc.fingerprint) then
                                -- Two causal producers claim the same stream key with
                                -- DIFFERENT state. Neither claim is preferable, and
                                -- letting the later pid win is deciding it on sort
                                -- order, so the second one is refused instead.
                                results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId,
                                    "CAUSAL_CONFLICT:" .. tostring(owner))
                            else
                                causes[key] = { sequence = acc.sequence, fingerprint = acc.fingerprint }
                                causeOwner[key] = pid
                            end
                        end
                    else
                        results[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "CAUSAL_TRANSFORM_FAILED")
                    end
                end
            end
        end
    end
    return results, causes
end

function O:settleOperation(handle, report)
    if type(handle) ~= "table" or self.openHandles[handle.operationId] ~= handle or not handle.open then return O.OUTCOME_UNRESOLVED, "HANDLE_CLOSED" end
    if self.busy then return O.OUTCOME_UNRESOLVED, "REENTRANT" end
    local st = self.handleState[handle.operationId]
    if type(report) ~= "table" then
        closeHandle(self, handle)
        self:_qualifyCaptured(st.before, "UNRESOLVED_SETTLEMENT:REPORT", nil)
        return O.OUTCOME_UNRESOLVED, "REPORT"
    end
    self.busy = true
    local defer = beginDefer(self)
    -- A protected settle: adapter-supplied report data drives a long branch
    -- and an unexpected error must never leave the store locked. The candidate
    -- phase touches nothing live; the install pass has no external callback,
    -- so an error there is a foundation defect and still leaves no lock.
    local ok, outcome, reason = pcall(self._settle, self, handle, st, report)
    self.busy = false
    closeHandle(self, handle)
    if not ok then
        local err = tostring(outcome)
        pcall(self._qualifyCaptured, self, st.before, "SETTLE_ERROR", type(report) == "table" and report.participantsAfter or nil)
        print("[StockGuard] settleOperation " .. tostring(handle.operationId) .. " failed: " .. err)
        if defer then flushDeferred(self) end
        return O.OUTCOME_UNRESOLVED, "SETTLE_ERROR"
    end
    if defer then flushDeferred(self) end
    return outcome, reason
end

--- Build the detached candidate set, validate it, then install once.
function O:_settle(handle, st, report)
    local before = st.before
    local afterRaw = type(report.participantsAfter) == "table" and report.participantsAfter or {}
    -- COPIED, because step 2 stamps an allocationRef onto each entry. Writing that
    -- into the caller's own table mutates the adapter's allocations behind its back.
    local allocations = type(report.allocations) == "table" and copy(report.allocations) or {}
    local created = type(report.createdBindings) == "table" and report.createdBindings or {}
    local replacements = type(report.replacements) == "table" and report.replacements or {}
    local function fail(why)
        self:_qualifyCaptured(before, "UNRESOLVED_SETTLEMENT:" .. why, afterRaw)
        return O.OUTCOME_UNRESOLVED, why
    end
    if not self.registry:isLive(st.lease, SGRegistry.KIND_CARRIER_ADAPTER) then return fail("ADAPTER_GONE") end

    -- 1. Every reported after-state is validated up front; nothing unvalidated
    --    reaches a record.
    local after = {}
    for carrierId, ns in pairs(afterRaw) do
        if type(carrierId) ~= "string" then return fail("AFTER_STATE_KEY") end
        local state, why = O.validateNativeState(ns)
        if state == nil then return fail("AFTER_STATE:" .. tostring(why)) end
        after[carrierId] = state
    end

    -- 2. Report shape.
    for i, a in ipairs(allocations) do
        local okA, why = validateAllocation(a)
        if okA == nil then return fail(why) end
        if a.source.carrierId ~= nil and before.carriers[a.source.carrierId] == nil then return fail("SOURCE_NOT_CAPTURED") end
        if a.source.slotId ~= nil and before.slots[a.source.slotId] == nil then return fail("SLOT_NOT_CAPTURED") end
        if a.destination.carrierId ~= nil and before.carriers[a.destination.carrierId] == nil then return fail("DESTINATION_NOT_CAPTURED") end
        if a.destination.slotId ~= nil and created[a.destination.slotId] == nil then return fail("CREATED_BINDING_MISSING") end
        if handle.kind == "CONVERT" and a.destination.retire ~= true and a.conversionBasisId == nil then return fail("CONVERSION_BASIS_REQUIRED") end
        if a.destination.retire ~= true and a.conversionBasisId == nil and a.destinationUnit ~= a.sourceUnit then return fail("UNIT_MISMATCH") end
        a.allocationRef = handle.operationId .. ":a" .. tostring(i)
    end
    local createdStates = {}
    for slotId, cb in pairs(created) do
        if before.slots[slotId] == nil or type(cb) ~= "table" or not SGRecords.isCarrierBinding(cb.binding) then return fail("CREATED_BINDING") end
        if cb.binding.carrierKey.adapterId ~= handle.adapterId then return fail("CREATED_BINDING_ADAPTER") end
        if cb.nativeCreatorKey ~= nil and cb.nativeCreatorKey ~= before.slots[slotId].nativeCreatorKey then return fail("CREATED_BINDING_CREATOR") end
        local state, why = O.validateNativeState(cb.nativeState)
        if state == nil then return fail("CREATED_BINDING:" .. tostring(why)) end
        createdStates[slotId] = state
    end
    local moves = {}
    for _, r in ipairs(replacements) do
        if type(r) ~= "table" or before.carriers[r.carrierId] == nil or not SGRecords.isCarrierBinding(r.binding) then return fail("REPLACEMENT") end
        if r.binding.carrierKey.adapterId ~= handle.adapterId then return fail("REPLACEMENT_ADAPTER") end
        local old = before.carriers[r.carrierId].carrier.binding
        if r.binding.aliasOf ~= r.carrierId and r.binding.quantityBasisKey ~= old.quantityBasisKey then return fail("REPLACEMENT_UNPROVED") end
        local newId = self:carrierIdOf(r.binding)
        if newId ~= r.carrierId and self.carriers[newId] ~= nil then return fail("REPLACEMENT_COLLISION") end
        if moves[r.carrierId] ~= nil then return fail("REPLACEMENT_DUPLICATE") end
        moves[r.carrierId] = { newId = newId, binding = copy(r.binding) }
    end

    -- 3. Captured baselines must still be current.
    for carrierId, b in pairs(before.carriers) do
        local carrier = self.carriers[carrierId]
        if carrier == nil then return fail("BASELINE_CHANGED") end
        local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
        local refNow = stock and self:stockRef(stock) or nil
        local refThen = b.stock and b.stock.stockRef or nil
        if (refNow == nil) ~= (refThen == nil) or (refNow ~= nil and not sameRef(refNow, refThen)) then return fail("BASELINE_CHANGED") end
    end

    -- 4. No allocations: a proved no-op, or an unexplained change reconciled.
    -- A NON-EMPTY CREATED SET IS WORK. Step 2 only checks the other direction (an
    -- allocation must name a created binding), so a report that creates a birth
    -- binding and allocates nothing used to take this exit and return NO_OP, leaving
    -- the adapter holding a natively created carrier StockGuard never registered and
    -- raising no error at all. A birth slot legitimately creates a carrier with no
    -- source allocation, so this falls through to the install in step 8 rather than
    -- refusing the report.
    if #allocations == 0 and next(moves) == nil and next(created) == nil then
        local changed = false
        for carrierId, ns in pairs(after) do
            local b = before.carriers[carrierId]
            if b ~= nil and (not nearlyEqual(ns.amount, b.amount) or not SGValues.equal(ns.materialRef, b.materialRef)) then changed = true end
        end
        if not changed then return O.OUTCOME_NO_OP, nil end
        for carrierId, ns in pairs(after) do
            if self.carriers[carrierId] ~= nil then reconcile(self, carrierId, ns, "UNEXPLAINED_CHANGE") end
        end
        return O.OUTCOME_COMMITTED, "UNEXPLAINED_CHANGE"
    end

    -- 5. Debits and credits per participant; over-debit and a missing
    --    after-state for any changed participant are unresolved.
    local debited, credited, touched = {}, {}, {}
    for _, a in ipairs(allocations) do
        if a.source.carrierId ~= nil then
            debited[a.source.carrierId] = (debited[a.source.carrierId] or 0) + a.sourceAmount
            touched[a.source.carrierId] = true
        end
        if a.destination.carrierId ~= nil then
            credited[a.destination.carrierId] = (credited[a.destination.carrierId] or 0) + a.destinationAmount
            touched[a.destination.carrierId] = true
        end
    end
    for carrierId in pairs(touched) do
        if after[carrierId] == nil then return fail("AFTER_STATE_REQUIRED:" .. carrierId) end
    end
    for carrierId, d in pairs(debited) do
        if d > before.carriers[carrierId].amount + O.EPSILON then return fail("OVER_DEBIT:" .. carrierId) end
    end
    for carrierId in pairs(moves) do
        if after[carrierId] == nil then return fail("AFTER_STATE_REQUIRED:" .. carrierId) end
    end

    -- 6. Candidate identities: a candidate StockRef per destination that will
    --    hold stock, assigned before any callback.
    local candidates = {}       -- destKey -> candidate
    local function candidateFor(destKey, carrierId, slotId)
        local c = candidates[destKey]
        if c ~= nil then return c end
        c = { destKey = destKey, carrierId = carrierId, slotId = slotId, contributions = {}, stockRef = nil, amount = nil, unit = nil, materialRef = nil }
        candidates[destKey] = c
        return c
    end
    -- Sources' remaining portion (source that is also a destination keeps its
    -- own remainder as destinationBefore, never a double count).
    local portionsBySource = {}
    for _, a in ipairs(allocations) do
        local portion = { allocationRef = a.allocationRef, amount = a.destinationAmount or 0, unit = a.destinationUnit or a.sourceUnit, sourceAmount = a.sourceAmount, sourceUnit = a.sourceUnit, conversionBasisId = a.conversionBasisId, result = a.result, reason = a.reason }
        if a.source.carrierId ~= nil then
            local b = before.carriers[a.source.carrierId]
            portion.sourceCarrierId = a.source.carrierId
            if b.stock ~= nil then
                portion.sourceStockRef = copy(b.stock.stockRef)
                portion.materialRef = copy(b.stock.materialRef)
                portion.properties = copy(b.stock.properties)
                portion.acceptedCauses = copy(b.stock.acceptedCauses)
                portion.knowledge = b.stock.knowledge
                local share = b.amount > 0 and math.min(1, a.sourceAmount / b.amount) or 0
                portion.sourceShare = share
                for _, p in pairs(portion.properties) do
                    if p.basisAmount ~= nil then
                        p.knownAmount = p.knownAmount * share
                        p.basisAmount = p.basisAmount * share
                    end
                end
            else
                portion.materialRef = copy(b.materialRef)
                portion.properties = {}
                portion.acceptedCauses = {}
                portion.knowledge = "UNKNOWN"
                portion.sourceShare = 0
            end
        else
            portion.slotId = a.source.slotId
            portion.nativeCreatorKey = before.slots[a.source.slotId].nativeCreatorKey
            portion.knowledge = "UNKNOWN"
            portion.properties = {}
            portion.acceptedCauses = {}
            portion.sourceShare = 0
        end
        portionsBySource[#portionsBySource + 1] = portion
        if a.destination.retire ~= true then
            local destKey = a.destination.carrierId or ("slot:" .. a.destination.slotId)
            local c = candidateFor(destKey, a.destination.carrierId, a.destination.slotId)
            c.contributions[#c.contributions + 1] = portion
        end
    end
    -- Sources that keep a remainder, and moved carriers, are candidates too.
    for carrierId in pairs(touched) do
        if candidates[carrierId] == nil then candidateFor(carrierId, carrierId, nil) end
    end
    for carrierId in pairs(moves) do
        if candidates[carrierId] == nil then candidateFor(carrierId, carrierId, nil) end
    end

    -- 7. Per candidate: observed after-state, expected amount, material rule,
    --    candidate ref, property interpretation on detached inputs.
    local context = { operationId = handle.operationId, operationKind = handle.kind, before = copy(before), allocations = copy(allocations), candidates = {}, report = { outcomeEvidence = copy(report.outcomeEvidence) } }
    local order = {}
    for destKey in pairs(candidates) do order[#order + 1] = destKey end
    table.sort(order)
    local pendingLease = nil
    for _, lease in self.registry:each(SGRegistry.KIND_CARRIER_PENDING) do pendingLease = lease end
    for _, destKey in ipairs(order) do
        local c = candidates[destKey]
        local b = c.carrierId and before.carriers[c.carrierId] or nil
        -- A candidate with neither a carrier nor a slot would index createdStates with
        -- nil and throw into the settle pcall, reporting SETTLE_ERROR for what is
        -- really a malformed candidate. Steps 5 and 6 make it unreachable today; a
        -- truthful refusal is still better than an exception.
        local state = c.carrierId and after[c.carrierId] or (c.slotId ~= nil and createdStates[c.slotId] or nil)
        if state == nil then return fail("CANDIDATE_STATE_MISSING:" .. tostring(destKey)) end
        c.after = state
        c.amount = state.amount
        c.unit = state.unit
        c.materialRef = state.materialRef and copy(state.materialRef) or nil
        local expected = (b and b.amount or 0) - (c.carrierId and debited[c.carrierId] or 0) + (c.carrierId and credited[c.carrierId] or 0)
        for _, p in ipairs(c.contributions) do if c.slotId ~= nil then expected = expected + p.amount end end
        c.unexplainedDelta = not nearlyEqual(expected, state.amount)
        for _, p in ipairs(c.contributions) do
            if p.unit ~= state.unit and p.conversionBasisId == nil then return fail("UNIT_MISMATCH:" .. destKey) end
        end
        local existing = b and b.stock or nil
        local remaining = b and (b.amount - (debited[c.carrierId] or 0)) or 0
        c.existing = existing
        if existing ~= nil and state.amount > 0 and state.materialRef ~= nil and SGValues.equal(state.materialRef, existing.materialRef) then
            -- Same generation continues: the own remainder is the destination baseline.
            c.mode = "UPDATE"
            c.stockRef = copy(existing.stockRef)
            local db = copy(existing)
            local share = existing.observedAmount > 0 and math.min(1, remaining / existing.observedAmount) or 0
            db.remainingShare = share
            db.observedAmount = remaining
            for _, p in pairs(db.properties) do
                if p.basisAmount ~= nil then
                    p.knownAmount = p.knownAmount * share
                    p.basisAmount = p.basisAmount * share
                end
            end
            c.destinationBefore = db
        elseif state.amount > 0 and state.materialRef ~= nil then
            -- Birth, or a material change: a new generation (the reconcile rule).
            c.mode = existing ~= nil and "REPLACE" or "BIRTH"
            local carrier = c.carrierId and self.carriers[c.carrierId] or nil
            local lastGen = carrier and (carrier.lastGeneration or 0) or 0
            if existing ~= nil then lastGen = math.max(lastGen, existing.stockRef.contentsGeneration) end
            c.generation = lastGen + 1
            c.stockRef = { stockId = self:newStockId(), contentsGeneration = c.generation, dataRevision = "candidate" }
            c.destinationBefore = nil
        else
            c.mode = existing ~= nil and "EMPTY" or "STAY_EMPTY"
            c.stockRef = nil
        end
        context.candidates[destKey] = { stockRef = c.stockRef and copy(c.stockRef) or nil, carrierId = c.carrierId, slotId = c.slotId, amount = c.amount, unit = c.unit, materialRef = copy(c.materialRef), mode = c.mode }
    end
    for _, destKey in ipairs(order) do
        local c = candidates[destKey]
        if c.stockRef ~= nil and #c.contributions > 0 then
            c.properties, c.acceptedCauses = interpretDestination(self, context, handle.kind, c.contributions, c.destinationBefore, c)
        elseif c.stockRef ~= nil and c.mode == "UPDATE" then
            -- A source that keeps a remainder: its own records travel scaled by
            -- the remaining share; no interpretation callback runs for it.
            c.properties = copy(c.destinationBefore.properties)
            c.acceptedCauses = copy(c.destinationBefore.acceptedCauses or {})
        elseif c.stockRef ~= nil then
            c.properties, c.acceptedCauses = {}, {}
        end
        -- The empty-carrier creation join: a LIVE creation on an armed empty
        -- carrier goes through the registered owner's pure prepareCreationBinding.
        local b = c.carrierId and before.carriers[c.carrierId] or nil
        local armed = b and b.pending and b.pending.pendingTarget ~= nil and b.stock == nil
        if armed and c.mode == "BIRTH" and pendingLease ~= nil then
            local live = self.pending[c.carrierId]
            if live == nil or live.emptyEpoch ~= b.pending.emptyEpoch or live.selectionRevision ~= b.pending.selectionRevision then
                return fail("PENDING_CHANGED:" .. c.carrierId)
            end
            local okP, staged, reason = pcall(pendingLease.spec.prepareCreationBinding, copy(context), copy(b.pending), { stockRef = copy(c.stockRef), carrierId = c.carrierId, amount = c.amount, unit = c.unit, materialRef = copy(c.materialRef), properties = copy(c.properties) })
            if not okP or type(staged) ~= "table" or type(staged.carrierUpdates) ~= "table" then
                live.availability = "UNAVAILABLE"
                live.reason = "CREATION_BINDING_FAILED:" .. tostring(okP and reason or "ERROR")
                return fail("CREATION_BINDING_FAILED")
            end
            local u = staged.carrierUpdates
            if u.collectionPath ~= pendingLease.spec.collectionPath or u.key ~= c.carrierId or u.expectedEmptyEpoch ~= live.emptyEpoch or u.expectedSelectionRevision ~= live.selectionRevision or type(u.replacementRecord) ~= "table" then
                live.availability = "UNAVAILABLE"
                live.reason = "CREATION_BINDING_INVALID"
                return fail("CREATION_BINDING_INVALID")
            end
            for pid, rec in pairs(staged.propertyResults or {}) do
                local valid, why = self:validateResult(rec, nil)
                if valid == nil then
                    live.availability = "UNAVAILABLE"
                    live.reason = "CREATION_BINDING_INVALID:" .. tostring(why)
                    return fail("CREATION_BINDING_INVALID:" .. tostring(pid))
                end
                c.properties[pid] = valid
            end
            c.pendingReplacement = copy(u.replacementRecord)
            c.pendingReplacement.boundStockRef = copy(c.stockRef)
        elseif armed and c.mode == "BIRTH" then
            return fail("PENDING_OWNER_ABSENT")
        end
    end

    -- 8. Install once: no external callback from here to the end.
    local slotCarrier = {}
    for slotId, cb in pairs(created) do
        local carrierId = self:carrierIdOf(cb.binding)
        local carrier = self.carriers[carrierId]
        if carrier == nil then
            carrier = { carrierId = carrierId, adapterId = handle.adapterId, binding = copy(cb.binding), native = createdStates[slotId], state = "READY", lastGeneration = 0, revision = bump(self) }
            self.carriers[carrierId] = carrier
            pendingOf(self, carrier, createdStates[slotId].amount)
        end
        slotCarrier[slotId] = carrier
    end
    for oldId, mv in pairs(moves) do
        if mv.newId ~= oldId then
            local carrier = self.carriers[oldId]
            self.carriers[oldId] = nil
            carrier.carrierId = mv.newId
            carrier.binding = mv.binding
            self.carriers[mv.newId] = carrier
            local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
            if stock ~= nil then
                stock.carrierId = mv.newId
                stock.carrierKey = copy(mv.binding.carrierKey)
            end
            self.pending[mv.newId] = self.pending[oldId]
            self.pending[oldId] = nil
            notify(self, "CARRIER", oldId)
            notify(self, "CARRIER", mv.newId)
        else
            self.carriers[oldId].binding = mv.binding
        end
    end
    local function carrierOf(c)
        if c.slotId ~= nil then return slotCarrier[c.slotId] end
        local mv = moves[c.carrierId]
        return self.carriers[mv and mv.newId or c.carrierId]
    end
    for _, destKey in ipairs(order) do
        local c = candidates[destKey]
        local carrier = carrierOf(c)
        local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
        carrier.native = c.after
        if c.mode == "UPDATE" then
            stock.observedAmount = c.amount
            stock.amountUnit = c.unit
            for pid, rec in pairs(c.properties) do installProperty(self, stock, rec) end
            for pid in pairs(stock.properties) do if c.properties[pid] == nil then stock.properties[pid] = nil end end
            stock.acceptedCauses = c.acceptedCauses
            stock.dataRevision = bump(self)
            stock.knowledge = O.knowledgeOf(stock)
            if c.unexplainedDelta then
                if stock.knowledge == "KNOWN" then stock.knowledge = "PARTIAL" end
                stock.reason = "UNEXPLAINED_DELTA"
            else
                stock.reason = nil
            end
            notify(self, "STOCK", stock.stockId)
        elseif c.mode == "BIRTH" or c.mode == "REPLACE" then
            if stock ~= nil then
                carrier.lastGeneration = stock.contentsGeneration
                retireStock(self, stock, "MATERIAL_CHANGED")
                notify(self, "STOCK", stock.stockId)
            end
            local s = newStock(self, carrier, { materialRef = c.materialRef, amount = c.amount, unit = c.unit }, c.generation, "UNKNOWN", nil, c.stockRef.stockId)
            carrier.lastGeneration = c.generation
            for pid, rec in pairs(c.properties) do
                local installed = copy(rec)
                installed.propertyRevision = 1
                installed.materialRevision = s.dataRevision
                s.properties[pid] = installed
            end
            s.acceptedCauses = c.acceptedCauses or {}
            s.knowledge = O.knowledgeOf(s)
            if c.unexplainedDelta then s.reason = "UNEXPLAINED_DELTA" end
            if c.pendingReplacement ~= nil then
                local p = self.pending[carrier.carrierId]
                local r = c.pendingReplacement
                p.pendingTarget = r.pendingTarget and copy(r.pendingTarget) or nil
                p.boundStockRef = copy(r.boundStockRef)
                p.nativeContentState = "NONEMPTY"
                p.selectionRevision = p.selectionRevision + 1
                p.availability = "READY"
                p.reason = nil
            end
            notify(self, "STOCK", s.stockId)
        elseif c.mode == "EMPTY" then
            carrier.lastGeneration = stock.contentsGeneration
            retireStock(self, stock, "TRANSFERRED_OUT")
            advanceEmptyEpoch(self, carrier.carrierId, "TRANSFERRED_OUT")
            notify(self, "STOCK", stock.stockId)
        end
    end
    -- Reported after-states for captured carriers outside the allocations:
    -- an unexplained change is reconciled, never balanced.
    for carrierId, ns in pairs(after) do
        if candidates[carrierId] == nil and self.carriers[carrierId] ~= nil then
            local carrier = self.carriers[carrierId]
            local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
            if stock == nil or not nearlyEqual(stock.observedAmount, ns.amount) or not SGValues.equal(stock.materialRef, ns.materialRef) then
                reconcile(self, carrierId, ns, "UNEXPLAINED_CHANGE")
            else
                carrier.native = ns
            end
        end
    end
    for _, carrier in pairs(slotCarrier) do
        notify(self, "CARRIER", carrier.carrierId)
        self:notifyBinding(carrier, "READY")
    end
    return O.OUTCOME_COMMITTED, nil
end

--- Qualify captured participants after an unresolved settlement, then
--- reconcile whatever valid after-state was reported.
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
        local state = O.validateNativeState(ns)
        if self.carriers[carrierId] ~= nil and state ~= nil then reconcile(self, carrierId, state, reason) end
    end
end

function O:abandonOperation(handle, reason, participantsAfter)
    if type(handle) ~= "table" or self.openHandles[handle.operationId] ~= handle or not handle.open then return false, "HANDLE_CLOSED" end
    if self.busy then return false, "REENTRANT" end
    local st = self.handleState[handle.operationId]
    closeHandle(self, handle)
    local after = type(participantsAfter) == "table" and participantsAfter or nil
    if after == nil then
        -- Nothing observed after: facts stay, but the affected material is qualified as unproved.
        self:_qualifyCaptured(st.before, "ABANDONED:" .. tostring(reason), nil)
        return true, "QUALIFIED"
    end
    local changed = false
    for carrierId, ns in pairs(after) do
        local b = st.before.carriers[carrierId]
        local state = O.validateNativeState(ns)
        if state == nil then changed = true
        elseif b ~= nil and (not nearlyEqual(state.amount, b.amount) or not SGValues.equal(state.materialRef, b.materialRef)) then changed = true end
    end
    if not changed then return true, "NO_OP" end
    self:_qualifyCaptured(st.before, "ABANDONED:" .. tostring(reason), after)
    return true, "QUALIFIED"
end

-- ---------------------------------------------------------
-- Carrier pending: readCarrierPending / setCarrierPending
-- ---------------------------------------------------------
local function carrierAccess(self, carrier, actor)
    local lease = self.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, carrier.adapterId)
    if lease == nil then return false end
    local ok, allowed = pcall(lease.spec.hasAccess, copy(carrier.binding), copy(actor))
    return ok and allowed == true
end

function O:carrierHasPending(carrierId)
    local p = self.pending[carrierId]
    return p ~= nil and p.pendingTarget ~= nil
end

--- Detached pending snapshot for a carrier key under the registered owner.
function O:readCarrierPending(pendingLease, carrierKey, trustedActor)
    if not self.registry:isLive(pendingLease, SGRegistry.KIND_CARRIER_PENDING) then return { state = "DENIED", reason = "LEASE" } end
    local carrierId = SGRecords.carrierKeyString(carrierKey)
    if carrierId == nil then return { state = "REFUSED", reason = "CARRIER_KEY" } end
    local carrier = self.carriers[carrierId]
    if carrier == nil then return { state = "UNAVAILABLE", reason = "UNKNOWN_CARRIER" } end
    if trustedActor ~= nil and not carrierAccess(self, carrier, trustedActor) then return { state = "DENIED", reason = "ACCESS" } end
    local p = pendingOf(self, carrier, carrier.native and carrier.native.amount or 0)
    local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
    local out = {
        state = "READY", schema = O.PENDING_SCHEMA, carrierId = carrierId, empty = stock == nil and (carrier.native == nil or carrier.native.amount == 0),
        emptyEpoch = p.emptyEpoch, selectionRevision = p.selectionRevision, nativeContentState = p.nativeContentState,
        pendingTarget = copy(p.pendingTarget), boundStockRef = copy(p.boundStockRef), availability = p.availability, reason = p.reason,
    }
    if type(pendingLease.spec.disclosePending) == "function" then
        local ok, d = pcall(pendingLease.spec.disclosePending, { trustedActorContext = copy(trustedActor), carrierId = carrierId }, copy(out))
        if ok and type(d) == "table" then return d end
    end
    return out
end

--- Arm, clear or replace the pending target of an actually empty carrier
--- under both concurrency tokens. A mismatch refuses without change.
function O:setCarrierPending(pendingLease, carrierKey, expectedEmptyEpoch, expectedSelectionRevision, newTarget, trustedActor)
    if self.busy then return "REFUSED", { reason = "REENTRANT" } end
    if not self.registry:isLive(pendingLease, SGRegistry.KIND_CARRIER_PENDING) then return "REFUSED", { reason = "LEASE" } end
    local carrierId = SGRecords.carrierKeyString(carrierKey)
    if carrierId == nil then return "REFUSED", { reason = "CARRIER_KEY" } end
    local carrier = self.carriers[carrierId]
    if carrier == nil then return "UNAVAILABLE", { reason = "UNKNOWN_CARRIER" } end
    if trustedActor ~= nil and not carrierAccess(self, carrier, trustedActor) then return "REFUSED", { reason = "ACCESS" } end
    local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
    if stock ~= nil or (carrier.native ~= nil and carrier.native.amount > 0) then return "REFUSED", { reason = "NOT_EMPTY" } end
    local p = pendingOf(self, carrier, 0)
    if p.emptyEpoch ~= expectedEmptyEpoch or p.selectionRevision ~= expectedSelectionRevision then
        return "STALE", { reason = "TOKEN_MISMATCH", emptyEpoch = p.emptyEpoch, selectionRevision = p.selectionRevision }
    end
    if newTarget ~= nil then
        if type(newTarget) ~= "table" or not SGRecords.isPayloadTree(newTarget) then return "REFUSED", { reason = "TARGET" } end
        local ok, valid, reason = pcall(pendingLease.spec.validatePending, { carrierId = carrierId, trustedActorContext = copy(trustedActor), emptyEpoch = p.emptyEpoch, selectionRevision = p.selectionRevision }, copy(newTarget))
        if not ok then return "REFUSED", { reason = "TARGET_INVALID:ERROR" } end
        if valid ~= true then return "REFUSED", { reason = "TARGET_INVALID:" .. tostring(reason or "REFUSED") } end
    end
    p.pendingTarget = newTarget and copy(newTarget) or nil
    p.selectionRevision = p.selectionRevision + 1
    p.availability = "READY"
    p.reason = nil
    bump(self)
    notify(self, "CARRIER", carrierId)
    return "APPLIED", { emptyEpoch = p.emptyEpoch, selectionRevision = p.selectionRevision }
end

--- Canonical serialized collection (sorted rows keyed by the lossless
--- carrier key token encoding).
function O:serializePending()
    local ids = {}
    for id in pairs(self.pending) do ids[#ids + 1] = id end
    table.sort(ids)
    local rows = {}
    for _, id in ipairs(ids) do
        local p = self.pending[id]
        local carrier = self.carriers[id]
        rows[#rows + 1] = { key = id, carrierKey = carrier and copy(carrier.binding.carrierKey) or nil, emptyEpoch = p.emptyEpoch, selectionRevision = p.selectionRevision,
            nativeContentState = p.nativeContentState, pendingTarget = copy(p.pendingTarget), boundStockRef = copy(p.boundStockRef) }
    end
    return { schemaVersion = 1, rows = rows }
end

function O.validatePending(coll)
    if type(coll) ~= "table" or coll.schemaVersion ~= 1 or type(coll.rows) ~= "table" then return nil, "PENDING_SCHEMA" end
    local seen = {}
    for i, r in ipairs(coll.rows) do
        if type(r) ~= "table" or not nonempty(r.key, 2048) or seen[r.key] or not isInteger(r.emptyEpoch) or r.emptyEpoch < 1 or not isInteger(r.selectionRevision) or r.selectionRevision < 1 then return nil, "PENDING_ROW:" .. i end
        if r.carrierKey ~= nil and SGRecords.carrierKeyString(r.carrierKey) ~= r.key then return nil, "PENDING_KEY:" .. i end
        if r.pendingTarget ~= nil and not SGRecords.isPayloadTree(r.pendingTarget) then return nil, "PENDING_TARGET:" .. i end
        if r.boundStockRef ~= nil and not SGRecords.isStockRef(r.boundStockRef) then return nil, "PENDING_BOUND:" .. i end
        seen[r.key] = true
    end
    return coll
end

--- Restore pending rows onto their carriers. A row whose carrier is not
--- present stays retained on its key (unavailable); a row whose carrier is
--- now nonempty keeps its tokens with the target dropped as stale.
function O:restorePending(coll)
    local restored, retained = 0, 0
    for _, r in ipairs(coll.rows) do
        local carrier = self.carriers[r.key]
        local p = { emptyEpoch = r.emptyEpoch, selectionRevision = r.selectionRevision, nativeContentState = r.nativeContentState or "EMPTY", pendingTarget = copy(r.pendingTarget), boundStockRef = copy(r.boundStockRef), availability = "READY", reason = nil }
        if carrier == nil then
            p.availability = "UNAVAILABLE"
            p.reason = "CARRIER_ABSENT"
            retained = retained + 1
        else
            local stock = carrier.stockId and self.stocks[carrier.stockId] or nil
            if stock ~= nil and p.pendingTarget ~= nil then
                p.emptyEpoch = p.emptyEpoch + 1
                p.pendingTarget = nil
                p.reason = "FILLED_BEFORE_RESTORE"
            end
            p.nativeContentState = stock ~= nil and "NONEMPTY" or "EMPTY"
            restored = restored + 1
        end
        self.pending[r.key] = p
    end
    return { restored = restored, retained = retained }
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
    local key = nil
    if reg.causal then
        if reg.causalUnavailable then return O.PUBLISH.UNAVAILABLE, { reason = "CAUSAL_INTERPRETATION_UNAVAILABLE" } end
        if type(cause) ~= "table" then return O.PUBLISH.REFUSED, { reason = "MISSING_CAUSE" } end
        if not nonempty(cause.sourceStreamId, 128) or not isInteger(cause.epoch) or not isInteger(cause.sequence) or cause.sequence < 1 or not nonempty(cause.fingerprint, 4096) then
            return O.PUBLISH.REFUSED, { reason = "MALFORMED_CAUSE" }
        end
        key = causeKey(cause)
    elseif cause ~= nil and type(cause) ~= "table" then
        return O.PUBLISH.REFUSED, { reason = "MALFORMED_CAUSE" }
    end
    -- Validate the whole batch first; causal admission is per entry.
    local staged = {}
    local alreadyApplied = 0
    for i, r in ipairs(results) do
        if type(r) ~= "table" or not SGRecords.isStockRef(r.stockRef) or type(r.record) ~= "table" then return O.PUBLISH.REFUSED, { reason = "RESULT", index = i } end
        if r.record.propertyId ~= propertyId then return O.PUBLISH.REFUSED, { reason = "NOT_OWNER", index = i } end
        local stock = self.stocks[r.stockRef.stockId]
        if stock == nil then return O.PUBLISH.UNAVAILABLE, { reason = "STOCK_UNAVAILABLE", index = i } end
        if not sameRef(r.stockRef, self:stockRef(stock)) then return O.PUBLISH.STALE, { reason = "STOCK_REVISION", index = i, current = self:stockRef(stock) } end
        local current = stock.properties[propertyId]
        local currentRev = current and current.propertyRevision or 0
        local acc = key and stock.acceptedCauses[key] or nil
        local entryApplied = false
        if acc ~= nil then
            if acc.sequence == cause.sequence then
                if acc.fingerprint == cause.fingerprint then entryApplied = true
                else return O.PUBLISH.REFUSED, { reason = "CAUSE_CONFLICT", index = i } end
            elseif acc.sequence > cause.sequence then
                return O.PUBLISH.STALE, { reason = "CAUSE_SEQUENCE", index = i, current = acc.sequence }
            end
        end
        if entryApplied then
            alreadyApplied = alreadyApplied + 1
            staged[#staged + 1] = { stock = stock, applied = true, propertyRevision = currentRev }
        else
            if r.expectedPropertyRevision == nil then
                if currentRev ~= 0 then return O.PUBLISH.REFUSED, { reason = "EXPECTED_REVISION_REQUIRED", index = i } end
            elseif r.expectedPropertyRevision ~= currentRev then
                return O.PUBLISH.STALE, { reason = "PROPERTY_REVISION", index = i, current = currentRev }
            end
            local valid, why = self:validateResult(r.record, reg.producerId)
            if valid == nil then return O.PUBLISH.REFUSED, { reason = why, index = i } end
            if valid.basisAmount ~= nil and valid.basisAmount > stock.observedAmount + O.EPSILON then return O.PUBLISH.REFUSED, { reason = "COVERAGE_EXCEEDS_BASIS", index = i } end
            if reg.causal then
                local okC, accepted, whyC = pcall(reg.validateCause, copy(cause), acc and copy(acc) or nil, { stockRef = self:stockRef(stock), amount = stock.observedAmount })
                if not okC or accepted ~= true then return O.PUBLISH.REFUSED, { reason = "CAUSE_REJECTED:" .. tostring(okC and whyC or "ERROR"), index = i } end
            end
            staged[#staged + 1] = { stock = stock, record = valid }
        end
    end
    if alreadyApplied == #staged then
        return O.PUBLISH.ALREADY_APPLIED, { propertyRevision = staged[1].propertyRevision, stockRef = self:stockRef(staged[1].stock) }
    end
    -- Install the whole batch once; no callback inside.
    self.busy = true
    local defer = beginDefer(self)
    local installed = {}
    for _, s in ipairs(staged) do
        if not s.applied then
            local rec = installProperty(self, s.stock, s.record)
            s.stock.dataRevision = bump(self)
            rec.materialRevision = s.stock.dataRevision
            if reg.causal then s.stock.acceptedCauses[key] = { sequence = cause.sequence, fingerprint = cause.fingerprint } end
            s.stock.knowledge = O.knowledgeOf(s.stock)
            installed[#installed + 1] = { stockRef = self:stockRef(s.stock), propertyRevision = rec.propertyRevision }
            notify(self, "STOCK", s.stock.stockId)
        end
    end
    self.busy = false
    if defer then flushDeferred(self) end
    return O.PUBLISH.APPLIED, { installed = installed, alreadyApplied = alreadyApplied }
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
            snap.acceptedCauses = nil
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
        if type(cursor) ~= "table" or cursor.revision ~= self.revision or cursor.epoch ~= self.loadEpoch or not isInteger(cursor.position) or cursor.position < 1 then
            return { state = "STALE", reason = "CURSOR", records = {}, exhausted = false }
        end
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

local function validCaptured(c)
    if type(c) ~= "table" then return false, "CAPTURED" end
    if not nonempty(c.captureRef, 256) or not nonempty(c.allocationRef, 256) then return false, "CAPTURED_REFS" end
    if not SGRecords.isMaterialRef(c.materialRef) then return false, "CAPTURED_MATERIAL" end
    if not SGRecords.isAmount(c.actualAmount) or not nonempty(c.amountUnit, 32) then return false, "CAPTURED_AMOUNT" end
    if type(c.properties) ~= "table" then return false, "CAPTURED_PROPERTIES" end
    for _, p in pairs(c.properties) do
        if not SGRecords.isPropertyRecord(p) then return false, "CAPTURED_PROPERTY" end
    end
    if not SGRecords.KNOWLEDGE[c.knowledge] then return false, "CAPTURED_KNOWLEDGE" end
    return true
end

--- Pure mix preview: the owner's combine over admitted contributions, no
--- store change. The consumer's resolver admits the referenced stocks and
--- the purpose; captured contributions carry the FP1 v2.15 fields.
function O:readPropertyMix(consumerLease, contributions, context)
    if not self.registry:isLive(consumerLease, SGRegistry.KIND_CONSUMER) then return { state = "DENIED", reason = "LEASE", properties = {} } end
    if type(contributions) ~= "table" or #contributions == 0 then return { state = "REFUSED", reason = "CONTRIBUTIONS", properties = {} } end
    local spec = consumerLease.spec
    context = type(context) == "table" and context or {}
    local refs = {}
    for i, c in ipairs(contributions) do
        if type(c) ~= "table" or not SGRecords.isAmount(c.amount) or not nonempty(c.unit, 32) then return { state = "REFUSED", reason = "CONTRIBUTION:" .. i, properties = {} } end
        if c.stockRef ~= nil then
            if not SGRecords.isStockRef(c.stockRef) then return { state = "REFUSED", reason = "CONTRIBUTION_REFERENCE:" .. i, properties = {} } end
            refs[#refs + 1] = copy(c.stockRef)
        elseif c.capturedContribution ~= nil then
            local okC, why = validCaptured(c.capturedContribution)
            if not okC then return { state = "REFUSED", reason = why .. ":" .. i, properties = {} } end
        else
            return { state = "REFUSED", reason = "CONTRIBUTION_SOURCE:" .. i, properties = {} }
        end
    end
    local ok, ctx, reason = pcall(spec.resolveReadContext, { purpose = context.purpose, refs = copy(refs), stockRefs = copy(refs), mixPreview = true, context = copy(context) })
    if not ok then return { state = "ERROR", reason = "RESOLVE_ERROR", properties = {} } end
    if type(ctx) ~= "table" or type(ctx.stockRefs) ~= "table" then return { state = "DENIED", reason = tostring(reason or "CONTEXT_DENIED"), properties = {} } end
    local admitted = {}
    for _, r in ipairs(ctx.stockRefs) do if type(r) == "table" then admitted[r.stockId] = true end end
    local detached = {}
    local basis = 0
    for i, c in ipairs(contributions) do
        local d = { amount = c.amount, unit = c.unit, properties = {}, knowledge = "UNKNOWN" }
        if c.stockRef ~= nil then
            if not admitted[c.stockRef.stockId] then return { state = "DENIED", reason = "CONTRIBUTION_NOT_ADMITTED:" .. i, properties = {} } end
            local stock = self.stocks[c.stockRef.stockId]
            if stock == nil or not sameRef(c.stockRef, self:stockRef(stock)) then return { state = "STALE", reason = "CONTRIBUTION_REFERENCE:" .. i, properties = {} } end
            d.materialRef = copy(stock.materialRef)
            d.properties = copy(stock.properties)
            d.knowledge = stock.knowledge
        else
            local cc = c.capturedContribution
            d.captured = { captureRef = cc.captureRef, allocationRef = cc.allocationRef, actualAmount = cc.actualAmount, amountUnit = cc.amountUnit }
            d.properties = copy(cc.properties)
            d.knowledge = cc.knowledge
            d.materialRef = copy(cc.materialRef)
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
            local okM, result, why = pcall(reg.spec.combine, copy(context), copy(detached), nil)
            if not okM or result == nil then
                properties[pid] = SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, okM and tostring(why or "UNKNOWN") or "COMBINE_ERROR")
            else
                local rec = pickResult(result, pid, nil)
                local valid, whyV = self:validateResult(rec, reg.spec.producerId)
                properties[pid] = valid or SGRecords.unavailableProperty(pid, reg.spec.schemaVersion, reg.spec.producerId, "INVALID_RESULT:" .. tostring(whyV))
            end
        end
    end
    return { state = "READY", basis = { amount = basis }, purpose = ctx.purpose, properties = properties }
end

-- ---------------------------------------------------------
-- Serialization of core values (SG_SAVE_2.coreValues)
-- ---------------------------------------------------------
local function serializeStock(s)
    local props = {}
    local pids = {}
    for pid in pairs(s.properties) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do props[#props + 1] = copy(s.properties[pid]) end
    local causes = {}
    local ckeys = {}
    for k in pairs(s.acceptedCauses or {}) do ckeys[#ckeys + 1] = k end
    table.sort(ckeys)
    for _, k in ipairs(ckeys) do causes[#causes + 1] = { key = k, sequence = s.acceptedCauses[k].sequence, fingerprint = s.acceptedCauses[k].fingerprint } end
    return {
        stockId = s.stockId, contentsGeneration = s.contentsGeneration, dataRevision = s.dataRevision, carrierId = s.carrierId, carrierKey = copy(s.carrierKey),
        quantityBasisKey = s.quantityBasisKey, materialRef = copy(s.materialRef), observedAmount = s.observedAmount, amountUnit = s.amountUnit,
        knowledge = s.knowledge, reason = s.reason, properties = props, acceptedCauses = causes, retireReason = s.retireReason,
    }
end

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
    for _, id in ipairs(sids) do stocks[#stocks + 1] = serializeStock(self.stocks[id]) end
    -- Unresolved historical stocks (carrier absent or mismatched at the last
    -- load) travel until a load resolves them; bounded by the retired limit.
    local historical = {}
    local hids = {}
    for id, s in pairs(self.retiredStocks) do if s.historical then hids[#hids + 1] = id end end
    table.sort(hids)
    for _, id in ipairs(hids) do historical[#historical + 1] = serializeStock(self.retiredStocks[id]) end
    return { schemaVersion = 2, revision = self.revision, nextStock = self.nextStock, carriers = carriers, stocks = stocks, historical = historical }
end

local function validateSavedStock(s, i, label, carrierIds)
    if type(s) ~= "table" or not SGRecords.isStockRef({ stockId = s.stockId, contentsGeneration = s.contentsGeneration, dataRevision = s.dataRevision }) then return nil, label .. ":" .. i end
    if not nonempty(s.carrierId, 2048) or not SGRecords.isMaterialRef(s.materialRef) or not SGRecords.isAmount(s.observedAmount) or not nonempty(s.amountUnit, 32) then return nil, label .. ":" .. i end
    if carrierIds ~= nil and not carrierIds[s.carrierId] then return nil, label .. ":" .. i end
    if not SGRecords.KNOWLEDGE[s.knowledge] then return nil, label .. "_KNOWLEDGE:" .. i end
    for j, p in ipairs(s.properties or {}) do
        if not SGRecords.isPropertyRecord(p) then return nil, "CORE_PROPERTY:" .. i .. "." .. j end
    end
    for j, c in ipairs(s.acceptedCauses or {}) do
        if type(c) ~= "table" or not nonempty(c.key, 256) or not isInteger(c.sequence) or not nonempty(c.fingerprint, 4096) then return nil, "CORE_CAUSE:" .. i .. "." .. j end
    end
    return true
end

--- Validate a saved coreValues table (detached, no store change).
function O.validateCore(core)
    if type(core) ~= "table" or core.schemaVersion ~= 2 then return nil, "CORE_SCHEMA" end
    if type(core.carriers) ~= "table" or type(core.stocks) ~= "table" then return nil, "CORE_SHAPE" end
    if core.historical ~= nil and type(core.historical) ~= "table" then return nil, "CORE_SHAPE" end
    if not isInteger(core.nextStock) or core.nextStock < 0 then return nil, "CORE_COUNTER" end
    local carrierIds = {}
    for i, c in ipairs(core.carriers) do
        if type(c) ~= "table" or not nonempty(c.carrierId, 2048) or not SGRecords.isCarrierBinding(c.binding) or carrierIds[c.carrierId] then return nil, "CORE_CARRIER:" .. i end
        if SGRecords.carrierKeyString(c.binding.carrierKey) ~= c.carrierId then return nil, "CORE_CARRIER_KEY:" .. i end
        carrierIds[c.carrierId] = true
    end
    local stockIds = {}
    for i, s in ipairs(core.stocks) do
        local ok, why = validateSavedStock(s, i, "CORE_STOCK", carrierIds)
        if not ok then return nil, why end
        if stockIds[s.stockId] then return nil, "CORE_STOCK:" .. i end
        stockIds[s.stockId] = true
    end
    for i, s in ipairs(core.historical or {}) do
        local ok, why = validateSavedStock(s, i, "CORE_HISTORICAL", nil)
        if not ok then return nil, why end
        if stockIds[s.stockId] then return nil, "CORE_HISTORICAL:" .. i end
        stockIds[s.stockId] = true
    end
    return core
end

local function retainHistorical(self, saved, reason)
    local h = copy(saved)
    h.properties = {}
    for _, p in ipairs(saved.properties or {}) do h.properties[p.propertyId] = copy(p) end
    h.acceptedCauses = {}
    for _, c in ipairs(saved.acceptedCauses or {}) do h.acceptedCauses[c.key] = { sequence = c.sequence, fingerprint = c.fingerprint } end
    h.retired = true
    h.historical = true
    h.retireReason = reason
    h.readiness = "UNAVAILABLE"
    self.retiredStocks[saved.stockId] = h
end

--- Restore saved core values against the actual enumerated carriers. A
--- saved stock reattaches only when its carrier is present with the same
--- material and native amount (the bar's restore rule); otherwise the
--- native quantity stands with UNKNOWN knowledge and the saved facts are
--- retained as historical and persisted until a load resolves them.
function O:restoreCore(core)
    local restored, unknown, historical = 0, 0, 0
    if core.nextStock > self.nextStock then self.nextStock = core.nextStock end
    local saved = {}
    for _, s in ipairs(core.stocks) do saved[#saved + 1] = s end
    for _, s in ipairs(core.historical or {}) do saved[#saved + 1] = s end
    for _, s in ipairs(saved) do
        local carrier = self.carriers[s.carrierId]
        local live = carrier and carrier.stockId and self.stocks[carrier.stockId] or nil
        local nativeAmount = carrier and carrier.native and carrier.native.amount or nil
        local nativeMaterial = carrier and carrier.native and carrier.native.materialRef or nil
        if carrier ~= nil and live ~= nil and self.stocks[s.stockId] == nil and nativeAmount == s.observedAmount and SGValues.equal(nativeMaterial, s.materialRef) then
            -- Reattach: identity, generation, properties and causes carried; native quantity stands.
            self.stocks[live.stockId] = nil
            live.stockId = s.stockId
            live.contentsGeneration = s.contentsGeneration
            live.knowledge = s.knowledge
            live.reason = s.reason
            live.properties = {}
            for _, p in ipairs(s.properties or {}) do live.properties[p.propertyId] = copy(p) end
            live.acceptedCauses = {}
            for _, c in ipairs(s.acceptedCauses or {}) do live.acceptedCauses[c.key] = { sequence = c.sequence, fingerprint = c.fingerprint } end
            live.dataRevision = bump(self)
            self.stocks[s.stockId] = live
            carrier.stockId = s.stockId
            carrier.lastGeneration = math.max(carrier.lastGeneration or 0, s.contentsGeneration)
            self.retiredStocks[s.stockId] = nil
            restored = restored + 1
        elseif carrier ~= nil and live ~= nil then
            live.knowledge = "UNKNOWN"
            live.reason = "RESTORE_MISMATCH"
            if s.contentsGeneration >= live.contentsGeneration then
                live.contentsGeneration = s.contentsGeneration + 1
                carrier.lastGeneration = live.contentsGeneration
            end
            live.dataRevision = bump(self)
            unknown = unknown + 1
            retainHistorical(self, s, "RESTORE_MISMATCH")
        else
            retainHistorical(self, s, "CARRIER_ABSENT")
            historical = historical + 1
        end
    end
    pruneRetired(self)
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
    self.handleState = {}
    self.carriers = {}
    self.stocks = {}
    self.retiredStocks = {}
    self.pending = {}
    self._deferred = nil
    self.busy = false
end
