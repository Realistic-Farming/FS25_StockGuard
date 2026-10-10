-- SG5-252-esc_first_paint_spec_test.lua
--
-- BUILD-252: a joined client opened the Esc RF Stock page and it said
-- "Stock is not available right now. Try again in a moment." The farm had stock, the
-- route was NS7, and the rows arrived about three seconds later.
--
-- The page cannot say it is waiting. SGTransport:expectSelection clears the replica
-- with reason SELECTION_CHANGING *before* the request event leaves the client
-- (SGTransport.lua:338), so the paint that refreshSnapshot reads one step after
-- issuing its own request is UNAVAILABLE by construction. refreshSnapshot then treats
-- UNAVAILABLE as a definitive answer and clears _pendingRequest in the same pass that
-- requestCursor set it (SgRfPdaGuest.lua:1740-1743), so the WAITING branch's
-- "Updating stock list..." is unreachable and the paint falls through to the terminal
-- unavailable line (:1481-1484).
--
-- It is a joined-client-only shape. On a listen host requestView answers itself
-- synchronously - onViewRequest(nil) -> publishTo(nil) -> applyView, all inside the
-- same requestCursor call - so the host's first paint is already READY and never sees
-- the wait. That asymmetry is group H.
--
-- THE ENTRY-POINT BAR IS GROUP A. Two processes booted through main.lua's own
-- appends, a server whose NetworkSync reports ready and a pure client whose own
-- selectRoute chooses NS7, talking over a modelled remote connection pair (the
-- MAINT-163 world). The page is entered the way the door enters it: the guest is
-- registered through the real RfEscModules.registerModule, selected through the real
-- selectModule, and driven through SgRfPdaGuest.onShow with lightOnly FALSE, which is
-- what RfPdaMenuPage:refreshContent passes on a panel enter (RfPdaMenuPage.lua:3077,
-- :3231 - enteringSg makes lightOnly false). Nothing here writes a replica, a paint,
-- a selection or an element's text by hand; every string asserted was painted by the
-- guest into the container the host would have given it.
--
-- The container serves any element id the guest asks for, so a paint always lands on
-- a readable element. That is deliberately more permissive than the real page: it
-- means a row can never pass because an element was missing.
--
-- Groups:
--   A  the entry-point bar: a joined client's first entry, the line it paints while
--      the server's first reply is in flight, and the rows once it lands
--   B  the bound: a reply that never comes still ends up saying unavailable, and a
--      fresh request re-arms the wait
--   H  the listen host: its first entry is answered synchronously, so it shows rows
--      and never either message
--   X  the branches that must not move: DENIED, a host-sent UNAVAILABLE, and the
--      expected farm-with-no-stock state
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGGroundBrush.lua, src/native/SGGroundArea.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGNativeHost.lua, src/sg3/SG3Profiles.lua, src/sg3/SG3Evaluator.lua, src/sg3/SG3Quality.lua, src/sg3/SG3Assessments.lua, src/sg3/SG3Condition.lua, src/sg3/SG3.lua, src/sg4/SG4Schema.lua, src/sg4/SG4Profiles.lua, src/sg4/SG4Library.lua, src/sg4/SG4Owner.lua, src/sg4/SG4.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, src/gui/RfEscModules.lua, src/gui/RfPdaMenuPage.lua, src/gui/RfEscBootstrap.lua, src/presentation/SGEscClientAdapter.lua, src/gui/SgGuideDialog.lua, src/gui/SgRfPdaGuest.lua, main.lua

local WHEAT = ENGINE_FT.WHEAT
NetworkNode = NetworkNode or { LOCAL_STREAM_ID = 0 }   -- network/NetworkNode.lua:3

-- The door's registry publishes itself through getfenv(0) (RfEscModules.lua:35, :59),
-- which is a Lua 5.1 global the game has and this harness's interpreter does not. In 5.1
-- getfenv(0) is the global environment table, so that is what this returns. A harness gap,
-- not a product shim: nothing in the mod is changed for it, and the runner gives every test
-- file its own Lua state, so it is not visible to any other test.
if getfenv == nil then getfenv = function() return _G end end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The four lines this page can put in rfFwEmptyHint, quoted from the guest's own
-- authored fallbacks. No g_i18n is loaded, so tr() returns exactly these.
local UNAVAILABLE = "Stock is not available right now. Try again in a moment."
local UPDATING = "Updating stock list..."
local DENIED = "You cannot view this stock from here."
local READY_EMPTY = "Nothing listed in this stock view yet. That does not mean the farm has no goods."
local STATION = "Waiting for this station address..."

