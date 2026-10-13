-- SG-187-reload_safety_spec_test.lua
--
-- MAINTENANCE row 187: StockGuard after a mods reload at the main menu. reloadDlcsAndMods
-- (mods.lua:1173-1211) sources the mod again without a game restart; the engine's own
-- classes keep what was written on them. On PC the mod gets a FRESH environment
-- (loadModDesc, mods.lua:482-493), on console the SAME one (:483-485). Every hook StockGuard
-- puts on an engine class is now one SGClassHook record per site for the process, and every
-- install rebinds it, so after a reload exactly one copy runs: the newest.
-- Bob's shape: Drafts/BOB-SHAPE-MAINT187-RELOAD-SAFETY-2026-10-01.md.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv). --!reload hands the bench
-- ENGINE_RELOAD_MODS(mode), which sources every file below again, as the reload does.
--
-- THE ENTRY-POINT BAR IS GROUP P. Two missions booted through main.lua's own hooks on the
-- engine classes (Mission00.load, loadMission00Finished, FSBaseMission.update and delete,
-- FSCareerMissionInfo.saveToXMLFile), a PC reload between them, and the counts Bob named:
-- one host per mission, one update per frame, one save write per save, one stream write per
-- object, and dispatch reaching the new host at every hooked engine class. The engine
-- natives count their own calls (SG-187-reload_model.lua); nothing writes a host, a hook or
-- a record by hand.
--
-- Groups:
--   D  site 5: a second mission with a new Dischargeable (no reload) captures discharges
--   C  the console reload (the same environment): one copy, rebound to the new chunk
--   P  the PC reload (a fresh environment): sites 1-4 and 6-9
--   L  a pre-fix StockGuard's wrapper under ours: a pass-through, one native call
--
-- THE CAPACITY CONTROLLER. The SG2 models publish StockGuardCapacity as a READY stub in the
-- real global table, for the restore barrier (SG2-2-engine_model.lua:466-468), so main.lua's
-- `StockGuardCapacity or SGCapacity.new()` finds it in every environment. A game has no such
-- global, so a fresh environment makes a NEW controller; the bench makes one real controller
-- per load and installs it (SGCapacity.installHooks, SGWireFormats.install), as that load's
-- main.lua and finished-loading hook do.
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG-187-reload_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua
--!reload: src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local REAL = getmetatable(_G).__index
local K = SGClassHook

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function engine(name, value) REAL[name] = value end
local function calls(name) return ENGINE_NATIVE_CALLS[name] or 0 end

--- The module tables one load of StockGuard made, read from the environment it ran in.
local function mods(env)
    return { env = env, SG = env.StockGuard, NH = env.SGNativeHost, M = env.SGNativeMaterialSave, WF = env.SGWireFormats,
             CAP = env.SGCapacity, CS = env.SGCutState, HC = env.SGHarvestCapture, F = env.SGFarmRestore,
             D = env.SGDischargeCapture, CP = env.SGCanonicalProfile, FUO = env.SGFillUnitObserver }
