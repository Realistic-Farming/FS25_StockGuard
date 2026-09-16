-- =========================================================
-- FS25_StockGuard - SG_SAVE_2 envelope, backends and staged load (SG-1 4.7)
-- =========================================================
-- One StateLedger "stockGuard" module registration (StateLedger.lua:51
-- registerModule(name, {serialize, deserialize}); parseFile delivers once
-- and a late registration is delivered immediately). Without StateLedger
-- the own-XML backend writes the same logical envelope as SG_VALUES_2 tokens
-- beneath stockGuard in the savegame directory. One backend per mission,
-- never two active writers; a small SG-owned manifest (backend, save
-- attempt, snapshot key) is written beside every save so a nil delivery
-- after an initialized save is a missing payload, not first use.
--
-- SG_SAVE_2 = {schemaVersion=2, backendId, saveAttemptId, nativeSnapshotKey,
--   initializedSections, coreValues, sections, nativeAssociations, farmRestore?}
--
-- Load is staged: the raw envelope is retained as a candidate by the restore
-- coordinator, validated once both barriers are released, then the core is
-- restored against the enumerated carriers and each registered member
-- section is staged (stageLoad) and installed (commitLoad) per COUPLED
-- dependency set: a set is READY only when every member installed; a
-- failure withdraws the whole set (clearReadiness on already installed
-- members) and keeps the originals. A retained section (absent owner,
-- schema mismatch, staging or commit failure, unsupported farm-restore
-- policy) travels through later saves with its ORIGINAL payload; its owner
-- serialize is not consulted. A refused envelope is written back unchanged.
--
-- Farm conversion (4.7.1): sections declare farmRestorePolicy INVARIANT or
-- OWNER; an undeclared section under an actual MERGED conversion, and an
-- OWNER section under FAILED or WAITING, stay retained. On a MERGED load a
-- receipt and one pending unit per retained candidate are emitted and
-- persisted in the same envelope; a unit is removed in the same step that
-- installs its data; a receipt is dropped once nothing references it.
-- =========================================================

SGSave = SGSave or {}
local S = SGSave
local SGSave_mt = { __index = S }

S.SCHEMA_VERSION = 2
S.MODULE_ID = "stockGuard"
S.XML_FILE = "stockGuard.xml"
S.XML_ROOT = "stockGuard"
S.MANIFEST_FILE = "stockGuardManifest.xml"
S.MANIFEST_ROOT = "stockGuardManifest"
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
    self.loadEpoch = "1"
    self.sectionState = {}        -- sectionId -> { ready, reason, retained, payload, schemaVersion }
    self.lastEnvelope = nil
    self.loadResult = nil
    self.retainedRaw = nil        -- a refused (decoded) envelope, written back unchanged
    self.retainedMalformed = false
    self.manifest = nil           -- { backendId, saveAttemptId, nativeSnapshotKey }
    self.farmRestore = { receipts = {}, pendingUnits = {} }
    self.loadedEnvelope = nil     -- the accepted envelope of this load (for units)
    self.lastContext = nil
    return self
end

-- ---------------------------------------------------------
-- Envelope
-- ---------------------------------------------------------
--- Validate an envelope. A farmRestore proof that fails validation is
--- dropped with its reason (only that data is unavailable); the core and
--- sections remain usable.
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
        if not ok then
            e.farmRestoreRefused = reason
            e.farmRestore = nil
        end
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

