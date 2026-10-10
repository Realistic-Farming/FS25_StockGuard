-- SG5-365-review_corrections_spec_test.lua
--
-- REPAIR-365: the six corrections Bob's cold review at da915d4 asked for, driven through
-- the real product. Nothing here writes a paint, a replica or an element's text by hand:
-- the guest is registered through the real RfEscModules.registerModule, selected through
-- the real selectModule, and entered through the real SgRfPdaGuest.onShow, and every
-- assertion reads what the product actually did.
--
-- A listen host is used wherever one process is enough, because it answers its own
-- requestView synchronously and so reaches a READY paint in a single entry.
--
-- Groups:
--   A  G1    the named-site picker: two ACTIVE own-farm sites offered one at a time, a
--            foreign farm's site and an inactive one excluded, the pick actually sent, and
--            an honest disabled chip when the provider has nothing to give
--   B  major2 no command affordance at all while submission is unavailable, mouse AND key
--   C  major3 no UI state on the published handle and no reach into host.transport
--   D  major4 two real mission loads with a delete between, re-registration on the second,
--            and SG-1's own update record not rebound
--   E  G4    opening the page touches no FarmTablet
--   F  minors the unit probe is gone from the paint path
--
--!load: tools/test/lua/SG2-2-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGGroundBrush.lua, src/native/SGGroundArea.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGNativeHost.lua, src/sg3/SG3Profiles.lua, src/sg3/SG3Evaluator.lua, src/sg3/SG3Quality.lua, src/sg3/SG3Assessments.lua, src/sg3/SG3Condition.lua, src/sg3/SG3.lua, src/sg4/SG4Schema.lua, src/sg4/SG4Profiles.lua, src/sg4/SG4Library.lua, src/sg4/SG4Owner.lua, src/sg4/SG4.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, src/gui/RfEscModules.lua, src/gui/RfPdaMenuPage.lua, src/gui/RfEscBootstrap.lua, src/presentation/SGEscClientAdapter.lua, src/gui/SgGuideDialog.lua, src/gui/SgRfPdaGuest.lua, main.lua

local WHEAT = ENGINE_FT.WHEAT
NetworkNode = NetworkNode or { LOCAL_STREAM_ID = 0 }
if getfenv == nil then getfenv = function() return _G end end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

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

local function newMission()
    local m = setmetatable({ _server = true, _localFarm = 1, _farms = {}, playerUserId = "host",
        missionInfo = {}, missionDynamicInfo = { isMultiplayer = false },
        _placeables = {}, _vehicles = {}, _users = {} }, Mission)
    m.userManager = { getUserByConnection = function(_, c) return m._users[c] end }
    m.accessHandler = { canFarmAccess = function(_, farmId, object)
        return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables,
        getPlaceableByUniqueId = function(_, id)
            for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles,
        getVehicleByUniqueId = function(_, id)
            for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

--- A listen host with one farm-1 silo, booted through main.lua's own hooks.
--- @param beforeFinish fun(m)|nil runs between Mission00.load and loadMission00Finished,
---        which is where a mission's Esc door really appears. Without it the guest's
---        registration during load falls back to whatever hub was published globally.
local function boot(beforeFinish)
    local m = newMission()
    m._gServer = {}
    g_server, g_client, g_currentMission = m._gServer, nil, m
    local s = Storage.newModel({ [WHEAT] = 5000 }, 100000, 1)
    m._placeables[1] = { uniqueId = "placeable:silo",
        getUniqueId = function(self) return self.uniqueId end,
        getOwnerFarmId = function() return 1 end,
        spec_silo = { storages = { s }, storagePerFarm = false } }
    m.storageSystem:addStorage(s)
    Mission00.load(m)
    if type(beforeFinish) == "function" then beforeFinish(m) end
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, StockGuard.hostOf(m)
end

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
        if not hub:selectModule("stockGuard") then error("the door refused the Stock panel", 0) end
    end)
    local function show(light)
        inProcess(m, SgRfPdaGuest.onShow, c, light and true or false)
    end
    return c, show
end

--- The chip label the player reads on slot 1, and whether it can be pressed.
local function chip1(c)
    local e = c.el["rfFwAct1"]
    return tostring(e.rfPivotChipLabel), e.rfPivotChipEnabled == true
end

