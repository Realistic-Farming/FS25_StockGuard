-- =========================================================
-- FS25_StockGuard - SG_SAVE_2 envelope, backends and staged load (SG-1 4.7)
-- =========================================================
-- One StateLedger "stockGuard" module registration (StateLedger.lua:51
-- registerModule(name, {serialize, deserialize}); parseFile delivers once
-- and a late registration is delivered immediately). Without StateLedger
-- the own-XML backend writes the same logical envelope as SG_VALUES_2 tokens
-- beneath stockGuard in the savegame directory. One backend per mission,
-- never two active writers; the manifest keys identify which one wrote.
--
-- SG_SAVE_2 = {schemaVersion=2, backendId, saveAttemptId, nativeSnapshotKey,
--   initializedSections, coreValues, sections, nativeAssociations, farmRestore?}
--
-- Load is staged: the raw envelope is retained as a candidate by the restore
-- coordinator (the StateLedger callback may arrive before farms or objects
-- are reconstructed), validated once both barriers are released, then the
-- core is restored against the enumerated carriers and each registered
-- member section is staged (stageLoad) and installed (commitLoad) as a
-- coupled dependency set: no set becomes READY before every required
-- installation succeeds; a failure withdraws that set and keeps its
-- original candidate. Missing initialized sections are an error, not
-- empty success; first use initializes empty.
-- =========================================================

SGSave = SGSave or {}
local S = SGSave
local SGSave_mt = { __index = S }

S.SCHEMA_VERSION = 2
S.MODULE_ID = "stockGuard"
S.XML_FILE = "stockGuard.xml"
S.XML_ROOT = "stockGuard"
S.BACKEND_LEDGER = "STATE_LEDGER"
S.BACKEND_XML = "OWN_XML"

local copy = SGValues.copy
local isInteger = SGValues.isInteger
local nonempty = SGRecords.nonemptyString

local function log(msg) print("[StockGuard] save: " .. tostring(msg)) end

function S.new(registry, operations, coordinator)
    local self = setmetatable({}, SGSave_mt)
    self.registry = registry
    self.operations = operations
    self.coordinator = coordinator
    self.backendId = nil
    self.ledger = nil
    self.ledgerRegistered = false
    self.saveAttemptId = 0
    self.nativeSnapshotKey = nil
    self.sectionState = {}        -- sectionId -> { ready, reason, candidate, payload, schemaVersion }
    self.lastEnvelope = nil
    self.loadResult = nil
    self.farmRestoreRetained = nil -- {receipts, pendingUnits}
    return self
end

-- ---------------------------------------------------------
-- Envelope
-- ---------------------------------------------------------
function S.validateEnvelope(e)
    if type(e) ~= "table" then return nil, "NOT_TABLE" end
    if e.schemaVersion ~= S.SCHEMA_VERSION then return nil, "UNSUPPORTED_SCHEMA" end
    if not nonempty(e.backendId, 32) then return nil, "BACKEND" end
    if not isInteger(e.saveAttemptId) or e.saveAttemptId < 0 then return nil, "SAVE_ATTEMPT" end
    if e.nativeSnapshotKey ~= nil and not nonempty(e.nativeSnapshotKey, 256) then return nil, "SNAPSHOT_KEY" end
    if type(e.initializedSections) ~= "table" or type(e.sections) ~= "table" then return nil, "SECTIONS" end
    for _, id in ipairs(e.initializedSections) do
        if not nonempty(id, 64) then return nil, "SECTION_ID" end
        if e.sections[id] == nil then return nil, "MISSING_INITIALIZED_SECTION:" .. id end
    end
    for id, sec in pairs(e.sections) do
        if type(sec) ~= "table" or not isInteger(sec.schemaVersion) then return nil, "SECTION_SHAPE:" .. tostring(id) end
    end
    local core, why = SGOperations.validateCore(e.coreValues)
    if core == nil then return nil, why end
    if e.nativeAssociations ~= nil and type(e.nativeAssociations) ~= "table" then return nil, "NATIVE_ASSOCIATIONS" end
    if e.farmRestore ~= nil then
        local ok, reason = S.validateFarmRestore(e.farmRestore)
        if not ok then return nil, reason end
    end
    return e
end

