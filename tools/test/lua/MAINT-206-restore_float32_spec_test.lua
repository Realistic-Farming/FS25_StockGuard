-- MAINT-206-restore_float32_spec_test.lua
--
-- MAINTENANCE row 206: SG-1's restore reattached a saved stock only when the reloaded native
-- level equalled the saved observedAmount exactly (SGOperations.lua restoreCore). SG-1 saves that
-- amount as an exact double (%.17g); the engine saves a fill unit's, a storage's and StockGuard's
-- own Combine slots' levels as XMLValueType.FLOAT, which it writes as the float32 to six decimals,
-- ties to even (measured from this machine's save files). So a reloaded level is the saved one as
-- native wrote it, and every level that is not already such a float came back RESTORE_MISMATCH:
-- UNKNOWN, its records (Soil's carried condition among them) only history. The fix compares both
-- sides through the adapter's restoredQuantityImage (SGValues.nativeFloatImage for those four
-- kinds), exact integer equality, never a tolerance (SG-1 brief :392).
--
-- THE ENTRY-POINT BAR IS GROUP F: SG2-3c's world (main.lua's load path, the savegame schema built
-- fresh by Vehicle.init, FillUnit's own save and load shape through XMLFile:setValue and getValue,
-- StockGuard's own file through its save hook, the mission deleted and a fresh one on the same
-- directory), with the XML model's FLOAT paths written as the engine writes them and read back
-- by either reader the C side might be. Group C does the same for a Combine's delay and straw
-- slots through SGCombineBufferSave's own FLOAT path. On 2f92a77 F1, F2, C1 and C2 come back
-- RESTORE_MISMATCH.
--
-- Groups:
--   G  the image against the (float32, text) pairs the engine wrote, and the bench's writer model
--   F  a trailer's fill unit: both readers, a whole-number control, a one-float32-step change, a
--      changed material
--   C  a Combine's delay and straw slots, both readers
--   A  the adapter member per kind, and the registry's optional-member check
--
-- NOT RUN here: a storage through a native save. No bench world saves a storage placeable's
-- level; A1 shows the adapter gives a storage the same image, and restoreCore's comparison is
-- the one F and C drive.
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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


-- The bench's own additions run inside one function, so its locals stay out of the chunk's
-- 200-local budget.
local function MAINT206_BENCH()

-- 52 (text, float32) pairs the engine wrote, lifted from 40 save files on 2026-10-02 (vehicles.xml
-- and placeables.xml fillLevel and amount attributes; 1646 distinct texts, every one the six-decimal
-- rendering of its float32, ties to even). 25 ties, every tie in the files.
local GOLDEN = {
    { "1989.148438", 1989.1484375, true },
    { "3321.617188", 3321.6171875, true },
    { "3376.867188", 3376.8671875, true },
    { "7234.101562", 7234.1015625, true },
    { "11664.148438", 11664.1484375, true },
    { "15726.289062", 15726.2890625, true },
    { "31485.726562", 31485.7265625, true },
    { "34181.476562", 34181.4765625, true },
    { "37057.335938", 37057.3359375, true },
    { "38893.960938", 38893.9609375, true },
    { "49787.492188", 49787.4921875, true },
    { "49981.710938", 49981.7109375, true },
    { "50639.476562", 50639.4765625, true },
    { "50787.757812", 50787.7578125, true },
    { "53012.335938", 53012.3359375, true },
    { "53502.335938", 53502.3359375, true },
    { "71037.335938", 71037.3359375, true },
    { "71514.976562", 71514.9765625, true },
    { "71914.835938", 71914.8359375, true },
    { "79660.007812", 79660.0078125, true },
    { "81836.382812", 81836.3828125, true },
    { "98836.867188", 98836.8671875, true },
    { "99998.398438", 99998.3984375, true },
    { "109467.132812", 109467.1328125, true },
    { "125419.585938", 125419.5859375, true },
    { "0.000003", 3.000000106112566e-06, false },
    { "0.001945", 0.0019450000254437327, false },
    { "0.014003", 0.014003000222146511, false },
    { "0.090361", 0.09036099910736084, false },
    { "0.250243", 0.25024300813674927, false },
    { "0.355000", 0.35499998927116394, false },
    { "0.501631", 0.5016310214996338, false },
    { "0.655395", 0.655394971370697, false },
    { "5.729167", 5.7291669845581055, false },
    { "15.650000", 15.649999618530273, false },
    { "16.551600", 16.551599502563477, false },
    { "173.998901", 173.9989013671875, false },
    { "344.992218", 344.9922180175781, false },
    { "444.990814", 444.9908142089844, false },
    { "847.307495", 847.3074951171875, false },
    { "1752.702759", 1752.7027587890625, false },
    { "2428.807373", 2428.807373046875, false },
    { "3116.525879", 3116.52587890625, false },
    { "4955.778809", 4955.77880859375, false },
    { "6902.572266", 6902.572265625, false },
    { "11988.944336", 11988.9443359375, false },
    { "21385.541016", 21385.541015625, false },
    { "51576.433594", 51576.43359375, false },
    { "108924.703125", 108924.703125, false },
    { "1.000000", 1.0, false },
    { "118.000000", 118.0, false },
    { "755.000000", 755.0, false },
}


