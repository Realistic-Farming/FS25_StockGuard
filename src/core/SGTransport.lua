-- =========================================================
-- FS25_StockGuard - private view delivery: NS-7 scoped join and the
-- dedicated StockGuard fallback (SG-1 4.5, 5, Appendix A)
-- =========================================================
-- With a supported NS-7 (mission.networkSync:getScopedCapabilities ready)
-- StockGuard registers the scoped module "stockGuard" with buildView /
-- applyView / clearView. buildView reads the connection's current validated
-- STOCK selection, returns WAITING for an unresolved actor, DENIED for a
-- spectator/invalid farm, READY/FULL with the SG_VALUES_2 token array of
-- the page (one NS7 STRING pair per token), and UNCHANGED when the previous
-- descriptor still names the same view key and data revision. Non-READY
-- results carry no private values. Selections are keyed by the connection
-- OBJECT (NS-7 hands the producer context.connection; its own "c<serial>"
-- ids are never assumed), "local" for the listen host.
--
-- Without NS-7 the dedicated pair SGViewRequestEvent (client to server:
-- selection, paging tail) and SGViewStateEvent (server to one connection:
-- the same token array plus session/epoch/publication ordering) carries the
-- identical application bytes and outcomes. Never both transports for one
-- replica, never a public broadcast. SGCommandRequestEvent /
-- SGCommandResultEvent carry SG_COMMAND_2 requests to the server and the
-- typed result back to the requesting connection only. Every event checks
-- its direction on the receiving side (Connection:getIsServer, network/
-- Connection.lua:146-148): a result or state event is accepted only from
-- the server, a request only on the server.
--
-- A present NS-7 that refuses the module registration leaves the route
-- UNAVAILABLE (reported), never a unilateral fallback that could split the
-- server and its clients across two transports.
-- =========================================================

SGTransport = SGTransport or {}
local TR = SGTransport
local SGTransport_mt = { __index = TR }

TR.MODULE_ID = "stockGuard"
TR.PROTOCOL_VERSION = 1
TR.MAX_TOKENS = 4096
TR.LOCAL = "local"

local copy = SGValues.copy

function TR.new(views, commands)
    local self = setmetatable({}, SGTransport_mt)
    self.views = views
    self.commands = commands
    self.route = nil                 -- "NS7", "FALLBACK" or "UNAVAILABLE"
    self.routeReason = "WAITING"
    self.selections = setmetatable({}, { __mode = "k" })   -- connection object (or TR.LOCAL) -> selection
    self.client = { expectedKey = nil, replica = nil, state = "UNAVAILABLE", reason = "NOT_SUBSCRIBED", usable = false, credentials = nil, request = nil }
    self.registered = false
    self.stockGuard = nil            -- back pointer set by the host
    self.dirty = false
    return self
end

local function keyOf(connection)
    if connection == nil then return TR.LOCAL end
    return connection
end
TR.keyOf = keyOf

-- ---------------------------------------------------------
-- Selection per connection (server)
-- ---------------------------------------------------------
function TR:selectionFor(connection)
    local key = keyOf(connection)
    local s = self.selections[key]
    if s == nil then
        s = { normalized = { route = SGViews.ROUTE_STOCK, selectionKind = "FARM" }, options = {} }
        s.selectionKey = SGViews.selectionKey(s.normalized, s.options)
        self.selections[key] = s
    end
    return s
end

--- Validated selection change for a live connection; grants nothing.
function TR:setSelection(connection, selection, readOptions)
    local normalized, why = SGViews.normalizeSelection(selection and selection.route or SGViews.ROUTE_STOCK, selection)
    if normalized == nil then return false, why end
    local options, whyO = SGViews.normalizeReadOptions(normalized, readOptions, false)
    if options == nil then return false, whyO end
    self.selections[keyOf(connection)] = { normalized = normalized, options = options, selectionKey = SGViews.selectionKey(normalized, options) }
    self.dirty = true
    return true
end

function TR:clearConnection(connection)
    self.selections[keyOf(connection)] = nil
end

