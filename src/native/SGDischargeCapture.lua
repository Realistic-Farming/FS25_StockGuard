-- =========================================================
-- FS25_StockGuard - outer Dischargeable capture (SG2-2 stage b)
-- =========================================================
-- A tool unloading into a station does it through ONE outer call:
-- Dischargeable:dischargeToObject(dischargeNode, emptyLiters, object, targetFillUnitIndex)
-- (vehicles/specializations/Dischargeable.lua:807-816). It converts through the
-- node's fill type converter, offers emptyLiters * factor to the target object
-- (an UnloadTrigger, which may convert again and forwards to its station), and
-- then debits its own fill unit by what the target accepted / factor. Everything a
-- sale needs to know about its SOURCE exists only here, before the debit: the
-- vehicle, dischargeNode.fillUnitIndex, the source material and the conversion.
--
-- MECHANISM 2: INSTANCE COPY. dischargeToObject is a registered function
-- (Dischargeable.lua:97), copied into every vehicle of the type, and native calls
-- it through self. So the capture wraps each live vehicle's instance slot, like
-- SGFillUnitObserver, installed by the native host when it observes a vehicle.
--
-- RECOGNITION IS EXACT FUNCTION IDENTITY against the method as Dischargeable
-- defined it when this file loaded. A vehicle whose slot holds anything else (an
-- overwritten function from another mod) is left untouched: its sales have no
-- admitted parent capture and the facade reports them unavailable, while the
-- native work runs exactly as it would.
--
-- The bracket never changes the native call: same arguments, every return
-- forwarded, a raised error re-raised unchanged after the capture is closed.

SGDischargeCapture = SGDischargeCapture or {}
local D = SGDischargeCapture

D.MARKER = "_sgDischargeCapture"
D.KEY = "dischargeToObject"

if D.nativeDischargeToObject == nil and Dischargeable ~= nil then
    D.nativeDischargeToObject = Dischargeable.dischargeToObject
end

local function packn(...)
    return select("#", ...), { ... }
end

--- Install the capture on one vehicle.
---@param onOpen function  (vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex) -> token
---@param onClose function (token, ok, vehicle, ...returns or error)
---@return boolean installed, string|nil why
function D.install(vehicle, onOpen, onClose)
    if g_server == nil then return false, "CLIENT" end
    if type(vehicle) ~= "table" or vehicle.spec_dischargeable == nil then return false, "NO_SPEC" end
    local baseline = D.nativeDischargeToObject
    if baseline == nil then return false, "NO_BASELINE" end
    local rec = rawget(vehicle, D.MARKER)
    local current = vehicle[D.KEY]
    if rec ~= nil and current == rec.wrapper then return true, "ALREADY" end
    if current ~= baseline then return false, "NOT_NATIVE" end

    local raw = rawget(vehicle, D.KEY)
    local wrapper = function(self, dischargeNode, emptyLiters, object, targetFillUnitIndex)
        local token
        if onOpen ~= nil then
            local okOpen, result = pcall(onOpen, self, dischargeNode, emptyLiters, object, targetFillUnitIndex)
            if okOpen then
                token = result
            else
                print("[StockGuard] discharge capture: open failed (" .. tostring(result) .. ")")
            end
        end
        -- The native call, protected ONLY so the capture can close.
        local n, r = packn(pcall(baseline, self, dischargeNode, emptyLiters, object, targetFillUnitIndex))
        if onClose ~= nil and token ~= nil then
            local okClose, err = pcall(onClose, token, r[1], self, unpack(r, 2, n))
            if not okClose then
                print("[StockGuard] discharge capture: close failed (" .. tostring(err) .. ")")
            end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    vehicle[D.KEY] = wrapper
    rawset(vehicle, D.MARKER, { raw = raw, wrapper = wrapper })
    return true
end

--- Restore the slot, only while our wrapper is still the current method.
---@return boolean restored, string|nil why
function D.uninstall(vehicle)
    if type(vehicle) ~= "table" then return false, "NO_VEHICLE" end
    local rec = rawget(vehicle, D.MARKER)
    if rec == nil then return false, "NOT_INSTALLED" end
    rawset(vehicle, D.MARKER, nil)
    if rawget(vehicle, D.KEY) ~= rec.wrapper then return false, "REPLACED_BY_ANOTHER" end
    rawset(vehicle, D.KEY, rec.raw)
    return true
end

function D.isInstalled(vehicle)
    local rec = type(vehicle) == "table" and rawget(vehicle, D.MARKER) or nil
    return rec ~= nil and vehicle[D.KEY] == rec.wrapper
end
