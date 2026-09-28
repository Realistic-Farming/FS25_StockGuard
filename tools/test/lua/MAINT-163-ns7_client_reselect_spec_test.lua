-- MAINT-163-ns7_client_reselect_spec_test.lua
--
-- MAINTENANCE row 163: on the NS7 route a remote client's selection change never
-- reached the server. SGTransport:requestView cleared the client's view and
-- recorded the new expected key, then refused anything but FALLBACK, so no
-- SGViewRequestEvent was sent; the server kept the old selection, and every later
-- NS-7 publication was refused as SELECTION_MISMATCH. The page stayed empty for the
-- session. The brief sends a selection change by SGViewRequestEvent on either route
-- and NS-7's buildView reads that connection's current selection (SG-1/NS-7 brief
-- :502, :508); the server already takes it on NS7. The fix is on the client: the
-- request is sent on NS7 too, and a request that is not sent clears nothing.
--
-- THE ENTRY-POINT BAR IS GROUP S. Two processes, both booted through main.lua's own
-- appends: a server whose NetworkSync reports ready, and a pure client whose own
-- selectRoute chooses NS7. They talk over a modelled remote connection pair: every
-- event is written with writeStream, read with readStream on the other side, and run
-- there with that process as the current mission. The server's goods enter through
-- the engine's StorageSystem and through a companion carrier adapter registered on the
-- handle; both are enumerated at the restore barrier. Nothing writes a carrier, a
-- stock, a selection or a replica.
--
-- Groups:
--   S  the entry-point bar: FARM, then GROUND, then FARM again, through the client's
--      handle, READY with the new selection's rows each time
--   L  a publication built for the old selection cannot restore the old page
--   F  a request that is not sent leaves the view as it was
--   B  a FALLBACK client is unchanged, and requestView no longer reports SEND_FAILED
--      on success
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local WHEAT = ENGINE_FT.WHEAT
NetworkNode = NetworkNode or { LOCAL_STREAM_ID = 0 }   -- network/NetworkNode.lua:3

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── two processes in one Lua state: each call runs as the process it belongs to,
-- with that process's g_currentMission, g_server and g_client (BaseMission.lua:689-693).
local function inProcess(m, fn, ...)
    local saved = { g_currentMission, g_server, g_client }
    g_currentMission, g_server, g_client = m, m and m._gServer or nil, m and m._gClient or nil
    local r = { pcall(fn, ...) }
    g_currentMission, g_server, g_client = saved[1], saved[2], saved[3]
    if not r[1] then error(r[2], 0) end
    return r[2], r[3]
end

-- ── a remote connection pair (network/Connection.lua, the non-local branch) ──────
-- sendEvent writes the event to a stream; the other process reads it into a fresh
-- instance of the same class and runs it with its own receiving connection, while
-- that process is g_currentMission.
local function newConnection(streamId, isServer)
    local c = { streamId = streamId, isServer = isServer, isConnected = true, isReadyForEvents = true, sent = 0, fail = false }
    function c:getIsServer() return self.isServer end
    function c:sendEvent(event)
        if self.fail then error("stream closed", 0) end
        self.sent = self.sent + 1
        local s = NewStream()
        event:writeStream(s, self)
        local class = getmetatable(event).__index
        local received = class.emptyNew()
        inProcess(self.peerMission, received.readStream, received, s, self.peer)
    end
    return c
end
local function newRemotePair(serverMission, clientMission)
    local toClient = newConnection(9, false)   -- the server's connection to the client
    local toServer = newConnection(9, true)    -- the client's connection to the server
    toClient.peer, toClient.peerMission = toServer, clientMission
    toServer.peer, toServer.peerMission = toClient, serverMission
    return toClient, toServer
end

