-- SG2-4a-savegame_model.lua - the native save path, MODELED for the SG2-4a bench.
--
-- Loaded after SG2-2-engine_model.lua and SG2-3-engine_model.lua, in the REAL global
-- table (the runner's --!env: modenv switch comes after the tools/ models), exactly
-- where the engine's own scripts and C functions live.
--
-- SavegameController (SavegameController.lua, byte-identical in 1.21.1.0 and 1.24.0.0):
--   :328-333 addSaveTask and :334-343 executeSaveTask VERBATIM for the density-map task
--   (the other task kinds are not modeled); :366-372 onSaveTaskComplete VERBATIM;
--   :373-436 onSaveStartComplete with the career XML call (:384), the fruit and haulm
--   branch (:392-423) and the height branch (:556-568) VERBATIM, then executeSaveTask
--   (:588-595); the weed, info-layer, navigation, growth, snow, split-shape, collision,
--   occluder and metadata writes between them are OMITTED (none touches the career
--   chain or the height map); :672-690 onSaveComplete with its directory and callback;
--   :700-727 saveSavegame reduced to the state it sets and its start call.
-- FSCareerMissionInfo (FSCareerMissionInfo.lua): :425-431 setSavegameDirectory and a
--   saveToXMLFile that writes careerSavegame.xml and, as :348 does, the vehicles file
--   through the vehicle save of SG2-3's model.
-- C functions, MODELED: saveWriteSavegameStart calls the named callback with a staging
--   directory; saveWriteSavegameFinish moves every staged file to the final directory
--   and then calls the named callback with the final directory (a later frame, unless
--   ENGINE_SAVE.finishSync); prepareSaveDensityMapToFile captures a map's CURRENT image
--   version, savePreparedDensityMapToFile writes the captured one and completes on a
--   later frame, saveDensityMapToFile writes the current one directly. Each map carries
--   a version the bench bumps to change the world, so the disk shows WHICH moment's
--   image was written.
-- g_asyncTaskManager, MODELED: one task per frame; ENGINE_RUN_FRAMES runs the queue,
--   calling an optional between-frames hook (the world moving on while a nonblocking
--   save is queued).

Savegame = Savegame or {}
Savegame.ERROR_OK = 0
Savegame.ERROR_WRITE = 7

-- ── the density maps ────────────────────────────────────────────────────────────
ENGINE_HEIGHT_ID = 900
ENGINE_MAPS = {
    [1] = { filename = "densityMap_fruits.gdm", version = 1 },
    [3] = { filename = "densityMap_grass.gdm", version = 1 },
    [4] = { filename = "densityMap_grassHaulm.gdm", version = 1 },
    [ENGINE_HEIGHT_ID] = { filename = "densityMap_height.gdm", version = 1, heightFirstChannel = 6, heightNumChannels = 6 },
}
function getDensityMapFilename(id) local m = ENGINE_MAPS[id] return m ~= nil and m.filename or nil end
function getDensityMapHeightFirstChannel(id) return ENGINE_MAPS[id].heightFirstChannel end
function getDensityMapHeightNumChannels(id) return ENGINE_MAPS[id].heightNumChannels end
g_densityMapHeightManager = g_densityMapHeightManager or {}
g_densityMapHeightManager.heightTypeFirstChannel = 0
g_densityMapHeightManager.heightTypeNumChannels = 6

--- A third fruit with its own plane and haulm, beside SG2-3's two fruits that share
--- plane 1, so the controller's set has fruit, haulm and height files.
ENGINE_GRASS_DESC = { index = 20, name = "GRASS", terrainDataPlaneId = 3, terrainDataPlaneIdHaulm = 4 }
function g_fruitTypeManager:getFruitTypes()
    return { self:getFruitTypeByIndex(FruitType.WHEAT), self:getFruitTypeByIndex(FruitType.BARLEY), ENGINE_GRASS_DESC }
end

ENGINE_PREPARED = {}      -- mapId -> { version, path } (the C side's one prepared image)
ENGINE_PREPARE_LOG = {}   -- every native prepare call reaching the C function
ENGINE_DIRECT_LOG = {}
function prepareSaveDensityMapToFile(id, path)
    ENGINE_PREPARE_LOG[#ENGINE_PREPARE_LOG + 1] = { id = id, path = path, version = ENGINE_MAPS[id].version }
    ENGINE_PREPARED[id] = { version = ENGINE_MAPS[id].version, path = path }
end
function saveDensityMapToFile(id, path)
    ENGINE_DIRECT_LOG[#ENGINE_DIRECT_LOG + 1] = { id = id, path = path, version = ENGINE_MAPS[id].version }
    ENGINE_DISK[path] = { image = id, version = ENGINE_MAPS[id].version }
end
function savePreparedDensityMapToFile(id, callbackName, target)
    local p = ENGINE_PREPARED[id]
    if p ~= nil then
        ENGINE_DISK[p.path] = { image = id, version = p.version }
        ENGINE_PREPARED[id] = nil
    end
    g_asyncTaskManager:addTask(function() target[callbackName](target, true) end)
end

-- ── the async task manager ──────────────────────────────────────────────────────
g_asyncTaskManager = { tasks = {} }
function g_asyncTaskManager:addTask(fn) self.tasks[#self.tasks + 1] = fn end
function g_asyncTaskManager:setAllowedTimePerFrame(_) end
--- Run queued tasks one per frame; `between(frame)` runs before each frame's task.
function ENGINE_RUN_FRAMES(between, limit)
    local frame = 0
    while #g_asyncTaskManager.tasks > 0 and frame < (limit or 1000) do
        frame = frame + 1
        if between ~= nil then between(frame) end
        local fn = table.remove(g_asyncTaskManager.tasks, 1)
        fn()
    end
    return frame
end

-- ── the savegame C functions ────────────────────────────────────────────────────
ENGINE_SAVE = { stagingPrefix = "staging", finalDir = nil, startError = nil, finishError = nil, errorAfterMove = false, finishSync = false, moved = 0 }
function saveWriteSavegameStart(index, _name, _maxSize, callbackName, target)
    local staging = ENGINE_SAVE.stagingPrefix .. tostring(index)
    target[callbackName](target, ENGINE_SAVE.startError or Savegame.ERROR_OK, ENGINE_SAVE.startError == nil and staging or nil)
end
local function moveStaged(staging, final)
    local moves = {}
    for path, data in pairs(ENGINE_DISK) do
        if path:sub(1, #staging + 1) == staging .. "/" then moves[path] = data end
    end
    for path, data in pairs(moves) do
        ENGINE_DISK[final .. path:sub(#staging + 1)] = data
        ENGINE_DISK[path] = nil
        ENGINE_SAVE.moved = ENGINE_SAVE.moved + 1
    end
end
function saveWriteSavegameFinish(_metadata, _desc, callbackName, target)
    local savegame = target.currentSavegame
    local staging = savegame.savegameDirectory
    local final = ENGINE_SAVE.finalDir
    local errorCode = ENGINE_SAVE.finishError or Savegame.ERROR_OK
    -- ENGINE_SAVE.errorAfterMove: the files reached the final directory and an error is
    -- still reported with it (the bench's hardest failure for a completion marker).
    local moved = errorCode == Savegame.ERROR_OK or ENGINE_SAVE.errorAfterMove == true
    local function complete()
        if moved then moveStaged(staging, final) end
        target[callbackName](target, errorCode, moved and final or nil)
    end
    if ENGINE_SAVE.finishSync then complete() else g_asyncTaskManager:addTask(complete) end
end
function startFrameRepeatMode() return false end
function endFrameRepeatMode() end

-- ── FSCareerMissionInfo (the career save) ──────────────────────────────────────
FSCareerMissionInfo = FSCareerMissionInfo or {}
FSCareerMissionInfo.__index = FSCareerMissionInfo
function FSCareerMissionInfo.new(fields)
    local self = setmetatable(fields or {}, FSCareerMissionInfo)
    return self
end
--- :425-431: the directory and the per-file paths under it.
function FSCareerMissionInfo:setSavegameDirectory(directory)
    self.savegameDirectory = directory
    if directory ~= nil then self.vehiclesXML = directory .. "/vehicles.xml" end
end
--- :246-409 MODELED: careerSavegame.xml, then the vehicles (:348) through the engine's
--- vehicle save. ENGINE_CAREER_HOOK, when set, runs in the middle of the chain (after
--- the vehicles), standing in for any code the chain reaches there.
ENGINE_CAREER_HOOK = nil
ENGINE_CAREER_CALLS = 0
function FSCareerMissionInfo:saveToXMLFile()
    ENGINE_CAREER_CALLS = ENGINE_CAREER_CALLS + 1
    ENGINE_DISK[self.savegameDirectory .. "/careerSavegame.xml"] = { mapId = self.mapId, heightVersion = ENGINE_MAPS[ENGINE_HEIGHT_ID].version }
    local mission = g_currentMission
    local xml = XMLFile.create("vehiclesXML", self.vehiclesXML, "vehicles", Vehicle.xmlSchemaSavegame)
    for i, v in ipairs(mission ~= nil and mission._vehicles or {}) do
        if v.specializationNames ~= nil then ENGINE_SAVE_VEHICLE(v, xml, string.format("vehicles.vehicle(%d)", i - 1), {}) end
    end
    xml:save()
    if ENGINE_CAREER_HOOK ~= nil then ENGINE_CAREER_HOOK(self) end
end

-- ── SavegameController ──────────────────────────────────────────────────────────
SavegameController = SavegameController or {}
SavegameController.__index = SavegameController
SavegameController.SAVE_TASK_DENSITY_MAP = 0
function SavegameController.new()
    local self = setmetatable({}, SavegameController)
    self.isSavingGame = false
    self.savingErrorCode = Savegame.ERROR_OK
    self.completed = {}
    self.onSaveCompleteCallback = function(target, errorCode) target.completed[#target.completed + 1] = errorCode end
    self.onSaveCompleteCallbackTarget = self
    return self
end
--- :700-727, reduced.
function SavegameController:saveSavegame(savegame, blocking)
    self.isSavingGame = true
    self.isSavingBlocking = blocking
    self.currentSavegame = savegame
    saveWriteSavegameStart(savegame.savegameIndex, savegame.savegameName, 0, "onSaveStartComplete", self)
end
--- :328-333 VERBATIM.
function SavegameController:addSaveTask(taskType, taskParam)
    table.insert(self.saveTasks, {
        ["type"] = taskType,
        ["param"] = taskParam
    })
end
--- :334-343 VERBATIM (the density-map task).
function SavegameController:executeSaveTask()
    if self.currentSaveTask > #self.saveTasks then
        self:onSaveTaskComplete(true)
        return
    else
        local taskData = self.saveTasks[self.currentSaveTask]
        self.currentSaveTask = self.currentSaveTask + 1
        if taskData.type == SavegameController.SAVE_TASK_DENSITY_MAP then
            savePreparedDensityMapToFile(taskData.param, "onSaveTaskComplete", self)
            return
        end
    end
end
--- :366-372 VERBATIM.
function SavegameController:onSaveTaskComplete(_)
    if self.currentSaveTask > #self.saveTasks then
        saveWriteSavegameFinish(self.savegameMetadata, self.savegameDisplayDesc, "onSaveComplete", self)
    else
        self:executeSaveTask()
    end
end
--- :373-436, the modeled branches VERBATIM (ENGINE_START_CALLS is the bench's count).
ENGINE_START_CALLS = 0
function SavegameController:onSaveStartComplete(errorCode, savegameDirectory)
    ENGINE_START_CALLS = ENGINE_START_CALLS + 1
    self.savingErrorCode = errorCode
    if errorCode == Savegame.ERROR_OK and savegameDirectory ~= nil then
        local startedRepeat = false
        if self.isSavingBlocking then
            startedRepeat = startFrameRepeatMode()
        end
        self.saveTasks = {}
        self.currentSaveTask = 1
        local savegame = self.currentSavegame
        savegame:setSavegameDirectory(savegameDirectory)
        savegame:saveToXMLFile()
        local dir = savegame.savegameDirectory
        local savedDensityMaps = {}
        for _, fruitTypeDesc in pairs(g_fruitTypeManager:getFruitTypes()) do
            local id = fruitTypeDesc.terrainDataPlaneId
            local haulmId = fruitTypeDesc.terrainDataPlaneIdHaulm
            if id ~= nil then
                local filename = getDensityMapFilename(id)
                if savedDensityMaps[filename] == nil then
                    savedDensityMaps[filename] = true
                    if self.isSavingBlocking then
                        saveDensityMapToFile(id, dir .. "/" .. filename)
                    else
                        g_asyncTaskManager:addTask(function()
                            prepareSaveDensityMapToFile(id, dir .. "/" .. filename)
                            self:addSaveTask(SavegameController.SAVE_TASK_DENSITY_MAP, id)
                        end)
                    end
                end
            end
            if haulmId ~= nil then
                local filename = getDensityMapFilename(haulmId)
                if savedDensityMaps[filename] == nil then
                    savedDensityMaps[filename] = true
                    if self.isSavingBlocking then
                        saveDensityMapToFile(haulmId, dir .. "/" .. filename)
                    else
                        g_asyncTaskManager:addTask(function()
                            prepareSaveDensityMapToFile(haulmId, dir .. "/" .. filename)
                            self:addSaveTask(SavegameController.SAVE_TASK_DENSITY_MAP, haulmId)
                        end)
                    end
                end
            end
        end
        local heightFilename = getDensityMapFilename(g_currentMission.terrainDetailHeightId)
        if heightFilename ~= nil and savedDensityMaps[heightFilename] == nil then
            savedDensityMaps[heightFilename] = true
            if self.isSavingBlocking then
                saveDensityMapToFile(g_currentMission.terrainDetailHeightId, dir .. "/" .. heightFilename)
            else
                g_asyncTaskManager:addTask(function()
                    prepareSaveDensityMapToFile(g_currentMission.terrainDetailHeightId, dir .. "/" .. heightFilename)
                    self:addSaveTask(SavegameController.SAVE_TASK_DENSITY_MAP, g_currentMission.terrainDetailHeightId)
                end)
            end
        end
        if self.isSavingBlocking then
            self:executeSaveTask()
        else
            g_asyncTaskManager:addTask(function()
                self:executeSaveTask()
            end)
        end
        if startedRepeat then
            endFrameRepeatMode()
            return
        end
    else
        self:onSaveComplete(errorCode)
    end
end
--- :672-690, reduced to the state, the directory and the callback.
function SavegameController:onSaveComplete(errorCode, finalSavegameDirectory)
    self.savingErrorCode = errorCode
    self.isSavingGame = false
    local savegame = self.currentSavegame
    if savegame ~= nil and finalSavegameDirectory ~= nil and finalSavegameDirectory ~= "" then
        savegame:setSavegameDirectory(finalSavegameDirectory)
    end
    self.onSaveCompleteCallback(self.onSaveCompleteCallbackTarget, errorCode)
end
