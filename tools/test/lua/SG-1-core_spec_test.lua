-- SG-1-core_spec_test.lua - the foundation's production modules against the
-- reference bar semantics: codec, records, farm restore coordinator,
-- registry leases, material store operations and the save envelope.
--
--!load: src/capacity/SGSha256.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua

FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15, MAX_FARM_ID = 8, MAX_NUM_FARMS = 8 }
local V, R, F = SGValues, SGRecords, SGFarmRestore

-- (A) SG_VALUES_2 codec
do
    local tree = { name = "silo", amount = 12.5, count = 3, ok = true, none = nil, list = { "a", 2, false, { k = "v" } }, nested = { z = "last", a = "first" } }
    local tokens = V.encode(tree)
    T.eq("A1 prefix format and version", tokens[1] .. "/" .. tokens[2], "SG_VALUES/2")
    local back, why = V.decode(tokens)
    T.eq("A2 roundtrip decodes without reason", why, nil)
    T.ok("A3 roundtrip is structurally equal", V.equal(back, tree))
    T.eq("A4 integer encodes with I", (function() for i = 3, #tokens - 1 do if tokens[i] == "count" then return tokens[i + 1] end end end)(), "I")
    T.eq("A5 real encodes with R", (function() for i = 3, #tokens - 1 do if tokens[i] == "amount" then return tokens[i + 1] end end end)(), "R")
    local sorted = V.encodeBare({ b = 1, a = 2 })
    T.eq("A6 map keys sort by bytes", sorted[3] .. sorted[6], "ab")
    T.eq("A7 duplicate key refuses", select(2, V.decodeBare({ "M", "2", "a", "I", "1", "a", "I", "2" })), "DUPLICATE_KEY")
    T.eq("A8 unsorted key refuses", select(2, V.decodeBare({ "M", "2", "b", "I", "1", "a", "I", "2" })), "UNSORTED_KEY")
    T.eq("A9 trailing tokens refuse", select(2, V.decodeBare({ "I", "1", "S" })), "TRAILING_TOKENS")
    T.eq("A10 unknown tag refuses", select(2, V.decodeBare({ "Q", "1" })), "UNKNOWN_TAG")
    T.eq("A11 count beyond remaining refuses", select(2, V.decodeBare({ "L", "5", "I", "1" })), "BAD_COUNT")
    T.eq("A12 unsupported format refuses", select(2, V.decode({ "SG_VALUES", "3", "N" })), "UNSUPPORTED_FORMAT")
    T.eq("A13 non-finite refuses to encode", select(2, V.encode({ x = 0 / 0 })), "NON_FINITE")
    T.eq("A14 leading zero integer refuses", select(2, V.decodeBare({ "I", "007" })), "BAD_INTEGER")
    T.eq("A15 selectionKey is length-prefixed", V.selectionKey({ "ab", "" , "c:d" }), "2:ab0:3:c:d")
    T.eq("A16 canonical key ignores construction order", V.canonicalKey({ a = 1, b = { c = 2 } }), V.canonicalKey({ b = { c = 2 }, a = 1 }))
    T.eq("A17 incrementDecimal carries", V.incrementDecimal("199") .. "/" .. V.incrementDecimal("9") .. "/" .. V.incrementDecimal("0"), "200/10/1")
    T.eq("A18 compareDecimal by length then bytes", V.compareDecimal("9", "10") .. "/" .. V.compareDecimal("21", "12") .. "/" .. V.compareDecimal("5", "5"), "-1/1/0")
    T.eq("A19 empty table encodes as empty list", V.encodeBare({})[1] .. V.encodeBare({})[2], "L0")
    T.eq("A20 absent decodes to nil with no reason", select(2, V.decode({ "SG_VALUES", "2", "N" })), nil)
end

-- (B) Records
do
    T.ok("B1 carrier key needs three nonempty strings", R.isCarrierKey({ adapterId = "sg2", nativeOwnerKey = "u1", componentKey = "c1" }) and not R.isCarrierKey({ adapterId = "sg2", nativeOwnerKey = "", componentKey = "c1" }))
    T.ok("B2 material ref kinds are exclusive", R.isMaterialRef({ kind = "FILL_TYPE", fillTypeName = "WHEAT" }) and R.isMaterialRef({ kind = "NATIVE_GROUP", groupId = "robot.spot" }) and not R.isMaterialRef({ kind = "FILL_TYPE", fillTypeName = "WHEAT", groupId = "x" }))
    T.ok("B3 stock ref shape", R.isStockRef({ stockId = "s1", contentsGeneration = 1, dataRevision = "3" }) and not R.isStockRef({ stockId = "s1", contentsGeneration = 0, dataRevision = "3" }))
    local p = { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 1, knowledge = "KNOWN", knownAmount = 10, basisAmount = 10, amountUnit = "LITRE", payload = { value = 0.14 } }
    T.ok("B4 property record accepted", R.isPropertyRecord(p))
    p.knownAmount = 11
    T.eq("B5 known above basis refuses", select(2, R.isPropertyRecord(p)), "COVERAGE")
    p.knownAmount = 0
    T.ok("B6 known zero is a valid value", R.isPropertyRecord(p))
    T.eq("B7 unknown knowledge refuses", select(2, R.isPropertyRecord({ propertyId = "x", schemaVersion = 1, producerId = "p", propertyRevision = 0, knowledge = "GOOD" })), "KNOWLEDGE")
    T.ok("B8 ordinary farm ids are 1..8", R.isOrdinaryFarmId(1) and R.isOrdinaryFarmId(8) and not R.isOrdinaryFarmId(0) and not R.isOrdinaryFarmId(9) and not R.isOrdinaryFarmId(14) and not R.isOrdinaryFarmId(1.5))
    local contractor = { farm = 2, spectator = false }
    T.ok("B9 contractor inspects an ordinary station with access", R.canInspect(contractor, { kind = "ordinary_station", ownerFarm = 1, stationAccess = true }))
    T.ok("B10 contractor cannot inspect another farm partition", not R.canInspect(contractor, { kind = "per_farm_partition", ownerFarm = 1, stationAccess = true }))
    T.ok("B11 spectator never inspects", not R.canInspect({ farm = 0 }, { kind = "production_inventory", ownerFarm = 0 }))
    local saved = R.record("silo-A", 1, "grain", 100, 7, 100)
    T.eq("B12 restore preserves generation on a match", R.restore(saved, { containerId = "silo-A", kind = "grain", quantity = 100 }).generation, 7)
    T.eq("B13 restore mismatch is UNKNOWN over the native quantity", R.restore(saved, { containerId = "silo-A", kind = "grain", quantity = 140 }).coverage, "UNKNOWN")
    local inc = R.reconcile(saved, 140, "grain")
    T.eq("B14 unexplained increase keeps the known share", inc.knownQuantity .. "/" .. inc.unknownQuantity, "100/40")
    T.eq("B15 refill after empty starts a new generation", R.reconcile(R.reconcile(inc, 0, "grain"), 60, "grain").generation, 8)
    T.eq("B16 recreated object without proof is unbound", R.recreate({ carrierKey = "old", nativeUniqueId = "U1", generation = 6, knowledge = "KNOWN" }, { carrierKey = "new", quantity = 4000 }, false).reason, "OBJECT_RECREATED_UNBOUND")
end

-- (C) Farm restore coordinator and owned hooks
do
    local reserved = F.specialFarmIds()
    local m = F.mapping(false, { 0, 1, 2, 3, 14 }, { [2] = 1, [3] = 1 }, 1, reserved)
    T.eq("C1 mapping accepts the observed merge", m[2] .. m[3], "11")
    T.eq("C2 receipt sequence decodes", F.receiptMap({ { sourceFarmId = 2, targetFarmId = 1 }, { sourceFarmId = 3, targetFarmId = 1 } }, 1)[3], 1)
    T.eq("C3 receipt rows are canonical", F.receiptRows({ [3] = 1, [2] = 1 })[1].sourceFarmId, 2)
    local coord = F.new("7")
    T.eq("C4 fresh coordinator waits", coord.phase, "WAITING")
    local staged = {}
    coord.onStage = function(c, payload, context) staged[#staged + 1] = { payload = payload, context = context } end
    coord:retainPayload({ firstUse = true }, "ledger")
    T.eq("C5 payload before farms does not stage", #staged, 0)
    g_currentMission.missionDynamicInfo = { isMultiplayer = false }
    local fm = { farms = { { farmId = 0 }, { farmId = 1 }, { farmId = 2 }, { farmId = 3 }, { farmId = 14 } }, farmIdToFarm = { [1] = {} } }
    coord:observeBeforeMerge(fm)
    fm.mergedFarms = { [2] = 1, [3] = 1 }
    coord:observeAfterMerge(fm)
    T.eq("C6 merge observed resolves MERGED", coord.phase, "MERGED")
    T.eq("C7 farms alone do not stage", #staged, 0)
    coord:observeNativeReady()
    T.eq("C8 both barriers stage once with the merged context", #staged .. "/" .. staged[1].context.phase .. "/" .. tostring(staged[1].context.sourceToTarget[2]), "1/MERGED/1")
    coord:observeNativeReady()
    coord:retainPayload({ firstUse = true }, "ledger")
    T.eq("C9 repeat callbacks stage once", #staged, 1)
    local mp = F.new("8")
    g_currentMission.missionDynamicInfo = { isMultiplayer = true }
    mp:observeBeforeMerge({ farms = { { farmId = 1 }, { farmId = 2 } } })
    mp:observeAfterMerge({ farms = {}, mergedFarms = nil })
    T.eq("C10 multiplayer resolves UNCHANGED with an empty map", mp.phase .. "/" .. tostring(next(mp.sourceToTarget)), "UNCHANGED/nil")
    local bad = F.new("9")
    g_currentMission.missionDynamicInfo = { isMultiplayer = false }
    bad:observeBeforeMerge({ farms = { { farmId = 1 }, { farmId = 2 } } })
    bad:observeAfterMerge({ farms = {}, mergedFarms = { [7] = 1 }, farmIdToFarm = { [1] = {} } })
    T.eq("C11 disagreeing native map is FAILED", bad.phase, "FAILED")
    local late = F.new("10")
    late.onStage = function(c, payload, context) staged[#staged + 1] = { payload = payload, context = context } end
    late:observeBeforeMerge({ farms = { { farmId = 1 } } })
    late:observeAfterMerge({ farms = {}, farmIdToFarm = { [1] = {} } })
    late:observeNativeReady()
    T.eq("C12 native ready waits for the payload", #staged, 1)
    late:retainPayload({ firstUse = true }, "xml")
    T.eq("C13 late payload uses the retained context", #staged .. "/" .. staged[2].context.phase, "2/UNCHANGED")
    -- Owned hooks: one class wrapper, delegate called once, token per mission.
    local calls = 0
    FarmManager.mergeFarmsForSingleplayer = function(self) calls = calls + 1 self.mergedFarms = { [2] = 1 } return "native" end
    FarmManager.loadDefaults = function(self) return "defaults" end
    local native = FarmManager.mergeFarmsForSingleplayer
    F.installHooks()
    T.ok("C14 class method is wrapped", FarmManager.mergeFarmsForSingleplayer ~= native)
    local hooked = F.new("11")
    F.setCurrent(hooked)
    local fm2 = { farms = { { farmId = 1 }, { farmId = 2 } }, farmIdToFarm = { [1] = {} } }
    T.eq("C15 wrapper returns the native result", FarmManager.mergeFarmsForSingleplayer(fm2), "native")
    T.eq("C16 native delegate called exactly once", calls, 1)
    T.eq("C17 wrapper observed the merge", hooked.phase .. "/" .. tostring(hooked.sourceToTarget[2]), "MERGED/1")
    F.setCurrent(nil)
    FarmManager.mergeFarmsForSingleplayer(fm2)
    T.eq("C18 without a token the wrapper is a pure delegate", calls, 2)
    local ours = FarmManager.mergeFarmsForSingleplayer
    local foreign = function(self, ...) return ours(self, ...) end
    FarmManager.mergeFarmsForSingleplayer = foreign
    F.removeHooks()
    T.eq("C19 a foreign wrapper around ours is left in place", FarmManager.mergeFarmsForSingleplayer, foreign)
    T.eq("C20 the defaults wrapper is restored when still ours", FarmManager.loadDefaults(fm2), "defaults")
    FarmManager.mergeFarmsForSingleplayer = native
    -- Native-field normalisation and canPublish as in the bar.
    local nc = { server = true, loaded = false, mp = false, phase = "MERGED", mapAgrees = true, map = m }
    local pallet = { admitted = true, class = "Vehicle", palletAttributes = { ownerFarmId = 2, fillLevel = 475 } }
    F.normalize(pallet, nc)
    F.normalize(pallet, nc)
    T.eq("C21 stored pallet owner converts once", pallet.palletAttributes.ownerFarmId .. "/" .. pallet.ownerWrites, "1/1")
    T.eq("C22 multiplayer never normalises", F.normalize({ admitted = true, class = "Bale", baleAttributes = { farmId = 2 } }, { server = true, loaded = false, mp = true, phase = "MERGED", mapAgrees = true, map = m }), false)
    T.eq("C23 canPublish needs the corrected actual owner", tostring(F.canPublish(2, 1, m)) .. "/" .. tostring(F.canPublish(2, 2, m)), "true/false")
end

-- (D) Registry leases
local registry = SGRegistry.new("1")
local adapterSpec, carriersOut = nil, {}
do
    adapterSpec = {
        version = 1, carrierKinds = { "silo" }, materialGroups = {},
        resolveCarrier = function() end, readNativeState = function() end, enumerateCarriers = function() return carriersOut end,
        hasAccess = function(binding, actor) return actor.farmId == 1 end,
    }
    T.eq("D1 adapter spec without callbacks refuses", select(2, registry:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" } })), "CALLBACKS")
    local lease = registry:registerCarrierAdapter("sg2", adapterSpec)
    T.ok("D2 adapter lease issued and live", lease ~= nil and registry:isLive(lease, SGRegistry.KIND_CARRIER_ADAPTER))
    T.eq("D3 duplicate live owner refuses", select(2, registry:registerCarrierAdapter("sg2", adapterSpec)), "DUPLICATE_OWNER")
    local forged = { leaseId = lease.leaseId, kind = lease.kind, ownerId = "sg2", epoch = "1", live = true }
    T.ok("D4 a matching id is not a credential", not registry:isLive(forged))
    T.eq("D5 unregister with a forged lease refuses", select(2, registry:unregisterOwner(forged)), "NOT_LIVE")
    T.eq("D6 property needs residency callbacks for OWNER_RESOLVED", select(2, registry:registerProperty("soil.x", { schemaVersion = 1, producerId = "soil", residency = "OWNER_RESOLVED", validate = function() end, combine = function() end, transform = function() end, disclosure = function() end })), "RESIDENT_CALLBACKS")
    T.eq("D7 consumer needs admitted material kinds", select(2, registry:registerConsumer("fp1", { version = 1, requiredSchemas = {}, materialKinds = { "PILE" }, resolveReadContext = function() end })), "MATERIAL_KINDS")
    T.eq("D8 management owner target kinds exclude OBSERVATION", select(2, registry:registerManagementOwner("native", { version = 1, targetKinds = { "OBSERVATION" }, enumerateTargets = function() end, resolveTarget = function() end, readTarget = function() end, hasAccess = function() end, getActions = function() end, invoke = function() end })), "TARGET_KINDS")
    local v = SGRegistry.validateAction({}, { actionId = "SET", targetKind = "PROCESS", targetId = "p1", expectedRevision = "1", argumentSchemaId = "S1", controlKind = "MYSTERY", admission = "DIRECT_DESIRED_STATE", available = true })
    T.eq("D9 unknown control kind makes only that action unavailable", tostring(v.available) .. "/" .. v.reasonCode, "false/CONTROL_KIND_UNKNOWN")
    local q = SGRegistry.validateAction({}, { actionId = "START", targetKind = "STOCK", targetId = "s", expectedRevision = "1", argumentSchemaId = "S1", controlKind = "ORDINARY", admission = "QUOTED", available = true })
    T.eq("D10 QUOTED without the quote trio is unavailable", q.reasonCode, "QUOTE_CALLBACKS_MISSING")
    T.eq("D11 second carrier-pending collection refuses", (function()
        local a = registry:registerCarrierPending("sg4", { sectionId = "sg4", collectionPath = "extensions.sg4.guidanceCarriers", schemaVersion = 1, validatePending = function() end, prepareCreationBinding = function() end })
        local _, why = registry:registerCarrierPending("other", { sectionId = "x", collectionPath = "y", schemaVersion = 1, validatePending = function() end, prepareCreationBinding = function() end })
        return why end)(), "ONE_COLLECTION")
    local old = SGRegistry.new("0")
    local oldLease = old:registerConsumer("c", { version = 1, requiredSchemas = {}, materialKinds = { "FILL_TYPE" }, resolveReadContext = function() end })
    T.ok("D12 a lease from another epoch is dead here", not registry:isLive(oldLease))
end

-- (E) Material store and operations
local ops = SGOperations.new(registry, "1")
local adapter = registry:get(SGRegistry.KIND_CARRIER_ADAPTER, "sg2")
local function binding(owner, comp)
    return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp }, adapterVersion = 1, profileId = "silo", profileVersion = 1, sourceDescriptor = { slot = comp }, quantityBasisKey = owner .. "/" .. comp }
end
local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
local combineCalls = 0
do
    local propSpec = {
        schemaVersion = 1, producerId = "soil", residency = "STORED", applicability = {},
        validate = function(r) return r.payload ~= nil and r.payload.moisture ~= nil, "PAYLOAD" end,
        combine = function(context, contributions, destinationBefore)
            combineCalls = combineCalls + 1
            local total, weighted, known = 0, 0, 0
            for _, c in ipairs(contributions) do
                local p = c.properties and c.properties["sf.moisture"]
                total = total + c.amount
                if p ~= nil and p.knowledge ~= "UNAVAILABLE" then weighted = weighted + p.payload.moisture * c.amount known = known + (p.knownAmount or c.amount) end
            end
            if destinationBefore ~= nil then
                local p = destinationBefore.properties["sf.moisture"]
                if p ~= nil then weighted = weighted + p.payload.moisture * destinationBefore.observedAmount total = total + destinationBefore.observedAmount known = known + (p.knownAmount or 0) end
            end
            if total == 0 then return nil, "NO_MATERIAL" end
            return { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = known >= total and "KNOWN" or "PARTIAL", knownAmount = math.min(known, total), basisAmount = total, amountUnit = "LITRE", payload = { moisture = weighted / total } }
        end,
        transform = function() return nil, "NOT_SUPPORTED" end,
        disclosure = function(context, record) local d = SGValues.copy(record) d.payload = { moisture = record.payload.moisture } return d end,
    }
    local prop = registry:registerProperty("sf.moisture", propSpec)
    T.ok("E1 property registered", prop ~= nil)
    local c1 = ops:bindCarrier(adapter, binding("silo1", "a"), { materialRef = wheat, amount = 100, unit = "l", label = "Silo A", x = 10, z = 10, ownerFarmId = 1 })
    T.ok("E2 carrier bound with a first stock", c1 ~= nil and c1.stockId ~= nil)
    local s1 = ops.stocks[c1.stockId]
    T.eq("E3 first observation is generation 1 with unknown history", s1.contentsGeneration .. "/" .. s1.knowledge, "1/UNKNOWN")
    T.eq("E4 rebind of the same carrier keeps the stock", ops:bindCarrier(adapter, binding("silo1", "a"), { materialRef = wheat, amount = 100, unit = "l" }).stockId, s1.stockId)
    T.eq("E5 wrong adapter id in the key refuses", select(2, ops:bindCarrier(adapter, { carrierKey = { adapterId = "other", nativeOwnerKey = "x", componentKey = "y" }, adapterVersion = 1, profileId = "p", profileVersion = 1, quantityBasisKey = "q" }, { amount = 0, unit = "l" })), "ADAPTER_MISMATCH")
    -- publishProperties: a known moisture on the stock.
    local ref = ops:stockRef(s1)
    local outcome, detail = ops:publishProperties(prop, { { stockRef = ref, expectedPropertyRevision = 0, record = { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = 100, basisAmount = 100, amountUnit = "LITRE", payload = { moisture = 0.14 } } } })
    T.eq("E6 publish applies", outcome, "APPLIED")
    T.eq("E7 stock is KNOWN after a full-coverage property", s1.knowledge, "KNOWN")
    local stale = ops:publishProperties(prop, { { stockRef = ref, expectedPropertyRevision = 0, record = { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = 100, basisAmount = 100, amountUnit = "LITRE", payload = { moisture = 0.2 } } } })
    T.eq("E8 old stock revision is STALE", stale, "STALE")
    local refused = ops:publishProperties(prop, { { stockRef = ops:stockRef(s1), expectedPropertyRevision = 1, record = { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = 120, basisAmount = 120, amountUnit = "LITRE", payload = { moisture = 0.2 } } } })
    T.eq("E9 coverage above the observed amount refuses", refused, "REFUSED")
    -- Unexplained increase keeps the known share as PARTIAL.
    ops:reconcileCarrier(c1.carrierId, { materialRef = wheat, amount = 140, unit = "l" })
    local p = s1.properties["sf.moisture"]
    T.eq("E10 unexplained increase: known 100 of basis 140, PARTIAL", p.knownAmount .. "/" .. p.basisAmount .. "/" .. p.knowledge, "100/140/PARTIAL")
    ops:reconcileCarrier(c1.carrierId, { materialRef = wheat, amount = 70, unit = "l" })
    T.near("E11 uniform decrease scales the known share", s1.properties["sf.moisture"].knownAmount, 50, 1e-6)
    -- Capture / settle: transfer 70 litres from silo1 into an empty trailer.
    local c2 = ops:bindCarrier(adapter, binding("trailer1", "unit1"), { amount = 0, unit = "l", label = "Trailer" })
    T.ok("E12 empty carrier has no stock", c2.stockId == nil)
    local cap = ops:captureOperation(adapter, "TRANSFER", { { carrierId = c1.carrierId, expectedStockRef = ops:stockRef(s1) }, { carrierId = c2.carrierId } })
    T.ok("E13 capture returns a handle and before facts", cap ~= nil and cap.before.carriers[c1.carrierId].amount == 70)
    T.eq("E14 capture with a stale ref refuses", select(2, ops:captureOperation(adapter, "TRANSFER", { { carrierId = c1.carrierId, expectedStockRef = ref } })), "STALE")
    local outcome2, why2 = ops:settleOperation(cap.handle, {
        participantsAfter = { [c1.carrierId] = { amount = 0, unit = "l" }, [c2.carrierId] = { materialRef = wheat, amount = 70, unit = "l" } },
        allocations = { { source = { carrierId = c1.carrierId }, destination = { carrierId = c2.carrierId }, sourceAmount = 70, sourceUnit = "l", destinationAmount = 70, destinationUnit = "l" } },
        outcomeEvidence = { note = "unload" },
    })
    T.eq("E15 settle commits", outcome2 .. "/" .. tostring(why2), "COMMITTED/nil")
    T.eq("E16 source emptied: stock retired, carrier without stock", tostring(ops.stocks[s1.stockId]) .. "/" .. tostring(ops.carriers[c1.carrierId].stockId), "nil/nil")
    local s2 = ops.stocks[ops.carriers[c2.carrierId].stockId]
    T.eq("E17 destination birth: generation 1, 70 litres of wheat", s2.contentsGeneration .. "/" .. s2.observedAmount .. "/" .. s2.materialRef.fillTypeName, "1/70/WHEAT")
    T.eq("E18 combine ran once for the destination", combineCalls, 1)
    T.near("E19 moisture carried through the contribution", s2.properties["sf.moisture"].payload.moisture, 0.14, 1e-9)
    T.eq("E20 coverage travels with the portion", string.format("%.1f/%.1f", s2.properties["sf.moisture"].knownAmount, s2.properties["sf.moisture"].basisAmount), "50.0/70.0")
    T.eq("E21 handle is consumed", ops:settleOperation(cap.handle, {}), "UNRESOLVED")
    -- Refill of silo1 starts generation 2 with unknown history.
    ops:reconcileCarrier(c1.carrierId, { materialRef = wheat, amount = 30, unit = "l" })
    local s3 = ops.stocks[ops.carriers[c1.carrierId].stockId]
    T.eq("E22 later refill is a new generation with unknown history", s3.contentsGeneration .. "/" .. s3.knowledge, "2/UNKNOWN")
    -- Abandon: no-op preserves facts; a changed amount qualifies.
    local cap2 = ops:captureOperation(adapter, "REMOVE", { { carrierId = c2.carrierId, expectedStockRef = ops:stockRef(s2) } })
    T.eq("E23 abandon with unchanged after-state is a no-op", select(2, ops:abandonOperation(cap2.handle, "cancelled", { [c2.carrierId] = { materialRef = wheat, amount = 70, unit = "l" } })), "NO_OP")
    T.eq("E24 facts preserved after the no-op", s2.properties["sf.moisture"].knowledge, "PARTIAL")
    local cap3 = ops:captureOperation(adapter, "REMOVE", { { carrierId = c2.carrierId, expectedStockRef = ops:stockRef(s2) } })
    ops:abandonOperation(cap3.handle, "crash", { [c2.carrierId] = { materialRef = wheat, amount = 65, unit = "l" } })
    T.eq("E25 changed material after abandon is qualified unavailable", s2.properties["sf.moisture"].knowledge .. "/" .. s2.observedAmount, "UNAVAILABLE/65")
    -- Baseline changed between capture and settle.
    local cap4 = ops:captureOperation(adapter, "TRANSFER", { { carrierId = c2.carrierId, expectedStockRef = ops:stockRef(s2) } })
    ops:reconcileCarrier(c2.carrierId, { materialRef = wheat, amount = 60, unit = "l" })
    T.eq("E26 a changed baseline invalidates the candidate", select(2, ops:settleOperation(cap4.handle, { allocations = { { source = { carrierId = c2.carrierId }, destination = { retire = true }, sourceAmount = 10, sourceUnit = "l" } } })), "BASELINE_CHANGED")
    -- Causal property: cause required, duplicates ALREADY_APPLIED, lower STALE.
    local causal = registry:registerProperty("cd15.disease", { schemaVersion = 1, producerId = "cd15", residency = "STORED", validate = function() return true end, combine = function() return nil end, transform = function() return nil end, disclosure = function(_, r) return r end,
        validateCause = function(c) return c.sequence > 0 end, transformCausalState = function() end, compactCausalState = function() end })
    local rec = function() return { propertyId = "cd15.disease", schemaVersion = 1, producerId = "cd15", propertyRevision = 0, knowledge = "KNOWN", payload = { pressure = 2 } } end
    T.eq("E27 causal schema without cause is REFUSED MISSING_CAUSE", select(2, ops:publishProperties(causal, { { stockRef = ops:stockRef(s3), expectedPropertyRevision = 0, record = rec() } })).reason, "MISSING_CAUSE")
    local cause = { sourceStreamId = "field7", epoch = 1, sequence = 5, fingerprint = "fp5" }
    T.eq("E28 causal publish applies with a cause", ops:publishProperties(causal, { { stockRef = ops:stockRef(s3), expectedPropertyRevision = 0, record = rec() } }, cause), "APPLIED")
    T.eq("E29 same accepted cause answers ALREADY_APPLIED without a write", ops:publishProperties(causal, { { stockRef = ops:stockRef(s3), expectedPropertyRevision = 0, record = rec() } }, cause), "ALREADY_APPLIED")
    T.eq("E30 lower sequence is STALE", ops:publishProperties(causal, { { stockRef = ops:stockRef(s3), expectedPropertyRevision = 1, record = rec() } }, { sourceStreamId = "field7", epoch = 1, sequence = 4, fingerprint = "fp4" }), "STALE")
    T.eq("E31 conflicting reuse of a sequence refuses", ops:publishProperties(causal, { { stockRef = ops:stockRef(s3), expectedPropertyRevision = 1, record = rec() } }, { sourceStreamId = "field7", epoch = 1, sequence = 5, fingerprint = "other" }), "REFUSED")
    -- readMaterial through a consumer lease.
    local consumer = registry:registerConsumer("fp1", { version = 1, requiredSchemas = { ["sf.moisture"] = 1, ["cd15.disease"] = 1 }, materialKinds = { "FILL_TYPE" },
        resolveReadContext = function(query) if query.purpose ~= "FEED" then return nil, "PURPOSE" end return { purpose = "FEED", stockRefs = query.refs } end })
    local read = ops:readMaterial(consumer, { purpose = "FEED", refs = { ops:stockRef(s3) }, propertyIds = { "cd15.disease" } })
    T.eq("E32 readMaterial returns the selected property only", read.state .. "/" .. tostring(read.records[1].properties["cd15.disease"] ~= nil) .. "/" .. tostring(read.records[1].properties["sf.moisture"]), "READY/true/nil")
    T.eq("E33 a property outside the admitted schemas refuses", ops:readMaterial(consumer, { purpose = "FEED", refs = {}, propertyIds = { "secret" } }).state, "REFUSED")
    T.eq("E34 an unresolved purpose is DENIED", ops:readMaterial(consumer, { purpose = "UI", refs = {} }).state, "DENIED")
    T.eq("E35 a retired stock reads as unavailable, never as current inventory", ops:readMaterial(consumer, { purpose = "FEED", refs = { ref } }).records[1].state, "UNAVAILABLE")
    local staleRef = ops:stockRef(s2)
    staleRef.dataRevision = "0"
    T.eq("E35b an old revision of a live stock is marked stale", ops:readMaterial(consumer, { purpose = "FEED", refs = { staleRef } }).records[1].state, "STALE_REFERENCE")
    -- OWNER_RESOLVED resident read with a stable revision, and a cycle.
    local residentRev = 3
    registry:registerProperty("soil.live", { schemaVersion = 1, producerId = "soil", residency = "OWNER_RESOLVED", validate = function() return true end, combine = function() return nil end, transform = function() return nil end, disclosure = function(_, r) return r end,
        resolveResident = function(ctx) return { propertyId = "soil.live", schemaVersion = 1, producerId = "soil", propertyRevision = residentRev, knowledge = "KNOWN", payload = { n = 1 } } end,
        getResidentRevision = function() local r = residentRev if residentRev == 3 then residentRev = 3 end return r end })
    local consumer2 = registry:registerConsumer("dc26", { version = 1, requiredSchemas = { ["soil.live"] = 1 }, materialKinds = { "FILL_TYPE" }, resolveReadContext = function(q) return { purpose = "P", stockRefs = q.refs } end })
    T.eq("E36 owner-resolved property read at a stable revision", ops:readMaterial(consumer2, { refs = { ops:stockRef(s3) } }).records[1].properties["soil.live"].knowledge, "KNOWN")
    residentRev = 4
    local unstable = registry:get(SGRegistry.KIND_PROPERTY, "soil.live").spec
    unstable.getResidentRevision = function() residentRev = residentRev + 1 return residentRev end
    T.eq("E37 a revision that moves during the read is unavailable", ops:readMaterial(consumer2, { refs = { ops:stockRef(s3) } }).records[1].properties["soil.live"].reason, "RESIDENT_UNSTABLE")
    -- Core serialization roundtrip and restore rules.
    local core = ops:serializeCore()
    T.ok("E38 core validates", SGOperations.validateCore(core) ~= nil)
    local tokens = SGValues.encode(core)
    local back = SGValues.decode(tokens)
    T.ok("E39 core survives the codec", SGOperations.validateCore(back) ~= nil and #back.stocks == #core.stocks)
    local ops2 = SGOperations.new(registry, "2")
    ops2:bindCarrier(adapter, binding("silo1", "a"), { materialRef = wheat, amount = 30, unit = "l" })
    ops2:bindCarrier(adapter, binding("trailer1", "unit1"), { materialRef = wheat, amount = 99, unit = "l" })
    local r = ops2:restoreCore(back)
    T.eq("E40 matching carrier reattaches, mismatched amount is unknown", r.restored .. "/" .. r.unknown, "1/1")
    T.eq("E41 reattached stock keeps its identity and generation", tostring(ops2.stocks[s3.stockId] ~= nil) .. "/" .. ops2.stocks[s3.stockId].contentsGeneration, "true/2")
    local mism = ops2.stocks[ops2.carriers[c2.carrierId].stockId]
    T.eq("E42 mismatch keeps native quantity, unknown history, next generation", mism.observedAmount .. "/" .. mism.knowledge .. "/" .. mism.contentsGeneration, "99/UNKNOWN/2")
    T.eq("E43 visit owned records enumerates with a bound cursor", ops:visitOwnedPropertyRecords(prop, nil, 64).exhausted, true)
    T.eq("E44 a cursor from another revision is stale", ops:visitOwnedPropertyRecords(prop, { revision = "0", epoch = "1", position = 1 }, 64).state, "STALE")
    local captured = { captureRef = "op:1:9", allocationRef = "op:1:9:a1", properties = {}, knowledge = "UNKNOWN", materialRef = wheat, actualAmount = 10, amountUnit = "l" }
    local mix = ops:readPropertyMix(consumer, { { stockRef = ops:stockRef(s2), amount = 10, unit = "l" }, { capturedContribution = captured, amount = 10, unit = "l" } }, { purpose = "FEED" })
    T.eq("E45 mix preview is detached and explicit about the unknown share", mix.state .. "/" .. mix.properties["sf.moisture"].knowledge .. "/" .. mix.properties["sf.moisture"].knownAmount, "READY/PARTIAL/0")
    T.eq("E45b a mix preview without a resolved purpose is DENIED, not previewed", ops:readPropertyMix(consumer, { { stockRef = ops:stockRef(s2), amount = 10, unit = "l" } }, {}).state, "DENIED")
    T.eq("E45c a captured contribution without its FP1 fields refuses", ops:readPropertyMix(consumer, { { capturedContribution = { properties = {}, knowledge = "UNKNOWN", materialRef = wheat }, amount = 10, unit = "l" } }, { purpose = "FEED" }).reason, "CAPTURED_REFS:1")
    T.eq("E46 mix preview did not change the store", ops.stocks[s2.stockId].observedAmount, 60)
    -- An error inside settle never leaves the store locked (Sasha, #2 review).
    local cap5 = ops:captureOperation(adapter, "TRANSFER", { { carrierId = c2.carrierId, expectedStockRef = ops:stockRef(s2) } })
    local realSettle = ops._settle
    ops._settle = function() error("adapter report blew up") end
    local o5, why5 = ops:settleOperation(cap5.handle, { participantsAfter = { [c2.carrierId] = { materialRef = wheat, amount = 60, unit = "l" } } })
    ops._settle = realSettle
    T.eq("E26b an exception during settle is UNRESOLVED SETTLE_ERROR", o5 .. "/" .. why5, "UNRESOLVED/SETTLE_ERROR")
    T.eq("E26b2 the store is never left busy after an error", ops.busy, false)
    T.eq("E26c the store is not left busy and the handle is consumed", tostring(ops.busy) .. "/" .. tostring(cap5.handle.open), "false/false")
    T.eq("E26d the captured stock is qualified, native quantity kept", ops.stocks[s2.stockId].knowledge .. "/" .. ops.stocks[s2.stockId].observedAmount, "UNAVAILABLE/60")
    local cap6 = ops:captureOperation(adapter, "REMOVE", { { carrierId = c2.carrierId, expectedStockRef = ops:stockRef(s2) } })
    T.eq("E26e a later settle still runs after the failed one", select(1, ops:settleOperation(cap6.handle, { participantsAfter = { [c2.carrierId] = { materialRef = wheat, amount = 60, unit = "l" } } })), "NO_OP")
    T.eq("E26f publishProperties is not locked out either", ops:publishProperties(prop, { { stockRef = ops:stockRef(s2), expectedPropertyRevision = ops.stocks[s2.stockId].properties["sf.moisture"].propertyRevision, record = { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = 60, basisAmount = 60, amountUnit = "LITRE", payload = { moisture = 0.11 } } } }), "APPLIED")
    -- Unregister withdraws the adapter's carriers only.
    local sgOps = ops
    registry.onUnregister = function(lease) if lease.kind == SGRegistry.KIND_CARRIER_ADAPTER then sgOps:withdrawAdapter(lease.ownerId, "ADAPTER_UNREGISTERED") end end
    registry:unregisterOwner(adapter)
    T.eq("E47 unregister retires the adapter's carriers", tostring(next(ops.carriers)), "nil")
    T.ok("E48 retired stock is historical, not spendable", ops.retiredStocks[s3.stockId] ~= nil and ops.stocks[s3.stockId] == nil)
end

-- (F) Save envelope, sections and backends
do
    local reg2 = SGRegistry.new("3")
    local ops3 = SGOperations.new(reg2, "3")
    local coord = SGFarmRestore.new("3")
    local save = SGSave.new(reg2, ops3, coord)
    local staged, committed, cleared = {}, {}, {}
    local mk = function(id, deps, failCommit)
        return { schemaVersion = 1, dependencies = deps, farmRestorePolicy = "INVARIANT",
            serialize = function() return { id = id, n = 1 } end,
            stageLoad = function(payload, context) staged[#staged + 1] = id return { id = id, payload = payload, phase = context.farmRestore and context.farmRestore.phase } end,
            commitLoad = function(c) if failCommit then error("boom") end committed[#committed + 1] = id end,
            clearReadiness = function(reason) cleared[#cleared + 1] = id end }
    end
    reg2:registerSaveSection("sg4", mk("sg4", {}))
    reg2:registerSaveSection("sg4.pending", mk("sg4.pending", { "sg4" }))
    reg2:registerSaveSection("sg2Ground", mk("sg2Ground", {}, true))
    reg2:registerSaveSection("sg2Dep", mk("sg2Dep", { "sg2Ground" }))
    save.backendId = SGSave.BACKEND_XML
    local env, failed = save:buildEnvelope({})
    T.ok("F1 envelope validates", SGSave.validateEnvelope(env) ~= nil and #failed == 0)
    T.eq("F2 four initialized sections", #env.initializedSections, 4)
    T.eq("F3 schema 3 refuses", select(2, SGSave.validateEnvelope({ schemaVersion = 3 })), "UNSUPPORTED_SCHEMA")
    local broken = SGValues.copy(env)
    broken.sections["sg4"] = nil
    T.eq("F4 a missing initialized section is an error", select(2, SGSave.validateEnvelope(broken)), "MISSING_INITIALIZED_SECTION:sg4")
    local tokens = SGValues.encode(env)
    local back = SGValues.decode(tokens)
    coord.onStage = function(_, payload, context) save:stageLoad(payload, { farmRestore = context }) end
    coord:retainPayload(back, "xml")
    coord:observeFarmsLoadedWithoutMerge()
    coord:observeNativeReady()
    T.eq("F5 dependency-ordered commit: sg4 before sg4.pending", table.concat(committed, ","), "sg4,sg4.pending")
    T.eq("F6 failed commit withdraws the set and its dependent", tostring(save:sectionReady("sg2Ground")) .. "/" .. tostring(save:sectionReady("sg2Dep")), "false/false")
    T.eq("F7 only the failed section's readiness is cleared; its dependent never committed", table.concat(cleared, ",") .. "/" .. save.sectionState["sg2Dep"].reason, "sg2Ground/DEPENDENCY_NOT_READY")
    T.eq("F8 independent set is READY", tostring(save:sectionReady("sg4.pending")), "true")
    T.eq("F9 failed section keeps its original payload retained", save.sectionState["sg2Ground"].payload.id, "sg2Ground")
    -- StateLedger backend: early delivery is retained, not thrown.
    local hooks = nil
    local ledger = { registerModule = function(self, name, h) hooks = h return true end, parseFile = function() end }
    local coord2 = SGFarmRestore.new("4")
    local save2 = SGSave.new(reg2, ops3, coord2)
    local delivered = {}
    coord2.onStage = function(_, payload) delivered[#delivered + 1] = payload end
    T.eq("F10 ledger backend selected", save2:registerBackend({ stateLedger = ledger }), "STATE_LEDGER")
    hooks.deserialize(nil)
    T.eq("F11 early nil delivery retained as first use, nothing staged yet", tostring(coord2.payload.firstUse) .. "/" .. #delivered, "true/0")
    coord2:observeFarmsLoadedWithoutMerge()
    coord2:observeNativeReady()
    T.eq("F12 staged once both barriers release", #delivered, 1)
    local out = hooks.serialize()
    T.eq("F13 ledger serialize yields the envelope table with the ledger backend id", out.backendId .. "/" .. out.schemaVersion, "STATE_LEDGER/2")
    -- Own XML backend roundtrip through a fake XMLFile.
    local store = {}
    XMLFile = { create = function(_, path, root) return { setInt = function(_, k, v) store[k] = v end, setString = function(_, k, v) store[k] = v end, save = function() end, delete = function() end } end,
        loadIfExists = function(_, path) if next(store) == nil then return nil end return { getInt = function(_, k, d) return store[k] or d end, getString = function(_, k, d) return store[k] or d end, delete = function() end } end }
    local coord3 = SGFarmRestore.new("5")
    local save3 = SGSave.new(reg2, ops3, coord3)
    save3.backendId = SGSave.BACKEND_XML
    T.ok("F14 own XML save writes tokens", save3:saveToXML({ savegameDirectory = "sg" }) and store["stockGuard#count"] > 3)
    local got = nil
    coord3.onStage = function(_, payload) got = payload end
    save3:loadFromXML({ savegameDirectory = "sg" })
    coord3:observeFarmsLoadedWithoutMerge()
    coord3:observeNativeReady()
    T.eq("F15 own XML load restores the same envelope", got.schemaVersion .. "/" .. got.backendId, "2/OWN_XML")
    store["stockGuard.token(2)#v"] = "Q"
    local coord4 = SGFarmRestore.new("6")
    local save4 = SGSave.new(reg2, ops3, coord4)
    save4.backendId = SGSave.BACKEND_XML
    local bad = nil
    coord4.onStage = function(_, payload) bad = payload end
    save4:loadFromXML({ savegameDirectory = "sg" })
    coord4:observeFarmsLoadedWithoutMerge()
    coord4:observeNativeReady()
    T.eq("F16 a malformed file is retained as malformed, never first use", tostring(bad.malformed) .. "/" .. tostring(bad.firstUse), "true/nil")
    XMLFile = nil
    -- Farm restore retention validates receipts.
    T.eq("F17 farmRestore receipts validate through receiptMap", select(2, SGSave.validateFarmRestore({ version = 1, receipts = { R = { sourceSaveAttemptId = 1, targetFarmId = 1, sourceToTarget = { { sourceFarmId = 2, targetFarmId = 3 } } } }, pendingUnits = {} })), "RECEIPT_MAP:R")
    T.ok("F18 valid farmRestore accepted", SGSave.validateFarmRestore({ version = 1, receipts = { R = { sourceSaveAttemptId = 1, targetFarmId = 1, sourceToTarget = { { sourceFarmId = 2, targetFarmId = 1 } } } }, pendingUnits = { A = { receiptId = "R", continuityLost = false } } }))
end

-- (G) Settlement rebuilt: detached candidates, validated after-states, one
-- replacement, CONVERT through transform, causal carry, candidate refs,
-- replacements, the carrier-pending join, historical persistence (#2 review).
do
    local reg = SGRegistry.new("g")
    local o = SGOperations.new(reg, "g")
    local function adapterSpecFor() return { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end, readNativeState = function() end, enumerateCarriers = function() return {} end, hasAccess = function() return true end } end
    local ad = reg:registerCarrierAdapter("sg2", adapterSpecFor())
    local otherAd = reg:registerCarrierAdapter("other", adapterSpecFor())
    local function b(owner, comp, adapterId, alias) return { carrierKey = { adapterId = adapterId or "sg2", nativeOwnerKey = owner, componentKey = comp }, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = owner .. "/" .. comp, aliasOf = alias } end
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local barley = { kind = "FILL_TYPE", fillTypeName = "BARLEY" }
    local combineCalls, transformCalls, causalCalls, contexts = 0, 0, 0, {}
    local moistureSpec = { schemaVersion = 1, producerId = "soil", residency = "STORED",
        validate = function(r) return r.payload ~= nil end,
        combine = function(ctx, contributions, before)
            combineCalls = combineCalls + 1
            contexts[#contexts + 1] = ctx
            local total, w = 0, 0
            for _, c in ipairs(contributions) do local p = c.properties["sf.moisture"] total = total + c.amount if p and p.payload then w = w + p.payload.m * c.amount end end
            if before then local p = before.properties["sf.moisture"] total = total + before.observedAmount if p and p.payload then w = w + p.payload.m * before.observedAmount end end
            if total == 0 then return nil, "NO_MATERIAL" end
            return { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = total, basisAmount = total, amountUnit = "LITRE", payload = { m = w / total } }
        end,
        transform = function(ctx, inputs, outputs)
            transformCalls = transformCalls + 1
            local out = outputs[1]
            return { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = out.amount, basisAmount = out.amount, amountUnit = "KILOGRAM", payload = { m = 0.5, basis = inputs[1].conversionBasisId } }
        end,
        disclosure = function(_, r) return r end }
    local moisture = reg:registerProperty("sf.moisture", moistureSpec)
    local function moist(m, amount) return { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { m = m } } end
    local function stockOf(c) return o.stocks[o.carriers[c.carrierId].stockId] end
    local function after(t) local out = {} for c, ns in pairs(t) do out[c.carrierId] = ns end return out end
    local function alloc(src, dst, n, unit, extra)
        local a = { source = { carrierId = src.carrierId }, destination = dst.retire and { retire = true } or { carrierId = dst.carrierId }, sourceAmount = n, sourceUnit = unit or "l", destinationAmount = n, destinationUnit = unit or "l" }
        for k, v in pairs(extra or {}) do a[k] = v end
        return a
    end

    -- G1: after-states are validated up front; nothing is written on refusal.
    local silo = o:bindCarrier(ad, b("silo", "1"), { materialRef = wheat, amount = 100, unit = "l" })
    o:publishProperties(moisture, { { stockRef = o:stockRef(stockOf(silo)), expectedPropertyRevision = 0, record = moist(0.10, 100) } })
    local trailer = o:bindCarrier(ad, b("trailer", "1"), { amount = 0, unit = "l" })
    local cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = trailer.carrierId } })
    local out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = wheat, amount = -5, unit = "l" }, [trailer.carrierId] = { amount = 0, unit = "l" } }, allocations = { alloc(silo, trailer, 40) } })
    T.eq("G1 a negative after-state amount is UNRESOLVED before any write", out .. "/" .. why, "UNRESOLVED/AFTER_STATE:AMOUNT")
    T.eq("G1b the source keeps its native quantity, qualified, and the destination stays empty", stockOf(silo).observedAmount .. "/" .. stockOf(silo).knowledge .. "/" .. tostring(o.carriers[trailer.carrierId].stockId), "100/UNAVAILABLE/nil")
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = trailer.carrierId } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = wheat, amount = "60", unit = "l" }, [trailer.carrierId] = { amount = 0, unit = "l" } }, allocations = { alloc(silo, trailer, 40) } })
    T.eq("G1c a string amount is UNRESOLVED, never installed", why, "AFTER_STATE:AMOUNT")
    T.eq("G1d a valid after-state reported beside the refusal is still reconciled as the observed native fact", stockOf(silo).observedAmount, 100)

    -- G2: a changed participant without an after-state is not invented.
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = trailer.carrierId } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = wheat, amount = 100, unit = "l" } }, allocations = { alloc(silo, trailer, 40) } })
    T.eq("G2 a destination without an after-state is UNRESOLVED", out .. "/" .. why, "UNRESOLVED/AFTER_STATE_REQUIRED:" .. trailer.carrierId)
    T.eq("G2b nothing was minted for the destination", tostring(o.carriers[trailer.carrierId].stockId), "nil")

    -- G3: an over-debit is UNRESOLVED, never clamped.
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = trailer.carrierId } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = wheat, amount = 100, unit = "l" }, [trailer.carrierId] = { amount = 0, unit = "l" } }, allocations = { alloc(silo, trailer, 150) } })
    T.eq("G3 an over-debit is UNRESOLVED", why, "OVER_DEBIT:" .. silo.carrierId)
    T.eq("G3b the source stock survived with its native quantity", stockOf(silo).observedAmount, 100)

    -- G4: the candidate phase runs the pure callbacks; a failure after them installs nothing.
    o:publishProperties(moisture, { { stockRef = o:stockRef(stockOf(silo)), expectedPropertyRevision = stockOf(silo).properties["sf.moisture"].propertyRevision, record = moist(0.10, 100) } })
    local pendingLease = reg:registerCarrierPending("sg4", { sectionId = "sg4", collectionPath = "extensions.sg4.guidanceCarriers", schemaVersion = 1,
        validatePending = function(ctx, target) return target.recipe ~= nil end,
        prepareCreationBinding = function(ctx, pendingBefore, created) return {} end })
    T.eq("G4 an empty carrier reads as empty with its tokens", (function() local r = o:readCarrierPending(pendingLease, b("trailer", "1").carrierKey) return tostring(r.empty) .. "/" .. r.emptyEpoch .. "/" .. r.selectionRevision end)(), "true/1/1")
    T.eq("G4b arming with a stale token is STALE without change", (o:setCarrierPending(pendingLease, b("trailer", "1").carrierKey, 1, 7, { recipe = "R1" })), "STALE")
    T.eq("G4c arming a nonempty carrier is refused", select(2, o:setCarrierPending(pendingLease, b("silo", "1").carrierKey, 1, 1, { recipe = "R1" })).reason, "NOT_EMPTY")
    T.eq("G4d an invalid target is refused by the owner", select(2, o:setCarrierPending(pendingLease, b("trailer", "1").carrierKey, 1, 1, { other = 1 })).reason, "TARGET_INVALID:REFUSED")
    local armed, armedDetail = o:setCarrierPending(pendingLease, b("trailer", "1").carrierKey, 1, 1, { recipe = "R1" })
    T.eq("G4e arming applies and advances the selection revision", armed .. "/" .. armedDetail.selectionRevision, "APPLIED/2")
    local before = combineCalls
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = trailer.carrierId } })
    T.eq("G4f capture records the pending state of the empty carrier", cap.before.carriers[trailer.carrierId].pending.pendingTarget.recipe, "R1")
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = wheat, amount = 60, unit = "l" }, [trailer.carrierId] = { materialRef = wheat, amount = 40, unit = "l" } }, allocations = { alloc(silo, trailer, 40) } })
    T.eq("G4g a malformed creation binding leaves the whole settlement UNRESOLVED", out .. "/" .. why, "UNRESOLVED/CREATION_BINDING_FAILED")
    T.eq("G4h the pure combine had already run (candidate phase), yet nothing from the candidate set was installed: the native outcome is reconciled as unexplained, the source qualified", tostring(combineCalls > before) .. "/" .. stockOf(silo).observedAmount .. "/" .. stockOf(silo).knowledge .. "/" .. stockOf(trailer).knowledge .. "/" .. tostring(stockOf(trailer).properties["sf.moisture"]) .. "/" .. tostring(stockOf(trailer).properties["sg4.recipeBinding"]), "true/60/UNAVAILABLE/UNKNOWN/nil/nil")
    T.eq("G4i the unbound target is marked unavailable before any view treats it as usable", o.pending[trailer.carrierId].availability, "UNAVAILABLE")
    T.eq("G4j the handle is consumed", cap.handle.open, false)

    -- G5: the creation join commits stock, property results and the carrier update once.
    local recipeProp = reg:registerProperty("sg4.recipeBinding", { schemaVersion = 1, producerId = "sg4", residency = "STORED", validate = function() return true end, combine = function() return nil end, transform = function() return nil end, disclosure = function(_, r) return r end })
    reg:get(SGRegistry.KIND_CARRIER_PENDING, "sg4").spec.prepareCreationBinding = function(ctx, pendingBefore, created)
        return { propertyResults = { ["sg4.recipeBinding"] = { propertyId = "sg4.recipeBinding", schemaVersion = 1, producerId = "sg4", propertyRevision = 0, knowledge = "KNOWN", payload = { recipe = pendingBefore.pendingTarget.recipe, stock = created.stockRef.stockId } } },
            carrierUpdates = { collectionPath = "extensions.sg4.guidanceCarriers", key = created.carrierId, expectedEmptyEpoch = pendingBefore.emptyEpoch, expectedSelectionRevision = pendingBefore.selectionRevision, replacementRecord = { pendingTarget = nil, nativeContentState = "NONEMPTY" } } }
    end
    local trailer2 = o:bindCarrier(ad, b("trailer", "2"), { amount = 0, unit = "l" })
    T.eq("G4k a fresh empty carrier arms", (o:setCarrierPending(pendingLease, b("trailer", "2").carrierKey, 1, 1, { recipe = "R1" })), "APPLIED")
    o:publishProperties(moisture, { { stockRef = o:stockRef(stockOf(silo)), expectedPropertyRevision = stockOf(silo).properties["sf.moisture"].propertyRevision, record = moist(0.10, 60) } })
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = trailer2.carrierId } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = wheat, amount = 20, unit = "l" }, [trailer2.carrierId] = { materialRef = wheat, amount = 40, unit = "l" } }, allocations = { alloc(silo, trailer2, 40) } })
    local created = stockOf(trailer2)
    T.eq("G5 the join commits", out .. "/" .. tostring(why), "COMMITTED/nil")
    T.eq("G5b the created stock carries the owner's recipe binding to its own candidate id", created.properties["sg4.recipeBinding"].payload.recipe .. "/" .. tostring(created.properties["sg4.recipeBinding"].payload.stock == created.stockId), "R1/true")
    T.eq("G5c the carrier update landed in the same replacement: target consumed, bound stock recorded, revision advanced", tostring(o.pending[trailer2.carrierId].pendingTarget) .. "/" .. tostring(o.pending[trailer2.carrierId].boundStockRef.stockId == created.stockId) .. "/" .. o.pending[trailer2.carrierId].selectionRevision, "nil/true/3")
    T.eq("G5d the source was debited to its observed after-state", stockOf(silo).observedAmount, 20)
    T.near("G5e moisture carried into the created stock", created.properties["sf.moisture"].payload.m, 0.10, 1e-9)

    -- G6: candidate refs and allocation refs are supplied to the pure callbacks.
    local ctx = contexts[#contexts]
    T.eq("G6 the combine context named the candidate StockRef that was then minted", tostring(ctx.candidates[trailer2.carrierId].stockRef.stockId == created.stockId) .. "/" .. ctx.candidates[trailer2.carrierId].mode, "true/BIRTH")
    T.eq("G6b allocation references are assigned before the callbacks", ctx.allocations[1].allocationRef, cap.operationId .. ":a1")

    -- G7: mix in place never double counts; the own remainder is the baseline.
    o:publishProperties(moisture, { { stockRef = o:stockRef(created), expectedPropertyRevision = created.properties["sf.moisture"].propertyRevision, record = moist(0.30, 40) } })
    o:publishProperties(moisture, { { stockRef = o:stockRef(stockOf(silo)), expectedPropertyRevision = stockOf(silo).properties["sf.moisture"].propertyRevision, record = moist(0.10, 20) } })
    local siloStockId = stockOf(silo).stockId
    cap = o:captureOperation(ad, "MIX", { { carrierId = trailer2.carrierId, expectedStockRef = o:stockRef(stockOf(trailer2)) }, { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [trailer2.carrierId] = { amount = 0, unit = "l" }, [silo.carrierId] = { materialRef = wheat, amount = 60, unit = "l" } }, allocations = { alloc(trailer2, silo, 40) } })
    T.eq("G7 mix into an occupied carrier commits into the same generation", out .. "/" .. tostring(stockOf(silo).stockId == siloStockId) .. "/" .. stockOf(silo).contentsGeneration, "COMMITTED/true/1")
    T.near("G7b the mix weighs the remainder once: (20*0.10+40*0.30)/60", stockOf(silo).properties["sf.moisture"].payload.m, 14 / 60, 1e-9)
    T.eq("G7c coverage basis equals the observed amount, not a double count", stockOf(silo).properties["sf.moisture"].basisAmount .. "/" .. stockOf(silo).observedAmount, "60/60")
    T.eq("G7d the emptied source retired and advanced its empty epoch", tostring(o.carriers[trailer2.carrierId].stockId) .. "/" .. o.pending[trailer2.carrierId].emptyEpoch, "nil/2")

    -- G8: a destination material change ends the generation like reconcile does.
    local bin = o:bindCarrier(ad, b("bin", "1"), { materialRef = barley, amount = 50, unit = "l" })
    local old = stockOf(silo)
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = bin.carrierId, expectedStockRef = o:stockRef(stockOf(bin)) }, { carrierId = silo.carrierId, expectedStockRef = o:stockRef(old) } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [bin.carrierId] = { amount = 0, unit = "l" }, [silo.carrierId] = { materialRef = barley, amount = 120, unit = "l" } }, allocations = { alloc(bin, silo, 50) } })
    T.eq("G8 a material change on the destination commits a NEW generation and retires the old stock", out .. "/" .. tostring(stockOf(silo).stockId ~= old.stockId) .. "/" .. stockOf(silo).contentsGeneration .. "/" .. tostring(o.retiredStocks[old.stockId].retireReason), "COMMITTED/true/2/MATERIAL_CHANGED")
    T.eq("G8b the delta the allocations do not explain is marked, not balanced", tostring(stockOf(silo).reason), "UNEXPLAINED_DELTA")

    -- G9: CONVERT goes through transform with its basis; unit mixing without a basis refuses.
    local mill = o:bindCarrier(ad, b("mill", "out"), { amount = 0, unit = "kg" })
    cap = o:captureOperation(ad, "CONVERT", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = mill.carrierId } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = barley, amount = 120, unit = "l" }, [mill.carrierId] = { amount = 0, unit = "kg" } }, allocations = { { source = { carrierId = silo.carrierId }, destination = { carrierId = mill.carrierId }, sourceAmount = 100, sourceUnit = "l", destinationAmount = 80, destinationUnit = "kg" } } })
    T.eq("G9 CONVERT without a conversion basis is UNRESOLVED", out .. "/" .. why, "UNRESOLVED/CONVERSION_BASIS_REQUIRED")
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = mill.carrierId } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = barley, amount = 120, unit = "l" }, [mill.carrierId] = { amount = 0, unit = "kg" } }, allocations = { { source = { carrierId = silo.carrierId }, destination = { carrierId = mill.carrierId }, sourceAmount = 100, sourceUnit = "l", destinationAmount = 80, destinationUnit = "kg" } } })
    T.eq("G9b a TRANSFER that mixes units without a basis is UNRESOLVED", why, "UNIT_MISMATCH")
    o:publishProperties(moisture, { { stockRef = o:stockRef(stockOf(silo)), expectedPropertyRevision = stockOf(silo).properties["sf.moisture"] and stockOf(silo).properties["sf.moisture"].propertyRevision or nil, record = moist(0.2, 120) } })
    cap = o:captureOperation(ad, "CONVERT", { { carrierId = silo.carrierId, expectedStockRef = o:stockRef(stockOf(silo)) }, { carrierId = mill.carrierId } })
    local t0 = transformCalls
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [silo.carrierId] = { materialRef = barley, amount = 20, unit = "l" }, [mill.carrierId] = { materialRef = { kind = "FILL_TYPE", fillTypeName = "FLOUR" }, amount = 80, unit = "kg" } }, allocations = { { source = { carrierId = silo.carrierId }, destination = { carrierId = mill.carrierId }, sourceAmount = 100, sourceUnit = "l", destinationAmount = 80, destinationUnit = "kg", conversionBasisId = "grind:1" } } })
    T.eq("G9c CONVERT with a basis commits through transform, each side keeping its unit", out .. "/" .. (transformCalls - t0) .. "/" .. stockOf(mill).amountUnit .. "/" .. stockOf(mill).properties["sf.moisture"].amountUnit .. "/" .. stockOf(mill).properties["sf.moisture"].payload.basis, "COMMITTED/1/kg/KILOGRAM/grind:1")
    T.eq("G9d the source keeps litres", stockOf(silo).amountUnit .. "/" .. stockOf(silo).observedAmount, "l/20")

    -- G10: causal state travels with the material and is transformed by its owner.
    local causalCalls2 = 0
    local causal = reg:registerProperty("cd15.disease", { schemaVersion = 1, producerId = "cd15", residency = "STORED", validate = function() return true end, combine = function() return { propertyId = "cd15.disease", schemaVersion = 1, producerId = "cd15", propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end, transform = function() return nil end, disclosure = function(_, r) return r end,
        validateCause = function(c, floor) return c.sequence > (floor and floor.sequence or 0) end, transformCausalState = function(ctx, sources, output) causalCalls2 = causalCalls2 + 1 return nil end, compactCausalState = function() end })
    local field = o:bindCarrier(ad, b("field", "7"), { materialRef = wheat, amount = 200, unit = "l" })
    local cause5 = { sourceStreamId = "f7", epoch = 1, sequence = 5, fingerprint = "fp5" }
    T.eq("G10 the causal owner validates against the accepted floor", o:publishProperties(causal, { { stockRef = o:stockRef(stockOf(field)), expectedPropertyRevision = 0, record = { propertyId = "cd15.disease", schemaVersion = 1, producerId = "cd15", propertyRevision = 0, knowledge = "KNOWN", payload = { p = 2 } } } }, cause5), "APPLIED")
    local cart = o:bindCarrier(ad, b("cart", "1"), { amount = 0, unit = "l" })
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = field.carrierId, expectedStockRef = o:stockRef(stockOf(field)) }, { carrierId = cart.carrierId } })
    out = o:settleOperation(cap.handle, { participantsAfter = { [field.carrierId] = { materialRef = wheat, amount = 120, unit = "l" }, [cart.carrierId] = { materialRef = wheat, amount = 80, unit = "l" } }, allocations = { alloc(field, cart, 80) } })
    T.eq("G10b the owner's transformCausalState ran for the descendant", out .. "/" .. causalCalls2, "COMMITTED/1")
    T.eq("G10c the accepted cause travelled: replaying it on the descendant is ALREADY_APPLIED", o:publishProperties(causal, { { stockRef = o:stockRef(stockOf(cart)), expectedPropertyRevision = 1, record = { propertyId = "cd15.disease", schemaVersion = 1, producerId = "cd15", propertyRevision = 0, knowledge = "KNOWN", payload = { p = 2 } } } }, cause5), "ALREADY_APPLIED")
    T.eq("G10d a lower sequence on the descendant is STALE", o:publishProperties(causal, { { stockRef = o:stockRef(stockOf(cart)), expectedPropertyRevision = 1, record = { propertyId = "cd15.disease", schemaVersion = 1, producerId = "cd15", propertyRevision = 0, knowledge = "KNOWN", payload = { p = 2 } } } }, { sourceStreamId = "f7", epoch = 1, sequence = 4, fingerprint = "fp4" }), "STALE")
    T.eq("G10e the source portion that stayed keeps its floor too", tostring(stockOf(field).acceptedCauses["f7/1"] ~= nil), "true")
    -- Without causal interpretation the property is unavailable while the floor still travels.
    reg:get(SGRegistry.KIND_PROPERTY, "cd15.disease").spec.causalUnavailable = true
    local cart2 = o:bindCarrier(ad, b("cart", "2"), { amount = 0, unit = "l" })
    cap = o:captureOperation(ad, "TRANSFER", { { carrierId = cart.carrierId, expectedStockRef = o:stockRef(stockOf(cart)) }, { carrierId = cart2.carrierId } })
    o:settleOperation(cap.handle, { participantsAfter = { [cart.carrierId] = { amount = 0, unit = "l" }, [cart2.carrierId] = { materialRef = wheat, amount = 80, unit = "l" } }, allocations = { alloc(cart, cart2, 80) } })
    T.eq("G10f without the owner's causal interpretation the descendant property is unavailable, floor retained", stockOf(cart2).properties["cd15.disease"].reason .. "/" .. tostring(stockOf(cart2).acceptedCauses["f7/1"].sequence), "CAUSAL_INTERPRETATION_UNAVAILABLE/5")

    -- G11: REBIND replacements alias a carrier without a new stock or generation.
    local oldId = cart2.carrierId
    local oldStock = stockOf(cart2)
    cap = o:captureOperation(ad, "REBIND", { { carrierId = oldId, expectedStockRef = o:stockRef(oldStock) } })
    out, why = o:settleOperation(cap.handle, { participantsAfter = { [oldId] = { materialRef = wheat, amount = 80, unit = "l" } }, replacements = { { carrierId = oldId, binding = b("cart", "2b", nil, oldId) } } })
    local newId = SGRecords.carrierKeyString(b("cart", "2b").carrierKey)
    T.eq("G11 a proved alias moves the carrier under its new key", out .. "/" .. tostring(o.carriers[oldId]) .. "/" .. tostring(o.carriers[newId] ~= nil), "COMMITTED/nil/true")
    T.eq("G11b the stock, its generation and its causes are unchanged", tostring(o.stocks[oldStock.stockId] ~= nil) .. "/" .. o.stocks[oldStock.stockId].contentsGeneration .. "/" .. o.stocks[oldStock.stockId].carrierId .. "/" .. tostring(o.stocks[oldStock.stockId].acceptedCauses["f7/1"] ~= nil), "true/1/" .. newId .. "/true")
    cap = o:captureOperation(ad, "REBIND", { { carrierId = newId } })
    T.eq("G11c an unproved replacement (no alias, other basis) refuses", select(2, o:settleOperation(cap.handle, { participantsAfter = { [newId] = { materialRef = wheat, amount = 80, unit = "l" } }, replacements = { { carrierId = newId, binding = b("cart", "9") } } })), "REPLACEMENT_UNPROVED")

    -- G12: adapters, handles, busy and knowledge rules.
    T.eq("G12 capturing another adapter's carrier is refused", select(2, o:captureOperation(otherAd, "REMOVE", { { carrierId = silo.carrierId } })), "ADAPTER_MISMATCH")
    local openCap = o:captureOperation(ad, "REMOVE", { { carrierId = silo.carrierId } })
    o:withdrawAdapter("sg2", "ADAPTER_UNREGISTERED")
    T.eq("G12b withdrawing an adapter closes its open handles", tostring(openCap.handle.open) .. "/" .. select(2, o:settleOperation(openCap.handle, {})), "false/HANDLE_CLOSED")
    o.busy = true
    T.eq("G12c mutators refuse while a replacement runs", select(2, o:bindCarrier(otherAd, b("x", "1", "other"), { amount = 0, unit = "l" })) .. "/" .. select(2, o:reconcileCarrier("x", { amount = 0, unit = "l" })) .. "/" .. select(2, o:withdrawCarrier("x")), "REENTRANT/REENTRANT/REENTRANT")
    o.busy = false
    T.eq("G12d knowledge of uniform states maps exactly", SGOperations.knowledgeOf({ properties = { a = { knowledge = "UNKNOWN" }, b = { knowledge = "UNKNOWN" } } }) .. "/" .. SGOperations.knowledgeOf({ properties = { a = { knowledge = "HISTORICAL" }, b = { knowledge = "HISTORICAL" } } }) .. "/" .. SGOperations.knowledgeOf({ properties = { a = { knowledge = "KNOWN" }, b = { knowledge = "PARTIAL" } } }), "UNKNOWN/HISTORICAL/PARTIAL")
    -- Notifications are queued during a replacement and flushed after it.
    local reg3 = SGRegistry.new("g3")
    local o3 = SGOperations.new(reg3, "g3")
    local ad3 = reg3:registerCarrierAdapter("sg2", adapterSpecFor())
    local seenDuring = {}
    o3.onChanged = function(kind, id) seenDuring[#seenDuring + 1] = { kind = kind, id = id, busy = o3.busy, stockThere = o3.stocks[id] ~= nil or o3.retiredStocks[id] ~= nil or o3.carriers[id] ~= nil } end
    local a3 = o3:bindCarrier(ad3, b("a", "1"), { materialRef = wheat, amount = 10, unit = "l" })
    local b3 = o3:bindCarrier(ad3, b("b", "1"), { amount = 0, unit = "l" })
    seenDuring = {}
    local cap3 = o3:captureOperation(ad3, "TRANSFER", { { carrierId = a3.carrierId }, { carrierId = b3.carrierId } })
    o3:settleOperation(cap3.handle, { participantsAfter = { [a3.carrierId] = { amount = 0, unit = "l" }, [b3.carrierId] = { materialRef = wheat, amount = 10, unit = "l" } }, allocations = { alloc(a3, b3, 10) } })
    local allAfter = #seenDuring > 0
    for _, n in ipairs(seenDuring) do if n.busy then allAfter = false end end
    T.eq("G12e change notifications fire only after the replacement, never inside it", tostring(allAfter), "true")
    -- scaleCoverage bumps the property revision; a changed basis key ends the generation.
    o3:publishProperties(reg3:registerProperty("sf.moisture", moistureSpec), { { stockRef = o3:stockRef(o3.stocks[o3.carriers[b3.carrierId].stockId]), expectedPropertyRevision = 0, record = moist(0.1, 10) } })
    local sb = o3.stocks[o3.carriers[b3.carrierId].stockId]
    local revBefore = sb.properties["sf.moisture"].propertyRevision
    o3:reconcileCarrier(b3.carrierId, { materialRef = wheat, amount = 5, unit = "l" })
    T.eq("G12f a coverage rescale bumps the property revision", sb.properties["sf.moisture"].propertyRevision, revBefore + 1)
    local rebound = { carrierKey = b("b", "1").carrierKey, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "b/1/v2" }
    o3:bindCarrier(ad3, rebound, { materialRef = wheat, amount = 5, unit = "l" })
    T.eq("G12g a rebind with a changed quantity basis ends the generation", tostring(o3.retiredStocks[sb.stockId] ~= nil) .. "/" .. o3.stocks[o3.carriers[b3.carrierId].stockId].contentsGeneration, "true/2")

    -- G13: per-entry ALREADY_APPLIED and the accepted floor.
    local reg4 = SGRegistry.new("g4")
    local o4 = SGOperations.new(reg4, "g4")
    local ad4 = reg4:registerCarrierAdapter("sg2", adapterSpecFor())
    local c4 = reg4:registerProperty("cd15.disease", { schemaVersion = 1, producerId = "cd15", residency = "STORED", validate = function() return true end, combine = function() return nil end, transform = function() return nil end, disclosure = function(_, r) return r end,
        validateCause = function() return true end, transformCausalState = function() return nil end, compactCausalState = function() end })
    local x = o4:bindCarrier(ad4, b("x", "1"), { materialRef = wheat, amount = 10, unit = "l" })
    local y = o4:bindCarrier(ad4, b("y", "1"), { materialRef = wheat, amount = 10, unit = "l" })
    local rec = function() return { propertyId = "cd15.disease", schemaVersion = 1, producerId = "cd15", propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end
    local sx, sy = o4.stocks[x.stockId], o4.stocks[y.stockId]
    o4:publishProperties(c4, { { stockRef = o4:stockRef(sx), expectedPropertyRevision = 0, record = rec() } }, cause5)
    local outcome, detail = o4:publishProperties(c4, { { stockRef = o4:stockRef(sx), expectedPropertyRevision = 1, record = rec() }, { stockRef = o4:stockRef(sy), expectedPropertyRevision = 0, record = rec() } }, cause5)
    T.eq("G13 a batch with one entry already accepted installs only the other", outcome .. "/" .. #detail.installed .. "/" .. detail.alreadyApplied, "APPLIED/1/1")
    T.eq("G13b a batch that is fully accepted answers ALREADY_APPLIED without a write", (o4:publishProperties(c4, { { stockRef = o4:stockRef(sx), expectedPropertyRevision = 1, record = rec() }, { stockRef = o4:stockRef(sy), expectedPropertyRevision = 1, record = rec() } }, cause5)), "ALREADY_APPLIED")

    -- G14: unresolved historical stocks persist until a load resolves them.
    local core = o4:serializeCore()
    local o5 = SGOperations.new(reg4, "g5")
    local r5 = o5:restoreCore(core)
    T.eq("G14 saved stocks whose carriers are absent are retained as historical", r5.historical, 2)
    local core2 = o5:serializeCore()
    T.eq("G14b historical stocks are serialized again, not dropped", #core2.historical .. "/" .. #core2.stocks, "2/0")
    T.ok("G14c a core with historical stocks validates", SGOperations.validateCore(core2) ~= nil)
    local o6 = SGOperations.new(reg4, "g6")
    o6:bindCarrier(ad4, b("x", "1"), { materialRef = wheat, amount = 10, unit = "l" })
    local r6 = o6:restoreCore(core2)
    T.eq("G14d a later load with the carrier back reattaches from the historical row", r6.restored .. "/" .. r6.historical .. "/" .. tostring(o6.stocks[sx.stockId] ~= nil) .. "/" .. #o6:serializeCore().historical, "1/1/true/1")
end

-- (H) Save retention rules: retained payloads travel untouched, a refused
-- envelope is written back, coupled sets are atomic, the farm-restore gate
-- is wired end to end with receipts and pending units, the manifest and
-- the pending collection injection (#2 review).
do
    local reg = SGRegistry.new("h")
    local ops = SGOperations.new(reg, "h")
    local serialized, committed, cleared = {}, {}, {}
    local function section(id, deps, opts)
        opts = opts or {}
        local spec = { schemaVersion = opts.schema or 1, dependencies = deps, farmRestorePolicy = opts.policy,
            serialize = function() serialized[#serialized + 1] = id return { id = id, live = true } end,
            stageLoad = function(payload, context) if opts.failStage then return nil, "BAD" end return { id = id, payload = payload, phase = context.farmRestore and context.farmRestore.phase } end,
            commitLoad = function(c) if opts.failCommit then error("boom") end committed[#committed + 1] = id end,
            clearReadiness = function(reason) cleared[#cleared + 1] = id .. ":" .. tostring(reason):match("^[A-Z_]+") end }
        return spec
    end
    reg:registerSaveSection("inv", section("inv", {}, { policy = "INVARIANT" }))
    reg:registerSaveSection("own", section("own", {}, { policy = "OWNER" }))
    reg:registerSaveSection("undecl", section("undecl", {}))
    reg:registerSaveSection("broken", section("broken", {}, { policy = "INVARIANT", failStage = true }))
    reg:registerSaveSection("depA", section("depA", {}, { policy = "INVARIANT" }))
    reg:registerSaveSection("depB", section("depB", { "depA" }, { policy = "INVARIANT", failCommit = true }))
    local coord = SGFarmRestore.new("h")
    local save = SGSave.new(reg, ops, coord)
    save.backendId = SGSave.BACKEND_XML
    local env = save:buildEnvelope({})
    env.sections.broken.payload = { id = "broken", original = true }
    env.sections.undecl.payload = { id = "undecl", original = true }
    -- A MERGED conversion: undeclared retained, OWNER installed with the phase, dependent set atomic.
    coord.onStage = function(_, payload, context) save:stageLoad(payload, { farmRestore = context }) end
    g_currentMission.missionDynamicInfo = { isMultiplayer = false }
    coord:observeBeforeMerge({ farms = { { farmId = 1 }, { farmId = 2 } } })
    coord:observeAfterMerge({ farms = {}, mergedFarms = { [2] = 1 }, farmIdToFarm = { [1] = {} } })
    coord:retainPayload(SGValues.decode(SGValues.encode(env)), "xml")
    coord:observeNativeReady()
    local st = save.sectionState
    T.eq("H1 under MERGED an undeclared policy is retained, INVARIANT and OWNER install", st.undecl.reason .. "/" .. tostring(st.inv.ready) .. "/" .. tostring(st.own.ready), "FARM_RESTORE_UNSUPPORTED/true/true")
    T.eq("H1b the OWNER section received context.farmRestore with the MERGED phase", (function() for _, id in ipairs(committed) do if id == "own" then return "own" end end return "none" end)() .. "/" .. tostring(save.loadResult.sections.own), "own/READY")
    T.eq("H1c a section whose staging failed is retained with its original payload", st.broken.reason:sub(1, 13) .. "/" .. tostring(st.broken.payload.original), "STAGE_FAILED:/true")
    T.eq("H2 a dependent's commit failure withdraws the whole coupled set", tostring(st.depA.ready) .. "/" .. st.depA.reason .. "/" .. tostring(st.depB.ready) .. "/" .. st.depB.reason:sub(1, 14), "false/DEPENDENCY_NOT_READY/false/COMMIT_FAILED:")
    T.eq("H2b the already installed dependency had its readiness cleared", (function() for _, c in ipairs(cleared) do if c == "depA:SET_WITHDRAWN" then return "cleared" end end return "kept" end)(), "cleared")
    -- The next save writes retained originals, never the live owner state.
    serialized = {}
    local env2 = save:buildEnvelope({})
    T.eq("H3 retained sections write their original payload and their serialize is not called", tostring(env2.sections.undecl.payload.original) .. "/" .. tostring(env2.sections.broken.payload.original) .. "/" .. (function() for _, id in ipairs(serialized) do if id == "undecl" or id == "broken" or id == "depA" then return "called" end end return "skipped" end)(), "true/true/skipped")
    T.eq("H3b live sections still serialize", (function() for _, id in ipairs(serialized) do if id == "own" then return "own" end end return "none" end)(), "own")
    T.eq("H4 the merged load emitted one receipt and a pending unit per retained candidate", (function() local n = 0 for _ in pairs(env2.farmRestore.receipts) do n = n + 1 end local u = {} for id in pairs(env2.farmRestore.pendingUnits) do u[#u + 1] = id end table.sort(u) return n .. "/" .. table.concat(u, ",") end)(), "1/section:broken,section:depA,section:depB,section:undecl")
    T.eq("H4b the receipt carries the canonical row sequence to the singleplayer target", env2.farmRestore.receipts[next(env2.farmRestore.receipts)].sourceToTarget[1].sourceFarmId .. "/" .. env2.farmRestore.receipts[next(env2.farmRestore.receipts)].targetFarmId, "2/1")
    T.ok("H4c the envelope with the proof validates", SGSave.validateEnvelope(SGValues.decode(SGValues.encode(env2))) ~= nil)
    T.eq("H4d the produced snapshot key names backend, epoch and attempt", env2.nativeSnapshotKey, "OWN_XML:1:2")
    -- A late owner that now declares its policy installs its retained section and resolves the unit.
    local lateSpec = section("undecl", {}, { policy = "OWNER" })
    reg.onRegister = function(lease) save:onSectionRegistered(lease) end
    reg:unregisterOwner(reg:get(SGRegistry.KIND_SAVE_SECTION, "undecl"))
    reg:registerSaveSection("undecl", lateSpec)
    T.eq("H5 a re-registered owner with a declared policy installs the retained original and removes its unit", tostring(save.sectionState.undecl.ready) .. "/" .. tostring(save.farmRestore.pendingUnits["section:undecl"]), "true/nil")
    T.ok("H5b the receipt stays while other units still reference it", next(save.farmRestore.receipts) ~= nil)
    -- FAILED and WAITING phases retain OWNER sections.
    local reg2 = SGRegistry.new("h2")
    reg2:registerSaveSection("own", section("own", {}, { policy = "OWNER" }))
    reg2:registerSaveSection("inv", section("inv", {}, { policy = "INVARIANT" }))
    local ops2 = SGOperations.new(reg2, "h2")
    local coord2 = SGFarmRestore.new("h2")
    local save2 = SGSave.new(reg2, ops2, coord2)
    save2.backendId = SGSave.BACKEND_XML
    local envF = save2:buildEnvelope({})
    coord2.onStage = function(_, payload, context) save2:stageLoad(payload, { farmRestore = context }) end
    coord2:observeBeforeMerge({ farms = { { farmId = 1 }, { farmId = 2 } } })
    coord2:observeAfterMerge({ farms = {}, mergedFarms = { [7] = 1 }, farmIdToFarm = { [1] = {} } })
    coord2:retainPayload(SGValues.decode(SGValues.encode(envF)), "xml")
    coord2:observeNativeReady()
    T.eq("H6 under FAILED an OWNER section is retained and INVARIANT installs", save2.sectionState.own.reason .. "/" .. tostring(save2.sectionState.inv.ready), "FARM_RESTORE_FAILED/true")
    -- A refused envelope is written back unchanged; a malformed file is never overwritten.
    local reg3 = SGRegistry.new("h3")
    local save3 = SGSave.new(reg3, SGOperations.new(reg3, "h3"), SGFarmRestore.new("h3"))
    save3.backendId = SGSave.BACKEND_LEDGER
    local newer = { schemaVersion = 3, future = "data", sections = {}, initializedSections = {} }
    save3:stageLoad(newer, {})
    T.eq("H7 a newer envelope is refused and retained", save3.loadResult.state .. "/" .. save3.loadResult.reason, "UNAVAILABLE/UNSUPPORTED_SCHEMA")
    T.eq("H7b the next save writes the retained envelope back unchanged", tostring(save3:serializeForLedger().future) .. "/" .. save3:serializeForLedger().schemaVersion, "data/3")
    local save4 = SGSave.new(reg3, SGOperations.new(reg3, "h4"), SGFarmRestore.new("h4"))
    save4.backendId = SGSave.BACKEND_XML
    save4:stageLoad({ malformed = true, reason = "XML_TOKENS" }, {})
    XMLFile = { create = function() error("must not be called") end, loadIfExists = function() return nil end }
    T.eq("H7c a malformed retained file is not overwritten", save4:saveToXML({ savegameDirectory = "sg" }), false)
    XMLFile = nil
    -- The manifest decides first use.
    local save5 = SGSave.new(reg3, SGOperations.new(reg3, "h5"), SGFarmRestore.new("h5"))
    save5.backendId = SGSave.BACKEND_LEDGER
    save5.manifest = { backendId = "STATE_LEDGER", saveAttemptId = 3 }
    save5:stageLoad({ firstUse = true, nilDelivery = true }, {})
    T.eq("H8 a nil delivery after an initialized save is a missing payload, never first use", save5.loadResult.state .. "/" .. save5.loadResult.reason, "UNAVAILABLE/PAYLOAD_MISSING")
    local save6 = SGSave.new(reg3, SGOperations.new(reg3, "h6"), SGFarmRestore.new("h6"))
    save6.backendId = SGSave.BACKEND_LEDGER
    save6:stageLoad({ firstUse = true, nilDelivery = true }, {})
    T.eq("H8b without a manifest a nil delivery is first use", save6.loadResult.state, "FIRST_USE")
    -- A refused farmRestore proof leaves only that proof unavailable.
    local save7 = SGSave.new(reg3, SGOperations.new(reg3, "h7"), SGFarmRestore.new("h7"))
    save7.backendId = SGSave.BACKEND_XML
    local env7 = save7:buildEnvelope({})
    env7.farmRestore = { version = 9 }
    save7:stageLoad(SGValues.decode(SGValues.encode(env7)), {})
    T.eq("H9 an invalid farmRestore proof is scoped: the load stays READY with the proof refused", save7.loadResult.state .. "/" .. tostring(save7.loadResult.farmRestoreRefused), "READY/FARM_RESTORE_VERSION")
    -- The carrier-pending collection is injected once at its declared path and restored from there.
    local reg8 = SGRegistry.new("h8")
    local ops8 = SGOperations.new(reg8, "h8")
    local ad8 = reg8:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end, readNativeState = function() end, enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    reg8:registerSaveSection("sg4", section("sg4", {}, { policy = "OWNER" }))
    local pl8 = reg8:registerCarrierPending("sg4", { sectionId = "sg4", collectionPath = "extensions.sg4.guidanceCarriers", schemaVersion = 1, validatePending = function() return true end, prepareCreationBinding = function() return {} end })
    local key8 = { adapterId = "sg2", nativeOwnerKey = "bay", componentKey = "A" }
    ops8:bindCarrier(ad8, { carrierKey = key8, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "bay/A" }, { amount = 0, unit = "l" })
    ops8:setCarrierPending(pl8, key8, 1, 1, { recipe = "R9" })
    local save8 = SGSave.new(reg8, ops8, SGFarmRestore.new("h8"))
    save8.backendId = SGSave.BACKEND_XML
    local env8 = save8:buildEnvelope({})
    T.eq("H10 the pending collection is injected at the owner's declared path", env8.sections.sg4.payload.extensions.sg4.guidanceCarriers.rows[1].pendingTarget.recipe .. "/" .. env8.sections.sg4.payload.extensions.sg4.guidanceCarriers.rows[1].selectionRevision, "R9/2")
    local ops9 = SGOperations.new(reg8, "h9")
    ops9:bindCarrier(ad8, { carrierKey = key8, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "bay/A" }, { amount = 0, unit = "l" })
    local save9 = SGSave.new(reg8, ops9, SGFarmRestore.new("h9"))
    save9.backendId = SGSave.BACKEND_XML
    save9:stageLoad(SGValues.decode(SGValues.encode(env8)), {})
    T.eq("H10b the collection restores its tokens and target onto the empty carrier", (function() local r = ops9:readCarrierPending(pl8, key8) return r.emptyEpoch .. "/" .. r.selectionRevision .. "/" .. tostring(r.pendingTarget and r.pendingTarget.recipe) end)(), "1/2/R9")
end

-- (J) The three cases Bob ranked on the #4 re-check, plus the MINOR each one
-- decides. Ordered as he ranked them: smallest fixture and highest value first.
do
    local function adapterSpec()
        return { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end,
                 readNativeState = function() end, enumerateCarriers = function() return {} end,
                 hasAccess = function() return true end }
    end
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local function bind(owner, comp)
        return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp },
                 adapterVersion = 1, profileId = "silo", profileVersion = 1,
                 quantityBasisKey = owner .. "/" .. comp }
    end

    -- ── J1: CAUSAL_CONFLICT ──────────────────────────────────────────────────
    -- Two causal producers on one destination both claim the same stream key with
    -- DIFFERENT state. Neither claim is preferable and letting the later pid win
    -- would decide it on sort order, so the second is refused.
    --
    -- This also pins the MINOR: the refused producer must land NONE of its cause
    -- keys. Before the repair the key loop continued past the conflict, so the
    -- producer's OTHER keys still wrote into causes while its own property was
    -- unavailable, which is half-accepting an interpretation we just said we could
    -- not trust. Worse, `pairs` has no defined order, so WHICH keys survived
    -- differed between runs on identical input.
    local reg = SGRegistry.new("j")
    local o = SGOperations.new(reg, "j")
    local ad = reg:registerCarrierAdapter("sg2", adapterSpec())

    -- Two causal producers. Names chosen so "aa" sorts before "zz": the
    -- interpretation loop walks pids in sorted order, so "aa" claims first and
    -- "zz" is the one that must be refused.
    local function causalSpec(pid, producerId, claims)
        return { schemaVersion = 1, producerId = producerId, residency = "STORED",
            validate = function() return true end,
            combine = function()
                return { propertyId = pid, schemaVersion = 1, producerId = producerId,
                         propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } }
            end,
            transform = function() return nil end,
            disclosure = function(_, r) return r end,
            validateCause = function() return true end,
            transformCausalState = function() return claims end,
            compactCausalState = function() end }
    end

    -- "aa" claims S1 at sequence 5. "zz" claims the SAME key at sequence 9, and
    -- also claims a second key S2 that nobody else wants.
    local pAA = reg:registerProperty("aa.stream", causalSpec("aa.stream", "aa", {
        ["S1/1"] = { sequence = 5, fingerprint = "fpA" },
    }))
    local pZZ = reg:registerProperty("zz.stream", causalSpec("zz.stream", "zz", {
        ["S1/1"] = { sequence = 9, fingerprint = "fpZ" },
        ["S2/1"] = { sequence = 3, fingerprint = "fpS2" },
    }))

    local src = o:bindCarrier(ad, bind("silo", "a"), { materialRef = wheat, amount = 100, unit = "l" })
    local srcStock = o.stocks[src.stockId]
    local rec = function(pid, producerId)
        return { propertyId = pid, schemaVersion = 1, producerId = producerId, propertyRevision = 0,
                 knowledge = "KNOWN", payload = { p = 1 } }
    end
    o:publishProperties(pAA, { { stockRef = o:stockRef(srcStock), expectedPropertyRevision = 0,
        record = rec("aa.stream", "aa") } }, { sourceStreamId = "S0", epoch = 1, sequence = 1, fingerprint = "f0" })
    -- Revision 0 for BOTH: these are two DIFFERENT properties on the same stock,
    -- so each carries its own property revision. Using 1 for the second reads as a
    -- stale publish, it is refused, and the property never reaches the stock at
    -- all, which silently removes it from the destination this case is about.
    o:publishProperties(pZZ, { { stockRef = o:stockRef(srcStock), expectedPropertyRevision = 0,
        record = rec("zz.stream", "zz") } }, { sourceStreamId = "S0", epoch = 1, sequence = 2, fingerprint = "f1" })

    local dst = o:bindCarrier(ad, bind("cart", "1"), { amount = 0, unit = "l" })
    local cap = o:captureOperation(ad, "TRANSFER", {
        { carrierId = src.carrierId, expectedStockRef = o:stockRef(srcStock) },
        { carrierId = dst.carrierId } })
    local outcome = o:settleOperation(cap.handle, {
        participantsAfter = { [src.carrierId] = { amount = 0, unit = "l" },
                              [dst.carrierId] = { materialRef = wheat, amount = 100, unit = "l" } },
        allocations = { { source = { carrierId = src.carrierId }, destination = { carrierId = dst.carrierId },
                          sourceAmount = 100, sourceUnit = "l", destinationAmount = 100, destinationUnit = "l" } },
    })
    T.eq("J1 the settle commits despite the causal conflict", outcome, "COMMITTED")

    local dstStock = o.stocks[o.carriers[dst.carrierId].stockId]
    T.eq("J1b the FIRST claimant's property survives", dstStock.properties["aa.stream"].knowledge, "KNOWN")
    T.eq("J1c the LATER claimant's property is unavailable", dstStock.properties["zz.stream"].knowledge, "UNAVAILABLE")
    T.eq("J1d and the reason names the producer it conflicted with",
         dstStock.properties["zz.stream"].reason, "CAUSAL_CONFLICT:aa.stream")
    T.eq("J1e the accepted cause for the contested key is the FIRST claimant's",
         dstStock.acceptedCauses["S1/1"].sequence, 5)
    T.eq("J1f and its fingerprint too, not the later one's",
         dstStock.acceptedCauses["S1/1"].fingerprint, "fpA")

    -- THE MINOR. The refused producer's OTHER key must not land either. Before the
    -- repair the loop continued and S2 was written while zz.stream was refused.
    T.eq("J1g THE REFUSED PRODUCER LANDS NONE OF ITS KEYS, not just the contested one",
         dstStock.acceptedCauses["S2/1"], nil)
end

do
    -- ── J1h: an IDENTICAL claim is not a conflict ────────────────────────────
    -- Two producers may legitimately agree about the same stream. Refusing that
    -- would make agreement indistinguishable from disagreement.
    local reg = SGRegistry.new("j2")
    local o = SGOperations.new(reg, "j2")
    local ad = reg:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function() end, readNativeState = function() end,
        enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local function bind(owner, comp)
        return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp },
                 adapterVersion = 1, profileId = "silo", profileVersion = 1,
                 quantityBasisKey = owner .. "/" .. comp }
    end
    local same = { ["S1/1"] = { sequence = 7, fingerprint = "identical" } }
    local function spec(pid, producerId)
        return { schemaVersion = 1, producerId = producerId, residency = "STORED",
            validate = function() return true end,
            combine = function() return { propertyId = pid, schemaVersion = 1, producerId = producerId,
                propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end,
            transform = function() return nil end, disclosure = function(_, r) return r end,
            validateCause = function() return true end,
            transformCausalState = function() return same end,
            compactCausalState = function() end }
    end
    local pA = reg:registerProperty("aa.stream", spec("aa.stream", "aa"))
    local pZ = reg:registerProperty("zz.stream", spec("zz.stream", "zz"))
    local src = o:bindCarrier(ad, bind("silo", "a"), { materialRef = wheat, amount = 100, unit = "l" })
    local s = o.stocks[src.stockId]
    local r = function(pid, pr) return { propertyId = pid, schemaVersion = 1, producerId = pr,
        propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end
    o:publishProperties(pA, { { stockRef = o:stockRef(s), expectedPropertyRevision = 0, record = r("aa.stream", "aa") } },
        { sourceStreamId = "S0", epoch = 1, sequence = 1, fingerprint = "f0" })
    o:publishProperties(pZ, { { stockRef = o:stockRef(s), expectedPropertyRevision = 0, record = r("zz.stream", "zz") } },
        { sourceStreamId = "S0", epoch = 1, sequence = 2, fingerprint = "f1" })
    local dst = o:bindCarrier(ad, bind("cart", "1"), { amount = 0, unit = "l" })
    local cap = o:captureOperation(ad, "TRANSFER", {
        { carrierId = src.carrierId, expectedStockRef = o:stockRef(s) }, { carrierId = dst.carrierId } })
    o:settleOperation(cap.handle, {
        participantsAfter = { [src.carrierId] = { amount = 0, unit = "l" },
                              [dst.carrierId] = { materialRef = wheat, amount = 100, unit = "l" } },
        allocations = { { source = { carrierId = src.carrierId }, destination = { carrierId = dst.carrierId },
            sourceAmount = 100, sourceUnit = "l", destinationAmount = 100, destinationUnit = "l" } } })
    local ds = o.stocks[o.carriers[dst.carrierId].stockId]
    T.eq("J1h an identical claim from a second producer is NOT a conflict",
         ds.properties["zz.stream"].knowledge, "KNOWN")
    T.eq("J1i and the first producer is unaffected", ds.properties["aa.stream"].knowledge, "KNOWN")
    T.eq("J1j the agreed cause is recorded once", ds.acceptedCauses["S1/1"].sequence, 7)
end

do
    -- ── J2: the no-allocation created-set fall-through ───────────────────────
    -- A birth slot legitimately creates a carrier with no source allocation. That
    -- used to take the no-op exit and return NO_OP, leaving the adapter holding a
    -- natively created carrier StockGuard never registered.
    --
    -- THE DECISION, which was Bob's MINOR: the carrier is registered and NO STOCK
    -- is minted. A stock is a provenance record carrying properties an owner
    -- interpreted and causes an owner accepted; with no allocation there is no
    -- contribution, no source and no interpretation callback, so minting one would
    -- assert a history nobody supplied. The amount is not lost, it is on the
    -- carrier's own native state.
    local reg = SGRegistry.new("j3")
    local o = SGOperations.new(reg, "j3")
    local ad = reg:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function() end, readNativeState = function() end,
        enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local binding = { carrierKey = { adapterId = "sg2", nativeOwnerKey = "bale", componentKey = "1" },
        adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "bale/1" }

    -- The slot has to be a captured PARTICIPANT: settle refuses a created binding
    -- whose slot was not in the capture (before.slots), which is what stops an
    -- adapter inventing a carrier after the fact.
    local cap = o:captureOperation(ad, "BIRTH", {
        { slotId = "slot1", nativeCreatorKey = "baler/chamber" } })
    T.ok("J2pre the birth capture opened", cap ~= nil)
    local outcome, why = o:settleOperation(cap.handle, {
        participantsAfter = {},
        allocations = {},
        createdBindings = { ["slot1"] = { binding = binding, nativeCreatorKey = "baler/chamber",
            nativeState = { materialRef = wheat, amount = 240, unit = "l" } } },
    })
    T.eq("J2 a created binding with no allocation COMMITS rather than reporting NO_OP", outcome, "COMMITTED")
    T.eq("J2b and it is not the unexplained-change path", why, nil)

    local carrierId = o:carrierIdOf(binding)
    local carrier = o.carriers[carrierId]
    -- Read through nil rather than indexing it. If the fall-through regresses to
    -- NO_OP the carrier is never registered, and a bare carrier.native.amount
    -- would throw and abort the whole FILE, taking every later case with it and
    -- hiding which rule actually broke. A mutation should fail by name.
    T.ok("J2c the carrier is registered", carrier ~= nil)
    T.eq("J2d its observed amount is on the carrier's native state",
         carrier and carrier.native and carrier.native.amount or nil, 240)
    T.eq("J2e THE DECISION: no stock is minted, because nothing interpreted it",
         carrier and carrier.stockId or nil, nil)
end

do
    -- ── J3: pruneRetired, historical against ordinary ────────────────────────
    -- Separate budgets per set, oldest first within each. The absence of this case
    -- let B10 regress once already.
    local reg = SGRegistry.new("j4")
    local o = SGOperations.new(reg, "j4")
    local ad = reg:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function() end, readNativeState = function() end,
        enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    o.retiredLimit = 2

    -- One historical stock, which arrives through a save restore and must survive
    -- an ordinary-side eviction storm. Its dataRevision is the oldest of all, so a
    -- shared budget or a shared oldest-first sweep would take it FIRST.
    o.retiredStocks["hist1"] = { stockId = "hist1", historical = true, dataRevision = "1" }

    -- Retire more ordinary stocks than the limit, in order, so oldest-first is
    -- observable by which ids survive.
    local ids = {}
    for i = 1, 5 do
        local c = o:bindCarrier(ad, { carrierKey = { adapterId = "sg2", nativeOwnerKey = "s" .. i, componentKey = "a" },
            adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "s" .. i .. "/a" },
            { materialRef = wheat, amount = 10, unit = "l" })
        ids[i] = c.stockId
        o:withdrawCarrier(c.carrierId)
    end

    local ordinary, historical = 0, 0
    for _, s in pairs(o.retiredStocks) do
        if s.historical then historical = historical + 1 else ordinary = ordinary + 1 end
    end
    T.eq("J3 the ordinary set is pruned to its own budget", ordinary, 2)
    T.eq("J3b THE HISTORICAL STOCK SURVIVES an ordinary eviction storm", historical, 1)
    T.ok("J3c and it is still the same record", o.retiredStocks["hist1"] ~= nil)

    -- Oldest first: the two most recently retired are the survivors.
    T.eq("J3d the oldest ordinary retirement was evicted", o.retiredStocks[ids[1]], nil)
    T.eq("J3e the second oldest too", o.retiredStocks[ids[2]], nil)
    T.ok("J3f the two newest ordinary retirements survive",
         o.retiredStocks[ids[4]] ~= nil and o.retiredStocks[ids[5]] ~= nil)

    -- The historical budget is its own, so historical entries evict historical.
    for i = 1, 4 do
        o.retiredStocks["h" .. i] = { stockId = "h" .. i, historical = true, dataRevision = tostring(10 + i) }
    end
    local c = o:bindCarrier(ad, { carrierKey = { adapterId = "sg2", nativeOwnerKey = "trigger", componentKey = "a" },
        adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "trigger/a" },
        { materialRef = wheat, amount = 10, unit = "l" })
    o:withdrawCarrier(c.carrierId)
    local hist2 = 0
    for _, s in pairs(o.retiredStocks) do if s.historical then hist2 = hist2 + 1 end end
    T.eq("J3g the historical set is pruned to its OWN budget, not a shared one", hist2, 2)
    T.eq("J3h and oldest-first took hist1, the oldest of them", o.retiredStocks["hist1"], nil)
end

do
    -- ── J4: THE SORT ITSELF, which was the one part of the repair with no bar ──
    --
    -- Bob deleted table.sort(keys) outright, kept both passes, and the bench stayed
    -- at 1105/0. J1g and J1h are both right and neither needs the sort, because
    -- with ONE conflicting key the order cannot matter.
    --
    -- So this case uses TWO conflicting keys owned by two DIFFERENT prior
    -- producers. Sorted order decides which conflict is found first, and the
    -- refusal reason names that owner. Under `pairs` the reason could name either.
    --
    -- HOW THIS CASE DISCRIMINATES, and read both halves before touching the keys.
    --
    -- THE INVARIANT IS SIMPLE, AND IT IS NOT ABOUT HASHING. This bench runs on
    -- fengari, whose pairs() over string keys is INSERTION ORDERED: a literal
    -- {zebra, apple} traverses zebra then apple, {apple, zebra} traverses apple
    -- then zebra, and assigning mm, bb, zz, aa in that order traverses mm, bb, zz,
    -- aa. Verified directly, in both literal and assignment form, and in reverse.
    --
    -- So the only thing this case needs is that the literal below is NOT already
    -- in sorted order, which is checkable by eye and survives a rename as long as
    -- the later-sorting key stays first. That is why attempt two of this case
    -- failed: the literal listed apple first, insertion order and sorted order
    -- coincided, and deleting the sort changed nothing observable.
    --
    -- THE CEILING, which matters more and is why the sentence above is not the
    -- whole story. Because fengari is insertion ordered, THIS BENCH CANNOT
    -- REPRODUCE THE NONDETERMINISM THE REPAIR EXISTS TO FIX. In the shipped
    -- runtime pairs order over string keys is hash dependent and genuinely
    -- arbitrary between runs; here the pre-repair behaviour was not
    -- nondeterministic at all, merely wrong in a fixed way.
    --
    -- So J4 proves the sort yields one SPECIFIC order. It does not, and no case on
    -- this runtime can, prove the bench would have caught the original defect.
    -- Do not read a green J4 as evidence that the nondeterminism is covered.
    local reg = SGRegistry.new("j5")
    local o = SGOperations.new(reg, "j5")
    local ad = reg:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function() end, readNativeState = function() end,
        enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local function bind(owner, comp)
        return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp },
                 adapterVersion = 1, profileId = "silo", profileVersion = 1,
                 quantityBasisKey = owner .. "/" .. comp }
    end
    local function spec(pid, producerId, claims)
        return { schemaVersion = 1, producerId = producerId, residency = "STORED",
            validate = function() return true end,
            combine = function() return { propertyId = pid, schemaVersion = 1, producerId = producerId,
                propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end,
            transform = function() return nil end, disclosure = function(_, r) return r end,
            validateCause = function() return true end,
            transformCausalState = function() return claims end,
            compactCausalState = function() end }
    end

    -- "aa" owns the alphabetically FIRST contested key, "bb" owns the second.
    -- "zz" sorts last, so it is the one refused, and it contests BOTH.
    local pAA = reg:registerProperty("aa.p", spec("aa.p", "aa", { ["apple/1"] = { sequence = 5, fingerprint = "a" } }))
    local pBB = reg:registerProperty("bb.p", spec("bb.p", "bb", { ["zebra/1"] = { sequence = 6, fingerprint = "b" } }))
    local pZZ = reg:registerProperty("zz.p", spec("zz.p", "zz", {
        -- ZEBRA IS WRITTEN FIRST ON PURPOSE. pairs follows insertion order for
        -- this pair, so listing zebra first makes pairs yield it before apple,
        -- the reverse of sorted order. Written apple-first the two coincide and
        -- the delete-the-sort mutation survives; that was the second version of
        -- this case and it proved nothing.
        ["zebra/1"] = { sequence = 9, fingerprint = "zZ" },
        ["apple/1"] = { sequence = 9, fingerprint = "zA" },
    }))

    local src = o:bindCarrier(ad, bind("silo", "a"), { materialRef = wheat, amount = 100, unit = "l" })
    local s = o.stocks[src.stockId]
    local function r(pid, pr) return { propertyId = pid, schemaVersion = 1, producerId = pr,
        propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end
    o:publishProperties(pAA, { { stockRef = o:stockRef(s), expectedPropertyRevision = 0, record = r("aa.p", "aa") } },
        { sourceStreamId = "S0", epoch = 1, sequence = 1, fingerprint = "f0" })
    o:publishProperties(pBB, { { stockRef = o:stockRef(s), expectedPropertyRevision = 0, record = r("bb.p", "bb") } },
        { sourceStreamId = "S0", epoch = 1, sequence = 2, fingerprint = "f1" })
    o:publishProperties(pZZ, { { stockRef = o:stockRef(s), expectedPropertyRevision = 0, record = r("zz.p", "zz") } },
        { sourceStreamId = "S0", epoch = 1, sequence = 3, fingerprint = "f2" })

    local dst = o:bindCarrier(ad, bind("cart", "1"), { amount = 0, unit = "l" })
    local cap = o:captureOperation(ad, "TRANSFER", {
        { carrierId = src.carrierId, expectedStockRef = o:stockRef(s) }, { carrierId = dst.carrierId } })
    o:settleOperation(cap.handle, {
        participantsAfter = { [src.carrierId] = { amount = 0, unit = "l" },
                              [dst.carrierId] = { materialRef = wheat, amount = 100, unit = "l" } },
        allocations = { { source = { carrierId = src.carrierId }, destination = { carrierId = dst.carrierId },
            sourceAmount = 100, sourceUnit = "l", destinationAmount = 100, destinationUnit = "l" } } })

    local ds = o.stocks[o.carriers[dst.carrierId].stockId]
    T.eq("J4 the refused producer's reason names the owner of the SORTED-FIRST key",
         ds.properties["zz.p"] and ds.properties["zz.p"].reason or nil, "CAUSAL_CONFLICT:aa.p")
    local zzReason = ds.properties["zz.p"] and ds.properties["zz.p"].reason or nil
    T.eq("J4b and it is NOT the owner of the later key, which pairs order could have picked",
         (zzReason == "CAUSAL_CONFLICT:bb.p"), false)
    T.eq("J4c both prior claimants keep their own properties",
         (ds.properties["aa.p"] and ds.properties["aa.p"].knowledge or nil) .. "/" ..
         (ds.properties["bb.p"] and ds.properties["bb.p"].knowledge or nil), "KNOWN/KNOWN")
    T.eq("J4d both contested causes keep the FIRST claimant's state, not the refused one's",
         (ds.acceptedCauses["apple/1"] and ds.acceptedCauses["apple/1"].fingerprint or nil) .. "/" ..
         (ds.acceptedCauses["zebra/1"] and ds.acceptedCauses["zebra/1"].fingerprint or nil), "a/b")
end

do
    -- ── J5: validCauseMap is the sort's ONLY precondition ────────────────────
    -- table.sort over a mixed-type key array throws, and the sole reason it cannot
    -- happen is that validCauseMap requires every key to be a string, three hundred
    -- lines away from the sort. Relaxing that guard leaves the sort unprotected,
    -- and a throw there is caught by settleOperation's pcall as SETTLE_ERROR, so
    -- ONE producer returning a mixed key set would poison an entire settlement
    -- rather than just its own transform. That is the opposite of what the
    -- two-pass repair exists for.
    local reg = SGRegistry.new("j6")
    local o = SGOperations.new(reg, "j6")
    local ad = reg:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function() end, readNativeState = function() end,
        enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local function bind(owner, comp)
        return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp },
                 adapterVersion = 1, profileId = "silo", profileVersion = 1,
                 quantityBasisKey = owner .. "/" .. comp }
    end
    -- An integer stream id, which is exactly the shape someone adds later.
    local bad = reg:registerProperty("bad.p", { schemaVersion = 1, producerId = "bad", residency = "STORED",
        validate = function() return true end,
        combine = function() return { propertyId = "bad.p", schemaVersion = 1, producerId = "bad",
            propertyRevision = 0, knowledge = "KNOWN", payload = { p = 1 } } end,
        transform = function() return nil end, disclosure = function(_, r) return r end,
        validateCause = function() return true end,
        transformCausalState = function() return { [1] = { sequence = 5, fingerprint = "int" } } end,
        compactCausalState = function() end })

    local src = o:bindCarrier(ad, bind("silo", "a"), { materialRef = wheat, amount = 100, unit = "l" })
    local s = o.stocks[src.stockId]
    o:publishProperties(bad, { { stockRef = o:stockRef(s), expectedPropertyRevision = 0,
        record = { propertyId = "bad.p", schemaVersion = 1, producerId = "bad", propertyRevision = 0,
                   knowledge = "KNOWN", payload = { p = 1 } } } },
        { sourceStreamId = "S0", epoch = 1, sequence = 1, fingerprint = "f0" })

    local dst = o:bindCarrier(ad, bind("cart", "1"), { amount = 0, unit = "l" })
    local cap = o:captureOperation(ad, "TRANSFER", {
        { carrierId = src.carrierId, expectedStockRef = o:stockRef(s) }, { carrierId = dst.carrierId } })
    local outcome = o:settleOperation(cap.handle, {
        participantsAfter = { [src.carrierId] = { amount = 0, unit = "l" },
                              [dst.carrierId] = { materialRef = wheat, amount = 100, unit = "l" } },
        allocations = { { source = { carrierId = src.carrierId }, destination = { carrierId = dst.carrierId },
            sourceAmount = 100, sourceUnit = "l", destinationAmount = 100, destinationUnit = "l" } } })

    T.eq("J5 a non-string cause key does NOT poison the whole settlement", outcome, "COMMITTED")
    local ds = o.stocks[o.carriers[dst.carrierId].stockId]
    T.eq("J5b it is refused as a failed transform, contained to its own producer",
         ds.properties["bad.p"] and ds.properties["bad.p"].reason or nil, "CAUSAL_TRANSFORM_FAILED")
    T.eq("J5c and none of its keys were accepted", ds.acceptedCauses[1], nil)
end