-- ── NetworkSync, shaped on NetworkSyncScoped at origin/development 63b390c ──────
-- Ready scoped capabilities; a registration per module; on the server a remote
-- SUBSCRIBE (:775) and a publication cadence that calls the producer with a detached
-- context, previous and forceFull (:608-660), then hands a FULL to the client's
-- module; on the client the consumer's applyView.
local function newNetworkSync(isServer)
    local ns = { modules = {}, subscriptions = {}, serial = 0, dirtyMarks = 0, fullRequests = 0, pendingSubscribes = {} }
    function ns:_isServer() return isServer end
    function ns:getScopedCapabilities() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true, reasonCode = "READY" } end
    function ns:registerScopedModule(id, spec) self.modules[id] = spec return true end
    function ns:unregisterScopedModule(id) self.modules[id] = nil return true end
    function ns:markDirty(id) self.dirtyMarks = self.dirtyMarks + 1 end
    function ns:subscribe(connection, actor, clientNs)
        self.serial = self.serial + 1
        self.subscriptions[connection] = { connectionId = "c" .. self.serial, actor = actor, previous = nil, clientNs = clientNs }
        clientNs.server, clientNs.connection = self, connection
    end
    --- Client: requestScopedFull (:926-938) clears the module and starts a new
    --- generation; its SUBSCRIBE reaches the server with the next network tick, where
    --- _scopedOnSubscribe answers it with a forced FULL (:775-829).
    function ns:requestScopedFull(modId)
        self.fullRequests = self.fullRequests + 1
        if self.modules[modId] ~= nil then self.modules[modId].clearView("NEW_GENERATION") end
        if self.server ~= nil then self.server.pendingSubscribes[self.connection] = true end
        return true
    end
    --- Build one publication per subscription in the server process; deliver each
    --- in the client's process unless `hold` is set.
    function ns:publishAll(hold)
        local out = {}
        for connection in pairs(self.pendingSubscribes) do
            local sub = self.subscriptions[connection]
            if sub ~= nil then sub.previous = nil end   -- the new generation's forced FULL
        end
        self.pendingSubscribes = {}
        for connection, sub in pairs(self.subscriptions) do
            local spec = self.modules[SGTransport.MODULE_ID]
            local context = { connection = connection, connectionId = sub.connectionId, userId = sub.actor.userId, farmId = sub.actor.farmId,
                actorState = sub.actor.actorState, serverSession = "1", subscriptionId = "1", modId = SGTransport.MODULE_ID }
            local r = inProcess(self.mission, spec.buildView, context, sub.previous, sub.previous == nil)
            context.connection = nil
            if r.state == "READY" then sub.previous = { viewKey = r.viewKey, dataRevision = r.dataRevision } else sub.previous = nil end
            out[#out + 1] = r
            if not hold then sub.clientNs:deliver(r) end
        end
        return out
    end
    function ns:deliver(r)
        local spec = self.modules[SGTransport.MODULE_ID]
        if r.state ~= "READY" then inProcess(self.mission, spec.clearView, r.reason) return { outcome = "CLEARED" } end
        if r.mode == "UNCHANGED" then return { outcome = "UNCHANGED" } end
        return inProcess(self.mission, spec.applyView, { mode = r.mode, values = r.values, dataRevision = r.dataRevision })
    end
    return ns
end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) if connection == nil then return self._localFarm end return self._farms[connection] end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(opts)
    local m = setmetatable({ _server = opts.server ~= false, _localFarm = 1, _farms = {}, playerUserId = "host", missionInfo = {},
        missionDynamicInfo = { isMultiplayer = true }, _placeables = {}, _vehicles = {}, _users = {} }, Mission)
    m.userManager = { getUserByConnection = function(_, c) return m._users[c] end }
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    m.networkSync = opts.networkSync
    return m
end

--- A companion's carrier adapter, registered on the handle as a mod would: one
--- heap of barley at a known place, so a GROUND footprint has a row to find.
local function yardAdapter()
    local binding = { carrierKey = { adapterId = "yardheaps", nativeOwnerKey = "yard", componentKey = "1" }, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "yard/1" }
    return { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function() return { heap = true } end,
        readNativeState = function() return { materialRef = { kind = "FILL_TYPE", fillTypeName = "BARLEY" }, amount = 800, unit = "l", label = "Yard heap", x = 100, z = 200 } end,
        enumerateCarriers = function() return { { binding = binding } } end,
        hasAccess = function(_, actor) return actor ~= nil and actor.farmId == 1 end }
end

--- The server: a farm-1 silo of 5000 L wheat and the yard heap, booted through main.lua.
local function bootServer(ns)
    local m = newMission({ networkSync = ns })
    m._gServer = {}
    g_server, g_client, g_currentMission = m._gServer, nil, m
    local s = Storage.newModel({ [WHEAT] = 5000 }, 100000, 1)
    m._placeables[1] = { uniqueId = "placeable:silo", getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                         spec_silo = { storages = { s }, storagePerFarm = false } }
    m.storageSystem:addStorage(s)
    Mission00.load(m)
    m.stockGuard.registerCarrierAdapter("yardheaps", yardAdapter())
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m)
end

--- A pure client, booted through main.lua with its own NetworkSync.
local function bootClient(ns, client)
    local m = newMission({ server = false, networkSync = ns })
    m._gClient = client
    g_server, g_client, g_currentMission = nil, client, m
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m)
end

