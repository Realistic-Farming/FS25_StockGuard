-- SG2-1-native_join_spec_test.lua
--
-- The SG2-1 native join and the two carrier adapters, driven through the ROUTE
-- THE GAME USES: the mission handle's registerCarrierAdapter, the restore-complete
-- barrier's enumeration, observeCarrier and refreshCarrier, and a saved envelope
-- restored through the coordinator and stageLoad. Bob's intake (ledger d4b7216)
-- found the old adapter bench called the adapter functions directly with invented
-- keys and never went through register, enumerateAdapter and bindCarrier; that is
-- how six contract defects stayed green.
--
-- Groups:
--   J  the core join: resolveCarrier, readNativeState, resolveAlias, observe, refresh
--   R  the restore join: restoreBinding, the one-to-one map, resolve on restore
--   N  the Storage and FillUnit adapters against an engine model, through the barrier
--   H  the native host: coalescing, boundaries, open frames, lifecycle hooks
--
-- Every group runs inside group(), so a Lua error fails a named row instead of
-- the runner discarding the whole file. Every refusal is paired with a twin that
-- proves the fixture reaches the branch.
--
--!load: src/capacity/SGSha256.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGNativeHost.lua

FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15, MAX_FARM_ID = 8, MAX_NUM_FARMS = 8 }
getTimeSec = function() return 100 end
StockGuardCapacity = { isReady = function() return true end }

local NA = SGNativeAdapters
local NH = SGNativeHost

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── Engine model ────────────────────────────────────────────────────────────
FillType = { UNKNOWN = 0 }
local FT_NAMES = { [1] = "WHEAT", [2] = "BARLEY", [3] = "DIESEL", [4] = "GRASS" }
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FT_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(FT_NAMES) do if v == n then return i end end return nil end,
}
local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }

-- Storage: a metatable class (mechanism 4), so a class wrap reaches instances.
local StorageClass = {}
StorageClass.__index = StorageClass
function StorageClass:setFillLevel(level, fillType)
    if self.fillTypes[fillType] ~= true then return end
    self.fillLevels[fillType] = math.max(0, math.min(level, self.capacity))
end
function StorageClass:empty()
    for ft in pairs(self.fillLevels) do self.fillLevels[ft] = 0 end
end
function StorageClass:getCapacity(ft) return self.capacity end
function StorageClass:getOwnerFarmId() return self.ownerFarmId end
local function newStorage(levels, ownerFarmId)
    local s = setmetatable({ fillTypes = { [1] = true, [2] = true, [4] = true }, fillLevels = { [1] = 0, [2] = 0, [4] = 0 }, capacity = 1000, ownerFarmId = ownerFarmId or 1 }, StorageClass)
    for ft, l in pairs(levels or {}) do s.fillLevels[ft] = l end
    return s
end

local function newSilo(uid, storages, perFarm)
    return { uniqueId = uid, getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
             spec_silo = { storages = storages, storagePerFarm = perFarm == true } }
end

-- Vehicle: instance functions (mechanism 2), getters, a motorized consumer unit.
local function newVehicle(uid, units, consumerIndex)
    local v = { uniqueId = uid, configFileName = "data/vehicles/trailer.xml", ownerFarmId = 1,
                spec_fillUnit = { fillUnits = units } }
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
    v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
    v.getFillUnitCapacity = function(self, i) return self.spec_fillUnit.fillUnits[i].capacity end
    v.addFillUnitFillLevel = function(self, farmId, i, delta, ft)
        local u = self.spec_fillUnit.fillUnits[i]
        if u == nil then return 0 end
        local before = u.fillLevel
        u.fillLevel = math.max(0, math.min(u.fillLevel + delta, u.capacity))
        if u.fillLevel > 0 then u.fillType = ft end
        if u.fillLevel == 0 then u.fillType = FillType.UNKNOWN end
        return u.fillLevel - before
    end
    v.setFillUnitFillType = function(self, i, ft) self.spec_fillUnit.fillUnits[i].fillType = ft end
    v.emptyAllFillUnits = function(self) for _, u in ipairs(self.spec_fillUnit.fillUnits) do u.fillLevel = 0 u.fillType = FillType.UNKNOWN end end
    if consumerIndex ~= nil then v.spec_motorized = { consumers = { { fillUnitIndex = consumerIndex } } } end
    return v
end

