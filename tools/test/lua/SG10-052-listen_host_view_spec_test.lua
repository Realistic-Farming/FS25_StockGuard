-- SG10-052-listen_host_view_spec_test.lua
--
-- SG10-052: the stock view never reached a server with a local player (single
-- player, or a listen host), on either route. A single-player host IS a server
-- (MPLoadingScreen.lua:587-590, startLocal :411-417, BaseMission.lua:692-693).
--   NS7:      NetworkSync publishes only to remote subscribers; the local stream is
--             never a delivery target (NetworkSyncScoped.lua:337, :412, :481-492,
--             :775) and SGTransport:requestView refused anything but FALLBACK.
--   FALLBACK: the host's request went out over the engine loopback. A local
--             connection runs the event directly on its reverse connection
--             (network/Connection.lua:71-74, Client.lua:141-143, Server.lua:250), so
--             the server's answer came back as an SGViewStateEvent, which
--             hostOnClient() drops on a server.
-- The listen-host projection (sendViewState with no connection) had no production
-- caller on either route. The fix: a server with a local player reads its own
-- detached server view through the host, in the trusted local context, whatever the
-- route (SG-1/NS-7 brief :464, :498). A dedicated server projects nothing. Remote
-- clients are unchanged.
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine model loads first, then every module
-- main.lua sources, then main.lua. The mission loads through main's own appends with
-- a NetworkSync that reports ready, so NS7 is chosen by the real selectRoute; the silo
-- enters through the engine's StorageSystem:addStorage and the native kernel's adapter
-- enumerates it at the restore barrier. Nothing here writes a carrier, a stock, a
-- selection or a replica.
--
-- Groups:
--   S  the entry-point bar: NS7, the host's own view READY with the silo's stock row,
--      a change through Storage:setFillLevel republished on the next tick
--   F  FALLBACK listen host through the real requestView and the engine loopback
--   D  a dedicated server projects nothing
--   R  a remote client on NS7 is unchanged, and the host's view never feeds it
--   P  the local player's farm change clears the host's replica at once
--   X  teardown
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local WHEAT = ENGINE_FT.WHEAT
NetworkNode = NetworkNode or { LOCAL_STREAM_ID = 0 }   -- network/NetworkNode.lua:3

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the engine loopback (network/Connection.lua:21-44 and :71-74) ─────────
-- Server:startLocal makes the server's local client connection (isServer false);
-- Connection.new builds its reverse (isServer true), and Client:startLocal takes
-- that reverse as the client's server connection. sendEvent on either side runs
-- the event on the other, with no stream.
local function newConnection(streamId, isServer)
    local c = { streamId = streamId, isServer = isServer, isConnected = true, isReadyForEvents = true, sent = 0 }
    function c:getIsServer() return self.isServer end
    function c:sendEvent(event)
        self.sent = self.sent + 1
        if not self.isConnected then return end
        if self.streamId == NetworkNode.LOCAL_STREAM_ID then event:run(self.localConnection) end
    end
    return c
end
local function newLoopback()
    local toClient = newConnection(NetworkNode.LOCAL_STREAM_ID, false)   -- g_server.clientConnections[LOCAL]
    local toServer = newConnection(NetworkNode.LOCAL_STREAM_ID, true)    -- g_client.serverConnection
    toClient.localConnection, toServer.localConnection = toServer, toClient
    return toClient, toServer
end

-- ── NetworkSync, shaped on NetworkSyncScoped at origin/development 63b390c ──
-- Ready scoped capabilities; a module registration; SUBSCRIBE only from a remote
-- connection (:775), the local stream never a target (:412); publication calls the
-- producer with a detached context whose connectionId is NS-7's own serial (:637-646).
local function newNetworkSync(isServer)
    local ns = { modules = {}, subscriptions = {}, serial = 0, producerCalls = 0, localProducerCalls = 0, dirtyMarks = 0 }
    function ns:_isServer() return isServer end
    function ns:getScopedCapabilities() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true, reasonCode = "READY" } end
    function ns:registerScopedModule(id, spec) self.modules[id] = spec return true end
    function ns:unregisterScopedModule(id) self.modules[id] = nil return true end
    function ns:markDirty(id) self.dirtyMarks = self.dirtyMarks + 1 end
    function ns:subscribe(connection, actor)
        if connection.streamId == NetworkNode.LOCAL_STREAM_ID or connection.isReadyForEvents ~= true then return false end
        self.serial = self.serial + 1
        self.subscriptions[connection] = { connectionId = "c" .. self.serial, actor = actor }
        return true
    end
    function ns:publishAll()
        local out = {}
        for connection, sub in pairs(self.subscriptions) do
            local spec = self.modules[SGTransport.MODULE_ID]
            local context = { connection = connection, connectionId = sub.connectionId, userId = sub.actor.userId, farmId = sub.actor.farmId,
                actorState = sub.actor.actorState, serverSession = "1", subscriptionId = "1", modId = SGTransport.MODULE_ID }
            self.producerCalls = self.producerCalls + 1
            if connection.streamId == NetworkNode.LOCAL_STREAM_ID then self.localProducerCalls = self.localProducerCalls + 1 end
            out[connection] = spec.buildView(context, nil, true)
            context.connection = nil
        end
        return out
    end
    return ns
