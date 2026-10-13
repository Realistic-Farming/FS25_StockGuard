-- soil_fixture/SoilBaleConditionProvider.lua
--
-- A VERBATIM SLICE of FS25_SoilFertilizer src/SoilFertilityManager.lua lines 2546-2605 at c410ac01 (Soil's
-- feat/SG3-3-yard-ladder-operation-echo; the section is unchanged from development 573a3e26): F215's
-- limited bale condition provider, the four methods SG-3 reads and binds through, on the manager. The bench
-- publishes a manager carrying them as g_currentMission.soilFertilityManager, Soil's cross-mod handle
-- (SoilFertilizer main.lua:761). Refresh this slice with Soil's file.

SoilFertilityManager = SoilFertilityManager or {}

-- ============================================================
-- [RSF-F215] The limited bale condition provider (SG-3's read and notification join)
-- ============================================================
-- Server-local. Listeners register at trusted server initialization only and are never
-- saved or supplied by a client. Every answer is detached data; exact native unique id
-- binding, never farm, fill type or capacity similarity. With the ground-material family
-- off (Experimental Systems) the capabilities are nil and every read is UNAVAILABLE.

local function yardLadderOf(self)
    local sys = self.soilSystem
    local yl = sys ~= nil and sys.yardLadder or nil
    if yl == nil or type(yl.isArmed) ~= 'function' or not yl:isArmed() then return nil end
    return yl
end

--- @return table|nil  { schema = "SG_SOIL_CONDITION_1", version = 1, ready, portions = true, notifications = true }
function SoilFertilityManager:getBaleConditionCapabilities()
    local yl = yardLadderOf(self)
    if yl == nil then return nil end
    local ok, caps = pcall(yl.getCapabilities, yl)
    if not ok then return nil end
    return caps
end

--- @return table|nil lease, string|nil reason
function SoilFertilityManager:registerBaleConditionListener(listenerId, callbacks)
    local yl = yardLadderOf(self)
    if yl == nil then return nil, "UNAVAILABLE" end
    local ok, lease, why = pcall(yl.registerListener, yl, listenerId, callbacks)
    if not ok then return nil, "ERROR" end
    return lease, why
end

--- @return boolean removed
function SoilFertilityManager:unregisterBaleConditionListener(lease)
    local yl = yardLadderOf(self)
    if yl == nil then return false end
    local ok, removed = pcall(yl.unregisterListener, yl, lease)
    return ok and removed == true
end

--- @return table  { state = READY | RESTORING | UNAVAILABLE, reason, carrierRevision, carrierEventSequence, nativeBaleUniqueId, nativeFillType, actualLitres, portions }
function SoilFertilityManager:getBaleConditionPortions(nativeBaleUniqueId)
    local yl = yardLadderOf(self)
    if yl == nil then return { state = "UNAVAILABLE", reason = "NOT_ARMED", nativeBaleUniqueId = nativeBaleUniqueId, portions = {} } end
    local ok, result = pcall(yl.getConditionPortions, yl, nativeBaleUniqueId)
    if not ok or type(result) ~= 'table' then
        return { state = "UNAVAILABLE", reason = "ERROR", nativeBaleUniqueId = nativeBaleUniqueId, portions = {} }
    end
    return result
end

--- The same-owner compatibility delegate: a bale node resolved to its exact unique id.
function SoilFertilityManager:getConditionPortionsForNode(nodeId)
    local yl = yardLadderOf(self)
    if yl == nil then return { state = "UNAVAILABLE", reason = "NOT_ARMED", portions = {} } end
    local ok, result = pcall(yl.getConditionPortionsForNode, yl, nodeId)
    if not ok or type(result) ~= 'table' then return { state = "UNAVAILABLE", reason = "ERROR", portions = {} } end
    return result
end
