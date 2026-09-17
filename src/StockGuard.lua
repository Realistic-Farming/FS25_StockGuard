-- =========================================================
-- FS25_StockGuard - the mission handle g_currentMission.stockGuard (SG-1)
-- =========================================================
-- One StockGuard host per mission: registry (leases), material store and
-- operations, farm-restore coordinator, save backend, SITE_V1 binding,
-- views, command sessions and the private transport. The PUBLIC handle on
-- the mission is a separate table of dot-bound closures (no implicit self,
-- the WT-8 provider convention); the host object itself is not reachable
-- through it. Material mutators are server-only.
--
-- Lifecycle (server and client):
--   attach(mission)            at Mission00.load: model, coordinator hooks,
--                              handle published, StateLedger registration
--                              (delivery may be immediate, so the model and
--                              coordinator exist first)
--   onLoadMission00Finished    early: manifest read, own-XML load when no
--                              ledger, NS-7 route and SITE binding attempts,
--                              message subscriptions
--   observer after            FSBaseMission.onFinishedLoading's original body
--   onFinishedLoading:         the restore-complete barrier. Installed on the
--                              mission instance AFTER SG-6's class wrapper is
--                              in the chain, so SG-6's conditional overwrite
--                              still suppresses the parent call on failure and
--                              this observer never bypasses it. Carrier
--                              enumeration, staged metadata restore, SITE and
--                              route retries, capacity publication.
--   update(dt)                 route and SITE retries until resolved, pending
--                              command completion polling, fallback republish
--   delete()                   teardown: token withdrawn first, wrappers
--                              restored only when still ours, message
--                              subscriptions removed, leases dead.
-- =========================================================

StockGuard = StockGuard or {}
local SG = StockGuard
local StockGuard_mt = { __index = SG }

SG.VERSION = "0.2.1"
SG.PURPOSE_LABEL_KEY = "sg_site_purpose_yard"
SG.RETRY_TICKS = 60

-- mission -> host (weak keys); the public handle never exposes the host.
SG._hosts = setmetatable({}, { __mode = "k" })

local function log(msg) print("[StockGuard] " .. tostring(msg)) end

local function serverTimeSec()
    if getTimeSec ~= nil then return getTimeSec() end
    return nil
end

