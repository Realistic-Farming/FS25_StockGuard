-- =========================================================
-- FS25_StockGuard - EP-1 chemical station: RF_WIP recovery route (pure logic)
-- =========================================================
-- The working chamber is a manual, explicitly admitted recovery source, never
-- an ordinary AI load-and-deliver destination (brief, "physical operation
-- closure"). After native LoadTrigger:load, and again after any reload or
-- recreation, the trigger carries automaticFilling=false,
-- requiresActiveVehicle=true, automaticFillingTimer=0 and autoStart=false.
-- Its LoadingStation keeps aiSupportedFillTypes empty.
--
-- Every increment goes through an SG-4 permit (prepareMaterialAddition) with a
-- positive finite maxCarrierLitres. The wrapper on the station's own
-- addFillLevelToFillableObject validates that permit against the actual
-- fillable object, fill unit and fill type, caps the request to
-- min(source available, receiver free capacity, requested, maxCarrierLitres)
-- before the captured native method runs, and returns zero with no mutation
-- when there is no valid permit. Native seams mirrored:
--   LoadTrigger.lua:137-148 (autoStart, automaticFilling from Platform,
--     requiresActiveVehicle, automaticFillingTimer)
--   LoadingStation.lua:142-166 (aiSupportedFillTypes, getAISupportedFillTypes,
--     getIsFillTypeAISupported)
--   LoadingStation.lua:188 addFillLevelToFillableObject(fillableObject,
--     fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType); the
--     native source cap at :205-213 decompiles collapsed, so the cap is
--     enforced here as well.
-- SG-4 is not built yet; the permit provider is injected, never looked up.
-- =========================================================

ChemicalStationWipRoute = ChemicalStationWipRoute or {}

local WipRoute = ChemicalStationWipRoute

WipRoute.REASON_NO_TRIGGER = "TRIGGER_MISSING"
WipRoute.REASON_FLAGS_WRONG = "TRIGGER_FLAGS_WRONG"
WipRoute.REASON_NO_STATION = "STATION_MISSING"
WipRoute.REASON_AI_ADVERTISED = "AI_ADVERTISED"
WipRoute.REASON_NO_PERMIT = "NO_PERMIT"
WipRoute.REASON_PERMIT_MISMATCH = "PERMIT_MISMATCH"
WipRoute.REASON_PERMIT_INVALID = "PERMIT_INVALID"
WipRoute.REASON_NOTHING_TO_MOVE = "NOTHING_TO_MOVE"
WipRoute.REASON_SOURCE_UNAVAILABLE = "SOURCE_UNAVAILABLE"
WipRoute.REASON_RECEIVER_UNAVAILABLE = "RECEIVER_UNAVAILABLE"
WipRoute.REASON_OK = "PERMITTED"

local function isFinite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- =========================================================
-- LoadTrigger flags
-- =========================================================

--- Assign the WIP trigger's Lua fields after native load (and after any
-- reload/recreation). Returns true when applied, false with reason otherwise.
function WipRoute.applyTriggerFlags(trigger)
    if type(trigger) ~= "table" then
        return false, WipRoute.REASON_NO_TRIGGER
    end
    trigger.automaticFilling = false
    trigger.requiresActiveVehicle = true
    trigger.automaticFillingTimer = 0
    trigger.autoStart = false
    return true, nil
end

--- Verify the flags are exactly as required. Returns ok, reason.
function WipRoute.verifyTriggerFlags(trigger)
    if type(trigger) ~= "table" then
        return false, WipRoute.REASON_NO_TRIGGER
    end
    if trigger.automaticFilling ~= false
        or trigger.requiresActiveVehicle ~= true
        or trigger.automaticFillingTimer ~= 0
        or trigger.autoStart ~= false then
        return false, WipRoute.REASON_FLAGS_WRONG
    end
    return true, nil
end

-- =========================================================
-- AI exclusion
-- =========================================================

--- Empty the station's AI fill-type advertisement. getAISupportedFillTypes then
-- returns an empty table and getIsFillTypeAISupported is false for every type.
function WipRoute.clearAiSupport(station)
    if type(station) ~= "table" then
        return false, WipRoute.REASON_NO_STATION
    end
    station.aiSupportedFillTypes = {}
    return true, nil
end

--- Verify nothing is advertised to AI. Returns ok, reason.
function WipRoute.verifyNoAiSupport(station)
    if type(station) ~= "table" then
        return false, WipRoute.REASON_NO_STATION
    end
    local list = nil
    if type(station.getAISupportedFillTypes) == "function" then
        list = station:getAISupportedFillTypes()
    else
        list = station.aiSupportedFillTypes
    end
    if type(list) ~= "table" then
        return false, WipRoute.REASON_AI_ADVERTISED
    end
    if next(list) ~= nil then
        return false, WipRoute.REASON_AI_ADVERTISED
    end
    return true, nil
end

-- =========================================================
-- Permit cap
-- =========================================================