end
local FIRST = mods(_ENV)

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir, index)
    local m = setmetatable({ _server = true, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, time = 1000,
        terrainSize = 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = index, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function() return true end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function() return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end
--- A tipper whose dischargeToObject is copied from the CURRENT Dischargeable, as a vehicle
--- built for this map load copies it (Dischargeable.lua:97).
local function tipper(uid)
    local v = ENGINE_NEW_TRAILER(uid, { level = 100, fillType = ENGINE_FT.WHEAT })
    v.spec_dischargeable = { dischargeNodes = { { index = 1, fillUnitIndex = 1 } } }
    v.dischargeToObject = Dischargeable.dischargeToObject
    return v
end
--- Boot a mission through main.lua's hooks on the engine classes; `S` names the module
--- copy the bench reads back (the hooks themselves decide which copy runs).
local function boot(S, saveDir, index, vehicles)
    local m = newMission(saveDir, index)
    engine("g_server", {})
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    for _, v in ipairs(vehicles or {}) do m._vehicles[#m._vehicles + 1] = v end
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, S.SG.hostOf(m), S.NH.current
end
local function nativeSave(m, finalDir)
    ENGINE_SAVE.finalDir = finalDir
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    ENGINE_RUN_FRAMES(nil)
end
engine("g_savegameController", SavegameController.new())

--- Count calls of obj[name] (an instance field over the class method).
local function counter(obj, name)
    local box = { n = 0 }
    local inner = obj[name]
    obj[name] = function(...) box.n = box.n + 1 if inner ~= nil then return inner(...) end end
    return box
end
--- Count calls of a module function the hooks look up at call time, without running it.
local function stub(tbl, name)
    local box = { n = 0 }
    tbl[name] = function() box.n = box.n + 1 end
    return box
end

-- ══════════════════════════════════════════════════════════════════════════
-- D. SITE 5: A SECOND MISSION WITH A NEW DISCHARGEABLE (no mods reload)
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local v1 = tipper("vehicle:tipper1")
    local okBoot, m1 = pcall(boot, FIRST, "d1", 71, { v1 })
    T.eq("D1 [precondition] the first mission boots and its tipper carries the discharge capture", tostring(okBoot) .. "/" .. tostring(rawget(v1, FIRST.D.MARKER) ~= nil), "true/true")
    if not okBoot then return end
    FSBaseMission.delete(m1)
    ENGINE_RESOURCE_DISCHARGEABLE()
    local v2 = tipper("vehicle:tipper2")
    boot(FIRST, "d2", 72, { v2 })
    T.eq("D2 the next map load builds a new Dischargeable; the capture reads it at install, so the new mission's tipper is captured too",
        tostring(rawget(v2, FIRST.D.MARKER) ~= nil) .. "/" .. tostring(FIRST.D.nativeDischargeToObject == Dischargeable.dischargeToObject), "true/true")
    FSBaseMission.delete(g_currentMission)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE CONSOLE RELOAD: THE SAME ENVIRONMENT
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local S = FIRST
    local m1 = boot(S, "c1", 91)
    local aroundBefore = K.record(Mission00, "load", "stockGuardMain").around
    FSBaseMission.delete(m1)
    local env = ENGINE_RELOAD_MODS("same")
    local S2 = mods(env)
    T.eq("C1 the console reload re-sources into the SAME environment: the module tables persist, and every hook is rebound to the new chunk's code",
        tostring(S2.SG == S.SG and S2.NH == S.NH) .. "/" .. tostring(K.record(Mission00, "load", "stockGuardMain").around ~= aroundBefore), "true/true")
    local okBoot, m2, sg2, nh2 = pcall(boot, S2, "c2", 92)
    local hosts = 0
    if okBoot then for _, h in pairs(S2.SG._hosts) do if h ~= nil and h.mission == m2 then hosts = hosts + 1 end end end
    T.eq("C2 the mission boots, with one host and one native kernel", tostring(okBoot) .. "/" .. hosts .. "/" .. tostring(okBoot and nh2 ~= nil and S2.NH.current == nh2), "true/1/true")
    if not okBoot then return end
    local ups, saves = counter(sg2, "update"), counter(sg2, "onSaveToXML")
    FSBaseMission.update(m2, 16)
    nativeSave(m2, "c2_final")
    T.eq("C3 one update per frame and one save write per save", ups.n .. "/" .. saves.n, "1/1")
    local bought = ENGINE_NEW_TRAILER("vehicle:boughtC", {})
    VehicleSystem.addVehicle(m2.vehicleSystem, bought)
    T.eq("C4 a bought vehicle reaches the host", tostring(rawget(bought, S2.FUO.MARKER) ~= nil), "true")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PC RELOAD: A FRESH ENVIRONMENT
-- ══════════════════════════════════════════════════════════════════════════
local NEW = nil
group("P", function()
    local m1, sg1, nh1 = boot(FIRST, "p1", 81)
    local ctl1 = FIRST.CAP.new()
    FIRST.CAP.installHooks(ctl1)         -- this load's controller, as its main.lua makes it
    local okWire1 = pcall(FIRST.WF.install, ctl1)   -- as mission one's finished-loading hook does
    T.eq("P0 [precondition] mission one: one host, its native kernel live, its stream pairs installed", tostring(sg1 ~= nil and nh1 ~= nil and FIRST.NH.current == nh1) .. "/" .. tostring(okWire1), "true/true")
    FSBaseMission.delete(m1)
    NEW = mods(ENGINE_RELOAD_MODS("fresh"))
    local ctl2 = NEW.CAP.new()
    local okCap = pcall(NEW.CAP.installHooks, ctl2)
    T.eq("P1 the reload sourced StockGuard into a fresh environment: new module tables, and its own capacity controller, installed",
        tostring(NEW.SG ~= FIRST.SG and NEW.NH ~= FIRST.NH and NEW.CAP ~= FIRST.CAP and ctl2 ~= ctl1) .. "/" .. tostring(okCap), "true/true")
    local okBoot, m2, sg2, nh2 = pcall(boot, NEW, "p2", 82)
    local okWire = okBoot and pcall(NEW.WF.install, ctl2)
    T.eq("P2 [entry point] mission two boots with exactly ONE StockGuard host and one native kernel, the new module's; the old module made none",
        tostring(okBoot) .. "/" .. tostring(okWire) .. "/" .. tostring(okBoot and sg2 ~= nil and m2.stockGuard == sg2.handle) .. "/" .. tostring(okBoot and FIRST.SG.hostOf(m2) or nil) .. "/"
            .. tostring(okBoot and nh2 ~= nil and NEW.NH.current == nh2) .. "/" .. tostring(FIRST.NH.current),
        "true/true/true/nil/true/nil")
    if not okBoot then return end
    local hookOwner = K.record(Mission00, "load", "stockGuardMain")
    T.eq("P3 each main.lua hook is one record, rebound to the new module, over the engine's own method",
        tostring(hookOwner ~= nil and hookOwner.owner == NEW.SG and hookOwner.original == ENGINE_NATIVES.load and Mission00.load == hookOwner.wrapper) .. "/"
            .. tostring(K.boundTo(FSBaseMission, "update", "stockGuardMain", NEW.SG) and K.record(FSBaseMission, "update", "stockGuardMain").original == ENGINE_NATIVES.update),
        "true/true")
    -- One update per frame.
    local ups, nhUps = counter(sg2, "update"), counter(nh2, "update")
    FSBaseMission.update(m2, 16)
    T.eq("P4 one frame: the host updates once and the native kernel once", ups.n .. "/" .. nhUps.n, "1/1")
    -- One save write per save, and the attempt on the new boundary.
    local saves = counter(sg2, "onSaveToXML")
    nativeSave(m2, "p2_final")
    T.eq("P5 one save: StockGuard writes once, and the native save's attempt opens on the NEW boundary, which alone the live wrappers serve",
        saves.n .. "/" .. tostring(sg2.nativeSave.lastAttempt ~= nil) .. "/" .. tostring(NEW.M.hooks.controller) .. "/"
            .. tostring(K.boundTo(SavegameController, "onSaveStartComplete", NEW.M.HOOK_ID, NEW.M)) .. "/"
            .. tostring(K.boundTo(SavegameController, "onSaveStartComplete", FIRST.M.HOOK_ID, FIRST.M)),
        "1/true/true/true/false")
    -- Site 1: a vehicle bought mid-mission.
    local bought = ENGINE_NEW_TRAILER("vehicle:bought", {})
    VehicleSystem.addVehicle(m2.vehicleSystem, bought)
    T.eq("P6 site 1: a bought vehicle reaches the new host, which installs its fill-unit observer",
        tostring(rawget(bought, NEW.FUO.MARKER) ~= nil) .. "/" .. tostring(K.boundTo(VehicleSystem, "addVehicle", NEW.NH.HOOK_ID, NEW.NH)), "true/true")
    -- Site 2: a storage level change.
    local seen = counter(nh2, "onStorageChange")
    local st = Storage.newModel({ [ENGINE_FT.WHEAT] = 100 })
    local before = calls("Storage.setFillLevel")
    st:setFillLevel(150, ENGINE_FT.WHEAT)
    T.eq("P7 site 2: a storage change is observed once, by the new host", tostring(seen.n), "1")
    -- Site 4: a cut, with an active cutter frame on the new module.
    local newBefore, oldBefore = stub(NEW.CS, "before"), stub(FIRST.CS, "before")
    NEW.HC.activeEntry = {}
    FSDensityMapUtil.cutFruitArea(ENGINE_FRUIT.WHEAT, 0, 0, 1, 0, 0, 1, false, false)
    NEW.HC.activeEntry = nil
    T.eq("P8 site 4: a cut is measured by the new cut-state module only (the old one never sees it)", newBefore.n .. "/" .. oldBefore.n, "1/0")
    -- Site 7: the capacity controller.
    local newEntry, oldEntry = counter(ctl2, "onMapDataEntry"), counter(ctl1, "onMapDataEntry")
    local loads = calls("FillTypeManager.loadMapData")
    local okLoad = pcall(FillTypeManager.loadMapData, {})
    local sizing = K.record(FillTypeManager, "addFillType", NEW.CAP.HOOK_ID)
    T.eq("P9 site 7: a map-data load reaches the native once and the NEW controller once, never the old; the sizing guard is one record over the native",
        tostring(okLoad) .. "/" .. (calls("FillTypeManager.loadMapData") - loads) .. "/" .. newEntry.n .. "/" .. oldEntry.n .. "/" .. tostring(sizing ~= nil and sizing.owner == NEW.CAP and sizing.original == ENGINE_NATIVES.addFillType),
        "true/1/1/0/true")
    local newHeader, oldHeader = stub(NEW.CP, "writeHeader"), stub(FIRST.CP, "writeHeader")
    local writes = calls("BaseMissionFinishedLoadingEvent.writeStream")
    local okWrite = pcall(BaseMissionFinishedLoadingEvent.writeStream, {}, 1, nil)
    T.eq("P10 site 7: the finished-loading event writes its native fields once and ONE admission header, the new module's",
        tostring(okWrite) .. "/" .. (calls("BaseMissionFinishedLoadingEvent.writeStream") - writes) .. "/" .. newHeader.n .. "/" .. oldHeader.n, "true/1/1/0")
    -- Site 8: the stream pairs.
    local newReady, oldReady = counter(ctl2, "isReady"), counter(ctl1, "isReady")
    local sw = calls("Storage.writeStream")
    Storage.writeStream({}, 1, { getIsServer = function() return true end })
    local pair = K.record(Storage, "writeStream", NEW.WF.HOOK_ID)
    T.eq("P11 site 8: one stream write per object: the new pair alone reads its controller, the native runs once, and the pair is one record over the native",
        newReady.n .. "/" .. oldReady.n .. "/" .. (calls("Storage.writeStream") - sw) .. "/" .. tostring(pair ~= nil and pair.owner == NEW.WF and pair.original == ENGINE_NATIVES.storageWrite and Storage.writeStream == pair.wrapper),
        "1/0/1/true")
    T.eq("P12 site 8: every replaced pair verifies as current after the reload", tostring((NEW.WF.verifyInstalled())), "true")
    local ours = Storage.writeStream
    Storage.writeStream = function(...) return ours(...) end
    local okV, what = NEW.WF.verifyInstalled()
    Storage.writeStream = ours
    T.eq("P12b and a foreign replacement of a pair after the reload is still caught, by name", tostring(okV) .. "/" .. tostring(what), "false/Storage.writeStream")
    -- Site 9: the farm hooks.
    local observed = counter(sg2.coordinator, "observeFarmsLoadedWithoutMerge")
    local defaults = calls("FarmManager.loadDefaults")
    FarmManager.loadDefaults({})
    T.eq("P13 site 9: FarmManager.loadDefaults runs its native once and reaches the new mission's coordinator once",
        (calls("FarmManager.loadDefaults") - defaults) .. "/" .. observed.n .. "/" .. tostring(K.boundTo(FarmManager, "loadDefaults", NEW.F.HOOK_ID, NEW.F)), "1/1/true")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. A PRE-FIX STOCKGUARD'S WRAPPER UNDER OURS
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    -- The process ran a pre-fix StockGuard first: its addVehicle wrapper sits on the class,
    -- dispatching to a module whose host is gone. Ours goes on top of it.
    K.unwrap(VehicleSystem, "addVehicle", NEW.NH.HOOK_ID)
    local legacy = 0
    local below = VehicleSystem.addVehicle
    VehicleSystem.addVehicle = function(self, ...)
        local r = { below(self, ...) }
        legacy = legacy + 1                    -- its dispatch reaches a module with no host
        return unpack(r)
    end
    rawset(VehicleSystem, "_sgNativeHostHooked", { addVehicle = { original = below, wrapper = VehicleSystem.addVehicle } })
    local S = mods(ENGINE_RELOAD_MODS("fresh"))
    local m = boot(S, "l1", 95)
    local rec = K.record(VehicleSystem, "addVehicle", S.NH.HOOK_ID)
    local bought = ENGINE_NEW_TRAILER("vehicle:boughtL", {})
    VehicleSystem.addVehicle(m.vehicleSystem, bought)
    T.eq("L1 ours wraps on top of the pre-fix wrapper (a new key, never rebound into the old one); the old one passes through once and the new host observes the vehicle",
        tostring(rec ~= nil and VehicleSystem.addVehicle == rec.wrapper and rec.original ~= ENGINE_NATIVES.addVehicle) .. "/" .. legacy .. "/" .. tostring(rawget(bought, S.FUO.MARKER) ~= nil),
        "true/1/true")
    FSBaseMission.delete(m)
end)
