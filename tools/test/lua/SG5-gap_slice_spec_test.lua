-- SG5-gap_slice_spec_test.lua
--
-- SG-5 host v2.15 gap slice (G3, G5, G6, G7, G2): the source half is SPEC-SG5-GAP-CODER.md
-- (E1-E12 in src/gui/SgRfPdaGuest.lua, G7 in src/presentation/SGEscClientAdapter.lua,
-- G6 in src/StockGuard.lua, the sentence in translations/translation_en.xml).
--
-- THE ENTRY-POINT BAR IS GROUP A. Two processes are booted through main.lua's own appends
-- (Mission00.load / loadMission00Finished / onFinishedLoading), exactly as SG5-252's world
-- does. The guest registers itself through its own SgRfPdaGuest.tryRegister (called by
-- main.lua's own registered retry hook at load, and by the bench through the same function
-- when a group needs a fresh registry), lands on the real RfEscModules registry, is selected
-- through the real RfEscModules:selectModule, and is driven through SgRfPdaGuest.onShow.
-- The farm change is published through a modelled MessageCenter's real dispatch with the
-- local player object. Nothing writes the guest's state, a paint, a selection or an
-- element's text by hand; SgRfPdaGuest._testState() is read-only evidence only.
--
-- Models, and the lines they follow:
--   MessageCenter  tools/test/lua/... none exists in this repo's models, so it is transcribed
--                  from D:\FS25_Decoded\dataS\scripts_decompiled\MessageCenter.lua:27-110:
--                  subscribe(type, callback, callbackTarget, argument, isOneShot),
--                  publish calls callback(callbackTarget, ...) when a target is set,
--                  unsubscribeAll(target) removes ONLY entries whose callbackTarget matches.
--                  The engine publishes PLAYER_FARM_CHANGED with the PLAYER object
--                  (player/events/PlayerSetFarmEvent.lua:40); StockGuard.lua:301 subscribes
--                  self.onPlayerFarmChanged with the SG host as target, so a wrong target
--                  for the guest shows up as a lost SG-1 subscription.
--   Site provider  a SITE_V1 facade shaped on WorkplaceSiteService.lua:837-880 (the same
--                  shape SG2-2-365 installs): dot-bound getSiteCapabilities,
--                  getSitesForFarm(ctx), getSite(siteId, ctx), registerSitePurpose,
--                  subscribeSiteChanges(consumerId, callback), unsubscribeSiteChanges.
--                  nil ctx is the own-farm replica. The server binds it through SGSiteBinding
--                  (StockGuard:trySites) and the client through SGEscClientAdapter.
--   GuiUtils       D:\FS25_Decoded\dataS\scripts_decompiled\gui\base\GuiUtils.lua. The
--                  decompiled getNormalizedValue (:71-106) shadows its own local and returns
--                  scalingValue for every px string, so it cannot be transcribed as written;
--                  the model follows the COHERENT sibling getNormalizedTextSize (:45-70),
--                  px / reference size, and says so here rather than inventing a third rule.
--                  Only applySgLayout / restoreSgLayout are read through it (C1/C2/C3).
--   companion carrier  a carrier adapter registered on the handle as a mod would, the shape
--                  MAINT-163-ns7_client_reselect's yardAdapter uses, so a SITE view has a
--                  positioned carrier to find; never hand-filled into a view.
--
-- Groups:
--   A  G3, the farm change while hidden (A1-A7, the entry-point bar)
--   B  G3's subscription target, the C1 constraint (B1-B3)
--   C  G5, the registry listener (C1-C7)
--   D  G6, openHostModule on the published handle (D1-D4)
--   E  G7, the paging version (E1-E3)
--   F  G2, the fallback note (F1-F5)
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGGroundBrush.lua, src/native/SGGroundArea.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGNativeHost.lua, src/sg3/SG3Profiles.lua, src/sg3/SG3Evaluator.lua, src/sg3/SG3Quality.lua, src/sg3/SG3Assessments.lua, src/sg3/SG3Condition.lua, src/sg3/SG3.lua, src/sg4/SG4Schema.lua, src/sg4/SG4Profiles.lua, src/sg4/SG4Library.lua, src/sg4/SG4Owner.lua, src/sg4/SG4.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, src/gui/RfEscModules.lua, src/gui/RfPdaMenuPage.lua, src/gui/RfEscBootstrap.lua, src/presentation/SGEscClientAdapter.lua, src/gui/SgGuideDialog.lua, src/gui/SgRfPdaGuest.lua, main.lua

local WHEAT, BARLEY = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY
NetworkNode = NetworkNode or { LOCAL_STREAM_ID = 0 }   -- network/NetworkNode.lua:3

-- The door's registry publishes itself through getfenv(0) (RfEscModules.lua:35, :59).
-- In 5.1 getfenv(0) is the global environment table; this harness has no getfenv at all,
-- so this is the harness shim SG5-252 also carries. Nothing in the mod changes for it.
if getfenv == nil then getfenv = function() return _G end end

local NOTE = "That place is no longer available. Showing the whole farm instead."
local EMPTY_BODY = "Nothing listed in this stock view yet. That does not mean the farm has no goods."
local UPDATING = "Updating stock list..."

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── GuiUtils, see the header for the lines followed ───────────────────────
local function splitSpaces(s)
    local out, i = {}, 1
    for part in tostring(s):gmatch("[^ ]+") do out[i] = part i = i + 1 end
    return out
end
GuiUtils = {}
local REF_W, REF_H = 1920, 1080
local function normOne(value, isX, default)
    if value == nil then return default end
    local s = tostring(value)
    local n = tonumber((s:gsub("px", ""):gsub("dp", "")))
    if n == nil then return default end
    if s:find("px", 1, true) then return n / (isX and REF_W or REF_H) end
    if s:find("dp", 1, true) then return n end
    return n
end
GuiUtils.getNormalizedScreenValues = function(values, default)
    if values == nil then return default end
    local parts = (type(values) == "string") and splitSpaces(values) or values
    local out = {}
    for i = 1, #parts do out[i] = normOne(parts[i], i % 2 == 1, default) end
    return out
end
GuiUtils.getNormalizedXValue = function(x, default) return normOne(x, true, default) end
GuiUtils.getNormalizedYValue = function(y, default) return normOne(y, false, default) end

-- ── the message center, transcribed as the header says ─────────────────────
local MC = { subscribers = {} }
function MC:subscribe(messageType, callback, callbackTarget, argument, isOneShot)
    if messageType == nil or callback == nil then return end
    self.subscribers[messageType] = self.subscribers[messageType] or {}
    table.insert(self.subscribers[messageType], {
        callback = callback, callbackTarget = callbackTarget, argument = argument, isOneShot = isOneShot == true,
    })
end
function MC:unsubscribeAll(callbackTarget)
    for k, list in pairs(self.subscribers) do
        for i = #list, 1, -1 do
            if list[i].callbackTarget == callbackTarget then table.remove(list, i) end
        end
        if #list == 0 then self.subscribers[k] = nil end
    end
