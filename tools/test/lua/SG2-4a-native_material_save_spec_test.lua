-- SG2-4a-native_material_save_spec_test.lua
--
-- SG2-4a: SG_NATIVE_MATERIAL_SAVE_V1 (SG-2 v2.3 :563-575, :818-836), the ground kind
-- and extensions.sg2Ground, the participant calls on mission.stockGuard, and the two
-- Combine drain deferrals.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv, mods.lua:489-495): the engine
-- models, the controller and the C functions live in the real global table, the mod's
-- src and this file in an environment whose _G is itself. Engine globals the bench sets
-- (g_currentMission, g_server, g_savegameController) are set in the real table, as the
-- engine sets them; an assignment through the mod's _G would only shadow them.
--
-- THE ENTRY-POINT BAR IS GROUP E. The engine models, then main.lua's modules and
-- main.lua; the mission through main's appends (the class hooks and the ground at
-- loadMission00Finished); then the modeled SavegameController's own save path:
-- saveSavegame, the C start calling onSaveStartComplete by name, the career chain with
-- StockGuard's envelope appended, the controller's queued density-map closures run
-- one per frame while the world moves on, the C finish moving the staged files and
-- calling onSaveComplete by name; then a fresh mission on the final directory. Nothing
-- writes a descriptor, a payload, a marker, an association or a guard by hand, and the
-- ground set is the empty one production has until SG2-4b.
--
-- Groups:
--   E  the entry-point bar: one nonblocking save, the height image is the freeze's,
--      exactly one prepare, the marker in the final directory, a READY reload
--   B  a blocking save: the freeze at the END of the career chain, before the direct
--      writes; no prepare at all; a synchronous finish too
--   P  the participant API (the SG-2 reference model, ported onto the real handle)
--   F  failures: a failed save writes no marker; a failed start opens nothing; a lost
--      marker, another map, layer or height file, a save outside an attempt
--   A  the attempt counter: no attempt increments as before; one counter; the key
--   G  the guard: the real table only; unmatched calls pass; a later wrapper stays
--   D  the drain deferral: held while the boundary is open, run once after, outermost
--   C  the codec: runs, refusals, and a populated round trip (bench-made cells)
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local REAL = getmetatable(_G).__index
local M, GR, NH, NA, HC, B = SGNativeMaterialSave, SGGround, SGNativeHost, SGNativeAdapters, SGHarvestCapture, SGCombineBufferSave
local C_PREPARE = REAL.prepareSaveDensityMapToFile
local HEIGHT_FILE = "densityMap_height.gdm"
local FRUIT = ENGINE_FRUIT.WHEAT

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
local function printed(fn)
    local lines, orig = {}, print
    REAL.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(fn)
    REAL.print = orig
    if not ok then error(err, 0) end
    return lines
