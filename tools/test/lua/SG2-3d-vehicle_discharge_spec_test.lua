-- SG2-3d-vehicle_discharge_spec_test.lua
--
-- SG2-3d, a vehicle overloading into another vehicle (Bob's intake: Drafts/BOB-INTAKE-
-- SG2-3d-VEHICLE-DISCHARGE-2026-09-24.md; SG-2 v2.3 :88). A combine's pipe discharging
-- into a trailer is ONE TRANSFER from the hopper's fill unit to the trailer's, settled
-- from each side's actual net change, so the cut's history follows the goods through
-- SG-1's transfer. A converting node, a cross-farm overload, the vehicle itself as the
-- target, and anything that does not bind keep today's per-side path; a trigger keeps
-- the station route.
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine models load first (SG2-2's, then the
-- harvest engine), then every module main.lua sources, then main.lua. The combine, its
-- header and the trailer are in the mission's vehicle list when the barrier runs, so the
-- host observes them the way it observes every vehicle, and the discharge capture wraps
-- the combine's INSTANCE slot of dischargeToObject. The cut runs through the engine's
-- harvest frame (SG2-3a's path); the overload runs through Dischargeable:discharge in the
-- OBJECT state, which calls dischargeToObject through self. Nothing here writes a
-- binding, a carrier, a stock or a capture.
--
-- Groups:
--   S  the entry-point bar: harvest, then overload: ONE TRANSFER hopper > trailer
--   H  history: the trailer's goods come from the stock the cut was born into, and a
--      producer's property follows them (published through the producer's own API:
--      nothing writes CUT_STATE onto a stock before SG2-4)
--   P  a nearly full trailer: only the accepted amount moves; the rest stays; no loss leg
--   F  conversions: a node factor not 1, and a type change at factor 1: per-side
--   X  a cross-farm overload: per-side (Tyson: provenance across farms is not decided)
--   V  the vehicle itself as the target (canFillOwnVehicle): per-side
--   R  a trigger target still takes the station route
--   N  a native throw: the frame closes, nothing settles twice
--   D  a delay-slot drain, then an overload: the history end to end
--   G  the log line: the first carried overload says so once; a per-side one never
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local NH, NA, DC = SGNativeHost, SGNativeAdapters, SGDischargeCapture
local WHEAT, BARLEY = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY
local FRUIT = ENGINE_FRUIT.WHEAT

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission()
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = false }, time = 1000, terrainSize = 256, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

