-- =========================================================
-- FS25_StockGuard - registrations and mission-local leases (SG-1 4.4)
-- =========================================================
-- Every registration returns a mission-local lease bound to the actual
-- registered owner callback table; a matching string id is not a
-- credential. Duplicate live ownership refuses. unregisterOwner(lease)
-- withdraws only that registration. Leases carry the registry epoch, so a
-- lease from an earlier mission is dead in the next one. No lease is saved
-- or transmitted.
--
-- Registrations: registerCarrierAdapter, registerProperty, registerConsumer,
-- registerManagementOwner, registerSaveSection, registerCarrierPending.
-- Specs are trusted initialization-time integration code; validation here
-- catches missing callbacks and bad shapes, not hostile Lua.
-- =========================================================

SGRegistry = SGRegistry or {}
local G = SGRegistry
local SGRegistry_mt = { __index = G }

G.KIND_CARRIER_ADAPTER = "CARRIER_ADAPTER"
G.KIND_PROPERTY = "PROPERTY"
G.KIND_CONSUMER = "CONSUMER"
G.KIND_MANAGEMENT = "MANAGEMENT_OWNER"
G.KIND_SAVE_SECTION = "SAVE_SECTION"
G.KIND_CARRIER_PENDING = "CARRIER_PENDING"

G.OPERATION_KINDS = { BIRTH = true, TRANSFER = true, MIX = true, CONVERT = true, REMOVE = true, REBIND = true }
G.TARGET_KINDS = { CARRIER = true, STOCK = true, PROCESS = true, LIBRARY = true }
G.ADMISSION = { DIRECT_DESIRED_STATE = true, QUOTED = true }
G.CONTROL_KINDS = { ORDINARY = true, ADMINISTRATIVE = true, CREATIVE = true, RECOVERY = true, DIAGNOSTIC = true }
G.FARM_RESTORE_POLICY = { INVARIANT = true, OWNER = true }

local isInteger = SGValues.isInteger
local nonempty = SGRecords.nonemptyString

local function isFn(f) return type(f) == "function" end
local function optFn(f) return f == nil or type(f) == "function" end
local function positiveInt(n) return isInteger(n) and n >= 1 end
local function stringList(t, allowed)
    if type(t) ~= "table" then return false end
    local n = 0
    for _, v in ipairs(t) do
        n = n + 1
        if type(v) ~= "string" or (allowed ~= nil and not allowed[v]) then return false end
    end
    return n >= 0
end

function G.new(epoch)
    local self = setmetatable({}, SGRegistry_mt)
    self.epoch = epoch or "1"
    self.nextLease = 0
    self.leases = {}          -- leaseId -> lease
    self.byKindAndId = {}     -- kind -> ownerId -> lease
    self.onUnregister = nil   -- function(lease)
    return self
end

local function issue(self, kind, ownerId, spec)
    local live = self.byKindAndId[kind] and self.byKindAndId[kind][ownerId]
    if live ~= nil then return nil, "DUPLICATE_OWNER" end
    self.nextLease = self.nextLease + 1
    local lease = { leaseId = self.epoch .. ":" .. tostring(self.nextLease), kind = kind, ownerId = ownerId, spec = spec, epoch = self.epoch, live = true }
    self.leases[lease.leaseId] = lease
    self.byKindAndId[kind] = self.byKindAndId[kind] or {}
    self.byKindAndId[kind][ownerId] = lease
    return lease
end

--- A lease is live only when it is this registry's own record for this epoch.
function G:isLive(lease, kind)
    if type(lease) ~= "table" or lease.epoch ~= self.epoch then return false end
    local mine = self.leases[lease.leaseId]
    if mine ~= lease or not mine.live then return false end
    if kind ~= nil and mine.kind ~= kind then return false end
    return true
end

function G:get(kind, ownerId)
    local t = self.byKindAndId[kind]
    return t and t[ownerId] or nil
end

function G:each(kind)
    local t = self.byKindAndId[kind] or {}
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids)
    local i = 0
    return function()
        i = i + 1
        local id = ids[i]
        if id == nil then return nil end
        return id, t[id]
    end
end

function G:count(kind)
    local n = 0
    for _ in pairs(self.byKindAndId[kind] or {}) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------