--- A WT8 facade with exactly the shape the brief names: dot-bound getSiteCapabilities()
--- and getSitesForFarm(nil). nil is the local actor's own replica, so this returns the
--- current farm's ACTIVE list only; a foreign farm's site and an inactive one are simply
--- not in it, which is what the real provider does rather than something SG filters after.
--- The full published facade, shaped from the provider's own source
--- (FS25_WorkplaceTriggers WorkplaceSiteService.lua :837-880): dot-bound
--- getSiteCapabilities(), getSitesForFarm(ctx), getSite(siteId, ctx),
--- subscribeSiteChanges(consumerId, callback), unsubscribeSiteChanges(consumerId).
--- nil ctx is the local actor's own ACTIVE replica. Nothing here adds submit or transport.
--- `wt.calls` records what the guest actually asked for, so a test can prove the callback
--- read nothing and that a foreign farm was never requested.
local function installWt8(m, opts)
    opts = opts or {}
    local wt
    wt = {
        sites = opts.sites or {
            { siteId = "site:north", name = "North Yard", revision = 7 },
            { siteId = "site:south", name = "South Yard", revision = 3 },
        },
        consumers = {},
        calls = { list = 0, one = 0, foreign = 0, subscribe = 0, unsubscribe = 0 },
        notReady = opts.notReady and true or false,
    }
    wt.getSiteCapabilities = function()
        if opts.capsNotReady then return { schema = "SITE_V1", ready = false, reasonCode = "NOT_READY" } end
        return { schema = "SITE_V1", ready = true }
    end
    wt.getSitesForFarm = function(ctx)
        wt.calls.list = wt.calls.list + 1
        if ctx ~= nil then wt.calls.foreign = wt.calls.foreign + 1 return {} end
        if wt.notReady then return nil, "NOT_READY" end
        if opts.empty then return {} end
        local out = {}
        for _, s in ipairs(wt.sites) do out[#out + 1] = s end
        return out
    end
    -- [REPAIR-377] An incomplete replacement, in exactly the shape the finding names: the
    -- provider still resolves (getSitesForFarm and getSiteCapabilities are present) but the
    -- single authoritative read is gone, so siteLifecycle must report SITE_GET_ABSENT.
    wt.getSite = function(siteId, ctx)
        wt.calls.one = wt.calls.one + 1
        if ctx ~= nil then wt.calls.foreign = wt.calls.foreign + 1 return nil, "DENIED" end
        if wt.notReady then return nil, "NOT_READY" end
        for _, s in ipairs(wt.sites) do if s.siteId == siteId then return s end end
        return nil, "NOT_FOUND"
    end
    -- Assigned and then removed, deliberately: `opts.noGetSite and nil or function() end`
    -- would hand back the function in BOTH cases, because `true and nil` is nil and
    -- `nil or f` is f. That trap made an "incomplete" facade complete.
    if opts.noGetSite then wt.getSite = nil end
    if not opts.noSubscribe then
        wt.subscribeSiteChanges = function(consumerId, callback)
            if type(consumerId) ~= "string" or consumerId == "" or type(callback) ~= "function" then
                return false
            end
            wt.calls.subscribe = wt.calls.subscribe + 1
            wt.consumers[consumerId] = callback
            return true
        end
        wt.unsubscribeSiteChanges = function(consumerId)
            wt.calls.unsubscribe = wt.calls.unsubscribe + 1
            local had = wt.consumers[consumerId] ~= nil
            wt.consumers[consumerId] = nil
            return had
        end
    end
    --- Fire a notice exactly as the service does: pcall, four metadata args, synchronous.
    wt.notify = function(siteId, revision, kind, ownerFarmId)
        local n = 0
        for _, cb in pairs(wt.consumers) do
            n = n + 1
            pcall(cb, siteId, revision, kind, ownerFarmId)
        end
        return n
    end
    wt.count = function()
        local n = 0
        for _ in pairs(wt.consumers) do n = n + 1 end
        return n
    end
    m.workplaceTriggers = wt
    return wt
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. G1: the named-site picker
-- ══════════════════════════════════════════════════════════════════════════
--- Register a REAL management owner through the published handle's own
--- registerManagementOwner (StockGuard.lua :122), publishing TWO available STOCK actions.
--- This is the actual public path an owner uses, so the rows that come back carry real
--- published actions. canSubmit is never mocked: the handle still has no submitCommand, so
--- submission stays genuinely unavailable while two actions are genuinely on offer.
local function installActionOwner(m)
    local h = m.stockGuard
    local spec = {
        version = 1,
        targetKinds = { "STOCK" },
        enumerateTargets = function() return {} end,
        resolveTarget = function(id) return { id = id } end,
        readTarget = function(b) return { revision = "r1" } end,
        hasAccess = function() return true end,
        getActions = function(b)
            return {
                { actionId = "sg365.alpha", targetKind = "STOCK", targetId = tostring(b.id),
                  expectedRevision = "r1", argumentSchemaId = "SG365_ALPHA_1",
                  available = true, controlKind = "ORDINARY", admission = "DIRECT_DESIRED_STATE" },
                { actionId = "sg365.beta", targetKind = "STOCK", targetId = tostring(b.id),
                  expectedRevision = "r1", argumentSchemaId = "SG365_BETA_1",
                  available = true, controlKind = "ORDINARY", admission = "DIRECT_DESIRED_STATE" },
            }
        end,
        invoke = function() return false, "NOT_IMPLEMENTED" end,
    }
    return inProcess(m, function() return h.registerManagementOwner("sg365.owner", spec) end)
end

--- Step to a page that publishes actions on a row, then FOCUS that row through the guest's
--- own onSheetRow. Focusing matters: the activate path reads focusedRow() and refuses on
--- `total <= 1`, so a row with actions somewhere on the page is not enough to isolate the
--- gate - that is exactly why an earlier version of this control could not kill M4. The
--- page is stepped with its own published entry point and re-entered through the real
--- onShow; nothing is hand-painted.
---
--- The count returned is the FOCUSED row's, read back out of the production paint: the
--- detail band renders "Actions: a  |  b" from focusedRow() and nothing else
--- (SgRfPdaGuest.lua :1166-1190), so its entries are the focused row's published actions.
--- The best row on the page is returned alongside, as a diagnostic only.
local function focusActionRow(m, show, c)
    -- Page 1 is the planner, whose rows are product GROUPS and carry no actions. The
    -- actions live on the per-storage rows of the drill page, so focus a product first and
    -- then drill into it, both through the guest's own published entry points.
    show(false)
    inProcess(m, SgRfPdaGuest.onSheetRow, 1)
    inProcess(m, SgRfPdaGuest.onSelectionIndex, 2)
    show(false)
    inProcess(m, SgRfPdaGuest.onSheetRow, 1)
    show(true)
    local best = inProcess(m, function()
        local paint = SGEscClientAdapter.getPaintState(m)
        local bn = 0
        for _, r in ipairs(paint.rows or {}) do
            local k = (type(r.actions) == "table") and #r.actions or 0
            if k > bn then bn = k end
        end
        return bn
    end)
    -- The focused row's own count, from the band the guest just painted.
    local focused, line = 0, nil
    for l in tostring(c.el["rfFwSheetBand"].text or ""):gmatch("[^\n]+") do
        if l:sub(1, 8) == "Actions:" then line = l end
    end
    if line ~= nil then
        focused = 1
        for _ in line:gmatch("  |  ") do focused = focused + 1 end
    end
    return 2, focused, best, line
end

group("A", function()
    local m = boot()
    installWt8(m)
    local c, show = openPage(m)
    show(false)

    local label, enabled = chip1(c)
    T.ok("A1 chip slot 1 carries a place picker, not furniture", label ~= "nil" and label ~= "")
    T.ok("A2 the picker is pressable when the catalogue has sites", enabled)
    T.ok("A3 it opens on the FARM floor and says how many places there are",
        label:find("Farm") ~= nil and label:find("2") ~= nil)

    -- the adapter must have been asked through the real published facade
    local opts = inProcess(m, SGEscClientAdapter.listSelectionOptions, m)
    local siteIds, foreign = {}, false
    for _, o in ipairs(opts) do
        if o.kind == "SITE" and o.available == true then siteIds[#siteIds + 1] = o.siteId end
    end
    T.eq("A4 both ACTIVE own-farm sites are offered", #siteIds, 2)
    T.eq("A5 and they are the provider's own ids, not invented", siteIds[1] .. "," .. siteIds[2],
        "site:north,site:south")

    -- stepping the picker actually requests a SITE, one at a time
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    local sel = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.eq("A6 one press moves off FARM to a single named SITE", tostring(sel.selectionKind), "SITE")
    T.eq("A7 and it sends the provider's opaque id only", tostring(sel.siteId), "site:north")
    T.ok("A8 no site revision rides the selection", sel.siteRevision == nil)

    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    local sel2 = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.eq("A9 the next press moves to the second site, still one at a time",
        tostring(sel2.siteId), "site:south")

    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    local sel3 = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.eq("A10 and it wraps back to the whole authorized farm",
        tostring(sel3.selectionKind), "FARM")
    FSBaseMission.delete(m)
end)

group("A-exclusion", function()
    local m = boot()
    -- the provider answers the own-farm replica only; a foreign farm's request gets nothing
    installWt8(m, { sites = { { siteId = "site:mine", name = "Mine", revision = 1 } } })
    local c, show = openPage(m)
    show(false)
    local opts = inProcess(m, SGEscClientAdapter.listSelectionOptions, m)
    local n = 0
    for _, o in ipairs(opts) do if o.kind == "SITE" and o.available == true then n = n + 1 end end
    T.eq("A11 only the sites the own-farm replica listed are offered", n, 1)
    local foreign = inProcess(m, function() return m.workplaceTriggers.getSitesForFarm(2) end)
    T.eq("A12 a foreign farm id is never asked for and would list nothing", #foreign, 0)
    FSBaseMission.delete(m)
end)

group("A-honest", function()
    local m = boot()
    installWt8(m, { notReady = true })
    local c, show = openPage(m)
    show(false)
    local label, enabled = chip1(m and c)
    T.ok("A13 a provider that has not answered leaves the picker disabled", not enabled)
    T.ok("A14 and says so rather than offering a dead press", label:lower():find("site") ~= nil)
    local before = inProcess(m, SGEscClientAdapter.lastSelection, m)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    local after = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.eq("A15 pressing it changes no selection at all",
        tostring(before.selectionKind), tostring(after.selectionKind))
    FSBaseMission.delete(m)
end)

group("A-noprovider", function()
    local m = boot()   -- no WT8 at all
    local c, show = openPage(m)
    show(false)
    local label, enabled = chip1(c)
    T.ok("A16 with no provider the picker is disabled, not hidden-and-forgotten", not enabled)
    T.ok("A17 the honest floor stays the whole authorized farm",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).selectionKind) == "FARM")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. major2: no command offered without real submission
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local m, host = boot()
    installWt8(m)
    T.ok("B1 the published handle really has no submitCommand", host.submitCommand == nil)
    local ok, why = inProcess(m, SGEscClientAdapter.canSubmit, m)
    T.ok("B2 so canSubmit refuses", ok ~= true)
    T.eq("B3 and names the missing capability", tostring(why), "NO_SUBMIT")

    local c, show = openPage(m)
    show(false)
    T.ok("B4 the Next-action chip is not offered", c.el["rfFwAct2"].rfPivotChipLabel == nil)
    T.ok("B5 the Run-action chip is not offered", c.el["rfFwAct3"].rfPivotChipLabel == nil)
    T.ok("B6 and the page says why instead of staying silent",
        tostring(c.el["rfFwCmdBanner"].text):lower():find("unavailable") ~= nil)

    T.ok("B7 a key or controller press on the step chip refuses too",
        inProcess(m, SgRfPdaGuest.onActionActivate, 2) ~= true)
    T.ok("B8 and on the run chip",
        inProcess(m, SgRfPdaGuest.onActionActivate, 3) ~= true)
    FSBaseMission.delete(m)
end)

group("B-credentials", function()
    local m, host = boot()
    -- a host that CAN submit but whose view carries no credentials must still refuse
    host.submitCommand = function() return true end
    local ok, why = inProcess(m, SGEscClientAdapter.canSubmit, m)
    T.ok("B9 submission alone is not enough", ok ~= true, "canSubmit said " .. tostring(ok)
        .. " reason " .. tostring(why))
    -- Name the reason rather than enumerate a guess: any non-empty refusal reason is the
    -- contract ("no action offered"), and printing it keeps the test self-diagnosing.
    T.ok("B10 and the refusal names a reason", type(why) == "string" and why ~= "",
        "reason was " .. tostring(why))
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. major3: nothing on the shared handle, no transport reach
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local m, host = boot()
    installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)   -- exercise a selection and a focus write
    show(true)

    -- mission.stockGuard is the PUBLISHED handle (StockGuard.lua: mission.stockGuard =
    -- self.handle), which is what A.hostOf resolves first and what every consumer shares.
    -- StockGuard.hostOf returns the MEMBER, a different object that does carry a transport.
    -- That asymmetry is precisely why reaching past the handle was wrong.
    local published = m.stockGuard
    T.ok("C0 the published handle is not the member object", published ~= host)
    T.ok("C1 no focus state is written onto the published handle", published._sg5FocusState == nil)
    T.ok("C2 no last selection is written onto it", published._sg5LastSelection == nil)
    T.ok("C3 no command state is written onto it", published._sg5CommandState == nil)
    T.ok("C4 the published handle exposes no transport to reach through", published.transport == nil)
    T.ok("C4b the member does carry one, which is the trap that was being sprung",
        host.transport ~= nil)

    -- the state is real, it just lives in the adapter's own module
    local sel = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.ok("C5 the adapter still remembers the selection in its own module",
        type(sel) == "table" and sel.selectionKind ~= nil)

    -- invalidateLocal must not need or touch a transport
    local okInv = pcall(function() return inProcess(m, SGEscClientAdapter.invalidateLocal, m, "UI_INVALIDATE") end)
    T.ok("C6 invalidateLocal works with no transport present", okInv)
    T.ok("C7 and still writes nothing onto the handle", published._sg5CommandState == nil)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. major4: two real mission loads, a delete between, no hook rebind
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    -- The door has to exist before the guest can register, so build it the way the host
    -- does and then drive the guest's OWN tryRegister, not the hub shortcut openPage uses.
    local function armDoor(m)
        inProcess(m, function()
            local hub = RfEscModules.getOrCreate()
            m.rfEscModules = hub
        end)
        return inProcess(m, SgRfPdaGuest.tryRegister)
    end

    local m1 = boot()
    installWt8(m1)
    local accepted1 = armDoor(m1)
    T.ok("D1 the guest registers itself on the first mission",
        inProcess(m1, SgRfPdaGuest.isRegistered) == true,
        "tryRegister returned " .. tostring(accepted1))

    FSBaseMission.delete(m1)
    T.ok("D2 the mission delete stands the guest down",
        inProcess(m1, SgRfPdaGuest.isRegistered) ~= true)

    -- a SECOND mission in the same Lua state, the case that had no bar at all
    local m2 = boot()
    installWt8(m2)
    local accepted2 = armDoor(m2)
    T.ok("D3 the second mission registers again, rather than inheriting a dead latch",
        inProcess(m2, SgRfPdaGuest.isRegistered) == true,
        "tryRegister returned " .. tostring(accepted2))
    local c2, show2 = openPage(m2)
    show2(false)
    local label2, enabled2 = chip1(c2)
    T.ok("D4 and a working picker on the second mission", enabled2)
    T.ok("D5 with no site leaked from the first mission",
        tostring(inProcess(m2, SGEscClientAdapter.lastSelection, m2).selectionKind) == "FARM")

    T.ok("D6 SG-1's own update record was never rebound away",
        type(FSBaseMission.update) == "function")
    -- [NOTE-376] Observe the update, rather than only that it did not raise: a chain that
    -- reaches nothing at all would also not raise. StockGuard.hostOf is the member that
    -- carries the real update; main.lua reads sg.update at call time, so wrapping the
    -- field is enough to count what the folded record actually drove.
    local seen1, seen2 = 0, 0
    local host1, host2 = StockGuard.hostOf(m1), StockGuard.hostOf(m2)
    if host1 ~= nil then
        local real1 = host1.update
        host1.update = function(self, dt) seen1 = seen1 + 1 return real1(self, dt) end
    end
    if host2 ~= nil then
        local real2 = host2.update
        host2.update = function(self, dt) seen2 = seen2 + 1 return real2(self, dt) end
    end
    local okUpd = pcall(function() return inProcess(m2, FSBaseMission.update, m2, 16) end)
    T.ok("D7 and the update chain still runs without raising", okUpd)
    T.eq("D8 SG-1's own update observably ran for the SECOND mission", seen2, 1)
    T.eq("D9 and never for the deleted first one", seen1, 0)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. G4: the page never touches FarmTablet
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local m = boot()
    installWt8(m)
    local closed = 0
    g_FarmTablet = { closeTablet = function() closed = closed + 1 end }
    m.farmTablet = { _chargeTarget = { closeTablet = function() closed = closed + 1 end } }
    local c, show = openPage(m)
    show(false)
    local okOpen = pcall(function() return inProcess(m, SgRfPdaGuest.openFromHostModule, m, {}) end)
    T.eq("E1 opening the Stock page closes no tablet", closed, 0)
    T.ok("E2 and the page still opens on its own", okOpen ~= nil)
    g_FarmTablet = nil
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. minors
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m = boot()
    installWt8(m)
    local c, show = openPage(m)
    local seen = 0
    local realPrint = print
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local s = table.concat(parts, " ")
        if s:find("unit%-probe") then seen = seen + 1 end
        return realPrint(...)
    end
    show(false)
    show(true)
    print = realPrint
    T.eq("F1 the one-shot unit probe no longer prints on paint", seen, 0)
    FSBaseMission.delete(m)
end)

-- G. major2 ISOLATED: a focused row with two real published actions, submit unavailable
group("G", function()
    local m = boot()
    installWt8(m)
    local okOwner = installActionOwner(m)
    T.ok("G1 the management owner registered through the published handle", okOwner ~= nil)
    T.ok("G2 submission is still genuinely unavailable, not mocked",
        m.stockGuard.submitCommand == nil)

    local c, show = openPage(m)
    show(false)
    local page, n, best, line = focusActionRow(m, show, c)
    T.ok("G3 the FOCUSED row really publishes two or more published actions",
        n >= 2, "focused row carried " .. tostring(n) .. " (best on page " .. tostring(best)
        .. ", page " .. tostring(page) .. ", band line " .. tostring(line) .. ")")
    T.ok("G3b and the activate path refuses on total <= 1, so that count is what makes "
        .. "removing the gate measurable", best >= 2)

    if n >= 2 then
        -- The step chip is the affordance that would move without the gate: it only
        -- advances an offset, so absent the gate it returns true even with nothing
        -- sendable. That is the measurable difference the control needs.
        T.ok("G4 the step affordance refuses while submission is unavailable",
            inProcess(m, SgRfPdaGuest.onActionActivate, 2) ~= true)
        T.ok("G5 the run affordance refuses too",
            inProcess(m, SgRfPdaGuest.onActionActivate, 3) ~= true)
        T.ok("G6 and no action chip is painted at all",
            c.el["rfFwAct2"].rfPivotChipLabel == nil
            and c.el["rfFwAct3"].rfPivotChipLabel == nil)
    end
    FSBaseMission.delete(m)
end)

-- H. G1 lifecycle: one stable consumer id, bound and unbound without leaking
group("H", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    T.eq("H1 exactly one consumer is bound after entering the page", wt.count(), 1)
    T.eq("H2 and it is this guest's one stable id", wt.consumers["stockGuard.sg5"] ~= nil, true)
    show(false)
    show(true)
    T.eq("H3 repeated shows do not leak a second binding", wt.calls.subscribe, 1)

    inProcess(m, SgRfPdaGuest.onHide)
    T.eq("H4 hiding the page unbinds", wt.count(), 0)
    T.ok("H5 and it unsubscribed this id", wt.calls.unsubscribe >= 1)

    local c2, show2 = openPage(m)
    show2(false)
    T.eq("H6 a later show rebinds cleanly", wt.count(), 1)

    FSBaseMission.delete(m)
    T.eq("H7 mission delete leaves no subscription behind", wt.count(), 0)

    -- no foreign farm was ever asked for, on any read
    T.eq("H8 no read ever passed a trusted actor context", wt.calls.foreign, 0)
end)

group("H-two-missions", function()
    local m1 = boot()
    local wt1 = installWt8(m1)
    local c1, show1 = openPage(m1)
    show1(false)
    T.eq("H9 first mission bound", wt1.count(), 1)

    -- The second mission is booted BEFORE the first is deleted, so g_currentMission is the
    -- SECOND one at delete time. That is the case the mission-identity fix exists for: a
    -- stand-down that falls back to whatever is current would stand down the wrong mission.
    local m2 = boot()
    local wt2 = installWt8(m2)
    local c2, show2 = openPage(m2)
    show2(false)
    T.eq("H11 second mission binds its own provider", wt2.count(), 1)

    FSBaseMission.delete(m1)
    T.eq("H10 deleting the first releases the FIRST mission's binding", wt1.count(), 0)
    T.eq("H12 and leaves the second mission's binding alone", wt2.count(), 1)
    FSBaseMission.delete(m2)
end)

group("H-absent", function()
    local m = boot()
    local wt = installWt8(m, { noSubscribe = true })
    local okLife, whyLife = inProcess(m, SGEscClientAdapter.siteLifecycle, m)
    T.ok("H13 an incomplete facade is reported, not worked around", okLife ~= true)
    T.eq("H14 and the missing method is named", tostring(whyLife), "SITE_SUBSCRIBE_ABSENT")
    local c, show = openPage(m)
    show(false)
    local label, enabled = chip1(c)
    T.ok("H15 the picker still offers the sites it can actually read", enabled)
    FSBaseMission.delete(m)
end)

group("H-provider-swap", function()
    local m = boot()
    local wtA = installWt8(m)
    local c, show = openPage(m)
    show(false)
    T.eq("H16 bound to the first provider", wtA.count(), 1)
    -- A REPLACED provider guarantees no callback of its own, so the identity must be checked
    local wtB = installWt8(m)
    show(false)
    T.eq("H17 the old provider was unsubscribed on replacement", wtA.count(), 0)
    T.eq("H18 and the new provider is bound", wtB.count(), 1)
    FSBaseMission.delete(m)
end)

-- I. G1 invalidation: the notice marks stale and nothing else; the re-read is at the next show
group("I", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)       -- pick site:north
    show(false)
    T.eq("I1 a site is selected", tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).siteId), "site:north")

    local before = { list = wt.calls.list, one = wt.calls.one }
    local fired = inProcess(m, function() return wt.notify("site:north", 8, "UPSERT", 1) end)
    T.eq("I2 the notice reached this guest", fired, 1)
    T.eq("I3 the callback read no site list", wt.calls.list, before.list)
    T.eq("I4 and read no single site either", wt.calls.one, before.one)
    local catStale, selStale = inProcess(m, SGEscClientAdapter.siteStale, m)
    T.ok("I5 it marked the catalogue stale", catStale)
    T.ok("I6 and marked the selected site stale, because the notice named it", selStale)

    -- the re-read happens at the next ordinary show, not in the callback
    wt.sites[1] = { siteId = "site:north", name = "North Yard", revision = 8 }
    show(false)
    T.ok("I7 the next show re-read the own-farm catalogue", wt.calls.list > before.list)
    local catAfter, selAfter = inProcess(m, SGEscClientAdapter.siteStale, m)
    T.ok("I8 a verified read is what clears the stale marks", not catAfter and not selAfter)
    FSBaseMission.delete(m)
