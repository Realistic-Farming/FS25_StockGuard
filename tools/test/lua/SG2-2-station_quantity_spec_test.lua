-- SG2-2-station_quantity_spec_test.lua
--
-- SG2-2 stage (a): the RSF-F207 station quantity correction, and the host binding
-- that puts it on admitted stations.
--
-- THE ENTRY-POINT BAR IS GROUP E. It enters where production enters: the engine
-- model (SG2-2-engine_model.lua) is loaded FIRST, so the adapter's file-scope
-- baseline is captured from the engine classes exactly as at mod source time; then
-- every module main.lua sources, then main.lua itself. The mission is loaded through
-- main's own Mission00.load and Mission00.loadMission00Finished appends, so the class
-- hooks and the host (with main's OWN sources, including the storage system) come
-- from main.lua and not from this file. Stations enter through the engine's
-- StorageSystem:addLoadingStation / addUnloadingStation, material through the
-- engine's UnloadTrigger:addFillUnitFillLevel and LoadTrigger's fill line, teardown
-- through main's FSBaseMission.delete. Nothing here writes a baseline, a binding, a
-- wrapper or a host source by hand.
--
-- Groups:
--   U  the reference assertions (RSF-F207 reference bar), pointed at the REAL
--      adapter factories, with the ENGINE's own loops as the legacy twins
--   F  failed native operations: stop, keep the observed state, report
--   I  recognition and teardown by exact function identity
--   E  the entry-point bar (above)
--   T  a later foreign CLASS wrap (TransportCompany's shape) in a second mission
--
-- Every group runs inside group(), so a Lua error fails a named row instead of the
-- runner discarding the file. Every refusal has a twin proving the fixture reaches
-- the branch.
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local SA, NH = SGStationAdapter, SGNativeHost
local WHEAT, BARLEY, GRASS = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY, ENGINE_FT.GRASS

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The two NATIVE loops, taken from the engine model before anything wraps them.
local legacyLoad = LoadingStation.removeFillLevel
local legacyUnload = UnloadingStation.addFillLevelFromTool

-- ══════════════════════════════════════════════════════════════════════════
-- Reference-style stores and stations (the RSF-F207 reference bar's shapes)
-- ══════════════════════════════════════════════════════════════════════════
local TYPE, TOOL = 17, 3
local function store(q, cap, maxChange)
    return {
        q = q, capacity = cap, maxChange = maxChange, writes = 0,
        getFillLevel = function(self, t) assert(t == TYPE) return self.q end,
        getFreeCapacity = function(self, t) assert(t == TYPE) return self.capacity - self.q end,
        setFillLevel = function(self, q2, t, info)
            assert(t == TYPE)
            local desired = math.max(0, math.min(self.capacity, q2))
            if self.maxChange then
                desired = self.q + math.max(-self.maxChange, math.min(self.maxChange, desired - self.q))
            end
            self.q = desired
            self.writes = self.writes + 1
            self.info = info
        end,
    }
end
local function total(stores) local n = 0 for _, v in ipairs(stores) do n = n + v.q end return n end
local failures = {}
local function onFail(station, kind, reason) failures[#failures + 1] = { station = station, kind = kind, reason = reason } end
-- The station's store lists are KEYED BY STORE and filled in order, as the engine's
-- addSourceStorage / addTargetStorage fill them. Not a constructor array: fengari's
-- pairs walks a constructor array {a, b} as b, a, which silently swapped every
-- "first store" in this group's first run.
local function ordered(stores) local t = {} for _, s in ipairs(stores) do t[s] = s end return t end
local function station(stores, access)
    return {
        list = stores, sourceStorages = ordered(stores), targetStorages = ordered(stores), fx = 0, planes = 0,
        hasFarmAccessToStorage = access or function() return true end,
        getIsFillTypeAllowed = function(self, t) return t == TYPE and not self.denyType end,
        getIsToolTypeAllowed = function(self, t) return t == TOOL and not self.denyTool end,
        startFx = function(self, t) self.fx = self.fx + 1 end,
        activateSimpleFillplanes = function(self, t) self.planes = self.planes + 1 end,
        removeFillLevel = SA.makeRemoveFillLevel(onFail),
        addFillLevelFromTool = SA.makeAddFillLevelFromTool(onFail),
    }
end

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE REFERENCE ASSERTIONS AGAINST THE REAL ADAPTER
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    g_server = {}
    for _, firstSmall in ipairs({ true, false }) do
        local x, y = firstSmall and 50 or 200, firstSmall and 200 or 50
        local label = firstSmall and "small-first" or "large-first"
        local ss = { store(x, 250), store(y, 250) }
        local before = total(ss)
        local st = station(ss)
        local rem = legacyLoad(st, TYPE, 100, 1)
        T.eq("U1 [" .. label .. "] engine load twin: actual source movement", before - total(ss), firstSmall and 150 or 100)
        T.eq("U2 [" .. label .. "] engine load twin: returned remainder", rem, 0)
        ss = { store(x, 250), store(y, 250) }
        before = total(ss)
        rem = station(ss):removeFillLevel(TYPE, 100, 1)
        T.eq("U3 [" .. label .. "] repaired load moves the request", before - total(ss), 100)
        T.eq("U4 [" .. label .. "] repaired load: nothing unserved", rem, 0)
        ss = { store(0, x), store(0, y) }
        local moved = legacyUnload(station(ss), 1, 100, TYPE, "info", TOOL)
        T.eq("U5 [" .. label .. "] engine unload twin: actual increase", total(ss), firstSmall and 150 or 100)
        T.eq("U6 [" .. label .. "] engine unload twin: acknowledgement", moved, 100)
        ss = { store(0, x), store(0, y) }
        st = station(ss)
        moved = st:addFillLevelFromTool(1, 100, TYPE, "info", TOOL)
        T.eq("U7 [" .. label .. "] repaired unload: actual increase", total(ss), 100)
        T.eq("U8 [" .. label .. "] repaired unload: acknowledgement", moved, 100)
        T.eq("U9 [" .. label .. "] repaired unload: effects once", st.fx, 1)
        T.eq("U10 [" .. label .. "] repaired unload: fill planes retained", st.planes, 1)
    end
    local st = station({ store(50, 100) })
    T.eq("U11 short load returns the unmet demand", st:removeFillLevel(TYPE, 100, 1), 50)
    st = station({ store(0, 50) })
    T.eq("U12 short unload returns the acceptance", st:addFillLevelFromTool(1, 100, TYPE, nil, TOOL), 50)
    local denied, allowed = store(50, 100), store(50, 100)
    denied.denied = true
    st = station({ denied, allowed }, function(self, farm, v) return not v.denied end)
    T.eq("U13 a denied source is skipped", st:removeFillLevel(TYPE, 40, 1), 0)
    T.eq("U14 the denied source is unchanged", denied.q, 50)
    T.eq("U15 the later eligible source serves it", allowed.q, 10)
    st = station({ store(0, 100) }, function() return false end)
    T.eq("U16 a denied unload accepts zero", st:addFillLevelFromTool(1, 50, TYPE, nil, TOOL), 0)
    T.eq("U17 and writes nothing", st.list[1].writes, 0)
    st = station({ store(0, 100) })
    T.eq("U18 an empty source leaves the load unserved", st:removeFillLevel(TYPE, 10, 1), 10)
    st = station({ store(100, 100) })
    T.eq("U19 a full target accepts zero", st:addFillLevelFromTool(1, 10, TYPE, nil, TOOL), 0)
    T.eq("U20 a zero load", st:removeFillLevel(TYPE, 0, 1), 0)
    T.eq("U21 a zero unload", st:addFillLevelFromTool(1, 0, TYPE, nil, TOOL), 0)
    T.eq("U22 zero requests call no setter", st.list[1].writes, 0)
    st = station({ store(0, 100) })
    st.denyType = true
    T.eq("U23 a type refusal comes before any write", st:addFillLevelFromTool(1, 10, TYPE, nil, TOOL), 0)
    st.denyType, st.denyTool = false, true
    T.eq("U24 a tool refusal comes before any write", st:addFillLevelFromTool(1, 10, TYPE, nil, TOOL), 0)
    T.eq("U25 admission refusals write nothing", st.list[1].writes, 0)
    st.denyTool = false
    T.eq("U25b [reached] twin: admitted, the same station accepts", st:addFillLevelFromTool(1, 10, TYPE, nil, TOOL), 10)
    st = station({ store(1, 1) })
    T.near("U26 a real small load remainder survives (no 0.0001 cutoff)", st:removeFillLevel(TYPE, 1.00005, 1), 0.00005, 1e-12)
    T.eq("U26b [reached] twin: the engine loop zeroes it", legacyLoad(station({ store(1, 1) }), TYPE, 1.00005, 1), 0)
    st = station({ store(0, 1) })
    T.eq("U27 a real small unload shortfall is not acknowledged as the request", st:addFillLevelFromTool(1, 1.0005, TYPE, nil, TOOL), 1)
    T.eq("U27b [reached] twin: the engine loop acknowledges the request", legacyUnload(station({ store(0, 1) }), 1, 1.0005, TYPE, nil, TOOL), 1.0005)
    st = station({ store(10, 100, 7), store(10, 100) })
    T.eq("U28 a short setter's remainder goes to the next source", st:removeFillLevel(TYPE, 10, 1), 0)
    T.eq("U29 the short source is observed, not assumed", st.list[1].q, 3)
    T.eq("U30 the next source serves the true remainder", st.list[2].q, 7)
    st = station({ store(0, 10, 7), store(0, 10) })
    T.eq("U31 a short destination setter: the actual total", st:addFillLevelFromTool(1, 10, TYPE, "marker", TOOL), 10)
    T.eq("U32 the short destination's actual amount", st.list[1].q, 7)
    T.eq("U33 the next destination takes the true remainder", st.list[2].q, 3)
    T.eq("U34 fill info is forwarded", st.list[2].info, "marker")
    -- The sliver within the effects threshold is still offered to the next store.
    st = station({ store(0, 99.9995), store(0, 10) })
    local acc = st:addFillLevelFromTool(1, 100, TYPE, nil, TOOL)
    T.near("U35 a total within 0.001 does not stop the walk: the next store takes the sliver", st.list[2].q, 0.0005, 1e-9)
    T.eq("U36 and the acceptance is exactly the actual increase", acc, total(st.list))
    T.eq("U37 the effects still fire once", st.fx, 1)
    local legacySt = station({ store(0, 99.9995), store(0, 10) })
    T.eq("U37b [reached] twin: the engine loop stops at the threshold and reports the request", tostring(legacyUnload(legacySt, 1, 100, TYPE, nil, TOOL)) .. "/" .. tostring(legacySt.list[2].q), "100/0")
    -- Each station's OWN access method is dispatched, its native third argument kept.
    local seen = {}
    local accessHandler = { canFarmAccess = function(self, farm, v, allowEqualAlways) seen[#seen + 1] = { farm = farm, flag = allowEqualAlways } return true end }
    station({ store(10, 20) }, function(self, farm, v) return accessHandler:canFarmAccess(farm, v) end):removeFillLevel(TYPE, 1, 2)
    station({ store(0, 20) }, function(self, farm, v) return accessHandler:canFarmAccess(farm, v, true) end):addFillLevelFromTool(2, 1, TYPE, nil, TOOL)
    T.eq("U38 loading keeps the absent third access argument", seen[1].flag, nil)
    T.eq("U39 unloading keeps its true third access argument", seen[2].flag, true)
    T.eq("U40 the passed actor farm reaches access", seen[2].farm, 2)
    st = station({ store(10, 20) }, function(self, farm, v) return farm == 1 end)
    T.eq("U41 a narrower custom access refuses the contractor", st:removeFillLevel(TYPE, 2, 2), 2)
    T.eq("U42 and serves the owner", st:removeFillLevel(TYPE, 2, 1), 0)
    T.eq("U43 no failure was reported by any ordinary case", #failures, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. FAILED NATIVE OPERATIONS
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    g_server = {}
    failures = {}
    local bad, next1 = store(10, 100), store(10, 100)
    bad.getFillLevel = function() return 0 / 0 end
    local st = station({ bad, next1 })
    T.eq("F1 a non-finite source level stops the load with the demand unserved", st:removeFillLevel(TYPE, 10, 1), 10)
    T.eq("F2 and is reported as a failed operation", failures[1] and failures[1].reason, "INVALID_SOURCE_LEVEL")
    T.eq("F3 no later source is touched (no retry of the full request)", next1.q, 10)
    local over, next2 = store(30, 100), store(30, 100)
    over.setFillLevel = function(self, q2) self.q = math.max(0, self.q - 2 * (self.q - q2)) self.writes = self.writes + 1 end
    st = station({ over, next2 })
    failures = {}
    local rem = st:removeFillLevel(TYPE, 10, 1)
    T.eq("F4 a source setter writing past its bound: the observed state is kept", over.q, 10)
    T.eq("F5 served counts only what was asked of that store; the rest is unserved", rem, 0)
    T.eq("F6 reported as a mutation outside the bound", failures[1] and failures[1].reason, "MUTATION_OUTSIDE_BOUND")
    T.eq("F7 and nothing else is debited", next2.q, 30)
    local tgt, next3 = store(0, 100), store(0, 100)
    tgt.getFreeCapacity = function() return 0 / 0 end
    st = station({ tgt, next3 })
    failures = {}
    T.eq("F8 a non-finite free capacity stops the unload with nothing accepted", st:addFillLevelFromTool(1, 10, TYPE, nil, TOOL), 0)
    T.eq("F9 reported, and nothing written anywhere", tostring(failures[1] and failures[1].reason) .. "/" .. (tgt.writes + next3.writes), "INVALID_TARGET_CAPACITY/0")
    local over2, next4 = store(0, 100), store(0, 100)
    over2.setFillLevel = function(self, q2) self.q = self.q + 2 * (q2 - self.q) self.writes = self.writes + 1 end
    st = station({ over2, next4 })
    failures = {}
    local acc = st:addFillLevelFromTool(1, 10, TYPE, nil, TOOL)
    T.eq("F10 a target setter writing past its bound: the observed state is kept", over2.q, 20)
    T.eq("F11 accepted from the tool is at most what was offered", acc, 10)
    T.eq("F12 reported, and the next target is not topped up", tostring(failures[1] and failures[1].reason) .. "/" .. next4.q, "MUTATION_OUTSIDE_BOUND/0")
    failures = {}
    local neg = store(10, 100)
    st = station({ neg })
    T.eq("F13 a negative load request is refused and returned unserved", st:removeFillLevel(TYPE, -5, 1), -5)
    T.eq("F14 reported, and no source written", tostring(failures[1] and failures[1].reason) .. "/" .. neg.writes, "INVALID_REQUEST/0")
    local raising = station({ store(0, 100) })
    raising.removeFillLevel = SA.makeRemoveFillLevel(function() error("observer boom") end)
    local okCall, value = pcall(raising.removeFillLevel, raising, TYPE, -1, 1)
    T.eq("F15 a raising failure observer does not raise out of the operation", tostring(okCall) .. "/" .. tostring(value), "true/-1")
    -- A setter driving a SMALL source negative: the one shape where the asked amount
    -- (the whole source) is less than the remaining demand, so capping the credit at
    -- the ask and at the remainder differ.
    local sink, after = store(30, 100), store(30, 100)
    sink.setFillLevel = function(self, q2) self.q = q2 - 10 self.writes = self.writes + 1 end
    st = station({ sink, after })
    failures = {}
    T.eq("F16 a source written below zero serves only the 30 asked of it: 20 of 50 unserved", st:removeFillLevel(TYPE, 50, 1), 20)
    T.eq("F17 reported, the negative level kept, the next source untouched", tostring(failures[1] and failures[1].reason) .. "/" .. sink.q .. "/" .. after.q, "MUTATION_OUTSIDE_BOUND/-10/30")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- I. RECOGNITION AND TEARDOWN BY EXACT FUNCTION IDENTITY
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    g_server = {}
    T.eq("I1 the load baseline is the engine's method, captured at file scope", SA.nativeLoadQuantity, legacyLoad)
    T.eq("I2 the unload baseline likewise", SA.nativeUnloadQuantity, legacyUnload)
    local function plain(kind)
        local s = { sourceStorages = { store(10, 20) }, targetStorages = {}, hasFarmAccessToStorage = function() return true end }
        return setmetatable(s, { __index = kind == SA.LOAD and LoadingStation or UnloadingStation })
    end
    local st = plain(SA.LOAD)
    T.eq("I3 an inherited native method is admitted", tostring((SA.install(st, SA.LOAD))), "true")
    local wrapper = st.removeFillLevel
    local ok2, why2 = SA.install(st, SA.LOAD)
    T.eq("I4 a second install is a no-op", tostring(ok2) .. "/" .. tostring(why2) .. "/" .. tostring(st.removeFillLevel == wrapper), "true/ALREADY/true")
    T.eq("I5 the repaired method runs", st:removeFillLevel(TYPE, 2, 1), 0)
    T.ok("I6 the owned wrapper is removed", (SA.uninstall(st, SA.LOAD)))
    T.eq("I7 the inherited raw slot is restored to nil", rawget(st, "removeFillLevel"), nil)
    T.eq("I8 native inheritance is restored", st.removeFillLevel, legacyLoad)
    local custom = function() return 9 end
    st.removeFillLevel = custom
    local okC, whyC = SA.install(st, SA.LOAD)
    T.eq("I9 a custom quantity method is refused", tostring(okC) .. "/" .. tostring(whyC), "false/NOT_NATIVE")
    T.eq("I10 and left untouched", st.removeFillLevel, custom)
    st.removeFillLevel = nil
    SA.install(st, SA.LOAD)
    st.removeFillLevel = custom
    local okU, whyU = SA.uninstall(st, SA.LOAD)
    T.eq("I11 a later replacement is not uninstalled", tostring(okU) .. "/" .. tostring(whyU), "false/REPLACED_BY_ANOTHER")
    T.eq("I12 and the later replacement is preserved", st.removeFillLevel, custom)
    st = plain(SA.LOAD)
    st.removeFillLevel = legacyLoad
    SA.install(st, SA.LOAD)
    T.ok("I13 [reached] a raw native slot is admitted and replaced", rawget(st, "removeFillLevel") ~= legacyLoad)
    SA.uninstall(st, SA.LOAD)
    T.eq("I14 the old raw native slot is restored as raw", rawget(st, "removeFillLevel"), legacyLoad)
    local sell = SellingStation.newModel()
    local okS, whyS = SA.install(sell, SA.UNLOAD)
    T.eq("I15 a SellingStation's own quantity method is not admitted", tostring(okS) .. "/" .. tostring(whyS), "false/NOT_NATIVE")
    local us = plain(SA.UNLOAD)
    T.eq("I16 [reached] twin: a plain UnloadingStation is admitted", tostring((SA.install(us, SA.UNLOAD))), "true")
    T.eq("I17 one kind's admission leaves the other kind alone", tostring(SA.isAdmitted(us, SA.UNLOAD)) .. "/" .. tostring(SA.isAdmitted(us, SA.LOAD)), "true/false")
    g_server = nil
    local okCl, whyCl = SA.install(plain(SA.LOAD), SA.LOAD)
    g_server = {}
    T.eq("I18 a client admits nothing", tostring(okCl) .. "/" .. tostring(whyCl), "false/CLIENT")
    T.eq("I19 an unknown kind is refused", select(2, SA.install(plain(SA.LOAD), "BOTH")), "KIND")
    local sale = SellingStation.newModel()
    g_server = nil
    local okSC, whySC = SA.installSaleBracket(sale, {})
    g_server = {}
    T.eq("I20 a client installs no sale bracket", tostring(okSC) .. "/" .. tostring(whySC) .. "/" .. tostring(rawget(sale, "sellFillType")), "false/CLIENT/nil")
    T.eq("I21 [reached] twin: the server installs it", tostring((SA.installSaleBracket(sale, {}))), "true")
    local okS2, whyS2 = SA.installSaleBracket(sale, {})
    T.eq("I22 a second sale bracket install is a no-op", tostring(okS2) .. "/" .. tostring(whyS2), "true/ALREADY")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- The world for E and T: a mission, silos, vehicles (the SG2-1 benches' shapes)
-- ══════════════════════════════════════════════════════════════════════════
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission()
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = false },
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessCalls = {}
    m.accessHandler = { canFarmAccess = function(_, farmId, object, allowEqual)
        m.accessCalls[#m.accessCalls + 1] = { farmId = farmId, object = object, allowEqual = allowEqual }
        return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId
    end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

local function newSilo(uid, storages)
    return { uniqueId = uid, getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
             spec_silo = { storages = storages, storagePerFarm = false } }
end

--- A silo placeable and its two stations over the same stores, as PlaceableSilo
--- builds them. Stores hold WHEAT at `levels` with capacity `caps`.
local function siloStations(m, uid, levels, caps, owners)
    local stores = {}
    for i, level in ipairs(levels) do
        stores[i] = Storage.newModel({ [WHEAT] = level, [BARLEY] = 0, [GRASS] = 0 }, caps[i], owners and owners[i] or 1)
    end
    local placeable = newSilo(uid, stores)
    m._placeables[#m._placeables + 1] = placeable
    local ls, us = LoadingStation.newModel(), UnloadingStation.newModel()
    for _, s in ipairs(stores) do
        ls:addSourceStorage(s)
        us:addTargetStorage(s)
        m.storageSystem:addStorage(s)
    end
    return placeable, ls, us, stores
end

local function level(stores, i) return stores[i]:getFillLevel(WHEAT) end
local function sum(stores) local n = 0 for _, s in ipairs(stores) do n = n + s:getFillLevel(WHEAT) end return n end

local function newVehicle(m, uid)
    local v = { uniqueId = uid, configFileName = "data/vehicles/trailer.xml", ownerFarmId = 1, activeFarm = 1,
                spec_fillUnit = { fillUnits = { { fillLevel = 0, capacity = 5000, fillType = FillType.UNKNOWN } } } }
    v.isa = function(self, class) return class == Vehicle end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
    v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
    v.getFillUnitCapacity = function(self, i) return self.spec_fillUnit.fillUnits[i].capacity end
    v.getFillUnitFreeCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u.capacity - u.fillLevel end
    v.addFillUnitFillLevel = function(self, farmId, i, delta, ft)
        local u = self.spec_fillUnit.fillUnits[i]
        if u == nil then return 0 end
        local before = u.fillLevel
        u.fillLevel = math.max(0, math.min(u.fillLevel + delta, u.capacity))
        if u.fillLevel > 0 then u.fillType = ft end
        return u.fillLevel - before
    end
    v.setFillUnitFillType = function(self, i, ft) self.spec_fillUnit.fillUnits[i].fillType = ft end
    v.emptyAllFillUnits = function(self) for _, u in ipairs(self.spec_fillUnit.fillUnits) do u.fillLevel = 0 u.fillType = FillType.UNKNOWN end end
    m._vehicles[#m._vehicles + 1] = v
    return v
end

local function unloadInto(target, amount, fillType, conversions)
    return UnloadTrigger.newModel(target, conversions):addFillUnitFillLevel(1, 1, amount, fillType or WHEAT, ToolType.DISCHARGEABLE, nil, nil)
end
local function loadOut(source, vehicle, amount)
    return LoadTrigger.fillStep({ source = source, currentFillableObject = vehicle, fillUnitIndex = 1, selectedFillType = WHEAT, dischargeInfo = nil }, amount)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
local E = {}
group("E", function()
    -- What main.lua sourced is what this bench loaded, in the same order.
    local declared = {}
    for _, d in ipairs({ "src/capacity/SGSha256.lua", "src/capacity/SGCanonicalProfile.lua", "src/capacity/SGWireFormats.lua", "src/capacity/SGCapacity.lua", "src/core/SGValues.lua", "src/core/SGRecords.lua", "src/core/SGRegistry.lua", "src/core/SGOperations.lua", "src/core/SGFarmRestore.lua", "src/core/SGSave.lua", "src/core/SGSiteBinding.lua", "src/core/SGViews.lua", "src/core/SGCommands.lua", "src/core/SGTransport.lua", "src/StockGuard.lua", "src/native/SGOperationContext.lua", "src/native/SGWorkAreaInstaller.lua", "src/native/SGStorageBracket.lua", "src/native/SGFillUnitObserver.lua", "src/native/SGNativeAdapters.lua", "src/native/SGStationAdapter.lua", "src/native/SGDischargeCapture.lua", "src/native/SGNativeSale.lua", "src/native/SGNativeHost.lua", "src/placeables/ChemicalStationRoles.lua", "src/placeables/ChemicalStationAddress.lua", "src/placeables/ChemicalStationWipRoute.lua", "src/placeables/ChemicalStationSaleGate.lua" }) do
        declared[#declared + 1] = g_currentModDirectory .. d
    end
    T.eq("E0 main.lua sourced exactly this bench's modules, in order", table.concat(ENGINE_SOURCED, ","), table.concat(declared, ","))

    local m = newMission()
    E.m = m
    g_server = {}
    g_currentMission = m
    local ss = m.storageSystem

    -- The map registers its stations before the kernel exists.
    local pA, lsA, _, sA = siloStations(m, "placeable:A", { 50, 200 }, { 1000, 1000 })
    ss:addLoadingStation(lsA, pA)
    local pU, _, usU, sU = siloStations(m, "placeable:U", { 0, 0 }, { 50, 200 })
    ss:addUnloadingStation(usU, pU)
    local pTW, lsTW, usTW, sTW = siloStations(m, "placeable:TW", { 50, 200 }, { 1000, 1000 })
    ss:addLoadingStation(lsTW, pTW)
    local pTU, _, usTU, sTU = siloStations(m, "placeable:TU", { 0, 0 }, { 50, 200 })
    ss:addUnloadingStation(usTU, pTU)
    local sell = SellingStation.newModel()
    ss:addUnloadingStation(sell, pA)
    local foreignCalls = 0
    local pF, _, usForeign = siloStations(m, "placeable:F", { 0 }, { 500 })
    usForeign.addFillLevelFromTool = function(self, ...) foreignCalls = foreignCalls + 1 return legacyUnload(self, ...) end
    local foreignFn = usForeign.addFillLevelFromTool
    ss:addUnloadingStation(usForeign, pF)
    local pR, _, usRaw = siloStations(m, "placeable:R", { 0 }, { 500 })
    usRaw.addFillLevelFromTool = legacyUnload   -- a raw instance slot holding the native method
    ss:addUnloadingStation(usRaw, pR)
    local pN, _, usNoPlace = siloStations(m, "placeable:N", { 0 }, { 500 })
    T.eq("E1 [world] the engine refuses a station registered with no placeable ...", ss:addUnloadingStation(usNoPlace), false)
    T.eq("E1b [world] ... and has already put it in its table", ss.unloadingStations[usNoPlace], usNoPlace)

    local veh = newVehicle(m, "vehicle:load")

    -- The mission loads through main.lua.
    Mission00.load(m)
    T.ok("E2 [reached] main.lua's Mission00.load append published the handle", m.stockGuard ~= nil)
    Mission00.loadMission00Finished(m)
    local host = NH.current
    E.host = host
    T.ok("E3 [reached] main.lua's loadMission00Finished append installed the host", host ~= nil and host.handle == m.stockGuard)
    T.eq("E4 the host reads the mission's storage system through main's own source", host.sources.storageSystem and host.sources.storageSystem(), ss)
    T.eq("E5 nothing is admitted before the restore barrier", tostring(SA.isAdmitted(lsA, SA.LOAD)) .. "/" .. tostring(SA.isAdmitted(usU, SA.UNLOAD)), "false/false")

    -- A station registered between install and barrier: the hook fires, the host is not live.
    local pM, _, usMid = siloStations(m, "placeable:M", { 0 }, { 500 })
    ss:addUnloadingStation(usMid, pM)
    T.eq("E6 a station registered before the barrier is not bound by the hook", SA.isAdmitted(usMid, SA.UNLOAD), false)

    -- The defect, before anything is bound: the engine's loops through the engine's callers.
    local twLoad = loadOut(lsTW, veh, 100)
    T.eq("E7 [twin] unbound, a 100 L load through the trigger reports 100 ...", twLoad, 100)
    T.eq("E8 [twin] ... and removes 150 L from 50 + 200 L", 250 - sum(sTW), 150)
    local twUnload = unloadInto(usTU, 100)
    T.eq("E9 [twin] unbound, a 100 L unload into 50 + 200 L free reports 100 ...", twUnload, 100)
    T.eq("E10 [twin] ... and lands 150 L", sum(sTU), 150)

    -- The restore barrier.
    m:onFinishedLoading()
    T.ok("E11 [reached] the barrier made the host live", host.ready == true)
    T.eq("E12 the barrier's sweep admitted the map's loading station", SA.isAdmitted(lsA, SA.LOAD), true)
    T.eq("E13 and its unloading station", SA.isAdmitted(usU, SA.UNLOAD), true)
    T.eq("E14 and the one registered between install and barrier", SA.isAdmitted(usMid, SA.UNLOAD), true)
    T.eq("E15 and the one the engine holds though it returned false", SA.isAdmitted(usNoPlace, SA.UNLOAD), true)
    T.eq("E16 a SellingStation is withheld from the correction and gets the observation-only sale bracket", tostring(SA.isAdmitted(sell, SA.UNLOAD)) .. "/" .. tostring(host.stations[sell] and host.stations[sell].UNLOAD) .. "/" .. tostring(SA.isSaleBracketed(sell)), "false/false/true")
    T.eq("E17 a foreign instance override is withheld and left in place", tostring(SA.isAdmitted(usForeign, SA.UNLOAD)) .. "/" .. tostring(usForeign.addFillLevelFromTool == foreignFn), "false/true")
    T.eq("E18 a raw slot holding the native method is admitted", SA.isAdmitted(usRaw, SA.UNLOAD), true)

    -- Corrected quantities through the engine's own callers. A probe on the SECOND
    -- store counts host flushes before its write: the first store's write went from
    -- empty (a boundary), which flushes at once on the generic path.
    local flushes, flushesAtSecondWrite = 0, nil
    local realFlush = host.flush
    host.flush = function(self, ...) flushes = flushes + 1 return realFlush(self, ...) end
    sU[2].setFillLevel = function(self, ...) flushesAtSecondWrite = flushes return Storage.setFillLevel(self, ...) end
    m.accessCalls = {}
    local accepted = unloadInto(usU, 100)
    host.flush = nil
    sU[2].setFillLevel = nil
    T.eq("E19a inside the corrected loop nothing flushes: one physical operation", flushesAtSecondWrite, 0)
    T.ok("E19b [reached] the boundary flush runs once the loop's context closes", flushes >= 1)
    T.eq("E19 100 L unloaded into 50 + 200 L free: the station reports 100", accepted, 100)
    T.eq("E20 and lands 50 then 50, not 50 then 100", level(sU, 1) .. "/" .. level(sU, 2), "50/50")
    T.eq("E21 the effects fire once and the fill planes are kept", usU.fxCalls .. "/" .. usU.planeCalls, "1/1")
    local function flags(want)
        local n, bad = #m.accessCalls, 0
        for _, c in ipairs(m.accessCalls) do if c.allowEqual ~= want then bad = bad + 1 end end
        return n > 0 and bad == 0, n
    end
    T.eq("E22 every unloading access call keeps its true third argument", (flags(true)), true)
    m.accessCalls = {}
    local fillBefore = veh:getFillUnitFillLevel(1)
    local served = loadOut(lsA, veh, 100)
    T.eq("E23 a 100 L load from 50 + 200 L: the trigger's fill reports 100", served, 100)
    T.eq("E24 and removes 50 then 50, not 50 then 100", level(sA, 1) .. "/" .. level(sA, 2), "0/150")
    T.eq("E25 the vehicle received exactly what the sources gave", veh:getFillUnitFillLevel(1) - fillBefore, 250 - sum(sA))
    T.eq("E26 every loading access call keeps its absent third argument", (flags(nil)), true)

    -- Registered after the barrier: the hook binds at once.
    local pB, lsB, _, sB = siloStations(m, "placeable:B", { 200, 50 }, { 1000, 1000 })
    ss:addLoadingStation(lsB, pB)
    T.eq("E27 a loading station registered after the barrier is admitted by the hook", SA.isAdmitted(lsB, SA.LOAD), true)
    loadOut(lsB, veh, 100)
    T.eq("E28 large-first order: 100 from the first store, none from the second", level(sB, 1) .. "/" .. level(sB, 2), "100/50")
    local pV, _, usV, sV = siloStations(m, "placeable:V", { 0, 0 }, { 200, 50 })
    ss:addUnloadingStation(usV, pV)
    T.eq("E29 large-first unload: 100 into the first, nothing into the second", unloadInto(usV, 100) .. "/" .. level(sV, 1) .. "/" .. level(sV, 2), "100/100/0")
    local pN2, _, usNoPlace2 = siloStations(m, "placeable:N2", { 0 }, { 500 })
    ss:addUnloadingStation(usNoPlace2)
    T.eq("E30 after the barrier, a station the engine holds despite returning false is bound (the table decides, not the return)", SA.isAdmitted(usNoPlace2, SA.UNLOAD), true)

    -- Short supply and short destination return the truth.
    local pC, lsC, _, sC = siloStations(m, "placeable:C", { 50 }, { 1000 })
    ss:addLoadingStation(lsC, pC)
    T.eq("E31 a 100 L demand against 50 L returns 50 unserved", lsC:removeFillLevel(WHEAT, 100, 1), 50)
    T.eq("E32 and the source is empty, not negative", level(sC, 1), 0)
    local pD, _, usD, sD = siloStations(m, "placeable:D", { 0 }, { 50 })
    ss:addUnloadingStation(usD, pD)
    T.eq("E33 100 L into 50 L free returns the 50 accepted", unloadInto(usD, 100), 50)
    T.eq("E34 no effects for a short acceptance, fill planes kept", usD.fxCalls .. "/" .. usD.planeCalls .. "/" .. level(sD, 1), "0/1/50")

    -- The sliver the native loop strands at its effects threshold.
    local pE, _, usE, sE = siloStations(m, "placeable:E", { 0, 0 }, { 99.9995, 10 })
    ss:addUnloadingStation(usE, pE)
    local accE = unloadInto(usE, 100)
    T.eq("E35 within 0.001 of the request, the acceptance is the actual increase, exactly", accE, sum(sE))
    T.near("E36 and the next store took the sliver", level(sE, 2), 0.0005, 1e-9)
    local _, _, usE2, sE2 = siloStations(m, "placeable:E2", { 0, 0 }, { 99.9995, 10 })
    T.eq("E37 [twin] the unbound engine loop reports 100 with 99.9995 landed", tostring(unloadInto(usE2, 100)) .. "/" .. tostring(sum(sE2)), "100/99.9995")

    -- A converting trigger divides the station's truth by its ratio (UnloadTrigger.lua:140).
    local conv = { [GRASS] = { outgoingFillType = WHEAT, ratio = 0.5 } }
    local pG, _, usG, sG = siloStations(m, "placeable:G", { 0, 0 }, { 20, 200 })
    ss:addUnloadingStation(usG, pG)
    T.eq("E38 100 L of grass converted at 0.5 into 20 + 200 L free: the trigger reports 100 ...", unloadInto(usG, 100, GRASS, conv), 100)
    T.eq("E38b ... and 50 L of wheat land, 20 then 30", level(sG, 1) + level(sG, 2) * 1000, 20 + 30 * 1000)
    local _, _, usG2, sG2 = siloStations(m, "placeable:G2", { 0, 0 }, { 20, 200 })
    T.eq("E39 [twin] unbound, the same unload also reports 100 ...", unloadInto(usG2, 100, GRASS, conv), 100)
    T.eq("E39b [twin] ... while 70 L of wheat land for 50 asked", sum(sG2), 70)

    -- Access stays the station's own: per-farm stores and a narrower subclass.
    local pP, lsP, _, sP = siloStations(m, "placeable:P", { 40, 40 }, { 1000, 1000 }, { 1, 2 })
    lsP.hasStoragePerFarm = true
    ss:addLoadingStation(lsP, pP)
    veh.activeFarm = 2
    loadOut(lsP, veh, 30)
    veh.activeFarm = 1
    T.eq("E40 a per-farm station serves the active farm's store only", level(sP, 1) .. "/" .. level(sP, 2), "40/10")
    local Narrow = setmetatable({}, { __index = LoadingStation })
    Narrow.hasFarmAccessToStorage = function(self, farmId, storage) return not self.locked end
    local pQ, _, _, sQ = siloStations(m, "placeable:Q", { 20 }, { 1000 })
    local lsQ = LoadingStation.newModel({ __index = Narrow })
    lsQ:addSourceStorage(sQ[1])
    lsQ.locked = true
    ss:addLoadingStation(lsQ, pQ)
    T.eq("E41 a subclass overriding only access is admitted", SA.isAdmitted(lsQ, SA.LOAD), true)
    T.eq("E42 and its narrower access is the one dispatched", lsQ:removeFillLevel(WHEAT, 5, 1), 5)
    lsQ.locked = false
    T.eq("E43 [reached] twin: unlocked, the same station serves", lsQ:removeFillLevel(WHEAT, 5, 1), 0)

    -- Withheld stations keep their own behaviour.
    T.eq("E44 the SellingStation still sells through its own method", tostring(unloadInto(sell, 100)) .. "/" .. tostring(sell.sold[1] and sell.sold[1].fillDelta), "100/100")
    unloadInto(usForeign, 10)
    T.eq("E45 the foreign override is still the method called", foreignCalls, 1)

    -- A failed operation reaches the host, and an open operation owns it.
    local pBad, _, usBad, sBad = siloStations(m, "placeable:BAD", { 0 }, { 500 })
    sBad[1].getFillLevel = function() return 0 / 0 end
    ss:addUnloadingStation(usBad, pBad)
    local frame = SGOperationContext.open(host.context, nil, "TEST")
    T.eq("E46 a failed unload accepts nothing", unloadInto(usBad, 10), 0)
    T.eq("E47 the host counted it", host.stationFailures, 1)
    T.eq("E48 and recorded it on the open operation", frame.observations[1] and frame.observations[1].source .. "/" .. frame.observations[1].failure, "STATION/INVALID_TARGET_LEVEL")
    SGOperationContext.close(host.context, frame)
    -- A trigger drives its station every frame: the same failure repeats.
    local pBad2, _, usBad2, sBad2 = siloStations(m, "placeable:BAD2", { 0 }, { 500 })
    sBad2[1].getFillLevel = function() return 0 / 0 end
    ss:addUnloadingStation(usBad2, pBad2)
    local realPrint, lines = print, 0
    print = function(s) if tostring(s):find("operation failed", 1, true) then lines = lines + 1 end end
    unloadInto(usBad, 10)
    unloadInto(usBad, 10)
    local repeats = lines
    unloadInto(usBad2, 10)
    print = realPrint
    T.eq("E48b a repeated failure is counted every time but logged once", host.stationFailures .. "/" .. repeats, "4/0")
    T.eq("E48c [reached] twin: another station's first failure is logged", lines, 1)

    -- Lifecycle: removal restores the raw slot, by kind, and never erases a later replacement.
    ss:removeUnloadingStation(usMid, pM)
    T.eq("E49 removal restores the inherited slot to nil", tostring(rawget(usMid, "addFillLevelFromTool")) .. "/" .. tostring(usMid.addFillLevelFromTool == legacyUnload), "nil/true")
    T.eq("E50 and the host forgets the station", host.stations[usMid], nil)
    local dual = setmetatable({ sourceStorages = {}, targetStorages = {}, fxCalls = 0, planeCalls = 0 }, { __index = function(_, k) if LoadingStation[k] ~= nil then return LoadingStation[k] end return UnloadingStation[k] end })
    ss:addLoadingStation(dual, pA)
    ss:addUnloadingStation(dual, pA)
    T.eq("E51 [reached] an object registered under both kinds is admitted under both", tostring(SA.isAdmitted(dual, SA.LOAD)) .. "/" .. tostring(SA.isAdmitted(dual, SA.UNLOAD)), "true/true")
    ss:removeLoadingStation(dual, pA)
    T.eq("E52 removing it as a loading station unbinds only that kind", tostring(SA.isAdmitted(dual, SA.LOAD)) .. "/" .. tostring(SA.isAdmitted(dual, SA.UNLOAD)), "false/true")
    ss:removeUnloadingStation(dual, pA)
    T.eq("E53 and removing the other kind forgets it", tostring(SA.isAdmitted(dual, SA.UNLOAD)) .. "/" .. tostring(host.stations[dual]), "false/nil")
    local pL, _, usLater = siloStations(m, "placeable:L", { 0 }, { 500 })
    ss:addUnloadingStation(usLater, pL)
    local laterFn = function() return 0 end
    usLater.addFillLevelFromTool = laterFn
    ss:removeUnloadingStation(usLater, pL)
    T.eq("E54 a later foreign replacement survives the removal", usLater.addFillLevelFromTool, laterFn)

    -- Registration is read from the MISSION's storage system, not from whichever
    -- instance ran the hooked class method.
    local pX, _, usX = siloStations(m, "placeable:X", { 0 }, { 500 })
    StorageSystem.newModel():addUnloadingStation(usX, pX)
    T.eq("E61 a station registered with a storage system that is not the mission's is not bound", SA.isAdmitted(usX, SA.UNLOAD), false)
    ss:addUnloadingStation(usX, pX)
    T.eq("E62 [reached] twin: registered with the mission's, it is", SA.isAdmitted(usX, SA.UNLOAD), true)

    -- Teardown through main's FSBaseMission.delete.
    FSBaseMission.delete(m)
    T.eq("E55 teardown clears the live host", NH.current, nil)
    T.eq("E56 and restores every inherited slot", tostring(rawget(lsA, "removeFillLevel")) .. "/" .. tostring(rawget(usU, "addFillLevelFromTool")) .. "/" .. tostring(rawget(lsB, "removeFillLevel")), "nil/nil/nil")
    T.eq("E57 and a raw native slot as raw", rawget(usRaw, "addFillLevelFromTool"), legacyUnload)
    T.eq("E58 inheritance is native again", tostring(lsA.removeFillLevel == legacyLoad) .. "/" .. tostring(usU.addFillLevelFromTool == legacyUnload), "true/true")
    local pPost, _, usPost = siloStations(m, "placeable:POST", { 0 }, { 500 })
    ss:addUnloadingStation(usPost, pPost)
    T.eq("E59 after teardown a registration binds nothing", SA.isAdmitted(usPost, SA.UNLOAD), false)
    T.eq("E60 the process hooks are still single", tostring(StorageSystem[NH.HOOK_MARKER] ~= nil) .. "/" .. tostring(StorageSystem.addUnloadingStation == StorageSystem[NH.HOOK_MARKER].addUnloadingStation.wrapper), "true/true")
    E.hookWrapper = StorageSystem.addUnloadingStation
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. A LATER FOREIGN CLASS WRAP (TransportCompany's shape) IN A SECOND MISSION
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local m = newMission()
    g_server = {}
    g_currentMission = m
    -- TransportCompany class-wraps UnloadingStation.addFillLevelFromTool from its
    -- manager constructor at mission load (TransportCompanyManager.lua:2360-2407).
    local tcCalls = 0
    local tcOriginal = UnloadingStation.addFillLevelFromTool
    UnloadingStation.addFillLevelFromTool = function(self, ...) tcCalls = tcCalls + 1 return tcOriginal(self, ...) end
    local pU, _, usU = siloStations(m, "placeable:TU", { 0 }, { 500 })
    m.storageSystem:addUnloadingStation(usU, pU)
    local pA, lsA = siloStations(m, "placeable:TA", { 100 }, { 1000 })
    m.storageSystem:addLoadingStation(lsA, pA)
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    T.ok("T1 [reached] the second mission's host is live", NH.current ~= nil and NH.current.ready == true)
    T.eq("T2 the baseline was not recaptured from the foreign wrap", SA.nativeUnloadQuantity, legacyUnload)
    T.eq("T3 a station resolving to the foreign class wrap is withheld", tostring(SA.isAdmitted(usU, SA.UNLOAD)) .. "/" .. tostring(rawget(usU, "addFillLevelFromTool")), "false/nil")
    unloadInto(usU, 10)
    T.eq("T4 and the foreign wrap is still reached", tcCalls, 1)
    T.eq("T5 [reached] twin: the loading station, still native, is admitted", SA.isAdmitted(lsA, SA.LOAD), true)
    T.eq("T6 the second kernel install did not stack a second station hook", StorageSystem.addUnloadingStation, E.hookWrapper)
    FSBaseMission.delete(m)
    UnloadingStation.addFillLevelFromTool = tcOriginal
    T.eq("T7 teardown restored the second mission's station", rawget(lsA, "removeFillLevel"), nil)
end)