end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
--- FSBaseMission.lua:1067-1071: on a server the local farm is nil until the host's own
--- player exists, which onStartMission creates after the restore barrier (:365-377).
function Mission:getFarmId(connection)
    if connection == nil then
        if self._server and g_localPlayer == nil then return nil end
        return self._localFarm
    end
    return self._farms[connection]
end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(opts)
    local m = setmetatable({ _server = opts.server ~= false, _localFarm = 1, _farms = {}, playerUserId = "host", missionInfo = {},
        missionDynamicInfo = { isMultiplayer = opts.multiplayer == true }, _placeables = {}, _vehicles = {}, _users = {} }, Mission)
    m.userManager = { getUserByConnection = function(_, c) return m._users[c] end }
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    m.networkSync = opts.networkSync
    return m
end

--- A farm-1 silo holding `wheat` litres, registered with the storage system.
local function newSilo(m, wheat)
    local s = Storage.newModel({ [WHEAT] = wheat }, 100000, 1)
    local p = { uniqueId = "placeable:silo", getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                spec_silo = { storages = { s }, storagePerFarm = false } }
    m._placeables[#m._placeables + 1] = p
    m.storageSystem:addStorage(s)
    return s
end

--- Boot one mission through main.lua's own load path. Only a server gets g_server.
local function boot(opts)
    local m = newMission(opts)
    g_server = m._server and {} or nil
    g_client = opts.client
    g_currentMission = m
    local silo = m._server and newSilo(m, opts.wheat or 5000) or nil
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m), silo
end

--- onStartMission on the host (FSBaseMission.lua:365-377): Player.createServerInstance
--- with isOwner, which PlayerSystem:addPlayer makes g_localPlayer (PlayerSystem.lua:279).
--- Then one host tick.
local function start(m)
    g_localPlayer = { userId = m.playerUserId }
    FSBaseMission.update(m, 16)
end

local function stop(m)
    FSBaseMission.delete(m)
    g_server, g_client, g_dedicatedServer, g_localPlayer = nil, nil, nil, nil
end

