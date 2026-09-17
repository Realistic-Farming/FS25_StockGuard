-- =========================================================
-- FS25_StockGuard - captured work-area pointer installer (SG2-1 kernel)
-- =========================================================
-- Installs a delegating bracket on the ONE slot the engine actually calls for a
-- work area, for vehicles already in the world and for vehicles that spawn later,
-- and removes it again only where the live pointer is still ours.
--
-- WHY THIS IS NOT SHARED WITH SOILFERTILIZER'S EQUIVALENT. SoilFertilizer has a
-- helper of the same shape. Importing it, or factoring a common one, would make
-- StockGuard depend on SoilFertilizer being installed, which the capability-gated
-- design refuses outright: SG-2 must work with Soil absent. So the two stay
-- consistent by sharing the documented RULE below, never the code.
--
-- THE RULE, and the reason it is written out rather than referenced.
-- A processing function reaches the engine through THREE copies in series and
-- only the last is ever called:
--   1. SpecializationUtil.registerFunction writes objectType.functions[name].
--   2. Vehicle.copyTypeFunctionsInto copies that onto the INSTANCE
--      (SpecializationUtil.lua:141), before onPreLoad.
--   3. WorkArea:onLoad captures workArea.processingFunction = self[functionName]
--      (WorkArea.lua:266).
-- The engine then calls ONLY the captured pointer (WorkArea.lua:182-183) and
-- never re-resolves. So a wrap on the class table, on objectType.functions, or on
-- the instance copy is INERT. All three sit upstream of a pointer already taken.
--
-- This is mechanism 1 of four. Mechanism 2, anything the engine calls as
-- self:fn(...), is the exact MIRROR: there the instance copy is the live target
-- and this slot does not exist. Getting one right does not protect against the
-- other, so identify the mechanism before choosing a target.
--
-- Coordinates above are re-anchored against D:\FS25_Decoded per the SG-2 intake
-- at tracking 19a57b9. The brief's own line numbers come from E: and do not land.
--
-- TWO THINGS THE BRACKET MUST DO THAT A PLAIN OBSERVER NEED NOT.
--
-- First, PRESERVE EVERY RETURN EXACTLY. WorkArea.lua:183 is
-- `local xs, _ = workArea.processingFunction(self, workArea, dt)` and :184 is
-- `if xs > 0`. A bracket returning nothing makes that a comparison of nil with a
-- number, which THROWS inside the per-frame work-area loop. It is a crash guard,
-- not accounting. The return count is carried through select('#') rather than a
-- table constructor, so a genuine trailing nil is not silently dropped.
--
-- Second, SETTLE EVEN WHEN THE WRAPPED FUNCTION THROWS. WorkArea.lua:183 has no
-- pcall around the call, so a throw from anywhere in that chain abandons the rest
-- of onUpdateTick, including the End event. An observer can shrug at that; a
-- bracket that has OPENED an operation cannot, because the operation would be left
-- open for the life of the session. So the original is called under pcall, the
-- bracket is closed either way, and the error is then re-raised so the engine sees
-- exactly the behaviour it would have seen without us.

SGWorkAreaInstaller = SGWorkAreaInstaller or {}
local I = SGWorkAreaInstaller

--- Capture a call's returns WITH their exact count, which a `{ f() }` table
--- constructor cannot do when the last value is nil.
local function packn(...)
    return select("#", ...), { ... }
end

--- Wrap the captured processing pointer of every matching work area on one
--- vehicle.
---
--- Selection takes the owning spec AND the function name together. The name alone
--- is not unique: several carrier specializations register a `processDropArea`,
--- so a name-only selector reaches another specialization's area.
---
--- Idempotent. A work area already carrying our bracket is skipped, so a second
--- sweep, or a re-entrant spawn hook, cannot stack two brackets and open two
--- operations for one pass.
---
---@param vehicle table          the vehicle, after its load has finished
---@param specField string       e.g. "spec_combine", the owning specialization
---@param functionName string    e.g. "processCombineSwathArea", as registered
---@param makeBracket function   (realFn, workArea) -> bracketFn
---@return number installed
function I.install(vehicle, specField, functionName, makeBracket)
    if g_server == nil then return 0 end
    if type(vehicle) ~= "table" or vehicle[specField] == nil then return 0 end
    if type(makeBracket) ~= "function" then return 0 end

    local waSpec = vehicle.spec_workArea
    if waSpec == nil or type(waSpec.workAreas) ~= "table" then return 0 end

    local installed = 0
    for _, workArea in pairs(waSpec.workAreas) do
        if type(workArea) == "table"
           and workArea.functionName == functionName
           and type(workArea.processingFunction) == "function" then
            workArea._sgBrackets = workArea._sgBrackets or {}
            if workArea._sgBrackets[functionName] == nil then
                local realFn = workArea.processingFunction
                local bracket = makeBracket(realFn, workArea)
                if type(bracket) == "function" then
                    workArea._sgBrackets[functionName] = { ours = bracket, original = realFn }
                    workArea.processingFunction = bracket
                    installed = installed + 1
                end
            end
        end
    end
    return installed
