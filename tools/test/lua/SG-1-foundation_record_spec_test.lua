-- Reference bar ported verbatim from the SG-1 delivery package (tracking repo); its trailing T.summary() is supplied by run-tests.mjs.
-- MODELED reference-contract spec. It does not claim that production APIs exist.

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = clone(item) end
    return out
end

local function record(container, farm, kind, quantity, generation, knownQuantity)
    return {
        containerId = container,
        ownerFarm = farm,
        kind = kind,
        quantity = quantity,
        generation = generation,
        knownQuantity = knownQuantity,
        unknownQuantity = quantity - knownQuantity,
        coverage = knownQuantity == quantity and "KNOWN" or "PARTIAL"
    }
end

local function restore(saved, native)
    -- Restore writes are bracketed. They are observations, not live operations.
    if saved.containerId ~= native.containerId or saved.kind ~= native.kind or saved.quantity ~= native.quantity then
        return { state = "UNKNOWN", coverage = "UNKNOWN", knownQuantity = 0, unknownQuantity = native.quantity, generation = saved.generation, quantity = native.quantity }
    end
    local restored = clone(saved)
    restored.quantity = native.quantity
    return restored
end

local function reconcile(old, observedQuantity, observedKind)
    local nextRecord = clone(old)
    if observedKind ~= old.kind then
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
    nextRecord.coverage = nextRecord.unknownQuantity == 0 and "KNOWN" or "PARTIAL"
    return nextRecord
end

local function canInspect(actor, store)
    if actor.farm == nil or actor.spectator or actor.farm <= 0 or actor.farm >= 14 then return false end
    if store.kind == "ordinary_station" then return store.stationAccess == true end
    if store.kind == "per_farm_partition" then
        return actor.farm == store.ownerFarm and store.stationAccess == true
    end
    if store.kind == "production_inventory" then return actor.farm == store.ownerFarm end
    return false
end

local function view(store)
    return clone({
        stockId = store.containerId,
        generation = store.generation,
        quantity = store.quantity,
        properties = { coverage = store.coverage, knownQuantity = store.knownQuantity }
    })
end

local saved = record("silo-A", 1, "grain", 100, 7, 100)
local nativeAfterLoad = { containerId = "silo-A", kind = "grain", quantity = 100 }
local loaded = restore(saved, nativeAfterLoad)
T.eq("native restore preserves generation", loaded.generation, 7)
T.eq("native restore preserves known coverage", loaded.coverage, "KNOWN")
T.eq("native restore does not create unknown litres", loaded.unknownQuantity, 0)

local badRestore = reconcile(record("silo-A", 1, "grain", 0, 7, 0), 100, "grain")
T.ok("bad control witness: treating restore refill as live violates contract", badRestore.generation ~= saved.generation)

local increased = reconcile(saved, 140, "grain")
T.eq("unexplained increase keeps known portion", increased.knownQuantity, 100)
T.eq("unexplained increase is unknown only for added amount", increased.unknownQuantity, 40)
T.eq("partial coverage is explicit", increased.coverage, "PARTIAL")

local emptied = reconcile(increased, 0, "grain")
T.eq("emptying clears current quantity", emptied.quantity, 0)
T.eq("emptying clears property coverage", emptied.coverage, "EMPTY")
local refilled = reconcile(emptied, 60, "grain")
T.eq("later refill starts a new generation", refilled.generation, 8)
T.eq("new generation has unknown history", refilled.coverage, "UNKNOWN")

local storeA = record("partition-A", 1, "grain", 20, 3, 20)
local storeB = record("partition-B", 1, "grain", 80, 4, 80)
local changedA = reconcile(storeA, 25, "grain")
T.eq("one store change leaves another store quantity intact", storeB.quantity, 80)
T.eq("one store change leaves another generation intact", storeB.generation, 4)
T.near("changed store quantity is observed exactly", changedA.quantity, 25, 0)

local contractor = { farm = 2, spectator = false }
local ordinary = { kind = "ordinary_station", ownerFarm = 1, stationAccess = true }
local partition = { kind = "per_farm_partition", ownerFarm = 1, stationAccess = true }
local production = { kind = "production_inventory", ownerFarm = 1, stationAccess = true }
T.ok("same contractor may inspect ordinary station", canInspect(contractor, ordinary))
T.ok("contractor cannot inspect another farm partition", not canInspect(contractor, partition))
T.ok("contractor cannot inspect production inventory", not canInspect(contractor, production))

local detached = view(increased)
detached.properties.coverage = "CHANGED_BY_CALLER"
detached.quantity = 1
T.eq("snapshot is detached from record properties", increased.coverage, "PARTIAL")
T.eq("snapshot is detached from record quantity", increased.quantity, 140)

local reduced = reconcile(increased, 70, "grain")
T.near("uniform decrease preserves known share", reduced.knownQuantity, 50, 0.000001)
T.near("uniform decrease preserves unknown share", reduced.unknownQuantity, 20, 0.000001)
local mismatch = restore(saved, { containerId = "silo-A", kind = "grain", quantity = 140 })
T.eq("restore mismatch cannot recertify extra native material", mismatch.coverage, "UNKNOWN")
T.eq("restore mismatch retains native quantity", mismatch.quantity, 140)
T.eq("restore mismatch invents no known share", mismatch.knownQuantity, 0)
T.ok("spectator equality cannot disclose stock", not canInspect({ farm = 0 }, { kind = "production_inventory", ownerFarm = 0 }))
T.ok("guided tour is not an ordinary stock actor", not canInspect({ farm = 14 }, { kind = "ordinary_station", stationAccess = true }))
T.ok("ordinary station refusal is preserved", not canInspect(contractor, { kind = "ordinary_station", stationAccess = false }))

-- Clean R2 first-handoff boundary for object stores that destroy and recreate
-- native objects. This is a reference contract, not native object-storage proof.
local function recreate(old,newObject,associationProved)
    if associationProved and newObject.uniqueId~=nil and newObject.uniqueId==old.nativeUniqueId then
        return {carrierKey=old.carrierKey,generation=old.generation,quantity=newObject.quantity,knowledge=old.knowledge}
    end
    return {carrierKey=newObject.carrierKey,generation=1,quantity=newObject.quantity,knowledge="UNAVAILABLE",reason="OBJECT_RECREATED_UNBOUND"}
end
local oldObject={carrierKey="bale-old",nativeUniqueId="U1",generation=6,knowledge="KNOWN"}
local storedOut=recreate(oldObject,{carrierKey="bale-new",quantity=4000},false)
T.eq("recreated object is a new carrier",storedOut.carrierKey,"bale-new")
T.eq("recreated object cannot borrow old generation",storedOut.generation,1)
T.eq("recreated object preserves native quantity",storedOut.quantity,4000)
T.eq("unproved object-store history is unavailable",storedOut.knowledge,"UNAVAILABLE")
T.eq("unproved object-store reason is explicit",storedOut.reason,"OBJECT_RECREATED_UNBOUND")
local direct=recreate(oldObject,{carrierKey="bale-old",uniqueId="U1",quantity=3900},true)
T.eq("proved world-bale identity keeps carrier",direct.carrierKey,"bale-old")
T.eq("proved world-bale identity keeps generation",direct.generation,6)
T.eq("proved world-bale identity keeps known history",direct.knowledge,"KNOWN")

