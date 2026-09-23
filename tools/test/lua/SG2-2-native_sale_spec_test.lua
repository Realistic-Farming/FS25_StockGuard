-- SG2-2-native_sale_spec_test.lua
--
-- SG2-2 stages (b) to (e): the outer Dischargeable capture, the SellingStation
-- sale bracket, NativeSaleFrameV1 and the MD-16 facade getNativeSaleInputsV1, and
-- settlement of the paid SELLING_STATION route through SG-1.
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine model loads first, then every module
-- main.lua sources, then main.lua. The mission loads through main's own appends;
-- the selling station enters through the engine's StorageSystem:addUnloadingStation,
-- the trailers are in the mission's vehicle list when the barrier runs (and one is
-- added later through VehicleSystem:addVehicle), and every sale is the ENGINE's
-- Dischargeable:dischargeToObject called on the vehicle, through the engine's
-- UnloadTrigger, into the engine's SellingStation body. The consumer is a
-- MarketDynamics-shaped class wrap of SellingStation.sellFillType that calls
-- g_currentMission.stockGuard.getNativeSaleInputsV1(nil) from inside the paid phase,
-- as MD-16 will. Nothing here writes a capture, a frame, a binding or a token.
--
-- Groups:
--   S  the entry-point bar
--   R  refusals: free-standing, zero, stale, altered, unsupported callers
--   M  the unpaid branches: a mission delivery and a station that stores the goods
--   C  a converting chain: the discharge node's converter and the trigger's ratio
--   G  a sale larger than the captured source
--   D  a discharge into a silo station: not captured, the F207 correction applies
--   L  load order: a class wrap installed after the barrier is still reached
--   X  teardown
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local SA, NH, NS, DC = SGStationAdapter, SGNativeHost, SGNativeSale, SGDischargeCapture
local WHEAT, BARLEY, GRASS = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY, ENGINE_FT.GRASS

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission()
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = false },
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