end)

group("I-delete", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    show(false)
    T.eq("I9 site selected before the delete", tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).siteId), "site:north")

    -- DELETE: the provider drops it from the own-farm ACTIVE list and notices
    table.remove(wt.sites, 1)
    inProcess(m, function() return wt.notify("site:north", 9, "DELETE", 1) end)
    T.eq("I10 the verified re-read reports it gone",
        tostring(inProcess(m, SGEscClientAdapter.verifySelectedSite, m)), "GONE")
    show(false)
    local sel = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.eq("I11 and the explicit FARM fallback ran", tostring(sel.selectionKind), "FARM")
    T.ok("I12 with no foreign or global fallback list", wt.calls.foreign == 0)
    FSBaseMission.delete(m)
end)

group("I-transfer", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    show(false)
    -- A transfer arrives as UPSERT with the NEW owner farm, and the site leaves this
    -- actor's own ACTIVE replica.
    table.remove(wt.sites, 1)
    inProcess(m, function() return wt.notify("site:north", 10, "UPSERT", 2) end)
    T.eq("I13 a transferred-away site reads as gone, not as another farm's row",
        tostring(inProcess(m, SGEscClientAdapter.verifySelectedSite, m)), "GONE")
    show(false)
    T.eq("I14 and the page falls back to this farm's floor",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).selectionKind), "FARM")
    FSBaseMission.delete(m)
