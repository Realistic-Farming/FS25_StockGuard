-- =========================================================
-- FS25_StockGuard - capabilities, selection keys, the paged management
-- projection and the SG_APPLICATION_2 STOCK codec (SG-1 4.4, 4.6, 5)
-- =========================================================
-- getManagementView(trustedActorContext, selection, readOptions?) is a
-- detached, read-only, actor-filtered page: it mutates no connection's
-- selection, session, quote or transport baseline. Selection kinds are
-- FARM, SITE(siteId) and GROUND(groundFootprint); readOptions carry an
-- opaque pageCursor, a navigationCarrierId focus (FARM only, no cursor) and
-- the trusted server-local rowKinds filter. A page holds at most 64
-- top-level rows in deterministic UTF-8-byte identity order; an outer
-- cursor binds mission/actor/farm epoch, normalized selection and the
-- identity after which continuation resumes. It carries identity only.
--
-- The STOCK VIEW encodes to SG_VALUES_2 (schemaVersion 2, pagingVersion 1)
-- and decodes on the client through decodeView, which refuses an
-- unsupported route or schema before any row is parsed (TERMINAL,
-- UNSUPPORTED_APPLICATION_VERSION). selectionKey is the lossless
-- token-length concatenation of the encoded selection request.
-- =========================================================

SGViews = SGViews or {}
local W = SGViews
local SGViews_mt = { __index = W }

W.APPLICATION = "SG_APPLICATION_2"
W.STOCK_SCHEMA_VERSION = 2
W.PAGING_VERSION = 1
W.PAGE_ROWS = 64
W.ROUTE_STOCK = "STOCK"
W.ROUTE_RECIPES = "RECIPE_LIBRARY"
W.SELECTION_KINDS = { FARM = true, SITE = true, GROUND = true }
W.ROW_KINDS = { CARRIER = true, STOCK = true, PROCESS = true, OBSERVATION = true }
W.AVAILABILITY = { READY = true, WAITING = true, DENIED = true, UNAVAILABLE = true, ERROR = true }
W.MAX_CURSOR_BYTES = 128
W.MAX_NAVIGATION_BYTES = 4096

local copy = SGValues.copy
local isFinite = SGValues.isFinite
local nonempty = SGRecords.nonemptyString

function W.new(registry, operations, sites)
    local self = setmetatable({}, SGViews_mt)
    self.registry = registry
    self.operations = operations
    self.sites = sites
    self.viewEpoch = "1"          -- bumps on authorization-domain resets (site changes, farm changes)
    self.cursors = {}             -- cursorToken -> cursor record (unsaved, mission-local)
    self.nextCursor = 0
    self.loadEpoch = "1"
    self.ready = false
    self.reasonCode = "NOT_READY"
    return self
end

-- ---------------------------------------------------------
-- Selection normalization and keys
-- ---------------------------------------------------------
--- Normalize a selection request; returns the normalized record or nil, reason.
function W.normalizeSelection(route, selection)
    if route ~= W.ROUTE_STOCK and route ~= W.ROUTE_RECIPES then return nil, "ROUTE" end
    if type(selection) ~= "table" then return nil, "SELECTION" end
    local kind = selection.selectionKind
    if route == W.ROUTE_STOCK then
        if kind == "FARM" then
            if selection.siteId ~= nil or selection.groundFootprint ~= nil or selection.libraryId ~= nil then return nil, "CROSS_KIND_PARAMETERS" end
            return { route = route, selectionKind = "FARM" }
        elseif kind == "SITE" then
            if not nonempty(selection.siteId, 128) or selection.groundFootprint ~= nil or selection.libraryId ~= nil then return nil, "SITE_PARAMETERS" end
            return { route = route, selectionKind = "SITE", siteId = selection.siteId }
        elseif kind == "GROUND" then
            local f = selection.groundFootprint
            if type(f) ~= "table" or not isFinite(f.x) or not isFinite(f.z) or not isFinite(f.radius) or f.radius <= 0 or selection.siteId ~= nil then return nil, "GROUND_PARAMETERS" end
            return { route = route, selectionKind = "GROUND", groundFootprint = { x = f.x, z = f.z, radius = f.radius } }
        end
        return nil, "SELECTION_KIND"
    end
    if kind ~= "LIBRARY" or not nonempty(selection.libraryId, 128) or selection.siteId ~= nil or selection.groundFootprint ~= nil then return nil, "LIBRARY_PARAMETERS" end
    return { route = route, selectionKind = "LIBRARY", libraryId = selection.libraryId }
