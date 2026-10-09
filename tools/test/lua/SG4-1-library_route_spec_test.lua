-- SG4-1-library_route_spec_test.lua
--
-- SG-4 Part 1, the two SG-1 prerequisites of SG-4's library (Bob's SG-4 intake U1 and U2; his R-15 of
-- 2026-10-08, Desk Office/Drafts/BOB-R15-SG4-PART1-VIEW-HOOK-ROUTES-2026-10-08.md):
--   U1  the RECIPE_LIBRARY route answered OWNER_ABSENT unconditionally (SGViews) and the handle's
--       getRecipeLibraryView was a stub. Now its one registered owner (registerRecipeLibraryView) builds
--       the view and checks its rows on both sides; OWNER_ABSENT only when none is registered (SG-1 :289).
--   U2  the transport held one selection per connection, so opening the library dropped the stock page.
--       Now STOCK and RECIPE_LIBRARY keep separate selections, replicas, credentials, ordering and
--       decoders: NS-7's "stockGuard" and "stockGuard.recipes" modules, or the fallback state event's
--       route (SG-1 :342, :500-508; SG-4 :365, :369).
--
-- THE ENTRY-POINT BAR IS GROUP S. Two processes booted through main.lua's own appends (MAINT-163's
-- world): a server and a pure client with no NetworkSync, so both take the real fallback, joined by a
-- remote pair where every event is written with writeStream and read with readStream in the other
-- process. The library owner is a stand-in of the shape SG-4 Part 2 registers (production's own owner
-- arrives there); it is registered on the handle in both processes before the barrier. Nothing writes a
-- selection, a replica or a subscription.
--
-- Groups:
--   S  the entry-point bar: STOCK, then RECIPE_LIBRARY, on one connection, both held; a server tick
--      republishes both; a library the owner cannot restore leaves the stock usable
--   V  a library token or row failure clears only the library; an unknown route clears nothing; a new
--      session and a farm change clear both
--   N  NS-7: both modules; the library's own FULL request; a refused stockGuard.recipes keeps STOCK on
--      NS-7, logs once and sends no fallback event; a client that refused it sends nothing
--   H  the listen host projects each route it subscribed
--   R  one owner; the capability; the handle's server-only read; another farm denied; the route-gated
--      decoder; with no owner, OWNER_ABSENT as before
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local WHEAT = ENGINE_FT.WHEAT

local function printed(fn)
    local lines, orig = {}, print
    print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(fn)
    print = orig
    if not ok then error(err, 0) end
    return lines
