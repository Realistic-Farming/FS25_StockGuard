-- =========================================================
-- FS25_StockGuard - common records and the material model (SG-1 foundation)
-- =========================================================
-- Record validators for CarrierKey, CarrierBinding, StockRef, StockRecord,
-- materialRef and PropertyRecord as fixed in the SG-1 brief (4.4 Common
-- records), the knowledge vocabulary, the actor/carrier inspection predicate
-- (Section 5 Permissions and visibility) and the pure contents model the
-- reference bar pins: native restore, reconcile against an observed native
-- quantity, the recreated-object boundary (Clean R2) and detached views.
--
-- Nothing here touches a native object. Quantities are observed native
-- amounts; the model never adds, removes or recreates goods.
-- =========================================================

SGRecords = SGRecords or {}
local R = SGRecords

R.KNOWLEDGE = { KNOWN = true, PARTIAL = true, UNKNOWN = true, HISTORICAL = true, UNAVAILABLE = true }
R.COVERAGE = { KNOWN = "KNOWN", PARTIAL = "PARTIAL", UNKNOWN = "UNKNOWN", EMPTY = "EMPTY" }
R.MATERIAL_KINDS = { FILL_TYPE = true, NATIVE_GROUP = true }
R.MATERIAL_SCHEMA = "STOCK_MATERIAL_V2"
R.RESIDENCY = { STORED = true, OWNER_RESOLVED = true }
R.READINESS = { READY = true, RESTORING = true, UNAVAILABLE = true, PENDING = true }
R.AMOUNT_UNITS = { LITRE = true, KILOGRAM = true, COUNT = true, FRACTION = true, CURRENCY = true }
R.STORE_KINDS = { ordinary_station = true, per_farm_partition = true, production_inventory = true, vehicle = true, object = true, ground = true }

local isFinite = SGValues.isFinite
local isInteger = SGValues.isInteger
local copy = SGValues.copy
R.copy = copy

local function nonemptyString(s, maxBytes)
    return type(s) == "string" and s ~= "" and #s <= (maxBytes or 256)
end
R.nonemptyString = nonemptyString

-- ---------------------------------------------------------
-- Native farm constants (FarmManager.lua:2-8), bound with fallbacks so the
-- predicate is the same on a bench without the engine table.
-- ---------------------------------------------------------
function R.farmConstants()
    local fm = FarmManager
    return {
        spectator = fm and fm.SPECTATOR_FARM_ID or 0,
        singleplayer = fm and fm.SINGLEPLAYER_FARM_ID or 1,
        guidedTour = fm and fm.GUIDED_TOUR_FARM_ID or 14,
        invalid = fm and fm.INVALID_FARM_ID or 15,
        maxFarmId = fm and fm.MAX_FARM_ID or 8,
    }
end

--- An ordinary farm id: integral, 1..MAX_FARM_ID, never spectator/tour/invalid.
function R.isOrdinaryFarmId(farmId)
    if not isInteger(farmId) then return false end
    local c = R.farmConstants()
    if farmId <= c.spectator or farmId >= c.guidedTour or farmId == c.invalid then return false end
    return farmId <= c.maxFarmId
end

-- ---------------------------------------------------------
-- Record validators
-- ---------------------------------------------------------
function R.isCarrierKey(k)
    return type(k) == "table" and nonemptyString(k.adapterId, 64) and nonemptyString(k.nativeOwnerKey, 512)
        and nonemptyString(k.componentKey, 256)
end

function R.carrierKeyString(k)
    if not R.isCarrierKey(k) then return nil end
    return SGValues.canonicalKey({ adapterId = k.adapterId, nativeOwnerKey = k.nativeOwnerKey, componentKey = k.componentKey })
end

function R.isMaterialRef(m)
    if type(m) ~= "table" then return false end
    if m.kind == "FILL_TYPE" then return nonemptyString(m.fillTypeName, 128) and m.groupId == nil end
    if m.kind == "NATIVE_GROUP" then return nonemptyString(m.groupId, 128) and m.fillTypeName == nil end
    return false
end

function R.isStockRef(s)
    return type(s) == "table" and nonemptyString(s.stockId, 128) and isInteger(s.contentsGeneration)
        and s.contentsGeneration >= 1 and nonemptyString(s.dataRevision, 64)
end