-- ── a property producer, as a domain owner registers one (SG-1 bench shape) ───
-- Its combine records the source stock of every contribution it is handed, so a row
-- can name where the trailer's goods came from.
local PROP = "sg23d.moisture"
local SEEN = { sources = {} }
local function moisture(value, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "sg23d", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { m = value } }
end
local moistureSpec = { schemaVersion = 1, producerId = "sg23d", residency = "STORED",
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total, w = 0, 0
        for _, c in ipairs(contributions) do
            SEEN.sources[#SEEN.sources + 1] = c.sourceStockRef and tostring(c.sourceStockRef.stockId) or "nil"
            local p = c.properties[PROP]
            total = total + c.amount
            if p and p.payload then w = w + p.payload.m * c.amount end
        end
        if before then
            local p = before.properties[PROP]
            total = total + before.observedAmount
            if p and p.payload then w = w + p.payload.m * before.observedAmount end
        end
        if total == 0 then return nil, "NO_MATERIAL" end
        return moisture(w / total, total)
    end,
    transform = function() return nil end, disclosure = function(_, r) return r end }

--- Boot through main.lua's load path, the world built first; `register` registers the
--- producer between the load and the barrier, as a domain owner's own load would.
local function boot(build, register)
    ENGINE_PLANE.cells = {}
    SEEN.sources = {}
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local w = {}
    build(m, w)
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    local lease = register and m.stockGuard.registerProperty(PROP, moistureSpec) or nil
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, sg, NH.current, w, lease
end
local function vehicleIn(m, v)
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function combineIn(m, uid, opts) return vehicleIn(m, ENGINE_NEW_COMBINE(uid, opts)) end
local function headerIn(m, uid, combine, opts) return vehicleIn(m, ENGINE_NEW_HEADER(uid, combine, opts)) end
local function trailerIn(m, uid, opts) return vehicleIn(m, ENGINE_NEW_TRAILER(uid, opts)) end
--- The standard field: area 1 cuts 4 ripe pixels, area 2 four at state 3 (half yield),
--- so one frame puts 4 + 2 = 6 L in the hopper.
local function harvestWorld(m, w, combineOpts, trailerOpts)
    w.combine = combineIn(m, "vehicle:combine", combineOpts)
    w.header = headerIn(m, "vehicle:header", w.combine, { areas = 2, width = 4, depth = 1 })
    w.trailer = trailerIn(m, "vehicle:trailer", trailerOpts)
    ENGINE_PLANE.sow(FRUIT, 0, 0, 4, 1, 4)
    ENGINE_PLANE.sow(FRUIT, 4, 0, 8, 1, 3)
end
--- One server frame of an overload: the raycast's result on the node, then the discharge.
local function overload(combine, target, fillUnitIndex, liters)
    local node = ENGINE_AIM_DISCHARGE(combine, target, fillUnitIndex)
    return combine:discharge(node, liters)
end

-- ── readers ───────────────────────────────────────────────────────────────
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function unitId(v, i) return cid(NA.fillUnitBinding(v, i or 1)) end
local function stockAt(sg, id) local c = sg.operations.carriers[id] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end
local function level(v) return v:getFillUnitFillLevel(1) end
local function head(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome)
end
--- The allocations as "source>destination:amount:result".
local function legsOf(ls, names)
    local out = {}
    for _, a in ipairs(ls and ls.report and ls.report.allocations or {}) do
        local src = names[a.source.carrierId] or "?"
        local dst = a.destination.retire and "retire" or (names[a.destination.carrierId] or "?")
        out[#out + 1] = src .. ">" .. dst .. ":" .. num(a.sourceAmount) .. ":" .. tostring(a.result)
    end
    return table.concat(out, ",")
end
--- "source/destination/loss/unexplained material/requested".
local function totals(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return num(ev.sourceTotal) .. "/" .. num(ev.destinationTotal) .. "/" .. num(ev.loss) .. "/" .. num(ev.unexplainedGain) .. " " .. tostring(ev.fillTypeName) .. "/" .. num(ev.requestedAmount)
end
local function portionsOf(ls)
    local out = {}
    for _, p in ipairs(ls and ls.report and ls.report.outcomeEvidence and ls.report.outcomeEvidence.portions or {}) do
        out[#out + 1] = num(p.weight) .. ":" .. tostring(p.knowledge) .. ":" .. (p.knowledge == "KNOWN" and ("s" .. tostring(p.growthState)) or tostring(p.reason))
    end
    return table.concat(out, ",")
end
local function props(s)
    if s == nil then return "nil" end
    local p = s.properties[PROP]
    if p == nil then return tostring(s.knowledge) .. ":none" end
    return tostring(s.knowledge) .. ":" .. num(p.payload.m) .. ":" .. num(p.knownAmount)
end
local function publish(m, sg, lease, id, value)
    local s = stockAt(sg, id)
    if s == nil then return "NO_STOCK" end
    return m.stockGuard.publishProperties(lease, { { stockRef = sg.operations:stockRef(s), expectedPropertyRevision = 0, record = moisture(value, s.observedAmount) } })
end
local function genericObservations(host, ids, fn)
    local n, real = 0, host.handle.observeCarrier
    host.handle.observeCarrier = function(lease, key, ...) if ids[key] then n = n + 1 end return real(lease, key, ...) end
    local ok, err = pcall(fn)
    host.handle.observeCarrier = real
    if not ok then error(err, 0) end
    return n
end
--- A discharge that kept today's per-side path: no frame opened, no settlement, and the
--- fill-unit observers' reports reached the generic path for both carriers.
local function perSide(host, ids, fn)
    local discharges, settled = host.nextDischarge, host.lastSettlement
    local generic = genericObservations(host, ids, fn)
    return tostring(host.nextDischarge - discharges) .. "/" .. tostring(host.lastSettlement == settled) .. "/" .. tostring(generic > 0)
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg, host, w = boot(function(m, w) harvestWorld(m, w) end)
    T.ok("S1 [reached] main.lua's load path made the host live", host ~= nil and host.ready == true)
    T.eq("S2 the host observed the combine: its instance dischargeToObject carries the discharge capture", tostring(DC.isInstalled(w.combine)), "true")
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    T.eq("S3 [world] the cut is ONE BIRTH of 6 L into the hopper, its portions KNOWN by the states cut",
        head(host.lastHarvest) .. " " .. portionsOf(host.lastHarvest) .. " " .. num(level(w.combine)), "COMBINE_CUT/COMMITTED 4:KNOWN:s4,2:KNOWN:s3 6")
    local born = stockAt(sg, hop)
    local bornId = born and born.stockId
    local before = host.nextDischarge
    local out
    local generic = genericObservations(host, { [hop] = true, [tr] = true }, function() out = { overload(w.combine, w.trailer, 1, 6) } end)
    T.eq("S4 [world] the native returns are untouched: 6 L debited, the hopper empty, the trailer holding 6 L of wheat",
        num(out[1]) .. "/" .. tostring(out[2]) .. "/" .. tostring(out[3]) .. "/" .. num(level(w.combine)) .. "/" .. num(level(w.trailer)) .. ":" .. tostring(w.trailer:getFillUnitFillType(1) == WHEAT),
        "-6/true/true/0/6:true")
    local ls = host.lastSettlement
    T.eq("S5 ONE vehicle TRANSFER, committed", tostring(host.nextDischarge - before) .. "/" .. head(ls), "1/VEHICLE_DISCHARGE/COMMITTED")
    T.eq("S6 one allocation: the 6 L from the hopper into the trailer", legsOf(ls, { [hop] = "hopper", [tr] = "trailer" }), "hopper>trailer:6:TRANSFERRED")
    T.eq("S7 the totals match, nothing lost or unexplained; the evidence names the material and the request (SG-2 :90)", totals(ls), "6/6/0/0 WHEAT/6")
    local ts = stockAt(sg, tr)
    T.eq("S8 the trailer's empty unit was refreshed and captured: it holds a 6 L wheat stock born of the transfer",
        num(ts and ts.observedAmount) .. ":" .. tostring(ts and ts.materialRef.fillTypeName), "6:WHEAT")
    local retired = bornId and sg.operations.retiredStocks[bornId]
    T.eq("S9 the stock the cut was born into retired as transferred out, and the hopper holds no stock", tostring(retired and retired.retireReason) .. "/" .. tostring(stockAt(sg, hop)), "TRANSFERRED_OUT/nil")
    T.eq("S10 nothing for the generic path: both sides' observer reports were consumed", generic .. "/" .. #host.dirtyOrder, "0/0")
    T.eq("S11 the context is at rest", SGOperationContext.isAtRest(host.context), true)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. HISTORY FOLLOWS THE GOODS
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    local m, sg, host, w, lease = boot(function(m, w) harvestWorld(m, w) end, true)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    local born = stockAt(sg, hop)
    local bornId = born and born.stockId
    T.eq("H1 [world] a producer publishes a known property on the stock the cut was born into, through its own API", publish(m, sg, lease, hop, 0.14), "APPLIED")
    SEEN.sources = {}
    overload(w.combine, w.trailer, 1, 4)
    local ls = host.lastSettlement
    T.eq("H2 a partial overload: ONE TRANSFER of 4 L", head(ls) .. " " .. legsOf(ls, { [hop] = "hopper", [tr] = "trailer" }), "VEHICLE_DISCHARGE/COMMITTED hopper>trailer:4:TRANSFERRED")
    T.eq("H3 the producer was handed the cut's own stock as the source of the trailer's goods: the trailer's history is the cut's",
        table.concat(SEEN.sources, ","), tostring(bornId))
    T.eq("H4 the trailer's stock carries the property, known, over its 4 L", props(stockAt(sg, tr)), "KNOWN:0.14:4")
    local keep = stockAt(sg, hop)
    T.eq("H5 the hopper keeps its 2 L in the same stock the cut made", num(keep and keep.observedAmount) .. "/" .. tostring(keep ~= nil and keep.stockId == bornId), "2/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. A NEARLY FULL TRAILER
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local m, sg, host, w = boot(function(m, w) harvestWorld(m, w, nil, { capacity = 10, level = 6 }) end)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    local bornId = stockAt(sg, hop) and stockAt(sg, hop).stockId
    local out = overload(w.combine, w.trailer, 1, 6)
    T.eq("P1 [world] the trailer took 4 of the 6 L offered and the source was debited only by that; the hopper keeps 2",
        num(out) .. "/" .. num(level(w.trailer)) .. "/" .. num(level(w.combine)), "-4/10/2")
    local ls = host.lastSettlement
    T.eq("P2 ONE TRANSFER of the accepted 4 L and no LOSS leg: the unaccepted 2 L never left the hopper",
        head(ls) .. " " .. legsOf(ls, { [hop] = "hopper", [tr] = "trailer" }), "VEHICLE_DISCHARGE/COMMITTED hopper>trailer:4:TRANSFERRED")
    T.eq("P3 totals: 4 out, 4 in, nothing lost; the request was 6", totals(ls), "4/4/0/0 WHEAT/6")
    local hs, ts = stockAt(sg, hop), stockAt(sg, tr)
    T.eq("P4 the hopper's cut stock stays at 2 L; the trailer's stock holds 10 L", num(hs and hs.observedAmount) .. ":" .. tostring(hs ~= nil and hs.stockId == bornId) .. "/" .. num(ts and ts.observedAmount), "2:true/10")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. CONVERSIONS KEEP THE PER-SIDE PATH
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    -- A node converting wheat at factor 0.5 (Dischargeable.lua:862-873): the trailer is
    -- credited 3 L for 6 L out (:811-813).
    local m, sg, host, w = boot(function(m, w)
        harvestWorld(m, w, { converter = { [WHEAT] = { targetFillTypeIndex = WHEAT, conversionFactor = 0.5 } } })
    end)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    T.eq("F1 a node factor of 0.5 is a conversion: no frame, no settlement, both sides through the generic path",
        perSide(host, { [hop] = true, [tr] = true }, function() overload(w.combine, w.trailer, 1, 6) end), "0/true/true")
    T.eq("F1b [world] the native conversion ran as native does: 6 L out, 3 L in", num(level(w.combine)) .. "/" .. num(level(w.trailer)), "0/3")
    FSBaseMission.delete(m)
    -- A converter entry changing the type at factor 1 (FillTypeManager.lua:492-498).
    m, sg, host, w = boot(function(m, w)
        harvestWorld(m, w, { converter = { [WHEAT] = { targetFillTypeIndex = BARLEY, conversionFactor = 1 } } }, { supported = { [WHEAT] = true, [BARLEY] = true } })
    end)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    hop, tr = unitId(w.combine), unitId(w.trailer)
    T.eq("F2 a type change at factor 1 is a conversion too: per-side, never a wheat history on barley",
        perSide(host, { [hop] = true, [tr] = true }, function() overload(w.combine, w.trailer, 1, 6) end), "0/true/true")
    T.eq("F2b [world] 6 L of wheat out, 6 L of barley in", num(level(w.combine)) .. "/" .. num(level(w.trailer)) .. ":" .. tostring(w.trailer:getFillUnitFillType(1) == BARLEY), "0/6:true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. A CROSS-FARM OVERLOAD KEEPS THE PER-SIDE PATH
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local m, sg, host, w = boot(function(m, w) harvestWorld(m, w, nil, { ownerFarmId = 2 }) end)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    T.eq("X1 a farm-1 combine into a farm-2 trailer: no frame, no settlement, both sides through the generic path",
        perSide(host, { [hop] = true, [tr] = true }, function() overload(w.combine, w.trailer, 1, 6) end), "0/true/true")
    T.eq("X2 [world] the native overload ran as native does", num(level(w.combine)) .. "/" .. num(level(w.trailer)), "0/6")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE VEHICLE ITSELF AS THE TARGET
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    -- canFillOwnVehicle (Dischargeable.lua:569, :1063-1065): a node filling another unit
    -- of its own vehicle, here the combine's buffer unit (2).
    local m, sg, host, w = boot(function(m, w) harvestWorld(m, w, { buffer = true, bufferCapacity = 100, hopperLevel = 10 }) end)
    local hop, buf = unitId(w.combine, 1), unitId(w.combine, 2)
    local before = level(w.combine)
    T.eq("V1 the combine as its own target is not carried: no frame, no settlement",
        perSide(host, { [hop] = true, [buf] = true }, function() overload(w.combine, w.combine, 2, 2) end):sub(1, 6), "0/true")
    T.eq("V1b [world] the native moved the 2 L into the buffer unit", num(before - level(w.combine)) .. "/" .. num(w.combine:getFillUnitFillLevel(2)), "2/2")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. A TRIGGER TARGET STILL TAKES THE STATION ROUTE
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local m, sg, host, w = boot(function(m, w)
        harvestWorld(m, w)
        w.store = Storage.newModel({ [WHEAT] = 0 }, 1000, 1)
        w.p = { uniqueId = "placeable:silo", getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                spec_silo = { storages = { w.store }, storagePerFarm = false } }
        m._placeables[#m._placeables + 1] = w.p
        m.storageSystem:addStorage(w.store)
        w.us = UnloadingStation.newModel()
        w.us:addTargetStorage(w.store)
        m.storageSystem:addUnloadingStation(w.us, w.p)
    end)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local before = host.nextDischarge
    overload(w.combine, UnloadTrigger.newModel(w.us), 1, 6)
    T.eq("R1 the combine unloading into a silo's trigger is ONE station TRANSFER, as SG2-2 carries it",
        tostring(host.nextDischarge - before) .. "/" .. head(host.lastSettlement), "1/STATION_UNLOAD/COMMITTED")
    T.eq("R1b [world] the store took the 6 L", num(w.store:getFillLevel(WHEAT)) .. "/" .. num(level(w.combine)), "6/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. A NATIVE THROW
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local m, sg, host, w = boot(function(m, w) harvestWorld(m, w) end)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    local bornId = stockAt(sg, hop) and stockAt(sg, hop).stockId
    -- The trailer's fill unit raises once, inside the native credit.
    local real = w.trailer.addFillUnitFillLevel
    w.trailer.addFillUnitFillLevel = function() error("credit boom") end
    local ok, err = pcall(overload, w.combine, w.trailer, 1, 6)
    w.trailer.addFillUnitFillLevel = real
    T.eq("N1 [world] the native error reaches the caller unchanged; nothing moved", tostring(ok) .. "/" .. tostring(tostring(err):find("credit boom", 1, true) ~= nil) .. "/" .. num(level(w.combine)) .. "/" .. num(level(w.trailer)), "false/true/6/0")
    T.eq("N2 the frame closed and the capture was abandoned for the native error, not settled", head(host.lastSettlement) .. "/" .. tostring(host.lastSettlement and host.lastSettlement.reason) .. "/" .. tostring(SGOperationContext.isAtRest(host.context)),
        "nil/ABANDONED/NATIVE_ERROR/true")
    local hs = stockAt(sg, hop)
    T.eq("N3 the hopper keeps the cut's 6 L stock; the trailer holds none", num(hs and hs.observedAmount) .. ":" .. tostring(hs ~= nil and hs.stockId == bornId) .. "/" .. tostring(stockAt(sg, tr)), "6:true/nil")
    local before = host.nextDischarge
    overload(w.combine, w.trailer, 1, 6)
    T.eq("N4 the next overload is ONE TRANSFER of its own 6 L: nothing from the thrown one settles again",
        tostring(host.nextDischarge - before) .. "/" .. head(host.lastSettlement) .. "/" .. legsOf(host.lastSettlement, { [hop] = "hopper", [tr] = "trailer" }), "1/VEHICLE_DISCHARGE/COMMITTED/hopper>trailer:6:TRANSFERRED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A DELAY-SLOT DRAIN, THEN AN OVERLOAD: THE HISTORY END TO END
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local m, sg, host, w, lease = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", { loadingDelay = 100 })
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, { areas = 1, width = 6, depth = 1 })
        w.trailer = trailerIn(m, "vehicle:delayTrailer")
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, true)
    local hop, tr = unitId(w.combine), unitId(w.trailer)
    local slot1 = cid(NA.combineSlotBinding(w.combine, NA.KIND_DELAY_SLOT, 1))
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local slotStock = stockAt(sg, slot1)
    local slotStockId = slotStock and slotStock.stockId
    T.eq("D1 [world] the cut is born into the delay slot, and a producer marks that stock", head(host.lastHarvest) .. "/" .. num(slotStock and slotStock.observedAmount) .. "/" .. publish(m, sg, lease, slot1, 0.2),
        "COMBINE_CUT/COMMITTED/6/APPLIED")
    SEEN.sources = {}
    ENGINE_HARVEST_TICK(nil, w.combine, 200)
    local hs = stockAt(sg, hop)
    T.eq("D2 the due slot drains into the hopper as ONE TRANSFER, from the slot's stock", head(host.lastDrain) .. "/" .. table.concat(SEEN.sources, ",") .. "/" .. num(hs and hs.observedAmount),
        "COMBINE_DRAIN/COMMITTED/" .. tostring(slotStockId) .. "/6")
    local hopStockId = hs and hs.stockId
    SEEN.sources = {}
    overload(w.combine, w.trailer, 1, 6)
    T.eq("D3 the overload is ONE TRANSFER from the hopper's stock, the one the drain made", head(host.lastSettlement) .. "/" .. table.concat(SEEN.sources, ","),
        "VEHICLE_DISCHARGE/COMMITTED/" .. tostring(hopStockId))
    T.eq("D4 the slot's property reached the trailer, known, over its 6 L: cut, drain, overload", props(stockAt(sg, tr)), "KNOWN:0.2:6")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE LOG LINE
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    local lines = {}
    local realPrint = print
    print = function(s) lines[#lines + 1] = tostring(s) realPrint(s) end
    local ok, err = pcall(function()
        NH.logged = {}
        -- A per-side overload first (another farm's trailer): no line.
        local m, sg, host, w = boot(function(m, w) harvestWorld(m, w, nil, { ownerFarmId = 2 }) end)
        ENGINE_HARVEST_TICK(w.header, w.combine, 16)
        overload(w.combine, w.trailer, 1, 6)
        FSBaseMission.delete(m)
        -- Then two carried overloads: one line, the first's.
        m, sg, host, w = boot(function(m, w) harvestWorld(m, w) end)
        ENGINE_HARVEST_TICK(w.header, w.combine, 16)
        overload(w.combine, w.trailer, 1, 4)
        overload(w.combine, w.trailer, 1, 2)
        FSBaseMission.delete(m)
    end)
    print = realPrint
    if not ok then error(err, 0) end
    local carried = {}
    for _, l in ipairs(lines) do
        if l:find("FIRST VEHICLE OVERLOAD CARRIED", 1, true) then carried[#carried + 1] = l end
    end
    T.eq("G1 one line for the first carried overload, none for the per-side one or the second carried one",
        tostring(#carried) .. " " .. tostring(carried[1]),
        "1 [StockGuard] native: FIRST VEHICLE OVERLOAD CARRIED: 4.0 L of WHEAT from data/vehicles/combine.xml into data/vehicles/trailer.xml as one transfer.")
end)