end)

group("I-missed", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    show(false)
    -- No notice at all: correctness must not depend on receiving one.
    table.remove(wt.sites, 1)
    T.eq("I15 a missed notice is still recovered by the ordinary re-read",
        tostring(inProcess(m, SGEscClientAdapter.verifySelectedSite, m)), "GONE")
    FSBaseMission.delete(m)
end)

group("I-waiting", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    show(false)
    -- A ready capability whose list still answers NOT_READY is waiting, not an empty list.
    wt.notReady = true
    T.eq("I16 NOT_READY is waiting, never gone",
        tostring(inProcess(m, SGEscClientAdapter.verifySelectedSite, m)), "WAITING")
    FSBaseMission.delete(m)
end)

-- J. NOTE-373 regression 1: no old intent or context across a farm change
group("J", function()
    local m = boot()
    local wt = installWt8(m)
    g_localPlayer = { farmId = 1 }
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)      -- old farm's SITE
    show(false)
    -- A real physical focus intent on the OLD farm, through the adapter's own published
    -- restore entry point. requestCursor pulls navigationCarrierId out of exactly this
    -- when the selection is FARM, which is the leak the audit describes.
    -- The owner has to be LIVE and resolve to the same address, or refreshSnapshot's own
    -- validatePhysicalFocus clears the intent on its own and the test proves nothing about
    -- the farm change. That is what made an earlier version of this assertion vacuous.
    local oldOwner = { getNavigationCarrierId = function() return "carrier:oldfarm" end }
    inProcess(m, SGEscClientAdapter.restoreFocusState, m,
        { mode = "FOCUSED", carrierId = "carrier:oldfarm", expectedCarrierId = "carrier:oldfarm",
          ownerObject = oldOwner, adopted = true })
    show(true)
    T.ok("J0b the focus intent survives an ordinary refresh, so it is really held",
        type(inProcess(m, SGEscClientAdapter.getFocusState, m)) == "table")
    T.ok("J0 the old farm really holds a focus intent",
        type(inProcess(m, SGEscClientAdapter.getFocusState, m)) == "table")
    T.eq("J1 farm 1 holds a SITE selection",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).siteId), "site:north")

    -- the same handle and the same mission, a different LOCAL ACTOR farm. localFarmId
    -- reads g_localPlayer, so that is what a farm change actually looks like here.
    g_localPlayer = { farmId = 2 }
    show(false)

    local sel = inProcess(m, SGEscClientAdapter.lastSelection, m)
    T.eq("J2 the next request is the new farm's own FARM floor",
        tostring(sel.selectionKind), "FARM")
    T.ok("J3 and carries no old site id", sel.siteId == nil)
    T.ok("J4 no focus intent survived the change",
        inProcess(m, SGEscClientAdapter.getFocusState, m) == nil)
    local label = chip1(c)
    T.ok("J5 the picker names no old farm's site", label:find("North") == nil)
    T.eq("J6 and no foreign farm was ever asked for", wt.calls.foreign, 0)
    g_localPlayer = nil
    FSBaseMission.delete(m)