-- ---------------------------------------------------------
-- Producer (server): buildView(context, previous, forceFull)
-- ---------------------------------------------------------
function TR:buildView(context, previous, forceFull)
    if type(context) ~= "table" then return { state = "ERROR", reason = "CONTEXT" } end
    local actor = { farmId = context.farmId, userId = context.userId, actorState = context.actorState, connectionId = context.connectionId }
    if context.actorState == "WAITING" then return { state = "WAITING", reason = "ACTOR_WAITING" } end
    if context.actorState == "SPECTATOR" or context.actorState == "INVALID" then return { state = "DENIED", reason = "ACTOR_" .. tostring(context.actorState) } end
    local sel = self:selectionFor(context.connection)
    local page = self.views:getManagementView(actor, { route = sel.normalized.route, selectionKind = sel.normalized.selectionKind, siteId = sel.normalized.siteId, groundFootprint = sel.normalized.groundFootprint, libraryId = sel.normalized.libraryId }, sel.options, false)
    if page.view == nil then return { state = "ERROR", reason = tostring(page.reason) } end
    local view = page.view
    if page.state ~= "READY" then
        local st = page.state
        if st == "STALE" then st = "UNAVAILABLE" end
        if not ({ WAITING = true, DENIED = true, UNAVAILABLE = true, ERROR = true })[st] then st = "UNAVAILABLE" end
        return { state = st, reason = tostring(page.reason or view.reasonCode) }
    end
    local creds = self.commands ~= nil and self.commands:credentialsFor(actor, view.route) or nil
    if creds ~= nil then
        view.commandSessionId = creds.commandSessionId
        view.nextSequence = creds.nextSequence
    end
    local dataRevision = SGValues.canonicalKey({ rev = view.dataRevision, sel = view.selectionKey, creds = creds and (creds.commandSessionId .. "/" .. creds.nextSequence) or "" })
    local _, hex = SGSha256.digest(dataRevision)
    dataRevision = "r" .. tostring(#dataRevision) .. ":" .. tostring(hex):sub(1, 32)
    view.dataRevision = dataRevision
    if not forceFull and previous ~= nil and previous.viewKey == view.viewKey and previous.dataRevision == dataRevision then
        return { state = "READY", viewKey = view.viewKey, dataRevision = dataRevision, mode = "UNCHANGED" }
    end
    local tokens = SGViews.encodeView(view)
    if tokens == nil or #tokens > TR.MAX_TOKENS then return { state = "ERROR", reason = "OVERSIZE" } end
    return { state = "READY", viewKey = view.viewKey, dataRevision = dataRevision, mode = "FULL", values = tokens }
end

-- ---------------------------------------------------------
-- Consumer (client): applyView(publication) / clearView(reason)
-- ---------------------------------------------------------
function TR:applyView(publication)
    if type(publication) ~= "table" then return { outcome = "RETRYABLE", reason = "APPLY_ERROR" } end
    local tokens = publication.values
    if not SGValues.isTokenArray(tokens) then return { outcome = "RETRYABLE", reason = "APPLY_ERROR", dataRevision = publication.dataRevision } end
    local view, why, terminal = SGViews.decodeView(tokens)
    if view == nil then
        self:clearReplica(why)
        if terminal then return { outcome = "TERMINAL", reason = "UNSUPPORTED_APPLICATION_VERSION", dataRevision = publication.dataRevision } end
        return { outcome = "RETRYABLE", reason = why, dataRevision = publication.dataRevision }
    end
    if publication.mode ~= "FULL" then return { outcome = "RETRYABLE", reason = "MODE", dataRevision = publication.dataRevision } end
    if self.client.expectedKey ~= nil and view.selectionKey ~= self.client.expectedKey then
        -- A late publication for another selection cannot restore a menu.
        return { outcome = "RETRYABLE", reason = "SELECTION_MISMATCH", dataRevision = publication.dataRevision }
    end
    self.client.replica = view
    self.client.state = view.availability
    self.client.reason = view.reasonCode
    self.client.usable = view.availability == "READY"
    self.client.credentials = view.commandSessionId ~= nil and { commandSessionId = view.commandSessionId, nextSequence = view.nextSequence } or nil
    return { outcome = "APPLIED", reason = nil, dataRevision = publication.dataRevision }
end

function TR:clearView(reason)
    self:clearReplica(reason)
end

function TR:clearReplica(reason)
    self.client.replica = nil
    self.client.usable = false
    self.client.credentials = nil
    self.client.state = "UNAVAILABLE"
    self.client.reason = tostring(reason or "CLEARED")
end

--- The client computes its expected selectionKey from its own request.
function TR:expectSelection(selection, readOptions)
    local normalized, why = SGViews.normalizeSelection(selection and selection.route or SGViews.ROUTE_STOCK, selection)
    if normalized == nil then return nil, why end
    local options, whyO = SGViews.normalizeReadOptions(normalized, readOptions, false)
    if options == nil then return nil, whyO end
    self.client.expectedKey = SGViews.selectionKey(normalized, options)
    self.client.request = { selection = copy(selection), readOptions = copy(readOptions or {}) }
    self:clearReplica("SELECTION_CHANGING")
    return self.client.expectedKey
end

--- Fallback client subscription: compute the expected key and send the
--- request event to the server. Returns true when an event was sent.
function TR:requestView(selection, readOptions, sender)
    selection = selection or { route = "STOCK", selectionKind = "FARM" }
    local key, why = self:expectSelection(selection, readOptions)
    if key == nil then return false, why end
    if self.route ~= "FALLBACK" then return false, "ROUTE" end
    if SGViewRequestEvent == nil then return false, "EVENT_CLASS" end
    local connection = sender
    if connection == nil and g_client ~= nil and type(g_client.getServerConnection) == "function" then connection = g_client:getServerConnection() end
    if connection == nil or type(connection.sendEvent) ~= "function" then return false, "NO_SERVER_CONNECTION" end
    local ok = pcall(function() connection:sendEvent(SGViewRequestEvent.new(selection, readOptions)) end)
    return ok, ok and nil or "SEND_FAILED"
end

-- ---------------------------------------------------------
-- Route selection
-- ---------------------------------------------------------
--- Select NS-7 when its scoped capability is ready; WAITING keeps trying;
--- absent or unsupported selects the dedicated fallback once; a present
--- NS-7 that refuses the registration is UNAVAILABLE, never fallback.
function TR:selectRoute(mission)
    if self.route ~= nil then return self.route end
    local ns = mission ~= nil and mission.networkSync or nil
    if type(ns) == "table" and type(ns.getScopedCapabilities) == "function" and type(ns.registerScopedModule) == "function" then
        local ok, caps = pcall(ns.getScopedCapabilities, ns)
        if ok and type(caps) == "table" then
            local supported = false
            for _, v in ipairs(caps.protocolVersions or {}) do if v == TR.PROTOCOL_VERSION then supported = true end end
            if caps.bootstrapVersion == 1 and supported then
                if caps.ready == true then
                    local transport = self
                    local okR, registered, whyR = pcall(ns.registerScopedModule, ns, TR.MODULE_ID, {
                        buildView = function(context, previous, forceFull) return transport:buildView(context, previous, forceFull) end,
                        applyView = function(publication) return transport:applyView(publication) end,
                        clearView = function(reason) return transport:clearView(reason) end,
                    })
                    if okR and registered == true then
                        self.route = "NS7"
                        self.routeReason = "READY"
                        self.networkSync = ns
                        self.registered = true
                        return self.route
                    end
                    self.route = "UNAVAILABLE"
                    self.routeReason = "NS7_REGISTRATION_REFUSED:" .. tostring(okR and whyR or registered)
                    return self.route
                end
                self.routeReason = tostring(caps.reasonCode or "NS7_WAITING")
                return nil -- compatible and initializing: WAITING, never unilateral fallback
            end
        end
    end
    self.route = "FALLBACK"
    self.routeReason = "READY"
    return self.route
end

function TR:markDirty()
    self.dirty = true
    if self.route == "NS7" and self.networkSync ~= nil and type(self.networkSync.markDirty) == "function" then
        pcall(self.networkSync.markDirty, self.networkSync, TR.MODULE_ID)
    end
end

function TR:teardown()
    if self.route == "NS7" and self.networkSync ~= nil and type(self.networkSync.unregisterScopedModule) == "function" then
        pcall(self.networkSync.unregisterScopedModule, self.networkSync, TR.MODULE_ID)
    end
    self.route = nil
    self.routeReason = "MISSION_END"
    self.networkSync = nil
    self.registered = false
    self.selections = setmetatable({}, { __mode = "k" })
    self:clearReplica("MISSION_END")
end

-- ---------------------------------------------------------
-- Dedicated fallback events (registered at file load)
-- ---------------------------------------------------------
local function writeTokens(streamId, tokens)
    streamWriteInt32(streamId, #tokens)
    for i = 1, #tokens do streamWriteString(streamId, tokens[i]) end
end

--- Read a token array. An oversize count is refused without allocation
--- and reported as OVERSIZE; the caller then disconnects the peer, because
--- the remaining stream cannot be consumed safely.
local function readTokens(streamId)
    local n = streamReadInt32(streamId)
    if n == nil or n < 0 or n > TR.MAX_TOKENS then return nil, "OVERSIZE" end
    local out = {}
    for i = 1, n do
        local s = streamReadString(streamId)
        if type(s) ~= "string" then return nil, "MALFORMED" end
        if #s > SGValues.MAX_STRING_BYTES then return nil, "STRING_TOO_LONG" end
        out[i] = s
    end
    return out
end
TR.writeTokens = writeTokens
TR.readTokens = readTokens

local function hostOnServer()
    local sg = StockGuard ~= nil and StockGuard.hostOf ~= nil and StockGuard.hostOf(g_currentMission) or nil
    if sg == nil or g_currentMission == nil or not g_currentMission:getIsServer() then return nil end
    return sg
end

local function hostOnClient()
    local sg = StockGuard ~= nil and StockGuard.hostOf ~= nil and StockGuard.hostOf(g_currentMission) or nil
    if sg == nil or (g_currentMission ~= nil and g_currentMission:getIsServer()) then return nil end
    return sg
end

--- The sending side of a server-to-client event must be the server.
local function fromServer(connection)
    return type(connection) == "table" and type(connection.getIsServer) == "function" and connection:getIsServer() == true
end
TR.fromServer = fromServer

--- A malformed or oversize event ends that peer's connection on the server.
local function dropPeer(connection, why)
    print("[StockGuard] transport: refusing " .. tostring(why) .. " event; closing the connection")
    if type(connection) ~= "table" then return end
    if g_server ~= nil and type(g_server.closeConnection) == "function" then
        pcall(g_server.closeConnection, g_server, connection)
    elseif type(connection.close) == "function" then
        pcall(connection.close, connection)
    end
end

-- SGViewRequestEvent: client -> server. Body: protocolVersion, route,
-- selectionKind, siteId, groundFootprint (x z radius as %.17g or ""),
-- libraryId, pagingVersion (UInt8), hasPageCursor + cursor, hasNavigation +
-- navigationCarrierId.
if Event ~= nil and Class ~= nil and InitEventClass ~= nil then
    SGViewRequestEvent = SGViewRequestEvent or {}
    local SGViewRequestEvent_mt = Class(SGViewRequestEvent, Event)
    InitEventClass(SGViewRequestEvent, "SGViewRequestEvent")
    function SGViewRequestEvent.emptyNew() return Event.new(SGViewRequestEvent_mt) end
    function SGViewRequestEvent.new(selection, readOptions)
        local self = SGViewRequestEvent.emptyNew()
        self.selection = selection or { route = "STOCK", selectionKind = "FARM" }
        self.readOptions = readOptions or {}
        return self
    end
    function SGViewRequestEvent:writeStream(streamId, connection)
        local s, o = self.selection, self.readOptions
        streamWriteUInt8(streamId, TR.PROTOCOL_VERSION)
        streamWriteString(streamId, tostring(s.route or "STOCK"))
        streamWriteString(streamId, tostring(s.selectionKind or "FARM"))
        streamWriteString(streamId, tostring(s.siteId or ""))
        local f = s.groundFootprint
        streamWriteString(streamId, f and string.format("%.17g", f.x) or "")
        streamWriteString(streamId, f and string.format("%.17g", f.z) or "")
        streamWriteString(streamId, f and string.format("%.17g", f.radius) or "")
        streamWriteString(streamId, tostring(s.libraryId or ""))
        streamWriteUInt8(streamId, SGViews.PAGING_VERSION)
        streamWriteBool(streamId, o.pageCursor ~= nil)
        if o.pageCursor ~= nil then streamWriteString(streamId, o.pageCursor) end
        streamWriteBool(streamId, o.navigationCarrierId ~= nil)
        if o.navigationCarrierId ~= nil then streamWriteString(streamId, o.navigationCarrierId) end
    end
    function SGViewRequestEvent:readStream(streamId, connection)
        self.protocolVersion = streamReadUInt8(streamId)
        local s = { route = streamReadString(streamId), selectionKind = streamReadString(streamId) }
        local siteId = streamReadString(streamId)
        local fx, fz, fr = streamReadString(streamId), streamReadString(streamId), streamReadString(streamId)
        local libraryId = streamReadString(streamId)
        self.pagingVersion = streamReadUInt8(streamId)
        local o = {}
        if streamReadBool(streamId) then o.pageCursor = streamReadString(streamId) end
        if streamReadBool(streamId) then o.navigationCarrierId = streamReadString(streamId) end
        if siteId ~= "" then s.siteId = siteId end
        if libraryId ~= "" then s.libraryId = libraryId end
        if fx ~= "" then s.groundFootprint = { x = SGValues.parseRealToken(fx), z = SGValues.parseRealToken(fz), radius = SGValues.parseRealToken(fr) } end
        self.selection, self.readOptions = s, o
        self:run(connection)
    end
    function SGViewRequestEvent:run(connection)
        local sg = hostOnServer()
        if sg == nil then return end
        if self.protocolVersion ~= TR.PROTOCOL_VERSION or self.pagingVersion ~= SGViews.PAGING_VERSION then return end
        if (self.readOptions.pageCursor ~= nil and self.readOptions.pageCursor == "") or (self.readOptions.navigationCarrierId ~= nil and self.readOptions.navigationCarrierId == "") then return end
        sg:onViewRequest(connection, self.selection, self.readOptions)
    end

    -- SGViewStateEvent: server -> one connection. Body: serverSession,
    -- viewEpoch, publicationId, state, reason, then the token array.
    SGViewStateEvent = SGViewStateEvent or {}
    local SGViewStateEvent_mt = Class(SGViewStateEvent, Event)
    InitEventClass(SGViewStateEvent, "SGViewStateEvent")
    function SGViewStateEvent.emptyNew() return Event.new(SGViewStateEvent_mt) end
    function SGViewStateEvent.new(serverSession, viewEpoch, publicationId, state, reason, tokens)
        local self = SGViewStateEvent.emptyNew()
        self.serverSession, self.viewEpoch, self.publicationId = serverSession, viewEpoch, publicationId
        self.state, self.reason, self.tokens = state, reason or "", tokens or {}
        return self
    end
    function SGViewStateEvent:writeStream(streamId, connection)
        streamWriteString(streamId, self.serverSession)
        streamWriteString(streamId, self.viewEpoch)
        streamWriteString(streamId, self.publicationId)
        streamWriteString(streamId, self.state)
        streamWriteString(streamId, self.reason)
        writeTokens(streamId, self.tokens)
    end
    function SGViewStateEvent:readStream(streamId, connection)
        self.serverSession = streamReadString(streamId)
        self.viewEpoch = streamReadString(streamId)
        self.publicationId = streamReadString(streamId)
        self.state = streamReadString(streamId)
        self.reason = streamReadString(streamId)
        self.tokens, self.tokensError = readTokens(streamId)
        self:run(connection)
    end
    function SGViewStateEvent:run(connection)
        local sg = hostOnClient()
        if sg == nil or not fromServer(connection) then return end
        if self.tokens == nil then
            sg.transport:clearReplica("TRANSPORT_" .. tostring(self.tokensError))
            return
        end
        sg:onViewState(self)
    end

    -- SGCommandRequestEvent: client -> server, SG_COMMAND_2 as tokens.
    SGCommandRequestEvent = SGCommandRequestEvent or {}
    local SGCommandRequestEvent_mt = Class(SGCommandRequestEvent, Event)
    InitEventClass(SGCommandRequestEvent, "SGCommandRequestEvent")
    function SGCommandRequestEvent.emptyNew() return Event.new(SGCommandRequestEvent_mt) end
    function SGCommandRequestEvent.new(request)
        local self = SGCommandRequestEvent.emptyNew()
        self.request = request
        return self
    end
    function SGCommandRequestEvent:writeStream(streamId, connection)
        local tokens = SGValues.encode(self.request) or {}
        writeTokens(streamId, tokens)
    end
    function SGCommandRequestEvent:readStream(streamId, connection)
        self.tokens, self.tokensError = readTokens(streamId)
        self:run(connection)
    end
    function SGCommandRequestEvent:run(connection)
        local sg = hostOnServer()
        if sg == nil then return end
        if self.tokens == nil then
            dropPeer(connection, self.tokensError)
            return
        end
        local req = SGValues.decode(self.tokens)
        if type(req) ~= "table" then return end
        sg:onCommandRequest(connection, req)
    end

    -- SGCommandResultEvent: server -> the requesting connection only.
    SGCommandResultEvent = SGCommandResultEvent or {}
    local SGCommandResultEvent_mt = Class(SGCommandResultEvent, Event)
    InitEventClass(SGCommandResultEvent, "SGCommandResultEvent")
    function SGCommandResultEvent.emptyNew() return Event.new(SGCommandResultEvent_mt) end
    function SGCommandResultEvent.new(result)
        local self = SGCommandResultEvent.emptyNew()
        self.result = result
        return self
    end
    function SGCommandResultEvent:writeStream(streamId, connection)
        writeTokens(streamId, SGValues.encode(self.result) or {})
    end
    function SGCommandResultEvent:readStream(streamId, connection)
        self.tokens, self.tokensError = readTokens(streamId)
        self:run(connection)
    end
    function SGCommandResultEvent:run(connection)
        local sg = hostOnClient()
        if sg == nil or not fromServer(connection) or self.tokens == nil then return end
        local res = SGValues.decode(self.tokens)
        if type(res) == "table" then sg:onCommandResult(res) end
    end
end
