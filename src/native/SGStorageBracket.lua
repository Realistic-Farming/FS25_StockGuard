-- =========================================================
-- FS25_StockGuard - Storage mutation brackets (SG2-1 kernel)
-- =========================================================
-- Brackets Storage:setFillLevel and Storage:empty so every change to a storage's
-- held material is observed, with the level before and after rather than the
-- level that was requested.
--
-- MECHANISM 4: METATABLE CLASS METHOD. Storage.new(isServer, isClient, customMt)
-- builds instances that resolve setFillLevel through a metatable with NO
-- per-instance copy, so a wrap on the class table reaches every instance,
-- including ones already constructed, with no timing constraint. That is the
-- opposite of the work-area slot (mechanism 1) and of the fill-unit instance copy
-- (mechanism 2); the right target here is the wrong target there.
--
-- THE CAVEAT IS REAL AND IS NOT HANDLED: anything constructed with its own
-- customMt resolves through that metatable instead and never reaches this wrap, so
-- a subclassed storage is NOT covered. Recorded as the known edge of this
-- bracket's reach rather than discovered later.
--
-- WHY WE BRACKET RATHER THAN SUBSCRIBE TO addFillLevelChangedListeners, which is
-- the supported observation path and the obvious choice. IT IS LOSSY TWICE OVER.
--
-- setFillLevel notifies its listeners only when
--   math.abs(delta) > 0.1 or fillLevelsLastPublished[fillType] ~= newFillLevelInt
-- The `or` rescues a change that crosses a rounding boundary, but a RUN of
-- sub-0.1 changes that never crosses one is completely silent. For a system whose
-- entire job is material continuity that is a leak with no symptom: the material
-- moves, the record does not, and nothing reports a discrepancy.
--
-- And Storage:empty does not go through setFillLevel at all, so a listener never
-- sees a store emptied.
--
-- Bracketing both directly sees every change at any size, and sees empty.
--
-- Coordinates verified against D:\FS25_Decoded this session, per 19a57b9:
-- setFillLevel objects/Storage.lua:287 with its listener threshold at :298-300,
-- empty at :255. setFillLevel returns nothing (bare return at :292 and falls off
-- the end), but returns are forwarded anyway rather than assumed away.
--
-- A NOTE ON READING THAT FILE. Its decompiled body has collapsed identifiers: in
-- setFillLevel `oldLevel` is declared twice (:289 and :294) and `delta` at :296
-- reads as zero as written. Line numbers and control flow are trustworthy; the
-- names are not, and nothing here is derived from them. The behaviour this bracket
-- relies on is the CONTROL FLOW: an early return when the clamped value equals the
-- current one or the fill type is unknown, and the threshold on notification.

SGStorageBracket = SGStorageBracket or {}
local B = SGStorageBracket

B.MARKER = "_sgStorageBracketed"

B.CAUSE_SET   = "SET_FILL_LEVEL"
B.CAUSE_EMPTY = "EMPTY"

local function packn(...)
    return select("#", ...), { ... }
end

--- Read a storage's current level for one fill type, defensively.
local function levelOf(storage, fillType)
    if type(storage) ~= "table" or type(storage.fillLevels) ~= "table" then return nil end
    return storage.fillLevels[fillType]
end

--- Install both brackets on the Storage class table.
---
--- Idempotent through a marker on the class table, so a second install cannot
--- stack two brackets and observe every change twice.
---
---@param storageClass table     the Storage class (injected, so the bench uses the same path)
---@param onChange function|nil  (storage, fillType, before, after, cause)
---@return boolean installed, string|nil why
function B.install(storageClass, onChange)
    if g_server == nil then return false, "CLIENT" end
    if type(storageClass) ~= "table" then return false, "NO_CLASS" end
    if type(storageClass.setFillLevel) ~= "function" or type(storageClass.empty) ~= "function" then
        return false, "MISSING_METHODS"
    end
    if storageClass[B.MARKER] ~= nil then return false, "ALREADY_INSTALLED" end

    local originalSet   = storageClass.setFillLevel
    local originalEmpty = storageClass.empty

    --- Report one observed change. Protected: an error in our observer must never
    --- become an error in a native storage mutation that has already happened.
    local function report(storage, fillType, before, after, cause)
        if onChange == nil then return end
        if before == after then return end
        local ok, err = pcall(onChange, storage, fillType, before, after, cause)
        if not ok then
            print("[StockGuard] storage bracket: observer failed (" .. tostring(err) .. ")")
        end
    end

    -- setFillLevel. The level BEFORE is read here because the native call is what
    -- changes it; the level AFTER is read from the same table rather than from the
    -- requested value, because the clamp to capacity lives inside the native
    -- function and the request is not what landed.
    storageClass.setFillLevel = function(self, fillLevel, fillType, fillInfo)
        local before = levelOf(self, fillType)
        local n, r = packn(originalSet(self, fillLevel, fillType, fillInfo))
        report(self, fillType, before, levelOf(self, fillType), B.CAUSE_SET)
        return unpack(r, 1, n)
    end

    -- empty. A separate path that a fill-level listener never sees at all. Every
    -- type present before the call is reported, because the native call zeroes all
    -- of them and afterwards there is nothing left to enumerate from.
    storageClass.empty = function(self, ...)
        local before = {}
        if type(self) == "table" and type(self.fillLevels) == "table" then
            for fillType, level in pairs(self.fillLevels) do
                before[fillType] = level
            end
        end

        local n, r = packn(originalEmpty(self, ...))

        for fillType, level in pairs(before) do
            report(self, fillType, level, levelOf(self, fillType), B.CAUSE_EMPTY)
        end
        return unpack(r, 1, n)
    end

    storageClass[B.MARKER] = { set = storageClass.setFillLevel, empty = storageClass.empty,
                               originalSet = originalSet, originalEmpty = originalEmpty }
    return true
end

--- Remove the brackets, but only where the live methods are still ours.
---
--- Same rule as the work-area installer: if something else has wrapped us since,
--- restoring the originals would delete their hook silently, so we leave ours in
--- place and report it.
---@return boolean restored, string|nil why
function B.uninstall(storageClass)
    if type(storageClass) ~= "table" then return false, "NO_CLASS" end
    local rec = storageClass[B.MARKER]
    if rec == nil then return false, "NOT_INSTALLED" end

    if storageClass.setFillLevel ~= rec.set or storageClass.empty ~= rec.empty then
        return false, "WRAPPED_BY_ANOTHER"
    end

    storageClass.setFillLevel = rec.originalSet
    storageClass.empty        = rec.originalEmpty
    storageClass[B.MARKER]    = nil
    return true
end
