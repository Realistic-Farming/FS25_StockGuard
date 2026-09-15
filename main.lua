-- =========================================================
-- FS25_StockGuard - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- SG-6 native material capacity (core) lands here first: the controller is
-- created at file load, before any mission exists, and its hooks install
-- once per process so preflight runs at the first Mission00.setMissionInfo
-- action. The SG-1 foundation (material records, StateLedger registration,
-- NS-7 scoped delivery join, mission handle publication) lands on its own
-- branch; when it creates g_currentMission.stockGuard the same controller
-- is published there as stockGuard.capacity.
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

-- One controller for the process; the unload hook resets it per mission.
StockGuardCapacity = StockGuardCapacity or SGCapacity.new()
SGCapacity.installHooks(StockGuardCapacity)

local function onMissionLoad(mission)
    if mission ~= nil and mission.stockGuard ~= nil then
        mission.stockGuard.capacity = StockGuardCapacity
    end
end
if Mission00 ~= nil and Mission00.load ~= nil then
    Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
end

if addConsoleCommand ~= nil then
    addConsoleCommand("sgCapacity", "StockGuard - show the material capacity state", "consoleCapacity", StockGuardCapacity)
    function SGCapacity:consoleCapacity()
        local s = self:getState()
        return string.format("StockGuard capacity: phase=%s reason=%s width=%s registered=%s ground=%s/%s flags=%d",
            tostring(s.phase), tostring(s.reasonCode), tostring(s.widthBits), tostring(s.registeredCount),
            tostring(s.groundTypeBits), tostring(s.groundCapacity), s.integrationFlags)
    end
end

print("[StockGuard] loaded (SG-6 capacity core; adapters unbound, see SGCapacity.UNBOUND_ADAPTERS)")