-- A mission with the systems the adapters read.
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(opts)
    opts = opts or {}
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = opts.mp == true },
        userManager = { getUserByConnection = function() return nil end }, _placeables = opts.placeables or {}, _vehicles = opts.vehicles or {} }, Mission)
    m.accessCalls = {}
    m.accessHandler = { canFarmAccess = function(_, farmId, object, allowEqual)
        m.accessCalls[#m.accessCalls + 1] = { farmId = farmId, object = object, allowEqual = allowEqual }
        return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId
    end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function(_, id) for _, p in ipairs(m._placeables) do if p.uniqueId == id then return p end end return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    return m
end

--- Attach StockGuard to a mission, install the native host, run the barrier.
local function boot(m, beforeBarrier)
    g_server = {}
    g_currentMission = m
    local sg = StockGuard.attach(m)
    sg:installFinishedLoadingObserver()
    local host = NH.new(m.stockGuard, { placeables = function() return m._placeables end, vehicles = function() return m._vehicles end })
    local ok, why = host:install()
    if beforeBarrier ~= nil then beforeBarrier(sg, host) end
    m:onFinishedLoading()
    return sg, host, ok, why
end

local function shutdown(sg, host)
    if host ~= nil then host:teardown() end
    if sg ~= nil then sg:delete() end
end

local function carrierOf(sg, binding) return sg.operations.carriers[SGRecords.carrierKeyString(binding.carrierKey)] end
local function stockOf(sg, binding)
    local c = carrierOf(sg, binding)
    return c ~= nil and c.stockId ~= nil and sg.operations.stocks[c.stockId] or nil
end

-- A plain fake adapter for the core join groups.
local function fakeBinding(owner, comp, basis)
    return { carrierKey = { adapterId = "fake", nativeOwnerKey = owner, componentKey = comp }, adapterVersion = 1, profileId = "FAKE_V1", profileVersion = 1, quantityBasisKey = basis or (owner .. "/" .. comp) }
end

-- ══════════════════════════════════════════════════════════════════════════
-- J. THE CORE JOIN
-- ══════════════════════════════════════════════════════════════════════════
group("J", function()
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local sg = StockGuard.attach(m)
    sg:installFinishedLoadingObserver()
    local world = { a = { amount = 10 }, b = { amount = 0 }, gone = nil }
    local reads, resolves = 0, 0
    local spec = {
        version = 1, carrierKinds = { "silo" },
        resolveCarrier = function(binding) resolves = resolves + 1 local k = binding.carrierKey.nativeOwnerKey if k == "throws" then error("resolve boom") end return world[k], "NOT_IN_WORLD" end,
        readNativeState = function(binding, native) reads = reads + 1 if native.unreadable then return nil, "BROKEN" end return { materialRef = native.amount > 0 and wheat or nil, amount = native.amount, unit = "LITRE" } end,
        enumerateCarriers = function()
            return { { binding = fakeBinding("a", "1"), nativeState = { materialRef = wheat, amount = 999, unit = "LITRE" } },
                     { binding = fakeBinding("gone", "1") }, { binding = fakeBinding("throws", "1") }, { nope = true } }
        end,
        hasAccess = function() return true end,
    }
    local bindingNotices = 0
    spec.onCarrierBindingChanged = function(binding, state) if binding.carrierKey.nativeOwnerKey == "a" then bindingNotices = bindingNotices + 1 end end
    local lease = m.stockGuard.registerCarrierAdapter("fake", spec)
    m:onFinishedLoading()

    local a = fakeBinding("a", "1")
    T.ok("J1 [reached] the barrier bound the resolvable entry", carrierOf(sg, a) ~= nil)
    T.eq("J2 its state is the ADAPTER'S READ (10), not the 999 pushed in the entry", stockOf(sg, a).observedAmount, 10)
    T.eq("J3 an entry the adapter cannot resolve is not bound", carrierOf(sg, fakeBinding("gone", "1")), nil)
    T.eq("J4 a resolve that throws is not bound and does not propagate", carrierOf(sg, fakeBinding("throws", "1")), nil)
    T.eq("J5 exactly one carrier bound from four entries", sg:status().carriers, 1)

    -- observeCarrier without a state reads through the join.
    world.a.amount = 25
    local key = SGRecords.carrierKeyString(a.carrierKey)
    local before = reads
    local c = m.stockGuard.observeCarrier(lease, key, nil)
    T.ok("J6 [reached] an observation with no state returns the carrier", c ~= nil)
    T.eq("J7 and the adapter was read", reads, before + 1)
    T.eq("J8 the stock follows the native read", stockOf(sg, a).observedAmount, 25)
    T.eq("J8b an observation reconciles; it does not re-announce the binding as newly READY", bindingNotices, 1)

    -- A pushed state still reconciles (the SG-1 push path is kept).
    m.stockGuard.observeCarrier(lease, key, { materialRef = wheat, amount = 30, unit = "LITRE" })
    T.eq("J9 a pushed state reconciles as before", stockOf(sg, a).observedAmount, 30)

    -- Another adapter never observes this adapter's carrier, pushed or read.
    local other = m.stockGuard.registerCarrierAdapter("other", { version = 1, carrierKinds = { "x" }, resolveCarrier = function() return {} end,
        readNativeState = function() return { amount = 0, unit = "LITRE" } end, enumerateCarriers = function() return {} end, hasAccess = function() return true end })
    T.eq("J10 a foreign lease reading is refused", select(2, m.stockGuard.observeCarrier(other, key, nil)), "ADAPTER_MISMATCH")
    T.eq("J11 a foreign lease pushing is refused", select(2, m.stockGuard.observeCarrier(other, key, { materialRef = wheat, amount = 1, unit = "LITRE" })), "ADAPTER_MISMATCH")
    T.eq("J12 and the stock did not move", stockOf(sg, a).observedAmount, 30)
    T.eq("J13 an unknown carrier id is refused", select(2, m.stockGuard.observeCarrier(lease, "nope", nil)), "UNKNOWN_CARRIER")

    -- refreshCarrier binds on demand; an unreadable carrier is refused with its reason.
    world.b.amount = 40
    local b = fakeBinding("b", "1")
    T.ok("J14 refreshCarrier binds an unbound binding", m.stockGuard.refreshCarrier(lease, b, "TEST") ~= nil and stockOf(sg, b).observedAmount == 40)
    world.u = { amount = 5, unreadable = true }
    T.eq("J15 an unreadable native carrier is refused with the adapter's reason", select(2, m.stockGuard.refreshCarrier(lease, fakeBinding("u", "1"), "TEST")), "UNREADABLE:BROKEN")
    T.eq("J16 an unresolvable one names why", select(2, m.stockGuard.refreshCarrier(lease, fakeBinding("zz", "1"), "TEST")), "UNRESOLVED:NOT_IN_WORLD")
    T.eq("J17 a binding for another adapter is refused", select(2, m.stockGuard.refreshCarrier(lease, { carrierKey = { adapterId = "other", nativeOwnerKey = "a", componentKey = "1" }, adapterVersion = 1, profileId = "P", profileVersion = 1, quantityBasisKey = "q" }, "TEST")), "ADAPTER_MISMATCH")

    -- A read that returns a state SG-1 refuses binds nothing.
    world.bad = { amount = 5 }
    spec.readNativeState = function(binding, native) if native == world.bad then return { amount = 5, unit = "LITRE" } end return { materialRef = native.amount > 0 and wheat or nil, amount = native.amount, unit = "LITRE" } end
    T.eq("J18 a nonempty read with no material is refused by the core", select(2, m.stockGuard.refreshCarrier(lease, fakeBinding("bad", "1"), "TEST")), "MATERIAL_REF")
    T.eq("J19 and bound nothing", carrierOf(sg, fakeBinding("bad", "1")), nil)
    shutdown(sg, nil)
end)

group("J-alias", function()
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local sg = StockGuard.attach(m)
    sg:installFinishedLoadingObserver()
    local canonical = fakeBinding("baler", "bale", "baler/bale")
    local alias = fakeBinding("baler", "chamber", "baler/bale")
    local stray = fakeBinding("baler", "stray", "other/basis")
    local aliasOn = true
    local spec = {
        version = 1, carrierKinds = { "baler" },
        resolveCarrier = function(b) return { amount = 50 } end,
        readNativeState = function(b, n) return { materialRef = wheat, amount = n.amount, unit = "LITRE" } end,
        enumerateCarriers = function() return { { binding = canonical }, { binding = alias } } end,
        hasAccess = function() return true end,
        resolveAlias = function(b)
            if not aliasOn then return nil end
            if b.carrierKey.componentKey == "chamber" then return canonical end
            if b.carrierKey.componentKey == "stray" then return canonical end
            return nil
        end,
    }
    local lease = m.stockGuard.registerCarrierAdapter("fake", spec)
    m:onFinishedLoading()
    T.ok("J20 [reached] the canonical carrier is bound", carrierOf(sg, canonical) ~= nil)
    T.eq("J21 the alias is NOT a second carrier", carrierOf(sg, alias), nil)
    T.eq("J22 one physical quantity is one stock", sg:status().stocks, 1)
    T.eq("J23 an alias over a different quantity basis is refused, never merged", select(2, m.stockGuard.refreshCarrier(lease, stray, "TEST")), "ALIAS_BASIS")
    aliasOn = false
    m.stockGuard.refreshCarrier(lease, alias, "TEST")
    T.eq("J24 twin: without resolveAlias's answer the same binding IS its own carrier", carrierOf(sg, alias) ~= nil, true)
    spec.resolveAlias = function() error("alias boom") end
    T.eq("J25 a resolveAlias that throws refuses with a reason", select(2, m.stockGuard.refreshCarrier(lease, fakeBinding("baler", "z"), "TEST")), "ALIAS_ERROR")
    shutdown(sg, nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RESTORE JOIN (through the coordinator and stageLoad)
-- ══════════════════════════════════════════════════════════════════════════

--- Build a saved envelope from a first mission whose fake adapter binds `saved`.
local function savedEnvelope(entries)
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local sg = StockGuard.attach(m)
    sg:installFinishedLoadingObserver()
    local byKey = {}
    for _, e in ipairs(entries) do byKey[e.binding.carrierKey.nativeOwnerKey .. "|" .. e.binding.carrierKey.componentKey] = e.amount end
    m.stockGuard.registerCarrierAdapter("fake", { version = 1, carrierKinds = { "silo" },
        resolveCarrier = function(b) local amt = byKey[b.carrierKey.nativeOwnerKey .. "|" .. b.carrierKey.componentKey] if amt == nil then return nil end return { amount = amt } end,
        readNativeState = function(b, n) return { materialRef = n.amount > 0 and wheat or nil, amount = n.amount, unit = "LITRE" } end,
        enumerateCarriers = function() local out = {} for _, e in ipairs(entries) do out[#out + 1] = { binding = e.binding } end return out end,
        hasAccess = function() return true end })
    m:onFinishedLoading()
    local ids = {}
    for _, e in ipairs(entries) do local s = stockOf(sg, e.binding) ids[#ids + 1] = s and s.stockId or nil end
    sg.save.backendId = SGSave.BACKEND_XML
    local env = sg.save:buildEnvelope({})
    shutdown(sg, nil)
    return SGValues.decode(SGValues.encode(env)), ids
end

--- Load an envelope into a second mission with the given adapter spec.
local function restoreInto(env, spec)
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local sg = StockGuard.attach(m)
    sg:installFinishedLoadingObserver()
    m.stockGuard.registerCarrierAdapter("fake", spec)
    sg.save.backendId = SGSave.BACKEND_XML
    sg:onLoadMission00Finished()
    sg.coordinator:retainPayload(env, "xml")
    m:onFinishedLoading()
    return sg, m
end

group("R", function()
    local old1, old2 = fakeBinding("silo:OLD", "1", "q1"), fakeBinding("silo:OLD", "2", "q2")
    local env, ids = savedEnvelope({ { binding = old1, amount = 60 }, { binding = old2, amount = 70 } })
    T.ok("R0 [reached] the first mission saved two stocks", ids[1] ~= nil and ids[2] ~= nil and #env.coreValues.stocks == 2)

    -- R1: restoreBinding remaps each saved key; the stock reattaches to the NEW carrier.
    local new1, new2 = fakeBinding("silo:NEW", "1", "q1"), fakeBinding("silo:NEW", "2", "q2")
    local seenContext = nil
    local world = { ["silo:NEW|1"] = 60, ["silo:NEW|2"] = 70 }
    local function worldSpec(extra)
        local s = { version = 1, carrierKinds = { "silo" },
            resolveCarrier = function(b) local amt = world[b.carrierKey.nativeOwnerKey .. "|" .. b.carrierKey.componentKey] if amt == nil then return nil end return { amount = amt } end,
            readNativeState = function(b, n) return { materialRef = n.amount > 0 and wheat or nil, amount = n.amount, unit = "LITRE" } end,
            enumerateCarriers = function() return {} end,
            hasAccess = function() return true end }
        for k, v in pairs(extra or {}) do s[k] = v end
        return s
    end
    local sg = restoreInto(env, worldSpec({ restoreBinding = function(saved, context)
        seenContext = context
        local c = SGValues.copy(saved)
        c.carrierKey.nativeOwnerKey = "silo:NEW"
        return c
    end }))
    T.ok("R1 [reached] restoreBinding received the load context with farmRestore", type(seenContext) == "table" and type(seenContext.farmRestore) == "table" and seenContext.farmRestore.phase ~= nil)
    T.ok("R2 the remapped carrier was resolved and bound during restore (enumeration named nothing)", carrierOf(sg, new1) ~= nil and carrierOf(sg, new2) ~= nil)
    T.eq("R3 the saved stock reattached to the remapped carrier, identity kept", stockOf(sg, new1) and stockOf(sg, new1).stockId, ids[1])
    T.eq("R4 and the second one too", stockOf(sg, new2) and stockOf(sg, new2).stockId, ids[2])
    T.eq("R5 the load reports two restored", sg.save.loadResult.core.restored .. "/" .. sg.save.loadResult.core.refused, "2/0")
    shutdown(sg, nil)

    -- R6: a refusal keeps the saved facts historical with the adapter's reason.
    world = { ["silo:OLD|1"] = 60, ["silo:OLD|2"] = 70 }
    sg = restoreInto(env, worldSpec({ restoreBinding = function(saved) if saved.carrierKey.componentKey == "1" then return nil, "LAYOUT" end return saved end,
        enumerateCarriers = function() return { { binding = old1 }, { binding = old2 } } end }))
    T.eq("R6 a refused binding's stock is NOT reattached though amount and material match", stockOf(sg, old1) ~= nil and stockOf(sg, old1).stockId == ids[1], false)
    T.eq("R7 its saved facts are historical with the refusal reason", sg.operations.retiredStocks[ids[1]] and sg.operations.retiredStocks[ids[1]].retireReason, "RESTORE_BINDING_REFUSED:LAYOUT")
    T.eq("R8 twin: the unrefused binding reattached", stockOf(sg, old2) and stockOf(sg, old2).stockId, ids[2])
    T.eq("R9 the live stock of the refused carrier stays UNKNOWN", stockOf(sg, old1) and stockOf(sg, old1).knowledge, "UNKNOWN")
    shutdown(sg, nil)

    -- R10: two saved carriers mapped onto ONE current carrier collide; neither is chosen.
    world = { ["silo:ONE|1"] = 60 }
    local one = fakeBinding("silo:ONE", "1", "q1")
    sg = restoreInto(env, worldSpec({ restoreBinding = function(saved)
        local c = SGValues.copy(saved)
        c.carrierKey.nativeOwnerKey, c.carrierKey.componentKey, c.quantityBasisKey = "silo:ONE", "1", "q1"
        return c
    end, enumerateCarriers = function() return { { binding = one } } end }))
    T.eq("R10 a collision reattaches NEITHER claimant", stockOf(sg, one) ~= nil and (stockOf(sg, one).stockId == ids[1] or stockOf(sg, one).stockId == ids[2]), false)
    T.eq("R11 both are historical as a collision", tostring(sg.operations.retiredStocks[ids[1]] and sg.operations.retiredStocks[ids[1]].retireReason) .. "/" .. tostring(sg.operations.retiredStocks[ids[2]] and sg.operations.retiredStocks[ids[2]].retireReason), "RESTORE_COLLISION/RESTORE_COLLISION")
    T.eq("R12 [reached] the current carrier itself was bound", carrierOf(sg, one) ~= nil, true)
    shutdown(sg, nil)

    -- R13: a restoreBinding that throws, or answers another adapter's binding.
    world = { ["silo:OLD|1"] = 60, ["silo:OLD|2"] = 70 }
    sg = restoreInto(env, worldSpec({ restoreBinding = function(saved)
        if saved.carrierKey.componentKey == "1" then error("restore boom") end
        local c = SGValues.copy(saved) c.carrierKey.adapterId = "someoneElse" return c
    end, enumerateCarriers = function() return { { binding = old1 }, { binding = old2 } } end }))
    T.eq("R13 a throwing restoreBinding is a refusal, not a crash", sg.operations.retiredStocks[ids[1]] and sg.operations.retiredStocks[ids[1]].retireReason, "RESTORE_BINDING_ERROR")
    T.eq("R14 a binding for another adapter is refused as invalid", sg.operations.retiredStocks[ids[2]] and sg.operations.retiredStocks[ids[2]].retireReason, "RESTORE_BINDING_INVALID")
    shutdown(sg, nil)

    -- R15: no restoreBinding: the saved binding is its own, and a carrier the
    -- enumeration missed is still resolved on restore.
    world = { ["silo:OLD|1"] = 60, ["silo:OLD|2"] = 70 }
    sg = restoreInto(env, worldSpec({}))
    T.eq("R15 without restoreBinding a resolvable saved carrier is bound on restore and reattaches", tostring(stockOf(sg, old1) and stockOf(sg, old1).stockId == ids[1]) .. "/" .. tostring(stockOf(sg, old2) and stockOf(sg, old2).stockId == ids[2]), "true/true")
    shutdown(sg, nil)
    world = {}
    sg = restoreInto(env, worldSpec({}))
    T.eq("R16 twin: an unresolvable saved carrier stays historical as CARRIER_ABSENT", sg.operations.retiredStocks[ids[1]] and sg.operations.retiredStocks[ids[1]].retireReason, "CARRIER_ABSENT")
    shutdown(sg, nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE STORAGE AND FILLUNIT ADAPTERS, THROUGH THE BARRIER
-- ══════════════════════════════════════════════════════════════════════════
group("N-storage", function()
    local s0 = newStorage({ [1] = 60 })
    local s1 = newStorage({ [2] = 15, [4] = 5 })
    local silo = newSilo("placeable:silo1", { s0, s1 }, false)
    local heap = { uniqueId = "placeable:heap", getUniqueId = function(self) return self.uniqueId end, spec_manureHeap = { manureHeap = newStorage({ [1] = 99 }) } }
    local anon = newSilo(nil, { newStorage({ [1] = 7 }) }, false)
    anon.getUniqueId = function() return nil end
    local m = newMission({ placeables = { silo, heap, anon } })
    local sg, host, ok, why = boot(m)
    T.ok("N1 [reached] the native host installed and registered both adapters: " .. tostring(why), ok == true and sg:status().adapters == 2)

    local b0 = NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "shared" }, "WHEAT")
    local b1b = NA.storageBinding(silo, { role = "silo", ordinal = 1, partition = "shared" }, "BARLEY")
    local b1g = NA.storageBinding(silo, { role = "silo", ordinal = 1, partition = "shared" }, "GRASS")
    local b1w = NA.storageBinding(silo, { role = "silo", ordinal = 1, partition = "shared" }, "WHEAT")
    T.eq("N2 defect 1: the barrier's enumeration BINDS through the handle (3 held slots)", sg:status().carriers, 3)
    T.ok("N3 defect 2: the binding is a valid SG-1 CarrierBinding", SGRecords.isCarrierBinding(b0))
    T.eq("N4 with the storage slot profile", b0.profileId .. "/" .. b0.profileVersion .. "/" .. b0.adapterVersion, "NATIVE_STORAGE_SLOT_V1/1/1")
    T.eq("N5 defect 3: one carrier per FILL TYPE, with a FILL_TYPE materialRef", stockOf(sg, b0) and stockOf(sg, b0).materialRef.fillTypeName .. "/" .. stockOf(sg, b0).observedAmount, "WHEAT/60")
    T.eq("N6 two fill types in one storage are two carriers", tostring(stockOf(sg, b1b) ~= nil) .. "/" .. tostring(stockOf(sg, b1g) ~= nil), "true/true")
    T.eq("N7 an empty supported slot is not enumerated", carrierOf(sg, b1w), nil)
    T.eq("N8 defect 5: keyed by the PLACEABLE's unique id and the slot", b0.carrierKey.nativeOwnerKey .. "|" .. b0.carrierKey.componentKey, "placeable:silo1|silo:0:shared:WHEAT")
    T.eq("N9 the second storage has ordinal 1", b1b.carrierKey.componentKey, "silo:1:shared:BARLEY")
    T.eq("N10 quantityBasisKey is the carrier's own key", b0.quantityBasisKey, SGRecords.carrierKeyString(b0.carrierKey))
    T.eq("N11 the unit is LITRE and the store kind ordinary", stockOf(sg, b0).amountUnit .. "/" .. carrierOf(sg, b0).native.storeKind, "LITRE/ordinary_station")
    T.eq("N12 a ManureHeap (not a Storage) is not enumerated", sg:status().carriers, 3)
    T.eq("N13 a placeable with no unique id is not enumerated", carrierOf(sg, NA.storageBinding({ uniqueId = "x", getUniqueId = function() return "x" end }, { role = "silo", ordinal = 0, partition = "shared" }, "WHEAT")), nil)

    -- defect 4: hasAccess(binding, actor), as the core calls it.
    local lease = host.storageLease
    local farm1 = { farmId = 1, actorState = "RESOLVED" }
    local farm2 = { farmId = 2, actorState = "RESOLVED" }
    m.accessCalls = {}
    T.eq("N14 defect 4: hasAccess(binding, actor) grants the owning farm", lease.spec.hasAccess(SGValues.copy(b0), farm1), true)
    T.ok("N15 and asked the native handler with the actor's farm and the STORAGE object", #m.accessCalls == 1 and m.accessCalls[1].farmId == 1 and m.accessCalls[1].object == s0 and m.accessCalls[1].allowEqual == true)
    T.eq("N16 another farm is refused by the handler", lease.spec.hasAccess(SGValues.copy(b0), farm2), false)
    T.eq("N17 an unresolved actor is refused before the handler is asked", lease.spec.hasAccess(SGValues.copy(b0), { farmId = 1, actorState = "WAITING" }), false)
    local handler = m.accessHandler
    m.accessHandler = {}
    T.eq("N18 a handler with no canFarmAccess refuses", lease.spec.hasAccess(SGValues.copy(b0), farm1), false)
    m.accessHandler = { canFarmAccess = function() error("boom") end }
    T.eq("N19 a handler that throws refuses", lease.spec.hasAccess(SGValues.copy(b0), farm1), false)
    m.accessHandler = { canFarmAccess = function() return 1 end }
    T.eq("N20 a truthy non-boolean is not permission", lease.spec.hasAccess(SGValues.copy(b0), farm1), false)
    m.accessHandler = { canFarmAccess = function() return true end }
    T.eq("N21 twin: a permissive handler grants", lease.spec.hasAccess(SGValues.copy(b0), farm1), true)
    g_server = nil
    T.eq("N22 a client is refused access EVEN THOUGH the handler grants", lease.spec.hasAccess(SGValues.copy(b0), farm1), false)
    T.eq("N23 a client resolves nothing", lease.spec.resolveCarrier(SGValues.copy(b0)), nil)
    T.eq("N24 reads nothing", lease.spec.readNativeState(SGValues.copy(b0), { storage = s0, fillTypeIndex = 1, fillTypeName = "WHEAT", partition = "shared", placeable = silo }), nil)
    T.eq("N25 and enumerates nothing", #lease.spec.enumerateCarriers(), 0)
    g_server = {}
    m.accessHandler = handler

    -- Resolve refusals name why.
    T.eq("N26 a fill type the storage does not support does not resolve", select(2, lease.spec.resolveCarrier(NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "shared" }, "DIESEL"))), "FILL_TYPE_UNSUPPORTED")
    T.eq("N27 an ordinal the placeable does not have does not resolve", select(2, lease.spec.resolveCarrier(NA.storageBinding(silo, { role = "silo", ordinal = 5, partition = "shared" }, "WHEAT"))), "SLOT_ABSENT")
    local forged = SGValues.copy(b0)
    forged.sourceDescriptor.ordinal = 1
    T.eq("N28 a descriptor that does not describe its key does not resolve", select(2, lease.spec.resolveCarrier(forged)), "DESCRIPTOR")
    T.ok("N29 twin: the real binding resolves to its storage", lease.spec.resolveCarrier(SGValues.copy(b0)).storage == s0)
    shutdown(sg, host)
end)

group("N-perfarm", function()
    -- A per-farm silo in multiplayer loads each XML storage once per farm, in XML
    -- order within each farm (PlaceableSilo.lua:69-84): flat [o0f1, o0f2, o1f1, o1f2].
    local o0f1, o0f2, o1f1, o1f2 = newStorage({ [1] = 60 }, 1), newStorage({ [1] = 60 }, 2), newStorage({ [2] = 10 }, 1), newStorage({ [2] = 20 }, 2)
    local silo = newSilo("placeable:pf", { o0f1, o0f2, o1f1, o1f2 }, true)
    local m = newMission({ mp = true, placeables = { silo } })
    local sg, host = boot(m)
    local f2o0 = NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "farm2" }, "WHEAT")
    local f1o1 = NA.storageBinding(silo, { role = "silo", ordinal = 1, partition = "farm1" }, "BARLEY")
    T.eq("N30 [reached] four partition slots bound", sg:status().carriers, 4)
    T.eq("N31 the ordinal is the rank WITHIN the farm, not the flat index (farm2's first storage is ordinal 0)", tostring(stockOf(sg, f2o0) ~= nil) .. "/" .. f2o0.carrierKey.componentKey, "true/silo:0:farm2:WHEAT")
    T.eq("N32 flat index 3 is farm1 ordinal 1", stockOf(sg, f1o1) and stockOf(sg, f1o1).observedAmount, 10)
    T.eq("N33 a partition's store kind is per_farm_partition", carrierOf(sg, f2o0).native.storeKind, "per_farm_partition")
    local spec = host.storageLease.spec
    T.eq("N34 restoreBinding keeps a partition in multiplayer", spec.restoreBinding(SGValues.copy(f2o0), { farmRestore = { phase = "UNCHANGED" } }) ~= nil, true)
    T.eq("N35 restoreBinding refuses a partition under a native farm merge", select(2, spec.restoreBinding(SGValues.copy(f2o0), { farmRestore = { phase = "MERGED" } })), "PER_FARM_LAYOUT")
    m.missionDynamicInfo.isMultiplayer = false
    T.eq("N36 and refuses it in singleplayer, where the partition layout does not exist", select(2, spec.restoreBinding(SGValues.copy(f2o0), {})), "PER_FARM_LAYOUT")
    local shared = NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "shared" }, "WHEAT")
    T.eq("N37 twin: a shared slot is its own binding in singleplayer", spec.restoreBinding(SGValues.copy(shared), {}) ~= nil, true)
    m.missionDynamicInfo.isMultiplayer = true
    sg.save.backendId = SGSave.BACKEND_XML
    local env = SGValues.decode(SGValues.encode(sg.save:buildEnvelope({})))
    local savedFarm1 = stockOf(sg, NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "farm1" }, "WHEAT")).stockId
    shutdown(sg, host)

    -- Reload that multiplayer save in singleplayer. The engine's flat-index load
    -- puts farm1 ordinal 0's 60 L of WHEAT in the first shared storage: the SAME
    -- amount and material the saved partition stock had. It must not reattach.
    local spSilo = newSilo("placeable:pf", { newStorage({ [1] = 60 }, 1), newStorage({ [1] = 60 }, 1) }, true)
    local m2 = newMission({ mp = false, placeables = { spSilo } })
    g_server = {}
    g_currentMission = m2
    local sg2 = StockGuard.attach(m2)
    sg2:installFinishedLoadingObserver()
    local host2 = NH.new(m2.stockGuard, { placeables = function() return m2._placeables end, vehicles = function() return {} end })
    host2:install()
    sg2.save.backendId = SGSave.BACKEND_XML
    sg2:onLoadMission00Finished()
    sg2.coordinator:retainPayload(env, "xml")
    m2:onFinishedLoading()
    local spShared = NA.storageBinding(spSilo, { role = "silo", ordinal = 0, partition = "shared" }, "WHEAT")
    T.ok("N38 [reached] the singleplayer shared slot is bound", stockOf(sg2, spShared) ~= nil)
    T.eq("N39 a partition stock never reattaches to a shared slot with equal litres", stockOf(sg2, spShared).stockId == savedFarm1, false)
    T.eq("N40 it is retained as history with the layout reason", sg2.operations.retiredStocks[savedFarm1] and sg2.operations.retiredStocks[savedFarm1].retireReason, "RESTORE_BINDING_REFUSED:PER_FARM_LAYOUT")
    shutdown(sg2, host2)
end)

group("N-fillunit", function()
    local veh = newVehicle("vehicle:7", {
        { fillLevel = 120, capacity = 400, fillType = 1 },
        { fillLevel = 0, capacity = math.huge, fillType = FillType.UNKNOWN },
        { fillLevel = 300, capacity = 500, fillType = 3 },   -- the motor's diesel
    }, 3)
    local weird = newVehicle("vehicle:weird", { { fillLevel = 50, capacity = 100, fillType = FillType.UNKNOWN } })
    local m = newMission({ vehicles = { veh, weird } })
    local sg, host = boot(m)
    local u1, u2, u3 = NA.fillUnitBinding(veh, 1), NA.fillUnitBinding(veh, 2), NA.fillUnitBinding(veh, 3)
    T.eq("N41 [reached] one carrier per supported fill unit", tostring(carrierOf(sg, u1) ~= nil) .. "/" .. tostring(carrierOf(sg, u2) ~= nil), "true/true")
    T.eq("N42 a motorized consumer unit is not a carrier", carrierOf(sg, u3), nil)
    T.eq("N43 keyed by vehicle unique id and unit index, with the fill unit profile", u1.carrierKey.nativeOwnerKey .. "|" .. u1.carrierKey.componentKey .. "|" .. u1.profileId, "vehicle:7|fillUnit:1|NATIVE_FILL_UNIT_V1")
    T.eq("N44 the material is named through the fill type manager", stockOf(sg, u1).materialRef.fillTypeName .. "/" .. stockOf(sg, u1).observedAmount, "WHEAT/120")
    T.eq("N45 an empty unit is a carrier with no stock", tostring(carrierOf(sg, u2).stockId), "nil")
    T.eq("N46 an infinite capacity is reported as unknown, not refused", tostring(carrierOf(sg, u2).native.capacity), "nil")
    T.eq("N47 a nonempty unit with no named fill type is not bound (never an invented material)", carrierOf(sg, NA.fillUnitBinding(weird, 1)), nil)
    local spec = host.fillUnitLease.spec
    T.eq("N47b the adapter itself refuses to read it, before the core has to", select(2, spec.readNativeState(NA.fillUnitBinding(weird, 1), { vehicle = weird, fillUnitIndex = 1 })), "FILL_TYPE_UNNAMED")
    veh.configFileName = "data/vehicles/other.xml"
    T.eq("N48 a different vehicle model under the same id is a changed layout", select(2, spec.resolveCarrier(SGValues.copy(u1))), "LAYOUT_CHANGED")
    veh.configFileName = "data/vehicles/trailer.xml"
    T.ok("N49 twin: the same model resolves", spec.resolveCarrier(SGValues.copy(u1)) ~= nil)
    T.eq("N50 hasAccess(binding, actor) asks with the VEHICLE object", tostring(spec.hasAccess(SGValues.copy(u1), { farmId = 1, actorState = "RESOLVED" })) .. "/" .. tostring(m.accessCalls[#m.accessCalls].object == veh), "true/true")
    g_server = nil
    T.eq("N51 a client resolves, reads and enumerates nothing and is refused access", tostring(spec.resolveCarrier(SGValues.copy(u1))) .. "/" .. tostring(spec.readNativeState(SGValues.copy(u1), { vehicle = veh, fillUnitIndex = 1 })) .. "/" .. #spec.enumerateCarriers() .. "/" .. tostring(spec.hasAccess(SGValues.copy(u1), { farmId = 1, actorState = "RESOLVED" })), "nil/nil/0/false")
    g_server = {}
    shutdown(sg, host)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE NATIVE HOST
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    local StorageSystemClass = { addStorage = function(self, s) if s == nil then return false end self.storages[s] = s return true end }
    local PlaceableSystemClass = { removePlaceable = function(self, p) self.removed = (self.removed or 0) + 1 return "native-return" end }
    local VehicleSystemClass = { addVehicle = function(self, v) if v.refuse then return false end return true end, removeVehicle = function(self, v) return nil end }
    g_server = {}
    T.eq("H1 class hooks install", NH.installClassHooks({ Storage = StorageClass, StorageSystem = StorageSystemClass, PlaceableSystem = PlaceableSystemClass, VehicleSystem = VehicleSystemClass }), true)
    local addStorageWrapper = StorageSystemClass.addStorage
    NH.installClassHooks({ Storage = StorageClass, StorageSystem = StorageSystemClass, PlaceableSystem = PlaceableSystemClass, VehicleSystem = VehicleSystemClass })
    T.eq("H2 a second install does not stack a second wrapper", StorageSystemClass.addStorage, addStorageWrapper)

    local s0 = newStorage({ [1] = 60 })
    local silo = newSilo("placeable:h", { s0 }, false)
    local veh = newVehicle("vehicle:h", { { fillLevel = 100, capacity = 1000, fillType = 1 } })
    local m = newMission({ placeables = { silo }, vehicles = { veh } })
    local b0 = NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "shared" }, "WHEAT")
    local barleyB = NA.storageBinding(silo, { role = "silo", ordinal = 0, partition = "shared" }, "BARLEY")

    local sg, host = boot(m, function(sgBefore, hostBefore)
        s0:setFillLevel(80, 1)
        T.eq("H3 before the barrier a storage change is ignored", #hostBefore.dirtyOrder, 0)
    end)
    T.eq("H4 [reached] the barrier bound the silo with the level changed before it", stockOf(sg, b0).observedAmount, 80)
    T.ok("H5 the barrier installed the fill unit observer on existing vehicles", veh[SGFillUnitObserver.MARKER] ~= nil)

    -- Coalescing: an ordinary change waits for the flush interval.
    s0:setFillLevel(90, 1)
    T.eq("H6 an ordinary change is held, not reconciled per call", stockOf(sg, b0).observedAmount, 80)
    T.eq("H7 and is marked dirty once", #host.dirtyOrder, 1)
    s0:setFillLevel(95, 1)
    T.eq("H8 a second change to the same carrier is not a second entry", #host.dirtyOrder, 1)
    host:update(NH.FLUSH_INTERVAL_MS - 1)
    T.eq("H9 nothing flushes before the interval", stockOf(sg, b0).observedAmount, 80)
    host:update(1)
    T.eq("H10 the interval flushes and the core reads the level that landed", stockOf(sg, b0).observedAmount, 95)

    -- Boundaries flush at once.
    local stockId = stockOf(sg, b0).stockId
    s0:setFillLevel(0, 1)
    T.eq("H11 reaching zero flushes immediately and ends the generation", tostring(stockOf(sg, b0)) .. "/" .. tostring(sg.operations.retiredStocks[stockId] ~= nil), "nil/true")
    s0:setFillLevel(30, 2)
    T.eq("H12 a first fill of an UNBOUND slot binds it on demand at once", stockOf(sg, barleyB) and stockOf(sg, barleyB).observedAmount, 30)
    s0:setFillLevel(40, 1)
    local wheatStock = stockOf(sg, b0)
    s0:empty()
    T.eq("H13 Storage:empty flushes every held slot at once", tostring(stockOf(sg, b0)) .. "/" .. tostring(stockOf(sg, barleyB)), "nil/nil")
    T.ok("H13b [reached] the wheat slot had a stock before the empty", wheatStock ~= nil)

    -- An open operation owns its observations.
    s0:setFillLevel(50, 1)
    local stockBefore = stockOf(sg, b0) and stockOf(sg, b0).observedAmount
    local frame = SGOperationContext.open(host.context, b0, "TEST")
    s0:setFillLevel(70, 1)
    T.eq("H14 inside an open frame the observation is recorded on the frame", #frame.observations, 1)
    T.eq("H15 and nothing is marked or reconciled", tostring(#host.dirtyOrder) .. "/" .. tostring(stockOf(sg, b0).observedAmount), "0/" .. tostring(stockBefore))
    SGOperationContext.close(host.context, frame)
    s0:setFillLevel(75, 1)
    host:update(NH.FLUSH_INTERVAL_MS)
    T.eq("H16 twin: after the frame closes, observation resumes", stockOf(sg, b0).observedAmount, 75)

    -- A busy store keeps the entry for the next flush.
    s0:setFillLevel(76, 1)
    sg.operations.busy = true
    host:flush()
    T.eq("H17 a REENTRANT refusal keeps the carrier dirty", #host.dirtyOrder, 1)
    sg.operations.busy = false
    host:flush()
    T.eq("H18 and the next flush lands it", tostring(#host.dirtyOrder) .. "/" .. stockOf(sg, b0).observedAmount, "0/76")

    -- Fill units: ACCEPTED delta, boundaries, empty-all.
    local u1 = NA.fillUnitBinding(veh, 1)
    veh:addFillUnitFillLevel(1, 1, 50, 1)
    T.eq("H19 a fill unit change is coalesced", stockOf(sg, u1).observedAmount, 100)
    host:update(NH.FLUSH_INTERVAL_MS)
    T.eq("H20 and flushes to the level the engine accepted", stockOf(sg, u1).observedAmount, 150)
    veh:emptyAllFillUnits()
    T.eq("H21 emptyAllFillUnits flushes at once", tostring(stockOf(sg, u1)), "nil")

    -- Lifecycle: addVehicle's return is the engine's, and decides the bind.
    local vs = setmetatable({}, { __index = VehicleSystemClass })
    local newV = newVehicle("vehicle:new", { { fillLevel = 10, capacity = 100, fillType = 2 } })
    m._vehicles[#m._vehicles + 1] = newV
    T.eq("H22 addVehicle's true return is preserved through the hook", vs:addVehicle(newV), true)
    T.eq("H23 and a registered vehicle is bound and observed", tostring(stockOf(sg, NA.fillUnitBinding(newV, 1)) ~= nil) .. "/" .. tostring(newV[SGFillUnitObserver.MARKER] ~= nil), "true/true")
    local refused = newVehicle("vehicle:refused", { { fillLevel = 10, capacity = 100, fillType = 2 } })
    refused.refuse = true
    -- The refused vehicle is RESOLVABLE (in the vehicle list), so the only thing
    -- that can keep it unbound is the engine's false return. Mutation H9 survived
    -- the first version of this fixture, where resolution failed first.
    m._vehicles[#m._vehicles + 1] = refused
    T.ok("H24a [reached] the refused vehicle would resolve if asked", host.fillUnitLease.spec.resolveCarrier(NA.fillUnitBinding(refused, 1)) ~= nil)
    T.eq("H24 a false return is preserved", vs:addVehicle(refused), false)
    T.eq("H25 and a refused vehicle is not bound", carrierOf(sg, NA.fillUnitBinding(refused, 1)), nil)
    T.eq("H25b nor observed", refused[SGFillUnitObserver.MARKER], nil)
    vs:removeVehicle(newV)
    T.eq("H26 removeVehicle withdraws the vehicle's carriers", carrierOf(sg, NA.fillUnitBinding(newV, 1)), nil)

    -- Lifecycle: a new placeable's storage, then removal of the placeable.
    local sysS = setmetatable({ storages = {} }, { __index = StorageSystemClass })
    local sNew = newStorage({ [4] = 12 })
    local silo2 = newSilo("placeable:new", { sNew }, false)
    m._placeables[#m._placeables + 1] = silo2
    T.eq("H27 addStorage's return is preserved", sysS:addStorage(sNew), true)
    local grassB = NA.storageBinding(silo2, { role = "silo", ordinal = 0, partition = "shared" }, "GRASS")
    T.eq("H28 an added storage's held slots are bound", stockOf(sg, grassB) and stockOf(sg, grassB).observedAmount, 12)
    local ps = setmetatable({}, { __index = PlaceableSystemClass })
    T.eq("H29 removePlaceable's return is preserved", ps:removePlaceable(silo2), "native-return")
    T.eq("H30 and the placeable's carriers were withdrawn before it went", carrierOf(sg, grassB), nil)
    T.eq("H31 twin: the other silo's carrier is untouched", carrierOf(sg, b0) ~= nil, true)

    -- A storage no adapter supports is looked up once, not on every change.
    local orphan = newStorage({ [1] = 5 })
    local finds = 0
    local realFind = NA.findStorage
    NA.findStorage = function(...) finds = finds + 1 return realFind(...) end
    orphan:setFillLevel(6, 1)
    orphan:setFillLevel(7, 1)
    orphan:setFillLevel(8, 1)
    NA.findStorage = realFind
    T.eq("H31b an unsupported storage's miss is cached: one lookup for three changes", finds, 1)
    T.eq("H31c and it marks nothing", #host.dirtyOrder, 0)

    -- Teardown: the dispatchers reach no host.
    T.eq("H32a [reached] the host is the current dispatch target before teardown", NH.current, host)
    host:teardown()
    T.eq("H32b teardown clears the dispatch target", NH.current, nil)
    -- Re-arm the host's own gate so only the dispatcher can stop the report.
    -- Mutation H13 survived the first version, where ready=false stopped it first.
    host.ready = true
    s0:setFillLevel(11, 1)
    T.eq("H32 after teardown nothing is dispatched", #host.dirtyOrder, 0)
    host.ready = false
    shutdown(sg, nil)
    g_server = {}
    T.eq("H33 a client installs no class hooks", (function() g_server = nil local ok, why = NH.installClassHooks({}) g_server = {} return tostring(ok) .. "/" .. tostring(why) end)(), "false/CLIENT")
    local m3 = newMission()
    g_currentMission = m3
    local sg3 = StockGuard.attach(m3)
    g_server = nil
    local okClient, whyClient = NH.new(m3.stockGuard, {}):install()
    g_server = {}
    T.eq("H34 a client host registers no adapters", tostring(okClient) .. "/" .. tostring(whyClient) .. "/" .. sg3:status().adapters, "false/CLIENT/0")
    local okServer = NH.new(m3.stockGuard, {}):install()
    T.eq("H35 twin: the server host registers both", tostring(okServer) .. "/" .. sg3:status().adapters, "true/2")
    if NH.current ~= nil then NH.current:teardown() end
    shutdown(sg3, nil)
end)