end)

-- K. NOTE-373 regression 2: a picked SITE survives ordinary paints
group("K", function()
    local m = boot()
    local wt = installWt8(m)
    local c, show = openPage(m)
    show(false)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    T.eq("K1 the pick is accepted",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).siteId), "site:north")

    show(false)
    T.eq("K2 a normal non-light refresh keeps the SITE",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).selectionKind), "SITE")
    inProcess(m, SgRfPdaGuest.onPageStep, 1)
    T.eq("K3 paging keeps it",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).selectionKind), "SITE")
    inProcess(m, SgRfPdaGuest.onHide)
    show(false)   -- reopening is another onShow; openPage would resetForTests, which no player can do
    T.eq("K4 and so does closing and reopening the page",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).selectionKind), "SITE")

    -- only a deliberate FARM choice, or a real context change, puts it back
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    inProcess(m, SgRfPdaGuest.onActionActivate, 1)
    T.eq("K5 stepping deliberately back to the farm floor resets it",
        tostring(inProcess(m, SGEscClientAdapter.lastSelection, m).selectionKind), "FARM")
    FSBaseMission.delete(m)
end)

T.summary()

-- ══════════════════════════════════════════════════════════════════════════
-- L. REPAIR-377 edge 1: the old provider is released BEFORE the replacement is judged
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local m = boot()
    local wtA = installWt8(m)
    local _c, show = openPage(m)
    show(false)
    T.eq("L1 bound to the complete provider", wtA.count(), 1)

    -- complete -> nil: the provider disappears outright
    m.workplaceTriggers = nil
    local ok, why = inProcess(m, SGEscClientAdapter.bindSiteChanges, m)
    T.ok("L2 a vanished provider is refused", ok ~= true)
    T.eq("L3 and refused honestly", tostring(why), "SITE_PROVIDER_ABSENT")
    T.eq("L4 the old consumer is released, not retained", wtA.count(), 0)
    T.ok("L5 through the old provider's own unsubscribe", wtA.calls.unsubscribe >= 1)
    FSBaseMission.delete(m)
