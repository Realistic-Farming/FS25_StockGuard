-- soil_fixture/soil_world.lua
--
-- Soil's side of SG-3 Part 3's bench (SG3-3-soil_bale_condition_spec_test.lua), beside the VERBATIM copies in this
-- folder: FS25_SoilFertilizer's src/YardLadder.lua and src/MaterialDown.lua at c410ac01 (Soil's
-- feat/SG3-3-yard-ladder-operation-echo, the operation echo this part joins; MaterialDown is unchanged from
-- development 573a3e26) and the provider slice of src/SoilFertilityManager.lua. They run as Soil's code in the
-- engine's table, outside StockGuard's mod environment, as another mod's code does. Refresh the copies with
-- Soil's files.
--
-- What this file adds is only what those copies take from the rest of Soil and the engine:
--   * SoilLogger (src/utils/Logger.lua), silent;
--   * SoilValueMaps' raw constants (SoilValueMaps.lua:151-159) and a value-maps object the store arms on, the
--     engine's storage substrate, which these rows never read;
--   * the engine's id helper Utils.getUniqueId (Utils.lua:98) and entityExists, as Soil's own S7 bench gives
--     them, when the world has none (MaterialDown mints the store's sourceEpoch with the first; the ladder's
--     daily pass asks the second);
--   * Soil's birth door, a stand-in of its shape: BalerCollection wraps the Baler's createBale and, when
--     createBale returns, binds the bale it deferred (src/ground/BalerCollection.lua BC.aroundCreate, then
--     BC.bindBirth, then src/hooks/HookManager.lua baleBirth, then YardLadder:onBaleCreated) with the chamber's
--     collected birth. Soil's own bench drives that door itself (SG3-3-operation_echo_spec_test.lua).

SoilLogger = SoilLogger or { info = function() end, debug = function() end, warning = function() end, error = function() end }
SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
Utils = Utils or {}
if Utils.getUniqueId == nil then
    local n = 0
    Utils.getUniqueId = function(_value, _map, prefix, _len) n = n + 1 return (prefix or "") .. "epoch" .. n end
end

-- The engine's entityExists (a live node exists), as Soil's own S7 bench gives it: YardLadder's daily pass
-- retires a row whose node is gone, and the StockGuard world has no scenegraph to ask.
if entityExists == nil then entityExists = function(node) return node ~= nil end end

SOIL_FIXTURE = {}

--- The value maps MaterialDown:arm checks (SoilValueMaps' SF-43 methods and its package layer).
function SOIL_FIXTURE.valueMaps()
    return { available = true, applyRawDeltaToLayer = function() return nil end, setPolygonWhere = function() return false end,
             hasAnyInBand = function() return nil end, readRawAtWorld = function() return nil end,
             getLayerEntry = function(_, key) return { key = key } end }
end

--- Soil's birth door on one Baler: its createBale wrapped so the bale createBale made is born in the ladder
--- with the chamber's collected wetness, when createBale returns (inside the finish that called it).
function SOIL_FIXTURE.door(vehicle, ladder, wetnessPct)
    local original = vehicle.createBale
    vehicle.createBale = function(self, ...)
        local spec = self.spec_baler
        local count = type(spec.bales) == "table" and #spec.bales or 0
        local r = table.pack(original(self, ...))
        local b = type(spec.bales) == "table" and spec.bales[count + 1] or nil
        local bale = b ~= nil and b.baleObject or nil
        if r[1] and bale ~= nil then
            local name = g_fillTypeManager:getFillTypeNameByIndex(bale:getFillType())
            ladder:onBaleCreated(bale.nodeId, bale, name, bale:getFillLevel(), bale:getOwnerFarmId(), bale:getFillLevel(),
                { collected = true, wetnessPct = wetnessPct })
        end
        return table.unpack(r, 1, r.n)
    end
end
