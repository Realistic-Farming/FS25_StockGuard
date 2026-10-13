-- SG2-5g-straw_blower_spec_test.lua
--
-- SG2-5 slice 5g (Bob's intake, Desk Office/Drafts/BOB-INTAKE-SG2-5G-STRAW-BLOWER-2026-10-09.md, and his
-- R-15 of the same day; SG-2 v2.3 :154, NATIVE_STRAW_BLOWER_V1): a straw blower's loaded bale and its fill
-- unit are one material quantity.
--   * the load notes a mirror: the unit's plain carrier (empty) withdrawn, the unit named by its alias of
--     the bale, nothing born;
--   * a discharge into a barn is ONE TRANSFER from the bale, native's setFillLevel its after-state;
--   * the last discharge deletes the bale inside the transfer: no separate REMOVE, the residue up to native's
--     0.01 L threshold a STRAW_BLOWER_TRIM loss, the carrier withdrawn and the mirror retired after the settle;
--   * a leave, another route's delete, an unbound bale, a removed blower, a save and a reload.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv) on the SG2 bale family 2a bench's world VERBATIM (the
-- engine's Bale and ItemSystem, the bales enumerated at the barrier, the engine's own save), with the
-- SG2-5d-b bench's FillUnit add VERBATIM in effect, the engine's StrawBlower (1.24, VERBATIM through its
-- server path), and a cow barn: a husbandry storage with its unloading station (the SG2-2 models).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's install wraps the live StrawBlower class's onUpdateTick and the
-- host the blower's instance trigger callback, delete listener, discharge and fill unit; the barrier binds the
-- bale, the blower's empty unit and the barn's storage; the engine's own trigger callback, onUpdateTick and
-- Dischargeable:dischargeToObject into the barn's unload trigger run the load and the blow. No mirror,
-- carrier, binding or stock is written by hand.
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGStrawBlower.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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

