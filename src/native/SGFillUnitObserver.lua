-- =========================================================
-- FS25_StockGuard - generic FillUnit observer (SG2-1 kernel)
-- =========================================================
-- Observes accepted fill-unit movement on a vehicle: how much the engine actually
-- took or gave, not how much was asked for.
--
-- MECHANISM 2: INSTANCE COPY, AND IT IS THE EXACT MIRROR OF THE WORK-AREA SLOT.
-- addFillUnitFillLevel, setFillUnitFillType and emptyAllFillUnits are registered
-- with SpecializationUtil.registerFunction (FillUnit.lua:197, :183, :215), which
-- writes objectType.functions[name]. Vehicle.copyTypeFunctionsInto then copies
-- each onto the INSTANCE (SpecializationUtil.lua:141), before onPreLoad. The
-- engine calls them as self:fn(...), so they resolve through the INSTANCE at call
-- time.
--
-- So here the instance copy is the LIVE target and wrapping it is correct, which
-- is precisely the thing that is dead for a work area. And a class-table wrap
-- works only before the vehicle type registers; at mission load that has already
-- happened, so it would reach nothing. Knowing mechanism 1 does not protect
-- against getting this one backwards, which is why both are spelled out.
--
-- THE RETURN IS THE EVIDENCE, AND IT IS NOT THE REQUEST.
-- addFillUnitFillLevel(farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex,
-- toolType, fillPositionData) returns the ACCEPTED delta (FillUnit.lua:1103). It
-- has at least five early `return 0` paths before any material moves: a negative
-- delta without farm access (:1106), a dynamic mount whose owner lacks access
-- (:1109-1113), an unknown fill unit (:1116), a positive delta refused by the
-- trailer fill limit (:1119), and an unsupported tool/fill type pair (:1122).
--
-- So the requested delta must never be recorded as movement. The brief names this
-- directly: do not equate a requested transfer, a native representation alias or a
-- returning wrapper scalar with a second physical quantity. We record the return.
--
-- Coordinates verified against D:\FS25_Decoded this session, per 19a57b9.
--
-- WHAT THIS DOES NOT USE. onFillUnitFillLevelChanged is a registerEvent
-- (FillUnit.lua:148), so it is mechanism 3 and would be reachable on the spec
-- table with no timing constraint at all, which makes it tempting. It is the wrong
-- source: it is a notification AFTER the fact, the level has already moved, and it
-- does not carry the operation that moved it. This observer needs the cause, so it
-- brackets the call rather than listening for its echo.

SGFillUnitObserver = SGFillUnitObserver or {}
local O = SGFillUnitObserver

O.MARKER = "_sgFillUnitObserved"

O.CAUSE_ADD        = "ADD_FILL_LEVEL"
O.CAUSE_TYPE       = "SET_FILL_TYPE"
O.CAUSE_EMPTY_ALL  = "EMPTY_ALL"

local function packn(...)
    return select("#", ...), { ... }
end

--- Install the observer on one vehicle's instance copies.
---
--- Idempotent per vehicle through a marker, so a second sweep or a re-entrant
--- spawn hook cannot stack two observers and count one movement twice.
---
---@param vehicle table          after its load has finished
---@param onMovement function|nil  (vehicle, fillUnitIndex, acceptedDelta, fillTypeIndex, cause)
---@return boolean installed, string|nil why
function O.install(vehicle, onMovement)
    if g_server == nil then return false, "CLIENT" end
    if type(vehicle) ~= "table" then return false, "NO_VEHICLE" end
    if vehicle.spec_fillUnit == nil then return false, "NO_FILLUNIT_SPEC" end
    if vehicle[O.MARKER] ~= nil then return false, "ALREADY_INSTALLED" end
    if type(vehicle.addFillUnitFillLevel) ~= "function" then return false, "NO_INSTANCE_COPY" end

    local originalAdd   = vehicle.addFillUnitFillLevel
    local originalType  = vehicle.setFillUnitFillType
    local originalEmpty = vehicle.emptyAllFillUnits

    local function report(fillUnitIndex, accepted, fillTypeIndex, cause)
        if onMovement == nil then return end
        local ok, err = pcall(onMovement, vehicle, fillUnitIndex, accepted, fillTypeIndex, cause)
        if not ok then
            print("[StockGuard] fill-unit observer: failed (" .. tostring(err) .. ")")
        end
    end

    -- THE ACCEPTED DELTA IS THE RETURN, never fillLevelDelta.
    vehicle.addFillUnitFillLevel = function(self, farmId, fillUnitIndex, fillLevelDelta,
                                            fillTypeIndex, toolType, fillPositionData)
        local n, r = packn(originalAdd(self, farmId, fillUnitIndex, fillLevelDelta,
                                       fillTypeIndex, toolType, fillPositionData))
        local accepted = r[1]
        -- A refusal returns 0 and is not movement. Recording it would invent a
        -- transfer that the engine declined.
        if type(accepted) == "number" and accepted ~= 0 then
            report(fillUnitIndex, accepted, fillTypeIndex, O.CAUSE_ADD)
        end
        return unpack(r, 1, n)
    end

    -- A fill-type change is not a quantity change, but it ends one material's
    -- occupancy of that unit and begins another's, so the record has to know.
    if type(originalType) == "function" then
        vehicle.setFillUnitFillType = function(self, fillUnitIndex, fillTypeIndex)
            local n, r = packn(originalType(self, fillUnitIndex, fillTypeIndex))
            report(fillUnitIndex, 0, fillTypeIndex, O.CAUSE_TYPE)
            return unpack(r, 1, n)
        end
    end

    -- emptyAllFillUnits is a separate path, the same way Storage:empty is.
    if type(originalEmpty) == "function" then
        vehicle.emptyAllFillUnits = function(self, ignoreDeleteOnEmptyFlag)
            local n, r = packn(originalEmpty(self, ignoreDeleteOnEmptyFlag))
            report(nil, 0, nil, O.CAUSE_EMPTY_ALL)
            return unpack(r, 1, n)
        end
    end

    vehicle[O.MARKER] = {
        add = vehicle.addFillUnitFillLevel, originalAdd = originalAdd,
        setType = vehicle.setFillUnitFillType, originalType = originalType,
        emptyAll = vehicle.emptyAllFillUnits, originalEmpty = originalEmpty,
    }
    return true
end

--- Remove the observer, but only where the live functions are still ours.
---@return boolean restored, string|nil why
function O.uninstall(vehicle)
    if type(vehicle) ~= "table" then return false, "NO_VEHICLE" end
    local rec = vehicle[O.MARKER]
    if rec == nil then return false, "NOT_INSTALLED" end

    if vehicle.addFillUnitFillLevel ~= rec.add then return false, "WRAPPED_BY_ANOTHER" end
    if rec.setType ~= nil and vehicle.setFillUnitFillType ~= rec.setType then return false, "WRAPPED_BY_ANOTHER" end
    if rec.emptyAll ~= nil and vehicle.emptyAllFillUnits ~= rec.emptyAll then return false, "WRAPPED_BY_ANOTHER" end

    vehicle.addFillUnitFillLevel = rec.originalAdd
    if rec.setType ~= nil then vehicle.setFillUnitFillType = rec.originalType end
    if rec.emptyAll ~= nil then vehicle.emptyAllFillUnits = rec.originalEmpty end
    vehicle[O.MARKER] = nil
    return true
end