--- farmRestore = {version=1, receipts, pendingUnits}; receipts map a
--- receiptId to {sourceSaveAttemptId, sourceNativeSnapshotKey, sourceToTarget
--- (canonical row sequence), targetFarmId}; pendingUnits map a unit identity
--- to {receiptId, sourcePayloadRevision, sourceNativeSnapshotKey,
--- currentNativeSnapshotKey, continuityLost}.
function S.validateFarmRestore(fr)
    if type(fr) ~= "table" or fr.version ~= 1 then return false, "FARM_RESTORE_VERSION" end
    if type(fr.receipts) ~= "table" or type(fr.pendingUnits) ~= "table" then return false, "FARM_RESTORE_SHAPE" end
    for id, r in pairs(fr.receipts) do
        if not nonempty(id, 64) or type(r) ~= "table" or not isInteger(r.sourceSaveAttemptId) or not isInteger(r.targetFarmId) then return false, "RECEIPT:" .. tostring(id) end
        if SGFarmRestore.receiptMap(r.sourceToTarget, r.targetFarmId) == nil then return false, "RECEIPT_MAP:" .. tostring(id) end
    end
    for id, u in pairs(fr.pendingUnits) do
        if not nonempty(id, 256) or type(u) ~= "table" or fr.receipts[u.receiptId] == nil then return false, "PENDING_UNIT:" .. tostring(id) end
        if type(u.continuityLost) ~= "boolean" then return false, "PENDING_UNIT:" .. tostring(id) end
    end
    return true
end