-- ── FillUnit:addFillUnitFillLevel (vehicles/specializations/FillUnit.lua:1103-1203) ──
-- The quantity path VERBATIM in effect: an unsupported type returns 0 before any event (:1121-1123);
-- the trailer mass limit reduces the request before the clamp (:1124-1130, `unit.massLimit`); the
-- same type clamps to [0, capacity] (:1135-1137); another type with a positive request first empties
-- the unit through self:addFillUnitFillLevel (:1142-1146) and then fills it (:1147-1150); the event is
-- raised with the reduced request and the applied delta, level after minus level before (:1167,
-- :1203, ENGINE_RAISE, by name at raise time), and the applied delta is returned (:1275). Access,
-- presentation and sync are abbreviated.
local function fillUnitAdd(self, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
    local unit = self.spec_fillUnit.fillUnits[fillUnitIndex]
    if unit == nil then return 0 end
    if fillTypeIndex ~= unit.fillType and not (unit.supportedFillTypes or {})[fillTypeIndex] then return 0 end
    if unit.refuse then return 0 end
    if fillLevelDelta > 0 and unit.massLimit ~= nil then fillLevelDelta = math.min(fillLevelDelta, unit.massLimit) end
    local oldLevel = unit.fillLevel
    local capacity = unit.capacity == 0 and math.huge or unit.capacity
    if unit.fillType == fillTypeIndex then
        unit.fillLevel = math.max(0, math.min(capacity, oldLevel + fillLevelDelta))
    elseif fillLevelDelta > 0 then
        if oldLevel > 0 then self:addFillUnitFillLevel(farmId, fillUnitIndex, -math.huge, unit.fillType, toolType, fillPositionData) end
        unit.fillLevel = math.max(0, math.min(capacity, fillLevelDelta))
        unit.fillType = fillTypeIndex
    end
    if unit.fillLevel < 0.00001 then unit.fillLevel = 0 end
    if unit.fillLevel > 0 then unit.lastValidFillType = unit.fillType else unit.fillType = FillType.UNKNOWN end
    local appliedDelta = unit.fillLevel - oldLevel
    ENGINE_RAISE(self, "onFillUnitFillLevelChanged", fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta)
    return appliedDelta
end

-- ══════════════════════════════════════════════════════════════════════════
-- SG2-5g: the StrawBlower, a barn, and the world bales it blows
-- ══════════════════════════════════════════════════════════════════════════
ToolType.BALE = ToolType.BALE or 9
-- SpecializationUtil.raiseEvent (specializations/SpecializationUtil.lua:18-25) VERBATIM in effect, as the SG2-4b
-- ground model's ENGINE_RAISE (not loaded in this world): every listener's function fetched BY NAME at raise time.
REAL.ENGINE_RAISE = REAL.ENGINE_RAISE or function(object, eventName, ...)
    for _, spec in ipairs(object.eventListeners[eventName] or {}) do spec[eventName](object, ...) end
end
ToolType.UNDEFINED = ToolType.UNDEFINED or 0
FillType.STRAW = STRAW
-- The 2a world names STRAW and SILAGE by index only; a storage's binding resolves its type by name
-- (FillTypeManager:getFillTypeIndexByName), so the model answers that direction too.
do
    local base = g_fillTypeManager.getFillTypeIndexByName
    local extra = { STRAW = STRAW, SILAGE = SILAGE }
    g_fillTypeManager.getFillTypeIndexByName = function(self, name) return extra[name] or (base ~= nil and base(self, name) or nil) end
end

-- ── the engine's StrawBlower (vehicles/specializations/StrawBlower.lua at 1.24, 196 lines) ───────
-- :32-61 VERBATIM through the server's fields (the deprecated-element checks, the trigger's addTrigger
-- and the client's sounds and animations out; the bench calls the trigger callback by name, as the
-- engine's trigger does), :82-93 VERBATIM, :94-99 VERBATIM (the addFillUnitFillLevel override, its
-- superFunc FillUnit's add), :100-135 VERBATIM with the decompile's missing `local spec` restored (the
-- callback reads spec at :105), :136-145 VERBATIM, :152-180 VERBATIM. Events are raised by name at raise
-- time (ENGINE_RAISE); the trigger callback and the delete listener are registered functions called by
-- name on the instance, as addTrigger (:41) and addDeleteListener (:108) call them.
local function newStrawBlowerClass()
    local S = {}
    function S:onLoad(savegame)
        local spec = self.spec_strawBlower
        spec.triggeredBales = {}
        spec.fillUnitIndex = self.xmlFile:getValue("vehicle.strawBlower#fillUnitIndex", 1)
        local fillUnit = self:getFillUnitByIndex(spec.fillUnitIndex)
        fillUnit.synchronizeFullFillLevel = true
        fillUnit.needsSaving = false
        if savegame ~= nil and not savegame.resetVehicles then
            self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, FillType.UNKNOWN, ToolType.UNDEFINED)
        end
    end
    function S:onUpdateTick(_, _, _, _)
        local spec = self.spec_strawBlower
        if spec.currentBale == nil and self:getFillUnitSupportsToolType(spec.fillUnitIndex, ToolType.BALE) then
            local bale = next(spec.triggeredBales)
            if bale ~= nil then
                self:setFillUnitCapacity(spec.fillUnitIndex, bale:getFillLevel())
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, FillType.UNKNOWN, ToolType.UNDEFINED)
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, bale:getFillLevel(), bale:getFillType(), ToolType.BALE)
                spec.currentBale = bale
            end
        end
    end
    function S:addFillUnitFillLevel(superFunc, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
        if fillUnitIndex == self.spec_strawBlower.fillUnitIndex then
            self:setFillUnitCapacity(fillUnitIndex, (math.max(self:getFillUnitCapacity(fillUnitIndex), self:getFillUnitFillLevel(fillUnitIndex) + fillLevelDelta)))
        end
        return superFunc(self, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
    end
    function S:strawBlowerBaleTriggerCallback(_, otherActorId, onEnter, onLeave, _, _)
        local spec = self.spec_strawBlower
        if onEnter then
            if otherActorId ~= 0 then
                local object = g_currentMission:getNodeObject(otherActorId)
                if object ~= nil and (object:isa(Bale) and (g_currentMission.accessHandler:canFarmAccess(self:getActiveFarm(), object) and (object:getAllowPickup() and self:getFillUnitSupportsFillType(self.spec_strawBlower.fillUnitIndex, object:getFillType())))) then
                    spec.triggeredBales[object] = Utils.getNoNil(spec.triggeredBales[object], 0) + 1
                    object.allowPickup = false
                    if spec.triggeredBales[object] == 1 and object.addDeleteListener ~= nil then
                        object:addDeleteListener(self, "onDeleteStrawBlowerObject")
                        return
                    end
                end
            end
        elseif onLeave and otherActorId ~= 0 then
            local object = g_currentMission:getNodeObject(otherActorId)
            if object ~= nil then
                local triggerCount = spec.triggeredBales[object]
                if triggerCount ~= nil then
                    if triggerCount == 1 then
                        spec.triggeredBales[object] = nil
                        object.allowPickup = true
                        if object == spec.currentBale then
                            spec.currentBale = nil
                            self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, self:getFillUnitFillType(spec.fillUnitIndex), ToolType.UNDEFINED)
                        end
                        if object.removeDeleteListener ~= nil then
                            object:removeDeleteListener(self, "onDeleteStrawBlowerObject")
                            return
                        end
                    else
                        spec.triggeredBales[object] = triggerCount - 1
                    end
                end
            end
        end
    end
    function S:onDeleteStrawBlowerObject(object)
        local spec = self.spec_strawBlower
        if spec.triggeredBales[object] ~= nil then
            spec.triggeredBales[object] = nil
            if object == spec.currentBale then
                spec.currentBale = nil
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, self:getFillUnitFillType(spec.fillUnitIndex), ToolType.UNDEFINED)
            end
        end
    end
    function S:onFillUnitFillLevelChanged(fillUnitIndex, _, fillTypeIndex, _, _, _)
        local spec = self.spec_strawBlower
        if fillUnitIndex == spec.fillUnitIndex then
            local newFillLevel = self:getFillUnitFillLevel(spec.fillUnitIndex)
            if self.isServer then
                local bale = spec.currentBale
                if bale ~= nil then
                    if newFillLevel <= 0.01 then
                        if self.removeDynamicMountedObject ~= nil then
                            self:removeDynamicMountedObject(bale)
                        end
                        local baleOwner = bale:getOwnerFarmId()
                        bale:delete()
                        spec.currentBale = nil
                        spec.triggeredBales[bale] = nil
                        self:setFillUnitCapacity(spec.fillUnitIndex, 1)
                        self:addFillUnitFillLevel(baleOwner, spec.fillUnitIndex, -math.huge, FillType.UNKNOWN, ToolType.UNDEFINED)
                        return
                    end
                    if newFillLevel < bale:getFillLevel() and fillTypeIndex == bale:getFillType() then
                        bale:setFillLevel(newFillLevel)
                        return
                    end
                end
            elseif newFillLevel <= 0 then
                self:setFillUnitCapacity(spec.fillUnitIndex, 1)
            end
        end
    end
    local fresh = {}
    for k, f in pairs(S) do
        if type(f) == "function" then local inner = f fresh[k] = function(...) return inner(...) end else fresh[k] = f end
    end
    return fresh