end

--- Normalize readOptions; rowKinds is trusted server-local and never a
--- client parameter. Returns normalized options or nil, reason.
function W.normalizeReadOptions(normalizedSelection, readOptions, trusted)
    local out = {}
    if readOptions == nil then return out end
    if type(readOptions) ~= "table" then return nil, "READ_OPTIONS" end
    if readOptions.pageCursor ~= nil then
        if normalizedSelection.route ~= W.ROUTE_STOCK then return nil, "CURSOR_ROUTE" end
        if type(readOptions.pageCursor) ~= "string" or readOptions.pageCursor == "" or #readOptions.pageCursor > W.MAX_CURSOR_BYTES then return nil, "CURSOR_MALFORMED" end
        out.pageCursor = readOptions.pageCursor
    end
    if readOptions.navigationCarrierId ~= nil then
        if normalizedSelection.route ~= W.ROUTE_STOCK or normalizedSelection.selectionKind ~= "FARM" then return nil, "NAVIGATION_ROUTE" end
        if out.pageCursor ~= nil then return nil, "NAVIGATION_WITH_CURSOR" end
        if type(readOptions.navigationCarrierId) ~= "string" or readOptions.navigationCarrierId == "" or #readOptions.navigationCarrierId > W.MAX_NAVIGATION_BYTES then return nil, "NAVIGATION_MALFORMED" end
        out.navigationCarrierId = readOptions.navigationCarrierId
    end
    if readOptions.rowKinds ~= nil then
        if not trusted then return nil, "ROW_KINDS_NOT_TRUSTED" end
        if type(readOptions.rowKinds) ~= "table" or #readOptions.rowKinds == 0 then return nil, "ROW_KINDS" end
        local kinds = {}
        for _, k in ipairs(readOptions.rowKinds) do
            if not W.ROW_KINDS[k] then return nil, "ROW_KINDS" end
            kinds[#kinds + 1] = k
        end
        table.sort(kinds)
        out.rowKinds = kinds
    end
    return out
end

--- Canonical selectionKey from a normalized selection plus options.
function W.selectionKey(normalized, options)
    local record = copy(normalized)
    options = options or {}
    if options.pageCursor ~= nil then record.pageCursor = options.pageCursor end
    if options.navigationCarrierId ~= nil then record.navigationCarrierId = options.navigationCarrierId end
    if options.rowKinds ~= nil then record.rowKinds = copy(options.rowKinds) end
    local tokens = SGValues.encode(record)
    return SGValues.selectionKey(tokens)
end

-- ---------------------------------------------------------
-- Capabilities
-- ---------------------------------------------------------
function W:getCapabilities()
    local adapters, properties, owners = {}, {}, {}
    for id, lease in self.registry:each(SGRegistry.KIND_CARRIER_ADAPTER) do adapters[#adapters + 1] = { adapterId = id, version = lease.spec.version, carrierKinds = copy(lease.spec.carrierKinds) } end
    for id, lease in self.registry:each(SGRegistry.KIND_PROPERTY) do properties[#properties + 1] = { propertyId = id, schemaVersion = lease.spec.schemaVersion, producerId = lease.spec.producerId, residency = lease.spec.residency } end
    local quoteReady = false
    for id, lease in self.registry:each(SGRegistry.KIND_MANAGEMENT) do
        owners[#owners + 1] = { ownerId = id, version = lease.spec.version, targetKinds = copy(lease.spec.targetKinds) }
        if type(lease.spec.quoteAction) == "function" and type(lease.spec.validateQuote) == "function" and type(lease.spec.executeAction) == "function" then quoteReady = true end
    end
    local pendingReady = self.registry:count(SGRegistry.KIND_CARRIER_PENDING) > 0
    return {
        applicationSchema = W.APPLICATION,
        stockSchemaVersion = W.STOCK_SCHEMA_VERSION,
        materialSchema = SGRecords.MATERIAL_SCHEMA,
        materialKinds = { "FILL_TYPE", "NATIVE_GROUP" },
        valuesFormat = SGValues.FORMAT_TOKEN,
        managementPagingVersion = self.ready and W.PAGING_VERSION or nil,
        siteSchema = (self.sites ~= nil and self.sites.available) and SGSiteBinding.SCHEMA or nil,
        siteReasonCode = self.sites ~= nil and self.sites.reasonCode or "NOT_BOUND",
        quoteSchema = quoteReady and "SG_QUOTE_1" or nil,
        carrierPendingSchema = pendingReady and "SG_CARRIER_PENDING_1" or nil,
        adapters = adapters, properties = properties, managementOwners = owners,
        ready = self.ready, reasonCode = self.ready and "READY" or self.reasonCode,
    }
end

-- ---------------------------------------------------------
-- Actor context
-- ---------------------------------------------------------
--- A trusted actor context is server-derived: {farmId, userId, actorState,
--- connectionId?, isMasterUser?}. Returns availability, reason.
function W.actorAvailability(actor)
    if type(actor) ~= "table" then return "DENIED", "NO_ACTOR" end
    if actor.actorState == "WAITING" then return "WAITING", "ACTOR_WAITING" end
    if actor.actorState == "SPECTATOR" or actor.actorState == "INVALID" then return "DENIED", "ACTOR_" .. actor.actorState end
    if not SGRecords.isOrdinaryFarmId(actor.farmId) then return "DENIED", "INVALID_FARM" end
    return "READY", nil
end

-- ---------------------------------------------------------
-- Row projection
-- ---------------------------------------------------------
local function carrierAccess(self, carrier, actor)
    local lease = self.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, carrier.adapterId)
    if lease == nil then return false end
    local ok, allowed = pcall(lease.spec.hasAccess, copy(carrier.binding), copy(actor))
    return ok and allowed == true
end

local function amountUnitToken(unit)
    if SGRecords.AMOUNT_UNITS[unit] then return unit end
    if unit == "l" or unit == "litre" or unit == "liter" then return "LITRE" end
    if unit == "kg" then return "KILOGRAM" end
    return nil
end
W.amountUnitToken = amountUnitToken

local function disclosedProperties(self, stock, actor, carrier)
    local out = {}
    local pids = {}
    for pid in pairs(stock.properties) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do
        local p = stock.properties[pid]
        local reg = self.registry:property(pid)
        local disclosed = nil
        if reg ~= nil then
            local context = { purpose = "PLAYER_VIEW", trustedActorContext = copy(actor), carrierBinding = copy(carrier.binding), stockRef = self.operations:stockRef(stock) }
            local ok, d = pcall(reg.spec.disclosure, context, copy(p))
            if ok and type(d) == "table" and SGRecords.isPropertyRecord(d) then
                disclosed = { propertyId = d.propertyId, schemaVersion = d.schemaVersion, producerId = d.producerId, propertyRevision = d.propertyRevision, knowledge = d.knowledge, knownAmount = d.knownAmount, basisAmount = d.basisAmount, amountUnit = d.amountUnit, payload = d.payload, reason = d.reason }
            end
        end
        if disclosed == nil then
            disclosed = { propertyId = pid, schemaVersion = p.schemaVersion, producerId = p.producerId, propertyRevision = p.propertyRevision, knowledge = "UNAVAILABLE", reason = reg and "NOT_DISCLOSED" or "PRODUCER_ABSENT" }
        end
        out[#out + 1] = disclosed
    end
    return out
end

local function navigationOf(self, carrier)
    local lease = self.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, carrier.adapterId)
    if lease == nil or type(lease.spec.getNavigationCarrierId) ~= "function" then return nil, nil end
    local ok, navId, role = pcall(lease.spec.getNavigationCarrierId, copy(carrier.binding))
    if not ok or not nonempty(navId, 4096) then return nil, nil end
    if role ~= nil and not nonempty(role, 32) then return nil, nil end
    return navId, role
end

local function actionsFor(self, targetKind, targetId, actor)
    local actions = {}
    for ownerId, lease in self.registry:each(SGRegistry.KIND_MANAGEMENT) do
        local supported = false
        for _, k in ipairs(lease.spec.targetKinds) do if k == targetKind then supported = true end end
        if supported then
            local okR, binding = pcall(lease.spec.resolveTarget, targetId)
            if okR and binding ~= nil then
                local okA, allowed = pcall(lease.spec.hasAccess, binding, copy(actor))
                if okA and allowed == true then
                    local okG, list = pcall(lease.spec.getActions, binding, copy(actor))
                    if okG and type(list) == "table" then
                        for _, a in ipairs(list) do
                            local v = SGRegistry.validateAction(lease.spec, a)
                            if v ~= nil then v.ownerId = ownerId actions[#actions + 1] = v end
                        end
                    end
                end
            end
        end
    end
    table.sort(actions, function(a, b) return a.actionId < b.actionId end)
    return actions
end

local function carrierRow(self, carrier, actor)
    local n = carrier.native or {}
    local navId, role = navigationOf(self, carrier)
    return {
        rowKind = "CARRIER", carrierId = carrier.carrierId, carrierKind = carrier.binding.profileId,
        label = tostring(n.label or carrier.binding.profileId), positionKnown = n.x ~= nil, x = n.x, z = n.z,
        capacityKnown = n.capacity ~= nil, capacity = n.capacity, capacityUnit = n.capacity ~= nil and amountUnitToken(n.unit) or nil,
        navigationCarrierId = navId, navigationRole = role, actions = actionsFor(self, "CARRIER", carrier.carrierId, actor),
    }
end

local function stockRow(self, stock, carrier, actor)
    local n = carrier.native or {}
    local navId, role = navigationOf(self, carrier)
    return {
        rowKind = "STOCK", stockRef = self.operations:stockRef(stock), carrierId = carrier.carrierId, quantityBasisKey = stock.quantityBasisKey,
        materialRef = copy(stock.materialRef), amount = stock.observedAmount, amountUnit = amountUnitToken(stock.amountUnit) or "UNAVAILABLE",
        label = tostring(n.label or carrier.binding.profileId), positionKnown = n.x ~= nil, x = n.x, z = n.z, knowledge = stock.knowledge,
        properties = disclosedProperties(self, stock, actor, carrier), navigationCarrierId = navId, navigationRole = role,
        actions = actionsFor(self, "STOCK", stock.stockId, actor),
    }
end

--- Enumerate the actor-authorized carriers in the selection, in
--- deterministic identity order.
function W:authorizedCarriers(actor, normalized, options)
    local ids = {}
    for id in pairs(self.operations.carriers) do ids[#ids + 1] = id end
    table.sort(ids)
    local site = nil
    if normalized.selectionKind == "SITE" then
        local s, reason = self.sites ~= nil and self.sites:site(normalized.siteId, actor) or nil, "SITE_UNAVAILABLE"
        if s == nil then return nil, "SITE_UNAVAILABLE" end
        site = s
    end
    local out = {}
    for _, id in ipairs(ids) do
        local c = self.operations.carriers[id]
        local n = c.native or {}
        local inScope = true
        if site ~= nil then inScope = SGSiteBinding.contains(site, n.x, n.z) end
        if normalized.selectionKind == "GROUND" then
            local f = normalized.groundFootprint
            inScope = n.x ~= nil and ((n.x - f.x) ^ 2 + (n.z - f.z) ^ 2) <= f.radius ^ 2
        end
        if options.navigationCarrierId ~= nil then
            local navId = navigationOf(self, c)
            inScope = inScope and navId == options.navigationCarrierId
        end
        if inScope and carrierAccess(self, c, actor) then out[#out + 1] = c end
    end
    return out
end

-- ---------------------------------------------------------
-- Cursors (unsaved derived read cursors)
-- ---------------------------------------------------------
local function cursorBinding(self, actor, normalized, options)
    return SGValues.canonicalKey({ epoch = self.loadEpoch, viewEpoch = self.viewEpoch, farmId = actor.farmId, userId = tostring(actor.userId or ""), selection = normalized, navigation = options.navigationCarrierId, rowKinds = options.rowKinds })
end

function W:issueCursor(binding, lastIdentity)
    self.nextCursor = self.nextCursor + 1
    local token = "c" .. self.loadEpoch .. "." .. tostring(self.nextCursor)
    self.cursors[token] = { binding = binding, lastIdentity = lastIdentity }
    return token
end

function W:resolveCursor(token, binding)
    local c = self.cursors[token]
    if c == nil then return nil, "CURSOR_UNKNOWN" end
    if c.binding ~= binding then return nil, "CURSOR_STALE" end
    return c
end

-- ---------------------------------------------------------
-- getManagementView
-- ---------------------------------------------------------
function W:getManagementView(actor, selection, readOptions, trusted)
    local availability, reason = W.actorAvailability(actor)
    local route = type(selection) == "table" and selection.route or W.ROUTE_STOCK
    local normalized, why = W.normalizeSelection(route, selection)
    if normalized == nil then return { state = "UNAVAILABLE", reason = why, view = nil } end
    local options, whyO = W.normalizeReadOptions(normalized, readOptions, trusted ~= false)
    if options == nil then return { state = "UNAVAILABLE", reason = whyO, view = nil } end
    local baseKey = W.selectionKey(normalized, { navigationCarrierId = options.navigationCarrierId, rowKinds = options.rowKinds })
    local view = {
        schemaVersion = W.STOCK_SCHEMA_VERSION, route = normalized.route, availability = availability, reasonCode = reason or "",
        viewKey = "", dataRevision = self.operations.revision, selectionKind = normalized.selectionKind, selectionKey = W.selectionKey(normalized, options),
        siteId = normalized.siteId, groundFootprint = normalized.groundFootprint, libraryId = normalized.libraryId,
        pagingVersion = W.PAGING_VERSION, pageCursor = options.pageCursor, nextPageCursor = nil, rows = {},
    }
    if availability ~= "READY" then return { state = availability, reason = reason, view = view } end
    if not self.ready then
        view.availability = "WAITING"
        view.reasonCode = self.reasonCode
        return { state = "WAITING", reason = self.reasonCode, view = view }
    end
    if normalized.route == W.ROUTE_RECIPES then
        view.availability = "UNAVAILABLE"
        view.reasonCode = "RECIPE_LIBRARY_OWNER_ABSENT"
        return { state = "UNAVAILABLE", reason = view.reasonCode, view = view }
    end
    local binding = cursorBinding(self, actor, normalized, options)
    view.viewKey = SGValues.canonicalKey({ binding = binding, access = self.viewEpoch })
    local after = nil
    if options.pageCursor ~= nil then
        local c, whyC = self:resolveCursor(options.pageCursor, binding)
        if c == nil then
            view.availability = "UNAVAILABLE"
            view.reasonCode = whyC
            return { state = "STALE", reason = whyC, view = view }
        end
        after = c.lastIdentity
    end
    local carriers, whyS = self:authorizedCarriers(actor, normalized, options)
    if carriers == nil then
        view.availability = "UNAVAILABLE"
        view.reasonCode = whyS
        return { state = "UNAVAILABLE", reason = whyS, view = view }
    end
    local wantKinds = nil
    if options.rowKinds ~= nil then
        wantKinds = {}
        for _, k in ipairs(options.rowKinds) do wantKinds[k] = true end
    end
    local rows = {}
    local lastIdentity = nil
    local truncated = false
    for _, c in ipairs(carriers) do
        if after == nil or c.carrierId > after then
            local stock = c.stockId and self.operations.stocks[c.stockId] or nil
            local produced = {}
            local wantCarrier = wantKinds == nil or wantKinds.CARRIER
            local wantStock = wantKinds == nil or wantKinds.STOCK
            local carrierHasContext = options.navigationCarrierId ~= nil or (#actionsFor(self, "CARRIER", c.carrierId, actor) > 0)
            if stock ~= nil then
                if wantStock then produced[#produced + 1] = stockRow(self, stock, c, actor) end
                if wantCarrier and carrierHasContext then table.insert(produced, 1, carrierRow(self, c, actor)) end
            elseif carrierHasContext and (wantCarrier or wantStock) then
                -- An empty carrier is enumerated only with a current action,
                -- pending context or the selected navigation focus; it stays
                -- the required contextual carrier beside STOCK-only requests.
                produced[#produced + 1] = carrierRow(self, c, actor)
            end
            if #produced > 0 then
                if #rows + #produced > W.PAGE_ROWS then truncated = true break end
                for _, r in ipairs(produced) do rows[#rows + 1] = r end
            end
            lastIdentity = c.carrierId
        end
    end
    view.rows = rows
    if truncated then view.nextPageCursor = self:issueCursor(binding, lastIdentity) end
    return { state = "READY", reason = nil, view = view }
end

--- Authorization-domain change (site notice, farm change, access change):
--- every cursor and view key is invalid.
function W:resetDomain()
    self.viewEpoch = SGValues.incrementDecimal(self.viewEpoch)
    self.cursors = {}
end

-- ---------------------------------------------------------
-- STOCK view codec (SG_VALUES_2)
-- ---------------------------------------------------------
--- Encode a VIEW record to a token array. Optional absent fields are
--- omitted; amounts keep their number tags.
function W.encodeView(view)
    local rows = {}
    for i, r in ipairs(view.rows or {}) do rows[i] = copy(r) end
    local record = {
        application = W.APPLICATION, schemaVersion = view.schemaVersion, route = view.route, availability = view.availability, reasonCode = view.reasonCode or "",
        viewKey = view.viewKey or "", dataRevision = view.dataRevision or "", selectionKind = view.selectionKind or "", selectionKey = view.selectionKey or "",
        siteId = view.siteId, siteRevision = view.siteRevision, groundFootprint = view.groundFootprint, libraryId = view.libraryId,
        commandSessionId = view.commandSessionId, nextSequence = view.nextSequence, pagingVersion = view.pagingVersion, pageCursor = view.pageCursor,
        nextPageCursor = view.nextPageCursor, rows = rows,
    }
    return SGValues.encode(record)
end

local function validateRow(r)
    if type(r) ~= "table" or not W.ROW_KINDS[r.rowKind] then return false end
    if r.rowKind == "STOCK" then
        if not SGRecords.isStockRef(r.stockRef) or not nonempty(r.carrierId, 2048) or not SGRecords.isMaterialRef(r.materialRef) then return false end
        if not SGRecords.isAmount(r.amount) or not nonempty(r.amountUnit, 32) or type(r.label) ~= "string" then return false end
        if type(r.properties) ~= "table" then return false end
    elseif r.rowKind == "CARRIER" then
        if not nonempty(r.carrierId, 2048) or type(r.label) ~= "string" then return false end
    elseif r.rowKind == "PROCESS" then
        if not nonempty(r.processId, 512) or type(r.label) ~= "string" or not nonempty(r.processStateLabelKey, 128) then return false end
    end
    if r.actions ~= nil and type(r.actions) ~= "table" then return false end
    return true
end

--- Decode a token array to a VIEW; the route and schema gate precede any
--- row parsing. Returns view or nil, reason, terminal.
function W.decodeView(tokens)
    local record, why = SGValues.decode(tokens)
    if why ~= nil or type(record) ~= "table" then return nil, why or "MALFORMED", false end
    if record.application ~= W.APPLICATION then return nil, "UNSUPPORTED_APPLICATION_VERSION", true end
    if record.route ~= W.ROUTE_STOCK then return nil, "UNSUPPORTED_ROUTE", true end
    if record.schemaVersion ~= W.STOCK_SCHEMA_VERSION then return nil, "UNSUPPORTED_APPLICATION_VERSION", true end
    if not W.AVAILABILITY[record.availability] then return nil, "MALFORMED", false end
    if type(record.viewKey) ~= "string" or type(record.dataRevision) ~= "string" or type(record.selectionKey) ~= "string" then return nil, "MALFORMED", false end
    if record.availability == "READY" then
        if record.pagingVersion ~= W.PAGING_VERSION then return nil, "UNSUPPORTED_PAGING_VERSION", true end
        if type(record.rows) ~= "table" then return nil, "MALFORMED", false end
        if #record.rows > W.PAGE_ROWS then return nil, "OVERSIZE_PAGE", false end
        for _, r in ipairs(record.rows) do
            if not validateRow(r) then return nil, "MALFORMED_ROW", false end
        end
    else
        if record.rows ~= nil and #record.rows > 0 then return nil, "PRIVATE_ROWS_ON_NON_READY", false end
        if record.commandSessionId ~= nil or record.nextPageCursor ~= nil then return nil, "CREDENTIALS_ON_NON_READY", false end
    end
    return record, nil, false
end
