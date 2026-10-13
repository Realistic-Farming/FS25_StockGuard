-- SG2-5bc-buffer_save_spec_test.lua
--
-- SG2-5bc-save (Bob's intake, Desk Office/Drafts/BOB-INTAKE-SG-5BC-SAVE-2026-10-04.md; SG-2 :144, :247):
-- a Tedder work area's remainder (workArea.litersToDrop) and a Mower drop area's (dropArea.litersToDrop
-- as dropArea.fillType) survive a save together with SG-1's binding to them and, for the Mower, the
-- fresh litres still waiting for Soil's birth at the deposit. Native saves neither and zeroes both at
-- load (Tedder.lua:242, Mower.lua:482), and on ae630364 the adapter refuses both bindings at restore
-- (NOT_RESTORABLE), so each saved stock stays history and the remainder is gone.
--
-- EVERY LAUNCH IS A NEW GAME PROCESS (MAINTENANCE row 214's launch header): ENGINE_NEW_PROCESS() sources
-- the prelude, the engine models, every file main.lua sources and main.lua itself into a brand-new
-- global table. Only the save directory's files cross from one launch to the next.
--
-- THE ENTRY-POINT BAR IS GROUP M: main.lua's install in each new process; a tedder and a mower built to
-- vehicleTypes.xml's composition (baseGroundTool's workArea, no fill unit), their work areas loaded
-- through each class's loadWorkAreaFromXML (the buffers zeroed); the engine's order (mission00.lua
-- :290-307 queues the additional files, whose finish at :356 loads the placeables and then the vehicles,
-- :604-612, so a vehicle's onPostLoad, raised through its class table, runs after loadMission00Finished
-- and before the barrier); the work through each machine's captured pointer; the savegame controller's
-- own save path (every vehicle through Vehicle:saveToXMLFile's specialization loop, StockGuard's
-- envelope through its save hook); and the barrier (FSBaseMission.onFinishedLoading's wrapper). Launch
-- A leaves a remainder in each machine (the drop reach blocked), the mower's with a fresh share and a
-- picked-up share carrying Soil's record; launch B reattaches both and drops part of each through one
-- open pixel, then saves; launch C reattaches both at the reduced levels. No entry, carrier, stock,
-- binding, save key or schema path is written by hand.
--
-- Groups:
--   M  the entry-point bar: three launches, two machines
--   U  the install: the class hooks, the savegame paths, and what a save writes
--   K  another configuration at the load: nothing restored, logged once, the stocks kept as history
--   L  another work-area layout, or another drop binding in the same layout, at the load: the same
--   H  a save edited by hand: another version, an index naming another area, an unknown fill type
--   R  a savegame flagged resetVehicles: nothing restored
--   N  an empty buffer writes no element and restores nothing
--   C  a client's post-load does nothing
--   S  the second savegame of one game session: the specializations sourced again into new class tables
--      (SpecializationManager.lua:68-95 from loadMapData, MPLoadingScreen.lua:352) while StockGuard is
--      not (mods.lua:976); the save made there still carries the buffers, and the next launch reattaches
--
--!launch: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, tools/test/lua/SG2-5bc-field_tool_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepCopy(x) end
    return t
end

-- ── one game launch: runs inside a new process, in the mod's environment ─────────────────────
-- plan = { dir, index, rounds = { round, ... } }. A round is one mission:
--   { keys = uid -> vehicles.xml key (load from the save), work = "A"|"B"|"EMPTY", save = bool,
--     tedder = opts, mower = opts (ENGINE_NEW_TEDDER / ENGINE_NEW_MOWER), resetVehicles = bool,
--     clientPostLoad = bool, resource = bool (the specializations sourced again first) }
local LAUNCH = [==[
local plan = ...
local REAL = getmetatable(_G).__index
local NA = SGNativeAdapters
local function engine(name, value) REAL[name] = value end
local lines = {}
local origPrint = REAL.print
REAL.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
local GRASS_W, DRY_W = FillType.GRASS_WINDROW, FillType.DRYGRASS_WINDROW

local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

-- Soil's published surface, as a recorder (the SG2-5c bench's): every call kept in order.
local SOIL = { calls = {}, seq = 0 }
local function soilOn(m)
    local gc = {}
    gc.admitPrimitive = function(...)
        local footprint, kind = ...
        SOIL.calls[#SOIL.calls + 1] = { fn = "admit", kind = kind }
        SOIL.seq = SOIL.seq + 1
        return { status = "ADMITTED", leaseToken = "SFGC-bench-" .. SOIL.seq }
    end
    gc.deliverMovement = function(...)
        local token, obs = ...
        SOIL.calls[#SOIL.calls + 1] = { fn = "deliver", token = token, obs = obs }
        return { status = "OK" }
    end
    gc.closePrimitive = function(...)
        SOIL.calls[#SOIL.calls + 1] = { fn = "close" }
        return true
    end
    m.soilFertilityManager = { groundCondition = gc,
        getCapabilities = function() return { groundCondition = { admissionRevision = 2 } } end }
end

local function newMission(saveDir, index)
    local m = setmetatable({ _server = true, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, time = 1000,
        terrainSize = 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND, tireTrackSystem = ENGINE_TIRE_TRACKS,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = index, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    soilOn(m)
    return m
end

-- The owner, as `soil.groundCondition` (the SG2-5c bench's stand-in, with Soil #1082's pending rule:
-- litres a settle names as pending fresh are left out of the floor; and the SG2-5b bench's transform,
-- which carries the floor through the hay basis). Resident on ground: a GROUND_CELL is KNOWN, c = 7.
local PID = "soil.groundCondition"
local HAY = "NATIVE_HAY_CONVERT_V1"
local function record(amount, c)
    return { propertyId = PID, schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN",
             knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { c = c } }
end
local function mix(ctx, contributions, before)
    local mine = ctx and ctx.report and ctx.report.outcomeEvidence and ctx.report.outcomeEvidence[PID] or nil
    local pf = mine and mine.pendingFresh or nil
    local byRef = {}
    for _, e in ipairs(pf and pf.allocations or {}) do byRef[ctx.operationId .. ":a" .. tostring(e.allocation)] = e.litres end
    local total, w, known = 0, 0, 0
    local function add(amount, p)
        if amount <= 1e-9 then return end
        total = total + amount
        if p and p.knowledge ~= "UNAVAILABLE" and p.payload then w = w + p.payload.c * amount known = known + amount end
    end
    for _, c in ipairs(contributions) do add(c.amount - (byRef[c.allocationRef] or 0), c.properties[PID]) end
    if before ~= nil then add(before.observedAmount - (pf and pf.destinationBefore or 0), before.properties[PID]) end
    if total == 0 then return nil, "NO_MATERIAL" end
    if known == 0 then return nil, "NO_KNOWN_INPUT" end
    local r = record(known, w / known)
    r.basisAmount = total
    r.knowledge = known >= total - 1e-6 and "KNOWN" or "PARTIAL"
    return r
end
local OWNER = {
    schemaVersion = 1, producerId = "soil", residency = "OWNER_RESOLVED", applicability = { residentStoreKinds = { "ground" } },
    validate = function() return true end,
    combine = mix,
    transform = function(ctx, contributions, destinations)
        local hay = false
        for _, c in ipairs(contributions) do
            if c.conversionBasisId == HAY then hay = true elseif c.conversionBasisId ~= nil then return nil, "BASIS" end
        end
        if not hay then return nil, "NO_BASIS" end
        local d = destinations[1]
        return mix(ctx, contributions, d and d.destinationBefore or nil)
    end,
    disclosure = function(_, r) return r end,
    resolveResident = function(ctx)
        local fp = ctx.footprint
        if type(fp) ~= "table" or fp.kind ~= "GROUND_CELL" then return nil, "NOT_RESIDENT" end
        return record(ctx.amount, 7)
    end,
    getResidentRevision = function() return "rev:1" end,
}

engine("g_savegameController", SavegameController.new())

-- The world's helpers, in one table (the chunk's locals are budgeted).
local W = {}
--- Fill (on) or clear (off) every pixel of the box with BARLEY at the most raw units a pixel holds:
--- the line model drops only onto empty pixels or its own type, so a blocked reach takes nothing.
function W.block(wx0, wz0, wx1, wz1, on)
    local maxRaw = 2 ^ ENGINE_MAPS[ENGINE_HEIGHT_ID].heightNumChannels - 1
    local x0, z0 = ENGINE_GROUND.cellOf(wx0, wz0)
    local x1, z1 = ENGINE_GROUND.cellOf(wx1, wz1)
    for x = x0, x1 do for z = z0, z1 do ENGINE_GROUND.put(x, z, ENGINE_HT.BARLEY.index, on and maxRaw or 0) end end
end
--- The two drop reaches (each line's whole radius, 4 m), blocked; `open` clears the nearest pixel of
--- each line, which takes at most stepRaw raw units a call (a partial drop).
function W.blockDrops(open)
    W.block(3.5, 25.5, 14.5, 34.5, true)
    W.block(15.5, -4.5, 26.5, 4.5, true)
    if open then
        local tx, tz = ENGINE_GROUND.cellOf(8.1, 29.9)
        local mx, mz = ENGINE_GROUND.cellOf(20.1, -0.1)
        ENGINE_GROUND.put(tx, tz, 0, 0)
        ENGINE_GROUND.put(mx, mz, 0, 0)
    end
end
function W.cid(b) return b ~= nil and SGRecords.carrierKeyString(b.carrierKey) or nil end
function W.binding(kind, v)
    if v == nil then return nil end
    if kind == "tedder" then return NA.tedderBufferBinding(v, 1) end
    return NA.mowerBufferBinding(v, 2)
end
--- What one machine's buffer holds now: native, the StockGuard entry, and the stock.
function W.snap(sg, kind, v)
    if v == nil then return {} end
    local id = W.cid(W.binding(kind, v))
    local entries = kind == "tedder" and NA.tedderBuffers or NA.mowerBuffers
    local e = id ~= nil and entries[id] or nil
    local c = id ~= nil and sg.operations.carriers[id] or nil
    local s = c ~= nil and c.stockId ~= nil and sg.operations.stocks[c.stockId] or nil
    local p = s ~= nil and s.properties[PID] or nil
    local area = kind == "tedder" and v.spec_workArea.workAreas[1] or v.spec_workArea.workAreas[2]
    local restore = (kind == "tedder" and v.spec_tedder or v.spec_mower).sgBufferRestore
    return { held = area.litersToDrop, last = area.lastDropFillType, fillType = area.fillType, lineOffset = kind == "tedder" and v.spec_workArea.workAreas[2].lineOffset or area.dropLineOffset,
        workAreaIndex = area.workAreaIndex, entry = e ~= nil, fresh = e and e.fresh, soilFramed = e and e.soilFramed, entryType = e and e.fillTypeName,
        id = s and s.stockId, knowledge = s and s.knowledge, reason = s and s.reason, amount = s and s.observedAmount,
        material = s and s.materialRef and s.materialRef.fillTypeName,
        record = p ~= nil and (tostring(p.knowledge) .. ":" .. string.format("%g", p.payload and p.payload.c or -1)) or "none",
        lastName = g_fillTypeManager:getFillTypeNameByIndex(area.lastDropFillType), typeName = area.fillType ~= nil and g_fillTypeManager:getFillTypeNameByIndex(area.fillType) or nil,
        restored = restore and restore.restored, unresolved = restore and table.concat(restore.unresolved, ","), seeded = restore and restore.seeded }
end

local function round(r)
    local first = #lines + 1
    if r.resource then ENGINE_RESOURCE_FIELD_TOOLS() end
    ENGINE_GROUND.reset()
    ENGINE_PLANE.cells = {}
    SOIL.calls = {}
    local m = newMission(plan.dir, plan.index)
    engine("g_server", {})
    engine("g_currentMission", m)
    -- MPLoadingScreen.lua:767 and :776: the savegame schema built fresh, then every specialization's
    -- initSpecialization through its class table.
    Vehicle.init()
    g_specializationManager:initSpecializations()
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    m.stockGuard.registerProperty(PID, OWNER)
    Mission00.loadMission00Finished(m)
    -- The queued loading tasks (mission00.lua:356, :604-612): the vehicles, each with its onPostLoad.
    local xml = nil
    if r.keys ~= nil then xml = REAL.XMLFile.load("vehiclesXML", plan.dir .. "/vehicles.xml", REAL.Vehicle.xmlSchemaSavegame) end
    local w = {}
    local function add(uid, v)
        m._vehicles[#m._vehicles + 1] = v
        w[uid] = v
        local key = r.keys ~= nil and r.keys[uid] or nil
        local savegame = key ~= nil and { xmlFile = xml, key = key, resetVehicles = r.resetVehicles == true } or nil
        if r.clientPostLoad then engine("g_server", nil) end
        ENGINE_POST_LOAD_VEHICLE(v, savegame)
        if r.clientPostLoad then engine("g_server", {}) end
        return v
    end
    local supported = { [GRASS_W] = true, [DRY_W] = true }
    add("vehicle:tg", ENGINE_NEW_TIPPER("vehicle:tg", { level = r.keys == nil and 100 or 0, fillType = GRASS_W, at = { x = 0, z = 30 }, supported = supported }))
    add("vehicle:td", ENGINE_NEW_TIPPER("vehicle:td", { level = r.keys == nil and 100 or 0, fillType = DRY_W, at = { x = 0, z = 0 }, supported = supported }))
    add("vehicle:tedder", ENGINE_NEW_TEDDER("vehicle:tedder", r.tedder))
    add("vehicle:mower", ENGINE_NEW_MOWER("vehicle:mower", r.mower))
    m:onFinishedLoading()
    local out = { epoch = sg.loadEpoch, loaded = { tedder = W.snap(sg, "tedder", w["vehicle:tedder"]), mower = W.snap(sg, "mower", w["vehicle:mower"]) },
                  retired = {} }
    if r.work == "A" or r.work == "EMPTY" then
        -- Launch A: a grass windrow under the tedder, a dry one and a meadow under the mower; with the
        -- drop reaches blocked each pass keeps what it took (EMPTY: unblocked, each drops it all).
        ENGINE_TIP(w["vehicle:tg"], 100)
        ENGINE_TIP(w["vehicle:td"], 100)
        ENGINE_PLANE.sow(FruitType.MEADOW, -1, -1, 1, 1, 4)
        if r.work == "A" then W.blockDrops(false) end
        ENGINE_TEDDER_TICK(w["vehicle:tedder"])
        ENGINE_MOWER_TICK(w["vehicle:mower"])
    elseif r.work == "B" then
        -- Launch B: one pixel of each reach open; a pass over bare ground drops what fits of each remainder.
        W.blockDrops(true)
        SOIL.calls = {}
        out.before = { tedder = W.snap(sg, "tedder", w["vehicle:tedder"]), mower = W.snap(sg, "mower", w["vehicle:mower"]) }
        ENGINE_TEDDER_TICK(w["vehicle:tedder"])
        ENGINE_MOWER_TICK(w["vehicle:mower"])
        out.delivers = {}
        for _, c in ipairs(SOIL.calls) do if c.fn == "deliver" then out.delivers[#out.delivers + 1] = c.obs end end
    end
    out.worked = { tedder = W.snap(sg, "tedder", w["vehicle:tedder"]), mower = W.snap(sg, "mower", w["vehicle:mower"]) }
    for id, h in pairs(sg.operations.retiredStocks) do out.retired[id] = tostring(h.retireReason) end
    if r.save then
        ENGINE_SAVE.finalDir = plan.dir
        REAL.g_savegameController:saveSavegame(m.missionInfo, false)
        ENGINE_RUN_FRAMES(nil)
        out.keys = {}
        for i, v in ipairs(m._vehicles) do out.keys[v.uniqueId] = string.format("vehicles.vehicle(%d)", i - 1) end
    end
    out.hooks = { tedderSave = rawget(Tedder, SGFieldToolBufferSave ~= nil and SGFieldToolBufferSave.MARKER or "?") ~= nil,
                  mowerSave = rawget(Mower, SGFieldToolBufferSave ~= nil and SGFieldToolBufferSave.MARKER or "?") ~= nil,
                  tedderPath = REAL.Vehicle.xmlSchemaSavegame.paths["vehicles.vehicle(?).tedder.stockGuardBuffer.area(?)#litersToDrop"] ~= nil,
                  mowerPath = REAL.Vehicle.xmlSchemaSavegame.paths["vehicles.vehicle(?).mower.stockGuardBuffer.dropArea(?)#fresh"] ~= nil }
    out.xmlErrors = ENGINE_XML_ERRORS
    FSBaseMission.delete(m)
    out.lines = {}
    for i = first, #lines do out.lines[#out.lines + 1] = lines[i] end
    return out
end

local results = {}
local ok, err = pcall(function()
    for i, r in ipairs(plan.rounds) do results[i] = round(r) end
end)
REAL.print = origPrint
if not ok then error(err, 0) end
return results
]==]

--- One new game process on `disk`: its rounds' results and the disk it leaves.
local function launch(disk, plan)
    local G, E = ENGINE_NEW_PROCESS()
    G.ENGINE_DISK = deepCopy(disk or {})
    local run = assert(load(LAUNCH, "=SG2-5bc launch", "t", E))
    local results = run(plan)
    return results, deepCopy(G.ENGINE_DISK)
end
local function one(disk, dir, index, r)
    local res, d = launch(disk, { dir = dir, index = index, rounds = { r } })
    return res[1], d
end

-- ── readers ───────────────────────────────────────────────────────────────────────────────
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
local function lineWith(lines, pattern) for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then return l end end return nil end
local function countLines(lines, pattern) local n = 0 for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then n = n + 1 end end return n end
local function counts(r)
    local l = lineWith(r.lines, "restored stocks:")
    return l and l:match("(%d+ reattached, %d+ mismatched)") or "no load line"
end
local function epochOf(r)
    local l = lineWith(r.lines, "mission handle published")
    return l and l:match("epoch (%d+)") or "?"
end
--- "material/amount/knowledge/record" of a snapshot's stock.
local function stockText(s) return tostring(s.material) .. "/" .. num(s.amount) .. "/" .. tostring(s.knowledge) .. "/" .. tostring(s.record) end
--- The vehicles file's keys under a vehicle key's buffer element (nil when there is none).
local function elementKeys(disk, dir, vkey, spec)
    local d = disk[dir .. "/vehicles.xml"]
    if d == nil then return nil end
    local prefix = vkey .. "." .. spec .. ".stockGuardBuffer"
    local out = {}
    for k, v in pairs(d) do if k:sub(1, #prefix) == prefix then out[k:sub(#prefix + 1)] = v end end
    return next(out) ~= nil and out or nil
end
--- The mower drop's delivery with a birth: "birth/total|record" as litres and the record's text.
local function birthSplit(obs)
    local c = obs and obs.contributions
    if c == nil then return nil end
    local born, rest, total, rec = 0, 0, 0, "none"
    for _, e in ipairs(c) do
        total = total + e.litres
        if e.birth ~= nil then born = born + e.litres else rest = rest + e.litres if e.record ~= nil then rec = tostring(e.record.knowledge) .. ":" .. string.format("%g", e.record.payload and e.record.payload.c or -1) end end
    end
    return { born = born, rest = rest, total = total, record = rec }
end
local function mowerDrop(r)
    for _, obs in ipairs(r.delivers or {}) do
        local s = birthSplit(obs)
        if s ~= nil and s.born > 0 then return s end
    end
    return nil
end

local A_ROUND = { work = "A", save = true }

-- ══════════════════════════════════════════════════════════════════════════
-- M. THE ENTRY-POINT BAR: THREE LAUNCHES, TWO MACHINES
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    local DIR = "s5bcm"
    local a, d1 = one(nil, DIR, 1, A_ROUND)
    local ta, ma = a.worked.tedder, a.worked.mower
    T.eq("M0 [reached] launch A: the tedder holds its pickup as dry grass and the mower its cut and the dry grass it took, each a stock with Soil's record; the mower's fresh share is the cut",
        num(ta.held) .. ":" .. stockText(ta) .. " " .. num(ma.held) .. ":" .. stockText(ma) .. " fresh " .. num(ma.fresh) .. " framed " .. tostring(ma.soilFramed),
        "100:DRYGRASS_WINDROW/100/KNOWN/KNOWN:7 500.74:GRASS_WINDROW/500.74/KNOWN/KNOWN:7 fresh 400.74 framed true")
    local te = elementKeys(d1, DIR, a.keys["vehicle:tedder"], "tedder")
    local me = elementKeys(d1, DIR, a.keys["vehicle:mower"], "mower")
    T.eq("M0b [reached] the save wrote each machine's element under its own spec key, the mower's level as the engine's FLOAT text",
        tostring(te and te[".area(0)#litersToDrop"]) .. " " .. tostring(te and te[".area(0)#fillType"]) .. " " .. tostring(me and me[".dropArea(0)#litersToDrop"]) .. " " .. tostring(me and me[".dropArea(0)#fresh"]),
        "100.000000 DRYGRASS_WINDROW 500.739990 400.739990")
    local b, d2 = one(d1, DIR, 1, { keys = a.keys, work = "B", save = true })
    local tb, mb = b.loaded.tedder, b.loaded.mower
    T.eq("M1 NAMED [entry point]: launch B, a new process, reattaches both buffers with launch A's stock ids and records, and the load line counts them",
        counts(b) .. " " .. tostring(tb.id == ta.id and tb.id ~= nil) .. " " .. tostring(mb.id == ma.id and mb.id ~= nil) .. " " .. stockText(tb) .. " " .. stockText(mb),
        "2 reattached, 0 mismatched true true DRYGRASS_WINDROW/100/KNOWN/KNOWN:7 GRASS_WINDROW/500.74/KNOWN/KNOWN:7")
    T.eq("M1b NAMED: the native remainders are back where native zeroed them, with the drop bindings, and the mower's fresh share and framing are back on its entry",
        num(tb.held) .. "/" .. tostring(tb.lastName) .. "/" .. tostring(tb.entryType) .. " " .. num(mb.held) .. "/" .. tostring(mb.typeName)
            .. "/" .. tostring(mb.workAreaIndex) .. " fresh " .. num(mb.fresh) .. " framed " .. tostring(mb.soilFramed) .. " offsets " .. num(tb.lineOffset) .. "/" .. num(mb.lineOffset),
        "100/DRYGRASS_WINDROW/DRYGRASS_WINDROW 500.74/GRASS_WINDROW/1 fresh 400.74 framed true offsets 1/1")
    local split = mowerDrop(b)
    local share = mb.fresh ~= nil and mb.held ~= nil and mb.held > 0 and mb.fresh / mb.held or nil
    T.eq("M2 NAMED: launch B drops part of each remainder through the open pixel; the mower drop's delivery to Soil births exactly the buffer's fresh share and carries the stock's record for the rest",
        tostring(b.worked.tedder.held < tb.held and b.worked.tedder.held > 0) .. " " .. tostring(b.worked.mower.held < mb.held and b.worked.mower.held > 0) .. " "
            .. tostring(split ~= nil and share ~= nil and math.abs(split.born - split.total * share) < 1e-6) .. " " .. tostring(split and split.record),
        "true true true KNOWN:7")
    local c = one(d2, DIR, 1, { keys = b.keys })
    local tc, mc = c.loaded.tedder, c.loaded.mower
    T.eq("M3 NAMED: launch C reattaches both again, the ids launch A's, at the levels launch B left, the mower's fresh share as its drop left it",
        counts(c) .. " " .. tostring(tc.id == ta.id) .. " " .. tostring(mc.id == ma.id) .. " " .. num(tc.held) .. "=" .. num(b.worked.tedder.held) .. " " .. num(mc.held) .. "=" .. num(b.worked.mower.held)
            .. " " .. num(mc.fresh) .. "=" .. num(b.worked.mower.fresh),
        "2 reattached, 0 mismatched true true " .. num(b.worked.tedder.held) .. "=" .. num(b.worked.tedder.held) .. " " .. num(b.worked.mower.held) .. "=" .. num(b.worked.mower.held)
            .. " " .. num(b.worked.mower.fresh) .. "=" .. num(b.worked.mower.fresh))
    T.eq("M4 [a new process each] every launch counted its epoch from the start", epochOf(a) .. epochOf(b) .. epochOf(c), "111")
    T.eq("M5 the save module's restore line, once per kind per process", countLines(b.lines, "FIRST TEDDER BUFFER RESTORED") .. countLines(b.lines, "FIRST MOWER BUFFER RESTORED") .. " " .. tostring(lineWith(b.lines, "could not be restored") == nil), "11 true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE INSTALL AND WHAT A SAVE WRITES
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local a, d1 = one(nil, "s5bcu", 2, A_ROUND)
    T.eq("U1 main.lua's install: the class hooks on Tedder and Mower, the savegame paths on this load's schema, and no XML error", tostring(a.hooks.tedderSave) .. "/" .. tostring(a.hooks.mowerSave) .. "/" .. tostring(a.hooks.tedderPath) .. "/" .. tostring(a.hooks.mowerPath) .. " " .. tostring(a.xmlErrors), "true/true/true/true 0")
    local te = elementKeys(d1, "s5bcu", a.keys["vehicle:tedder"], "tedder") or {}
    local me = elementKeys(d1, "s5bcu", a.keys["vehicle:mower"], "mower") or {}
    T.eq("U2 the tedder's element: version, configuration, layout, the area, its remainder, last drop type, drop binding and lineOffset, StockGuard's material",
        table.concat({ tostring(te["#version"]), tostring(te["#configFileName"]), tostring(te["#areaCount"]), tostring(te[".area(0)#index"]), tostring(te[".area(0)#lastDropFillType"]), tostring(te[".area(0)#dropIndex"]), tostring(te[".area(0)#lineOffset"]), tostring(te[".area(0)#fillType"]) }, " "),
        "1 data/vehicles/tedder.xml 1 1 DRYGRASS_WINDROW 2 1.000000 DRYGRASS_WINDROW")
    T.eq("U3 the mower's element: version, configuration, layout, the drop area, its type, the cut binding, dropLineOffset, fresh and framing",
        table.concat({ tostring(me["#version"]), tostring(me["#configFileName"]), tostring(me["#areaCount"]), tostring(me[".dropArea(0)#index"]), tostring(me[".dropArea(0)#fillType"]), tostring(me[".dropArea(0)#workAreaIndex"]), tostring(me[".dropArea(0)#dropLineOffset"]), tostring(me[".dropArea(0)#soilFramed"]) }, " "),
        "1 data/vehicles/mower.xml 1 2 GRASS_WINDROW 1 1.000000 true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K, L, R, C. A LOAD THAT MUST RESTORE NOTHING
-- ══════════════════════════════════════════════════════════════════════════
--- Launch A, then one load with `r` (keys added): nothing native, no entry, both saved stocks history.
local function refused(dir, index, r)
    local a, d1 = one(nil, dir, index, A_ROUND)
    r.keys = a.keys
    local b = one(d1, dir, index, r)
    local t, m = b.loaded.tedder, b.loaded.mower
    return a, b, num(t.held) .. "/" .. tostring(t.entry) .. " " .. num(m.held) .. "/" .. tostring(m.entry) .. " " .. tostring(b.retired[a.worked.tedder.id]) .. " " .. tostring(b.retired[a.worked.mower.id])
end
local HISTORY = "0/false 0/false CARRIER_ABSENT:UNRESOLVED:NOT_BOUND CARRIER_ABSENT:UNRESOLVED:NOT_BOUND"
group("K", function()
    local _, b, text = refused("s5bck", 3, { tedder = { configFileName = "data/vehicles/tedderWide.xml" }, mower = { configFileName = "data/vehicles/mowerWide.xml" } })
    T.eq("K1 NAMED: another configuration at the load restores nothing in either machine, and SG-1 keeps both saved stocks as history", text, HISTORY)
    T.eq("K2 the refusal is logged once per kind with its reason", tostring(b.loaded.tedder.unresolved) .. " " .. tostring(b.loaded.mower.unresolved) .. " "
        .. countLines(b.lines, "a saved tedder buffer could not be restored (CONFIGURATION)") .. countLines(b.lines, "a saved mower buffer could not be restored (CONFIGURATION)"), "CONFIGURATION CONFIGURATION 11")
end)
group("L", function()
    local _, b, text = refused("s5bcl", 4, { tedder = { extraPickup = true }, mower = { extraDrop = true } })
    T.eq("L1 NAMED: another work-area layout at the load (a second tedder area, a second mower drop area) restores nothing; both stocks history", text, HISTORY)
    T.eq("L2 the refusal's reason, per kind", tostring(b.loaded.tedder.unresolved) .. " " .. tostring(b.loaded.mower.unresolved), "AREA_LAYOUT AREA_LAYOUT")
    local _, b3, text3 = refused("s5bcl3", 9, { tedder = { dropTo = 3 }, mower = { cutDropsTo = 3 } })
    T.eq("L3 NAMED: the same configuration and area count with another binding (the tedder area dropping into another area, the mower's cut into another) restores nothing; both stocks history", text3, HISTORY)
    T.eq("L4 the refusal's reason, per kind", tostring(b3.loaded.tedder.unresolved) .. " " .. tostring(b3.loaded.mower.unresolved), "DROP_BINDING WORK_AREA_BINDING")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. A SAVE EDITED BY HAND
-- ══════════════════════════════════════════════════════════════════════════
-- One launch A, then one load per edit of its vehicles file: another version, an index naming
-- another area of the vehicle, a fill type name this game does not know.
group("H", function()
    local DIR = "s5bch"
    local a, d1 = one(nil, DIR, 10, A_ROUND)
    local tk = a.keys["vehicle:tedder"] .. ".tedder.stockGuardBuffer"
    local mk = a.keys["vehicle:mower"] .. ".mower.stockGuardBuffer"
    local function load(edits)
        local d = deepCopy(d1)
        local file = d[DIR .. "/vehicles.xml"]
        for k, v in pairs(edits) do file[k] = v end
        local b = one(d, DIR, 10, { keys = a.keys })
        local t, m = b.loaded.tedder, b.loaded.mower
        return num(t.held) .. "/" .. tostring(t.entry) .. " " .. num(m.held) .. "/" .. tostring(m.entry) .. " " .. tostring(t.unresolved) .. " " .. tostring(m.unresolved)
    end
    T.eq("H1 NAMED: another save version restores nothing", load({ [tk .. "#version"] = 2, [mk .. "#version"] = 2 }), "0/false 0/false VERSION VERSION")
    T.eq("H2 NAMED: an index naming another area of the vehicle (the tedder's drop area, the mower's cut area) restores nothing",
        load({ [tk .. ".area(0)#index"] = 2, [mk .. ".dropArea(0)#index"] = 1 }), "0/false 0/false AREA_INDEX AREA_INDEX")
    T.eq("H3 NAMED: a fill type name this game does not know restores nothing",
        load({ [tk .. ".area(0)#lastDropFillType"] = "NO_SUCH_TYPE", [mk .. ".dropArea(0)#fillType"] = "NO_SUCH_TYPE" }), "0/false 0/false FILL_TYPE FILL_TYPE")
end)
group("R", function()
    local _, b, text = refused("s5bcr", 5, { resetVehicles = true })
    T.eq("R1 NAMED: a savegame flagged resetVehicles restores nothing; both stocks history", text, HISTORY)
    T.eq("R2 and the save module says nothing", tostring(lineWith(b.lines, "field tool buffer save") == nil), "true")
end)
group("C", function()
    local _, b, text = refused("s5bcc", 6, { clientPostLoad = true })
    T.eq("C1 NAMED: a client's post-load restores nothing", text, HISTORY)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. AN EMPTY BUFFER
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    -- A whole-number converter factor: the model's line writes whole raw units, so a fractional cut
    -- would leave a sub-unit residue native keeps (and the save carries, as group M's launch C shows).
    local a, d1 = one(nil, "s5bcn", 7, { work = "EMPTY", save = true, mower = { factor = 200 } })
    T.eq("N0 [reached] with the reaches open each pass dropped everything it took", num(a.worked.tedder.held) .. " " .. num(a.worked.mower.held), "0 0")
    T.eq("N1 NAMED: an empty buffer writes no element", tostring(elementKeys(d1, "s5bcn", a.keys["vehicle:tedder"], "tedder") == nil) .. " " .. tostring(elementKeys(d1, "s5bcn", a.keys["vehicle:mower"], "mower") == nil), "true true")
    local b = one(d1, "s5bcn", 7, { keys = a.keys, mower = { factor = 200 } })
    T.eq("N2 and the next launch restores nothing and says nothing", num(b.loaded.tedder.held) .. " " .. num(b.loaded.mower.held) .. " " .. tostring(b.loaded.tedder.restored) .. " " .. tostring(lineWith(b.lines, "field tool buffer save") == nil), "0 0 nil true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SECOND SAVEGAME OF ONE GAME SESSION
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local DIR = "s5bcs"
    -- One process: a first mission, then (quit to the menu) the specializations sourced again into new
    -- class tables and a second mission that does launch A's work and saves. StockGuard is not sourced again.
    local res, d1 = launch(nil, { dir = DIR, index = 8, rounds = { { save = false }, { resource = true, work = "A", save = true } } })
    local second = res[2]
    T.eq("S0 [reached] the second mission ran on new Tedder and Mower class tables with StockGuard's hooks on them", tostring(second.hooks.tedderSave) .. "/" .. tostring(second.hooks.mowerSave), "true/true")
    T.eq("S1 NAMED: the second mission's savegame paths are registered and its save carries both buffers, with no XML error",
        tostring(second.hooks.tedderPath) .. "/" .. tostring(second.hooks.mowerPath) .. " " .. tostring(elementKeys(d1, DIR, second.keys["vehicle:tedder"], "tedder") ~= nil) .. " "
            .. tostring(elementKeys(d1, DIR, second.keys["vehicle:mower"], "mower") ~= nil) .. " " .. tostring(second.xmlErrors), "true/true true true 0")
    local c = one(d1, DIR, 8, { keys = second.keys })
    T.eq("S2 NAMED: the next launch reattaches both", counts(c) .. " " .. tostring(c.loaded.tedder.id == second.worked.tedder.id) .. " " .. tostring(c.loaded.mower.id == second.worked.mower.id), "2 reattached, 0 mismatched true true")
end)