-- registerCarrierAdapter(adapterId, spec)
-- ---------------------------------------------------------
function G:registerCarrierAdapter(adapterId, spec)
    if not nonempty(adapterId, 64) then return nil, "INVALID_ID" end
    if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
    if not positiveInt(spec.version) then return nil, "VERSION" end
    if not stringList(spec.carrierKinds) or #spec.carrierKinds == 0 then return nil, "CARRIER_KINDS" end
    if spec.materialGroups ~= nil and not stringList(spec.materialGroups) then return nil, "MATERIAL_GROUPS" end
    if not isFn(spec.resolveCarrier) or not isFn(spec.readNativeState) or not isFn(spec.enumerateCarriers) or not isFn(spec.hasAccess) then
        return nil, "CALLBACKS"
    end
    if not optFn(spec.resolveAlias) or not optFn(spec.restoreBinding) or not optFn(spec.onCarrierBindingChanged) or not optFn(spec.getNavigationCarrierId) then
        return nil, "OPTIONAL_CALLBACKS"
    end
    return issue(self, G.KIND_CARRIER_ADAPTER, adapterId, spec)
end

-- ---------------------------------------------------------
-- registerProperty(propertyId, spec)
-- ---------------------------------------------------------
function G:registerProperty(propertyId, spec)
    if not nonempty(propertyId, 128) then return nil, "INVALID_ID" end
    if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
    if not positiveInt(spec.schemaVersion) then return nil, "SCHEMA_VERSION" end
    if not nonempty(spec.producerId, 64) then return nil, "PRODUCER_ID" end
    if not SGRecords.RESIDENCY[spec.residency] then return nil, "RESIDENCY" end
    if spec.applicability ~= nil and type(spec.applicability) ~= "table" then return nil, "APPLICABILITY" end
    if not isFn(spec.validate) or not isFn(spec.combine) or not isFn(spec.transform) or not isFn(spec.disclosure) then return nil, "CALLBACKS" end
    if spec.residency == "OWNER_RESOLVED" and (not isFn(spec.resolveResident) or not isFn(spec.getResidentRevision)) then return nil, "RESIDENT_CALLBACKS" end
    local causal = spec.validateCause ~= nil or spec.transformCausalState ~= nil or spec.compactCausalState ~= nil or spec.causal == true
    if causal and not (isFn(spec.validateCause) and isFn(spec.transformCausalState) and isFn(spec.compactCausalState)) then
        -- Omission means the causal interpretation is unavailable, not
        -- permission to discard its history: the property is admitted with
        -- causal interpretation marked unavailable.
        spec.causalUnavailable = true
    end
    spec.causal = causal
    return issue(self, G.KIND_PROPERTY, propertyId, spec)
end

--- The property registration for a propertyId, or nil.
function G:property(propertyId)
    return self:get(G.KIND_PROPERTY, propertyId)
end

-- ---------------------------------------------------------
-- registerConsumer(consumerId, spec)
-- ---------------------------------------------------------
function G:registerConsumer(consumerId, spec)
    if not nonempty(consumerId, 64) then return nil, "INVALID_ID" end
    if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
    if not positiveInt(spec.version) then return nil, "VERSION" end
    if type(spec.requiredSchemas) ~= "table" then return nil, "REQUIRED_SCHEMAS" end
    for pid, ver in pairs(spec.requiredSchemas) do
        if not nonempty(pid, 128) or not positiveInt(ver) then return nil, "REQUIRED_SCHEMAS" end
    end
    if not stringList(spec.materialKinds, SGRecords.MATERIAL_KINDS) or #spec.materialKinds == 0 then return nil, "MATERIAL_KINDS" end
    if not isFn(spec.resolveReadContext) then return nil, "CALLBACKS" end
    return issue(self, G.KIND_CONSUMER, consumerId, spec)
end

-- ---------------------------------------------------------
-- registerManagementOwner(ownerId, spec)
-- ---------------------------------------------------------
function G:registerManagementOwner(ownerId, spec)
    if not nonempty(ownerId, 64) then return nil, "INVALID_ID" end
    if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
    if not positiveInt(spec.version) then return nil, "VERSION" end
    if not stringList(spec.targetKinds, G.TARGET_KINDS) or #spec.targetKinds == 0 then return nil, "TARGET_KINDS" end
    if not isFn(spec.enumerateTargets) or not isFn(spec.resolveTarget) or not isFn(spec.readTarget) or not isFn(spec.hasAccess)
        or not isFn(spec.getActions) or not isFn(spec.invoke) then
        return nil, "CALLBACKS"
    end
    if not optFn(spec.readPending) or not optFn(spec.onPendingComplete) or not optFn(spec.quoteAction) or not optFn(spec.validateQuote)
        or not optFn(spec.executeAction) or not optFn(spec.getNavigationCarrierId) then
        return nil, "OPTIONAL_CALLBACKS"
    end
    return issue(self, G.KIND_MANAGEMENT, ownerId, spec)
end

