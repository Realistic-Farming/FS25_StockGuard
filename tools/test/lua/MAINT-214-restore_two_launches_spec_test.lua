-- MAINT-214-restore_two_launches_spec_test.lua
--
-- MAINTENANCE row 214 (Bob's intake, Desk Office/Drafts/BOB-INTAKE-SG-RESTORE-EPOCH-COLLISION-2026-10-03.md):
-- the load epoch is an in-memory counter (SG.new, StockGuard.lua:61) that restarts at "1" in every game
-- process, and a stock id is "st:" .. epoch .. ":" .. n. The enumeration at the restore-complete barrier mints
-- the live stocks' ids BEFORE the staged restore, in a deterministic order, so on the first load after a
-- launch an unchanged carrier's fresh stock carries the very id its saved stock holds. The reattach requires
-- that id to be free (SGOperations.lua restoreCore), so every stock fell to RESTORE_MISMATCH, UNKNOWN with
-- its records only history, and the history row was a twin of the live stock's id, which the next load's
-- validateCore refused (the whole envelope, written back unchanged, at every load after). The fix frees a
-- saved id a stock minted at this load holds before the walk, and drops twins a save already carries.
--
-- EVERY LAUNCH HERE IS A NEW GAME PROCESS: ENGINE_NEW_PROCESS() (the runner's launch header, MAINTENANCE
-- row 214) sources the prelude, the engine models, every file main.lua sources and main.lua itself into a
-- brand-new global table, so StockGuard's epoch, every module table and every class hook start over. Only
-- the save directory's files cross from one launch to the next. An in-process reload (the mission deleted
-- and a fresh one booted in the same process, as every earlier reload bench does) counts the epoch on to
-- "2" and hides the fault: group E shows it.
--
-- THE ENTRY-POINT BAR IS GROUP A: main.lua's install in each new process, three trailers' fill units
-- enumerated by the native adapter at the real barrier (FSBaseMission.onFinishedLoading's wrapper), a
-- property published by a registered producer, the savegame controller's own save path (careerSavegame.xml
-- and every mission vehicle through Vehicle:saveToXMLFile, StockGuard's envelope through its save hook),
-- then a second and a third launch on the same directory with the trailers rebuilt by FillUnit's onPostLoad
-- from vehicles.xml. No store, registry or id is populated by hand. On a95ee35 A1 reads "0 reattached, 3
-- mismatched" and A3 reads the envelope refused.
--
-- Groups:
--   A  three unchanged trailers through three launches (the entry-point bar)
--   B  a new trailer first in the vehicle order at the second launch (the ids mint in another order)
--   C  a real change between launches still reads RESTORE_MISMATCH, and leaves no twin
--   D  a save the trunk wrote at its second launch (a history twin of each live stock) loads
--   E  CONTROL: an in-process reload (epoch "2") reattached on the trunk too
--   R  restoreCore's first claim: a stock an earlier restore pass reattached keeps its id
--   G  the ground payload's twin guard, on GR.coreOf
--
-- NOT HERE: the ground's own restore pass through a native ground save across new processes: the engine's
-- height layer would have to be carried as well as the disk. The ground's records restore through the same
-- restoreCore (group R drives a second pass), and group G drives its twin guard on GR.coreOf.
--
--!launch: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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
-- plan = { dir, index, rounds = { round, ... } } where a round is
--   { vehicles = { { uid, level, ft }, ... }, keys = uid -> vehicles.xml key (load from the save),
--     publish = uid -> value, save = true }
-- A process runs its rounds in order; more than one round is an in-process reload (group E).
local LAUNCH = [==[
local plan = ...
local REAL = getmetatable(_G).__index
local NH, NA = SGNativeHost, SGNativeAdapters
local function engine(name, value) REAL[name] = value end
local lines = {}
local origPrint = REAL.print
REAL.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end

local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
Mission.onFinishedLoading = function(m) return "parent" end
local function newMission(saveDir, index)
    local m = setmetatable({ _server = true, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, time = 1000,
        terrainSize = 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND, tireTrackSystem = ENGINE_TIRE_TRACKS,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = index, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

-- a property producer, as a domain owner registers one
local PROP = "m214.origin"
local function origin(value, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "m214", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { o = value } }
end
local originSpec = { schemaVersion = 1, producerId = "m214", residency = "STORED",
    validate = function() return true end,
    combine = function() return nil, "NOT_IN_THIS_BENCH" end,
    transform = function() return nil end, disclosure = function(_, r) return r end }

local BOTH = { [ENGINE_FT.WHEAT] = true, [ENGINE_FT.BARLEY] = true }
engine("g_savegameController", SavegameController.new())

local function cid(v) local b = NA.fillUnitBinding(v, 1) return b and SGRecords.carrierKeyString(b.carrierKey) or nil end
local function stockOf(sg, v)
    local c = sg.operations.carriers[cid(v)]
    return c and c.stockId and sg.operations.stocks[c.stockId] or nil
end
local function envelopeIds(dir)
    local d = ENGINE_DISK[dir .. "/stockGuard.xml"]
    if d == nil then return nil end
    local tokens = {}
    for i = 1, d["stockGuard#count"] do tokens[i] = d[string.format("stockGuard.token(%d)#v", i - 1)] end
    local e = SGValues.decode(tokens)
    local out = { stocks = {}, historical = {} }
    for _, s in ipairs(e and e.coreValues and e.coreValues.stocks or {}) do out.stocks[#out.stocks + 1] = s.stockId end
    for _, s in ipairs(e and e.coreValues and e.coreValues.historical or {}) do out.historical[#out.historical + 1] = s.stockId end
    return out
end

local function round(r)
    local first = #lines + 1
    local m = newMission(plan.dir, plan.index)
    engine("g_server", {})
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local vs = {}
    local xml = nil
    if r.keys ~= nil then xml = REAL.XMLFile.load("vehiclesXML", plan.dir .. "/vehicles.xml", REAL.Vehicle.xmlSchemaSavegame) end
    for _, spec in ipairs(r.vehicles) do
        local key = r.keys ~= nil and r.keys[spec.uid] or nil
        local v = ENGINE_NEW_TRAILER(spec.uid, { level = key ~= nil and 0 or spec.level, fillType = ENGINE_FT[spec.ft or "WHEAT"], capacity = 50000, supported = BOTH })
        m._vehicles[#m._vehicles + 1] = v
        vs[spec.uid] = v
        if key ~= nil then ENGINE_POST_LOAD_VEHICLE(v, { xmlFile = xml, key = key, resetVehicles = false }) end
    end
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    local lease = m.stockGuard.registerProperty(PROP, originSpec)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    local out = { stocks = {}, epoch = sg.loadEpoch, core = sg.save.loadResult and sg.save.loadResult.core or nil }
    for uid, v in pairs(vs) do
        local s = stockOf(sg, v)
        local p = s and s.properties[PROP]
        out.stocks[uid] = { id = s and s.stockId, knowledge = s and s.knowledge, reason = s and s.reason, prop = p and p.payload and p.payload.o, level = v:getFillUnitFillLevel(1) }
    end
    for uid, value in pairs(r.publish or {}) do
        local s = stockOf(sg, vs[uid])
        out.stocks[uid].published = s ~= nil and m.stockGuard.publishProperties(lease,
            { { stockRef = sg.operations:stockRef(s), expectedPropertyRevision = 0, record = origin(value, s.observedAmount) } }) ~= nil
    end
    out.retired = {}
    for id, h in pairs(sg.operations.retiredStocks) do out.retired[id] = tostring(h.retireReason) end
    if r.claimAfter ~= nil then
        -- group R: a second restore pass whose history claims this vehicle's reattached id
        local s = stockOf(sg, vs[r.claimAfter])
        local row = nil
        for _, x in ipairs(sg.save.loadedEnvelope.coreValues.stocks) do if s ~= nil and x.stockId == s.stockId then row = SGValues.copy(x) end end
        local claim = { ran = false }
        if row ~= nil then
            row.carrierKey = { adapterId = "m214.absent", nativeOwnerKey = "absent", componentKey = "1" }
            row.carrierId = SGRecords.carrierKeyString(row.carrierKey)
            row.retireReason = "CARRIER_ABSENT"
            local res = sg.operations:restoreCore({ schemaVersion = 2, nextStock = 0, carriers = {}, stocks = {}, historical = { row } }, {})
            local after = stockOf(sg, vs[r.claimAfter])
            local p = after and after.properties[PROP]
            claim = { ran = true, sameId = after ~= nil and after.stockId == s.stockId, knowledge = after and after.knowledge, prop = p and p.payload and p.payload.o,
                moved = res.moved, retired = sg.operations.retiredStocks[s.stockId] ~= nil }
        end
        out.claim = claim
    end
    if r.groundTwin then
        -- group G: the ground payload's records through GR.coreOf, once clean and once with the
        -- history twin of its cell's stock that the trunk's restore could leave
        local identity = SGGround.currentIdentity(m)
        local cells = { ["0:0"] = { x = 0, z = 0, stockId = "st:1:9", dataRevision = "4", knowledge = "KNOWN", reason = "INITIAL_OBSERVATION",
            property = "p1", fillType = "WHEAT", liters = 100, generation = 1, lastGeneration = 1 } }
        local props = { p1 = { properties = {}, acceptedCauses = {} } }
        local clean, whyClean = SGGround.coreOf(identity, cells, props, {})
        local twin = clean and SGValues.copy(clean.stocks[1]) or nil
        if twin ~= nil then twin.retireReason = "RESTORE_MISMATCH" end
        local first = #lines
        local core, why = SGGround.coreOf(identity, cells, props, { twin })
        local said = nil
        for i = first + 1, #lines do if lines[i]:find("historical duplicates of cell stocks", 1, true) then said = lines[i] end end
        out.ground = { clean = clean ~= nil and #clean.stocks or whyClean, accepted = core ~= nil, why = why, history = core and #core.historical or nil, said = said }
    end
    if r.save then
        ENGINE_SAVE.finalDir = plan.dir
        REAL.g_savegameController:saveSavegame(m.missionInfo, false)
        ENGINE_RUN_FRAMES(nil)
        out.keys = {}
        for i, v in ipairs(m._vehicles) do out.keys[v.uniqueId] = string.format("vehicles.vehicle(%d)", i - 1) end
        out.saved = envelopeIds(plan.dir)
    end
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
    local run = assert(load(LAUNCH, "=MAINT-214 launch", "t", E))
    local results = run(plan)
    return results, deepCopy(G.ENGINE_DISK)
end

-- ── readers ───────────────────────────────────────────────────────────────────────────────
local function lineWith(lines, pattern) for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then return l end end return nil end
local function counts(r)
    local l = lineWith(r.lines, "restored stocks:")
    return l and l:match("(%d+ reattached, %d+ mismatched)") or ("no load line" .. (lineWith(r.lines, "saved envelope refused") and " (envelope refused)" or ""))
end
local function refusal(r)
    local l = lineWith(r.lines, "saved envelope refused")
    return l and l:match("refused: ([^;]+)") or "none"
end
local function epochOf(r)
    local l = lineWith(r.lines, "mission handle published")
    return l and l:match("epoch (%d+)") or "?"
end
--- "id|knowledge|reason|value" per uid, in the order given.
local function stocksText(r, uids)
    local out = {}
    for _, uid in ipairs(uids) do
        local s = r.stocks[uid] or {}
        out[#out + 1] = tostring(s.knowledge) .. "|" .. tostring(s.reason) .. "|" .. tostring(s.prop)
    end
    return table.concat(out, " ")
end
--- true when every uid holds the same stock id in a and b.
local function sameIds(a, b, uids)
    for _, uid in ipairs(uids) do
        if a.stocks[uid] == nil or b.stocks[uid] == nil or a.stocks[uid].id == nil or a.stocks[uid].id ~= b.stocks[uid].id then return false end
    end
    return true
end
--- "N stocks, M history, unique|DUPLICATE id" for a saved envelope's ids.
local function savedText(saved)
    if saved == nil then return "no envelope" end
    local seen, dup = {}, false
    for _, id in ipairs(saved.stocks) do if seen[id] then dup = true end seen[id] = true end
    for _, id in ipairs(saved.historical) do if seen[id] then dup = true end seen[id] = true end
    return string.format("%d stocks, %d history, %s", #saved.stocks, #saved.historical, dup and "DUPLICATE id" or "unique ids")
end

local DIR = "m214"
local THREE = { { uid = "vehicle:t1", level = 1000 }, { uid = "vehicle:t2", level = 2000 }, { uid = "vehicle:t3", level = 3000, ft = "BARLEY" } }
local UIDS = { "vehicle:t1", "vehicle:t2", "vehicle:t3" }
local VALUES = { ["vehicle:t1"] = 0.11, ["vehicle:t2"] = 0.22, ["vehicle:t3"] = 0.33 }
local KNOWN3 = "KNOWN|INITIAL_OBSERVATION|0.11 KNOWN|INITIAL_OBSERVATION|0.22 KNOWN|INITIAL_OBSERVATION|0.33"

--- The first launch on a new directory: three trailers, a record published on each, saved.
local function firstLaunch(dir, index)
    local r, disk = launch(nil, { dir = dir, index = index, rounds = { { vehicles = THREE, publish = VALUES, save = true } } })
    return r[1], disk
end
local function relaunch(disk, dir, index, keys, vehicles, save)
    local r, d = launch(disk, { dir = dir, index = index, rounds = { { vehicles = vehicles or THREE, keys = keys, save = save } } })
    return r[1], d
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ENTRY-POINT BAR: THREE UNCHANGED TRAILERS THROUGH THREE LAUNCHES
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    local l1, d1 = firstLaunch(DIR .. "a", 1)
    T.eq("A0 [reached] the first launch: three trailers enumerated at the barrier, a record published on each, saved as three stocks",
        tostring(l1.stocks["vehicle:t1"].published) .. "/" .. tostring(l1.stocks["vehicle:t3"].published) .. " " .. savedText(l1.saved), "true/true 3 stocks, 0 history, unique ids")
    local l2, d2 = relaunch(d1, DIR .. "a", 1, l1.keys, nil, true)
    local l3 = relaunch(d2, DIR .. "a", 1, l2.keys, nil, false)
    T.eq("A1 NAMED [entry point]: the second launch, a new process, reattaches all three with their ids and records",
        counts(l2) .. " " .. tostring(sameIds(l1, l2, UIDS)) .. " " .. stocksText(l2, UIDS), "3 reattached, 0 mismatched true " .. KNOWN3)
    T.eq("A2 NAMED: the second launch's save holds each stock once, and no history", savedText(l2.saved), "3 stocks, 0 history, unique ids")
    T.eq("A3 NAMED: the third launch reads that save (not refused) and reattaches all three, ids and records the first launch's",
        refusal(l3) .. " " .. counts(l3) .. " " .. tostring(sameIds(l1, l3, UIDS)) .. " " .. stocksText(l3, UIDS), "none 3 reattached, 0 mismatched true " .. KNOWN3)
    T.eq("A4 [a new process each] every launch counted its epoch from the start", epochOf(l1) .. epochOf(l2) .. epochOf(l3), "111")
    T.eq("A5 the second launch moved the three fresh stocks off the saved ids before the walk", tostring(l2.core and l2.core.moved), "3")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A NEW TRAILER FIRST IN THE ORDER AT THE SECOND LAUNCH
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local l1, d1 = firstLaunch(DIR .. "b", 2)
    local FOUR = { { uid = "vehicle:t0", level = 500 }, THREE[1], THREE[2], THREE[3] }
    local l2, d2 = relaunch(d1, DIR .. "b", 2, l1.keys, FOUR, true)
    local newId = l2.stocks["vehicle:t0"] and l2.stocks["vehicle:t0"].id
    local clash = false
    for _, uid in ipairs(UIDS) do if l1.stocks[uid].id == newId then clash = true end end
    T.eq("B1 NAMED: with a new trailer enumerated first, the three saved stocks still reattach with their ids and records",
        counts(l2) .. " " .. tostring(sameIds(l1, l2, UIDS)) .. " " .. stocksText(l2, UIDS), "3 reattached, 0 mismatched true " .. KNOWN3)
    T.eq("B2 NAMED: the new trailer's stock holds none of the saved ids, and the save holds each id once",
        tostring(newId ~= nil and not clash) .. " " .. savedText(l2.saved), "true 4 stocks, 0 history, unique ids")
    local l3 = relaunch(d2, DIR .. "b", 2, l2.keys, FOUR, false)
    T.eq("B3 the third launch reads it and reattaches all four", refusal(l3) .. " " .. counts(l3), "none 4 reattached, 0 mismatched")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A REAL CHANGE BETWEEN LAUNCHES STILL READS RESTORE_MISMATCH, WITHOUT A TWIN
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local l1, d1 = firstLaunch(DIR .. "c", 3)
    local file = d1[DIR .. "c/vehicles.xml"]
    local k = l1.keys["vehicle:t2"] .. ".fillUnit.unit(0)#fillLevel"
    local old = file and file[k]
    if file ~= nil then file[k] = type(old) == "string" and "2500" or 2500 end
    local l2, d2 = relaunch(d1, DIR .. "c", 3, l1.keys, nil, true)
    local t2 = l2.stocks["vehicle:t2"] or {}
    local savedT2 = l1.stocks["vehicle:t2"].id
    T.eq("C0 [reached] the second launch rebuilt trailer 2 at the edited level", tostring(old ~= nil) .. " " .. tostring(t2.level), "true 2500")
    T.eq("C1 NAMED: trailer 2, changed between launches, is RESTORE_MISMATCH and UNKNOWN; the other two reattach",
        counts(l2) .. " " .. stocksText(l2, UIDS), "2 reattached, 1 mismatched KNOWN|INITIAL_OBSERVATION|0.11 UNKNOWN|RESTORE_MISMATCH|nil KNOWN|INITIAL_OBSERVATION|0.33")
    T.eq("C2 NAMED: its live stock has a new id, its saved record is history under the saved id, and the save holds each id once",
        tostring(t2.id ~= nil and t2.id ~= savedT2) .. " " .. tostring(l2.retired[savedT2]) .. " " .. savedText(l2.saved), "true RESTORE_MISMATCH 3 stocks, 1 history, unique ids")
    local l3 = relaunch(d2, DIR .. "c", 3, l2.keys, nil, false)
    T.eq("C3 NAMED: the third launch reads that save (not refused), drops nothing, reattaches all three, and keeps trailer 2's old record as history",
        refusal(l3) .. " " .. tostring(lineWith(l3.lines, "dropped") == nil) .. " " .. counts(l3) .. " " .. tostring(l3.retired[savedT2]),
        "none true 3 reattached, 0 mismatched RESTORE_SUPERSEDED")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A SAVE THE TRUNK WROTE AT ITS SECOND LAUNCH LOADS
-- ══════════════════════════════════════════════════════════════════════════
-- The envelope as a95ee35's restoreCore leaves it at the second launch of A's world: each live stock
-- UNKNOWN, RESTORE_MISMATCH, its generation one past the saved one and no records; each saved stock kept
-- as history under the SAME id, with its records, its carrier's binding and the reason RESTORE_MISMATCH.
-- Built from the first launch's real save, in a process of its own, through the mod's own codec.
local TWINS = [==[
local dir = ...
local d = ENGINE_DISK[dir .. "/stockGuard.xml"]
local tokens = {}
for i = 1, d["stockGuard#count"] do tokens[i] = d[string.format("stockGuard.token(%d)#v", i - 1)] end
local e = SGValues.decode(tokens)
local core = e.coreValues
local bindings = {}
for _, c in ipairs(core.carriers) do bindings[c.carrierId] = c.binding end
core.historical = {}
for _, s in ipairs(core.stocks) do
    local h = SGValues.copy(s)
    h.retireReason = "RESTORE_MISMATCH"
    h.binding = SGValues.copy(bindings[s.carrierId])
    core.historical[#core.historical + 1] = h
    s.knowledge, s.reason = "UNKNOWN", "RESTORE_MISMATCH"
    s.contentsGeneration = s.contentsGeneration + 1
    s.properties, s.acceptedCauses = {}, {}
end
local out = SGValues.encode(e)
for k in pairs(d) do d[k] = nil end
d["stockGuard#count"] = #out
for i, t in ipairs(out) do d[string.format("stockGuard.token(%d)#v", i - 1)] = t end
return #core.historical
]==]
group("D", function()
    local l1, d1 = firstLaunch(DIR .. "d", 4)
    local G, E = ENGINE_NEW_PROCESS()
    G.ENGINE_DISK = deepCopy(d1)
    local twins = assert(load(TWINS, "=MAINT-214 twins", "t", E))(DIR .. "d")
    local d2 = deepCopy(G.ENGINE_DISK)
    local l3 = relaunch(d2, DIR .. "d", 4, l1.keys, nil, true)
    T.eq("D1 NAMED: the trunk's twin save loads instead of being refused: the three twins dropped and named in the log",
        tostring(twins) .. " " .. refusal(l3) .. " " .. tostring(lineWith(l3.lines, "[StockGuard] restore: dropped 3 historical duplicates of live stocks") ~= nil),
        "3 none true")
    T.eq("D2 NAMED: its three live stocks reattach as they were saved (UNKNOWN, the mismatch the trunk recorded), and the next save holds each id once",
        counts(l3) .. " " .. stocksText(l3, UIDS) .. " " .. savedText(l3.saved),
        "3 reattached, 0 mismatched UNKNOWN|RESTORE_MISMATCH|nil UNKNOWN|RESTORE_MISMATCH|nil UNKNOWN|RESTORE_MISMATCH|nil 3 stocks, 0 history, unique ids")
end)


-- ══════════════════════════════════════════════════════════════════════════
-- E. CONTROL: AN IN-PROCESS RELOAD
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local G, E = ENGINE_NEW_PROCESS()
    local run = assert(load(LAUNCH, "=MAINT-214 launch", "t", E))
    local first = run({ dir = DIR .. "e", index = 5, rounds = { { vehicles = THREE, publish = VALUES, save = true } } })[1]
    local second = run({ dir = DIR .. "e", index = 5, rounds = { { vehicles = THREE, keys = first.keys, save = false } } })[1]
    T.eq("E1 [control] reloaded in the SAME process the epoch counts on to 2, so the ids cannot meet and all three reattach on the trunk too: why no earlier reload bench saw the fault",
        epochOf(first) .. epochOf(second) .. " " .. counts(second) .. " " .. stocksText(second, UIDS), "12 3 reattached, 0 mismatched " .. KNOWN3)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE FIRST CLAIM ON A SAVED ID STANDS
-- ══════════════════════════════════════════════════════════════════════════
-- A second restore pass in the same load (the ground section's runs after the envelope's) whose saved
-- history claims an id the first pass reattached: a save no consistent writer makes, but the trunk can
-- leave one across its two cores. The reattached stock keeps its id and record; the row stays history.
group("R", function()
    local l1, d1 = firstLaunch(DIR .. "r", 7)
    local l2 = relaunch(d1, DIR .. "r", 7, l1.keys, { THREE[1], THREE[2], THREE[3] }, false)
    local G, E = ENGINE_NEW_PROCESS()
    G.ENGINE_DISK = deepCopy(d1)
    local run = assert(load(LAUNCH, "=MAINT-214 launch", "t", E))
    local r = run({ dir = DIR .. "r", index = 7, rounds = { { vehicles = THREE, keys = l1.keys, save = false, claimAfter = "vehicle:t1" } } })[1]
    local c = r.claim or {}
    T.eq("R0 [reached] the envelope's pass reattached all three, then a second pass ran over a row claiming trailer 1's id",
        counts(l2) .. " " .. counts(r) .. " " .. tostring(c.ran), "3 reattached, 0 mismatched 3 reattached, 0 mismatched true")
    T.eq("R1 NAMED: trailer 1's stock keeps the id and the record it reattached with; the second pass moved nothing and kept the row as history",
        tostring(c.sameId) .. " " .. tostring(c.knowledge) .. "|" .. tostring(c.prop) .. " moved " .. tostring(c.moved) .. " " .. tostring(c.retired),
        "true KNOWN|0.11 moved 0 true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE GROUND PAYLOAD'S TWIN GUARD
-- ══════════════════════════════════════════════════════════════════════════
-- The ground's records restore through the same restoreCore, so a fresh launch could leave the history
-- twin of a cell's stock in the ground payload the same way (when a cell's fresh id met its saved id),
-- which GR.coreOf's validateCore refused, the whole ground binding UNAVAILABLE. Driven on GR.coreOf in a
-- booted process, with one cell built as decodeRuns returns it (no ground save in this bench).
group("G", function()
    local r = launch(nil, { dir = DIR .. "g", index = 8, rounds = { { vehicles = THREE, save = false, groundTwin = true } } })[1]
    local g = r.ground or {}
    T.eq("G0 [reached] a cell's records build cleanly", tostring(g.clean), "1")
    T.eq("G1 NAMED: with the history twin of its own stock, the ground's records still build: the twin dropped and named in the log",
        tostring(g.accepted) .. " " .. tostring(g.why) .. " " .. tostring(g.history) .. " " .. tostring(g.said),
        "true nil 0 [StockGuard] ground: dropped 1 historical duplicates of cell stocks")
end)