end
function MC:publish(messageType, ...)
    local list = self.subscribers[messageType]
    if list == nil then return 0 end
    local n = 0
    for i = 1, #list do
        local info = list[i]
        if info.callbackTarget ~= nil then info.callback(info.callbackTarget, ...) else info.callback(...) end
        n = n + 1
    end
    return n
end
g_messageCenter = MC
MessageType = MessageType or {}
MessageType.PLAYER_FARM_CHANGED = "PLAYER_FARM_CHANGED"

-- the local player: the engine's own object, the one PLAYER_FARM_CHANGED carries
local player = { farmId = 1, userId = "me" }
function player:getFarmId() return self.farmId end
function player:getUserId() return self.userId end
g_localPlayer = player

-- the Esc door the guest's openFromHostModule path needs (RfPdaMenuPage.show, :3542-3549)
local DOOR_PAGE = {}
g_gui = { screenControllers = {}, currentGuiName = "InGameMenu", showGui = function() end }
g_inGameMenu = { menuRealisticFarming = DOOR_PAGE, currentPage = DOOR_PAGE, goToPage = function() end }
InGameMenu = InGameMenu or {}

local function inProcess(m, fn, ...)
    local saved = { g_currentMission, g_server, g_client }
    g_currentMission, g_server, g_client = m, m and m._gServer or nil, m and m._gClient or nil
    local r = { pcall(fn, ...) }
    g_currentMission, g_server, g_client = saved[1], saved[2], saved[3]
    if not r[1] then error(r[2], 0) end
    return r[2], r[3]
end

local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) if connection == nil then return self._localFarm end return self._farms[connection] end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(opts)
    local m = setmetatable({ _server = opts.server ~= false, _localFarm = 1, _farms = {}, playerUserId = "host",
        missionInfo = {}, missionDynamicInfo = { isMultiplayer = true }, _placeables = {}, _vehicles = {}, _users = {} }, Mission)
    m.userManager = { getUserByConnection = function(_, c) return m._users[c] end }
    m.accessHandler = { canFarmAccess = function(_, farmId, object)
        return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables,
        getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles,
        getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    m.networkSync = opts.networkSync
    return m
end

local function newConnection(streamId, isServer)
    local c = { streamId = streamId, isServer = isServer, isConnected = true, isReadyForEvents = true, sent = 0 }
    function c:getIsServer() return self.isServer end
    function c:sendEvent(event)
        self.sent = self.sent + 1
        local s = NewStream()
        event:writeStream(s, self)
        local class = getmetatable(event)
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

-- NetworkSync, the shape SG5-252 and MAINT-163 model.
local function newNetworkSync(isServer)
    local ns = { modules = {}, subscriptions = {}, serial = 0, pendingSubscribes = {} }
    function ns:_isServer() return isServer end
    function ns:getScopedCapabilities() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true, reasonCode = "READY" } end
    function ns:registerScopedModule(id, spec) self.modules[id] = spec return true end
    function ns:unregisterScopedModule(id) self.modules[id] = nil return true end
    function ns:markDirty(id) end
    function ns:subscribe(connection, actor, clientNs)
        self.serial = self.serial + 1
        self.subscriptions[connection] = { connectionId = "c" .. self.serial, actor = actor, previous = nil, clientNs = clientNs }
        clientNs.server, clientNs.connection = self, connection
    end
    function ns:requestScopedFull(modId)
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
            local context = { connection = connection, connectionId = sub.connectionId, userId = sub.actor.userId,
                farmId = sub.actor.farmId, actorState = sub.actor.actorState, serverSession = "1",
                subscriptionId = "1", modId = SGTransport.MODULE_ID }
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
        if r.state ~= "READY" then inProcess(self.mission, spec.clearView, r.reason) return end
        if r.mode == "UNCHANGED" then return end
        return inProcess(self.mission, spec.applyView, { mode = r.mode, values = r.values, dataRevision = r.dataRevision })
    end
    return ns
end

-- ── the world ─────────────────────────────────────────────────────────────
local SITE_YARD = { siteId = "site:yard", ownerFarmId = 1, name = "StockGuard yard", purpose = "stockguard.yard",
    centreX = 100, centreZ = 200, radiusMetres = 10, revision = "1", state = "ACTIVE" }
local SITE_NORTH = { siteId = "site:north", ownerFarmId = 1, name = "North yard", purpose = "stockguard.yard",
    centreX = 900, centreZ = 900, radiusMetres = 50, revision = "2", state = "ACTIVE" }

