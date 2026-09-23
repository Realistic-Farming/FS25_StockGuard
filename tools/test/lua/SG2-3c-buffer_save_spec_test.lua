-- SG2-3c-buffer_save_spec_test.lua
--
-- SG2-3c, the Combine buffer save extension (SG-2 :132 save half, :136-140, :148): a
-- combine's in-flight grain (the loading delay slots) and buffered straw (the input
-- buffer) survive a save together with StockGuard's bindings to them. Native saves
-- neither (Combine.lua:275-282; loadCombineSetup builds every slot invalid, :517-525).
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine models, then main.lua's modules and
-- main.lua (sourced, as MPLoadingScreen.lua:735 does, before Vehicle.init); the
-- savegame schema built fresh by Vehicle.init and every specialization's
-- initSpecialization called through its class table (MPLoadingScreen.lua:767, :776);
-- the mission through main's appends; a combine and header in the vehicle list at the
-- barrier; a harvest frame in the engine's order; then the engine's own save path (the
-- vehicles file created with that schema, VehicleSystem.lua:293; Vehicle:saveToXMLFile's
-- class-table loop, Vehicle.lua:1210-1212; StockGuard's own file through its save
-- hook), the mission deleted, a fresh mission on the same save directory (a fresh
-- schema again), the vehicles file loaded with it (:324), the combine built with fresh
-- native buffers and its onPostLoad raised through the class table
-- (SpecializationUtil.lua:2-16, queued at Vehicle.lua:903-906), and the barrier.
-- Nothing writes a slot, a stock, a binding, a save key or a schema path by hand.
--
-- Groups:
--   S  the entry-point bar: a slot with 60 ms of delay left and its straw survive the
--      save, reattach at the barrier, and drain on time
--   Z  a slot past its delay at save time is due on the first update after the load
--   I  an incompatible layout, an unknown fill type, another straw layout, another
--      version: unresolved, nothing reallocated, SG-1 retires as absent
--   K  the straw cursors and timer survive the save
--   H  each straw slot's identity (haulm fruit or ground type, :148) survives the save
--   N  no live buffer writes no element and restores nothing
--   R  a savegame with resetVehicles restores nothing
--   C  no savegame, and a client, do nothing
--   V  a vehicle removed with grain in flight: destruction, its slot stocks retire
--   G  the log lines, once each
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local NH, NA, B = SGNativeHost, SGNativeAdapters, SGCombineBufferSave
local FRUIT = ENGINE_FRUIT.WHEAT

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── the world (as SG2-3a's, with a save directory) ─────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir)
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = { savegameDirectory = saveDir }, missionDynamicInfo = { isMultiplayer = false }, time = 1000, terrainSize = 256, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

--- Boot through main.lua's load path, the world built first.
local function boot(build, saveDir)
    ENGINE_PLANE.cells = {}
    local m = newMission(saveDir)
    g_server = {}
    g_currentMission = m
    -- MPLoadingScreen.lua:767 and :776: the savegame schema built fresh, then every
    -- specialization's initSpecialization through its class table.
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local w = {}
    build(m, w)
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, sg, NH.current, w
end
local function combineIn(m, uid, opts)
    local v = ENGINE_NEW_COMBINE(uid, opts)
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function headerIn(m, uid, combine, opts)
    local v = ENGINE_NEW_HEADER(uid, combine, opts)
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local OPTS = { loadingDelay = 100, hopperCapacity = 50 }
local HEADER = { areas = 1, width = 6, depth = 1 }
local VKEY = "vehicles.vehicle(0)"

--- The engine's saves: the vehicle through Vehicle:saveToXMLFile's specialization
--- loop, StockGuard's own file through its save hook.
local function saveWorld(m, sg, combine, dir)
    local xml = XMLFile.create("vehicles", dir .. "/vehicles.xml", "vehicles", Vehicle.xmlSchemaSavegame)
    ENGINE_SAVE_VEHICLE(combine, xml, VKEY, {})
    xml:save()
    sg:onSaveToXML(m.missionInfo)
    return xml
end
--- A combine bought back from the save: onLoad's fresh native buffers, then the
--- onPostLoad event with the savegame (nil for a vehicle not loaded from one).
local function loadCombine(m, uid, opts, dir, flags)
    local xml = dir ~= nil and XMLFile.load("vehicles", dir .. "/vehicles.xml", Vehicle.xmlSchemaSavegame) or nil
    local v = combineIn(m, uid, opts)
    local savegame = xml ~= nil and { xmlFile = xml, key = VKEY, resetVehicles = flags ~= nil and flags.resetVehicles or false } or nil
    ENGINE_POST_LOAD_VEHICLE(v, savegame)
    return v
end
--- Quit to the menu and load the save: a fresh mission on the same directory.
local function reload(m, dir, build)
    FSBaseMission.delete(m)
    return boot(build, dir)
end
--- A harvested world saved at 56 ms after its cut: slot 1 with 60 ms of delay left.
local function harvestedAndSaved(dir)
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", OPTS)
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, dir)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    ENGINE_HARVEST_TICK(nil, w.combine, 40)
    local xml = saveWorld(m, sg, w.combine, dir)
    return m, sg, host, w, xml