-- ── readers ───────────────────────────────────────────────────────────────
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
--- The client view as "STATE/usable/rows", rows as "rowKind:amount" joined by ",".
local function shown(h)
    local v = h.getClientView()
    local rows = {}
    for _, r in ipairs(v.view and v.view.rows or {}) do rows[#rows + 1] = tostring(r.rowKind) .. ":" .. num(r.amount) end
    return tostring(v.state) .. "/" .. tostring(v.usable) .. "/" .. table.concat(rows, ",")
end
local FARM = { route = "STOCK", selectionKind = "FARM" }

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: a single-player host on NS7
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local ns = newNetworkSync(true)
    local printed, realPrint = {}, print
    print = function(s) if type(s) == "string" and s:find("host view READY", 1, true) then printed[#printed + 1] = s end realPrint(s) end
    local okBoot, m, sg, silo = pcall(boot, { networkSync = ns })
    if not okBoot then print = realPrint error(m, 0) end
    local h = m.stockGuard
    T.eq("S1 the real selectRoute chose NS7 and registered the module", tostring(sg.transport.route) .. "/" .. tostring(ns.modules[SGTransport.MODULE_ID] ~= nil), "NS7/true")
    T.eq("S2 the native kernel enumerated the silo at the barrier, nothing hand-filled", h.getStatus().adapters .. "/" .. h.getStatus().carriers .. "/" .. h.getStatus().stocks, "1/1/1")
    T.eq("S3 at the barrier the host's own player does not exist yet: its view waits on the actor", shown(h) .. "|" .. tostring(h.getClientView().reason), "UNAVAILABLE/false/|ACTOR_WAITING")
    local waiting = sg.publicationId
    FSBaseMission.update(m, 16)
    FSBaseMission.update(m, 16)
    T.eq("S3a ticks before the player exists publish nothing", sg.publicationId, waiting)
    start(m)
    T.eq("S3b the tick after the host's player appears shows the silo's stock row, with no stock change and no page asking", shown(h), "READY/true/STOCK:5000")
    local ok, why = h.requestView(FARM, {})
    T.eq("S4 the handle's requestView is taken on NS7, not refused as ROUTE", tostring(ok) .. "/" .. tostring(why), "true/nil")
    T.eq("S5 and getClientView reads the detached server view", shown(h), "READY/true/STOCK:5000")
    local afterRequest = sg.publicationId
    FSBaseMission.update(m, 16)
    T.eq("S5b the request published once; the tick after it publishes nothing more", sg.publicationId, afterRequest)
    local okBad, whyBad = h.requestView({ route = "STOCK", selectionKind = "FARM", siteId = "x" }, {})
    T.eq("S5c an invalid selection is refused with its reason and the view is left as it was", tostring(okBad) .. "/" .. tostring(whyBad ~= nil) .. "|" .. shown(h) .. "|" .. tostring(sg.publicationId == afterRequest), "false/true|READY/true/STOCK:5000|true")
    T.eq("S6 NS-7 was never asked to build for the local stream", ns.localProducerCalls, 0)
    silo:setFillLevel(3500, WHEAT)
    T.eq("S7 a storage change is not shown before any tick", shown(h), "READY/true/STOCK:5000")
    -- main.lua ticks StockGuard, then the native host, which flushes its storage
    -- observations every FLUSH_INTERVAL_MS; the flush marks the view dirty.
    FSBaseMission.update(m, SGNativeHost.FLUSH_INTERVAL_MS)
    T.eq("S8a the native flush recorded the new amount", h.getStatus().stocks .. "/" .. num((function() for _, s in pairs(sg.operations.stocks) do return s.observedAmount end end)()), "1/3500")
    FSBaseMission.update(m, 16)
    T.eq("S8 the host tick after the flush republishes the host's view with the new amount", shown(h), "READY/true/STOCK:3500")
    local before = sg.publicationId
    FSBaseMission.update(m, 16)
    T.eq("S9 a tick with nothing dirty publishes nothing", sg.publicationId, before)
    print = realPrint
    T.eq("S10 log.txt gets one line for the host's view, however often it is republished", table.concat(printed, "|"),
        "[StockGuard] host view READY for the local player on route NS7: 1 row(s)")
    stop(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. FALLBACK listen host, through the real requestView and the engine loopback
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local toClient, toServer = newLoopback()
    local client = { getServerConnection = function() return toServer end }
    local m, sg = boot({ client = client, multiplayer = true })
    m._users[toClient] = MakeUser("host", true)
    m._farms[toClient] = 1
    start(m)
    local h = m.stockGuard
    T.eq("F1 with no NetworkSync the route is FALLBACK", tostring(sg.transport.route), "FALLBACK")
    -- DIFFERENCE, the two barriers this repairs. The loopback runs the event with no
    -- stream, so readStream never sets the request's protocol and paging versions and
    -- SGViewRequestEvent:run refuses it; and a state event coming back over the
    -- loopback is refused because its receiving side is a server (hostOnClient).
    sg.transport:clearReplica("BENCH")
    toServer:sendEvent(SGViewRequestEvent.new(FARM, {}))
    T.eq("F2 DIFFERENCE: the request crossed the loopback and the server never answered", toServer.sent .. "/" .. toClient.sent .. "|" .. shown(h), "1/0|UNAVAILABLE/false/")
    local built = sg.transport:buildView({ connection = toClient, userId = "host", farmId = 1, actorState = "RESOLVED" }, nil, true)
    toClient:sendEvent(SGViewStateEvent.new(sg.serverSession, sg.views.viewEpoch, "999", "READY", "", built.values))
    T.eq("F3 DIFFERENCE: a READY state event sent back over the loopback never reaches the host's view", tostring(built.state) .. "|" .. toClient.sent .. "|" .. shown(h), "READY|1|UNAVAILABLE/false/")
    toServer.sent, toClient.sent = 0, 0
    local ok, why = h.requestView(FARM, {})
    T.eq("F4 the handle's requestView is taken", tostring(ok) .. "/" .. tostring(why), "true/nil")
    T.eq("F5 the host's view is READY with the silo's stock row", shown(h), "READY/true/STOCK:5000")
    T.eq("F6 nothing went over the loopback: no request event, no state event", toServer.sent .. "/" .. toClient.sent, "0/0")
    T.eq("F7 the host is not a fallback subscriber of its own server", next(sg.fallbackSubscribers), nil)
    stop(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A dedicated server projects nothing
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    g_dedicatedServer = {}
    local ns = newNetworkSync(true)
    local m, sg, silo = boot({ networkSync = ns, multiplayer = true })
    local h = m.stockGuard
    T.eq("D1 NS7 on the dedicated server as well", tostring(sg.transport.route), "NS7")
    T.eq("D2 no view after the barrier", shown(h), "UNAVAILABLE/false/")
    local ok, why = h.requestView(FARM, {})
    T.eq("D3 requestView is refused: there is no local farmer", tostring(ok) .. "/" .. tostring(why), "false/DEDICATED_SERVER")
    silo:setFillLevel(100, WHEAT)
    FSBaseMission.update(m, SGNativeHost.FLUSH_INTERVAL_MS)
    FSBaseMission.update(m, 16)
    T.eq("D4 nothing was projected, before or after a change, its flush and a tick", shown(h) .. "|" .. sg.publicationId, "UNAVAILABLE/false/|0")
    stop(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. A remote client on NS7 is unchanged, and the host's view never feeds it
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local ns = newNetworkSync(true)
    local m, sg = boot({ networkSync = ns, multiplayer = true })
    start(m)
    local remote = newConnection(9, false)
    m._users[remote] = MakeUser("u9", false)
    m._farms[remote] = 1
    local toClient = newLoopback()
    T.eq("R1 NS-7 refuses the local stream as a subscriber", tostring(ns:subscribe(toClient, sg:resolveActorFor(nil))), "false")
    T.ok("R2 and takes the remote connection", ns:subscribe(remote, sg:resolveActorFor(remote)))
    m.stockGuard.requestView(FARM, {})
    local pubs = ns:publishAll()
    T.eq("R3 NS-7 built exactly one publication, for the remote", ns.producerCalls .. "/" .. ns.localProducerCalls .. "/" .. tostring(pubs[remote] and pubs[remote].state), "1/0/READY")
    T.eq("R4 the host's own projection sent nothing to the remote", remote.sent, 0)
    -- The remote's own process: a pure client whose NS7 module applies the publication.
    local serverM = m
    g_localPlayer = nil
    local cns = newNetworkSync(false)
    local cm = newMission({ server = false, networkSync = cns, multiplayer = true })
    g_server, g_currentMission = nil, cm
    Mission00.load(cm)
    Mission00.loadMission00Finished(cm)
    local csg = StockGuard.hostOf(cm)
    T.eq("R5 the pure client takes NS7 through its own selectRoute", tostring(csg.transport.route), "NS7")
    local applied = cns.modules[SGTransport.MODULE_ID].applyView(pubs[remote])
    T.eq("R6 NS-7's publication applies on the client with the stock row", tostring(applied.outcome) .. "|" .. shown(cm.stockGuard), "APPLIED|READY/true/STOCK:5000")
    local ok, why = cm.stockGuard.requestView(FARM, {})
    T.eq("R7 a pure NS7 client's requestView sends by SGViewRequestEvent (MAINTENANCE row 163); with no server connection in this bench it is refused, and the view is untouched",
        tostring(ok) .. "/" .. tostring(why) .. "|" .. shown(cm.stockGuard), "false/NO_SERVER_CONNECTION|READY/true/STOCK:5000")
    FSBaseMission.delete(cm)
    g_currentMission = serverM
    stop(serverM)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. The local player's farm change clears the host's replica at once
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local ns = newNetworkSync(true)
    local m, sg = boot({ networkSync = ns })
    local h = m.stockGuard
    start(m)
    T.eq("P1 READY before the change", shown(h), "READY/true/STOCK:5000")
    m._localFarm = 2
    sg:onPlayerFarmChanged(g_localPlayer)
    T.eq("P2 the local player's farm change clears the host's view before any tick", shown(h), "UNAVAILABLE/false/")
    FSBaseMission.update(m, 16)
    T.eq("P3 the next tick republishes for the new farm, which holds no stock here", shown(h), "READY/true/")
    m._localFarm = 1
    sg:onPlayerFarmChanged({ userId = "someoneElse" })
    T.eq("P4 another player's farm change does not clear the host's view", shown(h), "READY/true/")
    FSBaseMission.update(m, 16)
    T.eq("P5 and the republish after its dirty mark re-reads the local actor", shown(h), "READY/true/STOCK:5000")
    stop(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. Teardown
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local ns = newNetworkSync(true)
    local m, sg = boot({ networkSync = ns })
    T.ok("X1 the host is subscribed to its own view", sg.transport.localSubscribed == true)
    local transport = sg.transport
    stop(m)
    T.eq("X2 teardown ends the local subscription and clears the view", tostring(transport.localSubscribed) .. "/" .. tostring(transport.client.usable), "false/false")
end)
