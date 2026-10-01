-- SG-187-reload_model.lua - the engine methods StockGuard hooks that the SG2 models leave out,
-- for the reload bench (MAINTENANCE row 187).
--
-- NOT A TEST. A bar lists it after SG2-4a-savegame_model.lua and before any StockGuard file,
-- so main.lua's first load finds these classes, as the game defines them before a mod is
-- sourced. Every body is MODELED: it counts its calls in ENGINE_NATIVE_CALLS, so a bar can
-- say how many times a native ran under StockGuard's hooks. ENGINE_NATIVES keeps each
-- method as the engine defined it, before any mod wrapped it.

ENGINE_NATIVE_CALLS = {}
local function counted(name, body)
    return function(...)
        ENGINE_NATIVE_CALLS[name] = (ENGINE_NATIVE_CALLS[name] or 0) + 1
        if body ~= nil then return body(...) end
    end
end

-- FillTypeManager (SGCapacity.installHooks: the sizing guard and the epoch hooks).
FillTypeManager = FillTypeManager or {}
FillTypeManager.SEND_NUM_BITS = FillTypeManager.SEND_NUM_BITS or 8
FillTypeManager.addFillType = counted("FillTypeManager.addFillType", function(self, desc)
    self.fillTypes = self.fillTypes or {}
    self.fillTypes[#self.fillTypes + 1] = desc
    return true
end)
FillTypeManager.loadMapData = counted("FillTypeManager.loadMapData")
FillTypeManager.unloadMapData = counted("FillTypeManager.unloadMapData")

-- FarmManager (SGFarmRestore.installHooks).
FarmManager.mergeFarmsForSingleplayer = counted("FarmManager.mergeFarmsForSingleplayer")
FarmManager.loadDefaults = counted("FarmManager.loadDefaults")

-- BaseMissionFinishedLoadingEvent (events/BaseMissionFinishedLoadingEvent.lua:16-28; the
-- capacity hook adds its header after the native fields).
BaseMissionFinishedLoadingEvent = BaseMissionFinishedLoadingEvent or {}
BaseMissionFinishedLoadingEvent.writeStream = counted("BaseMissionFinishedLoadingEvent.writeStream")
BaseMissionFinishedLoadingEvent.readStream = counted("BaseMissionFinishedLoadingEvent.readStream")

-- The three stream pairs SGWireFormats replaces (inactive, they call the native).
SellingStation = SellingStation or {}
ProductionPoint = ProductionPoint or {}
for _, pair in ipairs({ { SellingStation, "SellingStation", { "readStream", "writeStream", "readUpdateStream", "writeUpdateStream" } },
                        { ProductionPoint, "ProductionPoint", { "readStream", "writeStream" } },
                        { Storage, "Storage", { "readStream", "writeStream", "readUpdateStream", "writeUpdateStream" } } }) do
    for _, method in ipairs(pair[3]) do pair[1][method] = counted(pair[2] .. "." .. method) end
end

ENGINE_NATIVES = {
    addFillType = FillTypeManager.addFillType,
    loadDefaults = FarmManager.loadDefaults,
    finishedWrite = BaseMissionFinishedLoadingEvent.writeStream,
    storageWrite = Storage.writeStream,
    sellingWrite = SellingStation.writeStream,
    productionWrite = ProductionPoint.writeStream,
    load = Mission00.load,
    update = FSBaseMission.update,
    addVehicle = VehicleSystem.addVehicle,
    setFillLevel = Storage.setFillLevel,
}

--- A new map load builds a new Dischargeable (Dischargeable.lua:2; SpecializationManager.lua:86
--- from MPLoadingScreen.lua:352 and :480): the same methods as new function values.
function ENGINE_RESOURCE_DISCHARGEABLE()
    local fresh = {}
    for k, v in pairs(Dischargeable) do
        if type(v) == "function" then
            local f = v
            fresh[k] = function(...) return f(...) end
        else
            fresh[k] = v
        end
    end
    Dischargeable = fresh
end
