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

-- SG2-1 native kernel: operation context, captured work-area installer, Storage
-- brackets, FillUnit observer, the Storage and FillUnit carrier adapters and the
-- server host that wires them to the mission handle.
source(modDirectory .. "src/native/SGOperationContext.lua")
source(modDirectory .. "src/native/SGWorkAreaInstaller.lua")
source(modDirectory .. "src/native/SGStorageBracket.lua")
source(modDirectory .. "src/native/SGFillUnitObserver.lua")
source(modDirectory .. "src/native/SGNativeAdapters.lua")
source(modDirectory .. "src/native/SGStationAdapter.lua")
source(modDirectory .. "src/native/SGNativeHost.lua")

-- EP-1 chemical station: role slots, the operator address, the WIP transfer route
-- and the sale gate. These four shipped in the zip but were never sourced, so the
-- globals did not exist in game and nothing could reach them. They are pure Lua
-- tables of functions with no load-time engine calls and no dependency on each
-- other, so this only makes the globals exist; no caller is wired up here.
source(modDirectory .. "src/placeables/ChemicalStationRoles.lua")
source(modDirectory .. "src/placeables/ChemicalStationAddress.lua")
source(modDirectory .. "src/placeables/ChemicalStationWipRoute.lua")
source(modDirectory .. "src/placeables/ChemicalStationSaleGate.lua")

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
    if StockGuard == nil or type(StockGuard.hostOf) ~= "function" then return nil end
    return StockGuard.hostOf(mission)
end

--- SG2-1: the native kernel host, server only. Adapters register before the
--- restore-complete barrier, which enumerates them; the class hooks install once
--- per process and dispatch to the current host.
local function installNativeKernel(mission)
    if mission == nil or mission.stockGuard == nil or type(mission.getIsServer) ~= "function" or not mission:getIsServer() then return end
    SGNativeHost.installClassHooks({ Storage = Storage, StorageSystem = StorageSystem, PlaceableSystem = PlaceableSystem, VehicleSystem = VehicleSystem })
    local host = SGNativeHost.new(mission.stockGuard, {
        placeables = function() return mission.placeableSystem ~= nil and mission.placeableSystem.placeables or {} end,
        vehicles = function() return mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles or {} end,
        storageSystem = function() return mission.storageSystem end,
    })
    local ok, why = host:install()
    print("[StockGuard] native kernel " .. (ok and "installed: Storage and FillUnit adapters registered" or ("not installed: " .. tostring(why))))
end

StockGuardHooks = StockGuardHooks or {}
if not StockGuardHooks.installed then
    StockGuardHooks.installed = true
    if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
        Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function(mission)
            local sg = stockGuardOf(mission)
            if sg ~= nil then
                pcall(sg.onLoadMission00Finished, sg)
                local ok, err = pcall(installNativeKernel, mission)
                if not ok then print("[StockGuard] native kernel install failed: " .. tostring(err)) end
            end
        end)
    end
    if FSBaseMission ~= nil and FSBaseMission.delete ~= nil then
        FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, function(mission)
            if SGNativeHost ~= nil and SGNativeHost.current ~= nil then pcall(SGNativeHost.current.teardown, SGNativeHost.current) end
            local sg = stockGuardOf(mission)
            if sg ~= nil then pcall(sg.delete, sg) end
        end)
    end
    if FSBaseMission ~= nil and FSBaseMission.update ~= nil then
        FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
            local sg = stockGuardOf(mission)
            if sg ~= nil then pcall(sg.update, sg, dt) end
            if SGNativeHost ~= nil and SGNativeHost.current ~= nil and sg ~= nil then pcall(SGNativeHost.current.update, SGNativeHost.current, dt) end
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