local function installSites(m, sites)
    local wt = { sites = {}, consumers = {}, purposes = {} }
    for i, s in ipairs(sites or {}) do wt.sites[i] = s end
    wt.getSiteCapabilities = function() return { schema = "SITE_V1", ready = true } end
    -- nil ctx is the local actor's own replica; a trusted actor context (the server) names the
    -- actor whose own farm is read (WorkplaceSiteService.lua:847-856). This provider holds farm
    -- 1's sites, so a context for any other farm sees none.
    wt.getSitesForFarm = function(ctx)
        if type(ctx) == "table" and ctx.farmId ~= nil and ctx.farmId ~= 1 then return {} end
        local out = {}
        for _, s in ipairs(wt.sites) do out[#out + 1] = s end
        return out
    end
    wt.getSite = function(siteId, ctx)
        if type(ctx) == "table" and ctx.farmId ~= nil and ctx.farmId ~= 1 then return nil, "DENIED" end
        for _, s in ipairs(wt.sites) do if s.siteId == siteId then return s end end
        return nil, "NOT_FOUND"
    end
    wt.registerSitePurpose = function(purpose) wt.purposes[purpose] = true return true end
    wt.openSiteManager = function() return true end
    wt.subscribeSiteChanges = function(consumerId, callback)
        if type(consumerId) ~= "string" or type(callback) ~= "function" then return false end
        wt.consumers[consumerId] = callback
        return true
    end
    wt.unsubscribeSiteChanges = function(consumerId)
        local had = wt.consumers[consumerId] ~= nil
        wt.consumers[consumerId] = nil
        return had
    end
    --- Fire a notice exactly as the service does: synchronous, four metadata args.
    wt.notify = function(siteId, revision, kind, ownerFarmId)
        local n = 0
        for _, cb in pairs(wt.consumers) do n = n + 1 pcall(cb, siteId, revision, kind, ownerFarmId) end
        return n
    end
    wt.count = function() local n = 0 for _ in pairs(wt.consumers) do n = n + 1 end return n end
    m.workplaceTriggers = wt
    return wt
end

local function addSilo(m, uniqueId, farmId, levels)
    local s = Storage.newModel(levels, 100000, farmId)
    m._placeables[#m._placeables + 1] = { uniqueId = uniqueId,
        getUniqueId = function(self) return self.uniqueId end,
        getOwnerFarmId = function() return farmId end,
        spec_silo = { storages = { s }, storagePerFarm = false } }
    m.storageSystem:addStorage(s)
    return s
end

local HEAPS = {
    { key = "1", amount = 800, x = 100, z = 200 },
    { key = "2", amount = 300, x = 105, z = 200 },
}

local function heapBinding(key)
    return { carrierKey = { adapterId = "yardheaps", nativeOwnerKey = "yard", componentKey = key },
        adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = "yard/" .. key }
end

--- The companion carrier adapter a mod registers on the handle (MAINT-163's shape): two
--- heaps of barley at known positions, so a SITE circle has carriers to find.
local function yardAdapter(heaps)
    return {
        version = 1, carrierKinds = { "silo" },
        resolveCarrier = function(binding) return { heap = tostring(binding.carrierKey.componentKey) } end,
        readNativeState = function(binding)
            local key = tostring(binding.carrierKey.componentKey)
            for _, h in ipairs(heaps) do
                if h.key == key then
                    return { materialRef = { kind = "FILL_TYPE", fillTypeName = "BARLEY" }, amount = h.amount,
                        unit = "l", label = "Yard heap " .. key, x = h.x, z = h.z }
                end
            end
            return nil, "NO_HEAP"
        end,
        enumerateCarriers = function()
            local out = {}
            for _, h in ipairs(heaps) do out[#out + 1] = { binding = heapBinding(h.key) } end
            return out
        end,
        hasAccess = function(_, actor) return actor ~= nil and actor.farmId == 1 end,
    }
end

local function bootServer(ns, opts)
    opts = opts or {}
    local m = newMission({ networkSync = ns })
    m._gServer = {}
    g_server, g_client, g_currentMission = m._gServer, nil, m
    if opts.emptyFarm1 then
        addSilo(m, "placeable:silo1", 1, {})
    else
        addSilo(m, "placeable:silo1", 1, opts.farm1 or { [WHEAT] = 5000 })
    end
    if opts.farm2 ~= nil then addSilo(m, "placeable:silo2", 2, opts.farm2) end
    if opts.serverSites ~= false then installSites(m, opts.sites or { SITE_YARD, SITE_NORTH }) end
    Mission00.load(m)
    if opts.heaps ~= nil then m.stockGuard.registerCarrierAdapter("yardheaps", yardAdapter(opts.heaps)) end
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    local sg = StockGuard.hostOf(m)
    if sg ~= nil and opts.serverSites ~= false then inProcess(m, function() sg:trySites() end) end
    return m, sg
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

--- Two processes joined by a remote pair. opts:
---   farm1 = fill levels for the farm-1 silo, emptyFarm1 = a farm-1 silo with nothing,
---   farm2 = fill levels for a farm-2 silo, heaps = the companion heaps,
---   serverSites = false to skip the server binding, sites = the client's site list.
local function world(opts)
    opts = opts or {}
    g_dedicatedServer = nil
    player.farmId = 1
    local sns, cns = newNetworkSync(true), newNetworkSync(false)
    local sm, ssg = bootServer(sns, opts)
    sns.mission = sm
    local client = {}
    local toClient, toServer = newRemotePair(sm, nil)
    client.getServerConnection = function() return toServer end
    local cm, csg = bootClient(cns, client)
    cns.mission = cm
    toClient.peerMission = cm
    sm._users[toClient] = MakeUser("u9", false)
    sm._farms[toClient] = opts.clientFarm or 1
    local w = { sm = sm, ssg = ssg, sns = sns, cm = cm, csg = csg, cns = cns,
        toClient = toClient, toServer = toServer, player = player }
    w.clientSites = installSites(cm, opts.sites or { SITE_YARD, SITE_NORTH })
    w.h = setmetatable({}, { __index = function(_, k)
        return function(...) return inProcess(cm, cm.stockGuard[k], ...) end
    end })
    return w
end

local function stop(w)
    if w.cm ~= nil then g_currentMission = w.cm FSBaseMission.delete(w.cm) end
    g_currentMission = w.sm
    FSBaseMission.delete(w.sm)
    g_server, g_client = nil, nil
    g_dedicatedServer = nil
end

-- ── the door's container, with the door's own geometry so the layout is observable ──
local function newContainer()
    local c = { reloads = 0 }
    local mk
    mk = function(id)
        local e = { id = id, position = { 0.5, 0.6 }, size = { 0.5, 0.1 }, textSize = 0.02 }
        function e:setText(t) self.text = t end
        function e:setVisible(v) self.visible = v end
        function e:setDisabled(v) self.disabled = v end
        function e:setPosition(x, y) self.position[1], self.position[2] = x, y end
        function e:setSize(w, h) self.size[1], self.size[2] = w, h end
        function e:setTextSize(s) self.textSize = s end
        function e:setTexts(t) self.texts = t end
        function e:setState(s) self.state = s end
        function e:setCanChangeState(v) self.canChangeState = v end
        function e:setDataSource(d) self.dataSource = d end
        function e:setDelegate(d) self.delegate = d end
        function e:updateAbsolutePosition() end
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

local function text(c, id) return tostring(c.el[id].text or "") end
local function hint(c) return text(c, "rfFwEmptyHint") end
local function hintShown(c) return c.el["rfFwEmptyHint"].visible == true end
local function more(c) return text(c, "rfFwMore") end
local function sheetRows(c)
    local ds = c.el["rfFwSheetList"].dataSource
    if ds == nil or type(ds.getNumberOfItemsInSection) ~= "function" then return 0 end
    return ds:getNumberOfItemsInSection(nil, 1)
end
local function rowText(c)
    local parts = {}
    for i = 1, 8 do
        for _, col in ipairs({ "A", "B", "C", "D" }) do
            parts[#parts + 1] = text(c, "rfFwRow" .. i .. col)
        end
    end
    return table.concat(parts, "\n")
end
local function allText(c)
    local parts = {}
    for _, e in pairs(c.el) do
        if type(e.text) == "string" and e.text ~= "" then parts[#parts + 1] = e.text end
    end
    return table.concat(parts, "\n")
end

--- Register and select the Stock panel through the guest's own tryRegister and the real
--- selectModule, on a fresh registry published on the mission, then hand back the container,
--- the show driver and the registry.
local function openPage(w, opts)
    opts = opts or {}
    local hub = RfEscModules.new()
    local c = newContainer()
    w.hub, w.container = hub, c
    inProcess(w.cm, function()
        SgRfPdaGuest.resetForTests()
        w.cm.rfEscModules = hub
        local registered = SgRfPdaGuest.tryRegister()
        if not hub:selectModule("stockGuard") then error("the door refused to select the Stock panel", 0) end
        return registered
    end)
    w.show = function(light) inProcess(w.cm, SgRfPdaGuest.onShow, c, light and true or false) end
    return c, w.show, hub
end

--- The farm-change publication, through the modelled MessageCenter's real dispatch.
local function publishFarmChange(subject)
    g_messageCenter:publish(MessageType.PLAYER_FARM_CHANGED, subject)
end

local function farmSubs()
    return g_messageCenter.subscribers[MessageType.PLAYER_FARM_CHANGED] or {}
end

local function memberSet(w)
    local set = {}
    local a, b = StockGuard.hostOf(w.sm), StockGuard.hostOf(w.cm)
    if a ~= nil then set[a] = true end
    if b ~= nil then set[b] = true end
    return set
end

--- Every PLAYER_FARM_CHANGED subscription whose target is not an SG host: the guest's.
local function guestSubs(w)
    local out, set = {}, memberSet(w)
    for _, s in ipairs(farmSubs()) do
        if not set[s.callbackTarget] then out[#out + 1] = s end
    end
    return out
end

local function subsWithTarget(target)
    local n = 0
    for _, s in ipairs(farmSubs()) do if s.callbackTarget == target then n = n + 1 end end
    return n
end

local function state(w) return inProcess(w.cm, SgRfPdaGuest._testState) end


--- Publish the client's current view and paint it.
local function settle(w, light)
    w.sns:publishAll()
    w.show(light ~= false)
end

--- Subscribe the client's connection to the server on the current farm, then paint the
--- farm floor and return with rows on screen.
local function enterFarm(w)
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    w.show(false)
    settle(w)
end

--- Move the player to another farm and let the server see it (the connection is re-resolved
--- and re-subscribed, which is what NS-7 does for a player whose farm changed).
local function movePlayerFarm(w, farmId)
    player.farmId = farmId
    w.sm._farms[w.toClient] = farmId
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. G3: the farm change while hidden (the entry-point bar)
-- ══════════════════════════════════════════════════════════════════════════
group("A1", function()
    local w = world({ heaps = HEAPS, farm2 = { [BARLEY] = 4000 } })
    local c, show, hub = openPage(w)
    local st = state(w)
    T.ok("A1 after registration the guest holds a farm-observer subscription and a registry listener",
        st.farmObserverBound == true and st.registryBound == true,
        "farmObserverBound=" .. tostring(st.farmObserverBound) .. " registryBound=" .. tostring(st.registryBound))
    inProcess(w.cm, SgRfPdaGuest.tryRegister)
    show(false)
    show(false)
    T.eq("A1b a second tryRegister and a second onShow leave exactly one subscription for the guest's target",
        #guestSubs(w), 1)
    T.eq("A1c and exactly one listener added by the guest on the registry", #hub.listeners, 1)
    T.eq("A1d the SG host's own subscription is still the only other one on this process",
        subsWithTarget(StockGuard.hostOf(w.cm)), 1)
    stop(w)
end)

group("A2", function()
    local w = world({ heaps = HEAPS, farm2 = { [BARLEY] = 4000 } })
    local c, show, hub = openPage(w)
    enterFarm(w)
    T.eq("A2a the farm floor is painted with the farm's rows on the planner",
        state(w).selectionKind .. "/" .. tostring(sheetRows(c)), "FARM/2")
    T.eq("A2b the planner names the view", more(c):find("Farm stock by product (2)", 1, true) ~= nil, true)

    -- a place is picked through the guest's own picker entry point
    inProcess(w.cm, SgRfPdaGuest.onActionActivate, 1)
    settle(w)
    T.eq("A2c a place was picked, through the picker, and its rows are painted",
        state(w).selectionKind .. "/" .. tostring(state(w).selectionSiteId) .. "/" .. tostring(sheetRows(c)),
        "SITE/site:yard/1")
    -- a product is drilled through the guest's own page entry point
    inProcess(w.cm, SgRfPdaGuest.onSelectionIndex, 2)
    show(true)
    T.eq("A2d a product was drilled: the drilled page names the place's product",
        more(c):find("Storages: BARLEY (2)", 1, true) ~= nil, true)
    inProcess(w.cm, SgRfPdaGuest.onSheetRow, 2)
    T.eq("A2e the focus is on the second row of the drilled page", state(w).focusSlot, 2)

    -- the adapter's own UI state, set through its published entry points; the command
    -- marker is written through the adapter's published state table because the adapter
    -- publishes no command setter, and the claim is only that clearUiState discards it.
    inProcess(w.cm, SGEscClientAdapter.restoreFocusState, w.cm, { mode = "FOCUSED", carrierId = "farm-1-carrier" })
    inProcess(w.cm, function()
        local cs = SGEscClientAdapter.getCommandState(w.cm)
        cs.lastTerminal = "FARM_1_COMMAND"
    end)
    T.ok("A2f the adapter holds a focus and a command state before the change",
        inProcess(w.cm, SGEscClientAdapter.getFocusState, w.cm) ~= nil
        and inProcess(w.cm, function() return SGEscClientAdapter.getCommandState(w.cm).lastTerminal end) == "FARM_1_COMMAND")

    -- leave the page for another module, then the farm changes
    inProcess(w.cm, function()
        w.cm.rfEscModules:registerModule({ id = "other", order = 90, title = "Other", onShow = function() end })
        w.cm.rfEscModules:selectModule("other")
    end)
    T.eq("A2g the page is hidden before the change", tostring(inProcess(w.cm, function() return w.cm.rfEscModules:getActivePanel().id end)), "other")
    player.farmId = 2
    inProcess(w.cm, publishFarmChange, player)

    local after = state(w)
    T.eq("A2h before any onShow the selection is back at the FARM floor", after.selectionKind, "FARM")
    T.eq("A2i the cached rows are empty before any new host reply", after.paintRowCount, 0)
    T.eq("A2j the cached sheet is empty before any new host reply", sheetRows(c), 0)
    T.eq("A2k the paging is reset (page, focus, hint skip)",
        after.pageIndex .. "/" .. after.focusSlot .. "/" .. after.hintSkip, "1/1/0")
    T.eq("A2l the transport trail is reset", after.cursorTrail .. "/" .. tostring(after.requestedCursor), "0/nil")
    T.eq("A2m the adapter's focus state is cleared for this mission handle",
        tostring(inProcess(w.cm, SGEscClientAdapter.getFocusState, w.cm)), "nil")
    T.eq("A2n the adapter's command state is cleared for this mission handle",
        tostring(inProcess(w.cm, function() return SGEscClientAdapter.getCommandState(w.cm).lastTerminal end)), "nil")
    T.eq("A2o the adapter's last selection is back at the farm floor",
        inProcess(w.cm, SGEscClientAdapter.lastSelection, w.cm).selectionKind, "FARM")
    T.eq("A2p the stale mark is set", after.identityStale, true)
    T.eq("A2q the site subscription is dropped too", w.clientSites.count(), 0)

    -- A3: the next onShow on the new farm (the player comes back to the page)
    movePlayerFarm(w, 2)
    inProcess(w.cm, function() w.cm.rfEscModules:selectModule("stockGuard") end)
    local sent = w.toServer.sent
    show(true)
    T.eq("A3a on the new farm the page asks the host again (a new request leaves the client)",
        w.toServer.sent - sent, 1)
    T.eq("A3b and the stale mark is cleared", state(w).identityStale, false)
    T.eq("A3c the wait line is painted, not the old rows", hint(c) .. "/" .. tostring(hintShown(c)), UPDATING .. "/true")
    T.ok("A3d none of the old farm's product names is on screen while the new reply is in flight",
        allText(c):find("WHEAT", 1, true) == nil)
    settle(w)
    T.eq("A3e the new farm's rows paint", sheetRows(c), 1)
    T.eq("A3f on the planner, not inside the old farm's drilled page",
        more(c):find("Farm stock by product (1)", 1, true) ~= nil and more(c):find("Storages:", 1, true) == nil, true)
    T.ok("A3g the old farm's wheat is never painted on the new farm",
        allText(c):find("WHEAT", 1, true) == nil)
    stop(w)
end)

--- A3's other half, and the only place identityStale is observable: the publication arrives
--- while the page is hidden but the player object has not caught up (a real race: the engine
--- publishes PLAYER_FARM_CHANGED with the player at PlayerSetFarmEvent.lua:40, and this guest
--- may read the player before its farmId changes). Without the stale mark the light refresh
--- issues no request and repaints the OLD farm's retained replica.
group("A3h", function()
    local w = world({ heaps = HEAPS })
    local c, show, hub = openPage(w)
    enterFarm(w)
    inProcess(w.cm, function()
        hub:registerModule({ id = "other", order = 90, title = "Other", onShow = function() end })
        hub:selectModule("other")
    end)
    inProcess(w.cm, publishFarmChange, player)
    T.eq("A3h the stale mark is set while the player still reports the old farm",
        tostring(state(w).identityStale) .. "/" .. tostring(player.farmId), "true/1")
    inProcess(w.cm, function() w.cm.rfEscModules:selectModule("stockGuard") end)
    local sent = w.toServer.sent
    show(true)
    T.eq("A3h2 a light refresh still asks the host, because the stale mark forces the request",
        w.toServer.sent - sent, 1)
    T.eq("A3h3 and the stale mark is cleared", tostring(state(w).identityStale), "false")
    T.eq("A3h4 the wait line is painted, not the retained old rows", hint(c) .. "/" .. tostring(hintShown(c)), UPDATING .. "/true")
    T.ok("A3h5 the old farm's wheat is not painted from the retained replica",
        allText(c):find("WHEAT", 1, true) == nil)
    stop(w)
end)

group("A4", function()
    local w = world({ heaps = HEAPS, farm2 = { [BARLEY] = 4000 } })
    local c, show = openPage(w)
    enterFarm(w)
    T.eq("A4a rows are on screen", sheetRows(c), 2)
    player.farmId = 2
    inProcess(w.cm, publishFarmChange, player)
    T.eq("A4b while the page is the ACTIVE panel the widgets are cleared at once: no row text survives",
        rowText(c):gsub("%s", ""), "")
    T.eq("A4c and the count line is gone at once", more(c), "")
    T.eq("A4d and the sheet is hidden at once", c.el["rfFwSheetBox"].visible, false)
    T.eq("A4e the selection is back at the FARM floor with no onShow in between",
        state(w).selectionKind, "FARM")
    movePlayerFarm(w, 2)
    show(false)
    settle(w)
    T.eq("A4f and the page repaints on the next onShow", sheetRows(c), 1)
    stop(w)
end)

group("A5", function()
    local w = world({ heaps = HEAPS })
    local c, show, hub = openPage(w)
    enterFarm(w)
    inProcess(w.cm, function()
        hub:registerModule({ id = "other", order = 90, title = "Other", onShow = function(container)
            container:getDescendantById("rfFwRow1A"):setText("DAIRY")
            container:getDescendantById("rfFwMore"):setText("DAIRY totals")
        end })
        hub:selectModule("other")
        hub.modules.other.onShow(c)
    end)
    T.eq("A5a the other module's marker is painted into the shared container",
        text(c, "rfFwRow1A") .. "/" .. more(c), "DAIRY/DAIRY totals")
    player.farmId = 2
    inProcess(w.cm, publishFarmChange, player)
    T.eq("A5b the hidden change drops the guest's own copy", state(w).paintRowCount .. "/" .. tostring(state(w).identityStale), "0/true")
    T.eq("A5c but the container is NOT cleared on the shared page: another module's marker survives",
        text(c, "rfFwRow1A") .. "/" .. more(c), "DAIRY/DAIRY totals")
    stop(w)
end)

group("A6", function()
    local w = world({ heaps = HEAPS })
    local c, show, hub = openPage(w)
    enterFarm(w)
    inProcess(w.cm, SgRfPdaGuest.onActionActivate, 1)   -- a SITE selection, so a drop is visible
    settle(w)
    T.eq("A6a a SITE selection is in place before the publication", state(w).selectionKind, "SITE")
    inProcess(w.cm, function()
        hub:registerModule({ id = "other", order = 90, title = "Other", onShow = function() end })
        hub:selectModule("other")
    end)

    inProcess(w.cm, publishFarmChange, { userId = "someone-else", farmId = 2 })
    T.eq("A6b a farm change for ANOTHER user is ignored: the SITE selection survives",
        state(w).selectionKind, "SITE")
    T.eq("A6c and nothing is marked stale", state(w).identityStale, false)
    T.eq("A6d and no copy is dropped", state(w).paintRowCount > 0, true)

    -- a subject with no user id, a nil subject, and the engine's own player are all local
    inProcess(w.cm, publishFarmChange, { farmId = 2 })
    T.eq("A6e a subject with no user id is treated as local, the safe side", state(w).identityStale, true)
    inProcess(w.cm, publishFarmChange, nil)
    T.eq("A6f a nil subject is treated as local", state(w).identityStale, true)
    inProcess(w.cm, publishFarmChange, player)
    T.eq("A6g the engine's own local player object is treated as local", state(w).identityStale, true)
    stop(w)
end)

group("A7", function()
    g_dedicatedServer = {}
    player.farmId = 1
    local ns = newNetworkSync(true)
    local sm, ssg = bootServer(ns, { heaps = HEAPS })
    ns.mission = sm
    local ctx = { sm = sm, cm = sm }
    local base = #guestSubs(ctx)
    T.eq("A7a a dedicated server never registers the Esc guest", tostring(SgRfPdaGuest.tryRegister()), "false")
    local ok = pcall(function() return inProcess(sm, SgRfPdaGuest.onShow, newContainer(), false) end)
    T.ok("A7b onShow on a dedicated server does nothing and raises nothing", ok)
    T.eq("A7c no farm-observer subscription exists after boot and those entry points", #guestSubs(ctx), base)
    T.eq("A7d and no registry listener exists (no registry is even published)", tostring(sm.rfEscModules), "nil")
    local st = state({ cm = sm })
    T.eq("A7e the observer and the listener both report unbound",
        tostring(st.farmObserverBound) .. "/" .. tostring(st.registryBound), "false/false")
    g_dedicatedServer = nil
    g_currentMission = sm
    FSBaseMission.delete(sm)
    g_server, g_client = nil, nil
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. G3's subscription target, the C1 constraint
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local w = world({ heaps = HEAPS, farm2 = { [BARLEY] = 4000 } })
    local c, show = openPage(w)
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    settle(w)
    T.eq("B0 the client holds a READY stock view to be cleared", inProcess(w.cm, w.cm.stockGuard.getClientView).state, "READY")

    local guests = guestSubs(w)
    T.eq("B2a the guest subscribed exactly one target of its own", #guests, 1)
    T.ok("B2b the guest's target is a table, distinct from the SG host and from the guest module",
        type(guests[1].callbackTarget) == "table"
        and guests[1].callbackTarget ~= StockGuard.hostOf(w.cm)
        and guests[1].callbackTarget ~= SgRfPdaGuest)

    inProcess(w.cm, g_messageCenter.unsubscribeAll, g_messageCenter, guests[1].callbackTarget)
    T.eq("B2c unsubscribeAll on the guest's target leaves the SG host's own subscription in the model",
        subsWithTarget(StockGuard.hostOf(w.cm)), 1)
    T.eq("B2d and removes only the guest's", #guestSubs(w), 0)

    -- rebind through the real show, then let resetForTests run its own unsubscribeAll
    inProcess(w.cm, SgRfPdaGuest.resetForTests)
    show(false)
    settle(w)
    T.eq("B1a after a teardown a show binds the observer again", #guestSubs(w), 1)
    inProcess(w.cm, SgRfPdaGuest.resetForTests)
    T.eq("B1b resetForTests' unsubscribeAll removed the guest's subscription and nothing else",
        #guestSubs(w) .. "/" .. tostring(subsWithTarget(StockGuard.hostOf(w.cm))), "0/1")
    inProcess(w.cm, publishFarmChange, player)
    T.eq("B1c SG-1's own handler still fires after that unsubscribeAll: the client view is cleared",
        inProcess(w.cm, w.cm.stockGuard.getClientView).state .. "/"
        .. tostring(inProcess(w.cm, w.cm.stockGuard.getClientView).reason), "UNAVAILABLE/FARM_CHANGED")

    -- B3: SG-5's site consumer id is its own, and the picker still hears site changes
    T.eq("B3a SG-5's site consumer id differs from the SG host's",
        SGEscClientAdapter.SITE_CONSUMER_ID .. "/" .. SGSiteBinding.CONSUMER_ID, "stockGuard.sg5/stockGuard")
    local w2 = world({ heaps = HEAPS })
    local c2, show2 = openPage(w2)
    enterFarm(w2)
    inProcess(w2.cm, SgRfPdaGuest.onActionActivate, 1)   -- a SITE selection
    settle(w2)
    T.eq("B3b the picker is bound under the SG-5 consumer id before the change",
        w2.clientSites.consumers["stockGuard.sg5"] ~= nil, true)
    player.farmId = 2
    inProcess(w2.cm, publishFarmChange, player)
    T.eq("B3c the farm change unbinds the site subscription", w2.clientSites.count(), 0)
    player.farmId = 1
    w2.show(false)
    T.eq("B3d the next show binds it again under the same id",
        w2.clientSites.consumers["stockGuard.sg5"] ~= nil, true)
    inProcess(w2.cm, function()
        w2.clientSites.notify("site:yard", 8, "CHANGED", 1)
    end)
    local cat, sel = inProcess(w2.cm, SGEscClientAdapter.siteStale, w2.cm)
    T.eq("B3e a SITE-change publication still reaches the picker after the drop and the rebind",
        tostring(cat) .. "/" .. tostring(sel), "true/false")
    stop(w2)
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. G5: the registry listener
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local w = world({ heaps = HEAPS })
    local c, show, hub = openPage(w)
    enterFarm(w)
    local ySG = c.el["rfFwMore"].position[2]
    T.ok("C0 the page owns the shared layout while it is the active panel (a value only applySgLayout writes)",
        ySG ~= 0.6, "rfFwMore y=" .. tostring(ySG))

    -- C1: another module takes the page
    inProcess(w.cm, function()
        hub:registerModule({ id = "other", order = 90, title = "Other", onShow = function() end })
        hub:selectModule("other")
    end)
    T.eq("C1a another module taking the page restores the shared layout", c.el["rfFwMore"].position[2], 0.6)
    T.eq("C1b and restores every element the layout states", c.el["rfFwSheetBand"].position[2], 0.6)
    inProcess(w.cm, function() hub:selectModule("stockGuard") end)
    show(false)
    settle(w)
    T.eq("C1c the next entry repaints the page", sheetRows(c), 2)
    local yAgain = c.el["rfFwMore"].position[2]
    T.ok("C1d and the entry took the layout back", yAgain == ySG)

    -- C2: selecting StockGuard itself
    local rowsBefore = sheetRows(c)
    inProcess(w.cm, function() hub:selectModule("stockGuard") end)
    T.eq("C2a selecting StockGuard itself leaves the layout alone", c.el["rfFwMore"].position[2], yAgain)
    T.eq("C2b and leaves the paint alone", sheetRows(c), rowsBefore)

    -- C3: a change that arrives during a door entry. The registry is told another module owns
    -- the page WITHOUT a notification (the pending-change shape), so a notification arriving in
    -- the entry finds isActivePanel false while the shared layout is still StockGuard's.
    hub.activeModuleId = "other"
    local yBeforeEntry = c.el["rfFwMore"].position[2]
    local midY, realSelectPanel = nil, hub.selectPanel
    hub.selectPanel = function(self, id)
        self:_notify()
        midY = c.el["rfFwMore"].position[2]
        return realSelectPanel(self, id)
    end
    local okOpen, whyOpen = inProcess(w.cm, function() return w.cm.stockGuard.openHostModule({}) end)
    hub.selectPanel = realSelectPanel
    T.eq("C3a the door entry succeeded", tostring(okOpen) .. "/" .. tostring(whyOpen), "true/nil")
    T.eq("C3b during the entry hold the listener restored nothing", midY, yBeforeEntry)

    -- C4: the leave does not clear another module's widgets
    inProcess(w.cm, function()
        hub:registerModule({ id = "other2", order = 91, title = "Other2", onShow = function(container)
            container:getDescendantById("rfFwRow2A"):setText("PASTURE")
        end })
        hub.modules.other2.onShow(c)
        hub:selectModule("other2")
    end)
    T.eq("C4 the leave does not clear another module's widgets", text(c, "rfFwRow2A"), "PASTURE")

    -- C5: the old listener still lives, because the registry has no removal API. It returns at
    -- its token line; C6 proves that from the outside, with a replacement registry whose token
    -- the old closure does not carry. Here the claim is only that firing it is inert and safe.
    local before = #hub.listeners
    inProcess(w.cm, SgRfPdaGuest.resetForTests)
    T.eq("C5a after resetForTests the registry still holds the old listener (no removal API)", #hub.listeners, before)
    local okFire = pcall(function() inProcess(w.cm, function() hub:_notify() end) end)
    T.ok("C5b firing it raises nothing and restores nothing", okFire and state(w).registryBound == false)

    -- C6: a replacement registry gets exactly one new listener; the old one is inert
    local hub2 = RfEscModules.new()
    local c2 = newContainer()
    inProcess(w.cm, function()
        w.cm.rfEscModules = hub2
        SgRfPdaGuest.tryRegister()
        hub2:registerModule({ id = "stockGuard", order = 55, title = "Stock",
            onShow = SgRfPdaGuest.onShow, onHide = SgRfPdaGuest.onHide })
        hub2:registerModule({ id = "other", order = 90, title = "Other", onShow = function() end })
        hub2:selectModule("stockGuard")
        SgRfPdaGuest.onShow(c2, false)
    end)
    w.sns:subscribe(w.toClient, w.ssg:resolveActorFor(w.toClient), w.cns)
    w.sns:publishAll()
    inProcess(w.cm, SgRfPdaGuest.onShow, c2, true)
    T.eq("C6a the replacement registry got exactly one listener from the guest", #hub2.listeners, 1)
    local y2 = c2.el["rfFwMore"].position[2]
    T.ok("C6b the replacement page painted with the layout applied", sheetRows(c2) == 2 and y2 ~= 0.6,
        "rows=" .. tostring(sheetRows(c2)) .. " y=" .. tostring(y2))
    -- the current registry is told another module took the page without notifying hub2, which is
    -- the stale-listener shape: only the OLD registry's listener is fired here.
    hub2.activeModuleId = "other"
    inProcess(w.cm, function() hub:selectModule("other") end)
    T.eq("C6c the old registry's listener is inert: it restored nothing", c2.el["rfFwMore"].position[2], y2)
    hub2.activeModuleId = "stockGuard"

    -- C7: the listener on a dedicated server
    g_dedicatedServer = {}
    local ns = newNetworkSync(true)
    local sm = bootServer(ns, { heaps = HEAPS })
    T.eq("C7a a dedicated server has no registry listener at all",
        tostring(sm.rfEscModules) .. "/" .. tostring(#(sm.rfEscModules and sm.rfEscModules.listeners or {})), "nil/0")
    T.eq("C7b and the guest holds no farm-observer target after that boot",
        tostring(state({ cm = sm }).farmObserverBound), "false")
    g_dedicatedServer = nil
    g_currentMission = sm
    FSBaseMission.delete(sm)
    g_server, g_client = nil, nil
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. G6: openHostModule on the published handle
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local w = world({ heaps = HEAPS })
    local c, show = openPage(w)
    enterFarm(w)

    T.eq("D1a on a non-dedicated process the published handle carries openHostModule as a function",
        type(w.cm.stockGuard.openHostModule), "function")
    local real = SgRfPdaGuest.openFromHostModule
    local seen = nil
    SgRfPdaGuest.openFromHostModule = function(opts)
        seen = opts
        return "SENTINEL_A", "SENTINEL_B"
    end
    local a, b = inProcess(w.cm, function() return w.cm.stockGuard.openHostModule({ focus = { siteId = "site:yard" } }) end)
    SgRfPdaGuest.openFromHostModule = real
    T.eq("D1b it delegates to SgRfPdaGuest.openFromHostModule and returns its results unchanged",
        tostring(a) .. "/" .. tostring(b), "SENTINEL_A/SENTINEL_B")
    T.ok("D1c and hands the options through", seen ~= nil and seen.focus ~= nil and seen.focus.siteId == "site:yard")

    local savedGuest = SgRfPdaGuest
    SgRfPdaGuest = nil
    local absentOk, absentWhy = inProcess(w.cm, function() return w.cm.stockGuard.openHostModule(nil) end)
    SgRfPdaGuest = savedGuest
    T.eq("D3 with SgRfPdaGuest nil the handle's function returns false, OPEN_HOST_ABSENT",
        tostring(absentOk) .. "/" .. tostring(absentWhy), "false/OPEN_HOST_ABSENT")

    local ok, why = inProcess(w.cm, function() return w.cm.stockGuard.openHostModule({ focus = { siteId = "site:yard" } }) end)
    T.eq("D4a a call with a SITE option opens the page on that place through the real openFromHostModule",
        tostring(ok) .. "/" .. tostring(why), "true/nil")
    local st = state(w)
    T.eq("D4b the guest's selection is that place", st.selectionKind .. "/" .. tostring(st.selectionSiteId), "SITE/site:yard")
    T.eq("D4c and the adapter's own last selection agrees",
        inProcess(w.cm, SGEscClientAdapter.lastSelection, w.cm).siteId, "site:yard")

    g_dedicatedServer = {}
    local ns = newNetworkSync(true)
    local sm = bootServer(ns, { heaps = HEAPS })
    T.eq("D2 on a dedicated server the handle has NO openHostModule",
        tostring(sm.stockGuard ~= nil) .. "/" .. tostring(sm.stockGuard and sm.stockGuard.openHostModule), "true/nil")
    g_dedicatedServer = nil
    g_currentMission = sm
    FSBaseMission.delete(sm)
    g_server, g_client = nil, nil
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. G7: the paging version
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local w = world({ heaps = HEAPS })
    local c, show = openPage(w)
    enterFarm(w)
    -- The replica was reached through the client process's own transport client for the STOCK
    -- route: StockGuard.hostOf(cm).transport.clients[SGViews.ROUTE_STOCK].replica, the exact
    -- table SGTransport:applyView assigned at SGTransport.lua:231 after decoding the server's
    -- real publication. NOT through the published handle: its getClientView returns a deep
    -- copy (StockGuard.lua:200-204), which is the point of the row.
    local replica = StockGuard.hostOf(w.cm).transport.clients[SGViews.ROUTE_STOCK].replica
    T.ok("E0 the server pipeline's own view carries pagingVersion = 1",
        type(replica) == "table" and replica.pagingVersion == 1,
        "pagingVersion=" .. tostring(type(replica) == "table" and replica.pagingVersion or nil))

    local p1 = inProcess(w.cm, SGEscClientAdapter.getPaintState, w.cm)
    T.eq("E1 a STOCK READY view carrying pagingVersion 1 paints READY",
        p1.state .. "/" .. tostring(p1.usable) .. "/" .. tostring(p1.rowCount), "READY/true/3")

    replica.pagingVersion = nil
    local p2 = inProcess(w.cm, SGEscClientAdapter.getPaintState, w.cm)
    T.eq("E2a without a paging version the same view is ERROR / MALFORMED_VIEW and unusable",
        p2.state .. "/" .. tostring(p2.reasonKey) .. "/" .. tostring(p2.usable), "ERROR/MALFORMED_VIEW/false")
    replica.pagingVersion = 2
    local p3 = inProcess(w.cm, SGEscClientAdapter.getPaintState, w.cm)
    T.eq("E2b a paging version other than 1 is ERROR / MALFORMED_VIEW and unusable",
        p3.state .. "/" .. tostring(p3.reasonKey) .. "/" .. tostring(p3.usable), "ERROR/MALFORMED_VIEW/false")
    replica.pagingVersion = 1
    local p4 = inProcess(w.cm, SGEscClientAdapter.getPaintState, w.cm)
    T.eq("E2c restoring 1 restores READY, so the check reads only that field",
        p4.state .. "/" .. tostring(p4.usable), "READY/true")

    -- E3: the branch lives in getPaintState's READY arm for the view it reads, which is the
    -- STOCK route's client (SGEscClientAdapter.lua:1128, :1156-1166). It never reads another
    -- route's view, so the check does not apply to a non-STOCK route. A READY RECIPE_LIBRARY
    -- replica with no paging version therefore cannot turn the stock paint into an error.
    local recipes = StockGuard.hostOf(w.cm).transport.clients[SGViews.ROUTE_RECIPES]
    recipes.state, recipes.usable = "READY", true
    recipes.replica = { availability = "READY", rows = {}, pagingVersion = nil }
    local p5 = inProcess(w.cm, SGEscClientAdapter.getPaintState, w.cm)
    T.eq("E3 a READY non-STOCK view without a paging version is not subject to the check, because getPaintState never reads it",
        p5.state .. "/" .. tostring(p5.rowCount), "READY/3")
    recipes.state, recipes.usable, recipes.replica = "UNAVAILABLE", false, nil
    stop(w)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. G2: the fallback note
-- ══════════════════════════════════════════════════════════════════════════
--- The production path: a SITE selection, its place deleted from the provider's own
--- catalogue, the provider's change notice, the next show's settleStaleSite, and the FARM
--- fallback request. Nothing writes _g5 here.
local function reachSite(w)
    enterFarm(w)
    inProcess(w.cm, SgRfPdaGuest.onActionActivate, 1)
    settle(w)
    return state(w).selectionKind == "SITE"
end

local function vanishSite(w)
    for i = #w.clientSites.sites, 1, -1 do
        if w.clientSites.sites[i].siteId == "site:yard" then table.remove(w.clientSites.sites, i) end
    end
    w.clientSites.notify(nil, nil, "DELETED", 1)
end

group("F1", function()
    local w = world({ heaps = HEAPS })
    local c, show = openPage(w)
    T.ok("F1a a SITE selection was reached through the picker", reachSite(w))
    T.ok("F1b the picked place's READY count line names its own product list",
        more(c):find("Farm stock by product (1)", 1, true) ~= nil, "count line was [" .. more(c) .. "]")
    vanishSite(w)
    w.show(false)
    T.eq("F1c a vanished place falls back to the whole farm", state(w).selectionKind, "FARM")
    T.eq("F1d and the fallback is noted", state(w).fallbackNote, true)
    settle(w)
    T.ok("F1e the painted READY count line carries the fallback sentence", more(c):find(NOTE, 1, true) ~= nil,
        "count line was [" .. more(c) .. "]")
    T.ok("F1f and it still names the view", more(c):find("Farm stock by product", 1, true) ~= nil)
    T.eq("F1g the sentence is exactly the English text and not a key", more(c):find(NOTE, 1, true) ~= nil
        and NOTE:find("sg_site_fallback", 1, true) == nil, true)
    stop(w)
end)

group("F2", function()
    local w = world({ emptyFarm1 = true })
    local c, show = openPage(w)
    enterFarm(w)
    T.eq("F2a the farm floor is READY with nothing in it", hint(c) .. "/" .. tostring(hintShown(c)), EMPTY_BODY .. "/true")
    T.ok("F2b a SITE selection was reached through the picker", reachSite(w))
    T.eq("F2c the place with no carriers is READY-empty",
        state(w).selectionKind .. "/" .. hint(c), "SITE/" .. EMPTY_BODY)
    vanishSite(w)
    w.show(false)
    T.eq("F2d the fallback is noted on the empty farm too", state(w).fallbackNote, true)
    settle(w)
    T.eq("F2e the note prefixes the READY-empty body, note, one space, body",
        hint(c), NOTE .. " " .. EMPTY_BODY)
    stop(w)
end)

group("F3", function()
    -- a deliberate selection clears it: another place, then back to the whole farm
    local w = world({ heaps = HEAPS })
    local c, show = openPage(w)
    reachSite(w)
    vanishSite(w)
    w.show(false)
    settle(w)
    T.eq("F3a the note is painted before the deliberate selection", more(c):find(NOTE, 1, true) ~= nil, true)
    inProcess(w.cm, SgRfPdaGuest.onActionActivate, 1)   -- step to the next place
    settle(w)
    T.eq("F3b a deliberate SITE choice ends the note in the state", state(w).fallbackNote, false)
    T.ok("F3c and the painted text no longer carries it", allText(c):find(NOTE, 1, true) == nil)
    inProcess(w.cm, SgRfPdaGuest.onActionActivate, 1)   -- and back to the whole farm
    settle(w)
    T.eq("F3d back at the farm floor the note is still gone", tostring(state(w).fallbackNote) .. "/" .. tostring(allText(c):find(NOTE, 1, true) == nil), "false/true")
    stop(w)

    -- a door entry clears it
    local w2 = world({ heaps = HEAPS })
    local c2 = openPage(w2)
    reachSite(w2)
    vanishSite(w2)
    w2.show(false)
    settle(w2)
    T.eq("F3e the note is painted before the door entry", more(c2):find(NOTE, 1, true) ~= nil, true)
    local okEntry = inProcess(w2.cm, function() return w2.cm.stockGuard.openHostModule({}) end)
    T.eq("F3f openFromHostModule succeeded", tostring(okEntry), "true")
    T.eq("F3g a door entry ends the note", state(w2).fallbackNote, false)
    T.ok("F3h and the entry's paint no longer carries it", allText(c2):find(NOTE, 1, true) == nil)
    stop(w2)

    -- a farm change clears it
    local w3 = world({ heaps = HEAPS, farm2 = { [BARLEY] = 4000 } })
    local c3 = openPage(w3)
    reachSite(w3)
    vanishSite(w3)
    w3.show(false)
    settle(w3)
    T.eq("F3i the note is painted before the farm change", more(c3):find(NOTE, 1, true) ~= nil, true)
    player.farmId = 2
    inProcess(w3.cm, publishFarmChange, player)
    T.eq("F3j a farm change ends the note", state(w3).fallbackNote, false)
    movePlayerFarm(w3, 2)
    w3.show(false)
    settle(w3)
    T.ok("F3k and the new farm's paint no longer carries it", allText(c3):find(NOTE, 1, true) == nil)
    stop(w3)
end)

group("F4", function()
    local w = world({ heaps = HEAPS })
    local c, show = openPage(w)
    reachSite(w)
    vanishSite(w)
    w.show(false)
    settle(w)
    T.eq("F4a the note shown only while the selection is FARM: the fallback left the selection at FARM",
        tostring(state(w).fallbackNote) .. "/" .. state(w).selectionKind, "true/FARM")
    inProcess(w.cm, SgRfPdaGuest.onActionActivate, 1)   -- select a place
    settle(w)
    T.ok("F4b a SITE selection paints no note", allText(c):find(NOTE, 1, true) == nil)
    T.eq("F4c and the state's note is off at that selection", state(w).fallbackNote, false)
    stop(w)
end)

group("F5", function()
    -- The guest's own default text is the English sentence. The XML half of F5 (the key occurs
    -- once in translation_en.xml and in no other language file) is checked by
    -- tools/test/mutate_sg5gap.py --l10n, because this harness's Lua exposes io but not
    -- io.open, so the bench cannot read the file. That is a harness limit, stated, not a skip.
    local w = world({ heaps = HEAPS })
    local c = openPage(w)
    reachSite(w)
    vanishSite(w)
    w.show(false)
    settle(w)
    local painted = more(c):match("(That place is no longer available%. Showing the whole farm instead%.)")
    T.eq("F5 the guest's tr() default text is the English sentence the xml carries", painted, NOTE)
    stop(w)
end)