function SG.hostOf(mission)
    if mission == nil then return nil end
    return SG._hosts[mission]
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
    self.save.loadEpoch = self.loadEpoch
    self.sites = SGSiteBinding.new()
    self.views = SGViews.new(self.registry, self.operations, self.sites)
    self.views.loadEpoch = self.loadEpoch
    self.commands = SGCommands.new(self.registry, serverTimeSec)
    self.transport = SGTransport.new(self.views, self.commands)
    self.transport.stockGuard = self
    self.capacity = nil
    self.finishedLoadingObserved = false
    self.enumerated = false
    self.serverSession = "s" .. self.loadEpoch
    self.publicationId = "0"
    self.fallbackSubscribers = setmetatable({}, { __mode = "k" })   -- connection -> actor (fallback route only)
    self.clientOrder = { serverSession = nil, viewEpoch = "0", publicationId = "0" }
    self.tick = 0
    local host = self
    self.coordinator.onStage = function(_, payload, context) host:onStagedRestore(payload, context) end
    self.operations.onChanged = function() host:onMaterialChanged() end
    self.registry.onUnregister = function(lease) host:onLeaseGone(lease) end
    self.registry.onRegister = function(lease) host:onLeaseIssued(lease) end
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
--- Build the handle: a separate table; every public method is a dot-bound
--- closure. Material mutators refuse on a client.
function SG:buildHandle()
    local host = self
    local h = {}
    local function serverOnly(fn)
        return function(...)
            if not host:isServer() then return nil, "NOT_SERVER" end
            return fn(...)
        end
    end
    -- Registrations
    h.registerCarrierAdapter = function(adapterId, spec) return host.registry:registerCarrierAdapter(adapterId, spec) end
    h.registerProperty = function(propertyId, spec) return host.registry:registerProperty(propertyId, spec) end
    h.registerConsumer = function(consumerId, spec) return host.registry:registerConsumer(consumerId, spec) end
    h.registerManagementOwner = function(ownerId, spec) return host.registry:registerManagementOwner(ownerId, spec) end
    h.registerSaveSection = function(sectionId, spec) return host.registry:registerSaveSection(sectionId, spec) end
    h.registerCarrierPending = function(ownerId, spec) return host.registry:registerCarrierPending(ownerId, spec) end
    h.unregisterOwner = function(lease) return host.registry:unregisterOwner(lease) end
    -- Server-local material services
    h.bindCarrier = serverOnly(function(lease, binding, nativeState) return host.operations:bindCarrier(lease, binding, nativeState) end)
    h.observeCarrier = serverOnly(function(lease, carrierId, nativeState) return SG.observeCarrier(host, lease, carrierId, nativeState) end)
    h.refreshCarrier = serverOnly(function(lease, binding, reason) return host.operations:refreshCarrier(lease, binding, reason) end)
    h.withdrawCarrier = serverOnly(function(lease, carrierId, reason) if not host.registry:isLive(lease, SGRegistry.KIND_CARRIER_ADAPTER) then return false, "LEASE" end return host.operations:withdrawCarrier(carrierId, reason) end)
    h.captureOperation = serverOnly(function(lease, kind, participants) return host.operations:captureOperation(lease, kind, participants) end)
    h.settleOperation = serverOnly(function(handle, report) return host.operations:settleOperation(handle, report) end)
    h.abandonOperation = serverOnly(function(handle, reason, participantsAfter) return host.operations:abandonOperation(handle, reason, participantsAfter) end)
    h.publishProperties = serverOnly(function(lease, results, cause) return host.operations:publishProperties(lease, results, cause) end)
    h.readMaterial = serverOnly(function(lease, query) return host.operations:readMaterial(lease, query) end)
    h.visitOwnedPropertyRecords = serverOnly(function(lease, cursor, limit) return host.operations:visitOwnedPropertyRecords(lease, cursor, limit) end)
    h.readPropertyMix = serverOnly(function(lease, contributions, context) return host.operations:readPropertyMix(lease, contributions, context) end)
    h.readCarrierPending = serverOnly(function(lease, carrierKey, trustedActor) return host.operations:readCarrierPending(lease, carrierKey, trustedActor) end)
    h.setCarrierPending = serverOnly(function(lease, carrierKey, expectedEmptyEpoch, expectedSelectionRevision, newTarget, trustedActor) return host.operations:setCarrierPending(lease, carrierKey, expectedEmptyEpoch, expectedSelectionRevision, newTarget, trustedActor) end)
    h.onPendingComplete = serverOnly(function(pendingId, outcome, detail) local ok = host.commands:onPendingComplete(pendingId, outcome, detail) if ok then host.transport:markDirty() end return ok end)
    -- Views and capabilities
    h.getCapabilities = function() return host.views:getCapabilities() end
    h.getManagementView = serverOnly(function(trustedActorContext, selection, readOptions) return host.views:getManagementView(trustedActorContext, selection, readOptions, true) end)
    h.getRecipeLibraryView = function() return { state = "UNAVAILABLE", reason = "RECIPE_LIBRARY_OWNER_ABSENT" } end
    h.resolveActor = serverOnly(function(connection) return SG.resolveActorFor(host, connection) end)
    h.farmRestoreContext = function() return host.coordinator:context() end
    h.requestView = function(selection, readOptions) return host.transport:requestView(selection, readOptions) end
    h.getClientView = function() local c = host.transport.client return { state = c.state, reason = c.reason, usable = c.usable, view = c.replica and SGValues.copy(c.replica) or nil, credentials = c.credentials and SGValues.copy(c.credentials) or nil } end
    h.getStatus = function() return SG.status(host) end
    self.handle = h
    return h
end

