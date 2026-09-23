-- SG2-1b-one_native_adapter_spec_test.lua
--
-- SG2-1b (Tyson's ruling (B), 2026-09-23): ONE native carrier adapter owns both the
-- storage and the fill-unit kinds, so a station transfer's source and destinations
-- are one adapter's carriers and settle as ONE SG-1 TRANSFER (SG-1 :238, SG-2 :88,
-- :92). Bob's intake: Drafts/BOB-INTAKE-SG2-1b-ONE-NATIVE-ADAPTER-2026-09-23.md.
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine model loads first, then every module
-- main.lua sources, then main.lua. The mission loads through main's own appends; the
-- stations enter through the engine's StorageSystem:addUnloadingStation and
-- addLoadingStation, the stores through addStorage, the trailers are in the mission's
-- vehicle list when the barrier runs, and every transfer is the ENGINE's call: the
-- vehicle's Dischargeable:dischargeToObject through the engine's UnloadTrigger for an
-- unload, and LoadTrigger's one fill line for a load. Nothing here writes a binding,
-- a carrier, a capture, a frame or an allocation. The one thing the bench supplies
-- is a property producer and the property records on the source stocks, as a domain
-- owner would publish them.
--
-- Groups:
--   S  the entry-point bar: one adapter, both kinds; key collision; UNLOAD 100 L into
--      50 + 200 L free and LOAD 100 L from 50 + 200 L, each ONE transfer, 50 and 50,
--      properties arriving, nothing committed twice
--   U  unequal totals, never rescaled: a short source (the SUSPECT outer load body)
--      leaves the destination's excess unexplained; a source excess is a LOSS leg
--   C  a converting unload (trigger ratio, discharge node factor) is not carried
--   V  a selling station that only stores goods: one transfer through its class super
--      call; one that stores AND sells is not a transfer
--   B  not carried: a BuyingStation's own load (a purchase is a birth) and a
--      conveyor-belt receiver; teardown restores the load bracket's slot
--   O  a dev save from before SG2-1b (sgStorage and sgFillUnit carriers) loads through
--      main.lua: the old stocks become history, the live carriers are read fresh
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local SA, NH, NA = SGStationAdapter, SGNativeHost, SGNativeAdapters
local WHEAT, BARLEY = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the save file: an in-memory XMLFile, so a save and a load use SGSave's own paths
local DISK = {}
XMLFile = {
    create = function(_, path, root)
        local data = {}
        return { setInt = function(_, k, v) data[k] = v end, setString = function(_, k, v) data[k] = v end,
                 save = function() DISK[path] = data return true end, delete = function() end }
    end,
    loadIfExists = function(_, path)
        local data = DISK[path]
        if data == nil then return nil end
        return { getInt = function(_, k, d) local v = data[k] if v == nil then return d end return v end,
                 getString = function(_, k, d) local v = data[k] if v == nil then return d end return v end,
                 delete = function() end }
    end,
}
local function savedEnvelopeAt(dir)
    local data = DISK[dir .. "/" .. SGSave.XML_FILE]
    if data == nil then return nil end
    local tokens = {}
    for i = 1, data[SGSave.XML_ROOT .. "#count"] or 0 do tokens[i] = data[string.format("%s.token(%d)#v", SGSave.XML_ROOT, i - 1)] end
    return (SGValues.decode(tokens))
end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir)
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = { savegameDirectory = saveDir }, missionDynamicInfo = { isMultiplayer = false },
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

local function store(wheat, capacity) return Storage.newModel({ [WHEAT] = wheat, [BARLEY] = 0 }, capacity, 1) end