--- Validate one action declaration returned by getActions. QUOTED admission
--- needs the owner's quote trio; a missing or unknown controlKind leaves
--- only that action unavailable.
function G.validateAction(spec, a)
    if type(a) ~= "table" then return nil, "MALFORMED" end
    if not nonempty(a.actionId, 64) or not G.TARGET_KINDS[a.targetKind] or not nonempty(a.targetId, 512) then return nil, "MALFORMED" end
    if not nonempty(a.expectedRevision, 64) then return nil, "MALFORMED" end
    if a.expectedGeneration ~= nil and not nonempty(a.expectedGeneration, 64) then return nil, "MALFORMED" end
    if not nonempty(a.argumentSchemaId, 128) then return nil, "MALFORMED" end
    local out = {
        actionId = a.actionId, targetKind = a.targetKind, targetId = a.targetId, expectedGeneration = a.expectedGeneration,
        expectedRevision = a.expectedRevision, available = a.available == true, reasonCode = tostring(a.reasonCode or ""),
        argumentSchemaId = a.argumentSchemaId, argumentContext = a.argumentContext, controlKind = a.controlKind, admission = a.admission,
    }
    if not G.CONTROL_KINDS[a.controlKind] then
        out.available = false
        out.controlKind = "UNAVAILABLE"
        out.reasonCode = "CONTROL_KIND_UNKNOWN"
    end
    if not G.ADMISSION[a.admission] then
        out.available = false
        out.admission = "UNAVAILABLE"
        out.reasonCode = "ADMISSION_UNKNOWN"
    elseif a.admission == "QUOTED" and not (isFn(spec.quoteAction) and isFn(spec.validateQuote) and isFn(spec.executeAction)) then
        out.available = false
        out.reasonCode = "QUOTE_CALLBACKS_MISSING"
    end
    if out.argumentContext ~= nil and not SGRecords.isPayloadTree(out.argumentContext) then out.argumentContext = nil end
    return out
end

-- ---------------------------------------------------------
-- registerSaveSection(sectionId, spec)
-- ---------------------------------------------------------
function G:registerSaveSection(sectionId, spec)
    if not nonempty(sectionId, 64) then return nil, "INVALID_ID" end
    if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
    if not positiveInt(spec.schemaVersion) then return nil, "SCHEMA_VERSION" end
    if spec.dependencies ~= nil and not stringList(spec.dependencies) then return nil, "DEPENDENCIES" end
    if not isFn(spec.serialize) or not isFn(spec.stageLoad) or not isFn(spec.commitLoad) or not isFn(spec.clearReadiness) then return nil, "CALLBACKS" end
    if spec.farmRestorePolicy ~= nil and not G.FARM_RESTORE_POLICY[spec.farmRestorePolicy] then return nil, "FARM_RESTORE_POLICY" end
    spec.farmRestorePolicy = spec.farmRestorePolicy or "INVARIANT"
    spec.dependencies = spec.dependencies or {}
    return issue(self, G.KIND_SAVE_SECTION, sectionId, spec)
end

-- ---------------------------------------------------------
-- registerCarrierPending(ownerId, spec)
-- ---------------------------------------------------------
function G:registerCarrierPending(ownerId, spec)
    if not nonempty(ownerId, 64) then return nil, "INVALID_ID" end
    if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
    if not nonempty(spec.sectionId, 64) or not nonempty(spec.collectionPath, 256) then return nil, "COLLECTION" end
    if not positiveInt(spec.schemaVersion) then return nil, "SCHEMA_VERSION" end
    if not isFn(spec.validatePending) or not isFn(spec.prepareCreationBinding) then return nil, "CALLBACKS" end
    if self:count(G.KIND_CARRIER_PENDING) > 0 then return nil, "ONE_COLLECTION" end
    return issue(self, G.KIND_CARRIER_PENDING, ownerId, spec)
end

-- ---------------------------------------------------------
-- unregisterOwner(lease)
-- ---------------------------------------------------------
function G:unregisterOwner(lease)
    if not self:isLive(lease) then return false, "NOT_LIVE" end
    lease.live = false
    self.leases[lease.leaseId] = nil
    local t = self.byKindAndId[lease.kind]
    if t ~= nil and t[lease.ownerId] == lease then t[lease.ownerId] = nil end
    if type(self.onUnregister) == "function" then pcall(self.onUnregister, lease) end
    return true
end

--- Mission teardown: every lease dies; owners are told once.
function G:clear()
    for _, lease in pairs(self.leases) do
        lease.live = false
        if type(self.onUnregister) == "function" then pcall(self.onUnregister, lease) end
    end
    self.leases = {}
    self.byKindAndId = {}
end