--- Create, wire and publish the handle on the mission. Returns the host.
function SG.attach(mission)
    if mission == nil then return nil end
    local existing = SG._hosts[mission]
    if existing ~= nil and mission.stockGuard == existing.handle then return existing end
    local self = SG.new(mission)
    self:buildHandle()
    SGFarmRestore.installHooks()
    SGFarmRestore.setCurrent(self.coordinator)
    SG._hosts[mission] = self
    mission.stockGuard = self.handle
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
        actor.connectionId = SGTransport.LOCAL
        actor.userId = m.playerUserId
        actor.isMasterUser = true
        if m.getFarmId ~= nil then
            local ok, id = pcall(m.getFarmId, m)
            if ok then actor.farmId = id end
        end
    else
        actor.connectionId = SGTransport.connectionIdOf(connection)
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
    if self:isServer() then
        self.save:readManifest(self.mission.missionInfo)
        if self.save.backendId == SGSave.BACKEND_XML then
            self.save:loadFromXML(self.mission.missionInfo)
        end
    end
    self:subscribeMessages()
    self:tryRoute()
    self:trySites()
end

function SG:subscribeMessages()
    if self.messagesSubscribed or g_messageCenter == nil or MessageType == nil then return end
    self.messagesSubscribed = true
    if MessageType.PLAYER_FARM_CHANGED ~= nil then g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.onPlayerFarmChanged, self) end
    if MessageType.FARM_DELETED ~= nil then g_messageCenter:subscribe(MessageType.FARM_DELETED, self.onFarmDeleted, self) end
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
        if host.mission == m and SG._hosts[m] == host then pcall(host.onFinishedLoadingObserved, host) end
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

--- Enumeration names bindings; the core reads each carrier through the join
--- (resolveCarrier then readNativeState). A state the adapter put in the entry
--- is not trusted: the adapter's read is the one path. An entry that cannot be
--- bound is counted and logged, never silently dropped.
function SG:enumerateAdapter(lease)
    local ok, list = pcall(lease.spec.enumerateCarriers)
    if not ok or type(list) ~= "table" then
        log("adapter " .. tostring(lease.ownerId) .. " enumeration failed; its carriers stay unavailable")
        return 0
    end
    local n, refused, firstWhy = 0, 0, nil
    for _, entry in ipairs(list) do
        local binding = type(entry) == "table" and entry.binding or nil
        local c, why = nil, "ENTRY"
        if binding ~= nil then c, why = self.operations:refreshCarrier(lease, binding, "INITIAL_OBSERVATION") end
        if c ~= nil then
            n = n + 1
        else
            refused = refused + 1
            firstWhy = firstWhy or why
        end
    end
    if refused > 0 then
        log(string.format("adapter %s: %d of %d enumerated carriers not bound (first reason %s); they stay unavailable",
            tostring(lease.ownerId), refused, n + refused, tostring(firstWhy)))
    end
    return n
end

--- An adapter observation. With a state, the pushed state reconciles as
--- before. Without one, the core reads the carrier through the join, so an
--- observer that only knows "this carrier changed" never has to guess what it
--- now holds.
function SG:observeCarrier(lease, carrierId, nativeState)
    if not self.registry:isLive(lease, SGRegistry.KIND_CARRIER_ADAPTER) then return nil, "LEASE" end
    local carrier = self.operations.carriers[carrierId]
    if carrier == nil then return nil, "UNKNOWN_CARRIER" end
    -- One adapter never observes another adapter's carrier, pushed or read.
    if carrier.adapterId ~= lease.ownerId then return nil, "ADAPTER_MISMATCH" end
    if nativeState ~= nil then return self.operations:reconcileCarrier(carrierId, nativeState, "ADAPTER_OBSERVATION") end
    return self.operations:refreshCarrier(lease, carrier.binding, "ADAPTER_OBSERVATION")
end

--- Staged metadata restore once payload, farms and native objects exist.
--- The member context carries context.farmRestore (4.7.1).
function SG:onStagedRestore(payload, context)
    if not self:isServer() then return end
    local result = self.save:stageLoad(payload, { farmRestore = context, backend = self.save.backendId, loadEpoch = self.loadEpoch })
    log(string.format("staged restore: %s (farm phase %s, core restored %s unknown %s historical %s superseded %s)", tostring(result.state), tostring(context.phase),
        tostring(result.core and result.core.restored or 0), tostring(result.core and result.core.unknown or 0), tostring(result.core and result.core.historical or 0),
        tostring(result.core and result.core.superseded or 0)))
    if result.reason ~= nil then log("staged restore reason: " .. tostring(result.reason)) end
    self.transport:markDirty()