end
local function count(lines, pattern) local n = 0 for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then n = n + 1 end end return n end
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
-- that process is g_currentMission (MAINT-163's pair).
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
-- Ready scoped capabilities and a registration per module id (refuse names ids it
-- refuses); on the server a remote SUBSCRIBE and, per module, a publication that calls
-- that module's producer with a detached context, previous and forceFull, handed to the
-- client's module of the same id (MAINT-163's model, one generation per module).
local function newNetworkSync(isServer, refuse)
    local ns = { modules = {}, subscriptions = {}, serial = 0, dirtyMarks = {}, fullRequests = {}, pendingSubscribes = {}, refuse = refuse or {} }
    function ns:getScopedCapabilities() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true, reasonCode = "READY" } end
    function ns:registerScopedModule(id, spec)
        if self.refuse[id] then return false, "MODULE_LIMIT" end
        self.modules[id] = spec
        return true
    end
    function ns:unregisterScopedModule(id) self.modules[id] = nil return true end
    function ns:markDirty(id) self.dirtyMarks[id] = (self.dirtyMarks[id] or 0) + 1 end
    function ns:subscribe(connection, actor, clientNs)
        self.serial = self.serial + 1
        self.subscriptions[connection] = { connectionId = "c" .. self.serial, actor = actor, previous = {}, clientNs = clientNs }
        clientNs.server, clientNs.connection = self, connection
    end
    function ns:requestScopedFull(modId)
        self.fullRequests[modId] = (self.fullRequests[modId] or 0) + 1
        if self.modules[modId] ~= nil then self.modules[modId].clearView("NEW_GENERATION") end
        if self.server ~= nil then self.server.pendingSubscribes[self.connection .. "|" .. modId] = true end
        return true
    end
    function ns:publishAll(modId)
        modId = modId or SGTransport.MODULE_ID
        local spec = self.modules[modId]
        if spec == nil then return {} end
        local out = {}
        for connection, sub in pairs(self.subscriptions) do
            if self.pendingSubscribes[tostring(connection) .. "|" .. modId] then sub.previous[modId] = nil end
            local context = { connection = connection, connectionId = sub.connectionId, userId = sub.actor.userId, farmId = sub.actor.farmId,
                actorState = sub.actor.actorState, serverSession = "1", subscriptionId = "1", modId = modId }
            local r = inProcess(self.mission, spec.buildView, context, sub.previous[modId], sub.previous[modId] == nil)
            context.connection = nil
            if r.state == "READY" then sub.previous[modId] = { viewKey = r.viewKey, dataRevision = r.dataRevision } else sub.previous[modId] = nil end
            out[#out + 1] = r
            sub.clientNs:deliver(r, modId)
        end
        self.pendingSubscribes = {}
        return out
    end
    function ns:deliver(r, modId)
        local spec = self.modules[modId]
        if spec == nil then return { outcome = "NO_MODULE" } end
        if r.state ~= "READY" then inProcess(self.mission, spec.clearView, r.reason) return { outcome = "CLEARED" } end
        if r.mode == "UNCHANGED" then return { outcome = "UNCHANGED" } end
        return inProcess(self.mission, spec.applyView, { mode = r.mode, values = r.values, dataRevision = r.dataRevision })
    end
    return ns
end

-- ── the RECIPE_LIBRARY owner: a stand-in of the shape SG-4 Part 2 registers ──────
-- One library per farm-1 actor, one LIBRARY row, its own data revision; its rows check
-- refuses anything but LIBRARY rows. Registered on the handle in both processes, as the
-- other owners are, before the restore barrier.
local LIB = { rev = 1, down = false, bad = false }
local function libraryOwner()
    return { version = 1, schemaVersion = 1,
        buildView = function(actor, selection)
            if actor.farmId ~= 1 then return { state = "DENIED", reason = "NO_LIBRARY" } end
            if LIB.down then return { state = "UNAVAILABLE", reason = "LIBRARY_RESTORE_FAILED" } end
            if LIB.bad then return { state = "READY", libraryId = "lib-1", dataRevision = "d0", rows = { { rowKind = "BOGUS" } } } end
            local id = selection.libraryId == "@current" and "lib-1" or selection.libraryId
            return { state = "READY", libraryId = id, dataRevision = "d" .. LIB.rev,
                     rows = { { rowKind = "LIBRARY", libraryId = id, libraryRevision = tostring(LIB.rev), retired = false } } }
        end,
        validateRows = function(rows)
            if type(rows) ~= "table" or #rows < 1 then return false, "COUNT" end
            for _, r in ipairs(rows) do
                if type(r) ~= "table" or r.rowKind ~= "LIBRARY" or type(r.libraryId) ~= "string" then return false, "ROW" end
            end
            return true
        end }
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

--- The server: a farm-1 silo of 5000 L wheat, booted through main.lua, the library owner
--- registered before the barrier unless opts.noOwner.
local function bootServer(ns, opts)
    local m = newMission({ networkSync = ns })
    m._gServer = {}
    g_server, g_client, g_currentMission = m._gServer, nil, m
    local s = Storage.newModel({ [WHEAT] = 5000 }, 100000, 1)
    m._placeables[1] = { uniqueId = "placeable:silo", getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                         spec_silo = { storages = { s }, storagePerFarm = false } }
    m.storageSystem:addStorage(s)
    Mission00.load(m)
    if not opts.noOwner then m.stockGuard.registerRecipeLibraryView("benchLibrary", libraryOwner()) end
    local lines = printed(function() Mission00.loadMission00Finished(m) m:onFinishedLoading() end)
    return m, StockGuard.hostOf(m), s, lines
end

--- A pure client, booted through main.lua with its own NetworkSync and the same owner.
local function bootClient(ns, client, opts)
    local m = newMission({ server = false, networkSync = ns })
    m._gClient = client
    g_server, g_client, g_currentMission = nil, client, m
    Mission00.load(m)
    if not opts.noOwner then m.stockGuard.registerRecipeLibraryView("benchLibrary", libraryOwner()) end
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m)
end