--- Server and client joined by a remote pair; the remote user farms farm 1.
local function world(opts)
    opts = opts or {}
    local sns, cns = nil, nil
    if not opts.fallback then sns, cns = newNetworkSync(true), opts.clientNs or newNetworkSync(false) end
    local sm, ssg = bootServer(sns)
    if sns ~= nil then sns.mission = sm end
    local client = {}
    local toClient, toServer = newRemotePair(sm, nil)
    client.getServerConnection = function() return toServer end
    local cm, csg = bootClient(cns, client)
    if cns ~= nil then cns.mission = cm end
    toClient.peerMission = cm
    sm._users[toClient] = MakeUser("u9", false)
    sm._farms[toClient] = 1
    local w = { sm = sm, ssg = ssg, sns = sns, cm = cm, csg = csg, cns = cns, toClient = toClient, toServer = toServer, client = client }
    --- The client's handle, each call run in the client's process.
    w.h = setmetatable({}, { __index = function(_, k) return function(...) return inProcess(cm, cm.stockGuard[k], ...) end end })
    return w
end
local function stop(w)
    g_currentMission = w.cm
    FSBaseMission.delete(w.cm)
    g_currentMission = w.sm
    FSBaseMission.delete(w.sm)
    g_server, g_client = nil, nil
end