--- min(source available, receiver free capacity, requested, maxCarrierLitres).
-- Every input must be a finite number; the first three must be >= 0 and
-- maxCarrierLitres must be > 0. Returns litres (0 when nothing may move) and a
-- reason. Never mutates anything.
function WipRoute.permitCap(sourceAvailable, receiverFree, requested, maxCarrierLitres)
    if not isFinite(sourceAvailable) or sourceAvailable < 0 then
        return 0, WipRoute.REASON_SOURCE_UNAVAILABLE
    end
    if not isFinite(receiverFree) or receiverFree < 0 then
        return 0, WipRoute.REASON_RECEIVER_UNAVAILABLE
    end
    if not isFinite(requested) or requested < 0 then
        return 0, WipRoute.REASON_PERMIT_INVALID
    end
    if not isFinite(maxCarrierLitres) or maxCarrierLitres <= 0 then
        return 0, WipRoute.REASON_PERMIT_INVALID
    end
    local litres = math.min(sourceAvailable, receiverFree, requested, maxCarrierLitres)
    if litres <= 0 then
        return 0, WipRoute.REASON_NOTHING_TO_MOVE
    end
    return litres, WipRoute.REASON_OK
end

--- Validate an SG-4 permit against the actual receiver of this increment.
-- permit = { fillableObject, fillUnitIndex, fillTypeIndex, maxCarrierLitres }
-- Returns ok, reason.
function WipRoute.validatePermit(permit, fillableObject, fillUnitIndex, fillTypeIndex)
    if type(permit) ~= "table" then
        return false, WipRoute.REASON_NO_PERMIT
    end
    if permit.fillableObject ~= fillableObject
        or permit.fillUnitIndex ~= fillUnitIndex
        or permit.fillTypeIndex ~= fillTypeIndex then
        return false, WipRoute.REASON_PERMIT_MISMATCH
    end
    if not isFinite(permit.maxCarrierLitres) or permit.maxCarrierLitres <= 0 then
        return false, WipRoute.REASON_PERMIT_INVALID
    end
    return true, nil
end

-- =========================================================
-- Station wrapper
-- =========================================================

--- Sum of the station's source storages' actual level for a fill type.
-- A non-finite or negative reading makes the source unavailable (nil).
local function readSourceAvailable(station, fillTypeIndex)
    local total = 0
    local sources = station.sourceStorages
    if type(sources) ~= "table" then
        return nil
    end
    for _, storage in pairs(sources) do
        if type(storage.getFillLevel) ~= "function" then
            return nil
        end
        local level = storage:getFillLevel(fillTypeIndex)
        if not isFinite(level) or level < 0 then
            return nil
        end
        total = total + level
    end
    return total
end

--- Actual free capacity of the receiver's fill unit, or nil when unreadable.
local function readReceiverFree(fillableObject, fillUnitIndex)
    if type(fillableObject) ~= "table" or type(fillableObject.getFillUnitFreeCapacity) ~= "function" then
        return nil
    end
    local free = fillableObject:getFillUnitFreeCapacity(fillUnitIndex)
    if not isFinite(free) or free < 0 then
        return nil
    end
    return free
end

--- Install the permit wrapper on one station instance. permitProvider is the
-- injected SG-4 seam: permitProvider:prepareMaterialAddition(request) returns a
-- permit table (see validatePermit) or nil. request = { station, fillableObject,
-- fillUnitIndex, fillTypeIndex, requested }.
-- The wrapper caps fillDelta before the captured native method runs and returns
-- 0 without calling it when there is no valid permit or nothing may move.
-- Returns ok, reason. Installing twice keeps the first captured native method.
function WipRoute.installPermitWrapper(station, permitProvider)
    if type(station) ~= "table" or type(station.addFillLevelToFillableObject) ~= "function" then
        return false, WipRoute.REASON_NO_STATION
    end
    if type(permitProvider) ~= "table" or type(permitProvider.prepareMaterialAddition) ~= "function" then
        return false, WipRoute.REASON_NO_PERMIT
    end
    if station._sgWipNative ~= nil then
        station._sgWipPermitProvider = permitProvider
        return true, nil
    end

    local native = station.addFillLevelToFillableObject
    station._sgWipNative = native
    station._sgWipPermitProvider = permitProvider
    station._sgWipLastReason = nil

    station.addFillLevelToFillableObject = function(self, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
        local provider = self._sgWipPermitProvider
        local permit = nil
        if provider ~= nil then
            permit = provider:prepareMaterialAddition({
                station = self,
                fillableObject = fillableObject,
                fillUnitIndex = fillUnitIndex,
                fillTypeIndex = fillTypeIndex,
                requested = fillDelta,
            })
        end
        local ok, reason = WipRoute.validatePermit(permit, fillableObject, fillUnitIndex, fillTypeIndex)
        if not ok then
            self._sgWipLastReason = reason
            return 0
        end

        local sourceAvailable = readSourceAvailable(self, fillTypeIndex)
        if sourceAvailable == nil then
            self._sgWipLastReason = WipRoute.REASON_SOURCE_UNAVAILABLE
            return 0
        end
        local receiverFree = readReceiverFree(fillableObject, fillUnitIndex)
        if receiverFree == nil then
            self._sgWipLastReason = WipRoute.REASON_RECEIVER_UNAVAILABLE
            return 0
        end

        local litres, capReason = WipRoute.permitCap(sourceAvailable, receiverFree, fillDelta, permit.maxCarrierLitres)
        self._sgWipLastReason = capReason
        if litres <= 0 then
            return 0
        end
        return native(self, fillableObject, fillUnitIndex, fillTypeIndex, litres, fillInfo, toolType)
    end
    return true, nil
end

--- Last refusal or permit reason recorded by the wrapper on this station.
function WipRoute.getLastReason(station)
    if type(station) ~= "table" then
        return nil
    end
    return station._sgWipLastReason
end