-- ---------------------------------------------------------
-- Nested payload paths (the carrier-pending injection point)
-- ---------------------------------------------------------
local function splitPath(path)
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do parts[#parts + 1] = part end
    return parts
end

local function setPath(root, path, value)
    local parts = splitPath(path)
    local t = root
    for i = 1, #parts - 1 do
        if type(t[parts[i]]) ~= "table" then t[parts[i]] = {} end
        t = t[parts[i]]
    end
    t[parts[#parts]] = value
end

local function getPath(root, path)
    local t = root
    for _, part in ipairs(splitPath(path)) do
        if type(t) ~= "table" then return nil end
        t = t[part]
    end
    return t
end

function S:pendingLease()
    for _, lease in self.registry:each(SGRegistry.KIND_CARRIER_PENDING) do return lease end
    return nil
end

-- ---------------------------------------------------------
-- Build
-- ---------------------------------------------------------
--- Build the current envelope. A retained section writes its original
--- payload and its owner's serialize is not called; a live section whose
--- serialize fails keeps its last good payload and is reported. While a
--- refused prior envelope is retained, that envelope is returned unchanged.
function S:buildEnvelope(context)
    if self.loadResult ~= nil and self.loadResult.state == "UNAVAILABLE" and self.retainedRaw ~= nil then
        if not self.retainedRawLogged then
            self.retainedRawLogged = true
            log("prior envelope was refused (" .. tostring(self.loadResult.reason) .. "); it is written back unchanged, current state is not saved")
        end
        self.lastEnvelope = copy(self.retainedRaw)
        return self.lastEnvelope, { "RETAINED_RAW" }
    end
    self.saveAttemptId = self.saveAttemptId + 1
    self.nativeSnapshotKey = tostring(self.backendId or S.BACKEND_XML) .. ":" .. tostring(self.loadEpoch) .. ":" .. tostring(self.saveAttemptId)
    local e = {
        schemaVersion = S.SCHEMA_VERSION,
        backendId = self.backendId or S.BACKEND_XML,
        saveAttemptId = self.saveAttemptId,
        nativeSnapshotKey = self.nativeSnapshotKey,
        initializedSections = {},
        coreValues = self.operations:serializeCore(),
        sections = {},
        nativeAssociations = { saveAttemptId = self.saveAttemptId, nativeSnapshotKey = self.nativeSnapshotKey },
    }
    local failed = {}
    for sectionId, lease in self.registry:each(SGRegistry.KIND_SAVE_SECTION) do
        local st = self.sectionState[sectionId] or {}
        if st.retained and st.payload ~= nil then
            e.sections[sectionId] = { schemaVersion = st.schemaVersion or lease.spec.schemaVersion, payload = copy(st.payload) }
        else
            local ok, payload = pcall(lease.spec.serialize, copy(context or {}))
            if ok and payload ~= nil and SGRecords.isPayloadTree(payload) then
                e.sections[sectionId] = { schemaVersion = lease.spec.schemaVersion, payload = payload }
                st.payload = payload
                st.schemaVersion = lease.spec.schemaVersion
            elseif st.payload ~= nil then
                e.sections[sectionId] = { schemaVersion = st.schemaVersion or lease.spec.schemaVersion, payload = copy(st.payload) }
                failed[#failed + 1] = sectionId
            else
                failed[#failed + 1] = sectionId
            end
        end
        if e.sections[sectionId] ~= nil then table.insert(e.initializedSections, sectionId) end
        self.sectionState[sectionId] = st
    end
    -- Retained sections from an absent owner travel unchanged.
    for sectionId, st in pairs(self.sectionState) do
        if e.sections[sectionId] == nil and st.retained and st.payload ~= nil then
            e.sections[sectionId] = { schemaVersion = st.schemaVersion, payload = copy(st.payload) }
            table.insert(e.initializedSections, sectionId)
        end
    end
    -- The canonical carrier-pending collection is injected once at its
    -- declared path inside the owner's section (never a second file).
    local pl = self:pendingLease()
    if pl ~= nil then
        local st = self.sectionState[pl.spec.sectionId]
        if not (st ~= nil and st.retained) then
            if e.sections[pl.spec.sectionId] == nil then
                e.sections[pl.spec.sectionId] = { schemaVersion = pl.spec.schemaVersion, payload = {} }
                table.insert(e.initializedSections, pl.spec.sectionId)
            end
            setPath(e.sections[pl.spec.sectionId].payload, pl.spec.collectionPath, self.operations:serializePending())
        end
    end
    table.sort(e.initializedSections)
    if next(self.farmRestore.pendingUnits) ~= nil then
        e.farmRestore = { version = 1, receipts = copy(self.farmRestore.receipts), pendingUnits = copy(self.farmRestore.pendingUnits) }
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
    if self.retainedMalformed then return nil end
    local e = self:buildEnvelope({ backend = self.backendId })
    return e
end

function S:onLedgerDelivered(data)
    -- May arrive before farm conversion or at once on late registration:
    -- retain as candidate and return normally (deliveredTo is already set).
    -- Nil alone is not proof of first use: the manifest decides at staging.
    if data == nil then
        self.coordinator:retainPayload({ firstUse = true, nilDelivery = true }, "ledger")
        return
    end
    self.coordinator:retainPayload(data, "ledger")
end

--- Own-XML path: tokens beneath stockGuard.token(i)#v with a count.
function S:xmlPath(missionInfo, file)
    local mi = missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    if mi == nil or mi.savegameDirectory == nil then return nil end
    return mi.savegameDirectory .. "/" .. (file or S.XML_FILE)
end

function S:loadFromXML(missionInfo)
    if self.backendId ~= S.BACKEND_XML then return end
    local path = self:xmlPath(missionInfo)
    if path == nil or XMLFile == nil or XMLFile.loadIfExists == nil then
        self.coordinator:retainPayload({ firstUse = true, nilDelivery = true }, "xml")
        return
    end
    local xmlFile = XMLFile.loadIfExists("stockGuardSave", path)
    if xmlFile == nil then
        self.coordinator:retainPayload({ firstUse = true, nilDelivery = true }, "xml")
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

--- Write the envelope. An encode failure or a malformed retained file keeps
--- the previous file untouched and is logged; the xmlFile save result is
--- checked.
function S:saveToXML(missionInfo)
    if self.backendId ~= S.BACKEND_XML then return false end
    local path = self:xmlPath(missionInfo)
    if path == nil or XMLFile == nil or XMLFile.create == nil then return false end
    if self.retainedMalformed then
        log("prior save file is malformed and retained; not overwritten")
        return false
    end
    local e = self:buildEnvelope({ backend = self.backendId })
    local tokens, why = SGValues.encode(e)
    if tokens == nil then
        log("envelope encode failed (" .. tostring(why) .. "); previous file kept")
        return false
    end
    local xmlFile = XMLFile.create("stockGuardSave", path, S.XML_ROOT)
    if xmlFile == nil then
        log("could not create " .. tostring(path) .. "; previous file kept")
        return false
    end
    xmlFile:setInt(S.XML_ROOT .. "#count", #tokens)
    xmlFile:setString(S.XML_ROOT .. "#format", SGValues.FORMAT_TOKEN)
    for i, t in ipairs(tokens) do
        xmlFile:setString(string.format("%s.token(%d)#v", S.XML_ROOT, i - 1), t)
    end
    local saved = xmlFile:save()
    xmlFile:delete()
    if saved == false then
        log("xml save reported failure for " .. tostring(path))
        return false
    end
    return true
end

-- ---------------------------------------------------------
-- Initialization manifest (both backends)
-- ---------------------------------------------------------
function S:writeManifest(missionInfo)
    local path = self:xmlPath(missionInfo, S.MANIFEST_FILE)
    if path == nil or XMLFile == nil or XMLFile.create == nil or self.lastEnvelope == nil then return false end
    local xmlFile = XMLFile.create("stockGuardManifest", path, S.MANIFEST_ROOT)
    if xmlFile == nil then return false end
    xmlFile:setString(S.MANIFEST_ROOT .. "#backendId", tostring(self.lastEnvelope.backendId))
    xmlFile:setInt(S.MANIFEST_ROOT .. "#saveAttemptId", self.lastEnvelope.saveAttemptId or 0)
    xmlFile:setString(S.MANIFEST_ROOT .. "#nativeSnapshotKey", tostring(self.lastEnvelope.nativeSnapshotKey or ""))
    xmlFile:save()
    xmlFile:delete()
    return true
end

function S:readManifest(missionInfo)
    local path = self:xmlPath(missionInfo, S.MANIFEST_FILE)
    if path == nil or XMLFile == nil or XMLFile.loadIfExists == nil then return nil end
    local xmlFile = XMLFile.loadIfExists("stockGuardManifest", path)
    if xmlFile == nil then return nil end
    local m = {
        backendId = xmlFile:getString(S.MANIFEST_ROOT .. "#backendId", nil),
        saveAttemptId = xmlFile:getInt(S.MANIFEST_ROOT .. "#saveAttemptId", 0),
        nativeSnapshotKey = xmlFile:getString(S.MANIFEST_ROOT .. "#nativeSnapshotKey", nil),
    }
    xmlFile:delete()
    self.manifest = m
    return m
end

-- ---------------------------------------------------------
-- Staged load (called by the coordinator once both barriers are released)
-- ---------------------------------------------------------
function S:markAllSections(state, reason)
    for sectionId in self.registry:each(SGRegistry.KIND_SAVE_SECTION) do
        self.sectionState[sectionId] = self.sectionState[sectionId] or {}
        self.sectionState[sectionId].ready = (state == "READY_EMPTY")
        self.sectionState[sectionId].reason = reason or state
    end
end

function S:stageLoad(payload, context)
    local result = { state = "READY", core = nil, sections = {}, reason = nil }
    self.lastContext = context
    if type(payload) == "table" and payload.firstUse then
        if self.manifest ~= nil and (self.manifest.saveAttemptId or 0) > 0 then
            -- An initialized save delivered nothing: a missing payload, never first use.
            result.state = "UNAVAILABLE"
            result.reason = "PAYLOAD_MISSING"
            self.loadResult = result
            self:markAllSections("UNAVAILABLE", result.reason)
            log("manifest names save attempt " .. tostring(self.manifest.saveAttemptId) .. " but no payload was delivered; prior data unavailable")
            return result
        end
        result.state = "FIRST_USE"
        self.loadResult = result
        self:markAllSections("READY_EMPTY")
        return result
    end
    if type(payload) == "table" and payload.malformed then
        result.state = "UNAVAILABLE"
        result.reason = "MALFORMED:" .. tostring(payload.reason)
        self.retainedMalformed = true
        self.loadResult = result
        self:markAllSections("UNAVAILABLE", result.reason)
        log("saved file is malformed (" .. tostring(payload.reason) .. "); it is retained and not overwritten")
        return result
    end
    local e, why = S.validateEnvelope(payload)
    if e == nil then
        result.state = "UNAVAILABLE"
        result.reason = why
        self.loadResult = result
        self:markAllSections("UNAVAILABLE", why)
        log("saved envelope refused: " .. tostring(why) .. "; prior data retained unavailable and written back unchanged")
        self.retainedRaw = payload
        return result
    end
    if e.farmRestoreRefused ~= nil then
        log("saved farmRestore proof refused: " .. tostring(e.farmRestoreRefused) .. "; that proof is unavailable, core and sections continue")
        result.farmRestoreRefused = e.farmRestoreRefused
    end
    if e.backendId ~= self.backendId then
        log("saved envelope was written by " .. tostring(e.backendId) .. ", current backend " .. tostring(self.backendId) .. "; matched explicitly, no simultaneous writers")
    end
    self.loadedEnvelope = e
    self.saveAttemptId = math.max(self.saveAttemptId, e.saveAttemptId)
    if e.farmRestore ~= nil then
        self.farmRestore = { receipts = copy(e.farmRestore.receipts), pendingUnits = copy(e.farmRestore.pendingUnits) }
    end
    result.core = self.operations:restoreCore(e.coreValues)
    -- Member sections as coupled dependency sets.
    local pending = {}
    for _, id in ipairs(e.initializedSections) do pending[id] = e.sections[id] end
    result.sections = self:installSections(pending, context)
    self:installPendingCollection(e)
    self:accountFarmRestore(e, context, result)
    self.loadResult = result
    return result
end

--- Stage every registered section that has a payload, then commit each
--- coupled dependency set only when all its members staged; a failed
--- commit withdraws the whole set and retains the originals.
function S:installSections(pending, context)
    local out = {}
    local staged = {}
    local farmRestore = context and context.farmRestore or nil
    local phase = farmRestore and farmRestore.phase or nil
    for sectionId, sec in pairs(pending) do
        local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, sectionId)
        local st = self.sectionState[sectionId] or {}
        st.payload = sec.payload
        st.schemaVersion = sec.schemaVersion
        local policy = lease and lease.spec.farmRestorePolicy or nil
        if lease == nil then
            st.retained, st.ready, st.reason = true, false, "OWNER_ABSENT"
            out[sectionId] = "RETAINED"
        elseif lease.spec.schemaVersion ~= sec.schemaVersion then
            st.retained, st.ready, st.reason = true, false, "SCHEMA_MISMATCH"
            out[sectionId] = "RETAINED"
        elseif phase == SGFarmRestore.PHASE_MERGED and policy == nil then
            st.retained, st.ready, st.reason = true, false, "FARM_RESTORE_UNSUPPORTED"
            out[sectionId] = "RETAINED"
        elseif (phase == SGFarmRestore.PHASE_FAILED or phase == SGFarmRestore.PHASE_WAITING) and policy == "OWNER" then
            st.retained, st.ready, st.reason = true, false, "FARM_RESTORE_" .. phase
            out[sectionId] = "RETAINED"
        else
            local ok, candidate, reason = pcall(lease.spec.stageLoad, copy(sec.payload), copy(context or {}))
            if ok and candidate ~= nil then
                staged[sectionId] = candidate
            else
                st.retained, st.ready, st.reason = true, false, "STAGE_FAILED:" .. tostring(ok and reason or candidate)
                out[sectionId] = "RETAINED"
            end
        end
        self.sectionState[sectionId] = st
    end
    self:commitSets(staged, pending, out)
    -- Registered sections with no saved payload on a non-first-use load.
    for sectionId, lease in self.registry:each(SGRegistry.KIND_SAVE_SECTION) do
        if out[sectionId] == nil then
            self.sectionState[sectionId] = self.sectionState[sectionId] or {}
            self.sectionState[sectionId].ready = true
            self.sectionState[sectionId].retained = false
            self.sectionState[sectionId].reason = "NO_SAVED_DATA"
            out[sectionId] = "READY_EMPTY"
        end
    end
    return out
end

--- Coupled dependency sets over the staged candidates: connected components
--- of the dependency graph. A set commits in dependency order; a member
--- that is not staged, or any commit failure, withdraws the whole set.
function S:commitSets(staged, pending, out)
    local ids = {}
    for id in pairs(staged) do ids[#ids + 1] = id end
    table.sort(ids)
    local deps = function(id)
        local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, id)
        local d = lease and SGValues.copy(lease.spec.dependencies) or {}
        table.sort(d)
        return d
    end
    -- Undirected adjacency among sections that have a payload or a candidate.
    local adjacency = {}
    local function link(a, b)
        adjacency[a] = adjacency[a] or {}
        adjacency[b] = adjacency[b] or {}
        adjacency[a][b] = true
        adjacency[b][a] = true
    end
    for _, id in ipairs(ids) do
        adjacency[id] = adjacency[id] or {}
        for _, dep in ipairs(deps(id)) do link(id, dep) end
    end
    local seen = {}
    for _, root in ipairs(ids) do
        if not seen[root] then
            -- Collect the component.
            local members, stack = {}, { root }
            seen[root] = true
            while #stack > 0 do
                local id = table.remove(stack)
                members[#members + 1] = id
                for n in pairs(adjacency[id] or {}) do
                    if not seen[n] then seen[n] = true stack[#stack + 1] = n end
                end
            end
            table.sort(members)
            -- A member without a candidate leaves the set not ready.
            local blocked = nil
            for _, id in ipairs(members) do
                if staged[id] == nil then blocked = id end
            end
            if blocked ~= nil then
                for _, id in ipairs(members) do
                    if staged[id] ~= nil then
                        local st = self.sectionState[id] or {}
                        st.retained, st.ready, st.reason = true, false, "DEPENDENCY_NOT_READY"
                        self.sectionState[id] = st
                        out[id] = "RETAINED"
                    end
                end
            else
                -- Topological order within the set.
                local order, visited = {}, {}
                local function visit(id, stack2)
                    if visited[id] or stack2[id] then return end
                    stack2[id] = true
                    for _, dep in ipairs(deps(id)) do if staged[dep] ~= nil then visit(dep, stack2) end end
                    stack2[id] = nil
                    visited[id] = true
                    order[#order + 1] = id
                end
                for _, id in ipairs(members) do visit(id, {}) end
                local committed = {}
                local failedId, failedErr = nil, nil
                for _, id in ipairs(order) do
                    local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, id)
                    local ok, err = pcall(lease.spec.commitLoad, staged[id])
                    if ok then
                        committed[#committed + 1] = id
                    else
                        failedId, failedErr = id, err
                        break
                    end
                end
                if failedId == nil then
                    for _, id in ipairs(members) do
                        -- Guarded like every other sectionState read in this file; an
                        -- unguarded index here threw instead of reporting.
                        local st = self.sectionState[id]
                        if st ~= nil then
                            st.ready, st.retained, st.reason = true, false, nil
                            out[id] = "READY"
                        end
                    end
                else
                    -- Withdraw the set: already installed members are cleared,
                    -- every member keeps its original candidate.
                    for _, id in ipairs(committed) do
                        local lease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, id)
                        pcall(lease.spec.clearReadiness, "SET_WITHDRAWN:" .. failedId)
                    end
                    local failedLease = self.registry:get(SGRegistry.KIND_SAVE_SECTION, failedId)
                    pcall(failedLease.spec.clearReadiness, "COMMIT_FAILED:" .. tostring(failedErr))
                    for _, id in ipairs(members) do
                        local st = self.sectionState[id]
                        if st ~= nil then
                            st.ready, st.retained = false, true
                            if id == failedId then st.reason = "COMMIT_FAILED:" .. tostring(failedErr)
                            else st.reason = "DEPENDENCY_NOT_READY" end
                            out[id] = "RETAINED"
                        end
                    end
                end
            end
        end
    end
end

--- The carrier-pending collection is staged once from its declared path
--- after its owner section installed; a retained owner keeps the rows
--- inside its retained payload.
function S:installPendingCollection(e)
    local pl = self:pendingLease()
    if pl == nil then return end
    local st = self.sectionState[pl.spec.sectionId]
    local sec = e.sections[pl.spec.sectionId]
    if sec == nil or st == nil or not st.ready then return end
    local raw = getPath(sec.payload, pl.spec.collectionPath)
    if raw == nil then return end
    local coll, why = SGOperations.validatePending(raw)
    if coll == nil then
        log("carrier-pending collection refused: " .. tostring(why) .. "; rows stay retained in the owner payload")
        return
    end
    local r = self.operations:restorePending(coll)
    if r.retained > 0 then log("carrier-pending: " .. r.retained .. " row(s) retained on absent carriers") end
end

-- ---------------------------------------------------------
-- Farm restore receipts and pending units
-- ---------------------------------------------------------
function S:unitsReferencing(receiptId)
    for _, u in pairs(self.farmRestore.pendingUnits) do
        if u.receiptId == receiptId then return true end
    end
    return false
end

--- Remove a unit's pending marker (called in the same step that installs
--- its data) and collect its receipt when nothing references it.
function S:resolveUnit(unitId)
    local u = self.farmRestore.pendingUnits[unitId]
    if u == nil then return false end
    self.farmRestore.pendingUnits[unitId] = nil
    if not self:unitsReferencing(u.receiptId) then self.farmRestore.receipts[u.receiptId] = nil end
    return true
end

--- After a load: units that installed this time are resolved; on an
--- observed MERGED conversion, a receipt and one unit per retained
--- candidate are emitted and persisted in the same envelope.
function S:accountFarmRestore(e, context, result)
    for sectionId, state in pairs(result.sections or {}) do
        if state == "READY" or state == "READY_EMPTY" then self:resolveUnit("section:" .. sectionId) end
    end
    for _, s in ipairs(e.coreValues.stocks or {}) do
        if self.operations.stocks[s.stockId] ~= nil then self:resolveUnit("core:" .. s.stockId) end
    end
    for _, s in ipairs(e.coreValues.historical or {}) do
        if self.operations.stocks[s.stockId] ~= nil then self:resolveUnit("core:" .. s.stockId) end
    end
    local fr = context and context.farmRestore or nil
    if fr == nil or fr.phase ~= SGFarmRestore.PHASE_MERGED then return end
    local receiptId = "r" .. tostring(self.loadEpoch) .. "." .. tostring(e.saveAttemptId)
    local receipt = { sourceSaveAttemptId = e.saveAttemptId, sourceNativeSnapshotKey = e.nativeSnapshotKey or "", sourceToTarget = SGFarmRestore.receiptRows(fr.sourceToTarget), targetFarmId = fr.targetFarmId }
    local units = 0
    local function unit(id, revision)
        if self.farmRestore.pendingUnits[id] ~= nil then return end
        self.farmRestore.pendingUnits[id] = { receiptId = receiptId, sourcePayloadRevision = tostring(revision), sourceNativeSnapshotKey = e.nativeSnapshotKey or "", currentNativeSnapshotKey = e.nativeSnapshotKey or "", continuityLost = false }
        units = units + 1
    end
    for sectionId, state in pairs(result.sections or {}) do
        if state == "RETAINED" then unit("section:" .. sectionId, (e.sections[sectionId] and e.sections[sectionId].schemaVersion or 0) .. ":" .. e.saveAttemptId) end
    end
    for _, s in ipairs(e.coreValues.stocks or {}) do
        if self.operations.stocks[s.stockId] == nil then unit("core:" .. s.stockId, s.dataRevision) end
    end
    for _, s in ipairs(e.coreValues.historical or {}) do
        if self.operations.stocks[s.stockId] == nil then unit("core:" .. s.stockId, s.dataRevision) end
    end
    if units > 0 then
        self.farmRestore.receipts[receiptId] = receipt
        log("farm conversion observed; " .. units .. " unresolved unit(s) retained under receipt " .. receiptId)
    end
end

--- A section owner that registers after the load: its retained payload is
--- staged and committed now as its own set, under the retained context.
function S:onSectionRegistered(lease)
    if self.loadResult == nil or self.loadedEnvelope == nil then return end
    local st = self.sectionState[lease.ownerId]
    if st == nil or not st.retained or st.payload == nil then return end
    if st.reason ~= "OWNER_ABSENT" and st.reason ~= "FARM_RESTORE_UNSUPPORTED" then return end
    local pending = { [lease.ownerId] = { schemaVersion = st.schemaVersion, payload = st.payload } }
    local out = self:installSections(pending, self.lastContext)
    if out[lease.ownerId] == "READY" then
        self:resolveUnit("section:" .. lease.ownerId)
        log("late owner " .. tostring(lease.ownerId) .. " installed its retained section")
    end
end

function S:sectionReady(sectionId)
    local st = self.sectionState[sectionId]
    return st ~= nil and st.ready == true
end

function S:clear()
    self.sectionState = {}
    self.lastEnvelope = nil
    self.loadResult = nil
    self.loadedEnvelope = nil
    self.retainedRaw = nil
    self.retainedMalformed = false
    self.farmRestore = { receipts = {}, pendingUnits = {} }
    self.ledger = nil
    self.ledgerRegistered = false
    self.backendId = nil
end
