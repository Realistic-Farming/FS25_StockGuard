-- =========================================================
-- FS25_StockGuard - the mission handle g_currentMission.stockGuard (SG-1)
-- =========================================================
-- One StockGuard per mission: registry (leases), material store and
-- operations, farm-restore coordinator, save backend, SITE_V1 binding,
-- views, command sessions and the private transport. The public methods on
-- the handle are dot-bound closures (no implicit self), matching the WT-8
-- provider convention Bob fixed for step 1.
--
-- Lifecycle (server and client):
--   attach(mission)            at Mission00.load: model, coordinator hooks,
--                              handle published, StateLedger registration
--                              (delivery may be immediate, so the model and
--                              coordinator exist first)
--   onLoadMission00Finished    early: own-XML load when no ledger, NS-7 route
--                              selection attempt, SITE binding attempt
--   observer after            FSBaseMission.onFinishedLoading's original body
--   onFinishedLoading:         the restore-complete barrier. Installed on the
--                              mission instance AFTER SG-6's class wrapper is
--                              in the chain, so SG-6's conditional overwrite
--                              still suppresses the parent call on failure and
--                              this observer never bypasses it. Carrier
--                              enumeration, staged metadata restore, SITE and
--                              route retries, capacity publication.
--   delete()                   teardown: token withdrawn first, wrappers
--                              restored only when still ours, leases dead.
-- =========================================================

StockGuard = StockGuard or {}
local SG = StockGuard
local StockGuard_mt = { __index = SG }

SG.VERSION = "0.2.0"
SG.PURPOSE_LABEL_KEY = "sg_site_purpose_yard"

local function log(msg) print("[StockGuard] " .. tostring(msg)) end

local function serverTimeSec()
    if getTimeSec ~= nil then return getTimeSec() end
    return nil
end

function SG.new(mission)
    local self = setmetatable({}, StockGuard_mt)
    self.mission = mission
    SG._epoch = (SG._epoch or 0) + 1
    self.loadEpoch = tostring(SG._epoch)
    self.registry = SGRegistry.new(self.loadEpoch)
    self.operations = SGOperations.new(self.registry, self.loadEpoch)
    self.coordinator = SGFarmRestore.new(self.loadEpoch)
    self.save = SGSave.new(self.registry, self.operations, self.coordinator)
    self.sites = SGSiteBinding.new()
    self.views = SGViews.new(self.registry, self.operations, self.sites)
    self.views.loadEpoch = self.loadEpoch
    self.commands = SGCommands.new(self.registry, serverTimeSec)
    self.transport = SGTransport.new(self.views, self.commands)
    self.transport.stockGuard = self
    self.capacity = nil
    self.finishedLoadingObserved = false
    self.enumerated = false
    self.serverSession = "1"
    self.viewEpoch = "1"
    self.publicationId = "0"
    self.fallbackSubscribers = {}   -- connectionId -> connection (fallback route only)
    local host = self
    self.coordinator.onStage = function(_, payload, context) host:onStagedRestore(payload, context) end
    self.operations.onChanged = function() host:onMaterialChanged() end
    self.registry.onUnregister = function(lease) host:onLeaseGone(lease) end
    self.sites.onChanged = function(siteId, revision, kind, ownerFarmId) host:onSiteChanged(siteId, revision, kind, ownerFarmId) end
    return self
end

function SG:isServer()
    local m = self.mission or g_currentMission
    return m ~= nil and m.getIsServer ~= nil and m:getIsServer() == true
end

