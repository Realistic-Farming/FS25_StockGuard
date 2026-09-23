-- SG2-2-engine_model.lua - the engine the SG2-2 station bench runs against.
--
-- NOT A TEST (no _test suffix, so the runner never runs it alone). A test lists it
-- FIRST in its --!load header, so these classes exist before any StockGuard file
-- loads, exactly as the game defines its classes before any mod's source(). That
-- ordering is the point: SGStationAdapter captures its permitted native references
-- at FILE SCOPE, and a bench that defined LoadingStation after the adapter loaded
-- would have to write the baseline by hand, which is the one thing the entry-point
-- bar must never do.
--
-- Bodies marked VERBATIM follow D:\FS25_Decoded\dataS\scripts_decompiled at the
-- cited lines, control flow and arithmetic unchanged. Bodies marked MODELED stand
-- in for decompiled text whose locals collapsed (Storage:getFreeCapacity's empty
-- loops, LoadingStation:addFillLevelToFillableObject's reused names); each says
-- what it resolves and why. Nothing here is StockGuard code.

-- ── engine helpers ─────────────────────────────────────────────────────────
-- utils/Utils.lua:380-402, VERBATIM.
Utils = Utils or {}
function Utils.appendedFunction(oldFunc, newFunc)
    return oldFunc ~= nil and function(...) oldFunc(...) newFunc(...) end or newFunc
end
function Utils.prependedFunction(oldFunc, newFunc)
    return oldFunc ~= nil and function(...) newFunc(...) oldFunc(...) end or newFunc
end
function Utils.overwrittenFunction(oldFunc, newFunc)
    return oldFunc == nil and function(self, ...) return newFunc(self, nil, ...) end
        or function(self, ...) return newFunc(self, oldFunc, ...) end
end

MessageType = MessageType or { LOADING_STATIONS_CHANGED = 101, UNLOADING_STATIONS_CHANGED = 102 }
g_messageCenter = g_messageCenter or { published = {}, publish = function(self, t) self.published[#self.published + 1] = t end }
ToolType = ToolType or { UNDEFINED = 0, TRIGGER = 1, DISCHARGEABLE = 2 }
FillType = FillType or { UNKNOWN = 0 }
printCallstack = printCallstack or function() end
FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15, MAX_FARM_ID = 8, MAX_NUM_FARMS = 8 }
getTimeSec = getTimeSec or function() return 100 end

ENGINE_FT = { WHEAT = 1, BARLEY = 2, GRASS = 4 }
local FT_NAMES = { [1] = "WHEAT", [2] = "BARLEY", [4] = "GRASS" }
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FT_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(FT_NAMES) do if v == n then return i end end return nil end,
}

-- ── Storage (objects/Storage.lua), a metatable class: mechanism 4 ─────────────
Storage = {}
local Storage_mt = { __index = Storage }

--- MODEL CONSTRUCTOR (Storage.new + load read XML; the bench passes the values).
function Storage.newModel(levels, capacity, ownerFarmId)
    local self = setmetatable({ fillLevels = {}, fillTypes = {}, capacities = {}, capacity = capacity or 1000,
        supportsMultipleFillTypes = true, ownerFarmId = ownerFarmId or 1, fillLevelsLastPublished = {},
        fillLevelChangedListeners = {}, isServer = true, setCalls = 0 }, Storage_mt)
    for ft, level in pairs(levels) do
        self.fillTypes[ft] = true
        self.fillLevels[ft] = level
    end
    return self
end
-- :278-286 VERBATIM.
function Storage:getFillLevel(fillType) return self.fillLevels[fillType] or 0 end
function Storage:getFillLevels() return self.fillLevels end
function Storage:getCapacity(fillType) return self.capacities[fillType] or self.capacity end
function Storage:getOwnerFarmId() return self.ownerFarmId end
-- :287-292 control flow VERBATIM: clamp to capacity, early return when the type is
-- unknown or the clamped value equals the current one. (The decompile reuses
-- `oldLevel` for both the clamped and the old value; the flow is what is kept.)
function Storage:setFillLevel(fillLevel, fillType, fillInfo)
    local capacity = self.capacities[fillType] or self.capacity
    local clamped = math.max(0, math.min(fillLevel, capacity))
    if self.fillLevels[fillType] == nil or clamped == self.fillLevels[fillType] then return end
    self.fillLevels[fillType] = clamped
    self.setCalls = self.setCalls + 1
    self.lastFillInfo = fillInfo
end
-- :336-359 MODELED. The decompile shows both used-capacity loops with empty bodies.
-- The shared-capacity branch resolves to capacity minus every held level, the one
-- reading under which the return depends on the loop at all.
function Storage:getFreeCapacity(fillType)
    if self.fillLevels[fillType] == nil then return 0 end
    if self.capacities[fillType] ~= nil then
        return math.max(self.capacities[fillType] - self.fillLevels[fillType], 0)
    end
    local used = 0
    for _, level in pairs(self.fillLevels) do used = used + level end
    return math.max(self.capacity - used, 0)
end
function Storage:empty()
    for ft in pairs(self.fillLevels) do self.fillLevels[ft] = 0 end
end

-- ── LoadingStation (objects/LoadingStation.lua), Class(LoadingStation, Object) ─
LoadingStation = {}
local LoadingStation_mt = { __index = LoadingStation }
function LoadingStation.newModel(customMt)
    return setmetatable({ sourceStorages = {}, hasStoragePerFarm = false }, customMt or LoadingStation_mt)
end
function LoadingStation:addSourceStorage(storage)
    self.sourceStorages[storage] = storage
    return true
end
-- :188-219 MODELED. The decompile collapses three locals into two reused names
-- (`freeCapacity` twice, `object` for the added amount). Kept: the zero/unknown
-- early exits, the vehicle active-farm substitution, availability summed over
-- ACCESSIBLE sources, and the visible pairing `added - self:removeFillLevel(added)`.
-- The conveyor-belt branches are omitted: no bench vehicle has one.
function LoadingStation:addFillLevelToFillableObject(fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
    if fillableObject == nil or fillTypeIndex == FillType.UNKNOWN or fillDelta == 0 or toolType == nil then
        return 0
    end
    local farmId = fillableObject:getOwnerFarmId()
    if fillableObject:isa(Vehicle) then
        farmId = fillableObject:getActiveFarm()
    end
    local availableFillLevel = 0
    for _, sourceStorage in pairs(self.sourceStorages) do
        if self:hasFarmAccessToStorage(farmId, sourceStorage) then
            availableFillLevel = availableFillLevel + (sourceStorage:getFillLevel(fillTypeIndex) or 0)
        end
    end
    local delta = math.min(fillDelta, availableFillLevel)
    if delta == 0 then return 0 end
    delta = math.min(delta, fillableObject:getFillUnitFreeCapacity(fillUnitIndex))
    local added = fillableObject:addFillUnitFillLevel(farmId, fillUnitIndex, delta, fillTypeIndex, toolType, fillInfo)
    return added - self:removeFillLevel(fillTypeIndex, added, farmId)
end
-- :220-234 VERBATIM. The defect: the ORIGINAL fillDelta per source (:226) and the
-- 0.0001 cutoff (:229).
function LoadingStation:removeFillLevel(fillTypeIndex, fillDelta, farmId)
    local remainingDelta = fillDelta
    for _, sourceStorage in pairs(self.sourceStorages) do
        if self:hasFarmAccessToStorage(farmId, sourceStorage) then
            local oldFillLevel = sourceStorage:getFillLevel(fillTypeIndex)
            if oldFillLevel > 0 then
                sourceStorage:setFillLevel(oldFillLevel - fillDelta, fillTypeIndex)
            end
            remainingDelta = remainingDelta - (oldFillLevel - sourceStorage:getFillLevel(fillTypeIndex))
            if remainingDelta < 0.0001 then
                return 0
            end
        end
    end
    return remainingDelta
end
-- :247-252 VERBATIM.
function LoadingStation:hasFarmAccessToStorage(farmId, storage)
    if not self.hasStoragePerFarm then
        return g_currentMission.accessHandler:canFarmAccess(farmId, storage)
    end
    return farmId == storage:getOwnerFarmId()
end

-- ── UnloadingStation (objects/UnloadingStation.lua), Class(UnloadingStation, Object)
UnloadingStation = {}
local UnloadingStation_mt = { __index = UnloadingStation }
function UnloadingStation.newModel(customMt)
    return setmetatable({ targetStorages = {}, hasStoragePerFarm = false, fxCalls = 0, planeCalls = 0 }, customMt or UnloadingStation_mt)
end
function UnloadingStation:addTargetStorage(storage)
    self.targetStorages[storage] = storage
    return true
end
-- :207-209 and :239-241 VERBATIM.
function UnloadingStation:getIsFillTypeAllowed(fillTypeIndex, extraAttributes) return true end
function UnloadingStation:getIsToolTypeAllowed(toolType) return true end
-- :210-218 VERBATIM.
function UnloadingStation:getFreeCapacity(fillTypeIndex, farmId)
    local freeCapacity = 0
    for _, targetStorage in pairs(self.targetStorages) do
        if farmId == nil or self:hasFarmAccessToStorage(farmId, targetStorage) then
            freeCapacity = freeCapacity + targetStorage:getFreeCapacity(fillTypeIndex)
        end
    end
    return freeCapacity
end
-- :242-262 VERBATIM. The defect: the ORIGINAL delta per target (:250) and the
-- rewrite of a total within 0.001 to the request (:254-256).
function UnloadingStation:addFillLevelFromTool(farmId, deltaFillLevel, fillType, fillInfo, toolType, _)
    assert(deltaFillLevel >= 0)
    local movedFillLevel = 0
    if self:getIsFillTypeAllowed(fillType) and self:getIsToolTypeAllowed(toolType) then
        for _, targetStorage in pairs(self.targetStorages) do
            if self:hasFarmAccessToStorage(farmId, targetStorage) then
                if targetStorage:getFreeCapacity(fillType) > 0 then
                    local oldFillLevel = targetStorage:getFillLevel(fillType)
                    targetStorage:setFillLevel(oldFillLevel + deltaFillLevel, fillType, fillInfo)
                    movedFillLevel = movedFillLevel + (targetStorage:getFillLevel(fillType) - oldFillLevel)
                end
                if deltaFillLevel - 0.001 <= movedFillLevel then
                    self:startFx(fillType)
                    movedFillLevel = deltaFillLevel
                    break
                end
            end
        end
    end
    self:activateSimpleFillplanes(fillType)
    return movedFillLevel
end
-- :263-272 and :273-300 MODELED as counters: the bodies are presentation only
-- (fill planes, sound, animation, effects), so the bench counts the calls.
function UnloadingStation:activateSimpleFillplanes(fillTypeIndex) self.planeCalls = self.planeCalls + 1 end
function UnloadingStation:startFx(fillType) self.fxCalls = self.fxCalls + 1 end
-- :305-311 VERBATIM. Unloading passes allowEqual = true; loading does not.
function UnloadingStation:hasFarmAccessToStorage(farmId, storage)
    if not self.hasStoragePerFarm then
        return g_currentMission.accessHandler:canFarmAccess(farmId, storage, true)
    end
    return farmId == storage:getOwnerFarmId()
end

-- ── SellingStation (objects/SellingStation.lua), Class(SellingStation, UnloadingStation)
SellingStation = setmetatable({}, { __index = UnloadingStation })
local SellingStation_mt = { __index = SellingStation }
function SellingStation.newModel(customMt)
    local self = UnloadingStation.newModel(customMt or SellingStation_mt)
    self.missions, self.acceptedFillTypes, self.sold = {}, { [1] = true, [2] = true, [4] = true }, {}
    return self
end
function SellingStation:superClass() return UnloadingStation end
function SellingStation:getIsFillTypeAllowed(fillTypeIndex, _) return self.acceptedFillTypes[fillTypeIndex] and true or false end
function SellingStation:getStoreGoods(farmId, fillTypeIndex) return false end
function SellingStation:getSkipSell(farmId, fillTypeIndex) return false end
function SellingStation:getIsFillAllowedFromFarm(farmId) return true end
-- :305-342 VERBATIM except the final else branch, which the decompile writes as
-- `deltaFillLevel = movedFillLevel` with no such local in scope; it is kept as
-- written (nil) rather than guessed.
function SellingStation:addFillLevelFromTool(farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    if deltaFillLevel > 0 then
        local storeGoods = self:getStoreGoods(farmId, fillTypeIndex)
        local storageAccess = not storeGoods or self:getIsFillAllowedFromFarm(farmId)
        if self:getIsFillTypeAllowed(fillTypeIndex, extraAttributes) and storageAccess then
            local usedMission = nil
            local highestProgress = 0
            local usedByMission = false
            for _, mission in pairs(self.missions) do
                if mission.fillSold ~= nil and (mission.fillTypeIndex == fillTypeIndex and mission.farmId == farmId) then
                    local progress = mission:getCompletion()
                    if highestProgress < progress then
                        usedMission = mission
                        highestProgress = progress
                    end
                end
            end
            if usedMission ~= nil then
                usedMission:fillSold(deltaFillLevel)
                usedByMission = true
            end
            if storeGoods and not usedByMission then
                deltaFillLevel = SellingStation:superClass().addFillLevelFromTool(self, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
            else
                self:startFx(fillTypeIndex)
            end
            if not usedByMission and (not self:getSkipSell(farmId, fillTypeIndex) and deltaFillLevel > 0.001) then
                self:sellFillType(farmId, deltaFillLevel, fillTypeIndex, toolType, extraAttributes)
            end
        else
            deltaFillLevel = 0
        end
        self:activateSimpleFillplanes(fillTypeIndex)
    else
        deltaFillLevel = nil
    end
    return deltaFillLevel
end
-- :349 MODELED: records the sale and returns a price as money (2 per litre). The
-- price body (:356-360) is the market's business, not this bench's.
function SellingStation:sellFillType(farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
    self.sold[#self.sold + 1] = { farmId = farmId, fillDelta = fillDelta, fillTypeIndex = fillTypeIndex, toolType = toolType, extraAttributes = extraAttributes }
    return fillDelta * 2
end
-- :481-483 VERBATIM (the superclass call written out).
function SellingStation:getIsFillAllowedFromFarm(farmId)
    return not self:getStoreGoods(farmId, nil) and true or UnloadingStation.getIsFillAllowedFromFarm(self, farmId)
end
-- UnloadingStation.lua getIsFillAllowedFromFarm VERBATIM.
function UnloadingStation:getIsFillAllowedFromFarm(farmId)
    for _, targetStorage in pairs(self.targetStorages) do
        if self:hasFarmAccessToStorage(farmId, targetStorage) then
            return true
        end
    end
    return false
end

-- ── Dischargeable (vehicles/specializations/Dischargeable.lua) ────────────────
Dischargeable = {}
-- :807-816 VERBATIM: the outer call of every tool-to-station unload.
function Dischargeable:dischargeToObject(dischargeNode, emptyLiters, object, targetFillUnitIndex)
    local fillType, factor = self:getDischargeFillType(dischargeNode)
    local dischargedLiters = 0
    if object:getFillUnitSupportsFillType(targetFillUnitIndex, fillType) and object:getFillUnitAllowsFillType(targetFillUnitIndex, fillType) then
        dischargeNode.currentDischargeObject = object
        local delta = object:addFillUnitFillLevel(self:getActiveFarm(), targetFillUnitIndex, emptyLiters * factor, fillType, dischargeNode.toolType, dischargeNode.info) / factor
        local unloadInfo = self:getFillVolumeUnloadInfo(dischargeNode.unloadInfoIndex)
        dischargedLiters = self:addFillUnitFillLevel(self:getOwnerFarmId(), dischargeNode.fillUnitIndex, -delta, self:getFillUnitFillType(dischargeNode.fillUnitIndex), ToolType.UNDEFINED, unloadInfo)
    end
    return dischargedLiters
end
-- :862-873 VERBATIM: the node's fill type converter.
function Dischargeable:getDischargeFillType(dischargeNode)
    local fillType = self:getFillUnitFillType(dischargeNode.fillUnitIndex)
    local conversionFactor = 1
    if dischargeNode.fillTypeConverter ~= nil then
        local conversion = dischargeNode.fillTypeConverter[fillType]
        if conversion ~= nil then
            fillType = conversion.targetFillTypeIndex
            conversionFactor = conversion.conversionFactor
        end
    end
    return fillType, conversionFactor
end

-- ── StorageSystem (objects/StorageSystem.lua) ────────────────────────────────
StorageSystem = {}
local StorageSystem_mt = { __index = StorageSystem }
function StorageSystem.newModel()
    return setmetatable({ storages = {}, loadingStations = {}, unloadingStations = {}, placeableLoadingStations = {},
        placeableUnloadingStations = {}, extendableLoadingStations = {}, extendableUnloadingStations = {} }, StorageSystem_mt)
end
function StorageSystem:addStorage(storage)
    if storage == nil then return false end
    self.storages[storage] = storage
    return true
end
-- :67-83 VERBATIM.
function StorageSystem:addLoadingStation(station, placeable)
    if station == nil then
        return false
    end
    self.loadingStations[station] = station
    g_messageCenter:publish(MessageType.LOADING_STATIONS_CHANGED)
    if placeable ~= nil then
        if self.placeableLoadingStations[placeable] == nil then
            self.placeableLoadingStations[placeable] = {}
        end
        table.insert(self.placeableLoadingStations[placeable], station)
    end
    if station.supportsExtension then
        self.extendableLoadingStations[station] = station
    end
    return true
end
-- :84-101 VERBATIM.
function StorageSystem:removeLoadingStation(station, placeable)
    if station == nil then
        return false
    end
    self.loadingStations[station] = nil
    self.extendableLoadingStations[station] = nil
    if placeable ~= nil and self.placeableLoadingStations[placeable] ~= nil then
        for k, s in ipairs(self.placeableLoadingStations[placeable]) do
            if station == s then
                table.remove(self.placeableLoadingStations[placeable], k)
            end
        end
        if #self.placeableLoadingStations[placeable] == 0 then
            self.placeableLoadingStations[placeable] = nil
        end
    end
    g_messageCenter:publish(MessageType.LOADING_STATIONS_CHANGED)
    return true
end
-- :162-181 VERBATIM, including the no-placeable branch that has ALREADY inserted
-- the station when it logs and returns false.
function StorageSystem:addUnloadingStation(station, placeable)
    if station == nil then
        return false
    end
    self.unloadingStations[station] = station
    g_messageCenter:publish(MessageType.UNLOADING_STATIONS_CHANGED)
    if placeable == nil then
        Logging.error("StorageSystem:addUnloadingStation(): no placeable given")
        printCallstack()
        return false
    end
    if self.placeableUnloadingStations[placeable] == nil then
        self.placeableUnloadingStations[placeable] = {}
    end
    table.insert(self.placeableUnloadingStations[placeable], station)
    if station.supportsExtension then
        self.extendableUnloadingStations[station] = station
    end
    return true
end
-- :182-198 VERBATIM (ipairs_reverse written out).
function StorageSystem:removeUnloadingStation(station, placeable)
    if station == nil then
        return false
    end
    self.unloadingStations[station] = nil
    self.extendableUnloadingStations[station] = nil
    if placeable ~= nil and self.placeableUnloadingStations[placeable] ~= nil then
        local list = self.placeableUnloadingStations[placeable]
        for k = #list, 1, -1 do
            if station == list[k] then
                table.remove(list, k)
            end
        end
        if #list == 0 then
            self.placeableUnloadingStations[placeable] = nil
        end
    end
    g_messageCenter:publish(MessageType.UNLOADING_STATIONS_CHANGED)
    return true
end

-- ── triggers ────────────────────────────────────────────────────────────────
-- triggers/UnloadTrigger.lua:134-141 VERBATIM, the tool-side entry into a station.
UnloadTrigger = {}
local UnloadTrigger_mt = { __index = UnloadTrigger }
function UnloadTrigger.newModel(target, fillTypeConversions)
    return setmetatable({ target = target, fillTypeConversions = fillTypeConversions or {}, extraAttributes = nil }, UnloadTrigger_mt)
end
-- :144-153 VERBATIM: what a discharging vehicle asks the trigger first.
function UnloadTrigger:getFillUnitSupportsFillType(_, fillType) return self:getIsFillTypeSupported(fillType) end
function UnloadTrigger:getFillUnitAllowsFillType(_, fillType) return self:getIsFillTypeAllowed(fillType) end
function UnloadTrigger:getIsFillTypeAllowed(fillType) return self:getIsFillTypeSupported(fillType) end
-- :154-168 VERBATIM.
function UnloadTrigger:getIsFillTypeSupported(fillType)
    if self.fillTypes ~= nil and not self.fillTypes[fillType] then
        return false
    end
    if self.target ~= nil then
        local conversion = self.fillTypeConversions[fillType]
        if conversion ~= nil then
            fillType = conversion.outgoingFillType
        end
        if not self.target:getIsFillTypeAllowed(fillType, self.extraAttributes) then
            return false
        end
    end
    return true
end
function UnloadTrigger:addFillUnitFillLevel(farmId, _, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, extraAttributes)
    local fillTypeConverison = self.fillTypeConversions[fillTypeIndex]
    if fillTypeConverison == nil then
        return self.target:addFillLevelFromTool(farmId, fillLevelDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes or self.extraAttributes)
    end
    local ratio = fillTypeConverison.ratio
    return self.target:addFillLevelFromTool(farmId, fillLevelDelta * ratio, fillTypeConverison.outgoingFillType, fillPositionData, toolType, extraAttributes or self.extraAttributes) / ratio
end
-- triggers/LoadTrigger.lua:425 VERBATIM, the one line by which a load trigger's
-- update moves material out of its station.
LoadTrigger = {}
function LoadTrigger.fillStep(trigger, delta)
    return trigger.source:addFillLevelToFillableObject(trigger.currentFillableObject, trigger.fillUnitIndex, trigger.selectedFillType, delta, trigger.dischargeInfo, ToolType.TRIGGER)
end

-- ── vehicles, placeables, systems the host's class hooks name ─────────────────
Vehicle = {}
VehicleSystem = {}
function VehicleSystem:addVehicle(vehicle) return true end
function VehicleSystem:removeVehicle(vehicle) return nil end
PlaceableSystem = {}
function PlaceableSystem:removePlaceable(placeable) return nil end

-- ── the load boundary main.lua enters through ────────────────────────────────
Mission00 = { load = function(mission) end, loadMission00Finished = function(mission) end }
FSBaseMission = { delete = function(mission) end, update = function(mission, dt) end, onConnectionClosed = function(mission, connection) end }
g_currentModDirectory = "bench/FS25_StockGuard/"
g_currentModName = "FS25_StockGuard"
ENGINE_SOURCED = {}
function source(path) ENGINE_SOURCED[#ENGINE_SOURCED + 1] = path end
-- SG-6's capacity gate is not what this bench measures: the restore barrier reads a
-- READY controller, as the SG2-1 benches supply it.
StockGuardCapacity = { isReady = function() return true end }
