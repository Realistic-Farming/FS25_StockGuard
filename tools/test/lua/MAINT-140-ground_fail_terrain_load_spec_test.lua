-- MAINT-140-ground_fail_terrain_load_spec_test.lua
--
-- MAINTENANCE row 140 (Bob's intake: Desk Office/Drafts/BOB-INTAKE-SG-ROW140-GROUND-FAIL-
-- LOAD-HANG-2026-09-26.md; Tyson's ruling 2026-09-26, shape (a')). A failed SG-6 ground
-- preparation used to skip native DensityMapHeightManager:initialize, so the terrain load
-- died in SnowSystem:onTerrainLoad (1 / nil, SnowSystem.lua:108) before its TERRAIN target,
-- and the failure was never presented: the game hung on the loading screen. Now native
-- initialize runs with the saved mapping withheld, the phase stays FAILED, and finished
-- loading presents the failure and cancels the load.
--
-- THE ENTRY-POINT BAR IS GROUP T. The engine models load first (SG2-2's, then the SG-6
-- terrain model), then every module main.lua sources, then Soil & Fertilizer's REAL
-- SoilCapacityIntegration.lua (tools/test/lua/vendor/, byte-identical to FS25_SoilFertilizer
-- development 9234ebfd, git blob 130b882b, last changed there by f30391d9), then main.lua,
-- which installs SG-6's hooks on the engine's classes. The engine publishes each mod's
-- environment as a global under its mod name (mods.lua:429), so FS25_SoilFertilizer is
-- Soil's environment and StockGuard's preflight resolves Soil's table itself. A load then
-- runs the engine's order: fill type registration through the hooked FillTypeManager,
-- Mission00:setMissionInfo (SG-6's preflight joins Soil), Mission00:load, the terrain load
-- (the saved mapping, initialize, the snow system, the TERRAIN target),
-- loadMission00Finished, onFinishedLoading, and the unload. Nothing here writes a phase, a
-- join, a ground row or a failure.
--
-- Groups:
--   T  the entry-point bar: a map whose ground slots are nearly full takes none of Soil's
--      solids and refuses POLIFOSKA (the player's log); the terrain load reaches TERRAIN,
--      native initialize ran with no mapping and no conversion, the ground is not marked
--      initialized, and finished loading presents the failure and cancels
--   R  the READY path is unchanged: a map with room keeps its saved mapping through native
--      initialize, the ground is marked initialized, and finished loading runs the native body
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG-6-terrain_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, tools/test/lua/vendor/SoilCapacityIntegration.lua, main.lua

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The engine publishes Soil's mod environment under its mod name (mods.lua:429).
FS25_SoilFertilizer = { SoilCapacityIntegration = SoilCapacityIntegration }

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = setmetatable({}, { __index = FSBaseMission })
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end

local function newMission()
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = false }, time = 1000, terrainSize = 2048,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {}, snowSystem = { isServer = true }, cancelLoading = false }, Mission)
    m.accessHandler = { canFarmAccess = function() return true end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function() return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

local SOIL = { "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA", "GYPSUM", "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE" }

--- The map's own ground roster (the base game's, the map's and other mods' tippable
--- materials, sorted): the two templates Soil copies, then `others` more.
local function rosterNames(others)
    local names = { "FERTILIZER", "MANURE" }
    for i = 1, others do names[#names + 1] = string.format("GROUND_%02d", i) end
    return names
end

--- One mission load in the engine's order. `world.others` sizes the map's roster; a
--- `world.saved` mapping (lowercase name to index) makes it an accepted existing save.
local function load(world)
    ENGINE_DIALOGS, ENGINE_TEARDOWNS, ENGINE_C_CALLS = {}, 0, {}
    g_mpLoadingScreen.targets = {}
    local names = rosterNames(world.others)
    local ftm = FillTypeManager.newModel()
    g_fillTypeManager = ftm
    ftm:loadMapData()
    ftm:addFillType({ name = "UNKNOWN" })
    for _, n in ipairs(names) do ftm:addFillType({ name = n }) end
    for _, n in ipairs(SOIL) do ftm:addFillType({ name = n }) end
    ftm:addFillType({ name = "SNOW" })
    local rows = {}
    for _, n in ipairs(names) do rows[#rows + 1] = { n, ftm:getFillTypeIndexByName(n) } end
    local hm = DensityMapHeightManager.newModel(rows, 6)
    g_densityMapHeightManager = hm
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local path = world.saved ~= nil and "savegame1/densityMapHeight.xml" or nil
    ENGINE_SAVED_MAPPINGS = {}
    if path ~= nil then ENGINE_SAVED_MAPPINGS[path] = world.saved end
    local mi = { isValid = world.saved ~= nil, mapId = "MapUS", densityMapHeightXMLLoad = path,
        getIsDensityMapValid = function() return world.saved ~= nil end }
    Mission00.setMissionInfo(m, mi, { isMultiplayer = false, mods = { { modName = "FS25_StockGuard" }, { modName = "FS25_SoilFertilizer" } } })
    Mission00.load(m)
    local ok, err = pcall(ENGINE_INIT_TERRAIN, m)
    local finished = nil
    if ok then
        Mission00.loadMission00Finished(m)
        finished = m:onFinishedLoading()
    end
    return { m = m, hm = hm, ftm = ftm, ok = ok, err = err, finished = finished }
end
--- The mission's unload: StockGuard's teardown and the fill type manager's unload
--- (which ends Soil's join through SG-6's epoch reset, SGCapacity.lua onEpochReset).
local function unload(w)
    FSBaseMission.delete(w.m)
    g_fillTypeManager:unloadMapData()
end

local function saved(list)
    local out = {}
    for i, n in ipairs(list) do out[string.lower(n)] = i end
    return out
end

-- ══════════════════════════════════════════════════════════════════════════
-- T. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local ctl = StockGuardCapacity
    T.eq("T1 [reached] main.lua wrapped the engine's setMissionInfo, initialize and onFinishedLoading",
        tostring(Mission00.setMissionInfo ~= ENGINE_ORIGINALS.setMissionInfo) .. "/" .. tostring(DensityMapHeightManager.initialize ~= ENGINE_ORIGINALS.initialize) .. "/" .. tostring(FSBaseMission.onFinishedLoading ~= ENGINE_ORIGINALS.onFinishedLoading),
        "true/true/true")
    -- The map's roster fills 57 of the 63 ground slots six type channels give; the save
    -- was made with fewer mods, when Soil's twelve still fitted (51 + 12 = 63).
    local older = rosterNames(49)
    for _, n in ipairs(SOIL) do older[#older + 1] = n end
    local w = load({ others = 55, saved = saved(older) })
    T.eq("T2 [world] Soil's real prepare refused POLIFOSKA at the ceiling and wrote nothing: the phase is FAILED",
        tostring(ctl.phase) .. " " .. tostring(ctl.reasonCode) .. " " .. tostring(ctl.offending) .. " " .. tostring(w.hm.numHeightTypes),
        "FAILED SOIL_PREPARE:GROUND_CAPACITY POLIFOSKA 57")
    T.eq("T3 the terrain load ran to its TERRAIN target: the snow system's layer height is a number and the server updater exists",
        tostring(w.ok) .. " " .. table.concat(g_mpLoadingScreen.targets, ",") .. " " .. type(w.m.snowSystem.layerHeight) .. " " .. tostring(w.m.snowSystem.updater ~= nil),
        "true TERRAIN number true")
    T.eq("T4 native initialize ran once, handed no saved mapping, and asked for no type conversion",
        tostring(w.hm.initializeCalls) .. " " .. tostring(w.hm.mappingSeenByNative) .. " " .. tostring(w.hm.forceTypeConversion) .. " " .. tostring(w.hm.tipTypeMappings),
        "1 false false nil")
    T.eq("T5 the ground is not marked initialized", tostring(ctl.groundInitialized), "false")
    T.eq("T6 finished loading presents the failure once and cancels: one notice naming the refusal, one teardown, the native body never runs",
        tostring(w.m.cancelLoading) .. " " .. tostring(#ENGINE_DIALOGS) .. " " .. tostring(ENGINE_DIALOGS[1] ~= nil and ENGINE_DIALOGS[1]:find("SOIL_PREPARE:GROUND_CAPACITY (POLIFOSKA)", 1, true) ~= nil) .. " " .. tostring(ENGINE_TEARDOWNS) .. " " .. tostring(w.m.nativeFinishedLoading) .. " " .. tostring(w.finished),
        "true 1 true 1 nil nil")
    T.eq("T7 the phase is still FAILED after finished loading", tostring(ctl.phase), "FAILED")
    unload(w)
    T.eq("T8 the unload reopened the controller and ended Soil's join", tostring(ctl.phase) .. " " .. tostring(SoilCapacityIntegration.getJoinedMission()), "LOADING nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE READY PATH IS UNCHANGED
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local ctl = StockGuardCapacity
    -- 51 rows and Soil's twelve fill the 63 slots exactly; the save holds that roster.
    local full = rosterNames(49)
    for _, n in ipairs(SOIL) do full[#full + 1] = n end
    local w = load({ others = 49, saved = saved(full) })
    T.eq("R1 [world] Soil prepared its twelve solids at 52..63", tostring(w.hm.numHeightTypes) .. " " .. tostring(w.hm.heightTypes[52].fillTypeName) .. " " .. tostring(w.hm.heightTypes[63].fillTypeName),
        "63 UREA PELLETIZED_MANURE")
    T.eq("R2 the terrain load reached TERRAIN; native initialize ran once WITH the saved mapping and no conversion; the ground is marked initialized",
        tostring(w.ok) .. " " .. table.concat(g_mpLoadingScreen.targets, ",") .. " " .. tostring(w.hm.initializeCalls) .. " " .. tostring(w.hm.mappingSeenByNative) .. " " .. tostring(w.hm.forceTypeConversion) .. " " .. tostring(ctl.groundInitialized),
        "true TERRAIN 1 true false true")
    T.eq("R3 finished loading is READY and runs the native body once; no notice, no cancel",
        tostring(ctl.phase) .. " " .. tostring(w.finished) .. " " .. tostring(w.m.nativeFinishedLoading) .. " " .. tostring(#ENGINE_DIALOGS) .. " " .. tostring(w.m.cancelLoading),
        "READY native 1 0 false")
    unload(w)
end)