end
engine("StrawBlower", newStrawBlowerClass())

-- ── a bale's delete listeners (objects/Object.lua, the parts Bale inherits) ───────────────────
-- addDeleteListener(target, functionName) keeps (target, name); delete calls target[name](target, self) by
-- name at delete time, inside the delete, before the bale leaves the item system.
BaleModel.addDeleteListener = function(self, target, name)
    self.deleteListeners = self.deleteListeners or {}
    self.deleteListeners[#self.deleteListeners + 1] = { target = target, name = name }
end
BaleModel.removeDeleteListener = function(self, target, name)
    for i = #(self.deleteListeners or {}), 1, -1 do
        local l = self.deleteListeners[i]
        if l.target == target and l.name == name then table.remove(self.deleteListeners, i) end
    end
end
BaleModel.getAllowPickup = function(self) return self.allowPickup ~= false end
do
    local plainDelete = BaleModel.delete
    BaleModel.delete = function(self)
        if self.isDeleted then return end
        for _, l in ipairs(self.deleteListeners or {}) do l.target[l.name](l.target, self) end
        return plainDelete(self)
    end
end

-- ── a straw blower as the engine builds it ────────────────────────────────────────────────
-- vehicleTypes.xml's strawBlower: a trailer (FillUnit, Dischargeable) with StrawBlower. Its registered
-- functions COPIED into the instance (Vehicle.lua:486): the trigger callback and the delete listener;
-- FillUnit's add with StrawBlower's override over it (registerOverwrittenFunction, :23), as fillUnitAdd;
-- Dischargeable's dischargeToObject and getDischargeFillType. One fill unit taking STRAW by ToolType.BALE.
local function newBlower(m, uid, opts)
    opts = opts or {}
    local unit = { fillLevel = 0, capacity = 1, fillType = FillType.UNKNOWN, lastValidFillType = FillType.UNKNOWN,
                   supportedFillTypes = { [STRAW] = true }, supportedToolTypes = { [ToolType.BALE] = true } }
    local v = { uniqueId = uid, configFileName = "data/vehicles/strawBlower.xml", ownerFarmId = 1, activeFarm = 1, isServer = true, isClient = false,
                spec_fillUnit = { fillUnits = { unit }, fillTypeChangeThreshold = 0.05 }, spec_fillVolume = { unloadInfos = { {} } }, spec_dischargeable = {},
                spec_strawBlower = {} }
    v.isa = function(self, class) return class == Vehicle end
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getFillUnitByIndex = function(self, i) return self.spec_fillUnit.fillUnits[i] end
    v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
    v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
    v.getFillUnitCapacity = function(self, i) return self.spec_fillUnit.fillUnits[i].capacity end
    v.setFillUnitCapacity = function(self, i, c) self.spec_fillUnit.fillUnits[i].capacity = c end
    v.getFillUnitFreeCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u.capacity - u.fillLevel end
    v.getFillUnitSupportsFillType = function(self, i, ft) local u = self.spec_fillUnit.fillUnits[i] return u ~= nil and u.supportedFillTypes[ft] == true end
    v.getFillUnitSupportsToolType = function(self, i, tt) local u = self.spec_fillUnit.fillUnits[i] return u ~= nil and u.supportedToolTypes[tt] == true end
    v.addFillUnitFillLevel = function(self, ...) return StrawBlower.addFillUnitFillLevel(self, fillUnitAdd, ...) end
    v.getFillVolumeUnloadInfo = function(self, index) return self.spec_fillVolume.unloadInfos[index] end
    v.dischargeToObject = Dischargeable.dischargeToObject
    v.getDischargeFillType = Dischargeable.getDischargeFillType
    v.strawBlowerBaleTriggerCallback = StrawBlower.strawBlowerBaleTriggerCallback
    v.onDeleteStrawBlowerObject = StrawBlower.onDeleteStrawBlowerObject
    v.node = { fillUnitIndex = 1, toolType = ToolType.DISCHARGEABLE, info = {}, unloadInfoIndex = 1 }
    v.xmlFile = { getValue = function(_, _, d) return d end }
    v.specClasses = { StrawBlower }
    v.specializations = { ENGINE_FILLUNIT, StrawBlower }
    v.specializationNames = { "fillUnit", "strawBlower" }
    v.eventListeners = { onLoad = { StrawBlower }, onPostLoad = {}, onUpdateTick = { StrawBlower }, onFillUnitFillLevelChanged = { StrawBlower } }
    m._vehicles[#m._vehicles + 1] = v
    return v
end
--- The bale trigger (StrawBlower.lua:41): the engine calls the instance's callback by name with the
--- actor's node, entering or leaving.
local function triggerBale(v, bale, onEnter) return v:strawBlowerBaleTriggerCallback(nil, bale.nodeId, onEnter, not onEnter, false, nil) end
--- One server update of the blower: its onUpdateTick, raised by name at raise time.
local function updateBlower(v) ENGINE_RAISE(v, "onUpdateTick", 16, false, false, false) end
--- One frame of a discharge into a station, through its unload trigger (Dischargeable :807-816).
local function blow(v, station, litres) return v:dischargeToObject(v.node, litres, UnloadTrigger.newModel(station), 1) end

-- ── the world for the blower: a barn (a husbandry with its unloading station) and the mission's nodes ──
Utils.getNoNil = Utils.getNoNil or function(value, default) if value == nil then return default end return value end
--- BaseMission:getNodeObject: the object a trigger's actor node belongs to (here a bale by its node).
function Mission:getNodeObject(nodeId)
    for item in pairs(self.itemSystem.itemsToSave) do if item.nodeId == nodeId then return item end end
    return nil
end
--- A cow barn: PlaceableHusbandryStraw's storage (inputFillType STRAW, PlaceableHusbandryStraw.lua:42)
--- under the husbandry storage role, and its unloading station bound to it (:138-141).
local function newBarn(m, uid)
    local storage = Storage.newModel({ [STRAW] = 0 }, 100000, 1)
    local p = { uniqueId = uid, getUniqueId = function(self) return self.uniqueId end, getOwnerFarmId = function() return 1 end,
                spec_husbandry = { storage = storage } }
    m._placeables[#m._placeables + 1] = p
    m.storageSystem:addStorage(storage)
    local station = UnloadingStation.newModel()
    station:addTargetStorage(storage)
    m.storageSystem:addUnloadingStation(station, p)
    return { placeable = p, storage = storage, station = station }
end
--- The vehicle's load (Vehicle.lua:866): onLoad through its class table, with the savegame.
local function loadBlower(v, savegame)
    for _, spec in ipairs(v.eventListeners.onLoad) do spec.onLoad(v, savegame) end
end
--- A world: a barn, a blower, and straw bales (bales = { litres... }), all built before the barrier.
local function blowerWorld(o)
    return function(m, w)
        w.barn = newBarn(m, "placeable:barn")
        w.blower = newBlower(m, "vehicle:blower")
        if o.unitLevel ~= nil then
            local u = w.blower.spec_fillUnit.fillUnits[1]
            u.fillLevel, u.capacity, u.fillType = o.unitLevel, o.unitLevel, STRAW
        end
        loadBlower(w.blower, o.savegame)
        w.bales = {}
        for i, litres in ipairs(o.bales or { 1000 }) do w.bales[i] = newBale(STRAW, litres) end
    end
end
local function boot5g(o, dir, index)
    resetEngine()
    local m, sg, host, w = boot(blowerWorld(o), dir, { index = index, loadItems = o.loadItems })
    return m, sg, host, w
end

-- ── readers ──────────────────────────────────────────────────────────────────
local SB = SGStrawBlower
local function unitKey(v) return SGRecords.carrierKeyString(NA.fillUnitBinding(v, 1).carrierKey) end
local function barnId(w)
    local slot = NA.storageSlotsOfPlaceable(w.barn.placeable)[1]
    local b = NA.storageBinding(w.barn.placeable, slot, "STRAW")
    return b and SGRecords.carrierKeyString(b.carrierKey) or nil
end
local function barnText(sg, w)
    local c = sg.operations.carriers[barnId(w) or ""]
    local s = c and c.stockId and sg.operations.stocks[c.stockId] or nil
    return stockText(s)
end
local function mirrorCount() local n = 0 for _ in pairs(NA.strawBlowerMirrors) do n = n + 1 end return n end
--- The live straw stocks outside the barn's storage (the bale's, and any the blower's unit holds).
local function stocksOfStraw(sg, w)
    local n, barn = 0, barnId(w)
    for _, s in pairs(sg.operations.stocks) do
        if s.materialRef ~= nil and s.materialRef.fillTypeName == "STRAW" and s.observedAmount > 0 and s.carrierId ~= barn then n = n + 1 end
    end
    return n
end
local function legsText(ls)
    local out = {}
    for _, a in ipairs(ls and ls.report and ls.report.allocations or {}) do
        out[#out + 1] = tostring(a.result) .. ":" .. num(a.sourceAmount) .. (a.reason ~= nil and (":" .. a.reason) or "")
    end
    return table.concat(out, ",")
end
local function retired(reason) return SB.stats.retired[reason] or 0 end
--- Whether the unit's binding is an alias that resolves to this bale (false, never a raise, when it is not).
local function aliasNames(v, bale)
    local ok, own = pcall(NA.resolveAlias, NA.fillUnitBindingFor(v, 1))
    return ok and own ~= nil and SGRecords.carrierKeyString(own.carrierKey) == cid(bale)
end
local function loadAndMirror(v, bale)
    triggerBale(v, bale, true)
    updateBlower(v)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A STRAW BALE INTO THE BLOWER AND BLOWN INTO A BARN
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_e", 301)
    local v, bale = w.blower, w.bales[1]
    -- The barn's empty storage is not enumerated (only slots holding material are); the first transfer binds it.
    T.ok("E0 [reached] main.lua's install wrapped the live StrawBlower's onUpdateTick (SGClassHook), the blower's trigger callback and delete listener (instance copies), its discharge and its fill unit; the barrier bound the bale and the blower's empty unit, and the host bound the barn's station UNLOAD",
        SGClassHook.record(StrawBlower, "onUpdateTick", SB.HOOK_ID) ~= nil and rawget(v, SB.MARKER) ~= nil and stockOf(sg, bale) ~= nil
            and sg.operations.carriers[unitKey(v)] ~= nil and host.stations[w.barn.station] ~= nil and host.stations[w.barn.station].UNLOAD == true)
    local before = stockOf(sg, bale)
    loadAndMirror(v, bale)
    T.eq("L1 NAMED [entry point]: the load births nothing: the bale's stock is the same one, the blower's unit is no carrier, the mirror stands, and resolveAlias names the bale",
        tostring(stockOf(sg, bale) == before) .. " " .. stockText(stockOf(sg, bale)) .. " " .. tostring(sg.operations.carriers[unitKey(v)] == nil) .. " " .. mirrorCount()
            .. " " .. tostring(aliasNames(v, bale)) .. " " .. num(v:getFillUnitFillLevel(1)),
        "true " .. stockText(before) .. " true 1 true 1000")
    T.eq("P1 NAMED (Bob's bar): after the mirrored load the store holds exactly one straw stock, the bale's, and nothing under the unit's key",
        stocksOfStraw(sg, w) .. "/" .. tostring(sg.operations.carriers[unitKey(v)] == nil), "1/true")
    blow(v, w.barn.station, 400)
    local ls = host.lastSettlement
    T.eq("D1 NAMED: one discharge is ONE TRANSFER from the bale to the barn's storage of the accepted 400 L; the bale's record falls by exactly that, with no unexplained change",
        tostring(ls and ls.report and ls.report.outcomeEvidence.nativePath) .. "/" .. tostring(ls and ls.outcome) .. " " .. legsText(ls) .. " | " .. stockText(stockOf(sg, bale)) .. " | " .. barnText(sg, w)
            .. " | " .. num(bale:getFillLevel()),
        "STATION_UNLOAD/COMMITTED TRANSFERRED:400 | STRAW|600|UNKNOWN|nil | STRAW|400|UNKNOWN|nil | 600")
    T.eq("D1b the stock is the bale's own, not a new generation, and the unit is still no carrier", tostring(stockOf(sg, bale) == before) .. "/" .. tostring(sg.operations.carriers[unitKey(v)] == nil), "true/true")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE LAST DISCHARGE: THE BALE DELETED INSIDE IT
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local m, sg, host, w = boot5g({ bales = { 1000.005 } }, "w5g_d", 302)
    local v, bale = w.blower, w.bales[1]
    local id = cid(bale)
    loadAndMirror(v, bale)
    local retiredBefore = { last = retired("LAST_DISCHARGE"), cleared = retired("CLEARED") }
    blow(v, w.barn.station, 1000)
    local ls = host.lastSettlement
    T.eq("D2 NAMED: the last discharge deletes the bale inside the transfer: no BALE_DELETE remove, ONE TRANSFER of 1000 L to the barn and the 0.005 L native trims a STRAW_BLOWER_TRIM loss, the bale's carrier withdrawn, the mirror retired once after the settle",
        tostring(ls and ls.report and ls.report.outcomeEvidence.nativePath) .. "/" .. tostring(ls and ls.outcome) .. " " .. legsText(ls) .. " | " .. tostring(bale.isDeleted)
            .. " " .. tostring(sg.operations.carriers[id] == nil) .. " " .. mirrorCount() .. " " .. (retired("LAST_DISCHARGE") - retiredBefore.last) .. "/" .. (retired("CLEARED") - retiredBefore.cleared)
            .. " | " .. barnText(sg, w),
        "STATION_UNLOAD/COMMITTED TRANSFERRED:1000,LOSS:0.005:STRAW_BLOWER_TRIM | true true 0 1/0 | STRAW|1000|UNKNOWN|nil")
    T.eq("D2b the trim is within native's own 0.01 L threshold (StrawBlower.lua:159) and the unit is empty", tostring(ls ~= nil and ls.report ~= nil and (ls.report.outcomeEvidence.trimmed or 0) <= 0.01) .. "/" .. num(v:getFillUnitFillLevel(1)), "true/0")
    endMission(m)

    -- A station that reports more than its storage keeps: the bale's excess past native's threshold is
    -- no trim of native's, and stays UNMATCHED_SOURCE.
    m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_d3", 303)
    v, bale = w.blower, w.bales[1]
    loadAndMirror(v, bale)
    local honest = w.barn.station.addFillLevelFromTool
    w.barn.station.addFillLevelFromTool = function(self, farmId, delta, ...) return honest(self, farmId, delta * 0.99, ...) / 0.99 end
    blow(v, w.barn.station, 1000)
    ls = host.lastSettlement
    T.eq("D3 NAMED (Bob's mutant): a residue over 0.01 L is not native's trim: the deleted bale's 10 L the barn did not keep stay UNMATCHED_SOURCE",
        tostring(ls and ls.outcome) .. " " .. legsText(ls), "COMMITTED TRANSFERRED:990,LOSS:10:UNMATCHED_SOURCE")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE UNIT'S PLAIN CARRIER, AND M. AN UNFRAMED REPORT
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    -- The unit holds 5 L at the barrier, so its plain carrier has a stock when the bale loads.
    local m, sg, host, w = boot5g({ bales = { 1000 }, unitLevel = 5 }, "w5g_p", 304)
    local v, bale = w.blower, w.bales[1]
    loadAndMirror(v, bale)
    T.eq("P2 NAMED (Bob's bar): a unit carrier holding litres at the load gives no mirror (unproved), and its reports replay as today",
        mirrorCount() .. " " .. tostring(host.lastStrawBlowerLoad and host.lastStrawBlowerLoad.reason) .. " " .. tostring(sg.operations.carriers[unitKey(v)] ~= nil), "0 UNIT_HOLDS_STOCK true")
    endMission(m)
end)
group("M", function()
    local m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_m", 305)
    local v, bale = w.blower, w.bales[1]
    loadAndMirror(v, bale)
    -- A report on the mirrored unit outside any frame (a direct add, no discharge).
    v:addFillUnitFillLevel(1, 1, -50, STRAW, ToolType.UNDEFINED)
    host:flush()
    T.eq("M1 NAMED (Bob's bar): an unframed report on the mirrored unit reconciles the bale through the flush's UNKNOWN_CARRIER fallback, and binds nothing under the unit's key",
        num(bale:getFillLevel()) .. " " .. num(stockOf(sg, bale) and stockOf(sg, bale).observedAmount) .. " " .. tostring(sg.operations.carriers[unitKey(v)] == nil), "950 950 true")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T, X, U, R. THE CLEARS, ANOTHER ROUTE'S DELETE, AN UNBOUND BALE, A REMOVED BLOWER
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_t", 306)
    local v, bale = w.blower, w.bales[1]
    loadAndMirror(v, bale)
    blow(v, w.barn.station, 400)
    local s = stockOf(sg, bale)
    local settled = host.lastSettlement
    triggerBale(v, bale, false)
    T.eq("T1 NAMED: a trigger-leave mid-blow retires the mirror; the bale keeps its 600 L and its stock, nothing is removed, and the cleared unit is no carrier",
        mirrorCount() .. " " .. tostring(stockOf(sg, bale) == s) .. " " .. stockText(stockOf(sg, bale)) .. " " .. tostring(host.lastSettlement == settled) .. " " .. tostring(sg.operations.carriers[unitKey(v)] == nil)
            .. " " .. num(v:getFillUnitFillLevel(1)),
        "0 true STRAW|600|UNKNOWN|nil true true 0")
    endMission(m)
end)
group("X", function()
    local m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_x", 307)
    local v, bale = w.blower, w.bales[1]
    local id = cid(bale)
    loadAndMirror(v, bale)
    bale:delete()
    T.eq("X1 NAMED: a mirrored bale deleted by another route, outside any discharge, is that route's REMOVE; the mirror retires and the unit's clear removes nothing more",
        removeText(host) .. " " .. tostring(sg.operations.carriers[id] == nil) .. " " .. mirrorCount() .. " " .. tostring(sg.operations.carriers[unitKey(v)] == nil),
        "COMMITTED/BALE_DELETE/1000/REMOVED:BALE_DELETED true 0 true")
    endMission(m)
end)
group("U", function()
    local m, sg, host, w = boot5g({ bales = {} }, "w5g_u", 308)
    local v = w.blower
    -- A bale made after the barrier: StockGuard holds no carrier for it.
    local stray = newBale(STRAW, 800)
    loadAndMirror(v, stray)
    T.eq("U1 NAMED: a bale with no StockGuard carrier gets no mirror; nothing attaches by capacity, and the unit's own reports replay as today",
        mirrorCount() .. " " .. tostring(host.lastStrawBlowerLoad and host.lastStrawBlowerLoad.reason):sub(1, 13) .. " " .. tostring(stockOf(sg, stray) == nil),
        "0 BALE_UNBOUND: true")
    endMission(m)
end)
group("R", function()
    local m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_r", 309)
    local v, bale = w.blower, w.bales[1]
    loadAndMirror(v, bale)
    host:onVehicleRemoved(v)
    T.eq("R1 NAMED: a removed blower retires its mirror; the bale keeps its stock", mirrorCount() .. " " .. stockText(stockOf(sg, bale)), "0 STRAW|1000|UNKNOWN|INITIAL_OBSERVATION")
    endMission(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. A SAVE AND A RELOAD
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg, host, w = boot5g({ bales = { 1000 } }, "w5g_s", 310)
    local v, bale = w.blower, w.bales[1]
    loadAndMirror(v, bale)
    blow(v, w.barn.station, 300)
    local s = stockOf(sg, bale)
    nativeSave(m, "w5g_s")
    endMission(m)
    -- The next launch: the items come back with their uniqueIds; the blower loads from its savegame entry,
    -- which empties its unsaved unit (StrawBlower.lua:51-57).
    local m2, sg2, host2, w2 = boot5g({ bales = {}, loadItems = true, savegame = { resetVehicles = false } }, "w5g_s", 310)
    local v2 = w2.blower
    local back = nil
    for item in pairs(m2.itemSystem.itemsToSave) do if item.getFillLevel ~= nil then back = item end end
    local before = stockOf(sg2, back)
    T.eq("S1 NAMED: after a save and a reload the unit is empty and no mirror stands; the bale is back with its stock (700 L)",
        num(v2:getFillUnitFillLevel(1)) .. " " .. mirrorCount() .. " " .. stockText(before), "0 0 STRAW|700|UNKNOWN|nil")
    loadAndMirror(v2, back)
    T.eq("S1b NAMED: the next load is a new mirror over the same bale stock, with no duplicate",
        mirrorCount() .. " " .. tostring(stockOf(sg2, back) == before) .. " " .. stocksOfStraw(sg2, w2) .. " " .. tostring(sg2.operations.carriers[unitKey(v2)] == nil), "1 true 1 true")
    endMission(m2)
end)
