-- SG-6-terrain_model.lua - the capacity and terrain-load engine the MAINTENANCE row 140 bench
-- runs against.
--
-- NOT A TEST. A bar lists it SECOND in --!load, after SG2-2-engine_model.lua (Utils,
-- Mission00, FSBaseMission, source) and before any StockGuard file, as the game defines its
-- classes before a mod's source(): SG-6's hooks install at main.lua's load and wrap only the
-- methods that exist then.
--
-- Bodies marked VERBATIM follow D:\FS25_Decoded\dataS\scripts_decompiled at the cited lines;
-- bodies marked MODELED stand in for engine code whose effect here is a handful of fields
-- (the C calls of initialize and the terrain load are not visible in Lua).

FillType.SNOW = FillType.SNOW or 90

-- SG2-2-engine_model.lua stands a READY capacity stub in for the SG2 benches; this bench
-- runs the real controller, which main.lua creates when none exists.
StockGuardCapacity = nil

-- ── the terrain's density map (C) ─────────────────────────────────────────
-- A map's terrainDetailHeight layer: its height channels (FSBaseMission.lua:1367;
-- getDensityMapHeightFirstChannel / NumChannels are C) and its maximum height.
ENGINE_TERRAIN = { id = 7, heightFirstChannel = 6, heightNumChannels = 6, maxHeight = 4 }
function getDensityMapHeightFirstChannel(id) return ENGINE_TERRAIN.heightFirstChannel end
function getDensityMapHeightNumChannels(id) return ENGINE_TERRAIN.heightNumChannels end
ENGINE_C_CALLS = {}
--- SnowSystem.lua:111 hands the updater to this C function; recorded, never judged.
function setDensityMapHeightUpdateType(updater, heightType)
    ENGINE_C_CALLS[#ENGINE_C_CALLS + 1] = { fn = "setDensityMapHeightUpdateType", updater = updater, heightType = heightType }
end

-- ── FillTypeManager (fillTypes/FillTypeManager.lua) ────────────────────────
-- SEND_NUM_BITS :6; addFillType :203 MODELED (index = #fillTypes + 1, the name map); the
-- name and index lookups; loadMapData :65 and unloadMapData :98 as bare entry points.
FillTypeManager = { SEND_NUM_BITS = 8 }
local FillTypeManager_mt = { __index = FillTypeManager }
function FillTypeManager.newModel()
    return setmetatable({ fillTypes = {}, nameToIndex = {} }, FillTypeManager_mt)
end
function FillTypeManager:addFillType(desc)
    desc.index = #self.fillTypes + 1
    self.fillTypes[desc.index] = desc
    self.nameToIndex[desc.name] = desc.index
    return true
end
function FillTypeManager:getFillTypeIndexByName(name) return self.nameToIndex[name] end
function FillTypeManager:getFillTypeNameByIndex(index) local d = self.fillTypes[index] return d and d.name or nil end
function FillTypeManager:loadMapData() return true end
function FillTypeManager:unloadMapData() self.fillTypes = {} self.nameToIndex = {} end

-- ── DensityMapHeightManager (densityMaps/DensityMapHeightManager.lua) ─────────
DensityMapHeightManager = {}
local DensityMapHeightManager_mt = { __index = DensityMapHeightManager }
--- The four roster maps the engine creates (:44-46), the type channels (:117-118) and a
--- sorted roster: rows are { fillTypeName, fillTypeIndex }, indexed 1..n in order.
function DensityMapHeightManager.newModel(rows, typeNumChannels)
    local hm = setmetatable({ heightTypes = {}, fillTypeIndexToHeightType = {}, fillTypeNameToHeightType = {}, heightTypeIndexToFillTypeIndex = {},
        numHeightTypes = 0, heightTypeFirstChannel = 0, heightTypeNumChannels = typeNumChannels or 6, initializeCalls = 0 }, DensityMapHeightManager_mt)
    for _, r in ipairs(rows) do
        hm.numHeightTypes = hm.numHeightTypes + 1
        local ht = { index = hm.numHeightTypes, fillTypeName = r[1], fillTypeIndex = r[2], canBeTipped = true, allowsSmoothing = true,
            maxSurfaceAngle = 0.6, collisionScale = 1, collisionBaseOffset = 0, minCollisionOffset = 0, maxCollisionOffset = 1 }
        hm.heightTypes[ht.index] = ht
        hm.fillTypeIndexToHeightType[r[2]] = ht
        hm.fillTypeNameToHeightType[r[1]] = ht
        hm.heightTypeIndexToFillTypeIndex[ht.index] = r[2]
    end
    return hm
end
--- :187: the rows are built sorted.
function DensityMapHeightManager:sortHeightTypes() end
function DensityMapHeightManager:getTerrainDetailHeightUpdater() return self.terrainDetailHeightUpdater end
function DensityMapHeightManager:getDensityMapHeightTypeIndexByFillTypeIndex(fillTypeIndex)
    local ht = self.fillTypeIndexToHeightType[fillTypeIndex]
    return ht ~= nil and ht.index or nil
end
--- :150-164 MODELED: a saved densityMapHeight.xml's tipTypeMappings, lowercase name to
--- index. ENGINE_SAVED_MAPPINGS[path] is the file.
ENGINE_SAVED_MAPPINGS = {}
function DensityMapHeightManager:loadFromXMLFile(xmlFilename)
    local saved = xmlFilename ~= nil and ENGINE_SAVED_MAPPINGS[xmlFilename] or nil
    if saved == nil then return false end
    self.tipTypeMappings = {}
    for name, index in pairs(saved) do self.tipTypeMappings[name] = index end
    return true
end
--- :350-409 MODELED to the Lua effects this bench reads: heightToDensityValue (:373-374,
--- 2^heightNumChannels - 1 over the maximum height), the updater (:382), whether a saved
--- mapping reached it (:386-393 read it) and whether it asks the C side for a type
--- conversion (:398-409: a saved mapping whose names the roster does not use forces one).
function DensityMapHeightManager:initialize(isServer, tipCollisionMap, placementCollisionMap)
    self.initializeCalls = self.initializeCalls + 1
    local maxHeightDensityValue = 2 ^ getDensityMapHeightNumChannels(ENGINE_TERRAIN.id) - 1
    self.heightToDensityValue = maxHeightDensityValue / ENGINE_TERRAIN.maxHeight
    self.terrainDetailHeightUpdater = { name = "TerrainDetailHeightUpdater" }
    self.mappingSeenByNative = self.tipTypeMappings ~= nil and next(self.tipTypeMappings) ~= nil
    local force = false
    if self.tipTypeMappings ~= nil then
        local used, count = 0, 0
        for _, ht in ipairs(self.heightTypes) do
            if self.tipTypeMappings[string.lower(ht.fillTypeName)] ~= nil then used = used + 1 end
        end
        for _ in pairs(self.tipTypeMappings) do count = count + 1 end
        force = count ~= used
    end
    self.forceTypeConversion = force
end

-- ── SnowSystem (environment/SnowSystem.lua) ─────────────────────────────────
ENGINE_SNOW = {}
--- :89-125, the lines that read the height manager's initialize outputs, VERBATIM:
--- :91 (the snow height type), :108 (the layer height) and :109-111 (the server's updater);
--- the density modifiers (:92-107) and the saved snow state (:112-124) abbreviated.
function ENGINE_SNOW.onTerrainLoad(self)
    self.snowHeightTypeIndex = g_densityMapHeightManager:getDensityMapHeightTypeIndexByFillTypeIndex(FillType.SNOW)
    self.layerHeight = 1 / g_densityMapHeightManager.heightToDensityValue
    if self.isServer then
        self.updater = g_densityMapHeightManager.terrainDetailHeightUpdater
        setDensityMapHeightUpdateType(self.updater, self.snowHeightTypeIndex)
    end
end

-- ── the loading screen's targets (gui/MPLoadingScreen.lua) ─────────────────
MPLoadingScreen = { LOAD_TARGETS = { TERRAIN = "TERRAIN" } }
g_mpLoadingScreen = { targets = {} }
function g_mpLoadingScreen:hitLoadingTarget(target) self.targets[#self.targets + 1] = target end

-- ── the terrain load (FSBaseMission.lua) ────────────────────────────────────
--- :1367-1391 MODELED to the steps that touch the height manager, in the engine's order:
--- the saved mapping load and initialize (:1372-1375), the snow system (:1384), and the
--- TERRAIN target (:1391). The fruit, indoor mask, AI, ground type and
--- DensityMapHeightUtil steps between them are abbreviated. A raise here is the terrain
--- i3d callback dying: the target is never hit.
function ENGINE_INIT_TERRAIN(mission)
    mission.terrainDetailHeightId = ENGINE_TERRAIN.id
    if mission.terrainDetailHeightId ~= 0 then
        g_densityMapHeightManager:loadFromXMLFile(mission.missionInfo.densityMapHeightXMLLoad)
        g_densityMapHeightManager:initialize(mission:getIsServer(), 0, 0)
    end
    ENGINE_SNOW.onTerrainLoad(mission.snowSystem)
    g_mpLoadingScreen:hitLoadingTarget(MPLoadingScreen.LOAD_TARGETS.TERRAIN)
end

-- ── the mission's own entry points SG-6 wraps ───────────────────────────────
--- mission00.lua:98: queues the map tasks; the next task reads cancelLoading.
function Mission00.setMissionInfo(mission, missionInfo, missionDynamicInfo)
    mission.missionInfo = missionInfo
    mission.missionDynamicInfo = missionDynamicInfo
    mission.setMissionInfoCalls = (mission.setMissionInfoCalls or 0) + 1
end
--- FSBaseMission.lua:701: the native finished-loading body (it sends
--- BaseMissionFinishedLoadingEvent); counted.
function FSBaseMission.onFinishedLoading(mission)
    mission.nativeFinishedLoading = (mission.nativeFinishedLoading or 0) + 1
    return "native"
end

-- ── the failure presentation's GUI (gui/dialogs/InfoDialog.lua, menu.lua:66) ─────
ENGINE_DIALOGS = {}
ENGINE_TEARDOWNS = 0
InfoDialog = { INSTANCE = {} }
function InfoDialog.show(text, callback, target)
    ENGINE_DIALOGS[#ENGINE_DIALOGS + 1] = text
    if callback ~= nil then callback(target) end
end
function OnInGameMenuMenu() ENGINE_TEARDOWNS = ENGINE_TEARDOWNS + 1 end
g_dedicatedServer = nil

-- The engine's own methods, kept before any mod loads: a bar can tell a wrapped one.
ENGINE_ORIGINALS = { initialize = DensityMapHeightManager.initialize, onFinishedLoading = FSBaseMission.onFinishedLoading, setMissionInfo = Mission00.setMissionInfo }