end

-- ── readers ───────────────────────────────────────────────────────────────
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function hopperId(v) return cid(NA.fillUnitBinding(v, 1)) end
local function slotId(v, kind, i) return cid(NA.combineSlotBinding(v, kind, i)) end
local function stockAt(sg, id) local c = sg.operations.carriers[id] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end
local function retiredReasons(sg, reason)
    local n = 0
    for _, s in pairs(sg.operations.retiredStocks or {}) do if s.retireReason == reason then n = n + 1 end end
    return n
end
local function head(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome)
end
local function legsOf(ls, names)
    local out = {}
    for _, a in ipairs(ls and ls.report and ls.report.allocations or {}) do
        local src = a.source.slotId and ("w" .. (a.source.slotId:match(":w(%d+)") or "?")) or (names[a.source.carrierId] or "?")
        local dst = a.destination.retire and "retire" or (names[a.destination.carrierId] or "?")
        out[#out + 1] = src .. ">" .. dst .. ":" .. num(a.sourceAmount) .. ":" .. tostring(a.result)
    end
    return table.concat(out, ",")
end
--- The saved element, read raw from the file: "v<version>/<slotCount>:<toggle>/d<i>=<litres>:<type>:<remaining>.../s<count>:f<fill>:d<drop>:t<timer>:<fruit>/<i>=<liters>:<input>:<area>:<ratio>:<density>...".
local function savedBuffer(xml, base)
    local d = xml.data
    base = base .. "." .. B.ELEMENT
    if d[base .. "#version"] == nil then return "none" end
    local out = { "v" .. tostring(d[base .. "#version"]), tostring(d[base .. "#slotCount"]) .. ":" .. tostring(d[base .. "#delayedInsert"]) }
    local n = 0
    while d[string.format("%s.delaySlot(%d)#index", base, n)] ~= nil do
        local k = string.format("%s.delaySlot(%d)", base, n)
        out[#out + 1] = "d" .. tostring(d[k .. "#index"]) .. "=" .. num(d[k .. "#fillLevelDelta"]) .. ":" .. tostring(d[k .. "#fillType"]) .. ":" .. num(d[k .. "#remainingDelay"])
        n = n + 1
    end
    local k = base .. ".straw"
    if d[k .. "#slotCount"] ~= nil then
        out[#out + 1] = "s" .. tostring(d[k .. "#slotCount"]) .. ":f" .. tostring(d[k .. "#fillIndex"]) .. ":d" .. tostring(d[k .. "#dropIndex"]) .. ":t" .. num(d[k .. "#slotTimer"]) .. ":" .. tostring(d[k .. "#fruitType"])
        local i = 0
        while d[string.format("%s.slot(%d)#index", k, i)] ~= nil do
            local sk = string.format("%s.slot(%d)", k, i)
            out[#out + 1] = tostring(d[sk .. "#index"]) .. "=" .. num(d[sk .. "#liters"]) .. ":" .. num(d[sk .. "#inputLiters"]) .. ":" .. num(d[sk .. "#area"]) .. ":" .. num(d[sk .. "#strawRatio"]) .. ":" .. num(d[sk .. "#effectDensity"])
            i = i + 1
        end
    end
    return table.concat(out, "/")
end
--- The live delay slots: "<i>:<litres>:<type>:t<time>" per valid slot ("-" for none), then the insert toggle.
local function liveSlots(v)
    local cs = v.spec_combine
    local out = {}
    for i, s in ipairs(cs.loadingDelaySlots or {}) do
        if s.valid then out[#out + 1] = i .. ":" .. num(s.fillLevelDelta) .. ":" .. tostring(g_fillTypeManager:getFillTypeNameByIndex(s.fillType)) .. ":t" .. num(s.time) end
    end
    return (#out > 0 and table.concat(out, ",") or "-") .. "/" .. tostring(cs.loadingDelaySlotsDelayedInsert)
end
--- The live straw buffer: live slots, cursors, and the fruit the drop would take.
local function liveStraw(v)
    local ib = v.spec_combine.processing.inputBuffer
    local out = {}
    for i, s in ipairs(ib.buffer) do
        if s.liters > 0 or s.inputLiters > 0 or s.area > 0 then out[#out + 1] = i .. "=" .. num(s.liters) .. ":" .. num(s.inputLiters) .. ":" .. num(s.area) .. ":" .. num(s.strawRatio) .. ":" .. num(s.effectDensity) end
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(v.spec_combine.lastValidInputFruitType)
    return (#out > 0 and table.concat(out, ",") or "-") .. "/f" .. tostring(ib.fillIndex) .. ":d" .. tostring(ib.dropIndex) .. ":t" .. num(ib.slotTimer) .. "/" .. tostring(desc and desc.name)
end
--- A straw slot's identity the drop reads: "<haulm fruit index>:<ground value>".
local function strawIdentity(v, i)
    local s = v.spec_combine.processing.inputBuffer.buffer[i]
    return tostring(s.strawHaulmFruitTypeIndex) .. ":" .. tostring(s.strawGroundType)
end
local function schemaHas(path) return Vehicle.xmlSchemaSavegame ~= nil and Vehicle.xmlSchemaSavegame.paths[path] ~= nil end
local function unresolvedOf(v)
    local r = v.spec_combine.sgBufferRestore
    return r == nil and "nil" or (tostring(r.restored) .. ":" .. table.concat(r.unresolved, ","))
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", OPTS)
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, "save1")
    T.ok("S1 [reached] main.lua's load path wrapped the Combine class's saver and its post-load event", host ~= nil and host.ready and rawget(Combine, B.MARKER) ~= nil)
    local schema1 = Vehicle.xmlSchemaSavegame
    T.eq("S1b the savegame schema Vehicle.init built carries the element's paths beside native Combine's three, registered through Combine.initSpecialization when the mission loaded",
        tostring(schemaHas(B.SAVEGAME_BASE .. "#version")) .. "/" .. tostring(schemaHas(B.SAVEGAME_BASE .. ".delaySlot(?)#remainingDelay")) .. "/" .. tostring(schemaHas(B.SAVEGAME_BASE .. ".straw.slot(?)#groundType")) .. "/" .. tostring(schemaHas("vehicles.vehicle(?).combine#workedHectars")),
        "true/true/true/true")
    ENGINE_XML_ERRORS, ENGINE_XML_ERROR_LOG = 0, {}
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    ENGINE_HARVEST_TICK(nil, w.combine, 40)
    T.eq("S2 [world] 56 ms after the cut its 6 L wait in slot 1 (due at 1116) and its straw sits in input slot 1; the hopper is empty",
        liveSlots(w.combine) .. " " .. liveStraw(w.combine) .. " " .. num(w.combine:getFillUnitFillLevel(1)), "1:6:WHEAT:t1016/true 1=6:6:6:0.5:0.6/f1:d4:t99944/WHEAT 0")
    local xml = saveWorld(m, sg, w.combine, "save1")
    T.eq("S3 the vehicle's own save carries the live slot with the 60 ms of delay left, the layout and the insert toggle, and the straw slot with its cursors and fruit; the native values beside it are untouched",
        savedBuffer(xml, VKEY .. ".combine") .. " " .. tostring(xml.data[VKEY .. ".combine#workedHectars"]) .. "/" .. tostring(xml.data[VKEY .. ".fillUnit.unit(0)#fillLevel"]),
        "v1/7:true/d1=6:WHEAT:60/s4:f1:d4:t99944:WHEAT/1=6:6:6:0.5:0.6 0/0")
    T.eq("S3b every path the save wrote was registered on the schema the file was created with: no 'Path not registered' error, nothing silently dropped", ENGINE_XML_ERRORS, 0)
    -- Quit and load: the combine comes back with onLoad's empty buffers, a hopper whose
    -- last valid type is UNKNOWN again, and a mission clock starting over.
    local m2, sg2, host2, w2 = reload(m, "save1", function(m2, w2)
        w2.combine = loadCombine(m2, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, lastValid = FillType.UNKNOWN }, "save1")
        w2.header = headerIn(m2, "vehicle:delayHeader", w2.combine, HEADER)
    end)
    T.eq("S4 [world] the reloaded combine holds the slot again with its clock rebuilt on the new mission time (due at 1060), the toggle, the straw slot with its cursors and fruit; the load added nothing to the hopper",
        liveSlots(w2.combine) .. " " .. liveStraw(w2.combine) .. " " .. num(w2.combine:getFillUnitFillLevel(1)) .. " " .. unresolvedOf(w2.combine), "1:6:WHEAT:t960/true 1=6:6:6:0.5:0.6/f1:d4:t99944/WHEAT 0 2:")
    T.eq("S4b the fresh mission built a fresh schema (Vehicle.lua:249) and the paths were registered on it again; the load read every path through it without an error",
        tostring(Vehicle.xmlSchemaSavegame ~= schema1) .. "/" .. tostring(schemaHas(B.SAVEGAME_BASE .. "#version")) .. "/" .. num(ENGINE_XML_ERRORS) .. (ENGINE_XML_ERRORS > 0 and (" [" .. table.concat(ENGINE_XML_ERROR_LOG, "; ") .. "]") or ""), "true/true/0")
    local slot1, straw1, hop = slotId(w2.combine, NA.KIND_DELAY_SLOT, 1), slotId(w2.combine, NA.KIND_STRAW_SLOT, 1), hopperId(w2.combine)
    local grain, straw = stockAt(sg2, slot1), stockAt(sg2, straw1)
    T.eq("S5 SG-1 reattached both carriers' stocks across the save: 6 L wheat in the slot, 6 L straw in the input slot (named from the saved fruit, the hopper being empty), nothing retired as absent",
        num(grain and grain.observedAmount) .. ":" .. tostring(grain and grain.materialRef.fillTypeName) .. " " .. num(straw and straw.observedAmount) .. ":" .. tostring(straw and straw.materialRef.fillTypeName) .. " " .. tostring(retiredReasons(sg2, "CARRIER_ABSENT")),
        "6:WHEAT 6:STRAW 0")
    ENGINE_HARVEST_TICK(nil, w2.combine, 50)
    T.eq("S6 50 ms in, the slot is not yet due: no drain, the slot still valid", tostring(host2.lastDrain) .. "/" .. liveSlots(w2.combine), "nil/1:6:WHEAT:t960/true")
    ENGINE_HARVEST_TICK(nil, w2.combine, 16)
    T.eq("S7 66 ms in, the drain is ONE TRANSFER of the 6 L from the reattached slot into the hopper",
        head(host2.lastDrain) .. "/" .. legsOf(host2.lastDrain, { [slot1] = "slot1", [hop] = "hopper" }) .. "/" .. num(w2.combine:getFillUnitFillLevel(1)), "COMBINE_DRAIN/COMMITTED/slot1>hopper:6:TRANSFERRED/6")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. A SLOT PAST ITS DELAY AT SAVE TIME
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", OPTS)
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, "save2")
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    -- The clock passes the delay between two update ticks, then the game saves.
    g_currentMission.time = g_currentMission.time + 200
    local xml = saveWorld(m, sg, w.combine, "save2")
    T.eq("Z1 a slot past its delay at save time carries a remaining delay of 0, never a negative one", savedBuffer(xml, VKEY .. ".combine"):match("d1=[^/]+"), "d1=6:WHEAT:0")
    local m2, sg2, host2, w2 = reload(m, "save2", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", OPTS, "save2") end)
    ENGINE_HARVEST_TICK(nil, w2.combine, 16)
    T.eq("Z2 and it is due on the first update after the load: one drain of the 6 L, nothing added by the load itself",
        legsOf(host2.lastDrain, { [slotId(w2.combine, NA.KIND_DELAY_SLOT, 1)] = "slot1", [hopperId(w2.combine)] = "hopper" }) .. "/" .. num(w2.combine:getFillUnitFillLevel(1)), "slot1>hopper:6:TRANSFERRED/6")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- I. INCOMPATIBLE SAVES: UNRESOLVED, NOTHING REALLOCATED
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    local m = harvestedAndSaved("save3")
    -- Another loading delay: 4 native slots against a saved layout of 7.
    local m2, sg2, host2, w2 = reload(m, "save3", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", { loadingDelay = 50, hopperCapacity = 50 }, "save3") end)
    T.eq("I1 [world] a combine whose delay layout differs from the save keeps its fresh slots: nothing restored there, nothing reallocated; the straw, whose layout matches, restores",
        liveSlots(w2.combine) .. " " .. liveStraw(w2.combine):match("^[^/]+") .. " " .. unresolvedOf(w2.combine), "-/false 1=6:6:6:0.5:0.6 1:SLOT_LAYOUT")
    T.eq("I2 SG-1 then retires the saved slot stock as absent, as it did before this extension, and the hopper holds nothing",
        tostring(retiredReasons(sg2, "CARRIER_ABSENT")) .. "/" .. num(w2.combine:getFillUnitFillLevel(1)) .. "/" .. tostring(stockAt(sg2, slotId(w2.combine, NA.KIND_DELAY_SLOT, 1))), "1/0/nil")
    FSBaseMission.delete(m2)

    -- A fill type name this game does not know.
    m = harvestedAndSaved("save4")
    ENGINE_DISK["save4/vehicles.xml"][VKEY .. ".combine." .. B.ELEMENT .. ".delaySlot(0)#fillType"] = "UNOBTAINIUM"
    m2, sg2, host2, w2 = reload(m, "save4", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", OPTS, "save4") end)
    T.eq("I3 a saved fill type this game does not know leaves that slot unresolved, not restored as another type", liveSlots(w2.combine) .. " " .. unresolvedOf(w2.combine), "-/false 1:FILL_TYPE")
    FSBaseMission.delete(m2)

    -- A straw buffer of another slot count.
    m = harvestedAndSaved("save5")
    m2, sg2, host2, w2 = reload(m, "save5", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, strawSlots = 3 }, "save5") end)
    T.eq("I4 a straw buffer of another slot count leaves the saved straw unresolved while the delay slot restores",
        liveStraw(w2.combine) .. " " .. liveSlots(w2.combine) .. " " .. unresolvedOf(w2.combine), "-/f1:d3:t100000/nil 1:6:WHEAT:t960/true 1:STRAW_LAYOUT")
    FSBaseMission.delete(m2)

    -- Another version of the element.
    m = harvestedAndSaved("save6")
    ENGINE_DISK["save6/vehicles.xml"][VKEY .. ".combine." .. B.ELEMENT .. "#version"] = 2
    m2, sg2, host2, w2 = reload(m, "save6", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", OPTS, "save6") end)
    T.eq("I5 an element of another version restores nothing", liveSlots(w2.combine) .. " " .. liveStraw(w2.combine):match("^[^/]+") .. " " .. unresolvedOf(w2.combine), "-/false - 0:VERSION")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE STRAW CURSORS
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, slotDuration = 30 })
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, "save15")
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    ENGINE_HARVEST_TICK(nil, w.combine, 40)
    local xml = saveWorld(m, sg, w.combine, "save15")
    T.eq("K1 [world] one rotation moved the buffer's cursors and reset its timer (Combine.lua:441-451); the save carries them",
        liveStraw(w.combine):match("/f[^/]+") .. " " .. savedBuffer(xml, VKEY .. ".combine"):match("s4:[^/]+"), "/f2:d1:t30 s4:f2:d1:t30:WHEAT")
    local m2, sg2, host2, w2 = reload(m, "save15", function(m2, w2)
        w2.combine = loadCombine(m2, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, slotDuration = 30 }, "save15")
    end)
    T.eq("K2 the reloaded buffer resumes at the same cursors and timer, so the rotation continues where it stopped", liveStraw(w2.combine):match("/f[^/]+"), "/f2:d1:t30")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. EACH STRAW SLOT'S IDENTITY (:148)
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    -- Wheat chops to a ground type: the model's field ground system values CHOPPER_STRAW at 21.
    local m, sg, host, w, xml = harvestedAndSaved("save16")
    T.eq("H1 [world] the cut set the straw slot's identity the drop reads (Combine.lua:983-991): CHOPPER_STRAW's ground value, no haulm fruit", strawIdentity(w.combine, 1), "nil:21")
    T.eq("H2 the save carries it as the FieldChopperType member, not the game-local value", tostring(xml.data[VKEY .. ".combine.stockGuardBuffer.straw.slot(0)#groundType"]) .. "/" .. tostring(xml.data[VKEY .. ".combine.stockGuardBuffer.straw.slot(0)#haulmFruit"]), "CHOPPER_STRAW/nil")
    local m2, sg2, host2, w2 = reload(m, "save16", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", OPTS, "save16") end)
    T.eq("H3 the reloaded slot carries the same identity, resolved through this game's field ground system", strawIdentity(w2.combine, 1) .. " " .. unresolvedOf(w2.combine), "nil:21 2:")
    FSBaseMission.delete(m2)
    -- A haulm crop (the model's barley): the fruit itself is the identity.
    local m3, sg3, host3, w3 = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, lastValid = ENGINE_FT.BARLEY })
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, { areas = 1, width = 6, depth = 1, fruitTypes = { ENGINE_FRUIT.BARLEY } })
        ENGINE_PLANE.sow(ENGINE_FRUIT.BARLEY, 0, 0, 6, 1, 4)
    end, "save17")
    ENGINE_HARVEST_TICK(w3.header, w3.combine, 16)
    ENGINE_HARVEST_TICK(nil, w3.combine, 40)
    local xml3 = saveWorld(m3, sg3, w3.combine, "save17")
    T.eq("H4 [world] a haulm crop's cut names the fruit and no ground type, and the save carries the fruit name", strawIdentity(w3.combine, 1) .. " " .. tostring(xml3.data[VKEY .. ".combine.stockGuardBuffer.straw.slot(0)#haulmFruit"]) .. "/" .. tostring(xml3.data[VKEY .. ".combine.stockGuardBuffer.straw.slot(0)#groundType"]), "12:nil BARLEY/nil")
    local m4, sg4, host4, w4 = reload(m3, "save17", function(m4, w4) w4.combine = loadCombine(m4, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, lastValid = ENGINE_FT.BARLEY }, "save17") end)
    T.eq("H5 the reloaded slot names the fruit again", strawIdentity(w4.combine, 1) .. " " .. unresolvedOf(w4.combine), "12:nil 2:")
    -- An identity this game does not know: the slot stays unresolved, nothing guessed.
    ENGINE_DISK["save17/vehicles.xml"][VKEY .. ".combine.stockGuardBuffer.straw.slot(0)#haulmFruit"] = "TRITICALE"
    local m5, sg5, host5, w5 = reload(m4, "save17", function(m5, w5) w5.combine = loadCombine(m5, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, lastValid = ENGINE_FT.BARLEY }, "save17") end)
    T.eq("H6 a saved haulm fruit this game lacks leaves that straw slot unresolved (STRAW_SELECTOR): no liters put in it, no identity guessed; the delay slot beside it restores",
        liveStraw(w5.combine):match("^[^/]+") .. " " .. strawIdentity(w5.combine, 1) .. " " .. unresolvedOf(w5.combine), "- nil:nil 1:STRAW_SELECTOR")
    FSBaseMission.delete(m5)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. NOTHING LIVE
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local m, sg, host, w = boot(function(m, w) w.combine = combineIn(m, "vehicle:idle", OPTS) end, "save7")
    local xml = saveWorld(m, sg, w.combine, "save7")
    T.eq("N1 a combine with nothing in flight writes no element, and the native save beside it is untouched", savedBuffer(xml, VKEY .. ".combine") .. "/" .. tostring(xml.data[VKEY .. ".combine#numAttachedCutters"]), "none/0")
    local m2, sg2, host2, w2 = reload(m, "save7", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:idle", OPTS, "save7") end)
    T.eq("N2 and its load restores nothing and records nothing", liveSlots(w2.combine) .. " " .. unresolvedOf(w2.combine), "-/false nil")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. RESET VEHICLES
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local m = harvestedAndSaved("save8")
    local m2, sg2, host2, w2 = reload(m, "save8", function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", OPTS, "save8", { resetVehicles = true }) end)
    T.eq("R1 a savegame loaded with reset vehicles restores no buffer, as native restores no attachment then (Combine.lua:232)", liveSlots(w2.combine) .. " " .. liveStraw(w2.combine):match("^[^/]+") .. " " .. unresolvedOf(w2.combine), "-/false - nil")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. NO SAVEGAME, AND A CLIENT
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", OPTS)
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, "save9")
    local bought = combineIn(m, "vehicle:new", OPTS)
    local lines = {}
    local realPrint = print
    print = function(s) lines[#lines + 1] = tostring(s) realPrint(s) end
    local ok, err = pcall(ENGINE_POST_LOAD_VEHICLE, bought, nil)
    print = realPrint
    local failed = 0
    for _, l in ipairs(lines) do if l:find("hook failed", 1, true) then failed = failed + 1 end end
    T.eq("C1 a combine bought new has no savegame: its post-load runs clean, logs no failure and restores nothing", tostring(ok) .. "/" .. failed .. "/" .. liveSlots(bought) .. "/" .. unresolvedOf(bought), "true/0/-/false/nil")
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    g_server = nil
    local xml = XMLFile.create("vehicles", "save9/client.xml", "vehicles", Vehicle.xmlSchemaSavegame)
    ENGINE_SAVE_VEHICLE(w.combine, xml, VKEY, {})
    g_server = {}
    T.eq("C2 without a server the saver writes no element (a client never saves)", savedBuffer(xml, VKEY .. ".combine"), "none")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. A VEHICLE REMOVED WITH GRAIN IN FLIGHT
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", OPTS)
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, "save10")
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local grain, straw = stockAt(sg, slotId(w.combine, NA.KIND_DELAY_SLOT, 1)), stockAt(sg, slotId(w.combine, NA.KIND_STRAW_SLOT, 1))
    local gId, sId = grain and grain.stockId, straw and straw.stockId
    VehicleSystem.removeVehicle(m.vehicleSystem, w.combine)
    local gr, sr = gId and sg.operations.retiredStocks[gId], sId and sg.operations.retiredStocks[sId]
    T.eq("V1 selling the combine with grain in flight is destruction: the slot's and the straw slot's stocks retire with the vehicle and never reach the next machine",
        tostring(gr and gr.retireReason) .. "/" .. tostring(sr and sr.retireReason), "VEHICLE_REMOVED/VEHICLE_REMOVED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE LOG LINES
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    local lines = {}
    local realPrint = print
    print = function(s) lines[#lines + 1] = tostring(s) realPrint(s) end
    B.logged = {}
    for _, dir in ipairs({ "save11", "save12" }) do
        local m = harvestedAndSaved(dir)
        local m2 = reload(m, dir, function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", OPTS, dir) end)
        FSBaseMission.delete(m2)
    end
    for _, dir in ipairs({ "save13", "save14" }) do
        local m = harvestedAndSaved(dir)
        local m2 = reload(m, dir, function(m2, w2) w2.combine = loadCombine(m2, "vehicle:delay", { loadingDelay = 50, hopperCapacity = 50 }, dir) end)
        FSBaseMission.delete(m2)
    end
    print = realPrint
    local restored, unresolved = 0, 0
    for _, l in ipairs(lines) do
        if l:find("FIRST COMBINE BUFFER RESTORED", 1, true) then restored = restored + 1 end
        if l:find("could not be restored (SLOT_LAYOUT)", 1, true) then unresolved = unresolved + 1 end
    end
    T.eq("G1 the first restored buffer says so once in log.txt, over two loads", restored, 1)
    T.eq("G2 an unresolved buffer says so once per reason set, over two loads", unresolved, 1)
end)