--- A silo placeable holding `stores`, each registered with the storage system.
local function newSilo(m, uid, stores)
    local p = { uniqueId = uid, getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                spec_silo = { storages = stores, storagePerFarm = false } }
    m._placeables[#m._placeables + 1] = p
    for _, s in ipairs(stores) do m.storageSystem:addStorage(s) end
    return p
end

--- A trailer as the engine builds it: FillUnit, FillVolume and Dischargeable functions
--- COPIED into the instance, so the discharge capture and the fill unit observer wrap
--- real instance slots. opts.keep makes a receiver that keeps only that share of what
--- it reports accepting; opts.converter is a discharge node fill type converter.
local function newTrailer(m, uid, fillType, level, opts)
    opts = opts or {}
    local v = { uniqueId = uid, configFileName = "data/vehicles/trailer.xml", ownerFarmId = 1, activeFarm = 1,
                spec_fillUnit = { fillUnits = { { fillLevel = level, capacity = 5000, fillType = level > 0 and fillType or FillType.UNKNOWN } } },
                spec_fillVolume = { unloadInfos = { {} } }, spec_dischargeable = {} }
    v.isa = function(self, class) return class == Vehicle end
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
    v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
    v.getFillUnitCapacity = function(self, i) return self.spec_fillUnit.fillUnits[i].capacity end
    v.getFillUnitFreeCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u.capacity - u.fillLevel end
    v.addFillUnitFillLevel = function(self, farmId, i, delta, ft)
        local u = self.spec_fillUnit.fillUnits[i]
        if u == nil then return 0 end
        local before = u.fillLevel
        u.fillLevel = math.max(0, math.min(u.fillLevel + delta, u.capacity))
        if u.fillLevel == 0 then u.fillType = FillType.UNKNOWN elseif delta > 0 then u.fillType = ft end
        return u.fillLevel - before
    end
    if opts.keep ~= nil then
        local honest = v.addFillUnitFillLevel
        v.addFillUnitFillLevel = function(self, farmId, i, delta, ...)
            return honest(self, farmId, i, delta * opts.keep, ...) / opts.keep
        end
    end
    v.setFillUnitFillType = function(self, i, ft) self.spec_fillUnit.fillUnits[i].fillType = ft end
    v.emptyAllFillUnits = function(self) for _, u in ipairs(self.spec_fillUnit.fillUnits) do u.fillLevel = 0 u.fillType = FillType.UNKNOWN end end
    v.getFillVolumeUnloadInfo = function(self, index) return self.spec_fillVolume.unloadInfos[index] end
    v.dischargeToObject = Dischargeable.dischargeToObject
    v.getDischargeFillType = Dischargeable.getDischargeFillType
    v.node = { fillUnitIndex = 1, toolType = ToolType.DISCHARGEABLE, info = {}, unloadInfoIndex = 1, fillTypeConverter = opts.converter }
    m._vehicles[#m._vehicles + 1] = v
    return v
end

local function unload(tr, station, conversions) return tr:dischargeToObject(tr.node, 100, UnloadTrigger.newModel(station, conversions), 1) end
local function load(station, receiver, amount)
    return LoadTrigger.fillStep({ source = station, currentFillableObject = receiver, fillUnitIndex = 1, selectedFillType = WHEAT, dischargeInfo = nil }, amount or 100)
end

-- ── a property producer, as a domain owner registers one (SG-1 bench shape) ───
local PROP = "sg21b.moisture"
local function moisture(m, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "sg21b", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { m = m } }
end
local moistureSpec = { schemaVersion = 1, producerId = "sg21b", residency = "STORED",
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total, w = 0, 0
        for _, c in ipairs(contributions) do local p = c.properties[PROP] total = total + c.amount if p and p.payload then w = w + p.payload.m * c.amount end end
        if before then local p = before.properties[PROP] total = total + before.observedAmount if p and p.payload then w = w + p.payload.m * before.observedAmount end end
        if total == 0 then return nil, "NO_MATERIAL" end
        return moisture(w / total, total)
    end,
    transform = function() return nil end, disclosure = function(_, r) return r end }

--- Boot one mission through main.lua's own load path: build the world, load, register
--- the producer, finish loading (which installs the host), then the restore barrier.
local function boot(build, saveDir)
    local m = newMission(saveDir)
    g_server = {}
    g_currentMission = m
    local w = {}
    build(m, m.storageSystem, w)
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    local lease = m.stockGuard.registerProperty(PROP, moistureSpec)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, sg, NH.current, lease, w
end

-- ── readers ───────────────────────────────────────────────────────────────
--- A quantity as text, rounded to four places, with no integer/float spelling: the
--- engine's own arithmetic decides whether a level is 100 or 100.0 in Lua 5.3.
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function storeId(p, ordinal, name) return cid(NA.storageBinding(p, { role = "silo", ordinal = ordinal, partition = "shared" }, name or "WHEAT")) end
local function unitId(v) return cid(NA.fillUnitBinding(v, 1)) end
local function stockAt(sg, id) local c = sg.operations.carriers[id] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end
local function publish(m, sg, lease, id, value)
    local s = stockAt(sg, id)
    if s == nil then return "NO_STOCK" end
    return m.stockGuard.publishProperties(lease, { { stockRef = sg.operations:stockRef(s), expectedPropertyRevision = 0, record = moisture(value, s.observedAmount) } })
end
local function props(s)
    if s == nil then return "nil" end
    local p = s.properties[PROP]
    if p == nil then return tostring(s.knowledge) .. ":none" end
    return tostring(s.knowledge) .. ":" .. num(p.payload.m) .. ":" .. num(p.knownAmount)
end
--- The settlement's allocations as "source>destination:amount:result[:reason]".
local function legsOf(ls, names)
    local out = {}
    for _, a in ipairs(ls and ls.report and ls.report.allocations or {}) do
        local dst = a.destination.retire and "retire" or (names[a.destination.carrierId] or "?")
        out[#out + 1] = (names[a.source.carrierId] or "?") .. ">" .. dst .. ":" .. num(a.sourceAmount) .. ":" .. tostring(a.result) .. (a.reason and (":" .. a.reason) or "")
    end
    return table.concat(out, ",")
end
local function totals(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return num(ev.sourceTotal) .. "/" .. num(ev.destinationTotal) .. "/" .. num(ev.loss) .. "/" .. num(ev.unexplainedGain)
end
local function head(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome)
end
local function evidence(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.fillTypeName) .. "/" .. num(ev.requestedAmount)
end
--- How often the generic path observed any of `ids` while fn ran.
local function genericObservations(host, ids, fn)
    local n, real = 0, host.handle.observeCarrier
    host.handle.observeCarrier = function(lease, key, ...) if ids[key] then n = n + 1 end return real(lease, key, ...) end
    local ok, err = pcall(fn)
    host.handle.observeCarrier = real
    if not ok then error(err, 0) end
    return n
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg, host, lease, w = boot(function(m, ss, w)
        -- An unloading silo: two EMPTY stores with 50 L and 200 L free, then a store
        -- another farm owns and a store that takes no wheat. The native loop skips both
        -- (UnloadingStation.lua:246, :247), so neither may become a participant.
        w.u = { store(0, 50), store(0, 200), Storage.newModel({ [WHEAT] = 0, [BARLEY] = 0 }, 500, 2), Storage.newModel({ [BARLEY] = 0 }, 500, 1) }
        w.pU = newSilo(m, "placeable:U", w.u)
        w.us = UnloadingStation.newModel()
        for _, s in ipairs(w.u) do w.us:addTargetStorage(s) end
        ss:addUnloadingStation(w.us, w.pU)
        -- A loading silo: 50 L and 200 L of wheat.
        w.l = { store(50, 1000), store(200, 1000) }
        w.pL = newSilo(m, "placeable:L", w.l)
        w.ls = LoadingStation.newModel()
        for _, s in ipairs(w.l) do w.ls:addSourceStorage(s) end
        ss:addLoadingStation(w.ls, w.pL)
        -- A placeable and a vehicle whose unique ids are the same string.
        w.pK = newSilo(m, "shared:7", { store(30, 1000) })
        w.kV = newTrailer(m, "shared:7", BARLEY, 40)
        w.tr = newTrailer(m, "vehicle:unload", WHEAT, 100)
        w.rv = newTrailer(m, "vehicle:load", WHEAT, 0)
    end)
    T.ok("S1 [reached] main.lua's load path installed the host and the barrier made it live", host ~= nil and host.ready == true and host.handle == m.stockGuard)

    -- One adapter, both kinds.
    local ids = {}
    for id in sg.registry:each(SGRegistry.KIND_CARRIER_ADAPTER) do ids[#ids + 1] = id end
    T.eq("S2 ONE carrier adapter is registered, the native one", table.concat(ids, ","), "sgNative")
    local lease0 = sg.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, "sgNative")
    T.eq("S3 it owns every native kind: storage, fill unit and, since SG2-3, the Combine's two buffers", lease0 and table.concat(lease0.spec.carrierKinds, ","), "storage,fillUnit,combineDelaySlot,combineStrawSlot")
    T.eq("S4 neither SG2-1 id is registered", tostring(sg.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, "sgStorage")) .. "/" .. tostring(sg.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, "sgFillUnit")), "nil/nil")
    local n, foreign, kinds = 0, 0, {}
    for _, c in pairs(sg.operations.carriers) do
        n = n + 1
        if c.adapterId ~= "sgNative" then foreign = foreign + 1 end
        kinds[c.binding.sourceDescriptor.kind] = (kinds[c.binding.sourceDescriptor.kind] or 0) + 1
    end
    T.eq("S5 the barrier bound three store slots and three fill units, every one under the one adapter",
        n .. "/" .. foreign .. "/" .. tostring(kinds.storage) .. "/" .. tostring(kinds.fillUnit), "6/0/3/3")

    -- Keys cannot collide.
    local kStore, kUnit = storeId(w.pK, 0), unitId(w.kV)
    T.ok("K1 a placeable and a vehicle sharing the owner-key string get different carrier keys", kStore ~= nil and kUnit ~= nil and kStore ~= kUnit)
    local ks, kv = stockAt(sg, kStore), stockAt(sg, kUnit)
    T.eq("K2 both were bound by the barrier, each to its own stock", num(ks and ks.observedAmount) .. "/" .. num(kv and kv.observedAmount), "30/40")
    T.eq("K3 the storage component key carries its kind", sg.operations.carriers[kStore] and sg.operations.carriers[kStore].binding.carrierKey.componentKey, "storage:silo:0:shared:WHEAT")

    -- UNLOAD: 100 L from the trailer into 50 L + 200 L free.
    local u1, u2, trId = storeId(w.pU, 0), storeId(w.pU, 1), unitId(w.tr)
    T.eq("S6 [world] the destination slots are empty and hold no carrier: enumeration binds only slots with material", tostring(sg.operations.carriers[u1]) .. "/" .. tostring(sg.operations.carriers[u2]), "nil/nil")
    T.eq("S7 [world] the trailer's 100 L carries a known property", publish(m, sg, lease, trId, 0.14), "APPLIED")
    local trStockId = stockAt(sg, trId).stockId
    local before = host.nextDischarge
    local out
    local generic = genericObservations(host, { [u1] = true, [u2] = true, [trId] = true }, function() out = unload(w.tr, w.us) end)
    T.eq("S8 the native return is untouched and the F207 correction still lands 50 then 50", num(out) .. "/" .. num(w.u[1]:getFillLevel(WHEAT)) .. "/" .. num(w.u[2]:getFillLevel(WHEAT)), "-100/50/50")
    local ls = host.lastSettlement
    T.eq("S9 ONE station TRANSFER, committed", tostring(host.nextDischarge - before) .. "/" .. head(ls), "1/STATION_UNLOAD/COMMITTED")
    local names = { [trId] = "tr", [u1] = "u1", [u2] = "u2" }
    T.eq("S10 two allocations, 50 and 50, from the trailer into each store", legsOf(ls, names), "tr>u1:50:TRANSFERRED,tr>u2:50:TRANSFERRED")
    T.eq("S11 the totals match: nothing lost, nothing unexplained", totals(ls), "100/100/0/0")
    T.eq("S11b the evidence names the material and the requested amount (SG-2 :90)", evidence(ls), "WHEAT/100")
    local s1, s2 = stockAt(sg, u1), stockAt(sg, u2)
    T.eq("S12 the empty slots were refreshed and captured: each now holds a stock born of the transfer", num(s1 and s1.observedAmount) .. "/" .. num(s2 and s2.observedAmount), "50/50")
    T.eq("S13 the trailer's property arrived in both stores, known, over each store's amount", props(s1) .. " " .. props(s2), "KNOWN:0.14:50 KNOWN:0.14:50")
    T.eq("S13b with no unexplained delta", tostring(s1 and s1.reason) .. "/" .. tostring(s2 and s2.reason), "nil/nil")
    T.eq("S13c [world] the station's other two stores took nothing", num(w.u[3]:getFillLevel(WHEAT)) .. "/" .. num(w.u[4]:getFillLevel(WHEAT)), "0/0")
    T.eq("S13d a store another farm owns is no participant: its empty slot was never bound", tostring(sg.operations.carriers[storeId(w.pU, 2)]), "nil")
    T.eq("S13e nor is a store that takes no wheat", tostring(sg.operations.carriers[storeId(w.pU, 3)]), "nil")
    local retired = sg.operations.retiredStocks[trStockId]
    T.eq("S14 the trailer's stock retired as TRANSFERRED_OUT and the unit holds none", tostring(retired and retired.retireReason) .. "/" .. tostring(stockAt(sg, trId)), "TRANSFERRED_OUT/nil")
    T.eq("S15 the Storage bracket's and the observer's reports were consumed: the generic path observed no participant", generic .. "/" .. #host.dirtyOrder, "0/0")
    local rev1, rev2 = s1 and s1.dataRevision, s2 and s2.dataRevision
    host:flush()
    FSBaseMission.update(m, 1000)
    T.eq("S16 and a flush after the call commits nothing a second time", tostring(stockAt(sg, u1) == s1 and s1.dataRevision == rev1) .. "/" .. tostring(stockAt(sg, u2) == s2 and s2.dataRevision == rev2), "true/true")
    T.eq("S17 the call-scoped context is at rest", SGOperationContext.isAtRest(host.context), true)

    -- LOAD: 100 L from 50 L + 200 L into the empty trailer.
    local l1, l2, rvId = storeId(w.pL, 0), storeId(w.pL, 1), unitId(w.rv)
    T.eq("S18 [world] both source stores carry a known property", publish(m, sg, lease, l1, 0.10) .. "/" .. publish(m, sg, lease, l2, 0.20), "APPLIED/APPLIED")
    local l1StockId = stockAt(sg, l1).stockId
    -- A probe OUTSIDE the fill unit observer records the context the receiver's fill ran in.
    local seen = {}
    local observed = w.rv.addFillUnitFillLevel
    w.rv.addFillUnitFillLevel = function(self, ...)
        local f = SGOperationContext.current(host.context)
        seen[#seen + 1] = f
        return observed(self, ...)
    end
    local beforeT = host.nextTransfer
    local served
    generic = genericObservations(host, { [l1] = true, [l2] = true, [rvId] = true }, function() served = load(w.ls, w.rv) end)
    w.rv.addFillUnitFillLevel = observed
    T.eq("S19 a 100 L load from 50 L + 200 L serves 100 and takes 50 then 50", num(served) .. "/" .. num(w.l[1]:getFillLevel(WHEAT)) .. "/" .. num(w.l[2]:getFillLevel(WHEAT)) .. "/" .. num(w.rv:getFillUnitFillLevel(1)), "100/0/150/100")
    local f = seen[1]
    T.eq("S20 the receiver's fill ran INSIDE the load TRANSFER context", tostring(f and f.kind), "LOAD_TRANSFER")
    local order = {}
    for _, obs in ipairs(f and f.observations or {}) do order[#order + 1] = obs.source end
    T.eq("S21 which spans the receiver's fill AND the source debit after it", table.concat(order, ","), "FILL_UNIT,STORAGE,STORAGE")
    local lt = host.lastSettlement
    T.eq("S22 ONE station TRANSFER for the load, committed", tostring(host.nextTransfer - beforeT) .. "/" .. head(lt), "1/STATION_LOAD/COMMITTED")
    T.eq("S23 two allocations, 50 and 50, from each store into the trailer", legsOf(lt, { [l1] = "l1", [l2] = "l2", [rvId] = "rv" }), "l1>rv:50:TRANSFERRED,l2>rv:50:TRANSFERRED")
    T.eq("S24 the totals match", totals(lt), "100/100/0/0")
    T.eq("S24b and the evidence names the material and the requested amount", evidence(lt), "WHEAT/100")
    T.eq("S25 the trailer's new stock mixes both sources' property by what each gave", props(stockAt(sg, rvId)), "KNOWN:0.15:100")
    local l1r = sg.operations.retiredStocks[l1StockId]
    T.eq("S26 the emptied store retired TRANSFERRED_OUT; the other keeps 150 L with its own property", tostring(l1r and l1r.retireReason) .. "/" .. props(stockAt(sg, l2)), "TRANSFERRED_OUT/KNOWN:0.2:150")
    T.eq("S27 nothing for the generic path here either", generic .. "/" .. #host.dirtyOrder, "0/0")
    T.eq("S28 the context is at rest", SGOperationContext.isAtRest(host.context), true)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNEQUAL TOTALS ARE NEVER RESCALED (SG-2 :231)
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local m, sg, host, lease, w = boot(function(m, ss, w)
        -- Two 50 L sources; the first is HELD: its setter writes nothing.
        w.l = { store(50, 1000), store(50, 1000) }
        w.l[1].setFillLevel = function() end
        w.p = newSilo(m, "placeable:SHORT", w.l)
        w.ls = LoadingStation.newModel()
        for _, s in ipairs(w.l) do w.ls:addSourceStorage(s) end
        ss:addLoadingStation(w.ls, w.p)
        w.rv = newTrailer(m, "vehicle:short", WHEAT, 100)
        -- One 200 L source and a receiver that keeps half of what it reports accepting.
        w.c = { store(200, 1000) }
        w.pc = newSilo(m, "placeable:LOSS", w.c)
        w.lc = LoadingStation.newModel()
        w.lc:addSourceStorage(w.c[1])
        ss:addLoadingStation(w.lc, w.pc)
        w.lie = newTrailer(m, "vehicle:keeps-half", WHEAT, 0, { keep = 0.5 })
    end)
    local held, free, rvId = storeId(w.p, 0), storeId(w.p, 1), unitId(w.rv)
    T.eq("U0 [world] the trailer's 100 L and the free store's 50 L carry known properties", publish(m, sg, lease, rvId, 0.30) .. "/" .. publish(m, sg, lease, free, 0.10), "APPLIED/APPLIED")
    local rvStock, heldStock = stockAt(sg, rvId), stockAt(sg, held)
    local heldRev = heldStock and heldStock.dataRevision
    local served = load(w.ls, w.rv)
    T.eq("U1 [world] the engine's load: the trailer took 100 L while the stores gave 50 (the SUSPECT outer body)",
        num(served) .. "/" .. num(w.rv:getFillUnitFillLevel(1)) .. "/" .. num(w.l[1]:getFillLevel(WHEAT)) .. "/" .. num(w.l[2]:getFillLevel(WHEAT)), "50/200/50/0")
    local ls = host.lastSettlement
    T.eq("U2 one TRANSFER, committed", head(ls), "STATION_LOAD/COMMITTED")
    T.eq("U3 ONE allocation, of the 50 L the store actually gave, not rescaled to the 100 L received",
        legsOf(ls, { [held] = "held", [free] = "free", [rvId] = "rv" }), "free>rv:50:TRANSFERRED")
    T.eq("U4 the 50 L the trailer gained beyond it is named as unexplained", totals(ls), "50/100/0/50")
    local rs = stockAt(sg, rvId)
    T.eq("U5 the trailer keeps its stock, now 200 L, qualified by the unexplained delta",
        tostring(rs ~= nil and rs.stockId == rvStock.stockId) .. "/" .. num(rs and rs.observedAmount) .. "/" .. tostring(rs and rs.knowledge) .. "/" .. tostring(rs and rs.reason),
        "true/200/PARTIAL/UNEXPLAINED_DELTA")
    local hs = stockAt(sg, held)
    T.eq("U6 the held store gave nothing: same stock, 50 L, not rewritten", tostring(hs == heldStock) .. "/" .. num(hs and hs.observedAmount) .. "/" .. tostring(hs and hs.dataRevision == heldRev), "true/50/true")

    -- A source excess: the receiver reports 100 L accepted and keeps 50.
    local src, lieId = storeId(w.pc, 0), unitId(w.lie)
    T.eq("U7 [world] the source's 200 L carries a known property", publish(m, sg, lease, src, 0.25), "APPLIED")
    served = load(w.lc, w.lie)
    T.eq("U8 [world] the engine's load: the store gave 100 L and the trailer kept 50", num(served) .. "/" .. num(w.c[1]:getFillLevel(WHEAT)) .. "/" .. num(w.lie:getFillUnitFillLevel(1)), "100/100/50")
    ls = host.lastSettlement
    T.eq("U9 the 50 L that arrived moves, and the 50 L that did not retires as a LOSS leg",
        legsOf(ls, { [src] = "src", [lieId] = "rv" }), "src>rv:50:TRANSFERRED,src>retire:50:LOSS:UNMATCHED_SOURCE")
    T.eq("U10 with the totals saying so", totals(ls), "100/50/50/0")
    local ss_, ls_ = stockAt(sg, src), stockAt(sg, lieId)
    T.eq("U11 the source keeps 100 L with its property and no unexplained delta; the trailer holds 50 L of it",
        props(ss_) .. "/" .. tostring(ss_ and ss_.reason) .. " " .. props(ls_), "KNOWN:0.25:100/nil KNOWN:0.25:50")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A CONVERTING UNLOAD IS NOT CARRIED
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local m, sg, host, lease, w = boot(function(m, ss, w)
        w.c = { store(0, 500) }
        w.p = newSilo(m, "placeable:C", w.c)
        w.us = UnloadingStation.newModel()
        w.us:addTargetStorage(w.c[1])
        ss:addUnloadingStation(w.us, w.p)
        w.tRatio = newTrailer(m, "vehicle:ratio", WHEAT, 100)
        w.tFactor = newTrailer(m, "vehicle:factor", WHEAT, 100, { converter = { [WHEAT] = { targetFillTypeIndex = WHEAT, conversionFactor = 2 } } })
        w.tType = newTrailer(m, "vehicle:type", WHEAT, 100)
        w.tHalf = newTrailer(m, "vehicle:half", WHEAT, 100)
        w.tPlain = newTrailer(m, "vehicle:plain", WHEAT, 100)
    end)
    local before = host.nextDischarge
    unload(w.tRatio, w.us, { [WHEAT] = { ratio = 0.5, outgoingFillType = BARLEY } })
    T.eq("C1 [world] the trigger converts: the trailer's 100 L of wheat lands as 50 L of barley", num(w.tRatio:getFillUnitFillLevel(1)) .. "/" .. num(w.c[1]:getFillLevel(BARLEY)), "0/50")
    T.eq("C2 a trigger conversion that changes type and amount is not carried", host.nextDischarge - before, 0)
    local barley = stockAt(sg, storeId(w.p, 0, "BARLEY"))
    T.eq("C3 each side keeps the per-side path: the store's barley is read with UNKNOWN history", num(barley and barley.observedAmount) .. "/" .. tostring(barley and barley.knowledge), "50/UNKNOWN")
    -- Each guard alone: the type at ratio 1, then the ratio with the type kept.
    unload(w.tType, w.us, { [WHEAT] = { ratio = 1, outgoingFillType = BARLEY } })
    T.eq("C3b a conversion that only changes type is not carried", num(w.c[1]:getFillLevel(BARLEY)) .. "/" .. tostring(host.nextDischarge - before), "150/0")
    unload(w.tFactor, w.us)
    T.eq("C4 [world] the discharge node's factor 2 sends 200 L to the station for 100 L off the trailer", num(w.tFactor:getFillUnitFillLevel(1)) .. "/" .. num(w.c[1]:getFillLevel(WHEAT)), "0/200")
    T.eq("C5 a discharge factor other than 1 is not carried", host.nextDischarge - before, 0)
    unload(w.tHalf, w.us, { [WHEAT] = { ratio = 0.5, outgoingFillType = WHEAT } })
    T.eq("C5b a trigger ratio other than 1 that keeps the type is not carried either", num(w.c[1]:getFillLevel(WHEAT)) .. "/" .. tostring(host.nextDischarge - before), "250/0")
    unload(w.tPlain, w.us)
    T.eq("C6 [twin] an identity unload into the same station IS carried", tostring(host.nextDischarge - before) .. "/" .. head(host.lastSettlement), "1/STATION_UNLOAD/COMMITTED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. A SELLING STATION THAT ONLY STORES GOODS
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local m, sg, host, lease, w = boot(function(m, ss, w)
        w.v = { store(0, 50), store(0, 200) }
        w.p = newSilo(m, "placeable:V", w.v)
        w.keep = SellingStation.newModel()
        w.keep.getStoreGoods = function() return true end
        w.keep.getSkipSell = function() return true end
        for _, s in ipairs(w.v) do w.keep:addTargetStorage(s) end
        ss:addUnloadingStation(w.keep, w.p)
        w.both = SellingStation.newModel()
        w.both.getStoreGoods = function() return true end
        w.bothStore = { store(0, 500) }
        w.pb = newSilo(m, "placeable:BOTH", w.bothStore)
        w.both:addTargetStorage(w.bothStore[1])
        ss:addUnloadingStation(w.both, w.pb)
        w.tr = newTrailer(m, "vehicle:keep", WHEAT, 100)
        w.tb = newTrailer(m, "vehicle:both", WHEAT, 100)
    end)
    T.eq("V1 [world] the selling station keeps its own method: sale-bracketed, never corrected", tostring(SA.isSaleBracketed(w.keep)) .. "/" .. tostring(SA.isAdmitted(w.keep, SA.UNLOAD)), "true/false")
    local v1, v2, trId = storeId(w.p, 0), storeId(w.p, 1), unitId(w.tr)
    local before = host.nextDischarge
    local out = unload(w.tr, w.keep)
    T.eq("V2 [world] its class super call runs the NATIVE loop, which lands 150 L for a 100 L debit (F207, uncorrected here)",
        num(w.v[1]:getFillLevel(WHEAT)) .. "/" .. num(w.v[2]:getFillLevel(WHEAT)) .. "/" .. num(out), "50/100/-100")
    local ls = host.lastSettlement
    T.eq("V3 ONE transfer through the selling station, and nothing sold", tostring(host.nextDischarge - before) .. "/" .. head(ls) .. "/" .. #w.keep.sold, "1/STATION_UNLOAD/COMMITTED/0")
    T.eq("V4 the debit is allocated by what each store gained, the 50 L beyond it left unexplained, not rescaled",
        legsOf(ls, { [trId] = "tr", [v1] = "v1", [v2] = "v2" }) .. " " .. totals(ls), "tr>v1:33.3333:TRANSFERRED,tr>v2:66.6667:TRANSFERRED 100/150/0/50")
    local s1, s2 = stockAt(sg, v1), stockAt(sg, v2)
    T.eq("V5 both stores' stocks carry the unexplained delta", tostring(s1 and s1.reason) .. "/" .. tostring(s2 and s2.reason), "UNEXPLAINED_DELTA/UNEXPLAINED_DELTA")
    before = host.nextDischarge
    unload(w.tb, w.both)
    T.eq("V6 [twin] a selling station that stores AND sells is neither a transfer nor a sale here: not carried", tostring(host.nextDischarge - before) .. "/" .. #w.both.sold, "0/1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. A NATIVE ERROR INSIDE A TRANSFER
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local m, sg, host, lease, w = boot(function(m, ss, w)
        -- The source store's setter raises: the receiver has already been filled
        -- (LoadingStation.lua:217) when the debit throws (:218).
        w.l = { store(50, 1000) }
        w.l[1].setFillLevel = function() error("store boom") end
        w.p = newSilo(m, "placeable:BOOM", w.l)
        w.ls = LoadingStation.newModel()
        w.ls:addSourceStorage(w.l[1])
        ss:addLoadingStation(w.ls, w.p)
        w.rv = newTrailer(m, "vehicle:boom", WHEAT, 0)
    end)
    local before = host.nextTransfer
    local ok, err = pcall(load, w.ls, w.rv)
    T.eq("E1 [world] the error reaches the engine unchanged, from inside a captured transfer",
        tostring(ok) .. "/" .. tostring(tostring(err):find("store boom", 1, true) ~= nil) .. "/" .. tostring(host.nextTransfer - before), "false/true/1")
    local ls = host.lastSettlement or {}
    T.eq("E2 the transfer is abandoned as a native error, never committed", tostring(ls.outcome) .. "/" .. tostring(ls.reason), "ABANDONED/NATIVE_ERROR")
    T.eq("E3 the context is at rest", SGOperationContext.isAtRest(host.context), true)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. NOT CARRIED: A PURCHASE, A CONVEYOR BELT; AND TEARDOWN
-- ══════════════════════════════════════════════════════════════════════════
-- BuyingStation.lua:89-111, MODELED: its own addFillLevelToFillableObject fills the
-- receiver from nothing (the price and money lines are the shop's, not this bench's).
local Buying = setmetatable({}, { __index = LoadingStation })
local Buying_mt = { __index = Buying }
function Buying:addFillLevelToFillableObject(fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
    if fillableObject == nil or fillTypeIndex == FillType.UNKNOWN or fillDelta == 0 or toolType == nil then return 0 end
    return fillableObject:addFillUnitFillLevel(fillableObject:getOwnerFarmId(), fillUnitIndex, fillDelta, fillTypeIndex, toolType, fillInfo)
end

group("B", function()
    local m, sg, host, lease, w = boot(function(m, ss, w)
        w.b = { store(400, 1000) }
        w.p = newSilo(m, "placeable:B", w.b)
        w.ls = LoadingStation.newModel()
        w.ls:addSourceStorage(w.b[1])
        ss:addLoadingStation(w.ls, w.p)
        w.pShop = newSilo(m, "placeable:SHOP", {})
        w.buy = LoadingStation.newModel(Buying_mt)
        ss:addLoadingStation(w.buy, w.pShop)
        w.shopper = newTrailer(m, "vehicle:shopper", WHEAT, 0)
        w.belt = newTrailer(m, "vehicle:belt", WHEAT, 0)
        w.belt.getConveyorBeltTargetObject = function() return nil end
        w.plain = newTrailer(m, "vehicle:plain", WHEAT, 0)
    end)
    T.eq("B1 [twin] the ordinary loading station is load-bracketed", SA.isLoadBracketed(w.ls), true)
    T.eq("B2 a BuyingStation-shaped station keeps its own method: no load bracket", tostring(SA.isLoadBracketed(w.buy)) .. "/" .. tostring(rawget(w.buy, "addFillLevelToFillableObject")), "false/nil")
    local before = host.nextTransfer
    load(w.buy, w.shopper)
    T.eq("B3 a purchase is a birth, not a transfer: not carried, and the per-side path reads the new stock UNKNOWN",
        tostring(host.nextTransfer - before) .. "/" .. tostring(stockAt(sg, unitId(w.shopper)) and stockAt(sg, unitId(w.shopper)).knowledge), "0/UNKNOWN")
    load(w.ls, w.belt)
    T.eq("B4 a conveyor-belt receiver is not carried (its capacity is its target's, LoadingStation.lua:207-215)", tostring(host.nextTransfer - before) .. "/" .. num(w.belt:getFillUnitFillLevel(1)), "0/100")
    load(w.ls, w.plain)
    T.eq("B5 [twin] the same station loading an ordinary trailer is carried", tostring(host.nextTransfer - before) .. "/" .. head(host.lastSettlement), "1/STATION_LOAD/COMMITTED")
    FSBaseMission.delete(m)
    T.eq("X1 mission delete removes the load bracket and restores the station's slot", tostring(SA.isLoadBracketed(w.ls)) .. "/" .. tostring(rawget(w.ls, "addFillLevelToFillableObject")) .. "/" .. tostring(NH.current), "false/nil/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. A DEV SAVE FROM BEFORE SG2-1b
-- ══════════════════════════════════════════════════════════════════════════
-- The SG2-1 adapters no longer exist, so the old save is written the only way it
-- can be now: a mission whose sgStorage and sgFillUnit adapters bind carriers in
-- exactly SG2-1's binding shape (keys without a kind prefix, descriptors without a
-- kind, adapter version 1), saved through SGSave's own XML path.
local function sg21Binding(adapterId, owner, comp, profileId, descriptor)
    local key = { adapterId = adapterId, nativeOwnerKey = owner, componentKey = comp }
    return { carrierKey = key, adapterVersion = 1, profileId = profileId, profileVersion = 1, sourceDescriptor = descriptor, quantityBasisKey = SGRecords.carrierKeyString(key) }
end

group("O", function()
    local DIR = "bench/savegame-sg21"
    local oldStore = sg21Binding("sgStorage", "placeable:OLD", "silo:0:shared:WHEAT", "NATIVE_STORAGE_SLOT_V1", { role = "silo", ordinal = 0, partition = "shared", fillTypeName = "WHEAT" })
    local oldUnit = sg21Binding("sgFillUnit", "vehicle:OLD", "fillUnit:1", "NATIVE_FILL_UNIT_V1", { fillUnitIndex = 1, configFileName = "data/vehicles/trailer.xml" })
    local m1 = newMission(DIR)
    g_server = {}
    g_currentMission = m1
    local sg1 = StockGuard.attach(m1)
    sg1:installFinishedLoadingObserver()
    sg1.save.backendId = SGSave.BACKEND_XML
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local function oldSpec(binding, amount)
        return { version = 1, carrierKinds = { binding == oldStore and "storage" or "fillUnit" },
            resolveCarrier = function(b) if b.carrierKey.componentKey == binding.carrierKey.componentKey then return { amount = amount } end return nil end,
            readNativeState = function(b, nat) return { materialRef = wheat, amount = nat.amount, unit = "LITRE" } end,
            enumerateCarriers = function() return { { binding = binding } } end,
            hasAccess = function() return true end }
    end
    m1.stockGuard.registerCarrierAdapter("sgStorage", oldSpec(oldStore, 60))
    m1.stockGuard.registerCarrierAdapter("sgFillUnit", oldSpec(oldUnit, 70))
    m1:onFinishedLoading()
    local oldIds = { stockAt(sg1, cid(oldStore)) and stockAt(sg1, cid(oldStore)).stockId, stockAt(sg1, cid(oldUnit)) and stockAt(sg1, cid(oldUnit)).stockId }
    sg1:onSaveToXML(m1.missionInfo)
    sg1:delete()
    local env1 = savedEnvelopeAt(DIR)
    local savedAdapters = {}
    for _, c in ipairs(env1 and env1.coreValues.carriers or {}) do savedAdapters[#savedAdapters + 1] = c.binding.carrierKey.adapterId end
    table.sort(savedAdapters)
    T.eq("O1 [reached] the dev save holds a storage carrier under sgStorage and a fill unit under sgFillUnit, each with a stock",
        table.concat(savedAdapters, ",") .. "/" .. tostring(oldIds[1] ~= nil and oldIds[2] ~= nil) .. "/" .. #(env1 and env1.coreValues.stocks or {}), "sgFillUnit,sgStorage/true/2")

    -- This PR's mission loads that save through main.lua, over the same world.
    local m, sg, host, lease, w = boot(function(m, ss, w)
        w.p = newSilo(m, "placeable:OLD", { store(60, 1000) })
        w.v = newTrailer(m, "vehicle:OLD", WHEAT, 70)
    end, DIR)
    local r = sg.save.loadResult
    T.eq("O2 the load completes through main.lua: host live, nothing reattached, both saved stocks kept as history, nothing refused",
        tostring(host ~= nil and host.ready) .. "/" .. tostring(r and r.state) .. "/" .. tostring(r and r.core and r.core.restored) .. "/" .. tostring(r and r.core and r.core.historical) .. "/" .. tostring(r and r.core and r.core.refused),
        "true/READY/0/2/0")
    local h1, h2 = sg.operations.retiredStocks[oldIds[1]], sg.operations.retiredStocks[oldIds[2]]
    T.eq("O3 the old stocks are history: their adapter is gone, so their carrier is absent", tostring(h1 and h1.retireReason) .. "/" .. tostring(h2 and h2.retireReason), "CARRIER_ABSENT/CARRIER_ABSENT")
    local ls_, lu = stockAt(sg, storeId(w.p, 0)), stockAt(sg, unitId(w.v))
    T.eq("O4 the live silo slot and trailer are read fresh under sgNative, with UNKNOWN history",
        num(ls_ and ls_.observedAmount) .. ":" .. tostring(ls_ and ls_.knowledge) .. "/" .. num(lu and lu.observedAmount) .. ":" .. tostring(lu and lu.knowledge) .. "/" .. tostring(sg.operations.carriers[storeId(w.p, 0)] and sg.operations.carriers[storeId(w.p, 0)].adapterId),
        "60:UNKNOWN/70:UNKNOWN/sgNative")
    T.eq("O5 neither retired id is registered", tostring(sg.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, "sgStorage")) .. "/" .. tostring(sg.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, "sgFillUnit")), "nil/nil")
    sg:onSaveToXML(m.missionInfo)
    local env2 = savedEnvelopeAt(DIR)
    local ghosts = 0
    for _, hrow in ipairs(env2 and env2.coreValues.historical or {}) do if hrow.stockId == oldIds[1] or hrow.stockId == oldIds[2] then ghosts = ghosts + 1 end end
    T.eq("O6 the next save carries them as history rows (SG-1's retention rule; the PR names them)", ghosts, 2)
    local newIds = { ls_ and ls_.stockId, lu and lu.stockId }
    FSBaseMission.delete(m)

    -- That save, made under SG2-1b, loads again over the same world.
    local m3, sg3, host3, lease3, w3 = boot(function(m, ss, w)
        w.p = newSilo(m, "placeable:OLD", { store(60, 1000) })
        w.v = newTrailer(m, "vehicle:OLD", WHEAT, 70)
    end, DIR)
    local r3 = sg3.save.loadResult
    local s3, u3 = stockAt(sg3, storeId(w3.p, 0)), stockAt(sg3, unitId(w3.v))
    T.eq("O7 a save made after SG2-1b reloads with BOTH kinds reattached, identity kept",
        tostring(r3 and r3.core and r3.core.restored) .. "/" .. tostring(s3 ~= nil and s3.stockId == newIds[1]) .. "/" .. tostring(u3 ~= nil and u3.stockId == newIds[2]),
        "2/true/true")
    FSBaseMission.delete(m3)
end)