-- ── two processes in one Lua state (MAINT-163) ─────────────────────────────
local function inProcess(m, fn, ...)
    local saved = { g_currentMission, g_server, g_client }
    g_currentMission, g_server, g_client = m, m and m._gServer or nil, m and m._gClient or nil
    local r = { pcall(fn, ...) }
    g_currentMission, g_server, g_client = saved[1], saved[2], saved[3]
    if not r[1] then error(r[2], 0) end
    return r[2], r[3]
end

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
    local toClient = newConnection(9, false)
    local toServer = newConnection(9, true)
    toClient.peer, toClient.peerMission = toServer, clientMission
    toServer.peer, toServer.peerMission = toClient, serverMission
    return toClient, toServer
end

-- NetworkSync, shaped on NetworkSyncScoped (MAINT-163's model).
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
    function ns:requestScopedFull(modId)
        self.fullRequests = self.fullRequests + 1
        if self.modules[modId] ~= nil then self.modules[modId].clearView("NEW_GENERATION") end
        if self.server ~= nil then self.server.pendingSubscribes[self.connection] = true end
        return true
    end
    function ns:publishAll(hold)
        local out = {}
        for connection in pairs(self.pendingSubscribes) do
            local sub = self.subscriptions[connection]
            if sub ~= nil then sub.previous = nil end
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

-- ── the world ─────────────────────────────────────────────────────────────
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

--- The server: a farm-1 silo, booted through main.lua. `stock` false leaves the farm
--- with nothing in it, which is the expected-empty case group X needs.
local function bootServer(ns, stock)
    local m = newMission({ networkSync = ns })
    m._gServer = {}
    g_server, g_client, g_currentMission = m._gServer, nil, m
    local s = Storage.newModel(stock == false and {} or { [WHEAT] = 5000 }, 100000, 1)
    m._placeables[1] = { uniqueId = "placeable:silo", getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                         spec_silo = { storages = { s }, storagePerFarm = false } }
    m.storageSystem:addStorage(s)
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m)
end

local function bootClient(ns, client)
    local m = newMission({ server = false, networkSync = ns })
    m._gClient = client
    g_server, g_client, g_currentMission = nil, client, m
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m)
end

local function world(opts)
    opts = opts or {}
    local sns, cns = newNetworkSync(true), newNetworkSync(false)
    local sm, ssg = bootServer(sns, opts.stock)
    sns.mission = sm
    local client = {}
    local toClient, toServer = newRemotePair(sm, nil)
    client.getServerConnection = function() return toServer end
    local cm, csg = bootClient(cns, client)
    cns.mission = cm
    toClient.peerMission = cm
    sm._users[toClient] = MakeUser("u9", false)
    sm._farms[toClient] = opts.farmId == nil and 1 or opts.farmId
    local w = { sm = sm, ssg = ssg, sns = sns, cm = cm, csg = csg, cns = cns, toClient = toClient, toServer = toServer }
    w.h = setmetatable({}, { __index = function(_, k) return function(...) return inProcess(cm, cm.stockGuard[k], ...) end end })
    return w
end

--- A single process that is its own server with a local player: the listen host.
local function hostOnly()
    local ns = newNetworkSync(true)
    local sm, ssg = bootServer(ns, true)
    ns.mission = sm
    return { sm = sm, ssg = ssg, sns = ns }
end

local function stop(w)
    if w.cm ~= nil then g_currentMission = w.cm FSBaseMission.delete(w.cm) end
    g_currentMission = w.sm
    FSBaseMission.delete(w.sm)
    g_server, g_client = nil, nil
end

-- ── the door's container ──────────────────────────────────────────────────
local function newContainer()
    local c = { reloads = 0 }
    local mk
    mk = function(id)
        local e = { id = id, kids = nil }
        function e:setText(t) self.text = t end
        function e:setVisible(v) self.visible = v end
        function e:setDisabled(v) self.disabled = v end
        function e:setPosition(x, y) self.x, self.y = x, y end
        function e:setSize(wd, ht) self.w, self.h = wd, ht end
        function e:setTextSize(s) self.textSize = s end
        function e:setTexts(t) self.texts = t end
        function e:setState(s) self.state = s end
        function e:setCanChangeState(v) self.canChangeState = v end
        function e:setDataSource(d) self.dataSource = d end
        function e:setDelegate(d) self.delegate = d end
        function e:reloadData() c.reloads = c.reloads + 1 end
        function e:getDescendantByName(n)
            self.kids = self.kids or {}
            if self.kids[n] == nil then self.kids[n] = mk(id .. "/" .. tostring(n)) end
            return self.kids[n]
        end
        e.isLoaded = true
        return e
    end
    c.el = setmetatable({}, { __index = function(t, id) local e = mk(id) t[id] = e return e end })
    function c:getDescendantById(id) return self.el[id] end
    return c