-- ── readers ───────────────────────────────────────────────────────────────
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
--- "STATE/usable/kind/rows", rows as "fillType:amount" joined by ",".
local function shown(h)
    local v = h.getClientView()
    local rows = {}
    for _, r in ipairs(v.view and v.view.rows or {}) do rows[#rows + 1] = tostring(r.materialRef and r.materialRef.fillTypeName) .. ":" .. num(r.amount) end
    return tostring(v.state) .. "/" .. tostring(v.usable) .. "/" .. tostring(v.view and v.view.selectionKind) .. "/" .. table.concat(rows, ",")
end
local FARM = { route = "STOCK", selectionKind = "FARM" }
local YARD = { route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 100, z = 200, radius = 10 } }
local EMPTY = { route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 5000, z = 5000, radius = 10 } }
local BOTH = "READY/true/FARM/WHEAT:5000,BARLEY:800"

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: FARM, GROUND, FARM through the client's handle on NS7
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local w = world()
    local h = w.h
    T.eq("S1 both processes chose NS7 through their own selectRoute", tostring(w.ssg.transport.route) .. "/" .. tostring(w.csg.transport.route), "NS7/NS7")
    T.eq("S2 the silo and the yard heap were enumerated at the server's barrier", w.sm.stockGuard.getStatus().carriers .. "/" .. w.sm.stockGuard.getStatus().adapters, "2/2")
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    w.sns:publishAll()
    T.eq("S3 NS-7's first publication gives the client its FARM view", shown(h), BOTH)
    -- A reader's natural first call: open the page and request the FARM view it holds.
    h.requestView(FARM, {})
    T.eq("S3a asking again for the FARM view it holds: sent, cleared while it changes, a fresh FULL asked of NS-7",
        w.toServer.sent .. "/" .. w.cns.fullRequests .. "|" .. shown(h), "1/1|UNAVAILABLE/false/nil/")
    w.sns:publishAll()
    T.eq("S3b the forced FULL brings both rows back, with no stock change (the view itself is UNCHANGED)", shown(h), BOTH)
    local marks = w.sns.dirtyMarks
    local ok, why = h.requestView(YARD, {})
    T.eq("S4 the client's requestView on NS7 is sent, not refused as ROUTE", tostring(ok) .. "/" .. tostring(why) .. "/" .. w.toServer.sent, "true/nil/2")
    -- NS-7's own clear of the new generation calls the consumer with its reason (_scopedClientClear).
    T.eq("S5 while the selection changes the client shows nothing", shown(h) .. "|" .. tostring(h.getClientView().reason), "UNAVAILABLE/false/nil/|NEW_GENERATION")
    T.eq("S6 the server now holds GROUND for this connection and marked NS-7 dirty",
        w.ssg.transport:selectionFor(w.toClient).normalized.selectionKind .. "/" .. tostring(w.sns.dirtyMarks > marks), "GROUND/true")
    w.sns:publishAll()
    T.eq("S7 NS-7's next publication brings the yard heap, the one row inside the footprint", shown(h), "READY/true/GROUND/BARLEY:800")
    h.requestView(YARD, {})
    w.sns:publishAll()
    T.eq("S7a asking again for the same footprint keeps the heap's row", shown(h), "READY/true/GROUND/BARLEY:800")
    T.ok("S8 every request crossed the wire", h.requestView(FARM, {}) and w.toServer.sent == 4)
    w.sns:publishAll()
    T.eq("S9 and back at FARM both rows return", shown(h), BOTH)
    h.requestView(EMPTY, {})
    w.sns:publishAll()
    T.eq("S10 a footprint over empty ground is READY with no rows, not a stale page", shown(h), "READY/true/GROUND/")
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. A publication built for the old selection cannot restore the old page
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local w = world()
    local h = w.h
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    w.sns:publishAll()
    -- The FULL NS-7 would send for this connection's old selection (a recovery FULL).
    local lateFull = inProcess(w.sm, w.ssg.transport.buildView, w.ssg.transport, { connection = w.toClient, userId = "u9", farmId = 1, actorState = "RESOLVED" }, nil, true)
    T.eq("L0 the late FULL carries FARM's rows", tostring(lateFull.state) .. "/" .. tostring(lateFull.mode), "READY/FULL")
    h.requestView(YARD, {})
    local applied = w.cns:deliver(lateFull)
    T.eq("L1 a FULL built for FARM before the server took the request is refused", tostring(applied.outcome) .. "/" .. tostring(applied.reason), "RETRYABLE/SELECTION_MISMATCH")
    T.eq("L2 and the old page does not come back", shown(h), "UNAVAILABLE/false/nil/")
    w.sns:publishAll()
    T.eq("L3 the next publication, built for GROUND, applies", shown(h), "READY/true/GROUND/BARLEY:800")
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. A request that is not sent leaves the view as it was
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local w = world()
    local h = w.h
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    w.sns:publishAll()
    w.toServer.fail = true
    local ok, why = h.requestView(YARD, {})
    T.eq("F1 a send that fails answers SEND_FAILED and leaves the FARM view showing", tostring(ok) .. "/" .. tostring(why) .. "|" .. shown(h), "false/SEND_FAILED|" .. BOTH)
    T.eq("F1b and asks NS-7 for nothing", w.cns.fullRequests, 0)
    w.toServer.fail = false
    w.ssg.transport:markDirty()
    w.sns:publishAll()
    T.eq("F2 and the expected key is still FARM: the next FARM publication still applies", shown(h), BOTH)
    w.client.getServerConnection = function() return nil end
    T.eq("F3 no server connection: refused, view untouched", tostring(select(2, h.requestView(YARD, {}))) .. "|" .. shown(h), "NO_SERVER_CONNECTION|" .. BOTH)
    w.client.getServerConnection = function() return w.toServer end
    local okBad, whyBad = h.requestView({ route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 0, z = 0, radius = -1 } }, {})
    T.eq("F4 an invalid selection: refused with its reason, nothing sent, view untouched", tostring(okBad) .. "/" .. tostring(whyBad) .. "/" .. w.toServer.sent .. "|" .. shown(h), "false/GROUND_PARAMETERS/0|" .. BOTH)
    stop(w)
    -- A client whose NS-7 is still initializing has no route yet.
    local waiting = newNetworkSync(false)
    waiting.getScopedCapabilities = function() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = false, reasonCode = "WAITING_MISSION_LOAD" } end
    local w2 = world({ clientNs = waiting })
    local before = w2.h.getClientView()
    local okW, whyW = w2.h.requestView(YARD, {})
    local after = w2.h.getClientView()
    T.eq("F5 no route yet: refused as ROUTE, nothing sent, the view's state and reason unchanged",
        tostring(okW) .. "/" .. tostring(whyW) .. "/" .. w2.toServer.sent .. "/" .. tostring(before.reason == after.reason and before.state == after.state), "false/ROUTE/0/true")
    stop(w2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A FALLBACK client is unchanged
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local w = world({ fallback = true })
    local h = w.h
    T.eq("B1 without NetworkSync both sides take FALLBACK, and the client subscribed itself at load", tostring(w.ssg.transport.route) .. "/" .. tostring(w.csg.transport.route) .. "/" .. w.toServer.sent, "FALLBACK/FALLBACK/1")
    -- The load-time subscription left before the pair knew the client process; send it again.
    local ok, why = h.requestView(FARM, {})
    T.eq("B2 requestView answers true with no reason once the event is sent", tostring(ok) .. "/" .. tostring(why), "true/nil")
    T.eq("B3 the server's state event brings the FARM view", shown(h), BOTH)
    h.requestView(YARD, {})
    T.eq("B4 a GROUND request on the fallback is answered with the yard heap", shown(h), "READY/true/GROUND/BARLEY:800")
    stop(w)
end)