-- ---------------------------------------------------------
-- Attach and the public handle
-- ---------------------------------------------------------
--- Build the handle: every public method is a dot-bound closure.
function SG:buildHandle()
    local host = self
    local h = self
    -- Registrations
    h.registerCarrierAdapter = function(adapterId, spec) return host.registry:registerCarrierAdapter(adapterId, spec) end
    h.registerProperty = function(propertyId, spec) return host.registry:registerProperty(propertyId, spec) end
    h.registerConsumer = function(consumerId, spec) return host.registry:registerConsumer(consumerId, spec) end
    h.registerManagementOwner = function(ownerId, spec) return host.registry:registerManagementOwner(ownerId, spec) end
    h.registerSaveSection = function(sectionId, spec) return host.registry:registerSaveSection(sectionId, spec) end
    h.registerCarrierPending = function(ownerId, spec) return host.registry:registerCarrierPending(ownerId, spec) end
    h.unregisterOwner = function(lease) return host.registry:unregisterOwner(lease) end
    -- Server-local material services
    h.bindCarrier = function(lease, binding, nativeState) return host.operations:bindCarrier(lease, binding, nativeState) end
    h.observeCarrier = function(lease, carrierId, nativeState) if not host.registry:isLive(lease, SGRegistry.KIND_CARRIER_ADAPTER) then return nil, "LEASE" end return host.operations:reconcileCarrier(carrierId, nativeState, "ADAPTER_OBSERVATION") end
    h.withdrawCarrier = function(lease, carrierId, reason) if not host.registry:isLive(lease, SGRegistry.KIND_CARRIER_ADAPTER) then return false, "LEASE" end return host.operations:withdrawCarrier(carrierId, reason) end
    h.captureOperation = function(lease, kind, participants) return host.operations:captureOperation(lease, kind, participants) end
    h.settleOperation = function(handle, report) return host.operations:settleOperation(handle, report) end
    h.abandonOperation = function(handle, reason, participantsAfter) return host.operations:abandonOperation(handle, reason, participantsAfter) end
    h.publishProperties = function(lease, results, cause) return host.operations:publishProperties(lease, results, cause) end
    h.readMaterial = function(lease, query) return host.operations:readMaterial(lease, query) end
    h.visitOwnedPropertyRecords = function(lease, cursor, limit) return host.operations:visitOwnedPropertyRecords(lease, cursor, limit) end
    h.readPropertyMix = function(lease, contributions, context) return host.operations:readPropertyMix(lease, contributions, context) end
    -- Views and capabilities
    h.getCapabilities = function() return host.views:getCapabilities() end
    h.getManagementView = function(trustedActorContext, selection, readOptions) return host.views:getManagementView(trustedActorContext, selection, readOptions, true) end
    h.getRecipeLibraryView = function() return { state = "UNAVAILABLE", reason = "RECIPE_LIBRARY_OWNER_ABSENT" } end
    h.resolveActor = function(connection) return SG.resolveActorFor(host, connection) end
    h.farmRestoreContext = function() return host.coordinator:context() end
    h.getStatus = function() return SG.status(host) end
    return h
end

--- Create, wire and publish the handle on the mission.
function SG.attach(mission)
    if mission == nil then return nil end
    if mission.stockGuard ~= nil and getmetatable(mission.stockGuard) == StockGuard_mt then return mission.stockGuard end
    local self = SG.new(mission)
    self:buildHandle()
    SGFarmRestore.installHooks()
    SGFarmRestore.setCurrent(self.coordinator)
    mission.stockGuard = self
    if self:isServer() then
        self.save:registerBackend(mission)
    end
    log("mission handle published (SG-1 foundation " .. SG.VERSION .. ", epoch " .. self.loadEpoch .. ")")
    return self
end