end

--- Remove our bracket, but ONLY where the live pointer is still the bracket we
--- installed.
---
--- If something else has wrapped us since, restoring the original would delete
--- that other mod's hook silently, so we leave it and report it. The record is
--- KEPT in that case, so a later install sweep still sees this area as ours and
--- does not stack a second bracket on top of the foreign one.
---@return number restored, number leftInPlace
function I.uninstall(vehicle, specField, functionName)
    if type(vehicle) ~= "table" or vehicle[specField] == nil then return 0, 0 end
    local waSpec = vehicle.spec_workArea
    if waSpec == nil or type(waSpec.workAreas) ~= "table" then return 0, 0 end

    local restored, leftInPlace = 0, 0
    for _, workArea in pairs(waSpec.workAreas) do
        if type(workArea) == "table" and type(workArea._sgBrackets) == "table" then
            local rec = workArea._sgBrackets[functionName]
            if rec ~= nil then
                if workArea.processingFunction == rec.ours then
                    workArea.processingFunction = rec.original
                    workArea._sgBrackets[functionName] = nil
                    restored = restored + 1
                else
                    leftInPlace = leftInPlace + 1
                end
            end
        end
    end
    return restored, leftInPlace
end

--- Build a `makeBracket` for install() from an open/close pair.
---
--- The returned bracket CLOSES OVER the real function it is replacing. It does
--- not look it up through the record at call time, which would be one more thing
--- to be stale or wrong on a path that runs every frame.
---
--- `onOpen(vehicleSelf, workArea, dt)` may return an opaque token, handed back to
--- `onClose(token, ok, vehicleSelf, workArea, dt, ...)` with whether the native
--- call succeeded and its returns.
---
--- onClose runs WHETHER THE NATIVE CALL RETURNED OR THREW. When it threw, the
--- error is re-raised afterwards, so the engine sees exactly what it would have
--- seen without us, but only after our operation has closed. That is the whole
--- reason this is a bracket rather than an observer: WorkArea.lua:183 has no pcall,
--- so a throw there abandons the rest of onUpdateTick and would otherwise strand
--- an open operation for the life of the session.
---
--- Both callbacks are themselves protected. A fault in OUR bracket must not become
--- a fault in the player's game; by the time onClose runs the native work has
--- already happened.
---@param onOpen function|nil
---@param onClose function|nil
---@return function makeBracket  (realFn, workArea) -> bracketFn
function I.bracketFactory(onOpen, onClose)
    return function(realFn, _workArea)
        if type(realFn) ~= "function" then return nil end
        return function(vehicleSelf, workArea, dt)
            local token
            if onOpen ~= nil then
                local okOpen, result = pcall(onOpen, vehicleSelf, workArea, dt)
                if okOpen then
                    token = result
                else
                    print("[StockGuard] work-area bracket: open failed (" .. tostring(result) .. ")")
                end
            end

            -- The native call, protected ONLY so the bracket can close.
            local n, r = packn(pcall(realFn, vehicleSelf, workArea, dt))
            local ok = r[1]

            if onClose ~= nil then
                local okClose, err = pcall(onClose, token, ok, vehicleSelf, workArea, dt, unpack(r, 2, n))
                if not okClose then
                    print("[StockGuard] work-area bracket: close failed (" .. tostring(err) .. ")")
                end
            end

            if not ok then
                -- r[2] is the error the native call raised. Re-raise it unchanged.
                error(r[2], 0)
            end
            return unpack(r, 2, n)
        end
    end
end
