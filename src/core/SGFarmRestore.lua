-- =========================================================
-- FS25_StockGuard - native farm conversion and metadata restore (SG-1 4.7.1)
-- =========================================================
-- Opening a multiplayer save as singleplayer is an ownership conversion the
-- engine performs in FarmManager:mergeFarmsForSingleplayer (farms/
-- FarmManager.lua:100-129, called once from loadFromXMLFile :87). It is not
-- mixing, a new batch, a sale or an ordinary FARM_DELETED. This module has
-- two halves:
--
--   Pure helpers, the reference bar's model: mapping validation, stage
--   barriers, binding rekey, library retirement, empty-carrier guidance,
--   receipt sequences, the save-association bridge, the pending-unit commit,
--   the native stored-owner normalisation admission and canPublish.
--
--   The mission-local restore coordinator: observes the loaded source farm
--   ids before the native merge and the resulting mergedFarms after it (one
--   class wrapper per process with a per-mission token, the captured native
--   delegate called exactly once with its arguments and returns), resolves
--   context.farmRestore, and consumes the restore-complete barrier that the
--   StockGuard instance reports after BaseMission.onFinishedLoading's original
--   body. It never writes mergedFarms, never calls native mutations, never
--   initiates loading.
-- =========================================================

SGFarmRestore = SGFarmRestore or {}
local F = SGFarmRestore

F.VERSION = 1
F.PHASE_WAITING = "WAITING"
F.PHASE_UNCHANGED = "UNCHANGED"
F.PHASE_MERGED = "MERGED"
F.PHASE_FAILED = "FAILED"

local copy = SGValues.copy
local isInteger = SGValues.isInteger

local function log(msg)
    print("[StockGuard] restore: " .. tostring(msg))
end

-- ---------------------------------------------------------
-- Pure helpers (reference bar semantics)
-- ---------------------------------------------------------
--- Special farm ids that are never a conversion source or target.
function F.specialFarmIds()
    local c = SGRecords.farmConstants()
    return { [c.spectator] = true, [c.guidedTour] = true, [c.invalid] = true }
end

--- Validate an observed native merge map against the loaded farm list.
--- Multiplayer: no conversion, an empty map is the only valid answer and a
--- stale map refuses. Singleplayer: every loaded non-special, non-target
--- farm must map to the target and nothing else may appear. Returns a
--- detached copy of the map or nil.
function F.mapping(isMultiplayer, loadedFarmIds, actualMerged, targetFarmId, special)
    actualMerged = actualMerged or {}
    special = special or F.specialFarmIds()
    if isMultiplayer then
        if next(actualMerged) ~= nil then return nil end
        return {}
    end
    if not isInteger(targetFarmId) then return nil end
    local want = {}
    for _, id in ipairs(loadedFarmIds or {}) do
        if not isInteger(id) then return nil end
        if id ~= targetFarmId and not special[id] then want[id] = targetFarmId end
    end
    for k, v in pairs(want) do
        if actualMerged[k] ~= v then return nil end
    end
    for k, v in pairs(actualMerged) do
        if not isInteger(k) or want[k] ~= v then return nil end
    end
    return copy(actualMerged)
end

--- Stage barrier: a retained payload is staged once, only when both the farm
--- barrier and the native object barrier are released.
function F.stage(candidate)
    if type(candidate) ~= "table" then return false end
    if not candidate.payload or not candidate.farms or not candidate.native or candidate.staged then return false end
    candidate.staged = true
    candidate.calls = (candidate.calls or 0) + 1
    return true
end