-- ---------------------------------------------------------
-- Actor resolution (server)
-- ---------------------------------------------------------
--- Trusted actor for a connection (nil = the local host). The route is
--- UserManager:getUserByConnection, User:getId and FSBaseMission:getFarmId
--- (FSBaseMission.lua:1067). Never a client farm number, never farm 1 by
--- default. A dedicated server has no implicit local farmer.
function SG:resolveActorFor(connection)
    local m = self.mission or g_currentMission
    local actor = { connectionId = nil, userId = nil, farmId = nil, actorState = "WAITING", isMasterUser = false, isLocal = connection == nil }
    if m == nil then return actor end
    if connection == nil then
        if g_dedicatedServer ~= nil then
            actor.actorState = "INVALID"
            return actor
        end
        actor.connectionId = "local"
        actor.userId = m.playerUserId
        actor.isMasterUser = true
        if m.getFarmId ~= nil then
            local ok, id = pcall(m.getFarmId, m)
            if ok then actor.farmId = id end
        end
    else
        actor.connectionId = tostring(connection.streamId or tostring(connection))
        local user = nil
        if m.userManager ~= nil and m.userManager.getUserByConnection ~= nil then user = m.userManager:getUserByConnection(connection) end
        if user ~= nil then
            if user.getId ~= nil then actor.userId = user:getId() end
            if user.getIsMasterUser ~= nil then actor.isMasterUser = user:getIsMasterUser() == true else actor.isMasterUser = user.isMasterUser == true end
        end
        if m.getFarmId ~= nil then
            local ok, id = pcall(m.getFarmId, m, connection)
            if ok then actor.farmId = id end
        end
        if user == nil then return actor end
    end
    local c = SGRecords.farmConstants()
    if actor.farmId == nil then actor.actorState = "WAITING"
    elseif actor.farmId == c.spectator then actor.actorState = "SPECTATOR"
    elseif not SGRecords.isOrdinaryFarmId(actor.farmId) then actor.actorState = "INVALID"
    else actor.actorState = "RESOLVED" end
    return actor
end

-- ---------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------
function SG:onLoadMission00Finished()
    if self:isServer() and self.save.backendId == SGSave.BACKEND_XML then
        self.save:loadFromXML(self.mission.missionInfo)
    end
    self:tryRoute()
    self:trySites()
end

--- Install the restore-complete observer on the mission instance after the
--- original body (WT-8 pattern). The class chain already holds SG-6's
--- wrapper; this instance wrapper calls the current class method, so a
--- suppressed parent call stays suppressed.
function SG:installFinishedLoadingObserver()
    local mission = self.mission
    if mission == nil or type(mission.onFinishedLoading) ~= "function" or self.finishedLoadingWrapper ~= nil then return end
    local host = self
    local original = mission.onFinishedLoading
    local wrapper = function(m, ...)
        local results = { original(m, ...) }
        if host.mission == m and m.stockGuard == host then pcall(host.onFinishedLoadingObserved, host) end
        return unpack(results)
    end
    self.finishedLoadingWrapper = wrapper
    self.finishedLoadingOriginal = original
    mission.onFinishedLoading = wrapper
end

function SG:removeFinishedLoadingObserver()
    local mission = self.mission
    if mission ~= nil and self.finishedLoadingWrapper ~= nil and mission.onFinishedLoading == self.finishedLoadingWrapper then
        mission.onFinishedLoading = self.finishedLoadingOriginal
    end
    self.finishedLoadingWrapper, self.finishedLoadingOriginal = nil, nil
end

--- The native restore-complete barrier.
function SG:onFinishedLoadingObserved()
    if self.finishedLoadingObserved then return end
    if StockGuardCapacity ~= nil then self.capacity = StockGuardCapacity end
    -- SG-6's conditional overwrite suppressed the parent call: loading is
    -- being cancelled, nothing is complete, and this observer marks nothing.
    if self.capacity ~= nil and type(self.capacity.isReady) == "function" and not self.capacity:isReady() then
        log("finished-loading observed while capacity is not READY; restore barrier not marked")
        return
    end
    self.finishedLoadingObserved = true
    if self:isServer() then
        self.coordinator:observeFarmsLoadedWithoutMerge()
        self:enumerateCarriers()
        self.coordinator:observeNativeReady()
    end
    self:tryRoute()
    self:trySites()
    self.views.ready = true
    self.views.reasonCode = "READY"
    self.transport:markDirty()
    log("restore-complete barrier observed; views READY")
end

--- Every registered adapter enumerates its actual carriers once after the
--- barrier; late registrations enumerate on registration.
function SG:enumerateCarriers()
    for adapterId, lease in self.registry:each(SGRegistry.KIND_CARRIER_ADAPTER) do
        self:enumerateAdapter(lease)
    end
    self.enumerated = true
end