end

function SG:tryRoute()
    local route = self.transport:selectRoute(self.mission)
    if route ~= nil and not self.routeLogged then
        self.routeLogged = true
        log("private view route: " .. route .. (route == "UNAVAILABLE" and (" (" .. tostring(self.transport.routeReason) .. ")") or ""))
        if route == "FALLBACK" and not self:isServer() then
            -- A fallback client subscribes itself; the server never guesses a selection.
            local ok, why = self.transport:requestView({ route = "STOCK", selectionKind = "FARM" }, {})
            if not ok then log("fallback subscription not sent: " .. tostring(why)) end
        end
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
        log("SITE_V1 provider not usable: " .. tostring(reason) .. "; FARM view remains, retrying")
    end
end

--- Per-frame host tick (appended to FSBaseMission.update): retries until
--- the route and the site provider resolve, pending completion polling,
--- fallback republish.
function SG:update(dt)
    self.tick = self.tick + 1
    if self.tick % SG.RETRY_TICKS == 0 then
        if self.transport.route == nil then self:tryRoute() end
        if not self.sites.available then self:trySites() end
    end
    if self:isServer() then
        if self.commands:pollPending() > 0 then self.transport:markDirty() end
        self:publishAllFallback()
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

function SG:onLeaseIssued(lease)
    if lease.kind == SGRegistry.KIND_SAVE_SECTION then self.save:onSectionRegistered(lease) end
    if lease.kind == SGRegistry.KIND_CARRIER_ADAPTER and self.enumerated and self:isServer() then self:enumerateAdapter(lease) end
    self.transport:markDirty()
end

function SG:onLeaseGone(lease)
    if lease.kind == SGRegistry.KIND_CARRIER_ADAPTER then self.operations:withdrawAdapter(lease.ownerId, "ADAPTER_UNREGISTERED") end
    if lease.kind == SGRegistry.KIND_MANAGEMENT then self.commands:withdrawAll("OWNER_UNREGISTERED") end
    self.views:resetDomain()
    self.transport:markDirty()
end

--- Native farm change (PlayerSetFarmEvent publishes the player; the switch
--- event publishes the old farm): only that player's private state is
--- revoked; a client clears its replica only for the local player.
function SG:onPlayerFarmChanged(subject)
    local userId = nil
    if type(subject) == "table" then
        if type(subject.getUserId) == "function" then local ok, id = pcall(subject.getUserId, subject) if ok then userId = id end end
        if userId == nil and subject.userId ~= nil then userId = subject.userId end
    end
    if self:isServer() then
        if userId ~= nil then
            self.commands:withdrawUser(userId, "FARM_CHANGED")
        else
            -- Not a player (a farm object or unknown shape): the whole domain is revalidated.
            self.commands:withdrawAll("FARM_CHANGED")
            self.views:resetDomain()
        end
        self.transport:markDirty()
    else
        local isLocal = subject == nil or g_localPlayer == nil or subject == g_localPlayer or (userId ~= nil and g_localPlayer.userId == userId)
        if isLocal then
            self.transport:clearReplica("FARM_CHANGED")
            if self.transport.route == "FALLBACK" and self.transport.client.request ~= nil then
                self.transport:requestView(self.transport.client.request.selection, self.transport.client.request.readOptions)
            end
        end
    end
end

function SG:onFarmDeleted(farmId)
    if not self:isServer() then return end
    self.commands:withdrawAll("FARM_DELETED")
    self.views:resetDomain()
    self.transport:markDirty()
end

function SG:onConnectionClosed(connection)
    if connection == nil then return end
    self.commands:withdrawConnection(SGTransport.connectionIdOf(connection), "CONNECTION_CLOSED")
    self.transport:clearConnection(connection)
    self.fallbackSubscribers[connection] = nil
