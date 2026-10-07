-- SG2-bale-2a-carrier_kind_spec_test.lua
--
-- The SG2 bale family, part 2a (Bob's intake BOB-INTAKE-SG2-BALE-FAMILY-2026-10-06, section 4, with
-- its 2026-10-06 addendum on the hall row): the world bale as a carrier of the one native adapter.
--   * the bale kind, keyed by the bale's own native uniqueId (Bale.lua:802-805), resolved through
--     ItemSystem:getItemByUniqueId (ItemSystem.lua:156-158), read as its fill type and level;
--   * every bale the item system holds is enumerated at the restore barrier, except a round Baler's
--     mounted bale (Part 3's alias, SG-2 :473), which is never a second carrier;
--   * Bale:delete is one REMOVE of a bound bale's token (SG-2 :400), on every route, then the carrier
--     is withdrawn; nothing at mission end;
--   * a hall round trip ends the stock, and the bale that comes back with the same uniqueId is
--     unbound for the session and a NEW stock, UNKNOWN with INITIAL_OBSERVATION, after the next
--     enumeration (:894's "never match"; OBJECT_RECREATED_UNBOUND is WITHHELD for the hall adapter);
--   * a world bale and a loader's bale keep their binding through a save and reload (same uniqueId);
--   * a Bale subclass (PackedBale.lua:4) is a bale: bound UNKNOWN, and its delete, which reaches
--     Bale's through superClass() (PackedBale.lua:14-17), one REMOVE;
--   * two map loads in one process.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv) on the SG2-4a world: the engine models, then
-- main.lua's modules and main.lua; the mission through main's appends; the savegame controller's own
-- save path, with the item system's save in the career chain (FSCareerMissionInfo.lua:350, through
-- the model's ENGINE_CAREER_HOOK, which stands in for code the chain reaches there).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's install (the class hook on the live Bale class, the
-- adapter's bale kind on the mission's item system) and the restore barrier's enumeration over real
-- model bales, made as the engine makes them: Bale.new, then loadFromConfigXML, which adds the bale to
-- the item system (Bale.lua:243-275). No binding, registry or catalogue is written by hand.
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local REAL = getmetatable(_G).__index
local NH, NA = SGNativeHost, SGNativeAdapters

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function engine(name, value) REAL[name] = value end
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── the engine's Class (shared/class.lua:1-35): class, superClass and isa ─────────
local function engineClass(members, baseClass)
    members = members or {}
    local mt = { __metatable = members, __index = members }
    if baseClass ~= nil then setmetatable(members, { __index = baseClass }) end
    function members:class() return members end
    function members:superClass() return baseClass end
    function members.isa(_, other)
        local cur = members
        while cur ~= nil do
            if cur == other then return true end
            cur = cur:superClass()
        end
        return false
    end
    return members, mt
end

-- ── fill types: the model's, with a bale's own (named as the engine names them) ───
local STRAW, SILAGE = 10, 11
do
    local base = g_fillTypeManager.getFillTypeNameByIndex
    local extra = { [STRAW] = "STRAW", [SILAGE] = "SILAGE" }
    g_fillTypeManager.getFillTypeNameByIndex = function(self, i) return extra[i] or base(self, i) end
end

-- ── THE ENGINE'S FLOAT WRITER (as ROW86's bench and MAINTENANCE 206's): an XMLValueType.FLOAT is
-- written as its float32 to six decimals, ties to even, and read back as a float32. A bale's fillLevel
-- is a FLOAT in items.xml (Bale.lua:17), so its saved level is the engine's rounding, not the live one.
local function f32(x) return (string.unpack("<f", string.pack("<f", x))) end
local function halfEvenInt(z)
    local r = math.floor(z)
    local f = z - r
    if f > 0.5 or (f == 0.5 and r % 2 == 1) then r = r + 1 end
    return r
end
local function writeFloat(x)
    local y = f32(x)
    local neg = y < 0
    if neg then y = -y end
    local s = string.format("%.0f", halfEvenInt(y * 1000000))
    while #s < 7 do s = "0" .. s end
    return (neg and "-" or "") .. s:sub(1, -7) .. "." .. s:sub(-6)
end
local function readFloat(text) return f32(tonumber(text)) end

-- ── objects/Bale.lua at 1.24, the parts the bale kind and its delete reach ────────
-- MountableObject is the base (Bale.lua:6, Class(Bale, MountableObject)); Bale.new registers the
-- class name (:34) and starts with needsSaving true (:37); loadFromConfigXML applies a given uniqueId
-- (:269-271), then adds the bale to the item system (:272); delete removes it from the item system
-- (:75) after stopping fermentation (:69-71, abbreviated); setFillLevel is a direct set with no event
-- (:564-569); saveToXMLFile writes the uniqueId (:417).
local MountableObject = engineClass({})
local BaleModel, Bale_mt = engineClass({}, MountableObject)
local NEXT_NODE = 70000
function BaleModel.new(isServer, isClient, customMt)
    NEXT_NODE = NEXT_NODE + 1
    local self = setmetatable({ isServer = isServer, isClient = isClient, nodeId = NEXT_NODE, fillType = STRAW, fillLevel = 0, needsSaving = true }, customMt or Bale_mt)
    REAL.registerObjectClassName(self, "Bale")
    return self
end
function BaleModel:loadFromConfigXML(filename, _x, _y, _z, _rx, _ry, _rz, uniqueId)
    self.xmlFilename = filename
    if uniqueId ~= nil then self:setUniqueId(uniqueId) end
    g_currentMission.itemSystem:addItem(self)
    return true
end
function BaleModel:getUniqueId() return self.uniqueId end
function BaleModel:setUniqueId(id) self.uniqueId = id end
function BaleModel:getFillType() return self.fillType end
function BaleModel:setFillType(ft) self.fillType = ft end
function BaleModel:getFillLevel() return self.fillLevel end
function BaleModel:setFillLevel(l) self.fillLevel = l end
function BaleModel:getNeedsSaving() return self.needsSaving end
function BaleModel:setNeedsSaving(v) self.needsSaving = v end
function BaleModel:getOwnerFarmId() return self.ownerFarmId or 1 end
function BaleModel:setOwnerFarmId(f) self.ownerFarmId = f end
function BaleModel:register() end
function BaleModel:mountKinematic() self.mounted = true end
function BaleModel:setCanBeSold(v) self.canBeSold = v end
function BaleModel:delete()
    if self.isDeleted then return end
    self.isDeleted = true
    local system = g_currentMission ~= nil and g_currentMission.itemSystem or nil
    if system ~= nil and system.itemsToSave[self] ~= nil then system:removeItem(self) end
end
function BaleModel:saveToXMLFile()
    return { uniqueId = self.uniqueId, filename = self.xmlFilename, fillType = self.fillType, fillLevel = writeFloat(self.fillLevel) }
end
engine("Bale", BaleModel)
--- objects/PackedBale.lua at 1.24: a Bale subclass (:4), made through Bale.new with its own class
--- (:6-8); its delete runs its own teardown, then Bale's through superClass() (:14-17, abbreviated).
local PackedBaleModel, PackedBale_mt = engineClass({}, BaleModel)
function PackedBaleModel.new(isServer, isClient)
    local self = BaleModel.new(isServer, isClient, PackedBale_mt)
    REAL.registerObjectClassName(self, "PackedBale")
    return self
end
function PackedBaleModel:delete()
    self.packedTornDown = true
    PackedBaleModel:superClass().delete(self)
end
--- Another kind of item in the item system (a pallet's object, say): not a Bale.
local OtherItem, Other_mt = engineClass({}, MountableObject)
function OtherItem.new() local self = setmetatable({}, Other_mt) REAL.registerObjectClassName(self, "Other") return self end
function OtherItem:getUniqueId() return self.uniqueId end
function OtherItem:setUniqueId(id) self.uniqueId = id end
function OtherItem:saveToXMLFile() return { uniqueId = self.uniqueId, other = true } end

-- ── misc/ItemSystem.lua at 1.24: getItemByUniqueId (:156-158), addItem (:194-221), removeItem
-- (:222-232) in effect; its save (:162-193) iterates sortedItemsToSave and keeps an item whose
-- getNeedsSaving is true (:170), and its load gives each saved bale its uniqueId back (Bale.lua:346,
-- applied :320). The XML I/O is abbreviated to a table on the model's disk.
local ItemSystemModel = {}
ItemSystemModel.__index = ItemSystemModel
local IDS = { n = 0 }
function ItemSystemModel.new(mission)
    return setmetatable({ mission = mission, itemsToSave = {}, itemByUniqueId = {}, sortedItemsToSave = {} }, ItemSystemModel)
end
function ItemSystemModel:getItemByUniqueId(uniqueId) return self.itemByUniqueId[uniqueId] end
function ItemSystemModel:addItem(item)
    if item.saveToXMLFile == nil or item.getUniqueId == nil or self.mission.objectsToClassName[item] == nil then return end
    if self.itemsToSave[item] ~= nil then return end
    self.itemsToSave[item] = { item = item, className = self.mission.objectsToClassName[item] }
    if item:getUniqueId() == nil or self.itemByUniqueId[item:getUniqueId()] == nil then
        if item:getUniqueId() == nil then
            IDS.n = IDS.n + 1
            item:setUniqueId("item" .. IDS.n)
        end
        self.itemByUniqueId[item:getUniqueId()] = item
        table.insert(self.sortedItemsToSave, self.itemsToSave[item])
    end
end
function ItemSystemModel:removeItem(item)
    local data = self.itemsToSave[item]
    if data == nil then return end
    for i, e in ipairs(self.sortedItemsToSave) do if e == data then table.remove(self.sortedItemsToSave, i) break end end
    self.itemsToSave[item] = nil
    self.itemByUniqueId[item:getUniqueId()] = nil
end
function ItemSystemModel:save(path)
    local out = {}
    for _, e in ipairs(self.sortedItemsToSave) do
        if e.item.getNeedsSaving == nil or e.item:getNeedsSaving() then out[#out + 1] = { className = e.className, data = e.item:saveToXMLFile() } end
    end
    ENGINE_DISK[path] = out
end
function ItemSystemModel:loadItems(path)
    for _, e in ipairs(ENGINE_DISK[path] or {}) do
        if e.className == "Bale" then
            local b = BaleModel.new(true, false)
            b:loadFromConfigXML(e.data.filename, 0, 0, 0, 0, 0, 0, e.data.uniqueId)
            b:setFillType(e.data.fillType)
            b:setFillLevel(readFloat(e.data.fillLevel))
        end
    end
end
--- BaseMission:delete empties the item system (BaseMission.lua:144-145): each item's own delete.
function ItemSystemModel:deleteAll()
    local list = {}
    for _, e in ipairs(self.sortedItemsToSave) do list[#list + 1] = e.item end
    for _, item in ipairs(list) do if item.delete ~= nil then item:delete() end end
end
engine("registerObjectClassName", function(object, className) g_currentMission.objectsToClassName[object] = className end)

--- A bale made as the engine makes one: Bale.new, then loadFromConfigXML (which adds it), type, level.
local function newBale(ft, litres, uniqueId)
    local b = BaleModel.new(true, false)
    b:loadFromConfigXML("data/objects/bales/roundbale" .. tostring(ft) .. ".xml", 0, 0, 0, 0, 0, 0, uniqueId)
    b:setFillType(ft)
    b:setFillLevel(litres)
    return b
end

-- ── the native routes that delete a bale (SG-2 :400), each as its engine file calls it ──────────
--- BaleUnloadTrigger:onBaleTriggerCallback's feed (triggers/BaleUnloadTrigger.lua:82): the bale's delete.
local function triggerFeed(bale) bale:delete() end
--- BaleMission's cleanup of a mission bale (missions/field/BaleMission.lua:154).
local function missionCleanup(bale) bale:delete() end
--- A player's delete (the bale's own delete, as the item system's console delete and a sale call it).
local function playerDelete(bale) bale:delete() end

-- ── a hall (placeables/specializations/PlaceableObjectStorage.lua at 1.24) ────────────────────
-- AbstractBaleObject keeps the bale's attributes and deletes the live bale (:908-910); taking it out
-- recreates it with the kept uniqueId (:947, :965).
local function hallStore(bale)
    local attributes = bale:saveToXMLFile()
    bale:delete()
    return attributes
end
local function hallUnload(attributes)
    local b = BaleModel.new(true, false)
    b:loadFromConfigXML(attributes.filename, 0, 0, 0, 0, 0, 0, attributes.uniqueId)
    b:setFillType(attributes.fillType)
    b:setFillLevel(readFloat(attributes.fillLevel))
    return b
end

-- ── a bale loader's own save (vehicles/specializations/BaleLoader.lua at 1.24) ──────────────
-- Its bales are saved with the loader through bale:saveToXMLFile, which writes the uniqueId (:706),
-- not by the item system, and recreated with that uniqueId at load (:725). Modeled as a vehicle whose
-- bales do not save through the item system, its own list written in the career chain.
local function newLoader(m, uid)
    local v = { uniqueId = uid, configFileName = "data/vehicles/baleLoader.xml", loaded = {} }
    v.getUniqueId = function(self) return self.uniqueId end
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function loaderTake(loader, bale)
    bale:setNeedsSaving(false)
    loader.loaded[#loader.loaded + 1] = bale
end
local function loaderSave(loader, dir)
    local out = {}
    for _, b in ipairs(loader.loaded) do if not b.isDeleted then out[#out + 1] = b:saveToXMLFile() end end
    ENGINE_DISK[dir .. "/loader_" .. loader.uniqueId .. ".xml"] = out
end
local function loaderLoad(loader, dir)
    for _, a in ipairs(ENGINE_DISK[dir .. "/loader_" .. loader.uniqueId .. ".xml"] or {}) do
        local b = BaleModel.new(true, false)
        b:loadFromConfigXML(a.filename, 0, 0, 0, 0, 0, 0, a.uniqueId)
        b:setFillType(a.fillType)
        b:setFillLevel(readFloat(a.fillLevel))
        loaderTake(loader, b)
    end
end

-- ── a round Baler's mounted bale (vehicles/specializations/Baler.lua:1478-1490, createBale's
-- round branch: Bale.new, loadFromConfigXML with no id, the type and level, register, mountKinematic;
-- appended to spec.bales). The rest of the Baler is not needed here.
local function newRoundBaler(m, uid)
    local v = { uniqueId = uid, configFileName = "data/vehicles/roundBaler.xml", spec_baler = { hasUnloadingAnimation = true, nonStopBaling = false, bales = {} } }
    v.getUniqueId = function(self) return self.uniqueId end
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function mountRoundBale(v, ft, litres)
    local b = BaleModel.new(true, false)
    b:loadFromConfigXML("data/objects/bales/roundbale.xml", 0, 0, 0, 0, 0, 0)
    b:setFillType(ft)
    b:setFillLevel(litres)
    b:register()
    b:mountKinematic()
    table.insert(v.spec_baler.bales, { baleObject = b, fillType = ft, fillLevel = litres })
    return b
end

--- A square Baler's bale (createBale's square branch, :1527-1539: Bale.new, loadFromConfigXML with no
--- id, register, setCanBeSold(false), setNeedsSaving(false)), kept in spec.bales until it drops. Its
--- chamber was cleared before (:1438), so it is a world bale, not a mirror.
local function newSquareBaler(m, uid)
    local v = { uniqueId = uid, configFileName = "data/vehicles/squareBaler.xml", spec_baler = { hasUnloadingAnimation = false, nonStopBaling = false, bales = {} } }
    v.getUniqueId = function(self) return self.uniqueId end
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function squareBale(v, ft, litres)
    local b = BaleModel.new(true, false)
    b:loadFromConfigXML("data/objects/bales/squarebale.xml", 0, 0, 0, 0, 0, 0)
    b:setFillType(ft)
    b:setFillLevel(litres)
    b:register()
    b:setCanBeSold(false)
    b:setNeedsSaving(false)
    table.insert(v.spec_baler.bales, { baleObject = b, fillType = ft, fillLevel = litres })
    return b
end

-- ── the world (the SG2-4a bench's), with the mission's item system ─────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir, opts)
    local m = setmetatable({ _server = true, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, time = 1000,
        terrainSize = 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {}, objectsToClassName = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = opts.index or 1, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    m.itemSystem = ItemSystemModel.new(m)
    return m
end

--- Boot through main.lua's load path: the world (and a save's items) built first, then the mission.
local function boot(build, saveDir, opts)
    opts = opts or {}
    ENGINE_PLANE.cells = {}
    local m = newMission(saveDir, opts)
    engine("g_server", {})
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local w = {}
    if opts.loadItems then m.itemSystem:loadItems(saveDir .. "/items.xml") end
    if build ~= nil then build(m, w) end
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    -- The barrier's own log (StockGuard.lua's enumerateAdapter names every enumerated carrier it
    -- could not bind), kept so a row can see an entry refused rather than never enumerated.
    local lines, orig = {}, REAL.print
    REAL.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(function() Mission00.loadMission00Finished(m) m:onFinishedLoading() end)
    REAL.print = orig
    if not ok then error(err, 0) end
    m._barrierLog = lines
    return m, sg, NH.current, w
end
--- The engine's own save through the controller, with the item system's save in the career chain
--- (FSCareerMissionInfo.lua:350) and any loader's own (`extra`).
local function nativeSave(m, finalDir, extra)
    ENGINE_SAVE.finalDir = finalDir
    REAL.ENGINE_CAREER_HOOK = function(mi)
        m.itemSystem:save(mi.savegameDirectory .. "/items.xml")
        if extra ~= nil then extra(mi.savegameDirectory) end
    end
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    ENGINE_RUN_FRAMES(nil)
    REAL.ENGINE_CAREER_HOOK = nil
end
--- The mission ends as the engine ends it: main.lua's FSBaseMission.delete prepend (the host torn
--- down), then BaseMission:delete empties the item system (BaseMission.lua:144-145).
local function endMission(m)
    FSBaseMission.delete(m)
    m.itemSystem:deleteAll()
end
local function resetEngine()
    REAL.ENGINE_PREPARE_LOG, REAL.ENGINE_DIRECT_LOG, REAL.ENGINE_PREPARED = {}, {}, {}
    ENGINE_SAVE.startError, ENGINE_SAVE.finishError, ENGINE_SAVE.finishSync, ENGINE_SAVE.errorAfterMove = nil, nil, false, false
    REAL.ENGINE_CAREER_HOOK = nil
    g_asyncTaskManager.tasks = {}
end
engine("g_savegameController", SavegameController.new())

-- ── readers ────────────────────────────────────────────────────────────────
local function refusedAtBarrier(m)
    for _, l in ipairs(m._barrierLog or {}) do if l:find("enumerated carriers not bound", 1, true) then return true end end
    return false
end
local function cid(bale) local b = NA.baleBinding(bale) return b and SGRecords.carrierKeyString(b.carrierKey) or nil end
local function stockOf(sg, bale) local c = sg.operations.carriers[cid(bale) or ""] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end
local function stockText(s)
    if s == nil then return "none" end
    return table.concat({ tostring(s.materialRef and s.materialRef.fillTypeName), num(s.observedAmount), tostring(s.knowledge), tostring(s.reason) }, "|")
end
--- The bale binding's key, field by field: adapter|nativeOwnerKey|componentKey.
local function keyText(bale)
    local b = NA.baleBinding(bale)
    local k = b and b.carrierKey or {}
    return tostring(k.adapterId) .. "|" .. tostring(k.nativeOwnerKey) .. "|" .. tostring(k.componentKey)
end
local function baleCarriers(sg)
    local n = 0
    for _, c in pairs(sg.operations.carriers) do if NA.isBaleKey(c.binding.carrierKey) then n = n + 1 end end
    return n
end
local function retiredFor(sg, id)
    local n = 0
    for _, s in pairs(sg.operations.retiredStocks or {}) do if s.carrierId == id then n = n + 1 end end
    return n
end
--- The last REMOVE the host settled: outcome, nativePath, retired litres and the leg's result/reason.
local function removeText(host)
    local ls = host and host.lastSettlement or nil
    if ls == nil then return "none" end
    local leg = ls.report and ls.report.allocations and ls.report.allocations[1] or nil
    return tostring(ls.outcome) .. "/" .. tostring(ls.report and ls.report.outcomeEvidence.nativePath) .. "/" .. num(leg and leg.sourceAmount)
        .. "/" .. tostring(leg and leg.result) .. ":" .. tostring(leg and leg.reason)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: THE BARRIER'S ENUMERATION OVER REAL MODEL BALES
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww)
        ww.straw = newBale(STRAW, 4000)
        ww.silage = newBale(SILAGE, 2500)
    end, "e_save", { index = 11 })
    local spec = sg.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, NA.NATIVE_ADAPTER_ID)
    local kinds = spec and spec.spec and spec.spec.carrierKinds or {}
    local hasBaleKind = false
    for _, k in ipairs(kinds) do if k == NA.KIND_BALE then hasBaleKind = true end end
    local budget = false
    for _, c in ipairs(sg.operations.retiredClasses or {}) do if c.name == "bale" and c.owns(NA.baleBinding(w.straw).carrierKey) then budget = true end end
    T.ok("E0 [reached] main.lua's install wrapped the live Bale class's delete (SGClassHook), registered the bale kind on the one native adapter, and gave a farm's retired bales their own history budget",
        SGClassHook.record(Bale, "delete", NH.HOOK_ID) ~= nil and hasBaleKind and budget)
    T.eq("E1 NAMED [entry point]: the barrier's enumeration bound every bale the item system holds, keyed by its own uniqueId, read as its type and level, UNKNOWN with INITIAL_OBSERVATION (no birth is known in 2a)",
        baleCarriers(sg) .. "|" .. stockText(stockOf(sg, w.straw)) .. "|" .. stockText(stockOf(sg, w.silage)) .. "|" .. keyText(w.straw),
        "2|STRAW|4000|UNKNOWN|INITIAL_OBSERVATION|SILAGE|2500|UNKNOWN|INITIAL_OBSERVATION|sgNative|" .. tostring(w.straw:getUniqueId()) .. "|bale")
    local kind = NA.baleKind(function() return m.itemSystem end, function() return m._vehicles end)
    local native, why = kind.resolveCarrier(NA.baleBinding(w.straw))
    local ns = native and kind.readNativeState(NA.baleBinding(w.straw), native) or nil
    T.eq("E2 a bound bale resolves to itself through getItemByUniqueId and reads as the engine holds it (storeKind bale, its native id)",
        tostring(native and native.bale == w.straw) .. "/" .. tostring(ns and ns.storeKind) .. "/" .. tostring(ns and ns.nativeUniqueId == w.straw:getUniqueId()) .. "/" .. tostring(why),
        "true/bale/true/nil")
    w.straw:setFillLevel(3000)
    sg.operations:refreshCarrier(host.nativeLease, NA.baleBinding(w.straw), "ADAPTER_OBSERVATION")
    T.eq("E3 an external setFillLevel (:284, a direct set with no event) is SG-1's reconcile at the next read, marked UNEXPLAINED_DELTA (MAINTENANCE row 238)", stockText(stockOf(sg, w.straw)), "STRAW|3000|UNKNOWN|UNEXPLAINED_DELTA")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. EVERY DELETE ROUTE IS ONE REMOVE (SG-2 :400)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww)
        ww.a = newBale(STRAW, 4000)
        ww.b = newBale(SILAGE, 2500)
        ww.c = newBale(STRAW, 1200)
    end, "r_save", { index = 12 })
    local out, ids = {}, {}
    for _, step in ipairs({ { "player", playerDelete, w.a }, { "trigger", triggerFeed, w.b }, { "mission", missionCleanup, w.c } }) do
        local id = cid(step[3])
        ids[#ids + 1] = id
        local stockBefore = stockOf(sg, step[3])
        step[2](step[3])
        out[#out + 1] = step[1] .. ":" .. removeText(host) .. "/" .. retiredFor(sg, id) .. "/" .. tostring(sg.operations.carriers[id] == nil) .. "/" .. tostring(stockBefore and stockBefore.retired)
    end
    T.eq("R1 NAMED: a player's delete, a bale trigger's feed and a mission bale's cleanup are each ONE REMOVE of the bound bale's token: its whole level retired (REMOVED, BALE_DELETED), its stock retired once, its carrier withdrawn",
        table.concat(out, " "),
        "player:COMMITTED/BALE_DELETE/4000/REMOVED:BALE_DELETED/1/true/true trigger:COMMITTED/BALE_DELETE/2500/REMOVED:BALE_DELETED/1/true/true mission:COMMITTED/BALE_DELETE/1200/REMOVED:BALE_DELETED/1/true/true")
    local classes = {}
    for _, id in ipairs(ids) do
        for _, s in pairs(sg.operations.retiredStocks or {}) do if s.carrierId == id then classes[#classes + 1] = tostring(s.retiredClass) end end
    end
    T.eq("R3 each deleted bale's retired stock counts against the bale budget, never the core one (as the mower buffer's, SG2-5c P14), so a farm's bale turnover cannot evict a silo's or a trailer's history",
        table.concat(classes, ","), "bale,bale,bale")
    host.lastSettlement = nil
    local late = newBale(STRAW, 800)
    playerDelete(late)
    T.eq("R2 a bale with no carrier (made after the barrier; 2b binds a baler's births) is none of ours: its delete makes no REMOVE", removeText(host) .. "/" .. baleCarriers(sg), "none/0")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. MISSION TEARDOWN MAKES NO REMOVE
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww) ww.a = newBale(STRAW, 4000) ww.b = newBale(SILAGE, 2500) end, "t_save", { index = 13 })
    local ida, idb = cid(w.a), cid(w.b)
    endMission(m)
    T.eq("T1 NAMED: the mission's end (the host torn down first, then the item system emptied, each bale's own delete) makes no REMOVE: no stock retired, no settlement, both bales deleted natively",
        removeText(host) .. "/" .. retiredFor(sg, ida) .. "/" .. retiredFor(sg, idb) .. "/" .. tostring(NH.current) .. "/" .. tostring(w.a.isDeleted and w.b.isDeleted),
        "none/0/0/nil/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. A ROUND BALER'S MOUNTED BALE IS NEVER A SECOND CARRIER (Part 3's alias, SG-2 :473)
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww)
        ww.baler = newRoundBaler(mm, "vehicle:roundBaler")
        ww.mounted = mountRoundBale(ww.baler, STRAW, 4000)
        ww.free = newBale(STRAW, 4000)
        ww.square = squareBale(newSquareBaler(mm, "vehicle:squareBaler"), STRAW, 3000)
    end, "k_save", { index = 14 })
    local kind = NA.baleKind(function() return m.itemSystem end, function() return m._vehicles end)
    local _, why = kind.resolveCarrier(NA.baleBinding(w.mounted))
    T.eq("K1 NAMED: the bale mounted in a round Baler (its spec.bales) is not enumerated (the barrier logs no carrier it could not bind) and does not resolve; the free bale and a square Baler's bale (a world bale, its chamber cleared) are carriers",
        baleCarriers(sg) .. "/" .. tostring(stockOf(sg, w.mounted)) .. "/" .. tostring(why) .. "/" .. tostring(stockOf(sg, w.free) ~= nil) .. "/" .. tostring(stockOf(sg, w.square) ~= nil) .. "/" .. tostring(refusedAtBarrier(m)),
        "2/nil/ROUND_BALER_MOUNTED/true/true/false")
    playerDelete(w.mounted)
    T.eq("K2 its delete makes no REMOVE", removeText(host), "none")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. ONLY A BALE
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww)
        ww.other = OtherItem.new()
        mm.itemSystem:addItem(ww.other)
        ww.bale = newBale(STRAW, 4000)
    end, "x_save", { index = 15 })
    local kind = NA.baleKind(function() return m.itemSystem end, function() return m._vehicles end)
    local forged = { carrierKey = { adapterId = NA.NATIVE_ADAPTER_ID, nativeOwnerKey = w.other:getUniqueId(), componentKey = NA.KIND_BALE }, sourceDescriptor = { kind = NA.KIND_BALE } }
    local _, why = kind.resolveCarrier(forged)
    T.eq("X1 another kind of item in the item system is neither enumerated nor resolved as a bale (Class isa, shared/class.lua:30)",
        baleCarriers(sg) .. "/" .. tostring(why) .. "/" .. tostring(NA.isBale(w.other)) .. "/" .. tostring(NA.isBale(w.bale)), "1/NOT_A_BALE/false/true")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. A BALE SUBCLASS IS A BALE (PackedBale.lua:4; InlineBaleSingle.lua:2 likewise)
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww)
        ww.packed = PackedBaleModel.new(true, false)
        ww.packed:loadFromConfigXML("data/objects/bales/packedSquareBale120.xml", 0, 0, 0, 0, 0, 0)
        ww.packed:setFillType(STRAW)
        ww.packed:setFillLevel(1500)
    end, "p_save", { index = 21 })
    local id = cid(w.packed)
    local bound = stockText(stockOf(sg, w.packed))
    playerDelete(w.packed)
    T.eq("P1 NAMED: a packed bale (a Bale subclass) is a carrier like any bale, UNKNOWN (no homogeneity claimed; :669's portioned form is not carried), and its delete, its own teardown and then Bale's through superClass(), is ONE REMOVE of its token",
        bound .. "/" .. removeText(host) .. "/" .. retiredFor(sg, id) .. "/" .. tostring(sg.operations.carriers[id] == nil) .. "/" .. tostring(w.packed.packedTornDown),
        "STRAW|1500|UNKNOWN|INITIAL_OBSERVATION/COMMITTED/BALE_DELETE/1500/REMOVED:BALE_DELETED/1/true/true")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. A WORLD BALE THROUGH A SAVE AND A FRESH MISSION KEEPS ITS BINDING
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww) ww.a = newBale(STRAW, 4000.37) end, "s_save", { index = 16 })
    local id, before = w.a:getUniqueId(), stockOf(sg, w.a)
    nativeSave(m, "s_final")
    endMission(m)
    local m2, sg2 = boot(nil, "s_final", { index = 16, loadItems = true })
    local b2 = m2.itemSystem:getItemByUniqueId(id)
    local after = b2 and stockOf(sg2, b2) or nil
    local saved = nil
    for _, e in ipairs(ENGINE_DISK["s_final/items.xml"] or {}) do if e.data.uniqueId == id then saved = e.data.fillLevel end end
    T.eq("S1 NAMED: the item system saved the bale with its uniqueId and its level as the engine's float (4000.37 written 4000.370117), the fresh mission brought it back as a float32, and its stock REATTACHES (the same stock id) through the bale kind's float image",
        tostring(saved) .. "/" .. tostring(b2 ~= nil and b2 ~= w.a) .. "/" .. tostring(after ~= nil and before ~= nil and after.stockId == before.stockId) .. "/" .. stockText(after),
        "4000.370117/true/true/STRAW|4000.3701|UNKNOWN|INITIAL_OBSERVATION")
    endMission(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. A BALE LOADER'S BALE THROUGH A SAVE AND A FRESH MISSION KEEPS ITS BINDING
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww)
        ww.loader = newLoader(mm, "vehicle:baleLoader")
        ww.a = newBale(SILAGE, 2500)
        loaderTake(ww.loader, ww.a)
    end, "l_save", { index = 17 })
    local id, before = w.a:getUniqueId(), stockOf(sg, w.a)
    nativeSave(m, "l_final", function(dir) loaderSave(w.loader, dir) end)
    local inItems = false
    for _, e in ipairs(ENGINE_DISK["l_final/items.xml"] or {}) do if e.data.uniqueId == id then inItems = true end end
    endMission(m)
    local m2, sg2 = boot(function(mm, ww) ww.loader = newLoader(mm, "vehicle:baleLoader") loaderLoad(ww.loader, "l_final") end, "l_final", { index = 17, loadItems = true })
    local b2 = m2.itemSystem:getItemByUniqueId(id)
    local after = b2 and stockOf(sg2, b2) or nil
    T.eq("L1 NAMED: a loader's bale is saved by the loader with its uniqueId (not by the item system), recreated with it at load (BaleLoader.lua:706, :725), and its stock REATTACHES",
        tostring(inItems) .. "/" .. tostring(b2 ~= nil) .. "/" .. tostring(after ~= nil and before ~= nil and after.stockId == before.stockId) .. "/" .. stockText(after),
        "false/true/true/SILAGE|2500|UNKNOWN|INITIAL_OBSERVATION")
    endMission(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. A HALL ROUND TRIP: THE STOCK ENDS; THE BALE BACK IS NEW CONTENTS, NEVER THE OLD RECORD
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww) ww.a = newBale(STRAW, 4000) end, "h_save", { index = 18 })
    local id, old = w.a:getUniqueId(), stockOf(sg, w.a)
    local attributes = hallStore(w.a)
    local stored = removeText(host)
    local back = hallUnload(attributes)
    T.eq("H1 NAMED: storing the bale (AbstractBaleObject deletes it, PlaceableObjectStorage.lua:908-910) is one REMOVE; the bale back with the SAME uniqueId (:965) is unbound for the rest of the session",
        stored .. "|" .. tostring(back:getUniqueId() == id) .. "/" .. tostring(stockOf(sg, back)) .. "/" .. baleCarriers(sg),
        "COMMITTED/BALE_DELETE/4000/REMOVED:BALE_DELETED|true/nil/0")
    nativeSave(m, "h_final")
    endMission(m)
    local m2, sg2 = boot(nil, "h_final", { index = 18, loadItems = true })
    local b2 = m2.itemSystem:getItemByUniqueId(id)
    local now = b2 and stockOf(sg2, b2) or nil
    T.eq("H2 NAMED: after the next enumeration it is a NEW stock and generation, UNKNOWN with INITIAL_OBSERVATION; the retired record does not reattach (SG-2 :400, :894)",
        tostring(now ~= nil and old ~= nil and now.stockId ~= old.stockId) .. "/" .. tostring(now and now.contentsGeneration) .. "/" .. stockText(now),
        "true/1/STRAW|4000|UNKNOWN|INITIAL_OBSERVATION")
    endMission(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. TWO MAP LOADS IN ONE PROCESS
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    resetEngine()
    local m, sg, host, w = boot(function(mm, ww) ww.a = newBale(STRAW, 4000) end, "m_save1", { index = 19 })
    endMission(m)
    local m2, sg2, host2, w2 = boot(function(mm, ww) ww.a = newBale(SILAGE, 2500) end, "m_save2", { index = 20 })
    local settles = 0
    local real = host2.handle.settleOperation
    host2.handle.settleOperation = function(...) settles = settles + 1 return real(...) end
    local id = cid(w2.a)
    playerDelete(w2.a)
    host2.handle.settleOperation = real
    T.eq("M1 NAMED: on the second map load the Bale class's one wrapper dispatches to the new host: one REMOVE for one delete, not two",
        settles .. "/" .. removeText(host2) .. "/" .. retiredFor(sg2, id), "1/COMMITTED/BALE_DELETE/2500/REMOVED:BALE_DELETED/1")
    endMission(m2)
end)