-- ── THE ENGINE'S FLOAT WRITER AND ITS TWO POSSIBLE READERS, MODELLED ─────────────────────
-- Measured from the save files (the GOLDEN pairs above): an XMLValueType.FLOAT is written as
-- its float32, to six decimals, ties to even. This model shares no code with production's
-- SGValues.nativeFloatImage: float32 here is string.pack's (fengari's 5.3; the game's 5.1 has
-- none, so production cannot use it), and G2 checks the model against every golden pair.
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
-- The C reader is not visible from Lua: it hands back the float32 of the text or a double of
-- it. Every reload row runs under both.
local READER = "float32"
local function readFloat(text)
    local d = tonumber(text)
    if READER == "float32" then return f32(d) end
    return d
end
local function isFloatPath(o, k)
    local pd = o.schema ~= nil and o.schema.paths[(string.gsub(k, "%(%d*%)", "(?)"))] or nil
    return pd ~= nil and pd.valueTypeId == "FLOAT"
end
local createXml, loadXml = XMLFile.create, XMLFile.load
local function faithful(o)
    if o == nil then return nil end
    local set, get = o.setValue, o.getValue
    function o:setValue(k, v)
        if type(v) == "number" and isFloatPath(self, k) then return set(self, k, writeFloat(v)) end
        return set(self, k, v)
    end
    function o:getValue(k, d)
        local v = get(self, k, d)
        if type(v) == "string" and isFloatPath(self, k) then return readFloat(v) end
        return v
    end
    return o
end
XMLFile.create = function(...) return faithful(createXml(...)) end
XMLFile.load = function(...) return faithful(loadXml(...)) end
XMLFile.loadIfExists = XMLFile.load

local function printed(fn)
    local lines, orig = {}, print
    print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(fn)
    print = orig
    if not ok then error(err, 0) end
    return lines
end
local function lineWith(lines, pattern) for _, l in ipairs(lines) do if l:find(pattern, 1, true) then return l end end return nil end
local function digits(text) return tonumber((text:gsub("%.", ""))) end
local IMAGE = SGValues.nativeFloatImage

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE IMAGE AGAINST WHAT THE ENGINE WROTE
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    local okV, okD, okF, okModel, tiesUp, tiesDown, firstBad = 0, 0, 0, 0, 0, 0, nil
    for _, g in ipairs(GOLDEN) do
        local text, v, tie = g[1], g[2], g[3]
        local want = digits(text)
        if IMAGE(v) == want then okV = okV + 1 elseif firstBad == nil then firstBad = text .. ":v=" .. tostring(IMAGE(v)) end
        if IMAGE(tonumber(text)) == want then okD = okD + 1 elseif firstBad == nil then firstBad = text .. ":double=" .. tostring(IMAGE(tonumber(text))) end
        if IMAGE(f32(tonumber(text))) == want then okF = okF + 1 elseif firstBad == nil then firstBad = text .. ":float32=" .. tostring(IMAGE(f32(tonumber(text)))) end
        if writeFloat(v) == text then okModel = okModel + 1 elseif firstBad == nil then firstBad = text .. ":model=" .. writeFloat(v) end
        if tie then
            if digits(text) > math.floor(v * 1000000) then tiesUp = tiesUp + 1 else tiesDown = tiesDown + 1 end
        end
    end
    local n = #GOLDEN
    T.eq("G1 NAMED: production's image of every float32 the engine wrote, and of its text read back as a double and as a float32, is the written text's count of millionths",
        okV .. "/" .. okD .. "/" .. okF .. " of " .. n .. " " .. tostring(firstBad), n .. "/" .. n .. "/" .. n .. " of " .. n .. " nil")
    T.eq("G2 the bench's own writer model reproduces every text the engine wrote, so the reload rows below write what the engine writes",
        okModel .. " of " .. n, n .. " of " .. n)
    T.eq("G3 the pairs hold ties both ways (to even: some up, some down), so a tie rule that always rounds one way fails G1",
        tostring(tiesUp > 0) .. "/" .. tostring(tiesDown > 0) .. "/" .. (tiesUp + tiesDown), "true/true/25")
    T.eq("G4 the edges: not a number, an infinity and NaN give nil; zero and a level far below six decimals give 0; a negative level is the negative of its image",
        tostring(IMAGE("1")) .. "/" .. tostring(IMAGE(math.huge)) .. "/" .. tostring(IMAGE(0 / 0)) .. "/" .. tostring(IMAGE(0)) .. "/" .. tostring(IMAGE(1e-40)) .. "/" .. tostring(IMAGE(-3000.37) == -IMAGE(3000.37)),
        "nil/nil/nil/0/0/true")
    T.eq("G5 a level and its own float32 have one image; levels one float32 step apart do not",
        tostring(IMAGE(3000.37) == IMAGE(f32(3000.37))) .. "/" .. tostring(IMAGE(3000.3701171875) == IMAGE(3000.3701171875 + 2 ^ -12)),
        "true/false")