function SG:enumerateAdapter(lease)
    local ok, list = pcall(lease.spec.enumerateCarriers)
    if not ok or type(list) ~= "table" then
        log("adapter " .. tostring(lease.ownerId) .. " enumeration failed; its carriers stay unavailable")
        return 0
    end
    local n = 0
    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.binding ~= nil then
            local c = self.operations:bindCarrier(lease, entry.binding, entry.nativeState)
            if c ~= nil then n = n + 1 end
        end
    end
    return n
end

--- Staged metadata restore once payload, farms and native objects exist.
function SG:onStagedRestore(payload, context)
    if not self:isServer() then return end
    local result = self.save:stageLoad(payload, context)
    log(string.format("staged restore: %s (farm phase %s, core restored %s unknown %s historical %s)", tostring(result.state), tostring(context.phase),
        tostring(result.core and result.core.restored or 0), tostring(result.core and result.core.unknown or 0), tostring(result.core and result.core.historical or 0)))
    self.transport:markDirty()
end

function SG:tryRoute()
    local route = self.transport:selectRoute(self.mission)
    if route ~= nil and not self.routeLogged then
        self.routeLogged = true
        log("private view route: " .. route)
    end
end

function SG:trySites()
    if self.sites.available then return end
    local label = (g_i18n ~= nil and g_i18n.getText ~= nil) and g_i18n:getText(SG.PURPOSE_LABEL_KEY) or "StockGuard yard"
    local ok, reason = self.sites:bind(self.mission, label)
    if ok and not self.sitesLogged then
        self.sitesLogged = true
        log("SITE_V1 provider bound (WorkplaceTriggers), purpose stockguard.yard registered")
    elseif not ok and reason ~= "NO_PROVIDER" and not self.sitesReasonLogged then
        self.sitesReasonLogged = true
        log("SITE_V1 provider not usable: " .. tostring(reason) .. "; FARM view remains")
    end
end

function SG:onSiteChanged(siteId, revision, kind, ownerFarmId)
    self.views:resetDomain()
    self.commands:withdrawAll("SITE_CHANGED")
    self.transport:markDirty()
end

function SG:onMaterialChanged()
    self.transport:markDirty()
end

function SG:onLeaseGone(lease)
    if lease.kind == SGRegistry.KIND_CARRIER_ADAPTER then self.operations:withdrawAdapter(lease.ownerId, "ADAPTER_UNREGISTERED") end
    if lease.kind == SGRegistry.KIND_MANAGEMENT then self.commands:withdrawAll("OWNER_UNREGISTERED") end
    self.views:resetDomain()
    self.transport:markDirty()
end

--- Native local farm change: private state is revoked before replacement.
function SG:onPlayerFarmChanged(player)
    if self:isServer() then
        self.commands:withdrawAll("FARM_CHANGED")
        self.views:resetDomain()
        self.transport:markDirty()
    else
        self.transport:clearReplica("FARM_CHANGED")
    end
end

function SG:onFarmDeleted(farmId)
    if not self:isServer() then return end
    self.commands:withdrawAll("FARM_DELETED")
    self.views:resetDomain()
    self.transport:markDirty()
end

function SG:onConnectionClosed(connection)
    local id = connection ~= nil and tostring(connection.streamId or tostring(connection)) or nil
    if id == nil then return end
    self.transport:clearConnection(id)
    self.fallbackSubscribers[id] = nil
end

-- ---------------------------------------------------------
-- Fallback route handlers (server)
-- ---------------------------------------------------------
function SG:onViewRequest(connection, selection, readOptions)
    if not self:isServer() then return end
    local actor = self:resolveActorFor(connection)
    local id = actor.connectionId or "local"
    local ok, why = self.transport:setSelection(id, selection, readOptions)
    if not ok then
        self:sendViewState(connection, "UNAVAILABLE", why, nil)
        return
    end
    self.viewEpoch = SGValues.incrementDecimal(self.viewEpoch)
    if connection ~= nil then self.fallbackSubscribers[id] = connection end
    self:publishTo(connection, actor)
end