--- Rekey saved bindings through a one-to-one canonical key map. Any missing
--- or colliding key refuses the entire set and leaves the source untouched.
--- Stock identity, contents generation, native amounts and historical facts
--- are carried unchanged.
function F.bindings(saved, keys)
    local seen, out = {}, {}
    for _, r in ipairs(saved or {}) do
        local k = keys[r.key]
        if k == nil or seen[k] then return nil end
        seen[k] = true
        local n = copy(r)
        n.key = k
        out[#out + 1] = n
    end
    return out
end

--- SG-4 policy under conversion: a merged source farm's library is retired
--- under its old identity, its definitions retained, the survivor's library
--- untouched. Never combined or reassigned.
function F.library(lib, map)
    local r = copy(lib)
    if map[r.owner] ~= nil then r.retired = true end
    return r
end

--- An empty armed carrier whose native owner was remapped loses its pending
--- target and advances its selection revision once as ownership transfer;
--- filled stock keeps its bound history; the survivor's carriers are untouched.
function F.guidance(g, map)
    local r = copy(g)
    if map[r.owner] ~= nil and r.empty then
        r.target = nil
        r.revision = r.revision + 1
        r.owner = map[r.owner]
    end
    return r
end

--- Decode a persisted receipt sequence into a source-to-target map. The raw
--- value is the decoded SG_VALUES_2 L of M records; validate dense numeric
--- sequence keys, exact record fields, integral native ids within 1..MAX,
--- excluded special ids, the survivor never a source, every target equal to
--- the recorded singleplayer target, strictly increasing unique sources.
--- Duplicate semantic sources are separate rows and refuse here.
function F.receiptMap(raw, target)
    local c = SGRecords.farmConstants()
    local special = F.specialFarmIds()
    if type(raw) ~= "table" or not isInteger(target) or target ~= c.singleplayer then return nil end
    local count = 0
    for k in pairs(raw) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return nil end
        count = count + 1
    end
    local out, last = {}, 0
    for i = 1, count do
        local row = raw[i]
        if type(row) ~= "table" then return nil end
        local n, v = row.sourceFarmId, row.targetFarmId
        for k in pairs(row) do
            if k ~= "sourceFarmId" and k ~= "targetFarmId" then return nil end
        end
        if type(n) ~= "number" or n % 1 ~= 0 or n <= last or n > c.maxFarmId or special[n] or n == target or v ~= target then
            return nil
        end
        out[n] = v
        last = n
    end
    return out
end

--- Canonical receipt rows from a source-to-target map (sorted sources).
function F.receiptRows(map)
    local sources = {}
    for s in pairs(map or {}) do sources[#sources + 1] = s end
    table.sort(sources)
    local rows = {}
    for _, s in ipairs(sources) do rows[#rows + 1] = { sourceFarmId = s, targetFarmId = map[s] } end
    return rows
end

--- Save-association bridge for one pending unit: currentNativeSnapshotKey
--- advances to the new save only when the unit was continuously observed
--- unchanged at the expected generation; anything else sets continuityLost
--- and the original source proof stays.
function F.bridge(s, key, from, to, gen, unchanged)
    local p = s.pending[key]
    if p == nil or p.continuityLost then return false end
    if not unchanged or p.current ~= from or p.generation ~= gen then
        p.continuityLost = true
        return false
    end
    p.current = to
    return true
end

--- Commit one pending unit through its receipt: exact revision, native
--- association and generation, a valid receipt map for the singleplayer
--- target, the unit's owner present in that map; installs the transformed
--- data and removes the pending marker in one step; the receipt is
--- collected only when no other unit references it.
function F.commit(s, key, rev, native, gen, ok)
    local p = s.pending[key]
    if p == nil or p.continuityLost or p.revision ~= rev or p.current ~= native or p.generation ~= gen or not ok then return false end
    local r = s.receipts[p.receiptId]
    if r == nil then return false end
    local decoded = F.receiptMap(r.sourceToTarget or r.map, SGRecords.farmConstants().singleplayer)
    if decoded == nil then return false end
    local candidate = copy(s.data[key])
    if candidate == nil then return false end
    local target = decoded[candidate.owner]
    if target == nil then return false end
    candidate.owner = target
    s.data[key] = candidate
    s.pending[key] = nil
    local retained = false
    for _, o in pairs(s.pending) do
        if o.receiptId == p.receiptId then retained = true end
    end
    if not retained then s.receipts[p.receiptId] = nil end
    return true
end

--- Native stored-owner normalisation admission (SG-2's native load adapter
--- model): only on the server, before loaded, never in multiplayer, only in
--- the MERGED phase with an agreeing map, only for an admitted child of an
--- exact class, and only when the stored owner field is a number. Writes
--- the owner once; amounts, material, identity and progress untouched.
function F.normalize(child, ctx)
    if type(child) ~= "table" or type(ctx) ~= "table" then return false end
    if not ctx.server or ctx.loaded or ctx.mp or ctx.phase ~= F.PHASE_MERGED or not ctx.mapAgrees then return false end
    if not child.admitted then return false end
    local t, k
    if child.class == "Vehicle" then
        t = child.palletAttributes
        k = "ownerFarmId"
    elseif child.class == "Bale" or child.class == "PackedBale" then
        if child.baleObject then t = child.baleObject k = "owner" else t = child.baleAttributes k = "farmId" end
    else
        return false
    end
    if t == nil or type(t[k]) ~= "number" then return false end
    local target = ctx.map[t[k]]
    if target ~= nil then
        t[k] = target
        child.ownerWrites = (child.ownerWrites or 0) + 1
    end
    return true
end

--- May rebound metadata publish for a child? Only when the actual current
--- owner equals the saved owner as corrected by the map.
function F.canPublish(savedOwner, actualOwner, map)
    return actualOwner ~= nil and actualOwner == ((map or {})[savedOwner] or savedOwner)
end

-- ---------------------------------------------------------
-- Mission-local restore coordinator
-- ---------------------------------------------------------
local SGFarmRestore_mt = { __index = F }

function F.new(loadEpoch)
    local self = setmetatable({}, SGFarmRestore_mt)
    self.loadEpoch = loadEpoch or "1"
    self.phase = F.PHASE_WAITING
    self.sourceToTarget = {}
    self.targetFarmId = nil
    self.loadedFarmIds = nil
    self.farmsLoaded = false
    self.nativeReady = false
    self.payload = nil          -- retained raw candidate envelope
    self.payloadSource = nil    -- "ledger" or "xml"
    self.staged = false
    self.stageCalls = 0
    self.onStage = nil          -- function(coordinator, payload, context)
    self.resolvedMapping = nil
    return self
end

--- The detached farmRestore context handed to member load callbacks.
function F:context()
    return {
        version = F.VERSION,
        loadEpoch = self.loadEpoch,
        phase = self.phase,
        sourceToTarget = copy(self.sourceToTarget),
        targetFarmId = self.targetFarmId,
    }
end

function F:isMultiplayer()
    local m = g_currentMission
    return m ~= nil and m.missionDynamicInfo ~= nil and m.missionDynamicInfo.isMultiplayer == true
end

--- Called before the native merge: capture the loaded farm ids.
function F:observeBeforeMerge(farmManager)
    local ids = {}
    if type(farmManager) == "table" and type(farmManager.farms) == "table" then
        for _, farm in ipairs(farmManager.farms) do
            if type(farm) == "table" and isInteger(farm.farmId) then ids[#ids + 1] = farm.farmId end
        end
    end
    self.loadedFarmIds = ids
end

--- Called after the native merge returned: copy mergedFarms and resolve.
function F:observeAfterMerge(farmManager)
    local merged = {}
    if type(farmManager) == "table" and type(farmManager.mergedFarms) == "table" then
        for k, v in pairs(farmManager.mergedFarms) do merged[k] = v end
    end
    local c = SGRecords.farmConstants()
    local target = c.singleplayer
    local mp = self:isMultiplayer()
    local mapping = F.mapping(mp, self.loadedFarmIds or {}, merged, target, F.specialFarmIds())
    local targetExists = true
    if not mp and type(farmManager) == "table" then
        local fn = farmManager.getFarmById
        if type(fn) == "function" then
            local ok, farm = pcall(fn, farmManager, target)
            targetExists = ok and farm ~= nil
        elseif type(farmManager.farmIdToFarm) == "table" then
            targetExists = farmManager.farmIdToFarm[target] ~= nil
        end
    end
    self.farmsLoaded = true
    if mapping == nil or not targetExists then
        self.phase = F.PHASE_FAILED
        self.sourceToTarget = {}
        self.targetFarmId = nil
        log("native farm map disagreed with the loaded farms; metadata stays unavailable")
        return
    end
    if self.resolvedMapping ~= nil and not SGValues.equal(self.resolvedMapping, mapping) then
        -- A changed mapping after resolution withdraws readiness; no blind rewrite.
        self.phase = F.PHASE_FAILED
        self.sourceToTarget = {}
        log("native farm map changed after resolution; readiness withdrawn")
        return
    end
    self.resolvedMapping = mapping
    self.sourceToTarget = mapping
    if next(mapping) == nil then
        self.phase = F.PHASE_UNCHANGED
        self.targetFarmId = (not mp) and target or nil
    else
        self.phase = F.PHASE_MERGED
        self.targetFarmId = target
    end
end

--- Farms loaded without the merge wrapper firing (defaults, or a host that
--- never ran the merge): UNCHANGED with an empty map.
function F:observeFarmsLoadedWithoutMerge(loadOk)
    if self.farmsLoaded then return end
    self.farmsLoaded = true
    if loadOk == false then
        self.phase = F.PHASE_FAILED
        self.sourceToTarget = {}
        self.targetFarmId = nil
        log("native farm data failed to load; metadata stays unavailable")
        return
    end
    self.phase = F.PHASE_UNCHANGED
    self.sourceToTarget = {}
    self.targetFarmId = (not self:isMultiplayer()) and SGRecords.farmConstants().singleplayer or nil
end

--- The restore-complete barrier (after onFinishedLoading's original body).
function F:observeNativeReady()
    self.nativeReady = true
    self:tryStage()
end

--- Retain a raw candidate payload from either backend and try staging.
function F:retainPayload(payload, source)
    self.payload = payload
    self.payloadSource = source
    self:tryStage()
end

--- Stage once when the payload and both barriers exist (bar's stage rule).
function F:tryStage()
    local candidate = { payload = self.payload ~= nil, farms = self.farmsLoaded, native = self.nativeReady, staged = self.staged, calls = self.stageCalls }
    if not F.stage(candidate) then return false end
    self.staged = true
    self.stageCalls = candidate.calls
    if type(self.onStage) == "function" then
        local ok, err = pcall(self.onStage, self, self.payload, self:context())
        if not ok then log("staged restore callback failed: " .. tostring(err)) end
    end
    return true
end

-- ---------------------------------------------------------
-- Owned hooks: one class wrapper per process, a per-mission token
-- ---------------------------------------------------------
F._current = nil

--- Install the FarmManager wrappers once per process. The live coordinator
--- is the token; without one the wrappers are pure delegates.
function F.installHooks()
    if F._hooksInstalled then return true end
    if FarmManager == nil then return false end
    F._hooksInstalled = true
    if type(FarmManager.mergeFarmsForSingleplayer) == "function" then
        local native = FarmManager.mergeFarmsForSingleplayer
        F._nativeMerge = native
        F._mergeWrapper = function(fm, ...)
            local c = F._current
            if c ~= nil then pcall(c.observeBeforeMerge, c, fm) end
            local results = { native(fm, ...) }
            if c ~= nil then pcall(c.observeAfterMerge, c, fm) end
            return unpack(results)
        end
        FarmManager.mergeFarmsForSingleplayer = F._mergeWrapper
    end
    if type(FarmManager.loadDefaults) == "function" then
        local nativeDefaults = FarmManager.loadDefaults
        F._nativeDefaults = nativeDefaults
        F._defaultsWrapper = function(fm, ...)
            local results = { nativeDefaults(fm, ...) }
            local c = F._current
            if c ~= nil then pcall(c.observeFarmsLoadedWithoutMerge, c) end
            return unpack(results)
        end
        FarmManager.loadDefaults = F._defaultsWrapper
    end
    return true
end

--- Withdraw the token first; restore an original only if the current method
--- is still our wrapper, otherwise retire as a no-op inside a foreign chain.
function F.removeHooks()
    F._current = nil
    if FarmManager == nil then return end
    if F._mergeWrapper ~= nil and FarmManager.mergeFarmsForSingleplayer == F._mergeWrapper then
        FarmManager.mergeFarmsForSingleplayer = F._nativeMerge
    end
    if F._defaultsWrapper ~= nil and FarmManager.loadDefaults == F._defaultsWrapper then
        FarmManager.loadDefaults = F._nativeDefaults
    end
    F._hooksInstalled = nil
    F._mergeWrapper, F._nativeMerge, F._defaultsWrapper, F._nativeDefaults = nil, nil, nil, nil
end

function F.setCurrent(coordinator)
    F._current = coordinator
end