--- Build the current envelope. Sections serialize through their registered
--- callbacks; a failed serialization keeps that section's last good payload
--- rather than writing an empty replacement, and is reported.
function S:buildEnvelope(context)
    self.saveAttemptId = self.saveAttemptId + 1
    local e = {
        schemaVersion = S.SCHEMA_VERSION,
        backendId = self.backendId or S.BACKEND_XML,
        saveAttemptId = self.saveAttemptId,
        nativeSnapshotKey = self.nativeSnapshotKey,
        initializedSections = {},
        coreValues = self.operations:serializeCore(),
        sections = {},
        nativeAssociations = { saveAttemptId = self.saveAttemptId },
    }
    local failed = {}
    for sectionId, lease in self.registry:each(SGRegistry.KIND_SAVE_SECTION) do
        local st = self.sectionState[sectionId] or {}
        local ok, payload = pcall(lease.spec.serialize, copy(context or {}))
        if ok and payload ~= nil and SGRecords.isPayloadTree(payload) then
            e.sections[sectionId] = { schemaVersion = lease.spec.schemaVersion, payload = payload }
            st.payload = payload
        elseif st.payload ~= nil then
            e.sections[sectionId] = { schemaVersion = st.schemaVersion or lease.spec.schemaVersion, payload = st.payload }
            failed[#failed + 1] = sectionId
        else
            failed[#failed + 1] = sectionId
        end
        if e.sections[sectionId] ~= nil then table.insert(e.initializedSections, sectionId) end
        self.sectionState[sectionId] = st
    end
    -- Retained sections from an absent owner travel unchanged.
    for sectionId, st in pairs(self.sectionState) do
        if e.sections[sectionId] == nil and st.retained and st.payload ~= nil then
            e.sections[sectionId] = { schemaVersion = st.schemaVersion, payload = st.payload }
            table.insert(e.initializedSections, sectionId)
        end
    end
    table.sort(e.initializedSections)
    if self.farmRestoreRetained ~= nil and (next(self.farmRestoreRetained.pendingUnits) ~= nil) then
        e.farmRestore = copy(self.farmRestoreRetained)
        e.farmRestore.version = 1
    end
    self.lastEnvelope = e
    return e, failed
end

-- ---------------------------------------------------------
-- Backends
-- ---------------------------------------------------------
--- Select and register the backend once per mission. Called early (the
--- coordinator is initialized first because delivery may be immediate).
function S:registerBackend(mission)
    if self.backendId ~= nil then return self.backendId end
    local ledger = (mission ~= nil and mission.stateLedger) or g_stateLedger
    if type(ledger) == "table" and type(ledger.registerModule) == "function" then
        local save = self
        local ok, err = pcall(function()
            ledger:registerModule(S.MODULE_ID, {
                serialize = function() return save:serializeForLedger() end,
                deserialize = function(data) save:onLedgerDelivered(data) end,
            })
        end)
        if ok then
            self.ledger = ledger
            self.ledgerRegistered = true
            self.backendId = S.BACKEND_LEDGER
            log("StateLedger module 'stockGuard' registered")
            return self.backendId
        end
        log("StateLedger registration failed: " .. tostring(err) .. "; own XML backend selected")
    end
    self.backendId = S.BACKEND_XML
    return self.backendId
end

function S:serializeForLedger()
    if self.backendId ~= S.BACKEND_LEDGER then return nil end
    local e = self:buildEnvelope({ backend = self.backendId })
    return e
end

function S:onLedgerDelivered(data)
    -- May arrive before farm conversion or at once on late registration:
    -- retain as candidate and return normally (deliveredTo is already set).
    if data == nil then
        self.coordinator:retainPayload({ firstUse = true }, "ledger")
        return
    end
    self.coordinator:retainPayload(data, "ledger")
end

--- Own-XML path: tokens beneath stockGuard.token(i)#v with a count.
function S:xmlPath(missionInfo)
    local mi = missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    if mi == nil or mi.savegameDirectory == nil then return nil end
    return mi.savegameDirectory .. "/" .. S.XML_FILE
end

function S:loadFromXML(missionInfo)
    if self.backendId ~= S.BACKEND_XML then return end
    local path = self:xmlPath(missionInfo)
    if path == nil or XMLFile == nil or XMLFile.loadIfExists == nil then
        self.coordinator:retainPayload({ firstUse = true }, "xml")
        return
    end
    local xmlFile = XMLFile.loadIfExists("stockGuardSave", path)
    if xmlFile == nil then
        self.coordinator:retainPayload({ firstUse = true }, "xml")
        return
    end
    local count = xmlFile:getInt(S.XML_ROOT .. "#count", 0)
    local tokens = {}
    for i = 1, count do
        tokens[i] = xmlFile:getString(string.format("%s.token(%d)#v", S.XML_ROOT, i - 1), nil)
        if tokens[i] == nil then tokens = nil break end
    end
    xmlFile:delete()
    if tokens == nil then
        self.coordinator:retainPayload({ malformed = true, reason = "XML_TOKENS" }, "xml")
        return
    end
    local value, why = SGValues.decode(tokens)
    if why ~= nil then
        self.coordinator:retainPayload({ malformed = true, reason = why }, "xml")
        return
    end
    self.coordinator:retainPayload(value, "xml")
end

function S:saveToXML(missionInfo)
    if self.backendId ~= S.BACKEND_XML then return false end
    local path = self:xmlPath(missionInfo)
    if path == nil or XMLFile == nil or XMLFile.create == nil then return false end
    local e = self:buildEnvelope({ backend = self.backendId })
    local tokens = SGValues.encode(e)
    if tokens == nil then return false end
    local xmlFile = XMLFile.create("stockGuardSave", path, S.XML_ROOT)
    if xmlFile == nil then return false end
    xmlFile:setInt(S.XML_ROOT .. "#count", #tokens)
    xmlFile:setString(S.XML_ROOT .. "#format", SGValues.FORMAT_TOKEN)
    for i, t in ipairs(tokens) do
        xmlFile:setString(string.format("%s.token(%d)#v", S.XML_ROOT, i - 1), t)
    end
    xmlFile:save()
    xmlFile:delete()
    return true
end

-- ---------------------------------------------------------
-- Staged load (called by the coordinator once both barriers are released)
-- ---------------------------------------------------------
function S:stageLoad(payload, context)
    local result = { state = "READY", core = nil, sections = {}, reason = nil }
    if type(payload) == "table" and payload.firstUse then
        result.state = "FIRST_USE"
        self.loadResult = result
        self:markAllSections("READY_EMPTY")
        return result
    end
    if type(payload) == "table" and payload.malformed then
        result.state = "UNAVAILABLE"
        result.reason = "MALFORMED:" .. tostring(payload.reason)
        self.loadResult = result
        self:markAllSections("UNAVAILABLE", result.reason)
        return result
    end
    local e, why = S.validateEnvelope(payload)
    if e == nil then
        result.state = "UNAVAILABLE"
        result.reason = why
        self.loadResult = result
        self:markAllSections("UNAVAILABLE", why)
        log("saved envelope refused: " .. tostring(why) .. "; prior data retained unavailable")
        self.retainedRaw = payload
        return result
    end
    if e.backendId ~= self.backendId then
        log("saved envelope was written by " .. tostring(e.backendId) .. ", current backend " .. tostring(self.backendId) .. "; matched explicitly")
    end
    self.saveAttemptId = math.max(self.saveAttemptId, e.saveAttemptId)
    self.nativeSnapshotKey = e.nativeSnapshotKey
    if e.farmRestore ~= nil then self.farmRestoreRetained = copy(e.farmRestore) end
    result.core = self.operations:restoreCore(e.coreValues)
    -- Member sections as coupled dependency sets.
    local pending = {}
    for _, id in ipairs(e.initializedSections) do pending[id] = e.sections[id] end
    result.sections = self:installSections(pending, context)
    self.loadResult = result
    return result
end

function S:markAllSections(state, reason)
    for sectionId in self.registry:each(SGRegistry.KIND_SAVE_SECTION) do
        self.sectionState[sectionId] = self.sectionState[sectionId] or {}
        self.sectionState[sectionId].ready = (state == "READY_EMPTY")
        self.sectionState[sectionId].reason = reason or state
    end
end

--- Stage every registered section that has a payload, then commit each
--- coupled dependency set only when all its members staged; a failed
--- commit withdraws the set and retains the originals.
function S:installSections(pending, context)
    local out = {}
    local staged = {}
    local farmRestore = context and context.farmRestore or nil
    for sectionId, sec in pairs(pending) do
        local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, sectionId)
        local st = self.sectionState[sectionId] or {}
        st.payload = sec.payload
        st.schemaVersion = sec.schemaVersion
        if lease == nil then
            st.retained = true
            st.ready = false
            st.reason = "OWNER_ABSENT"
            out[sectionId] = "RETAINED"
        elseif lease.spec.schemaVersion ~= sec.schemaVersion then
            st.retained = true
            st.ready = false
            st.reason = "SCHEMA_MISMATCH"
            out[sectionId] = "RETAINED"
        elseif farmRestore ~= nil and farmRestore.phase == SGFarmRestore.PHASE_MERGED and lease.spec.farmRestorePolicy ~= "OWNER" and lease.spec.farmRestorePolicy ~= "INVARIANT" then
            st.retained = true
            st.ready = false
            st.reason = "FARM_RESTORE_UNSUPPORTED"
            out[sectionId] = "RETAINED"
        else
            local ok, candidate, reason = pcall(lease.spec.stageLoad, copy(sec.payload), copy(context or {}))
            if ok and candidate ~= nil then
                staged[sectionId] = candidate
            else
                st.retained = true
                st.ready = false
                st.reason = "STAGE_FAILED:" .. tostring(ok and reason or candidate)
                out[sectionId] = "RETAINED"
            end
        end
        self.sectionState[sectionId] = st
    end
    -- Dependency sets: dependencies commit first (topological order over
    -- the staged candidates, ties by id); a section commits only when every
    -- dependency is already committed, so a failed dependency never lets a
    -- dependent install and no set is READY before its required
    -- installations succeeded.
    local committed = {}
    local order, visited = {}, {}
    local function visit(sectionId, stack)
        if visited[sectionId] then return end
        if stack[sectionId] then return end
        stack[sectionId] = true
        local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, sectionId)
        if lease ~= nil then
            local deps = SGValues.copy(lease.spec.dependencies)
            table.sort(deps)
            for _, dep in ipairs(deps) do
                if staged[dep] ~= nil then visit(dep, stack) end
            end
        end
        stack[sectionId] = nil
        visited[sectionId] = true
        order[#order + 1] = sectionId
    end
    local ids = {}
    for id in pairs(staged) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do visit(id, {}) end
    for _, sectionId in ipairs(order) do
        local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, sectionId)
        local st = self.sectionState[sectionId]
        local depsReady = true
        for _, dep in ipairs(lease.spec.dependencies) do
            if not committed[dep] then depsReady = false end
        end
        if not depsReady then
            st.ready = false
            st.retained = true
            st.reason = "DEPENDENCY_NOT_READY"
            out[sectionId] = "RETAINED"
        else
            local ok, err = pcall(lease.spec.commitLoad, staged[sectionId])
            if ok then
                st.ready = true
                st.retained = false
                st.reason = nil
                committed[sectionId] = true
                out[sectionId] = "READY"
            else
                st.ready = false
                st.retained = true
                st.reason = "COMMIT_FAILED:" .. tostring(err)
                out[sectionId] = "RETAINED"
                pcall(lease.spec.clearReadiness, st.reason)
            end
        end
    end
    -- Registered sections with no saved payload on a non-first-use load.
    for sectionId, lease in self.registry:each(SGRegistry.KIND_SAVE_SECTION) do
        if out[sectionId] == nil then
            self.sectionState[sectionId] = self.sectionState[sectionId] or {}
            self.sectionState[sectionId].ready = true
            self.sectionState[sectionId].reason = "NO_SAVED_DATA"
            out[sectionId] = "READY_EMPTY"
        end
    end
    return out
end

function S:sectionReady(sectionId)
    local st = self.sectionState[sectionId]
    return st ~= nil and st.ready == true
end

function S:clear()
    self.sectionState = {}
    self.lastEnvelope = nil
    self.loadResult = nil
    self.ledger = nil
    self.ledgerRegistered = false
    self.backendId = nil
end