--- Server and client joined by a remote pair; the remote user farms farm 1.
local function world(opts)
    opts = opts or {}
    LIB.rev, LIB.down, LIB.bad = 1, false, false
    local sns, cns = nil, nil
    if not opts.fallback then sns, cns = newNetworkSync(true, opts.serverRefuse), newNetworkSync(false, opts.clientRefuse) end
    local sm, ssg, silo, serverLines = bootServer(sns, opts)
    if sns ~= nil then sns.mission = sm end
    local client = {}
    local toClient, toServer = newRemotePair(sm, nil)
    client.getServerConnection = function() return toServer end
    local cm, csg = bootClient(cns, client, opts)
    if cns ~= nil then cns.mission = cm end
    toClient.peerMission = cm
    sm._users[toClient] = MakeUser("u9", false)
    sm._farms[toClient] = 1
    local w = { sm = sm, ssg = ssg, sns = sns, cm = cm, csg = csg, cns = cns, toClient = toClient, toServer = toServer, client = client, silo = silo, serverLines = serverLines }
    --- Each handle's calls, run in their own process.
    w.h = setmetatable({}, { __index = function(_, k) return function(...) return inProcess(cm, cm.stockGuard[k], ...) end end })
    w.sh = setmetatable({}, { __index = function(_, k) return function(...) return inProcess(sm, sm.stockGuard[k], ...) end end })
    return w
end
local function stop(w)
    g_currentMission = w.cm
    FSBaseMission.delete(w.cm)
    g_currentMission = w.sm
    FSBaseMission.delete(w.sm)
    g_server, g_client = nil, nil
end
--- One server tick (the fallback republishes every subscribed route after a dirty mark).
local function serverTick(w) inProcess(w.sm, FSBaseMission.update, w.sm, 16) end