function R.isCarrierBinding(b)
    if type(b) ~= "table" or not R.isCarrierKey(b.carrierKey) then return false end
    if not isInteger(b.adapterVersion) or b.adapterVersion < 1 then return false end
    if not nonemptyString(b.profileId, 128) or not isInteger(b.profileVersion) or b.profileVersion < 1 then return false end
    if b.sourceDescriptor ~= nil and type(b.sourceDescriptor) ~= "table" then return false end
    if not nonemptyString(b.quantityBasisKey, 512) then return false end
    if b.aliasOf ~= nil and not nonemptyString(b.aliasOf, 512) then return false end
    return true
end

function R.isAmount(n)
    return isFinite(n) and n >= 0
end

--- PropertyRecord validator. Coverage is finite with 0 <= knownAmount <=
--- basisAmount in one unit; unavailable coverage is absent.
function R.isPropertyRecord(p)
    if type(p) ~= "table" then return false, "NOT_TABLE" end
    if not nonemptyString(p.propertyId, 128) then return false, "PROPERTY_ID" end
    if not isInteger(p.schemaVersion) or p.schemaVersion < 1 then return false, "SCHEMA_VERSION" end
    if not nonemptyString(p.producerId, 64) then return false, "PRODUCER_ID" end
    if not isInteger(p.propertyRevision) or p.propertyRevision < 0 then return false, "PROPERTY_REVISION" end
    if p.materialRevision ~= nil and not nonemptyString(p.materialRevision, 64) then return false, "MATERIAL_REVISION" end
    if not R.KNOWLEDGE[p.knowledge] then return false, "KNOWLEDGE" end
    if p.knownAmount ~= nil or p.basisAmount ~= nil then
        if not R.isAmount(p.knownAmount) or not R.isAmount(p.basisAmount) then return false, "COVERAGE" end
        if p.knownAmount > p.basisAmount then return false, "COVERAGE" end
        if not nonemptyString(p.amountUnit, 32) then return false, "AMOUNT_UNIT" end
    end
    if p.observedGameDay ~= nil and not isInteger(p.observedGameDay) then return false, "GAME_DAY" end
    if p.payload ~= nil and not R.isPayloadTree(p.payload, 0) then return false, "PAYLOAD" end
    if p.causalState ~= nil and type(p.causalState) ~= "table" then return false, "CAUSAL_STATE" end
    return true
end

--- Typed value tree: absent, boolean, finite number, string, ordered list or
--- string-keyed map.
function R.isPayloadTree(v, depth)
    depth = depth or 0
    if depth > 32 then return false end
    local t = type(v)
    if v == nil or t == "boolean" or t == "string" then return true end
    if t == "number" then return isFinite(v) end
    if t ~= "table" then return false end
    local array = SGValues.isArray(v)
    for k, item in pairs(v) do
        if not array and type(k) ~= "string" then return false end
        if not R.isPayloadTree(item, depth + 1) then return false end
    end
    return true
end

--- A detached, knowledge-bearing property placeholder for an unavailable fact.
function R.unavailableProperty(propertyId, schemaVersion, producerId, reason, materialRevision)
    return {
        propertyId = propertyId, schemaVersion = schemaVersion or 1, producerId = producerId or "unknown",
        propertyRevision = 0, materialRevision = materialRevision, knowledge = "UNAVAILABLE", reason = reason,
    }
end

-- ---------------------------------------------------------
-- Actor and carrier inspection (Section 5)
-- ---------------------------------------------------------
--- May this actor inspect this store? Spectator, guided tour and invalid
--- farms never read stock. Ordinary stations need the actual native station
--- access predicate; per-farm partitions are exact-owner data (owner and
--- station access); production inventory is owner-only.
function R.canInspect(actor, store)
    if type(actor) ~= "table" or type(store) ~= "table" then return false end
    if actor.spectator == true then return false end
    if not R.isOrdinaryFarmId(actor.farm) then return false end
    if store.kind == "ordinary_station" then return store.stationAccess == true end
    if store.kind == "per_farm_partition" then
        return actor.farm == store.ownerFarm and store.stationAccess == true
    end
    if store.kind == "production_inventory" or store.kind == "vehicle" or store.kind == "object" then
        return actor.farm == store.ownerFarm
    end
    if store.kind == "ground" then
        return store.landAccess == true
    end
    return false
end