end

local function hint(c) return tostring(c.el["rfFwEmptyHint"].text) end
local function hintShown(c) return c.el["rfFwEmptyHint"].visible == true end
--- "<the line>/<shown>" - what the player reads, and whether it is on screen.
local function reads(c) return hint(c) .. "/" .. tostring(hintShown(c)) end

--- Register and select the Stock panel on this mission exactly as the door does,
--- then hand back a driver for the host page's own onShow call.
local function openPage(m)
    local c = newContainer()
    inProcess(m, function()
        SgRfPdaGuest.resetForTests()
        local hub = RfEscModules.getOrCreate()
        m.rfEscModules = hub
        hub:registerModule({
            id = "stockGuard", order = 55, title = "Stock",
            onShow = SgRfPdaGuest.onShow, onHide = SgRfPdaGuest.onHide,
        })
        if not hub:selectModule("stockGuard") then error("the door refused to select the Stock panel", 0) end
    end)
    --- RfPdaMenuPage:refreshContent(false) on a panel enter: lightOnly = not (false or enteringSg).
    local function show(light)
        inProcess(m, SgRfPdaGuest.onShow, c, light and true or false)
    end
    return c, show
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ENTRY-POINT BAR: a joined client's first entry to the Stock page
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    local w = world()
    local c, show = openPage(w.cm)

    T.eq("A1 both processes chose NS7 through their own selectRoute",
        tostring(w.ssg.transport.route) .. "/" .. tostring(w.csg.transport.route), "NS7/NS7")
    T.eq("A2 the door selected the Stock panel, so the guest's active-panel gate is open",
        tostring(inProcess(w.cm, function() return w.cm.rfEscModules:getActivePanel().id end)), "stockGuard")
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    T.eq("A3 before entering the page the client holds no view at all",
        tostring(w.h.getClientView().state) .. "/" .. tostring(w.h.getClientView().reason), "UNAVAILABLE/NOT_SUBSCRIBED")

    local sentBefore = w.toServer.sent
    show(false)
    T.eq("A4 entering the page asked the server for the farm's stock, once",
        w.toServer.sent - sentBefore, 1)
    -- expectSelection clears with SELECTION_CHANGING, then NS7's requestScopedFull clears
    -- the module again with NEW_GENERATION (NetworkSyncScoped.lua:935), so NEW_GENERATION is
    -- the reason a joined client is actually left holding. A fix keyed only on
    -- SELECTION_CHANGING would never fire on the route the player is on.
    T.eq("A5 and the client's own request is what emptied its view: UNAVAILABLE, reason NEW_GENERATION",
        tostring(w.h.getClientView().state) .. "/" .. tostring(w.h.getClientView().reason),
        "UNAVAILABLE/NEW_GENERATION")
    T.ok("A6 no station focus is involved, so the station line is not what is on screen",
        hint(c) ~= STATION)

    -- THE ROW. The server's first reply is in flight. The page must say so.
    T.eq("A7 while the first reply is in flight the page says it is updating, not that stock is unavailable",
        reads(c), UPDATING .. "/true")

    w.sns:publishAll()
    T.eq("A8 the publication reached the client and its view is READY with the silo's wheat",
        tostring(w.h.getClientView().state) .. "/" .. tostring(#(w.h.getClientView().view or {}).rows),
        "READY/1")
    show(true)
    T.eq("A9 the next light tick paints the row and takes the message off screen",
        tostring(inProcess(w.cm, SgRfPdaGuest._testState).paintRowCount) .. "/" .. tostring(hintShown(c)),
        "1/false")
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE BOUND: a reply that never comes still ends up saying unavailable
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local w = world()
    local c, show = openPage(w.cm)
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)

    show(false)
    T.eq("B1 the first pass says updating", reads(c), UPDATING .. "/true")
    for _ = 1, 5 do show(true) end
    T.eq("B2 and it keeps saying so while the wait is still plausible (six passes)",
        reads(c), UPDATING .. "/true")
    show(true)
    T.eq("B3 past the bound a silent server reads as unavailable again, which is the honest answer",
        reads(c), UNAVAILABLE .. "/true")
    for _ = 1, 4 do show(true) end
    T.eq("B4 and it stays unavailable rather than flickering back", reads(c), UNAVAILABLE .. "/true")

    -- Re-entering the page is a fresh request, so the wait gets a fresh budget.
    show(false)
    T.eq("B5 a fresh request re-arms the wait", reads(c), UPDATING .. "/true")
    w.sns:publishAll()
    show(true)
    T.eq("B6 and when the reply finally lands the row paints",
        tostring(inProcess(w.cm, SgRfPdaGuest._testState).paintRowCount) .. "/" .. tostring(hintShown(c)),
        "1/false")

    -- NS-7 can start a new generation by itself on a resubscribe
    -- (NetworkSyncScoped.lua:231 resets the module with the same NEW_GENERATION reason),
    -- so the wait can begin again with no request of ours in between. It gets the whole
    -- budget then too, which is only true if an answered paint puts the count back.
    inProcess(w.cm, w.cns.modules[SGTransport.MODULE_ID].clearView, "NEW_GENERATION")
    for _ = 1, 6 do show(true) end
    T.eq("B7 a generation NS-7 starts on its own, after a paint that was answered, gets the whole budget",
        reads(c), UPDATING .. "/true")
    show(true)
    T.eq("B8 and is bounded the same way", reads(c), UNAVAILABLE .. "/true")
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE LISTEN HOST: answered synchronously, so it never sees the wait
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    local w = hostOnly()
    local c, show = openPage(w.sm)
    show(false)
    T.eq("H1 the host's own request is answered inside the same call: READY, no wait state",
        tostring(w.sm.stockGuard.getClientView().state), "READY")
    T.eq("H2 so its first paint shows the row and neither message",
        tostring(inProcess(w.sm, SgRfPdaGuest._testState).paintRowCount) .. "/" .. tostring(hintShown(c)),
        "1/false")
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. THE BRANCHES THAT MUST NOT MOVE
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    -- A spectator's view is DENIED by the server's own actor rules, and the refusal does
    -- reach this client - but only as a reason. Both routes drop the STATE of a non-READY
    -- publication: NS7 hands the consumer clearView(reason) alone
    -- (NetworkSyncScoped:_scopedOnControl keeps cs.state for itself), and the fallback does
    -- the same at StockGuard.lua:611. SGTransport:clearReplica then sets UNAVAILABLE
    -- whatever the reason was, so a pure client's view state is only ever READY or
    -- UNAVAILABLE and the guest's DENIED branch below cannot be reached from the wire.
    -- This row records that as it is. DISCLOSED in the 252 result, not repaired here: the
    -- repair belongs in the transport's state machine, not in the availability line.
    local w = world({ farmId = 0 })
    local c, show = openPage(w.cm)
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    show(false)
    w.sns:publishAll()
    show(true)
    T.eq("X1 a server refusal arrives as a bare clear, so the page shows the unavailable line and never the denied one (DISCLOSED)",
        reads(c) .. "|" .. tostring(w.h.getClientView().state) .. "/" .. tostring(w.h.getClientView().reason),
        UNAVAILABLE .. "/true|UNAVAILABLE/ACTOR_SPECTATOR")
    T.ok("X1b the refusal is not mistaken for a wait: the reason is not one of the two the client causes itself",
        hint(c) ~= UPDATING)
    stop(w)

    -- The DENIED line itself still works where a DENIED state can exist, so the branch is
    -- proved live rather than assumed dead.
    local wd = world()
    local cd, showd = openPage(wd.cm)
    showd(false)
    inProcess(wd.cm, function()
        local t = wd.csg.transport
        t.client.state, t.client.reason, t.client.usable, t.client.replica = "DENIED", "DENIED", false, nil
    end)
    showd(true)
    T.eq("X1c given a DENIED view the page does say the player cannot view this stock from here",
        reads(cd), DENIED .. "/true")
    stop(wd)

    -- A host-sent UNAVAILABLE is an answer, not a wait, and keeps the unavailable line.
    local w2 = world()
    local c2, show2 = openPage(w2.cm)
    w2.sns:subscribe(w2.toClient, w2.ssg:resolveActorFor(w2.toClient), w2.cns)
    show2(false)
    inProcess(w2.cm, w2.csg.transport.clearReplica, w2.csg.transport, "UNAVAILABLE")
    show2(true)
    T.eq("X2 an UNAVAILABLE the host actually sent keeps the unavailable line",
        reads(c2), UNAVAILABLE .. "/true")
    stop(w2)

    -- The expected state the packet asks to be told apart: a farm with no stock.
    local w3 = world({ stock = false })
    local c3, show3 = openPage(w3.cm)
    w3.sns:subscribe(w3.toClient, w3.ssg:resolveActorFor(w3.toClient), w3.cns)
    show3(false)
    w3.sns:publishAll()
    show3(true)
    T.eq("X3 a farm with nothing in it says so, and is never reported as unavailable",
        reads(c3), READY_EMPTY .. "/true")
    stop(w3)
end)