-- ── readers ───────────────────────────────────────────────────────────────
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
--- STOCK: "STATE/usable/kind/rows", rows as "fillType:amount".
local function stock(h)
    local v = h.getClientView()
    local rows = {}
    for _, r in ipairs(v.view and v.view.rows or {}) do rows[#rows + 1] = tostring(r.materialRef and r.materialRef.fillTypeName) .. ":" .. num(r.amount) end
    return tostring(v.state) .. "/" .. tostring(v.usable) .. "/" .. tostring(v.view and v.view.selectionKind) .. "/" .. table.concat(rows, ",")
end
--- RECIPE_LIBRARY: "STATE/usable/libraryId/libraryRevision/rows/reason" (the transport hashes the
--- view's dataRevision, so the owner's own row revision is read).
local function library(h)
    local v = h.getClientView("RECIPE_LIBRARY")
    local view = v.view or {}
    local row = view.rows and view.rows[1] or nil
    return tostring(v.state) .. "/" .. tostring(v.usable) .. "/" .. tostring(view.libraryId) .. "/" .. tostring(row and row.libraryRevision)
        .. "/" .. #(view.rows or {}) .. "/" .. tostring(v.reason)
end
local FARM = { route = "STOCK", selectionKind = "FARM" }
local LIBRARY = { route = "RECIPE_LIBRARY", selectionKind = "LIBRARY", libraryId = "@current" }
local STOCK_READY = "READY/true/FARM/WHEAT:5000"
local function libReady(rev) return "READY/true/lib-1/" .. rev .. "/1/" end
--- A state event sent from the server process to the client, through the pair.
local function sendState(w, publicationId, state, reason, tokens, route, session)
    inProcess(w.sm, w.toClient.sendEvent, w.toClient,
        SGViewStateEvent.new(session or w.ssg.serverSession, w.ssg.views.viewEpoch, publicationId, state, reason, tokens, route))
    -- The server's own later publications order after a crafted one.
    if SGValues.compareDecimal(publicationId, w.ssg.publicationId) > 0 then w.ssg.publicationId = publicationId end
end
--- The tokens of a READY library view the server's real builder makes, for crafted events.
local function libraryTokens(w, mutate)
    local page = inProcess(w.sm, w.ssg.views.getManagementView, w.ssg.views, { farmId = 1, userId = "u9", actorState = "RESOLVED", connectionId = "9" }, LIBRARY, {}, false)
    local view = SGValues.copy(page.view)
    if mutate ~= nil then mutate(view) end
    return SGViews.encodeView(view)
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: STOCK AND RECIPE_LIBRARY ON ONE FALLBACK CONNECTION
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local w = world({ fallback = true })
    local h = w.h
    T.eq("S1 [world] without NetworkSync both processes take FALLBACK, and the client subscribed itself to STOCK at load",
        tostring(w.ssg.transport.route) .. "/" .. tostring(w.csg.transport.route) .. "/" .. w.toServer.sent, "FALLBACK/FALLBACK/1")
    h.requestView(FARM, {})
    T.eq("S2 the client's STOCK request, through the real request and state events, brings the FARM view", stock(h), STOCK_READY)
    local ok, why = h.requestView(LIBRARY, {})
    T.eq("S3 [entry point] NAMED (SG-4 Part 1): a RECIPE_LIBRARY request on the same connection brings the library view, and the STOCK view stays READY beside it",
        tostring(ok) .. "/" .. tostring(why) .. " | " .. library(h) .. " | " .. stock(h), "true/nil | " .. libReady(1) .. " | " .. STOCK_READY)
    T.eq("S4 the server holds one selection per route for that connection: STOCK at FARM, RECIPE_LIBRARY at @current",
        inProcess(w.sm, w.ssg.transport.selectionFor, w.ssg.transport, w.toClient, "STOCK").normalized.selectionKind .. "/"
        .. inProcess(w.sm, w.ssg.transport.selectionFor, w.ssg.transport, w.toClient, "RECIPE_LIBRARY").normalized.libraryId, "FARM/@current")
    h.requestView({ route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 5000, z = 5000, radius = 10 } }, {})
    h.requestView(LIBRARY, {})
    T.eq("S4b a library request after a GROUND stock request leaves the stock selection, and the stock view, at GROUND",
        inProcess(w.sm, w.ssg.transport.selectionFor, w.ssg.transport, w.toClient, "STOCK").normalized.selectionKind .. " | " .. stock(h) .. " | " .. library(h),
        "GROUND | READY/true/GROUND/ | " .. libReady(1))
    h.requestView(FARM, {})
    -- The owner's library moves on; a dirty mark and one server tick republish every subscribed route. (A native
    -- storage change cannot drive this here: both processes share one Lua state, so SGNativeHost.current is the
    -- client's host. SG10-052's group S bars a native change republished.)
    LIB.rev = 2
    inProcess(w.sm, w.ssg.transport.markDirty, w.ssg.transport)
    local sentBefore = w.toClient.sent
    serverTick(w)
    T.eq("S5 the next server tick republishes both routes to the subscriber: the library's new revision arrives, and the stock view stays READY",
        (w.toClient.sent - sentBefore) .. " | " .. library(h) .. " | " .. stock(h), "2 | " .. libReady(2) .. " | " .. STOCK_READY)
    LIB.down = true
    inProcess(w.sm, w.ssg.transport.markDirty, w.ssg.transport)
    serverTick(w)
    T.eq("S6 a library the owner cannot restore is UNAVAILABLE with its reason, and the stock rows stay usable",
        library(h) .. " | " .. stock(h), "UNAVAILABLE/false/nil/nil/0/LIBRARY_RESTORE_FAILED | " .. STOCK_READY)
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. ONE ROUTE'S FAILURE IS THAT ROUTE'S; FARM AND SESSION CHANGES CLEAR BOTH
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local w = world({ fallback = true })
    local h = w.h
    h.requestView(FARM, {})
    h.requestView(LIBRARY, {})
    local big = {}
    for i = 1, SGTransport.MAX_TOKENS + 1 do big[i] = "x" end
    sendState(w, "900", "READY", "", big, "RECIPE_LIBRARY")
    T.eq("V1 an oversize library state event clears only the library (the route travels before the tokens)",
        library(h) .. " | " .. stock(h), "UNAVAILABLE/false/nil/nil/0/TRANSPORT_OVERSIZE | " .. STOCK_READY)
    h.requestView(LIBRARY, {})
    sendState(w, "910", "READY", "", libraryTokens(w, function(v) v.rows = { { rowKind = "BOGUS" } } end), "RECIPE_LIBRARY")
    T.eq("V2 a library row the owner's check refuses clears only the library", library(h) .. " | " .. stock(h), "UNAVAILABLE/false/nil/nil/0/MALFORMED_ROW | " .. STOCK_READY)
    h.requestView(LIBRARY, {})
    sendState(w, "915", "READY", "", libraryTokens(w, function(v) v.availability = "UNAVAILABLE" end), "RECIPE_LIBRARY")
    T.eq("V2b a non-READY library view that carries rows is refused before it is held", library(h), "UNAVAILABLE/false/nil/nil/0/PRIVATE_ROWS_ON_NON_READY")
    h.requestView(LIBRARY, {})
    local before = library(h) .. " | " .. stock(h)
    sendState(w, "920", "UNAVAILABLE", "BENCH", {}, "BOGUS")
    sendState(w, "921", "UNAVAILABLE", "BENCH", {}, "")
    T.eq("V3 a state event on an unknown or empty route is dropped and clears nothing", library(h) .. " | " .. stock(h), before)
    -- Each route keeps its own ordering baseline (SG-1 :342): the library cleared at 930, the stock applied at 950,
    -- then a library publication at 940, later than the library's last but earlier than the stock's.
    local stockNow = inProcess(w.sm, w.ssg.transport.buildView, w.ssg.transport, { connection = w.toClient, userId = "u9", farmId = 1, actorState = "RESOLVED" }, nil, true, "STOCK").values
    sendState(w, "930", "UNAVAILABLE", "BENCH", {}, "RECIPE_LIBRARY")
    sendState(w, "950", "READY", "", stockNow, "STOCK")
    sendState(w, "940", "READY", "", libraryTokens(w), "RECIPE_LIBRARY")
    T.eq("V3b each route keeps its own ordering: a library publication after the library's last applies though the stock's last is later",
        library(h) .. " | " .. stock(h), libReady(1) .. " | " .. STOCK_READY)
    sendState(w, "1", "READY", "", inProcess(w.sm, w.ssg.transport.buildView, w.ssg.transport, { connection = w.toClient, userId = "u9", farmId = 1, actorState = "RESOLVED" }, nil, true, "STOCK").values, "STOCK", "s-new")
    T.eq("V4 a new server session seen on the STOCK route resets both baselines: the stock view applies, the library is cleared",
        stock(h) .. " | " .. library(h), STOCK_READY .. " | UNAVAILABLE/false/nil/nil/0/SERVER_SESSION_CHANGED")
    h.requestView(LIBRARY, {})
    w.toServer.fail = true
    inProcess(w.cm, w.csg.onPlayerFarmChanged, w.csg, nil)
    T.eq("V5 the local player's farm change clears both routes (their re-requests not sent here)",
        stock(h) .. " | " .. library(h), "UNAVAILABLE/false/nil/ | UNAVAILABLE/false/nil/nil/0/FARM_CHANGED")
    w.toServer.fail = false
    inProcess(w.cm, w.csg.onPlayerFarmChanged, w.csg, nil)
    T.eq("V6 and once the re-requests are sent, both routes come back", stock(h) .. " | " .. library(h), STOCK_READY .. " | " .. libReady(1))
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. NS-7: TWO SCOPED MODULES, AND A REFUSED SECOND ONE
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local w = world()
    local h = w.h
    T.eq("N1 both processes chose NS7 and registered stockGuard and stockGuard.recipes",
        tostring(w.ssg.transport.route) .. "/" .. tostring(w.sns.modules.stockGuard ~= nil) .. "/" .. tostring(w.sns.modules["stockGuard.recipes"] ~= nil)
        .. "/" .. tostring(w.csg.transport.route) .. "/" .. tostring(w.cns.modules["stockGuard.recipes"] ~= nil), "NS7/true/true/NS7/true")
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    w.sns:publishAll("stockGuard")
    local sent = w.toServer.sent
    h.requestView(LIBRARY, {})
    T.eq("N2 the library request is sent and asks NS-7 for a fresh FULL of the library's own module",
        (w.toServer.sent - sent) .. "/" .. tostring(w.cns.fullRequests["stockGuard.recipes"]) .. "/" .. tostring(w.cns.fullRequests["stockGuard"]), "1/1/nil")
    w.sns:publishAll("stockGuard.recipes")
    T.eq("N3 the library's module publishes the library view; the STOCK module's view stays READY", library(h) .. " | " .. stock(h), libReady(1) .. " | " .. STOCK_READY)
    T.eq("N4 the STOCK module still builds STOCK for that connection", tostring(w.sns:publishAll("stockGuard")[1].state) .. " | " .. stock(h), "READY | " .. STOCK_READY)
    local marks = w.sns.dirtyMarks["stockGuard.recipes"] or 0
    inProcess(w.sm, w.ssg.transport.markDirty, w.ssg.transport)
    T.eq("N4b a dirty mark reaches the library's module too", tostring((w.sns.dirtyMarks["stockGuard.recipes"] or 0) > marks), "true")
    stop(w)
    T.eq("N8 mission end unregisters both modules on both sides", tostring(next(w.sns.modules)) .. "/" .. tostring(next(w.cns.modules)), "nil/nil")

    local w2 = world({ serverRefuse = { ["stockGuard.recipes"] = true } })
    T.eq("N5 a server whose NS-7 refuses stockGuard.recipes keeps STOCK on NS7, reports the library route UNAVAILABLE and logs it once",
        tostring(w2.ssg.transport.route) .. "/" .. tostring(w2.ssg.transport.recipesRegistered) .. " | " .. tostring((w2.sh.getCapabilities().recipeLibraryRoute or {}).state) .. "/"
        .. tostring((w2.sh.getCapabilities().recipeLibraryRoute or {}).reasonCode) .. " | " .. count(w2.serverLines, "recipe library route UNAVAILABLE"),
        "NS7/false | UNAVAILABLE/NS7_RECIPES_REGISTRATION_REFUSED:MODULE_LIMIT | 1")
    w2.sns:subscribe(w2.toClient, w2.ssg:resolveActorFor(w2.toClient), w2.cns)
    local toClientBefore = w2.toClient.sent
    w2.h.requestView(LIBRARY, {})
    serverTick(w2)
    T.eq("N6 the client's library request reaches that server, which sends no fallback state event for it", w2.toClient.sent - toClientBefore, 0)
    stop(w2)

    local w3 = world({ clientRefuse = { ["stockGuard.recipes"] = true } })
    local okC, whyC = w3.h.requestView(LIBRARY, {})
    T.eq("N7 a client whose NS-7 refused stockGuard.recipes refuses a library request and sends nothing",
        tostring(okC) .. "/" .. tostring(whyC) .. "/" .. w3.toServer.sent .. " | " .. library(w3.h), "false/RECIPES_ROUTE_UNAVAILABLE/0 | UNAVAILABLE/false/nil/nil/0/NS7_RECIPES_REGISTRATION_REFUSED:MODULE_LIMIT")
    stop(w3)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE LISTEN HOST PROJECTS EACH ROUTE IT SUBSCRIBED
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    local w = world({ fallback = true })
    local sh = w.sh
    sh.requestView(LIBRARY, {})
    T.eq("H1 the host's own library request is projected locally, and its STOCK view (subscribed at the barrier) stays READY",
        library(sh) .. " | " .. stock(sh), libReady(1) .. " | " .. STOCK_READY)
    LIB.rev = 3
    inProcess(w.sm, w.ssg.transport.markDirty, w.ssg.transport)
    serverTick(w)
    T.eq("H2 a dirty mark republishes both local routes on the next tick", library(sh) .. " | " .. stock(sh), libReady(3) .. " | " .. STOCK_READY)
    local subscribers, remoteOnly = 0, true
    for connection in pairs(w.ssg.fallbackSubscribers) do subscribers = subscribers + 1 if connection ~= w.toClient then remoteOnly = false end end
    T.eq("H3 the host is no fallback subscriber of its own server: the one subscriber is the remote client", subscribers .. "/" .. tostring(remoteOnly), "1/true")
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE OWNER HOOK, THE HANDLE, THE CAPABILITY AND THE ROUTE-GATED DECODER
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local w = world({ fallback = true })
    local again = { w.sh.registerRecipeLibraryView("another", libraryOwner()) }
    local bad = { w.sh.registerRecipeLibraryView("broken", { version = 1, schemaVersion = 1, buildView = function() end }) }
    T.eq("R1 the library has one owner: a second registration refuses, and a spec without validateRows refuses",
        tostring(again[1]) .. "/" .. tostring(again[2]) .. " " .. tostring(bad[1]) .. "/" .. tostring(bad[2]), "nil/LIBRARY_VIEW_PRESENT nil/CALLBACKS")
    local caps = w.sh.getCapabilities()
    T.eq("R2 getCapabilities names the owner and its schema, and the library route READY on the fallback",
        tostring((caps.recipeLibrary or {}).ownerId) .. "/" .. tostring((caps.recipeLibrary or {}).schemaVersion) .. "/" .. tostring(caps.recipeLibraryReasonCode) .. "/"
        .. tostring((caps.recipeLibraryRoute or {}).state), "benchLibrary/1/nil/READY")
    local page = w.sh.getRecipeLibraryView({ farmId = 1, userId = "u9", actorState = "RESOLVED" }, { libraryId = "@current" })
    local clientCall = { pcall(w.h.getRecipeLibraryView, { farmId = 1, userId = "u9", actorState = "RESOLVED" }, { libraryId = "@current" }) }
    T.eq("R3 the handle's getRecipeLibraryView reads the owner's view on the server and refuses on a client",
        tostring(page.state) .. "/" .. tostring(page.view and page.view.libraryId) .. "/" .. tostring(clientCall[2] == nil or clientCall[2].state ~= "READY"), "READY/lib-1/true")
    local denied = w.sh.getRecipeLibraryView({ farmId = 2, userId = "u2", actorState = "RESOLVED" }, { libraryId = "@current" })
    T.eq("R4 another farm's actor gets the owner's non-READY answer with no rows", tostring(denied.state) .. "/" .. tostring(denied.reason) .. "/" .. #(denied.view and denied.view.rows or {}), "DENIED/NO_LIBRARY/0")
    LIB.bad = true
    local badPage = w.sh.getRecipeLibraryView({ farmId = 1, userId = "u9", actorState = "RESOLVED" }, { libraryId = "@current" })
    LIB.bad = false
    T.eq("R7 rows the owner's own check refuses are an ERROR at build, with no rows", tostring(badPage.state) .. "/" .. tostring(badPage.reason) .. "/" .. #(badPage.view and badPage.view.rows or {}),
        "ERROR/LIBRARY_ROWS_MALFORMED/0")
    local libTokens = libraryTokens(w)
    local stockTokens = inProcess(w.sm, w.ssg.transport.buildView, w.ssg.transport, { connection = w.toClient, userId = "u9", farmId = 1, actorState = "RESOLVED" }, nil, true, "STOCK").values
    -- The client's own decoder, called directly (it reads only its registry), so all three returns are kept.
    local a = { w.csg.views:decodeRouteView(libTokens, "STOCK") }
    local b = { w.csg.views:decodeRouteView(stockTokens, "RECIPE_LIBRARY") }
    local c = { w.csg.views:decodeRouteView(libraryTokens(w, function(v) v.schemaVersion = 2 end), "RECIPE_LIBRARY") }
    T.eq("R5 the route is checked first: library bytes on STOCK and stock bytes on RECIPE_LIBRARY are TERMINAL, and a library view of another schema is TERMINAL before its rows",
        tostring(a[2]) .. "/" .. tostring(a[3]) .. " " .. tostring(b[2]) .. "/" .. tostring(b[3]) .. " " .. tostring(c[2]) .. "/" .. tostring(c[3]),
        "UNSUPPORTED_ROUTE/true UNSUPPORTED_ROUTE/true UNSUPPORTED_APPLICATION_VERSION/true")
    stop(w)

    local w2 = world({ fallback = true, noOwner = true })
    w2.h.requestView(FARM, {})
    w2.h.requestView(LIBRARY, {})
    local caps2 = w2.sh.getCapabilities()
    T.eq("R6 with no owner the library route is UNAVAILABLE RECIPE_LIBRARY_OWNER_ABSENT, as before, and STOCK is unaffected",
        library(w2.h) .. " | " .. tostring(caps2.recipeLibrary) .. "/" .. tostring(caps2.recipeLibraryReasonCode) .. " | " .. stock(w2.h),
        "UNAVAILABLE/false/nil/nil/0/RECIPE_LIBRARY_OWNER_ABSENT | nil/RECIPE_LIBRARY_OWNER_ABSENT | " .. STOCK_READY)
    stop(w2)
end)