-- ---------------------------------------------------------
-- Contents model (reference bar semantics)
-- ---------------------------------------------------------
--- Build a record for a container with an observed quantity and a known share.
function R.record(containerId, ownerFarm, kind, quantity, generation, knownQuantity)
    knownQuantity = knownQuantity or 0
    return {
        containerId = containerId,
        ownerFarm = ownerFarm,
        kind = kind,
        quantity = quantity,
        generation = generation,
        knownQuantity = knownQuantity,
        unknownQuantity = quantity - knownQuantity,
        coverage = (knownQuantity == quantity) and "KNOWN" or "PARTIAL",
    }
end

--- Native restore: the saved record is reattached only when identity, kind
--- and quantity agree with the reconstructed native object; anything else is
--- UNKNOWN coverage over the native quantity. Restore writes are
--- observations, never live operations, and never invent a known share.
function R.restore(saved, native)
    if type(saved) ~= "table" or type(native) ~= "table" then return nil end
    if saved.containerId ~= native.containerId or saved.kind ~= native.kind or saved.quantity ~= native.quantity then
        return {
            containerId = native.containerId, kind = native.kind, ownerFarm = saved.ownerFarm,
            state = "UNKNOWN", coverage = "UNKNOWN", knownQuantity = 0, unknownQuantity = native.quantity,
            generation = saved.generation, quantity = native.quantity,
        }
    end
    local restored = copy(saved)
    restored.quantity = native.quantity
    return restored
end

--- Reconcile a record against an observed native quantity and kind. A kind
--- change is unknown material; zero ends the generation (EMPTY); a fill
--- after empty starts a new generation with unknown history; an unexplained
--- increase keeps the known portion and adds unknown; a decrease scales both
--- shares uniformly.
function R.reconcile(old, observedQuantity, observedKind)
    local nextRecord = copy(old)
    if observedKind ~= old.kind then
        nextRecord.kind = observedKind
        nextRecord.quantity = observedQuantity
        nextRecord.knownQuantity = 0
        nextRecord.unknownQuantity = observedQuantity
        nextRecord.coverage = "UNKNOWN"
        return nextRecord
    end
    if observedQuantity == 0 then
        nextRecord.quantity = 0
        nextRecord.knownQuantity = 0
        nextRecord.unknownQuantity = 0
        nextRecord.coverage = "EMPTY"
        return nextRecord
    end
    if old.quantity == 0 then
        nextRecord.generation = old.generation + 1
        nextRecord.quantity = observedQuantity
        nextRecord.knownQuantity = 0
        nextRecord.unknownQuantity = observedQuantity
        nextRecord.coverage = "UNKNOWN"
        return nextRecord
    end
    if observedQuantity > old.quantity then
        local unexplained = observedQuantity - old.quantity
        nextRecord.quantity = observedQuantity
        nextRecord.knownQuantity = old.knownQuantity
        nextRecord.unknownQuantity = old.unknownQuantity + unexplained
        nextRecord.coverage = "PARTIAL"
        return nextRecord
    end
    nextRecord.quantity = observedQuantity
    nextRecord.knownQuantity = old.knownQuantity * observedQuantity / old.quantity
    nextRecord.unknownQuantity = observedQuantity - nextRecord.knownQuantity
    nextRecord.coverage = (nextRecord.unknownQuantity == 0) and "KNOWN" or "PARTIAL"
    return nextRecord
end

--- Detached view of a record; the caller may edit it freely.
function R.view(store)
    return copy({
        stockId = store.containerId,
        generation = store.generation,
        quantity = store.quantity,
        properties = { coverage = store.coverage, knownQuantity = store.knownQuantity },
    })
end

--- Clean R2 boundary: a world object that keeps its admitted native
--- uniqueId with a proved association keeps carrier, generation and
--- knowledge; anything recreated without proof is a new carrier with a new
--- contents generation, native quantity retained, knowledge UNAVAILABLE and
--- reason OBJECT_RECREATED_UNBOUND. Never match by owner, type, amount,
--- slot order, position or time.
function R.recreate(old, newObject, associationProved)
    if associationProved == true and newObject.uniqueId ~= nil and newObject.uniqueId == old.nativeUniqueId then
        return { carrierKey = old.carrierKey, generation = old.generation, quantity = newObject.quantity, knowledge = old.knowledge }
    end
    return { carrierKey = newObject.carrierKey, generation = 1, quantity = newObject.quantity, knowledge = "UNAVAILABLE", reason = "OBJECT_RECREATED_UNBOUND" }
end
