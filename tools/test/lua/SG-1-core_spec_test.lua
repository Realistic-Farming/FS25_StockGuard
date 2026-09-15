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
    local mix = ops:readPropertyMix(consumer, { { stockRef = ops:stockRef(s2), amount = 10, unit = "l" }, { capturedContribution = { properties = {}, knowledge = "UNKNOWN", materialRef = wheat }, amount = 10, unit = "l" } }, {})
    T.eq("E45 mix preview is detached and explicit about the unknown share", mix.state .. "/" .. mix.properties["sf.moisture"].knowledge .. "/" .. mix.properties["sf.moisture"].knownAmount, "READY/PARTIAL/0")
    T.eq("E46 mix preview did not change the store", ops.stocks[s2.stockId].observedAmount, 60)
    -- An error inside settle never leaves the store locked (Sasha, #2 review).
    local cap5 = ops:captureOperation(adapter, "TRANSFER", { { carrierId = c2.carrierId, expectedStockRef = ops:stockRef(s2) } })
    local realSettle = ops._settle
    ops._settle = function() error("adapter report blew up") end
    local o5, why5 = ops:settleOperation(cap5.handle, { participantsAfter = { [c2.carrierId] = { materialRef = wheat, amount = 60, unit = "l" } } })
    ops._settle = realSettle
    T.eq("E26b an exception during settle is UNRESOLVED SETTLE_ERROR", o5 .. "/" .. why5, "UNRESOLVED/SETTLE_ERROR")
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