end
local function has(lines, pattern) for _, l in ipairs(lines) do if l:find(pattern, 1, true) then return true end end return false end
local function count(lines, pattern) local n = 0 for _, l in ipairs(lines) do if l:find(pattern, 1, true) then n = n + 1 end end return n end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir, opts)
    local m = setmetatable({ _server = opts.server ~= false, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, time = 1000,
        terrainSize = opts.terrainSize or 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = opts.mapId or "MapUS", savegameIndex = opts.index or 1, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

--- Boot through main.lua's load path, the world built first.
local function boot(build, saveDir, opts)
    opts = opts or {}
    ENGINE_PLANE.cells = {}
    local m = newMission(saveDir, opts)
    engine("g_server", opts.server ~= false and {} or nil)
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local w = {}
    if build ~= nil then build(m, w) end
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
--- The combine bought back from a save's vehicles file.
local function loadCombine(m, uid, opts, dir)
    local xml = XMLFile.load("vehicles", dir .. "/vehicles.xml", Vehicle.xmlSchemaSavegame)
    local v = combineIn(m, uid, opts)
    ENGINE_POST_LOAD_VEHICLE(v, xml ~= nil and { xmlFile = xml, key = "vehicles.vehicle(0)", resetVehicles = false } or nil)
    return v
end

--- The engine's own save: saveSavegame through the controller, then the frames.
local function nativeSave(m, blocking, finalDir, between)
    ENGINE_SAVE.finalDir = finalDir
    local controller = REAL.g_savegameController
    controller:saveSavegame(m.missionInfo, blocking)
    ENGINE_RUN_FRAMES(between)
    return controller
end
local function reload(m, dir, build, opts)
    FSBaseMission.delete(m)
    return boot(build, dir, opts)
end
local function resetEngine()
    REAL.ENGINE_PREPARE_LOG, REAL.ENGINE_DIRECT_LOG, REAL.ENGINE_PREPARED = {}, {}, {}
    ENGINE_SAVE.startError, ENGINE_SAVE.finishError, ENGINE_SAVE.finishSync, ENGINE_SAVE.errorAfterMove = nil, nil, false, false
    REAL.ENGINE_CAREER_HOOK = nil
    ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1
    ENGINE_MAPS[ENGINE_HEIGHT_ID].heightNumChannels = 6
    g_asyncTaskManager.tasks = {}
end
engine("g_savegameController", SavegameController.new())

-- ── readers ────────────────────────────────────────────────────────────────
local function envelopeAt(dir)
    local d = ENGINE_DISK[dir .. "/stockGuard.xml"]
    if d == nil then return nil end
    local tokens = {}
    for i = 1, d["stockGuard#count"] do tokens[i] = d[string.format("stockGuard.token(%d)#v", i - 1)] end
    return SGValues.decode(tokens)
end
local function descriptorAt(dir)
    local e = envelopeAt(dir)
    return e ~= nil and e.sections[GR.SECTION_ID] ~= nil and e.sections[GR.SECTION_ID].payload or nil
end
local function payloadAt(dir) return ENGINE_DISK[dir .. "/" .. GR.PAYLOAD_FILE] end
local function marker(dir) local p = payloadAt(dir) return p ~= nil and p[GR.PAYLOAD_ROOT .. "#completeAttemptId"] or nil end
local function preparesOf(id)
    local n, versions = 0, {}
    for _, p in ipairs(ENGINE_PREPARE_LOG) do if p.id == id then n = n + 1 versions[#versions + 1] = tostring(p.version) end end
    return n .. ":" .. table.concat(versions, ",")
end
local function readiness(sg) local r = sg.ground ~= nil and sg.ground:getReadiness() or {} return tostring(r.state) .. "/" .. tostring(r.reason) end
local function results(sg)
    local la = sg.nativeSave.lastAttempt
    if la == nil then return "none" end
    local ids = {}
    for id in pairs(la.results) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = id .. "=" .. la.results[id].state .. (la.results[id].reason and (":" .. la.results[id].reason) or "") end
    return table.concat(out, ",")
end
--- A stub participant: records what it saw; `freeze` returns its answer.
local function stub(freeze)
    local s = { seen = {} }
    s.spec = {
        beginAttempt = function(context) s.seen[#s.seen + 1] = "begin:" .. tostring(context.attemptId) s.context = context end,
        freezeAfterCareerXML = function(context)
            s.seen[#s.seen + 1] = "freeze:" .. tostring(context.attemptId)
            s.atFreeze = { career = ENGINE_CAREER_CALLS, direct = #ENGINE_DIRECT_LOG, envelope = ENGINE_DISK[context.careerSave.savegameDirectory .. "/stockGuard.xml"] ~= nil,
                vehicles = ENGINE_DISK[context.careerSave.savegameDirectory .. "/vehicles.xml"] ~= nil, blocking = context.isBlocking }
            return freeze(context)
        end,
        finishAttempt = function(context, errorCode, finalDir) s.seen[#s.seen + 1] = "finish:" .. tostring(errorCode) .. ":" .. tostring(finalDir) s.finalState = context.results.stub end,
    }
    return s
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetEngine()
    local lines, m, sg
    lines = printed(function() m, sg = boot(nil, "e_save", { index = 11 }) end)
    local caps = m.stockGuard.getCapabilities()
    T.ok("E1 [reached] main.lua sourced the boundary and the ground, wrapped the controller's start and result on its class, attached the ground and published nativeMaterialSave = 1",
        has(ENGINE_SOURCED, "src/native/SGNativeMaterialSave.lua") and has(ENGINE_SOURCED, "src/native/SGGround.lua")
        and SGClassHook.boundTo(SavegameController, "onSaveStartComplete", M.HOOK_ID, M) and SGClassHook.boundTo(SavegameController, "onSaveComplete", M.HOOK_ID, M)
        and sg.ground ~= nil and caps.nativeMaterialSave == 1 and has(lines, "native material save live: SG_NATIVE_MATERIAL_SAVE_V1"))
    T.eq("E1b no guard is on the engine global outside an attempt", tostring(rawget(REAL, "prepareSaveDensityMapToFile") == C_PREPARE) .. "/" .. tostring(M.guard), "true/nil")
    local before = sg.save.saveAttemptId
    local moved = {}
    lines = printed(function()
        nativeSave(m, false, "e_final", function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1 + frame moved[#moved + 1] = frame end)
    end)
    local d = descriptorAt("e_final")
    local e = envelopeAt("e_final")
    T.eq("E2 one attempt: the next id of SG-1's counter, carried by the envelope, extensions.sg2Ground and the payload alike",
        tostring(e and e.saveAttemptId) .. "/" .. tostring(d and d.attemptId) .. "/" .. tostring(payloadAt("e_final") and payloadAt("e_final")[GR.PAYLOAD_ROOT .. "#attemptId"]), tostring(before + 1) .. "/" .. tostring(before + 1) .. "/" .. tostring(before + 1))
    T.eq("E2b the descriptor is SG-2's shape: schema 1, the map, the layer, the height file, the payload file, payload schema 1, XML_HEIGHT_SAME_CALL",
        tostring(d.schema) .. "|" .. tostring(d.mapKey) .. "|" .. tostring(d.layerDescriptor) .. "|" .. tostring(d.nativeHeightFile) .. "|" .. tostring(d.groundPayloadFile) .. "|" .. tostring(d.payloadSchema) .. "|" .. tostring(d.boundary),
        "1|MapUS|height=densityMap_height.gdm;size=256;terrain=256;heightChannels=6+6;typeChannels=0+6|densityMap_height.gdm|stockGuardGround.xml|1|XML_HEIGHT_SAME_CALL")
    T.eq("E3 the world moved on for " .. #moved .. " frames while the save was queued, and the height map was prepared exactly once, with the image of the freeze (version 1)", preparesOf(ENGINE_HEIGHT_ID), "1:1")
    T.eq("E3b the controller's own closures still prepared every other map exactly once (the guard passed them through)",
        preparesOf(1) .. " " .. preparesOf(3) .. " " .. preparesOf(4), "1:1 1:1 1:1")
    T.eq("E4 the height file in the final directory is the freeze's image, the one the career XML was written beside",
        tostring(ENGINE_DISK["e_final/" .. HEIGHT_FILE] and ENGINE_DISK["e_final/" .. HEIGHT_FILE].version) .. "/" .. tostring(ENGINE_DISK["e_final/careerSavegame.xml"].heightVersion), "1/1")
    T.eq("E5 the completion marker is in the FINAL directory's payload, for this attempt; nothing is left in staging", tostring(marker("e_final")) .. "/" .. tostring(ENGINE_DISK["staging11/" .. GR.PAYLOAD_FILE] == nil), tostring(before + 1) .. "/true")
    T.eq("E6 after the result the guard is gone and the association cleared: the engine global is the C function again", tostring(rawget(REAL, "prepareSaveDensityMapToFile") == C_PREPARE) .. "/" .. tostring(M.guard) .. "/" .. #M.associations, "true/nil/0")
    T.eq("E6b the participant result: sg2Ground READY", results(sg), "sg2Ground=READY")
    T.eq("E6d the career save's temporary field is gone: the class chain answers the next call", tostring(rawget(m.missionInfo, "saveToXMLFile")), "nil")
    T.ok("E6c the guard's table was logged once: the real global table behind the mod's environment",
        count(lines, "prepare guard installed on the engine global prepareSaveDensityMapToFile (ENGINE table, getmetatable(_G).__index)") == 1)
    local m2, sg2
    lines = printed(function() m2, sg2 = reload(m, "e_final", nil, { index = 11 }) end)
    T.eq("E7 a fresh mission on the final directory: the ground binding is READY from this attempt's image, with no cells (none has a producer before SG2-4b)",
        readiness(sg2) .. "/" .. tostring(sg2.save:sectionReady(GR.SECTION_ID)), "READY/nil/true")
    T.ok("E7b and it said so once", count(lines, "ground image of attempt " .. tostring(before + 1) .. " restored: 0 cell(s)") == 1)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A BLOCKING SAVE
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    resetEngine()
    local m, sg = boot(nil, "b_save", { index = 12 })
    local s = stub(function() return { state = "READY", payloadFile = "stub.xml", images = {} } end)
    T.eq("B0 a second participant registers through the same handle call", tostring(m.stockGuard.registerNativeSaveParticipant("stub", s.spec)), "true")
    local careerBefore = ENGINE_CAREER_CALLS
    nativeSave(m, true, "b_final")
    T.eq("B1 the freeze ran at the END of the career chain: the career save, the vehicles and StockGuard's own envelope were written, the controller's direct density writes not yet",
        tostring(s.atFreeze.career - careerBefore) .. "/" .. tostring(s.atFreeze.vehicles) .. "/" .. tostring(s.atFreeze.envelope) .. "/" .. tostring(s.atFreeze.direct) .. "/" .. tostring(s.atFreeze.blocking), "1/true/true/0/true")
    T.eq("B2 a blocking save prepares nothing: the controller wrote every map directly, the height map at the world as it was at the freeze",
        #ENGINE_PREPARE_LOG .. "/" .. #ENGINE_DIRECT_LOG .. "/" .. tostring(ENGINE_DISK["b_final/" .. HEIGHT_FILE].version), "0/4/1")
    T.eq("B3 both participants were READY and the marker is written in the final directory", results(sg) .. "/" .. tostring(marker("b_final")), "sg2Ground=READY,stub=READY/" .. tostring(sg.save.saveAttemptId))
    -- The finish can come back inside the start call (a synchronous C finish).
    resetEngine()
    ENGINE_SAVE.finishSync = true
    nativeSave(m, true, "b_final2")
    T.eq("B4 with the result delivered inside the start call, the attempt still finished once and the marker is in the final directory",
        tostring(marker("b_final2")) .. "/" .. tostring(sg.nativeSave.attempt) .. "/" .. count(s.seen, "finish:0:b_final2"), tostring(sg.save.saveAttemptId) .. "/nil/1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PARTICIPANT API (SG-2-native_save_participant_spec, on the real handle)
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    resetEngine()
    local m, sg = boot(nil, "p_save", { index = 13 })
    local h = m.stockGuard
    local soil = stub(function() return { state = "READY", payloadFile = "soilGround.xml", images = {} } end)
    local cd = stub(function() return { state = "READY", payloadFile = "soilDisease.xml", images = { { mapId = 3, nativeFilename = "densityMap_grass.gdm" }, { mapId = 4, nativeFilename = "densityMap_grassHaulm.gdm" } } } end)
    T.eq("P1 first participant registers", tostring(h.registerNativeSaveParticipant("soil", soil.spec)), "true")
    T.eq("P2 the same registration is idempotent", tostring(h.registerNativeSaveParticipant("soil", soil.spec)), "true")
    local ok, why = h.registerNativeSaveParticipant("soil", stub(function() end).spec)
    T.eq("P3 a different owner cannot replace a live participant", tostring(ok) .. "/" .. tostring(why), "false/CONFLICT")
    T.eq("P4 CD's participant registers independently", tostring(h.registerNativeSaveParticipant("cd", cd.spec)), "true")
    local ok2, why2 = h.registerNativeSaveParticipant("x", { beginAttempt = function() end })
    T.eq("P4b a spec without the three callbacks is refused", tostring(ok2) .. "/" .. tostring(why2), "false/INVALID_SPEC")
    local starts = ENGINE_START_CALLS
    nativeSave(m, false, "p_final")
    local id = sg.save.saveAttemptId
    T.eq("P5 the captured native start ran exactly once", ENGINE_START_CALLS - starts, 1)
    T.eq("P6 every participant began the one shared attempt", table.concat(soil.seen, ",") .. " " .. table.concat(cd.seen, ","),
        "begin:" .. id .. ",freeze:" .. id .. ",finish:0:p_final begin:" .. id .. ",freeze:" .. id .. ",finish:0:p_final")
    T.eq("P7 distinct native images all stay READY; CD's fruit and haulm images were each prepared once, at the freeze", results(sg) .. " " .. preparesOf(3) .. " " .. preparesOf(4), "cd=READY,sg2Ground=READY,soil=READY 1:1 1:1")
    local bad = stub(function() return { state = "UNAVAILABLE", reason = "WRITE_FAILED" } end)
    T.eq("P8 a third participant may register", tostring(h.registerNativeSaveParticipant("bad", bad.spec)), "true")
    local careerBefore = ENGINE_CAREER_CALLS
    resetEngine()
    nativeSave(m, false, "p_final2")
    T.eq("P9 a participant's failure does not skip the native save, stays UNAVAILABLE, and every other participant stays READY",
        tostring(ENGINE_CAREER_CALLS - careerBefore) .. "/" .. results(sg) .. "/" .. tostring(marker("p_final2") == sg.save.saveAttemptId), "1/bad=UNAVAILABLE:WRITE_FAILED,cd=READY,sg2Ground=READY,soil=READY/true")
    T.eq("P9b it still received its finish, with the actual result, so it cleans up", bad.seen[#bad.seen], "finish:0:p_final2")
    local okU, whyU = h.unregisterNativeSaveParticipant("soil", cd.spec)
    T.eq("P10 the wrong spec cannot unregister a participant", tostring(okU) .. "/" .. tostring(whyU), "false/NOT_OWNER")
    T.eq("P11 its own spec can", tostring(h.unregisterNativeSaveParticipant("soil", soil.spec)), "true")
    T.eq("P12 unregister removed only that participant", tostring(sg.nativeSave.participants.soil) .. "/" .. tostring(sg.nativeSave.participants.cd == cd.spec), "nil/true")
    FSBaseMission.delete(m)
end)

group("P-dup", function()
    resetEngine()
    local m, sg = boot(nil, "pd_save", { index = 14 })
    local h = m.stockGuard
    -- Soil does not ask for the height image (brief :824); one that does duplicates SG2's.
    local dup = stub(function() return { state = "READY", payloadFile = "dup.xml", images = { { mapId = ENGINE_HEIGHT_ID, nativeFilename = HEIGHT_FILE } } } end)
    local wrongId = stub(function() return { state = "READY", payloadFile = "wrong.xml", images = { { mapId = 99, nativeFilename = "densityMap_fruits.gdm" } } } end)
    local barley = stub(function() return { state = "READY", payloadFile = "barley.xml", images = { { mapId = 1, nativeFilename = "densityMap_fruits.gdm" } } } end)
    local thrower = stub(function() error("boom") end)
    local clash1 = stub(function() return { state = "READY", payloadFile = "same.xml", images = {} } end)
    local clash2 = stub(function() return { state = "READY", payloadFile = "same.xml", images = {} } end)
    local escape = stub(function() return { state = "READY", payloadFile = "../outside.xml", images = {} } end)
    h.registerNativeSaveParticipant("zdup", dup.spec)
    h.registerNativeSaveParticipant("wrongId", wrongId.spec)
    h.registerNativeSaveParticipant("barley", barley.spec)
    h.registerNativeSaveParticipant("thrower", thrower.spec)
    h.registerNativeSaveParticipant("clash1", clash1.spec)
    h.registerNativeSaveParticipant("clash2", clash2.spec)
    h.registerNativeSaveParticipant("escape", escape.spec)
    local lines = printed(function() nativeSave(m, false, "pd_final", function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1 + frame end) end)
    local R = sg.nativeSave.lastAttempt.results
    T.eq("P13 the same map and path named by two participants invalidates BOTH, sg2Ground included, never keeping whichever came first (brief :698)",
        tostring(R.zdup.reason) .. "/" .. tostring(R.sg2Ground.reason), "DUPLICATE_MAP_PATH/DUPLICATE_MAP_PATH")
    T.eq("P14 a descriptor naming another id for a file the controller saves is not native; the id the controller meets first is", tostring(R.wrongId.reason) .. "/" .. tostring(R.barley.state), "IMAGE_NOT_NATIVE/READY")
    T.eq("P15 a participant that throws invalidates only itself, and it is logged", tostring(R.thrower.reason) .. "/" .. tostring(has(lines, "participant thrower threw at freeze")), "FREEZE_THREW/true")
    T.eq("P16 two participants on one payload file are both invalid; a payload path leaving the directory is refused",
        tostring(R.clash1.reason) .. "/" .. tostring(R.clash2.reason) .. "/" .. tostring(R.escape.reason), "PAYLOAD_FILE_CONFLICT/PAYLOAD_FILE_CONFLICT/PAYLOAD_FILE")
    local heightPrepares = {}
    for _, pr in ipairs(ENGINE_PREPARE_LOG) do if pr.id == ENGINE_HEIGHT_ID then heightPrepares[#heightPrepares + 1] = pr.version end end
    T.eq("P17 with no participant left holding the height image nothing prepared it early: the controller prepared it once, itself, later; barley's fruit plane once at the freeze; sg2Ground writes no marker",
        #heightPrepares .. ":" .. tostring((heightPrepares[1] or 0) > 1) .. " " .. preparesOf(1) .. " " .. tostring(marker("pd_final")), "1:true 1:1 nil")
    T.eq("P18 an invalidated participant is told in its finish (context.results), so it writes no marker", tostring(dup.seen[#dup.seen]) .. "/" .. tostring(sg.nativeSave.lastAttempt.results.zdup.state), "finish:0:pd_final/UNAVAILABLE")
    FSBaseMission.delete(m)
end)

group("P-client", function()
    resetEngine()
    local m = boot(nil, "pc_save", { index = 15, server = false })
    local ok, why = m.stockGuard.registerNativeSaveParticipant("soil", stub(function() end).spec)
    T.eq("P19 a client cannot register a participant, and publishes no capability", tostring(ok) .. "/" .. tostring(why) .. "/" .. tostring(m.stockGuard.getCapabilities().nativeMaterialSave), "false/NOT_SERVER/nil")
    FSBaseMission.delete(m)
    engine("g_server", {})
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. FAILURES
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    resetEngine()
    local m, sg = boot(nil, "f_save", { index = 16 })
    local s = stub(function() return { state = "READY", payloadFile = "stub.xml", images = {} } end)
    m.stockGuard.registerNativeSaveParticipant("stub", s.spec)
    ENGINE_SAVE.finishError = Savegame.ERROR_WRITE
    nativeSave(m, false, "f_final")
    T.eq("F1 a failed save (not ERROR_OK) writes no marker anywhere, and says why", tostring(marker("f_final")) .. "/" .. tostring(ENGINE_DISK["staging16/" .. GR.PAYLOAD_FILE] ~= nil and ENGINE_DISK["staging16/" .. GR.PAYLOAD_FILE][GR.PAYLOAD_ROOT .. "#completeAttemptId"]) .. "/" .. tostring(sg.ground.lastMarker.reason), "nil/nil/SAVE_FAILED:7")
    T.eq("F1b every participant still received the actual result, and the guard is gone", s.seen[#s.seen] .. "/" .. tostring(M.guard), "finish:7:nil/nil")
    resetEngine()
    ENGINE_SAVE.finishError, ENGINE_SAVE.errorAfterMove = Savegame.ERROR_WRITE, true
    nativeSave(m, false, "f_final1c")
    T.eq("F1c an error reported after the files already reached the final directory still writes no marker: only ERROR_OK does (:830)",
        tostring(payloadAt("f_final1c") ~= nil) .. "/" .. tostring(marker("f_final1c")) .. "/" .. tostring(sg.ground.lastMarker.reason), "true/nil/SAVE_FAILED:7")
    resetEngine()
    ENGINE_SAVE.startError = Savegame.ERROR_WRITE
    local before, seen = sg.save.saveAttemptId, #s.seen
    nativeSave(m, false, "f_final2")
    T.eq("F2 a failed start opens no attempt: no participant begins, the counter does not move, the native result path runs",
        tostring(#s.seen - seen) .. "/" .. tostring(sg.save.saveAttemptId - before) .. "/" .. tostring(REAL.g_savegameController.completed[#REAL.g_savegameController.completed]), "0/0/7")
    -- A good save, then its marker lost (an interrupted finalization).
    resetEngine()
    nativeSave(m, false, "f_final3")
    ENGINE_DISK["f_final3/" .. GR.PAYLOAD_FILE][GR.PAYLOAD_ROOT .. "#completeAttemptId"] = nil
    local m2, sg2 = reload(m, "f_final3", nil, { index = 16 })
    T.eq("F3 a payload without its completion field leaves the ground UNAVAILABLE, while SG-1's load itself is fine", readiness(sg2) .. "/" .. tostring(sg2.save.loadResult.state), "UNAVAILABLE/NOT_COMPLETE/READY")
    -- The next save writes a fresh descriptor and payload: the binding recovers.
    resetEngine()
    nativeSave(m2, false, "f_final4")
    local m3, sg3 = reload(m2, "f_final4", nil, { index = 16 })
    T.eq("F4 the next save after an unavailable load writes a fresh, complete image, and it restores", readiness(sg3), "READY/nil")
    -- An older save's payload beside this envelope (a partial replacement).
    local good = ENGINE_DISK["f_final4/" .. GR.PAYLOAD_FILE]
    ENGINE_DISK["f_final4/" .. GR.PAYLOAD_FILE] = ENGINE_DISK["f_final3/" .. GR.PAYLOAD_FILE]
    local m3b, sg3b = reload(m3, "f_final4", nil, { index = 16 })
    T.eq("F4b a payload of another attempt beside this envelope is never taken as current", readiness(sg3b), "UNAVAILABLE/PAYLOAD_ATTEMPT")
    ENGINE_DISK["f_final4/" .. GR.PAYLOAD_FILE] = good
    local m4, sg4 = reload(m3b, "f_final4", nil, { index = 16, mapId = "MapEU" })
    T.eq("F5 another map cannot inherit this ground history", readiness(sg4), "UNAVAILABLE/MAP_CHANGED")
    ENGINE_MAPS[ENGINE_HEIGHT_ID].heightNumChannels = 5
    local m5, sg5 = reload(m4, "f_final4", nil, { index = 16 })
    T.eq("F6 the same map with other height channels is an incompatible layer", readiness(sg5), "UNAVAILABLE/LAYER_INCOMPATIBLE")
    ENGINE_MAPS[ENGINE_HEIGHT_ID].heightNumChannels = 6
    local m6, sg6 = reload(m5, "f_final4", nil, { index = 16, terrainSize = 512 })
    T.eq("F7 the same map at another terrain scale is an incompatible layer", readiness(sg6), "UNAVAILABLE/LAYER_INCOMPATIBLE")
    ENGINE_MAPS[ENGINE_HEIGHT_ID].filename = "densityMap_height2.gdm"
    local m7, sg7 = reload(m6, "f_final4", nil, { index = 16 })
    T.eq("F8 another height file name is refused before the layer", readiness(sg7), "UNAVAILABLE/HEIGHT_FILE_CHANGED")
    ENGINE_MAPS[ENGINE_HEIGHT_ID].filename = HEIGHT_FILE
    -- A save that did not come through the controller (the SG-1 benches' direct path).
    sg7.save.openAttemptId = nil
    local okSave = pcall(sg7.onSaveToXML, sg7, m7.missionInfo)
    local m8, sg8 = reload(m7, "f_final4", nil, { index = 16 })
    T.eq("F9 an envelope written outside a native save attempt carries no image to couple to: UNAVAILABLE, SAVED_OUTSIDE_NATIVE_SAVE", tostring(okSave) .. "/" .. readiness(sg8), "true/UNAVAILABLE/SAVED_OUTSIDE_NATIVE_SAVE")
    FSBaseMission.delete(m8)
end)

group("P-own-file", function()
    resetEngine()
    local m, sg = boot(nil, "po_save", { index = 22 })
    local clash = stub(function() return { state = "READY", payloadFile = GR.PAYLOAD_FILE, images = {} } end)
    m.stockGuard.registerNativeSaveParticipant("zfile", clash.spec)
    nativeSave(m, false, "po_final", function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1 + frame end)
    local m2, sg2 = reload(m, "po_final", nil, { index = 22 })
    T.eq("P20 a participant claiming sg2Ground's own payload file invalidates both: no early prepare, no marker, and the reload is UNAVAILABLE",
        results(sg) .. "|" .. tostring(ENGINE_PREPARE_LOG[#ENGINE_PREPARE_LOG] and ENGINE_PREPARE_LOG[#ENGINE_PREPARE_LOG].version ~= 1) .. "|" .. tostring(marker("po_final")) .. "|" .. readiness(sg2),
        "sg2Ground=UNAVAILABLE:PAYLOAD_FILE_CONFLICT,zfile=UNAVAILABLE:PAYLOAD_FILE_CONFLICT|true|nil|UNAVAILABLE/NOT_COMPLETE")
    FSBaseMission.delete(m2)
end)

group("F-mismatch", function()
    resetEngine()
    local m, sg = boot(nil, "fm_save", { index = 21 })
    ENGINE_SAVE.finalDir = "fm_final"
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    -- Between the start and the result another writer serializes the envelope again.
    sg:onSaveToXML(m.missionInfo)
    ENGINE_RUN_FRAMES()
    local m2, sg2 = reload(m, "fm_final", nil, { index = 21 })
    T.eq("F10 an envelope rewritten between the start and the result names a later attempt than the ground image: UNAVAILABLE, ATTEMPT_MISMATCH", readiness(sg2), "UNAVAILABLE/ATTEMPT_MISMATCH")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ATTEMPT COUNTER (Bob's condition: both paths)
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    resetEngine()
    local m, sg = boot(nil, "a_save", { index = 17 })
    local base = sg.save.saveAttemptId
    sg:onSaveToXML(m.missionInfo)
    local e1 = envelopeAt("a_save")
    sg:onSaveToXML(m.missionInfo)
    local e2 = envelopeAt("a_save")
    T.eq("A1 with no open attempt, every envelope increments the counter exactly as before", tostring(e1.saveAttemptId - base) .. "/" .. tostring(e2.saveAttemptId - base), "1/2")
    nativeSave(m, false, "a_final")
    local e3 = envelopeAt("a_final")
    sg:onSaveToXML(m.missionInfo)
    local e4 = envelopeAt("a_final")
    T.eq("A2 a native attempt takes the next id of the same counter, and a later direct save the one after: monotonic", tostring(e3.saveAttemptId - base) .. "/" .. tostring(e4.saveAttemptId - base), "3/4")
    T.eq("A3 the snapshot key is built from the adopted id", tostring(e3.nativeSnapshotKey) .. "|" .. tostring(e3.nativeAssociations.saveAttemptId), "OWN_XML:" .. sg.loadEpoch .. ":" .. tostring(e3.saveAttemptId) .. "|" .. tostring(e3.saveAttemptId))
    T.eq("A4 the attempt is closed once the start call returned", tostring(sg.save.openAttemptId), "nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE GUARD ON THE ENGINE GLOBAL
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    resetEngine()
    local m, sg = boot(nil, "g_save", { index = 18 })
    local during = {}
    -- A later wrapper by someone else, put above the guard while the save is queued.
    local laterCalls = 0
    local later = nil
    ENGINE_SAVE.finalDir = "g_final"
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    during.real = rawget(REAL, "prepareSaveDensityMapToFile") ~= C_PREPARE
    during.modenv = rawget(_G, "prepareSaveDensityMapToFile")
    T.eq("G1 while the attempt is queued the guard is on the REAL global table, never in the mod's own", tostring(during.real) .. "/" .. tostring(during.modenv), "true/nil")
    local guard = rawget(REAL, "prepareSaveDensityMapToFile")
    later = function(id, path) laterCalls = laterCalls + 1 return guard(id, path) end
    REAL.prepareSaveDensityMapToFile = later
    -- An unmatched call reaches the C function. (A height prepare at another path would
    -- replace the one image the engine keeps per map, in game as in the model, so the
    -- same map at another path is checked on the match itself.)
    local n0 = #ENGINE_PREPARE_LOG
    prepareSaveDensityMapToFile(3, "elsewhere/densityMap_grass.gdm")
    local heightPath = "staging18/" .. HEIGHT_FILE
    T.eq("G2 an unmatched call passes to the captured predecessor; only the exact map and path of this attempt match",
        tostring(#ENGINE_PREPARE_LOG - n0) .. "/" .. tostring(M.matchAssociation(ENGINE_HEIGHT_ID, heightPath) ~= nil) .. "/" .. tostring(M.matchAssociation(ENGINE_HEIGHT_ID, "elsewhere/" .. HEIGHT_FILE)) .. "/" .. tostring(M.matchAssociation(3, heightPath)),
        "1/true/nil/nil")
    local laterBefore = laterCalls
    ENGINE_RUN_FRAMES(function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 10 + frame end)
    T.eq("G3 the controller's closures went through the later wrapper and the guard skipped only the height duplicate", tostring(laterCalls - laterBefore) .. "/" .. tostring(ENGINE_DISK["g_final/" .. HEIGHT_FILE].version), "4/1")
    T.eq("G4 at the result the guard's removal left the later wrapper in place; ours stays beneath it as a pass-through",
        tostring(rawget(REAL, "prepareSaveDensityMapToFile") == later) .. "/" .. tostring(M.guard ~= nil and M.guard.wrapper == guard), "true/true")
    local n1 = #ENGINE_PREPARE_LOG
    prepareSaveDensityMapToFile(ENGINE_HEIGHT_ID, "g_final2probe/" .. HEIGHT_FILE)
    T.eq("G5 with no attempt open, a call through both wrappers reaches the C function", #ENGINE_PREPARE_LOG - n1, 1)
    -- The next attempt reuses the guard that is still in the chain.
    resetEngine()
    nativeSave(m, false, "g_final2", function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 20 + frame end)
    T.eq("G6 the next attempt reuses it: still exactly one height prepare, still the freeze's image, no second guard stacked",
        preparesOf(ENGINE_HEIGHT_ID) .. "/" .. tostring(ENGINE_DISK["g_final2/" .. HEIGHT_FILE].version) .. "/" .. tostring(rawget(REAL, "prepareSaveDensityMapToFile") == later), "1:1/1/true")
    -- The later owner takes its wrapper off again, restoring what it captured.
    REAL.prepareSaveDensityMapToFile = guard
    FSBaseMission.delete(m)
    T.eq("G6b once the later wrapper is gone, teardown removes the guard that was left beneath it", tostring(rawget(REAL, "prepareSaveDensityMapToFile") == C_PREPARE) .. "/" .. tostring(M.guard), "true/nil")
    -- Teardown during a queued attempt removes the guard while it is ours.
    resetEngine()
    local m2, sg2 = boot(nil, "g_save", { index = 18 })
    ENGINE_SAVE.finalDir = "g_final3"
    REAL.g_savegameController:saveSavegame(m2.missionInfo, false)
    local queuedGuard = rawget(REAL, "prepareSaveDensityMapToFile") ~= C_PREPARE
    FSBaseMission.delete(m2)
    T.eq("G7 a mission ended with the attempt still queued: the guard is removed, the attempt finished as failed, the associations cleared",
        tostring(queuedGuard) .. "/" .. tostring(rawget(REAL, "prepareSaveDensityMapToFile") == C_PREPARE) .. "/" .. tostring(sg2.nativeSave.lastAttempt.errorCode) .. "/" .. #M.associations, "true/true/MISSION_END/0")
    g_asyncTaskManager.tasks = {}
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE COMBINE DRAIN DEFERRAL
-- ══════════════════════════════════════════════════════════════════════════
local OPTS = { loadingDelay = 100, hopperCapacity = 50 }
local HEADER = { areas = 1, width = 6, depth = 1 }
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function stockAt(sg, id) local c = sg.operations.carriers[id] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end

group("D", function()
    resetEngine()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", OPTS)
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, HEADER)
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end, "d_save", { index = 19 })
    local marks = SGClassHook.record(Combine, "onUpdateTick", M.HOOK_ID)
    local hc = SGClassHook.record(Combine, "onUpdateTick", HC.HOOK_ID)
    T.ok("D1 [reached] the deferral wraps the Combine class event OUTSIDE SGHarvestCapture's drain bracket",
        marks ~= nil and hc ~= nil and marks.original == hc.wrapper and Combine.onUpdateTick == marks.wrapper)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    m.time = m.time + 200                       -- the slot is past its delay
    local slot = w.combine.spec_combine.loadingDelaySlots[1]
    local slotStock = stockAt(sg, cid(NA.combineSlotBinding(w.combine, NA.KIND_DELAY_SLOT, 1)))
    local slotStockId = slotStock and slotStock.stockId or "none"
    local inHook = {}
    REAL.ENGINE_CAREER_HOOK = function()
        -- A re-entrant tick raised through the class, as the engine raises the event.
        for _, class in ipairs(w.combine.specClasses) do class.onUpdateTick(w.combine, 16, false, false, false) end
        inHook.valid, inHook.hopper, inHook.drain = slot.valid, w.combine:getFillUnitFillLevel(1), host.lastDrain
    end
    local drainBefore = host.lastDrain
    ENGINE_SAVE.finalDir = "d_final"
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    local afterStart = { valid = slot.valid, hopper = w.combine:getFillUnitFillLevel(1), drain = host.lastDrain }
    ENGINE_RUN_FRAMES()
    T.eq("D2 a drain tick raised while the boundary is open is held: the due slot stays valid and the hopper empty through the rest of the chain",
        tostring(inHook.valid) .. "/" .. num(inHook.hopper) .. "/" .. tostring(inHook.drain == drainBefore), "true/0/true")
    T.eq("D3 when the start call returns, the held tick runs once: the slot drains into the hopper as ONE TRANSFER through the drain bracket",
        tostring(afterStart.valid) .. "/" .. num(afterStart.hopper) .. "/" .. tostring(afterStart.drain ~= drainBefore) .. "/" .. tostring(afterStart.drain and afterStart.drain.outcome), "false/6/true/COMMITTED")
    T.eq("D4 the saved vehicle carries the slot the envelope carries: one snapshot", tostring(ENGINE_DISK["d_final/vehicles.xml"]["vehicles.vehicle(0).combine." .. B.ELEMENT .. ".delaySlot(0)#fillLevelDelta"]), "6")
    REAL.ENGINE_CAREER_HOOK = nil
    local m2, sg2, host2, w2 = reload(m, "d_final", function(m2, w2)
        w2.combine = loadCombine(m2, "vehicle:delay", OPTS, "d_final")
    end, { index = 19 })
    local s = stockAt(sg2, cid(NA.combineSlotBinding(w2.combine, NA.KIND_DELAY_SLOT, 1)))
    T.eq("D5 on reload the restored slot carries the SAME stock it had before the save (reattached by identity, SGOperations.lua:1877), not a fresh one: the envelope was written with the slot still holding its litres",
        tostring(slotStockId ~= "none") .. "/" .. tostring(s and s.stockId == slotStockId) .. "/" .. num(s and s.observedAmount) .. ":" .. tostring(s and s.materialRef.fillTypeName), "true/true/6:WHEAT")
    -- Outside the boundary a tick runs at once.
    local slot2 = w2.combine.spec_combine.loadingDelaySlots[1]
    m2.time = m2.time + 500
    ENGINE_HARVEST_TICK(nil, w2.combine, 16)
    T.eq("D6 outside a save a tick runs immediately (the deferral is a pass-through)", tostring(slot2.valid) .. "/" .. num(w2.combine:getFillUnitFillLevel(1)), "false/6")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE CODEC
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local function cell(x, z, liters, gen, prop) return { x = x, z = z, fillType = "WHEAT", liters = liters, generation = gen or 1, property = prop } end
    local props = { p1 = { moisture = 0.5 } }
    local cells = {}
    for _, c in ipairs({ cell(3, 7, 2), cell(4, 7, 2), cell(5, 7, 2), cell(7, 7, 2), cell(8, 7, 3), cell(3, 8, 2, 1, "p1") }) do cells[GR.cellKey(c.x, c.z)] = c end
    local runs = GR.encodeCells(cells, props)
    local shape = {}
    for _, r in ipairs(runs) do shape[#shape + 1] = r.z .. ":" .. r.x .. "+" .. r.n end
    T.eq("C1 identical adjacent cells along x coalesce into one run; a gap, other litres or another row start a new one", table.concat(shape, ","), "7:3+3,7:7+1,7:8+1,8:3+1")
    local back = GR.decodeRuns(runs, props)
    local same = true
    for k, c in pairs(cells) do local b = back[k] if b == nil or b.liters ~= c.liters or b.property ~= c.property or b.generation ~= c.generation then same = false end end
    for k in pairs(back) do if cells[k] == nil then same = false end end
    T.eq("C2 runs decode back to exactly the cells", same, true)
    T.eq("C3 overlapping runs are refused", select(2, GR.decodeRuns({ { z = 1, x = 1, n = 2, fillType = "WHEAT", liters = 1, generation = 1 }, { z = 1, x = 2, n = 1, fillType = "WHEAT", liters = 1, generation = 1 } }, {})), "OVERLAP:2:1")
    T.eq("C4 an unknown property, a negative coordinate and a generation of 0 are refused",
        tostring((select(2, GR.decodeRuns({ { z = 1, x = 1, n = 1, fillType = "WHEAT", liters = 1, generation = 1, property = "nope" } }, {})))) .. "/"
        .. tostring((select(2, GR.decodeRuns({ { z = 1, x = -1, n = 1, fillType = "WHEAT", liters = 1, generation = 1 } }, {})))) .. "/"
        .. tostring((select(2, GR.decodeRuns({ { z = 1, x = 1, n = 1, fillType = "WHEAT", liters = 1, generation = 0 } }, {})))),
        "RUN:1:PROPERTY/RUN:1:COORDINATES/RUN:1:GENERATION")
    -- A populated ground through a real save and reload. The cells are bench-made (the one
    -- hand-populated fixture in this file; nothing produces a cell before SG2-4b).
    resetEngine()
    local m, sg = boot(nil, "c_save", { index = 20 })
    sg.ground.cells, sg.ground.properties = cells, props
    nativeSave(m, false, "c_final")
    local m2, sg2 = reload(m, "c_final", nil, { index = 20 })
    local restored, n = sg2.ground.cells, 0
    local equal = true
    for k, c in pairs(cells) do n = n + 1 local b = restored[k] if b == nil or b.liters ~= c.liters or b.property ~= c.property then equal = false end end
    T.eq("C5 a populated ground set survives a real save and reload: every cell and its shared property", readiness(sg2) .. "/" .. n .. "/" .. tostring(equal) .. "/" .. tostring(sg2.ground.properties.p1 and sg2.ground.properties.p1.moisture), "READY/nil/6/true/0.5")
    FSBaseMission.delete(m2)
end)