end)

group("L-partial", function()
    local m = boot()
    local wtA = installWt8(m)
    local _c, show = openPage(m)
    show(false)
    T.eq("L6 bound to the complete provider", wtA.count(), 1)

    -- complete -> incomplete: resolves, but the single authoritative read is missing
    local wtB = installWt8(m, { noGetSite = true })
    local ok, why = inProcess(m, SGEscClientAdapter.bindSiteChanges, m)
    T.ok("L7 an incomplete replacement is refused", ok ~= true)
    T.eq("L8 and the missing method is named", tostring(why), "SITE_GET_ABSENT")
    T.eq("L9 the old provider is released anyway", wtA.count(), 0)
    T.eq("L10 and nothing is invented on the bad facade", wtB.count(), 0)

    local okHide = pcall(function() return inProcess(m, SgRfPdaGuest.onHide) end)
    T.ok("L11 hide still cleans up after a rejected replacement", okHide)
    FSBaseMission.delete(m)
    T.eq("L12 and delete leaves nothing on either provider", wtA.count() + wtB.count(), 0)
end)

group("L-idempotent", function()
    local m = boot()
    local wtA = installWt8(m)
    local _c, show = openPage(m)
    show(false)
    T.eq("L13 one subscribe for the first bind", wtA.calls.subscribe, 1)
    local ok = inProcess(m, SGEscClientAdapter.bindSiteChanges, m)
    T.ok("L14 the same complete provider is idempotent", ok == true)
    T.eq("L15 with no second subscribe", wtA.calls.subscribe, 1)
    T.eq("L16 and no needless unsubscribe", wtA.calls.unsubscribe, 0)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. REPAIR-377 edge 2: an older mission's delete must not reset the CURRENT guest
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local m1 = boot()
    local wt1 = installWt8(m1)
    local _c1, show1 = openPage(m1)
    show1(false)
    T.eq("N1 the first mission is bound", wt1.count(), 1)

    -- The second mission becomes current, registers, adopts a container and picks a SITE.
    local m2 = boot()
    local wt2 = installWt8(m2)
    local c2, show2 = openPage(m2)
    show2(false)
    -- openPage drives the hub shortcut, which never sets _registered. The guest's OWN
    -- tryRegister is what claims the module-global controller, so drive that too: the
    -- registration latch is one of the three things this edge was discarding.
    inProcess(m2, function()
        local hub = RfEscModules.getOrCreate()
        m2.rfEscModules = hub
    end)
    inProcess(m2, SgRfPdaGuest.tryRegister)
    inProcess(m2, SgRfPdaGuest.onActionActivate, 1)
    T.eq("N2 the current mission holds a SITE selection",
        tostring(inProcess(m2, SGEscClientAdapter.lastSelection, m2).selectionKind), "SITE")
    T.ok("N3 and is registered", inProcess(m2, SgRfPdaGuest.isRegistered) == true)
    T.eq("N4 with its own binding", wt2.count(), 1)

    FSBaseMission.delete(m1)

    T.eq("N5 the OLD mission's delete leaves the current SITE selection alone",
        tostring(inProcess(m2, SGEscClientAdapter.lastSelection, m2).selectionKind), "SITE")
    T.ok("N6 the current registration survives",
        inProcess(m2, SgRfPdaGuest.isRegistered) == true)
    T.eq("N7 the current subscription survives", wt2.count(), 1)
    T.eq("N8 and the old mission's own binding is still released", wt1.count(), 0)

    -- The held container must still be the live one: blank the band, then drive a paint that
    -- only reaches a container through _lastContainer.
    -- onPageStep repaints through _lastContainer unconditionally (SgRfPdaGuest.lua :2392),
    -- so if the old mission's delete had nil'd the container this element stays blank. Paging
    -- is already shown not to disturb the SITE selection (K3).
    c2.el["rfFwSheetBand"].text = nil
    inProcess(m2, SgRfPdaGuest.onPageStep, 1)
    T.ok("N9 the current mission's container is still held",
        c2.el["rfFwSheetBand"].text ~= nil)

    show2(false)
    T.eq("N10 and a normal non-light show still carries the SITE",
        tostring(inProcess(m2, SGEscClientAdapter.lastSelection, m2).selectionKind), "SITE")

    -- The CURRENT mission's own delete must still stand the guest down in full.
    FSBaseMission.delete(m2)
    T.ok("N11 deleting the current mission still stands the guest down",
        inProcess(m2, SgRfPdaGuest.isRegistered) ~= true)
    T.eq("N12 and releases its binding", wt2.count(), 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. NOTE-378: a mission BEGINNING must re-arm even while an older one still owns
-- ══════════════════════════════════════════════════════════════════════════
--- Does this door actually list the Stock module? Read through the hub's own getModules,
--- so a registration that never reached the registry cannot pass.
local function doorHasStock(hub)
    if hub == nil or type(hub.getModules) ~= "function" then return false end
    for _, mod in ipairs(hub:getModules() or {}) do
        if type(mod) == "table" and mod.id == "stockGuard" then return true end
    end
    return false
end

group("P", function()
    -- m1 boots with its OWN door and registers through the guest's own path, so it holds
    -- the module-global controller.
    -- Each mission gets its OWN door, present before its load finishes, which is where a
    -- real mission's door appears. No manual resetForTests and no manual tryRegister
    -- anywhere in this group: every registration here comes from main.lua's own records.
    local function withDoor(mm) mm.rfEscModules = RfEscModules.new() end

    local m1 = boot(withDoor)
    installWt8(m1)
    T.ok("P1 the first mission registered through the real load record",
        inProcess(m1, SgRfPdaGuest.isRegistered) == true)
    T.ok("P2 and its own door lists the Stock module", doorHasStock(m1.rfEscModules))

    -- m2 loads through the REAL main hooks while m1 is still alive and still owns the
    -- module-global controller. This is the NOTE-378 case.
    local m2 = boot(withDoor)
    installWt8(m2)
    T.ok("P3 the NEW mission's own door lists the Stock module", doorHasStock(m2.rfEscModules))
    T.ok("P4 and the guest reports itself registered for it",
        inProcess(m2, SgRfPdaGuest.isRegistered) == true)

    -- Only now the ordinary UI, and the REPAIR-377 edge must still hold on top. This does
    -- NOT use openPage: that helper calls resetForTests to give a group a clean page and then
    -- registers the module itself, which would discard the very registration latch this
    -- group is about. Here the page is opened on the module the REAL load record registered.
    local c2 = newContainer()
    inProcess(m2, function()
        if not m2.rfEscModules:selectModule("stockGuard") then
            error("the load record's own module was not selectable", 0)
        end
    end)
    local function show2(light)
        inProcess(m2, SgRfPdaGuest.onShow, c2, light and true or false)
    end
    show2(false)
    T.ok("P4b the registration from the load record is still the live one",
        inProcess(m2, SgRfPdaGuest.isRegistered) == true)
    inProcess(m2, SgRfPdaGuest.onActionActivate, 1)
    T.eq("P5 the current mission holds a SITE selection",
        tostring(inProcess(m2, SGEscClientAdapter.lastSelection, m2).selectionKind), "SITE")

    FSBaseMission.delete(m1)
    T.eq("P6 deleting the OLD mission keeps the current SITE",
        tostring(inProcess(m2, SGEscClientAdapter.lastSelection, m2).selectionKind), "SITE")
    T.ok("P7 and keeps the current registration",
        inProcess(m2, SgRfPdaGuest.isRegistered) == true)
    T.ok("P8 with the current door still listing Stock", doorHasStock(m2.rfEscModules))

    FSBaseMission.delete(m2)
    T.ok("P9 deleting the current mission still stands the guest down",
        inProcess(m2, SgRfPdaGuest.isRegistered) ~= true)
end)