end)

-- ── the trailer world: a property producer, as a domain owner registers one ──────────────
local PROP = "m206.origin"
local function origin(value, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "m206", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { o = value } }
end
local originSpec = { schemaVersion = 1, producerId = "m206", residency = "STORED",
    validate = function() return true end,
    combine = function(_, contributions, before)
        local total, w = 0, 0
        for _, c in ipairs(contributions) do local p = c.properties[PROP] total = total + c.amount if p and p.payload then w = w + p.payload.o * c.amount end end
        if before then local p = before.properties[PROP] total = total + before.observedAmount if p and p.payload then w = w + p.payload.o * before.observedAmount end end
        if total == 0 then return nil, "NO_MATERIAL" end
        return origin(w / total, total)
    end,
    transform = function() return nil end, disclosure = function(_, r) return r end }
local function bootP(build, dir)
    ENGINE_PLANE.cells = {}
    local m = newMission(dir)
    g_server = {}
    g_currentMission = m
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local w = {}
    build(m, w)
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    local lease = m.stockGuard.registerProperty(PROP, originSpec)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, sg, NH.current, w, lease
end
local BOTH = { [ENGINE_FT.WHEAT] = true, [ENGINE_FT.BARLEY] = true }
local function trailerIn(m, level)
    local v = ENGINE_NEW_TRAILER("vehicle:trailer", { level = level, fillType = ENGINE_FT.WHEAT, capacity = 50000, supported = BOTH })
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function saveTrailer(m, sg, v, dir)
    local xml = XMLFile.create("vehicles", dir .. "/vehicles.xml", "vehicles", Vehicle.xmlSchemaSavegame)
    ENGINE_SAVE_VEHICLE(v, xml, VKEY, {})
    xml:save()
    sg:onSaveToXML(m.missionInfo)
    return xml
end
--- FillUnit's load shape (FillUnit.lua:369-371): onPostLoad reads #fillLevel through getValue and
--- adds it with addFillUnitFillLevel.
local function loadTrailer(m, dir)
    local xml = XMLFile.load("vehicles", dir .. "/vehicles.xml", Vehicle.xmlSchemaSavegame)
    local v = trailerIn(m, 0)
    ENGINE_POST_LOAD_VEHICLE(v, { xmlFile = xml, key = VKEY, resetVehicles = false })
    return v
end
local LEVEL_KEY = VKEY .. ".fillUnit.unit(0)#fillLevel"
local TYPE_KEY = VKEY .. ".fillUnit.unit(0)#fillType"
--- One save and reload of a trailer holding `level` L of wheat with a published record. The
--- result: the written text, the reloaded level, and what SG-1 made of the saved stock.
local function trailerRound(level, reader, dir, edit)
    READER = reader
    local m, sg, _, w, lease = bootP(function(m, w) w.trailer = trailerIn(m, level) end, dir)
    local id = hopperId(w.trailer)
    local s0 = stockAt(sg, id)
    local pub = s0 and m.stockGuard.publishProperties(lease, { { stockRef = sg.operations:stockRef(s0), expectedPropertyRevision = 0, record = origin(0.42, s0.observedAmount) } })
    local savedId, savedAmount = s0 and s0.stockId, s0 and s0.observedAmount
    local xml = saveTrailer(m, sg, w.trailer, dir)
    local text = xml.data[LEVEL_KEY]
    if edit ~= nil then edit(ENGINE_DISK[dir .. "/vehicles.xml"]) end
    local m2, sg2, w2
    local lines = printed(function()
        FSBaseMission.delete(m)
        m2, sg2, _, w2 = bootP(function(mm, ww) ww.trailer = loadTrailer(mm, dir) end, dir)
    end)
    local s = stockAt(sg2, hopperId(w2.trailer))
    local p = s and s.properties[PROP]
    local r = {
        bound = s0 ~= nil and pub ~= nil, savedAmount = savedAmount, text = text, level = w2.trailer:getFillUnitFillLevel(1),
        reattached = s ~= nil and s.stockId == savedId, knowledge = s and s.knowledge, reason = s and s.reason,
        prop = p and p.payload and p.payload.o, retired = sg2.operations.retiredStocks[savedId] and sg2.operations.retiredStocks[savedId].retireReason,
        line = lineWith(lines, "restored stocks:"),
    }
    FSBaseMission.delete(m2)
    return r