local function newPlaceable(m, uid, storages)
    local p = { uniqueId = uid, getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                spec_silo = { storages = storages or {}, storagePerFarm = false } }
    m._placeables[#m._placeables + 1] = p
    return p
end

--- A trailer as the engine builds it: FillUnit, FillVolume and Dischargeable
--- functions COPIED into the instance (Vehicle.lua copyTypeFunctionsInto), so the
--- discharge capture and the fill unit observer wrap real instance slots.
local function newTrailer(m, uid, fillType, level, converter)
    local v = { uniqueId = uid, configFileName = "data/vehicles/trailer.xml", ownerFarmId = 1, activeFarm = 1,
                spec_fillUnit = { fillUnits = { { fillLevel = level, capacity = 5000, fillType = fillType } } },
                spec_fillVolume = { unloadInfos = { {} } }, spec_dischargeable = {} }
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
    v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
    v.getFillUnitCapacity = function(self, i) return self.spec_fillUnit.fillUnits[i].capacity end
    v.addFillUnitFillLevel = function(self, farmId, i, delta, ft)
        local u = self.spec_fillUnit.fillUnits[i]
        if u == nil then return 0 end
        local before = u.fillLevel
        u.fillLevel = math.max(0, math.min(u.fillLevel + delta, u.capacity))
        if u.fillLevel == 0 then u.fillType = FillType.UNKNOWN elseif delta > 0 then u.fillType = ft end
        return u.fillLevel - before
    end
    v.setFillUnitFillType = function(self, i, ft) self.spec_fillUnit.fillUnits[i].fillType = ft end
    v.emptyAllFillUnits = function(self) for _, u in ipairs(self.spec_fillUnit.fillUnits) do u.fillLevel = 0 u.fillType = FillType.UNKNOWN end end
    v.getFillVolumeUnloadInfo = function(self, index) return self.spec_fillVolume.unloadInfos[index] end
    v.dischargeToObject = Dischargeable.dischargeToObject
    v.getDischargeFillType = Dischargeable.getDischargeFillType
    v.node = { fillUnitIndex = 1, toolType = ToolType.DISCHARGEABLE, info = {}, unloadInfoIndex = 1, fillTypeConverter = converter }
    m._vehicles[#m._vehicles + 1] = v
    return v
end

local function level(v) return v:getFillUnitFillLevel(1) end

-- A MarketDynamics-shaped consumer: a CLASS wrap of sellFillType that asks the
-- facade from inside the paid phase (MD-16 :102, PriceHook.lua:94-111).
local md = { seen = {}, probe = nil }
local function mdWrap()
    local prior = SellingStation.sellFillType
    SellingStation.sellFillType = function(self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
        local handle = g_currentMission.stockGuard
        local inputs, why = nil, "NO_STOCKGUARD"
        if handle ~= nil then inputs, why = handle.getNativeSaleInputsV1(nil) end
        local rec = { inputs = inputs, why = why, fillDelta = fillDelta, toolType = toolType, extraAttributes = extraAttributes }
        if md.probe ~= nil then rec.probe = md.probe() end
        md.seen[#md.seen + 1] = rec
        return prior(self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
    end
    return prior
end
local mdNative = SellingStation.sellFillType

local S = {}

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m = newMission()
    S.m = m
    g_server = {}
    g_currentMission = m
    local ss = m.storageSystem
    local pSell = newPlaceable(m, "placeable:sell")
    local sell = SellingStation.newModel()
    S.sell = sell
    ss:addUnloadingStation(sell, pSell)
    local trig = UnloadTrigger.newModel(sell)
    S.trig = trig
    local tr = newTrailer(m, "vehicle:trailer", WHEAT, 1000)
    S.tr = tr

    -- MarketDynamics installs its price hook at mission load.
    mdWrap()
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    S.sg = sg
    -- A property producer, as a domain owner registers one.
    local lease = m.stockGuard.registerProperty("sg22.moisture", { schemaVersion = 1, producerId = "sg22", residency = "STORED",
        validate = function() return true end, combine = function() return nil end, transform = function() return nil end, disclosure = function(_, r) return r end })
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    local host = NH.current
    S.host = host
    T.ok("S1 [reached] the barrier made the host live", host ~= nil and host.ready == true)
    T.eq("S2 the trailer's discharge was captured by the host's vehicle observation", DC.isInstalled(tr), true)
    T.eq("S3 the selling station got the sale bracket and no quantity correction", tostring(SA.isSaleBracketed(sell)) .. "/" .. tostring(SA.isAdmitted(sell, SA.UNLOAD)), "true/false")

    local carrierId = SGRecords.carrierKeyString(SGNativeAdapters.fillUnitBinding(tr, 1).carrierKey)
    S.carrierId = carrierId
    local stock = sg.operations.stocks[sg.operations.carriers[carrierId].stockId]
    local refBefore = sg.operations:stockRef(stock)
    local published = m.stockGuard.publishProperties(lease, { { stockRef = refBefore, expectedPropertyRevision = 0,
        record = { propertyId = "sg22.moisture", schemaVersion = 1, producerId = "sg22", propertyRevision = 0, knowledge = "KNOWN", knownAmount = 1000, basisAmount = 1000, amountUnit = "LITRE", payload = { moisture = 0.14 } } } })
    T.eq("S4 [world] the trailer's stock carries a known property", published, "APPLIED")
    stock = sg.operations.stocks[sg.operations.carriers[carrierId].stockId]
    refBefore = sg.operations:stockRef(stock)

    -- The sale: the engine's own discharge call on the vehicle.
    md.seen = {}
    local discharged = tr:dischargeToObject(tr.node, 100, trig, 1)
    T.eq("S5 the native return is untouched: the vehicle discharged 100", discharged, -100)
    T.eq("S6 the station sold once, 100 L of wheat, with the native five arguments", #sell.sold .. "/" .. sell.sold[1].fillDelta .. "/" .. tostring(sell.sold[1].toolType == ToolType.DISCHARGEABLE), "1/100/true")
    T.eq("S7 the price hook ran once, inside the paid phase", #md.seen, 1)
    local inputs = md.seen[1] and md.seen[1].inputs
    S.firstInputs = inputs
    T.ok("S8 the facade answered from inside the paid phase", inputs ~= nil, tostring(md.seen[1] and md.seen[1].why))
    inputs = inputs or {}
    T.eq("S9 SaleInputsV1 names the path, farm, paid type, amount and unit",
        tostring(inputs.schemaVersion) .. "/" .. tostring(inputs.nativePath) .. "/" .. tostring(inputs.farmId) .. "/" .. tostring(inputs.fillTypeName) .. "/" .. tostring(inputs.paidAmount) .. "/" .. tostring(inputs.amountUnit),
        "1/SELLING_STATION/1/WHEAT/100/LITRE")
    T.eq("S10 the destination is the station's own mission-local token", inputs.destinationId, host:destinationToken(sell))
    T.ok("S11 the source is the trailer's stock as it was BEFORE the discharge", inputs.stockRefs ~= nil and SGOperations.sameRef(inputs.stockRefs[1], refBefore))
    local c = inputs.capturedContributions and inputs.capturedContributions[1] or {}
    T.eq("S12 one captured contribution", #(inputs.capturedContributions or {}), 1)
    T.eq("S12b on the paid basis: 100 L", c.actualAmount, 100)
    T.eq("S12c projected to 100 L of source", c.sourceAmount, 100)
    local p = c.properties and c.properties["sg22.moisture"] or {}
    T.eq("S13 the source property travels scaled to the sold share", tostring(p.knownAmount) .. "/" .. tostring(p.basisAmount) .. "/" .. tostring(p.payload and p.payload.moisture), "100.0/100.0/0.14")
    T.eq("S14 the contribution is in SG-1's captured grammar (readPropertyMix admits it)", (function()
        local cc = { captureRef = c.captureRef, allocationRef = c.allocationRef, materialRef = c.materialRef, actualAmount = c.actualAmount, amountUnit = c.amountUnit, properties = c.properties, knowledge = c.knowledge }
        local consumer = m.stockGuard.registerConsumer("sg22.md", { version = 1, requiredSchemas = { ["sg22.moisture"] = 1 }, materialKinds = { "FILL_TYPE" }, resolveReadContext = function(q) return { stockRefs = q.stockRefs, purpose = "SALE" } end })
        local mix = m.stockGuard.readPropertyMix(consumer, { { amount = 100, unit = "LITRE", capturedContribution = cc } }, { purpose = "SALE" })
        return mix and mix.state
    end)(), "READY")
    T.eq("S15 the source covers the whole paid basis", tostring(inputs.sourceComplete) .. "/" .. tostring(#(inputs.reasons or {})), "true/0")

    -- Settlement: the source debit retires through SG-1 at once, not at the next flush.
    local after = sg.operations.stocks[sg.operations.carriers[carrierId].stockId]
    T.eq("S16 the trailer's stock reads the settled 900 L immediately after the call", after and after.observedAmount, 900)
    local ls = host.lastSettlement or {}
    local a = ls.report and ls.report.allocations[1] or {}
    local ev = ls.report and ls.report.outcomeEvidence or {}
    T.eq("S16b one COMMITTED REMOVE: the actual 100 L debit retires as SOLD", tostring(ls.outcome) .. "/" .. tostring(a.sourceAmount) .. "/" .. tostring(a.destination and a.destination.retire) .. "/" .. tostring(a.result), "COMMITTED/100.0/true/SOLD")
    T.eq("S16c with the paid basis as evidence and no discrepancy", tostring(ev.paidAmount) .. "/" .. tostring(ev.paidFillTypeName) .. "/" .. tostring(ev.discrepancy), "100/WHEAT/0.0")
    T.eq("S17 and keeps its known property on the remainder", after and after.properties["sg22.moisture"] and after.properties["sg22.moisture"].knowledge, "KNOWN")
    T.eq("S18 nothing was left for the generic path to reconcile", #host.dirtyOrder, 0)
    T.eq("S19 the call-scoped context is back at rest", SGOperationContext.isAtRest(host.context), true)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. REFUSALS: native work runs once in every case
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local m, sell, host, tr, trig, sg = S.m, S.sell, S.host, S.tr, S.trig, S.sg
    md.seen = {}
    local soldBefore = #sell.sold
    local freeFrame
    md.probe = function() local e = host.salePhases[#host.salePhases] freeFrame = e and e.frame return true end
    local okFree, money = pcall(sell.sellFillType, sell, 1, 50, WHEAT, ToolType.TRIGGER, nil)
    md.probe = nil
    T.eq("R1 a free-standing sellFillType still pays natively once", tostring(okFree) .. "/" .. tostring(money) .. "/" .. (#sell.sold - soldBefore), "true/100/1")
    T.eq("R2 and the facade reports no parent", md.seen[1] and md.seen[1].why, "NO_PARENT")
    T.eq("R2b [reached] its frame, reused after the phase, is stale rather than parentless", select(2, m.stockGuard.getNativeSaleInputsV1(freeFrame)), "STALE_FRAME")
    md.seen = {}
    sell:sellFillType(1, 0, WHEAT, ToolType.TRIGGER, nil)
    T.eq("R3 a zero paid amount is refused before anything else", md.seen[1] and md.seen[1].why, "INVALID_PAID")
    T.eq("R4 outside any paid phase the facade has nothing to answer", select(2, m.stockGuard.getNativeSaleInputsV1(nil)), "NO_SALE_PHASE")

    -- A frame this server issued, used after its phase closed, and one altered.
    local issued, altered, alteredWhy
    md.probe = function()
        local entry = host.salePhases[#host.salePhases]
        issued = entry and entry.frame
        if issued ~= nil then
            altered = {}
            for k, v in pairs(issued) do altered[k] = v end
            altered.paidAmount = issued.paidAmount * 2
            alteredWhy = select(2, m.stockGuard.getNativeSaleInputsV1(altered))
            local accepted = m.stockGuard.getNativeSaleInputsV1(issued) ~= nil
            local keep = issued.paidAmount
            issued.paidAmount = keep * 2
            md.inPlaceWhy = select(2, m.stockGuard.getNativeSaleInputsV1(issued))
            issued.paidAmount = keep
            return accepted
        end
        return false
    end
    md.seen = {}
    tr:dischargeToObject(tr.node, 10, trig, 1)
    md.probe = nil
    T.eq("R5 [reached] the issued frame itself is accepted inside its phase", md.seen[1] and md.seen[1].probe, true)
    T.eq("R6 a copy with the paid amount changed is not a frame this server issued", alteredWhy, "UNKNOWN_FRAME")
    T.eq("R6b the issued frame altered in place is refused", md.inPlaceWhy, "FRAME_ALTERED")
    T.eq("R7 the issued frame, reused after its phase, is refused as stale", select(2, m.stockGuard.getNativeSaleInputsV1(issued)), "STALE_FRAME")
    issued.paidAmount = 1
    T.eq("R7b and altered in place it is refused either way", select(2, m.stockGuard.getNativeSaleInputsV1(issued)), "STALE_FRAME")

    -- A vehicle whose discharge is not the engine's is not captured.
    local foreign = newTrailer(m, "vehicle:foreign", WHEAT, 300)
    foreign.dischargeToObject = function(self, ...) return Dischargeable.dischargeToObject(self, ...) end
    local foreignFn = foreign.dischargeToObject
    VehicleSystem.addVehicle(m.vehicleSystem, foreign)
    T.eq("R8 a foreign dischargeToObject is left in place, uncaptured", tostring(foreign.dischargeToObject == foreignFn) .. "/" .. tostring(DC.isInstalled(foreign)), "true/false")
    md.seen = {}
    local soldNow = #sell.sold
    foreign:dischargeToObject(foreign.node, 30, trig, 1)
    T.eq("R9 its sale pays natively once and the facade reports no parent", (#sell.sold - soldNow) .. "/" .. tostring(md.seen[1] and md.seen[1].why), "1/NO_PARENT")
    local fresh = newTrailer(m, "vehicle:fresh", WHEAT, 200)
    VehicleSystem.addVehicle(m.vehicleSystem, fresh)
    T.eq("R10 [reached] twin: an engine vehicle added through VehicleSystem is captured", DC.isInstalled(fresh), true)
    md.seen = {}
    fresh:dischargeToObject(fresh.node, 20, trig, 1)
    T.ok("R11 and its sale gets inputs", md.seen[1] and md.seen[1].inputs ~= nil)
    T.eq("R12 the context is at rest after every refusal", SGOperationContext.isAtRest(host.context), true)

    -- A price hook that raises inside a captured sale: the error reaches the caller
    -- unchanged, the context closes, and nothing settles.
    local boomTr = newTrailer(m, "vehicle:boom", WHEAT, 100)
    VehicleSystem.addVehicle(m.vehicleSystem, boomTr)
    local cidB = SGRecords.carrierKeyString(SGNativeAdapters.fillUnitBinding(boomTr, 1).carrierKey)
    md.probe = function() error("boom") end
    local okB, errB = pcall(boomTr.dischargeToObject, boomTr, boomTr.node, 10, trig, 1)
    md.probe = nil
    T.eq("R13 an error inside the paid phase reaches the caller unchanged", tostring(okB) .. "/" .. tostring(errB ~= nil and tostring(errB):find("boom", 1, true) ~= nil), "false/true")
    T.eq("R14 the context closed and the capture was abandoned, not settled", tostring(SGOperationContext.isAtRest(host.context)) .. "/" .. tostring(host.lastSettlement and host.lastSettlement.outcome) .. "/" .. tostring(host.lastSettlement and host.lastSettlement.reason), "true/ABANDONED/NATIVE_ERROR")
    local stB = sg.operations.stocks[sg.operations.carriers[cidB].stockId]
    T.eq("R15 the untouched trailer keeps its stock: an abandon with no change qualifies nothing", tostring(stB and stB.observedAmount) .. "/" .. tostring(stB and stB.knowledge), "100/UNKNOWN")

    -- Foreign triggers that forward something other than what the discharge offered:
    -- the paid phase does not match its parent, so the facade refuses; native pays once.
    local liarTr = newTrailer(m, "vehicle:liar", WHEAT, 900)
    VehicleSystem.addVehicle(m.vehicleSystem, liarTr)
    local function via(trigger)
        md.seen = {}
        local n = #sell.sold
        liarTr:dischargeToObject(liarTr.node, 10, trigger, 1)
        return (md.seen[1] and md.seen[1].why) or "NO_CALL", #sell.sold - n
    end
    local farmLiar = UnloadTrigger.newModel(sell)
    farmLiar.addFillUnitFillLevel = function(self, farmId, ...) return UnloadTrigger.addFillUnitFillLevel(self, farmId + 1, ...) end
    local why16, n16 = via(farmLiar)
    T.eq("R16 a trigger forwarding another farm: FARM_MISMATCH, paid once", why16 .. "/" .. n16, "FARM_MISMATCH/1")
    local typeLiar = UnloadTrigger.newModel(sell)
    typeLiar.addFillUnitFillLevel = function(self, farmId, u, delta, ft, ...) return UnloadTrigger.addFillUnitFillLevel(self, farmId, u, delta, BARLEY, ...) end
    local why17, n17 = via(typeLiar)
    T.eq("R17 a trigger forwarding another fill type: TYPE_MISMATCH, paid once", why17 .. "/" .. n17, "TYPE_MISMATCH/1")
    local pOther = newPlaceable(m, "placeable:other")
    local sellOther = SellingStation.newModel()
    m.storageSystem:addUnloadingStation(sellOther, pOther)
    local stationLiar = UnloadTrigger.newModel(sell)
    stationLiar.addFillUnitFillLevel = function(self, farmId, u, delta, ft, toolType, fillPositionData, extra) return sellOther:addFillLevelFromTool(farmId, delta, ft, fillPositionData, toolType, extra) end
    md.seen = {}
    liarTr:dischargeToObject(liarTr.node, 10, stationLiar, 1)
    T.eq("R18 a trigger forwarding to another station: DESTINATION_MISMATCH, paid once there", tostring(md.seen[1] and md.seen[1].why) .. "/" .. #sellOther.sold, "DESTINATION_MISMATCH/1")
    local pLoose = newPlaceable(m, "placeable:loose")
    local loose = SellingStation.newModel()
    StorageSystem.newModel():addUnloadingStation(loose, pLoose)
    local captures = host.nextDischarge
    liarTr:dischargeToObject(liarTr.node, 10, UnloadTrigger.newModel(loose), 1)
    T.eq("R19 a selling station the mission never registered is not captured", tostring(host.nextDischarge - captures) .. "/" .. #loose.sold, "0/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. THE UNPAID BRANCHES
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    local m, sell, host, sg, trig = S.m, S.sell, S.host, S.sg, S.trig
    local tr = newTrailer(m, "vehicle:mission", WHEAT, 500)
    VehicleSystem.addVehicle(m.vehicleSystem, tr)
    local cid = SGRecords.carrierKeyString(SGNativeAdapters.fillUnitBinding(tr, 1).carrierKey)
    local deliveries = 0
    sell.missions = { { fillTypeIndex = WHEAT, farmId = 1, fillSold = function(self, delta) deliveries = deliveries + delta end, getCompletion = function() return 0.5 end } }
    md.seen = {}
    local calls = host.nextSaleCall
    tr:dischargeToObject(tr.node, 100, trig, 1)
    sell.missions = {}
    T.eq("M1 a mission delivery reaches the mission once", deliveries, 100)
    T.eq("M2 and produces no sale frame and no price call", tostring(host.nextSaleCall - calls) .. "/" .. #md.seen, "0/0")
    local st = sg.operations.stocks[sg.operations.carriers[cid].stockId]
    T.eq("M3 the delivered litres still retire from the trailer at once", st and st.observedAmount, 400)
    local ls = host.lastSettlement or {}
    local a = ls.report and ls.report.allocations[1] or {}
    T.eq("M3b settled as DELIVERED with reason NO_PAID_SALE, not as a sale", tostring(ls.outcome) .. "/" .. tostring(a.result) .. "/" .. tostring(a.reason), "COMMITTED/DELIVERED/NO_PAID_SALE")

    -- A station that STORES the goods: not carried, today's path kept.
    local store = Storage.newModel({ [WHEAT] = 0, [BARLEY] = 0, [GRASS] = 0 }, 1000, 1)
    local pStore = newPlaceable(m, "placeable:factory", { store })
    m.storageSystem:addStorage(store)
    local factory = SellingStation.newModel()
    factory.getStoreGoods = function() return true end
    factory:addTargetStorage(store)
    m.storageSystem:addUnloadingStation(factory, pStore)
    local tr2 = newTrailer(m, "vehicle:factory", WHEAT, 300)
    VehicleSystem.addVehicle(m.vehicleSystem, tr2)
    local cid2 = SGRecords.carrierKeyString(SGNativeAdapters.fillUnitBinding(tr2, 1).carrierKey)
    md.seen = {}
    local before = host.nextDischarge
    tr2:dischargeToObject(tr2.node, 100, UnloadTrigger.newModel(factory), 1)
    T.eq("M4 storing goods lands them in the store through the class super call", store:getFillLevel(WHEAT), 100)
    T.eq("M5 no discharge was captured for it", host.nextDischarge - before, 0)
    T.eq("M6 its paid phase, if any, has no parent", md.seen[1] and md.seen[1].why, "NO_PARENT")
    local st2 = sg.operations.stocks[sg.operations.carriers[cid2].stockId]
    T.eq("M7 [twin] the trailer is left to the generic path: 300 until the next flush", st2 and st2.observedAmount, 300)
    host:update(NH.FLUSH_INTERVAL_MS)
    st2 = sg.operations.stocks[sg.operations.carriers[cid2].stockId]
    T.eq("M8 and 200 after it", st2 and st2.observedAmount, 200)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A CONVERTING CHAIN
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local m, sell, host, sg = S.m, S.sell, S.host, S.sg
    -- The node converts grass to barley at 0.5; the trigger converts barley to wheat
    -- at 4. The chain's product is 2, so a projection that ignored either leg shows.
    local tr = newTrailer(m, "vehicle:grass", GRASS, 400, { [GRASS] = { targetFillTypeIndex = BARLEY, conversionFactor = 0.5 } })
    VehicleSystem.addVehicle(m.vehicleSystem, tr)
    local cid = SGRecords.carrierKeyString(SGNativeAdapters.fillUnitBinding(tr, 1).carrierKey)
    local trig = UnloadTrigger.newModel(sell, { [BARLEY] = { outgoingFillType = WHEAT, ratio = 4 } })
    md.seen = {}
    local soldBefore = #sell.sold
    local out = tr:dischargeToObject(tr.node, 100, trig, 1)
    T.eq("C1 100 L of grass offered: the station is paid for 200 L of wheat", sell.sold[soldBefore + 1] and sell.sold[soldBefore + 1].fillDelta, 200)
    T.eq("C2 the vehicle is debited 100 L of grass", out, -100)
    local inputs = md.seen[1] and md.seen[1].inputs or {}
    local c = inputs.capturedContributions and inputs.capturedContributions[1] or {}
    T.eq("C3 the facade keeps both bases: wheat paid ...", tostring(inputs.fillTypeName) .. "/" .. tostring(c.materialRef and c.materialRef.fillTypeName), "WHEAT/GRASS")
    T.eq("C3b ... 200 L paid ...", c.actualAmount, 200)
    T.eq("C3c ... from 100 L of grass source", c.sourceAmount, 100)
    T.eq("C4 and names the admitted conversion chain", tostring(c.conversion and c.conversion.dischargeFactor) .. "/" .. tostring(c.conversion and c.conversion.triggerRatio), "0.5/4")
    local st = sg.operations.stocks[sg.operations.carriers[cid].stockId]
    T.eq("C5 the grass settles at its actual debit", st and st.observedAmount, 300)
    local ev = host.lastSettlement and host.lastSettlement.report and host.lastSettlement.report.outcomeEvidence or {}
    T.eq("C6 the evidence projects the paid wheat back to 100 L of grass, no discrepancy", tostring(ev.projectedSourceAmount) .. "/" .. tostring(ev.discrepancy), "100.0/0.0")
end)

group("G", function()
    local m, sell, host, trig = S.m, S.sell, S.host, S.trig
    local tr = newTrailer(m, "vehicle:short", WHEAT, 60)
    VehicleSystem.addVehicle(m.vehicleSystem, tr)
    md.seen = {}
    local out = tr:dischargeToObject(tr.node, 100, trig, 1)
    T.eq("G1 [world] the engine sells the 100 L offered while the trailer held 60", tostring(sell.sold[#sell.sold].fillDelta) .. "/" .. tostring(out), "100/-60")
    local inputs = md.seen[1] and md.seen[1].inputs or {}
    T.eq("G2 the facade says the source does not cover the paid basis", tostring(inputs.sourceComplete) .. "/" .. tostring(inputs.reasons and inputs.reasons[1]), "false/OBSERVATION_GAP")
    local c = inputs.capturedContributions and inputs.capturedContributions[1] or {}
    T.eq("G3 and contributes only the 60 L it captured", c.sourceAmount, 60)
    local ls = host.lastSettlement or {}
    T.eq("G4 the settlement retires the actual 60 L and records the 40 L discrepancy", tostring(ls.outcome) .. "/" .. tostring(ls.report and ls.report.allocations[1].sourceAmount) .. "/" .. tostring(ls.report and ls.report.outcomeEvidence.discrepancy), "COMMITTED/60/-40.0")
end)

group("D", function()
    local m, host = S.m, S.host
    local s1 = Storage.newModel({ [WHEAT] = 0, [BARLEY] = 0, [GRASS] = 0 }, 50, 1)
    local s2 = Storage.newModel({ [WHEAT] = 0, [BARLEY] = 0, [GRASS] = 0 }, 200, 1)
    local pSilo = newPlaceable(m, "placeable:silo", { s1, s2 })
    local us = UnloadingStation.newModel()
    us:addTargetStorage(s1)
    us:addTargetStorage(s2)
    m.storageSystem:addStorage(s1)
    m.storageSystem:addStorage(s2)
    m.storageSystem:addUnloadingStation(us, pSilo)
    local tr = newTrailer(m, "vehicle:silo", WHEAT, 500)
    VehicleSystem.addVehicle(m.vehicleSystem, tr)
    local before = host.nextDischarge
    local out = tr:dischargeToObject(tr.node, 100, UnloadTrigger.newModel(us), 1)
    T.eq("D1 a discharge into a silo station is not captured: station TRANSFER is not carried", host.nextDischarge - before, 0)
    T.eq("D2 and lands 50 then 50 through the F207 correction", s1:getFillLevel(WHEAT) .. "/" .. s2:getFillLevel(WHEAT) .. "/" .. out, "50/50/-100.0")
    T.eq("D3 the context is at rest", SGOperationContext.isAtRest(host.context), true)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. LOAD ORDER: a class wrap installed after the barrier is still reached
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local m, sell, trig = S.m, S.sell, S.trig
    local tr = newTrailer(m, "vehicle:late", WHEAT, 100)
    VehicleSystem.addVehicle(m.vehicleSystem, tr)
    local lateSeen = 0
    local prior = SellingStation.sellFillType
    SellingStation.sellFillType = function(self, ...)
        lateSeen = lateSeen + 1
        return prior(self, ...)
    end
    md.seen = {}
    local soldBefore = #sell.sold
    tr:dischargeToObject(tr.node, 40, trig, 1)
    SellingStation.sellFillType = prior
    T.eq("L1 a wrap installed after our bracket is reached", lateSeen, 1)
    T.eq("L2 and the earlier price hook still sees the frame", tostring(md.seen[1] and md.seen[1].inputs ~= nil), "true")
    T.eq("L3 native paid once", #sell.sold - soldBefore, 1)
    -- TransportCompany's shape: a class wrap of the delivery method after the barrier.
    local deliveries = 0
    local priorDelivery = SellingStation.addFillLevelFromTool
    SellingStation.addFillLevelFromTool = function(self, ...)
        deliveries = deliveries + 1
        return priorDelivery(self, ...)
    end
    md.seen = {}
    tr:dischargeToObject(tr.node, 20, trig, 1)
    SellingStation.addFillLevelFromTool = priorDelivery
    T.eq("L4 a delivery wrap installed after our bracket is reached", deliveries, 1)
    T.eq("L5 and the sale inside it is still joined to its discharge", tostring(md.seen[1] and md.seen[1].inputs ~= nil), "true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. TEARDOWN
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local m, sell, trig, tr = S.m, S.sell, S.trig, S.tr
    FSBaseMission.delete(m)
    T.eq("X1 teardown removes the sale bracket", tostring(rawget(sell, "addFillLevelFromTool")) .. "/" .. tostring(rawget(sell, "sellFillType")), "nil/nil")
    md.seen = {}
    local soldBefore = #sell.sold
    tr:dischargeToObject(tr.node, 10, trig, 1)
    T.eq("X2 after teardown a discharge still sells natively once", #sell.sold - soldBefore, 1)
    T.ok("X3 and no host answers the facade", md.seen[1] ~= nil and md.seen[1].inputs == nil and md.seen[1].why ~= nil, tostring(md.seen[1] and md.seen[1].why))
    SellingStation.sellFillType = mdNative
end)