end

-- ---------------------------------------------------------
-- Fallback route handlers (server)
-- ---------------------------------------------------------
--- A view request sets the connection's selection on either route. Only the
--- FALLBACK route answers with a state event; on NS7 the scoped module
--- publishes after the dirty mark, never both transports for one replica.
function SG:onViewRequest(connection, selection, readOptions)
    if not self:isServer() then return end
    local actor = self:resolveActorFor(connection)
    local ok, why = self.transport:setSelection(connection, selection, readOptions)
    if self.transport.route == "NS7" then
        self.transport:markDirty()
        return
    end
    if self.transport.route ~= "FALLBACK" then return end
    if not ok then
        self:sendViewState(connection, "UNAVAILABLE", why, nil)
        return
    end
    if connection ~= nil then self.fallbackSubscribers[connection] = true end
    self:publishTo(connection, actor)
end

function SG:publishTo(connection, actor)
    actor = actor or self:resolveActorFor(connection)
    local context = { connection = connection, connectionId = actor.connectionId or SGTransport.LOCAL, userId = actor.userId, farmId = actor.farmId, actorState = actor.actorState, serverSession = self.serverSession, subscriptionId = "1", modId = SGTransport.MODULE_ID }
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
    local event = SGViewStateEvent.new(self.serverSession, self.views.viewEpoch, self.publicationId, state, reason, tokens or {})
    if connection == nil then
        -- Listen-host projection: apply the detached bytes locally.
        self:onViewState(event)
        return
    end
    if connection.isReadyForEvents ~= true and connection.sendEvent == nil then return end
    pcall(function() connection:sendEvent(event) end)
end

--- Republish every fallback subscriber after a dirty mark (from update).
function SG:publishAllFallback()
    if self.transport.route ~= "FALLBACK" or not self.transport.dirty or not self:isServer() then return end
    self.transport.dirty = false
    for connection in pairs(self.fallbackSubscribers) do
        if connection ~= nil and connection.isConnected ~= false then self:publishTo(connection) end
    end
end

-- Client side of the fallback route: publications are applied in order.
-- A different server session replaces the ordering baseline; a lower view
-- epoch or a publication not after the last applied one is ignored.
function SG:onViewState(event)
    local o = self.clientOrder
    if o.serverSession ~= event.serverSession then
        o.serverSession = event.serverSession
        o.viewEpoch, o.publicationId = "0", "0"
        self.transport:clearReplica("SERVER_SESSION_CHANGED")
    end
    local epochCmp = SGValues.compareDecimal(tostring(event.viewEpoch), o.viewEpoch)
    if epochCmp < 0 then return end
    if epochCmp == 0 and SGValues.compareDecimal(tostring(event.publicationId), o.publicationId) <= 0 then return end
    o.viewEpoch = tostring(event.viewEpoch)
    o.publicationId = tostring(event.publicationId)
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
    self.save:writeManifest(missionInfo)
end

function SG:status()
    return {
        version = SG.VERSION, epoch = self.loadEpoch, server = self:isServer(), route = self.transport.route or ("WAITING:" .. tostring(self.transport.routeReason)),
        backend = self.save.backendId or "NONE", farmPhase = self.coordinator.phase, staged = self.coordinator.staged,
        loadState = self.save.loadResult and self.save.loadResult.state or "PENDING",
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
    if self.messagesSubscribed and g_messageCenter ~= nil and type(g_messageCenter.unsubscribeAll) == "function" then
        pcall(g_messageCenter.unsubscribeAll, g_messageCenter, self)
    end
    self.messagesSubscribed = false
    self.sites:unbind()
    self.transport:teardown()
    self.commands:withdrawAll("MISSION_END")
    self.registry:clear()
    self.operations:clear()
    self.save:clear()
    if self.mission ~= nil then
        if self.mission.stockGuard == self.handle then self.mission.stockGuard = nil end
        if SG._hosts[self.mission] == self then SG._hosts[self.mission] = nil end
    end
    self.mission = nil
end