end
local function verdict(r)
    return tostring(r.reattached) .. "/" .. tostring(r.knowledge) .. "/" .. tostring(r.reason) .. "/" .. tostring(r.prop) .. "/" .. tostring(r.retired)
end

-- ══════════════════════════════════════════════════════════════════════════
-- F. A FILL UNIT THROUGH THE ENGINE'S SAVE AND A FRESH MISSION
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local a = trailerRound(3000.37, "float32", "m206f1")
    T.eq("F0 [reached] main.lua's load path bound the trailer with 3000.37 L and its record; the vehicles file holds the engine's text, the float32 to six decimals",
        tostring(a.bound) .. "/" .. tostring(a.savedAmount) .. "/" .. tostring(a.text), "true/3000.37/3000.370117")
    T.eq("F1 NAMED [entry point]: read back as a float32 (3000.3701171875, not 3000.37), the saved stock REATTACHES with its knowledge, the reason it was saved with and its record, and the load line counts it",
        string.format("%.17g", a.level) .. " " .. verdict(a) .. " | " .. tostring(a.line),
        "3000.3701171875 true/KNOWN/INITIAL_OBSERVATION/0.42/nil | [StockGuard] save: restored stocks: 1 reattached, 0 mismatched (RESTORE_MISMATCH), 0 kept as history, 0 superseded")
    local b = trailerRound(3000.37, "double", "m206f2")
    T.eq("F2 NAMED: read back as a double (3000.370117), it reattaches the same",
        string.format("%.17g", b.level) .. " " .. verdict(b), "3000.370117 true/KNOWN/INITIAL_OBSERVATION/0.42/nil")
    local c1, c2 = trailerRound(2000, "float32", "m206f3a"), trailerRound(2000, "double", "m206f3b")
    T.eq("F3 [control] a whole-number level is written exactly and reattaches under both readers (on today's code too)",
        c1.text .. " " .. verdict(c1) .. " " .. verdict(c2), "2000.000000 true/KNOWN/INITIAL_OBSERVATION/0.42/nil true/KNOWN/INITIAL_OBSERVATION/0.42/nil")
    -- The smallest change the save can carry at 3000 L is one float32 step (2^-12 L): a change of
    -- one written millionth maps back onto the same float32 and is no change native can make.
    local stepped = writeFloat(3000.3701171875 + 2 ^ -12)
    local d = trailerRound(3000.37, "float32", "m206f4", function(disk) disk[LEVEL_KEY] = stepped end)
    T.eq("F4 a native level one float32 step away at load (" .. stepped .. ") is RESTORE_MISMATCH: UNKNOWN, the saved stock kept as history, the record not carried, the line counts it",
        verdict(d) .. " | " .. tostring(d.line),
        "false/UNKNOWN/RESTORE_MISMATCH/nil/RESTORE_MISMATCH | [StockGuard] save: restored stocks: 0 reattached, 1 mismatched (RESTORE_MISMATCH), 0 kept as history, 0 superseded")
    local e = trailerRound(3000.37, "double", "m206f5", function(disk) disk[TYPE_KEY] = "BARLEY" end)
    T.eq("F5 the same level of another material at load is RESTORE_MISMATCH", verdict(e), "false/UNKNOWN/RESTORE_MISMATCH/nil/RESTORE_MISMATCH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A COMBINE'S DELAY AND STRAW SLOTS, THROUGH SGCombineBufferSave's OWN FLOAT PATH
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local results = {}
    local WANT_C = "6.2227404,6.2227404 true:nil true:nil | [StockGuard] save: restored stocks: 2 reattached, 0 mismatched (RESTORE_MISMATCH), 0 kept as history, 0 superseded"
    for _, reader in ipairs({ "float32", "double" }) do
        READER = reader
        Mission.getHarvestScaleMultiplier = function() return 1.0371234 end
        local dir = "m206c_" .. reader
        local m, sg, host, w = boot(function(m, w)
            w.combine = combineIn(m, "vehicle:delay", OPTS)
            w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
            ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
        end, dir)
        ENGINE_HARVEST_TICK(w.header, w.combine, 16)
        ENGINE_HARVEST_TICK(nil, w.combine, 40)
        local g0 = stockAt(sg, slotId(w.combine, NA.KIND_DELAY_SLOT, 1))
        local s0 = stockAt(sg, slotId(w.combine, NA.KIND_STRAW_SLOT, 1))
        local ids = { g0 and g0.stockId, s0 and s0.stockId }
        local amounts = (g0 and string.format("%.17g", g0.observedAmount) or "nil") .. "," .. (s0 and string.format("%.17g", s0.observedAmount) or "nil")
        saveWorld(m, sg, w.combine, dir)
        local m2, sg2, w2
        local lines = printed(function()
            m2, sg2, _, w2 = reload(m, dir, function(mm, ww)
                ww.combine = loadCombine(mm, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 50, lastValid = FillType.UNKNOWN }, dir)
                ww.header = headerIn(mm, "vehicle:delayHeader", ww.combine, HEADER)
            end)
        end)
        local g = stockAt(sg2, slotId(w2.combine, NA.KIND_DELAY_SLOT, 1))
        local s = stockAt(sg2, slotId(w2.combine, NA.KIND_STRAW_SLOT, 1))
        results[reader] = amounts .. " " .. tostring(g ~= nil and g.stockId == ids[1]) .. ":" .. tostring(g and g.reason) .. " " .. tostring(s ~= nil and s.stockId == ids[2]) .. ":" .. tostring(s and s.reason)
            .. " | " .. tostring(lineWith(lines, "restored stocks:"))
        FSBaseMission.delete(m2)
        Mission.getHarvestScaleMultiplier = function() return 1 end
    end
    T.eq("C1 NAMED: a delay slot and a straw slot holding 6.2227404 L (a harvest scale of 1.0371234: seven decimals, so neither reader gives it back) reattach after the save, read back as a float32",
        results.float32, WANT_C)
    T.eq("C2 and read back as a double, the same on its own", results.double, WANT_C)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ADAPTER MEMBER AND THE REGISTRY
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    READER = "double"
    local m, sg, _, w = bootP(function(m, w)
        w.trailer = trailerIn(m, 3000.37)
        w.combine = combineIn(m, "vehicle:c", OPTS)
    end, "m206a")
    local carrier = sg.operations.carriers[hopperId(w.trailer)]
    local lease = sg.operations.registry:get(SGRegistry.KIND_CARRIER_ADAPTER, carrier.adapterId)
    local image = lease and lease.spec.restoredQuantityImage
    local function show(x) return type(x) == "number" and string.format("%.0f", x) or tostring(x) end
    -- A storage and a ground cell by their kind alone: the member reads nothing else of a binding.
    local storage = { sourceDescriptor = { kind = NA.KIND_STORAGE } }
    local ground = { sourceDescriptor = { kind = NA.KIND_GROUND } }
    T.eq("A1 the native adapter supplies restoredQuantityImage: the image for a fill unit, a delay slot, a straw slot and a storage; nil for a ground cell, which compares as a number",
        show(image ~= nil and image(NA.fillUnitBinding(w.trailer, 1), 3000.37)) .. "/" .. show(image ~= nil and image(NA.combineSlotBinding(w.combine, NA.KIND_DELAY_SLOT, 1), 3000.37))
            .. "/" .. show(image ~= nil and image(NA.combineSlotBinding(w.combine, NA.KIND_STRAW_SLOT, 1), 3000.37)) .. "/" .. show(image ~= nil and image(storage, 3000.37)) .. "/" .. show(image ~= nil and image(ground, 3000.37)),
        "3000370117/3000370117/3000370117/3000370117/nil")
    FSBaseMission.delete(m)
    local reg = SGRegistry.new("m206")
    local function spec(extra)
        local s = { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end, readNativeState = function() end, enumerateCarriers = function() return {} end, hasAccess = function() return true end }
        for k, v in pairs(extra) do s[k] = v end
        return s
    end
    local _, why = reg:registerCarrierAdapter("bad", spec({ restoredQuantityImage = 7 }))
    local good = reg:registerCarrierAdapter("good", spec({ restoredQuantityImage = function() return 1 end }))
    T.eq("A2 the registry refuses a restoredQuantityImage that is not a function and takes one that is", tostring(why) .. "/" .. tostring(good ~= nil), "OPTIONAL_CALLBACKS/true")
end)
end
MAINT206_BENCH()
