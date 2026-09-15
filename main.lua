-- =========================================================
-- FS25_StockGuard - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- SG-6 native material capacity (core): the controller is created at file
-- load, before any mission exists, and its hooks install once per process
-- so preflight runs at the first Mission00.setMissionInfo action.
--
-- SG-1 foundation: the StockGuard mission handle (material records,
-- registrations, farm-restore coordinator, StateLedger "stockGuard" module
-- or own XML, SITE_V1 binding, NS-7 scoped join or the dedicated fallback,
-- command sessions) is created at Mission00.load and published as
-- g_currentMission.stockGuard; the capacity controller is published on it
-- as stockGuard.capacity. The restore-complete observer is installed on the
-- mission instance after SG-6's class wrapper is already in the chain, so
-- SG-6's conditional overwrite still suppresses the parent call on failure.
--
-- Hot-reload latch (FuelCosts reference): g_currentModDirectory and
-- g_currentModName are nil on a live re-source, so they are latched into
-- module globals on first load, with a g_modsDirectory loose-folder fallback.
-- =========================================================

StockGuardModDirectory = StockGuardModDirectory
    or g_currentModDirectory
    or (g_modsDirectory ~= nil and (g_modsDirectory .. "FS25_StockGuard/") or nil)
StockGuardModName = StockGuardModName or g_currentModName or "FS25_StockGuard"
local modDirectory = StockGuardModDirectory

source(modDirectory .. "src/capacity/SGSha256.lua")
source(modDirectory .. "src/capacity/SGCanonicalProfile.lua")
source(modDirectory .. "src/capacity/SGWireFormats.lua")
source(modDirectory .. "src/capacity/SGCapacity.lua")

source(modDirectory .. "src/core/SGValues.lua")
source(modDirectory .. "src/core/SGRecords.lua")
source(modDirectory .. "src/core/SGRegistry.lua")
source(modDirectory .. "src/core/SGOperations.lua")
source(modDirectory .. "src/core/SGFarmRestore.lua")
source(modDirectory .. "src/core/SGSave.lua")
source(modDirectory .. "src/core/SGSiteBinding.lua")
source(modDirectory .. "src/core/SGViews.lua")
source(modDirectory .. "src/core/SGCommands.lua")
source(modDirectory .. "src/core/SGTransport.lua")
source(modDirectory .. "src/StockGuard.lua")

-- One controller for the process; the unload hook resets it per mission.
StockGuardCapacity = StockGuardCapacity or SGCapacity.new()
SGCapacity.installHooks(StockGuardCapacity)

-- Mission handle first, then the capacity publication on it.
local function onMissionLoad(mission)
    if mission == nil then return end
    local sg = StockGuard.attach(mission)
    if sg ~= nil then
        sg.capacity = StockGuardCapacity
        sg:installFinishedLoadingObserver()
    end
end
if Mission00 ~= nil and Mission00.load ~= nil and not SGCapacity._missionLoadAppended then
    SGCapacity._missionLoadAppended = true   -- once per process, even if this file is re-sourced
    Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
end

local function stockGuardOf(mission)
    local sg = mission ~= nil and mission.stockGuard or nil
    if sg ~= nil and type(sg.onLoadMission00Finished) == "function" then return sg end
    return nil
end

StockGuardHooks = StockGuardHooks or {}
if not StockGuardHooks.installed then
    StockGuardHooks.installed = true
    if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
        Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function(mission)
            local sg = stockGuardOf(mission)
            if sg ~= nil then pcall(sg.onLoadMission00Finished, sg) end
        end)
    end
    if FSBaseMission ~= nil and FSBaseMission.delete ~= nil then
        FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, function(mission)
            local sg = stockGuardOf(mission)
            if sg ~= nil then pcall(sg.delete, sg) end
        end)
    end
    if FSBaseMission ~= nil and FSBaseMission.update ~= nil then
        FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
            local sg = stockGuardOf(mission)
            if sg ~= nil then pcall(sg.publishAllFallback, sg) end
        end)
    end
    if FSBaseMission ~= nil and FSBaseMission.onConnectionClosed ~= nil then
        FSBaseMission.onConnectionClosed = Utils.prependedFunction(FSBaseMission.onConnectionClosed, function(mission, connection, reason)
            local sg = stockGuardOf(mission)
            if sg ~= nil then pcall(sg.onConnectionClosed, sg, connection) end
        end)
    end
    if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function(missionInfo)
            local sg = stockGuardOf(g_currentMission)
            if sg ~= nil then pcall(sg.onSaveToXML, sg, missionInfo) end
        end)
    end
    if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil and g_messageCenter ~= nil and MessageType ~= nil then
        Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function(mission)
            local sg = stockGuardOf(mission)
            if sg == nil or sg.messagesSubscribed then return end
            sg.messagesSubscribed = true
            if MessageType.PLAYER_FARM_CHANGED ~= nil then g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, sg.onPlayerFarmChanged, sg) end
            if MessageType.FARM_DELETED ~= nil then g_messageCenter:subscribe(MessageType.FARM_DELETED, sg.onFarmDeleted, sg) end
        end)
    end
end

if addConsoleCommand ~= nil then
    addConsoleCommand("sgCapacity", "StockGuard - show the material capacity state", "consoleCapacity", StockGuardCapacity)
    function SGCapacity:consoleCapacity()
        local s = self:getState()
        return string.format("StockGuard capacity: phase=%s reason=%s width=%s registered=%s ground=%s/%s flags=%d",
            tostring(s.phase), tostring(s.reasonCode), tostring(s.widthBits), tostring(s.registeredCount),
            tostring(s.groundTypeBits), tostring(s.groundCapacity), s.integrationFlags)
    end
    if not StockGuardHooks.statusCommand then
        StockGuardHooks.statusCommand = true
        function consoleStockGuardStatus()
            local sg = g_currentMission ~= nil and g_currentMission.stockGuard or nil
            if sg == nil then return "StockGuard: no mission handle" end
            local s = sg.getStatus()
            return string.format("StockGuard %s epoch %s server=%s route=%s backend=%s farmPhase=%s staged=%s carriers=%d stocks=%d sites=%s (%s) views=%s adapters=%d properties=%d consumers=%d owners=%d sections=%d",
                s.version, s.epoch, tostring(s.server), s.route, s.backend, s.farmPhase, tostring(s.staged), s.carriers, s.stocks, tostring(s.sites), s.sitesReason,
                tostring(s.viewsReady), s.adapters, s.properties, s.consumers, s.owners, s.sections)
        end
        addConsoleCommand("sgStatus", "StockGuard - show the foundation state (Diagnostic, no private rows)", "consoleStockGuardStatus", nil)
    end
end

print("[StockGuard] loaded (SG-1 foundation " .. tostring(StockGuard.VERSION) .. "; SG-6 capacity core; extender, Realistic Livestock, Montana and realSilo bound; ProductionControl, Pumps N' Hoses, UnlimitedFillTypes and Distribution Redux refused, see SGCapacity.ADAPTERS)")