function SG:publishTo(connection, actor)
    actor = actor or self:resolveActorFor(connection)
    local context = { connection = connection, connectionId = actor.connectionId or "local", userId = actor.userId, farmId = actor.farmId, actorState = actor.actorState, serverSession = self.serverSession, subscriptionId = "1", modId = SGTransport.MODULE_ID }
    local result = self.transport:buildView(context, nil, true)
    if result.state ~= "READY" then
        self:sendViewState(connection, result.state, result.reason, nil)
        return
    end
    self:sendViewState(connection, "READY", "", result.values)
end

function SG:sendViewState(connection, state, reason, tokens)
    self.publicationId = SGValues.incrementDecimal(self.publicationId)
    if SGViewStateEvent == nil then return end
    local event = SGViewStateEvent.new(self.serverSession, self.viewEpoch, self.publicationId, state, reason, tokens or {})
    if connection == nil then
        -- Listen-host projection: apply the detached bytes locally.
        self:onViewState(event)
        return
    end
    if connection.isReadyForEvents ~= true and connection.sendEvent == nil then return end
    pcall(function() connection:sendEvent(event) end)
end

--- Republish every fallback subscriber after a dirty mark (called from the
--- host's update tick).
function SG:publishAllFallback()
    if self.transport.route ~= "FALLBACK" or not self.transport.dirty or not self:isServer() then return end
    self.transport.dirty = false
    for id, connection in pairs(self.fallbackSubscribers) do
        if SGRecords.nonemptyString(id) and connection ~= nil and connection.isConnected ~= false then self:publishTo(connection) end
    end
end

-- Client side of the fallback route.
function SG:onViewState(event)
    if event.state ~= "READY" then
        self.transport:clearReplica(event.reason)
        return
    end
    self.transport:applyView({ mode = "FULL", values = event.tokens, dataRevision = event.publicationId })
end

function SG:onCommandRequest(connection, req)
    if not self:isServer() then return end
    local actor = self:resolveActorFor(connection)
    local res = self.commands:handle(actor, req)
    if connection == nil then
        self:onCommandResult(res)
        return
    end
    if SGCommandResultEvent ~= nil then pcall(function() connection:sendEvent(SGCommandResultEvent.new(res)) end) end
    self.transport:markDirty()
end

function SG:onCommandResult(res)
    self.lastCommandResult = res
    if type(self.onCommandResultCallback) == "function" then pcall(self.onCommandResultCallback, res) end
end

-- ---------------------------------------------------------
-- Save participation and status
-- ---------------------------------------------------------
function SG:onSaveToXML(missionInfo)
    if not self:isServer() then return end
    if self.save.backendId == SGSave.BACKEND_XML then self.save:saveToXML(missionInfo) end
end

function SG:status()
    return {
        version = SG.VERSION, epoch = self.loadEpoch, server = self:isServer(), route = self.transport.route or "WAITING",
        backend = self.save.backendId or "NONE", farmPhase = self.coordinator.phase, staged = self.coordinator.staged,
        carriers = (function() local n = 0 for _ in pairs(self.operations.carriers) do n = n + 1 end return n end)(),
        stocks = (function() local n = 0 for _ in pairs(self.operations.stocks) do n = n + 1 end return n end)(),
        sites = self.sites.available, sitesReason = self.sites.reasonCode, viewsReady = self.views.ready,
        adapters = self.registry:count(SGRegistry.KIND_CARRIER_ADAPTER), properties = self.registry:count(SGRegistry.KIND_PROPERTY),
        consumers = self.registry:count(SGRegistry.KIND_CONSUMER), owners = self.registry:count(SGRegistry.KIND_MANAGEMENT),
        sections = self.registry:count(SGRegistry.KIND_SAVE_SECTION),
    }
end

-- ---------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------
function SG:delete()
    SGFarmRestore.setCurrent(nil)
    self:removeFinishedLoadingObserver()
    self.sites:unbind()
    self.transport:teardown()
    self.commands:withdrawAll("MISSION_END")
    self.registry:clear()
    self.operations:clear()
    self.save:clear()
    if self.mission ~= nil and self.mission.stockGuard == self then self.mission.stockGuard = nil end
    self.mission = nil
end
