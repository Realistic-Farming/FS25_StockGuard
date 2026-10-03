-- SG2-4b2-sowing_profile_spec_test.lua
--
-- SG-2 v2.3 :243 (as corrected 2026-10-03) and :177: the plain-sowing clause StockGuard #27 did not
-- carry (DESIGN-CHECK row 171), on Bob's intake (Desk Office/Drafts/BOB-INTAKE-SG27-PLAIN-SOWING-2026-10-03.md).
-- A sowing machine's own process call, processSowingMachineArea, runs inside a Destruction profile: the
-- same before and after cell sample the shovel and leveler use, over its work area's parallelogram. A
-- tracked cell empty after the call retires as Destruction; one changed but not empty goes unknown;
-- unchanged records nothing; a cell an inner wrapped primitive judged in the same call (direct sowing's
-- clearArea, FSDensityMapUtil.lua:2303) is never judged again.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b2 bench's world (its preamble, verbatim).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path; a sowing machine built as the engine builds its
-- OWN type (vehicleTypes.xml `sowingMachine`: workArea, fillUnit and sowingMachine among the parent
-- baseGroundToolFillable's chain; `fertilizingSowingMachine` adds sprayer and fertilizingSowingMachine,
-- whose processSowingMachineArea overrides through Utils.overwrittenFunction), its work area's pointer
-- captured at load the way WorkArea.lua:266 captures it; the native host observes it at the barrier and
-- the installer brackets the CAPTURED pointer; then the engine's order: the start event and the captured
-- call (WorkArea.lua:183), over a pile the real tip path laid and StockGuard tracks. Nothing writes a
-- binding, a carrier, a stock or a cell by hand.
--
-- THE ONE PATH NO SOURCE SHOWS IS A MODEL. Plain updateSowingArea (:1998-2110) makes no Lua height call,
-- and that absence "proves neither an unseen C++ clear nor no clearing" (Design's 2026-10-03
-- clarification). No API exists for such a write, so the rows that need one (E, U, F1, T) stand it in
-- with `unseen`: a write straight to the native height layer inside the modelled updateSowingArea,
-- bypassing every Lua wrapper. It models the unobservable path; it is not a claim that native does it.
--
-- Groups:
--   E  the entry-point bar: a modelled unseen clear under plain sowing retires the pile as Destruction, once;
--      the envelope reaches the parallelogram's far edge
--   P  plain sowing that changes nothing: no operation; the pointer's returns unchanged (a control)
--   U  a partial height change and a type change: unknown, not retired
--   D  direct sowing: the util wrap retires the cleared cells and the profile books nothing more (a control
--      for the world, and the no-double-retirement row for the profile)
--   N  a wrapped primitive inside the call that leaves its cells tracked and changed: not judged again
--   F  the fertilizing type: the override's captured pointer is bracketed, plain and direct
--   C  a client: nothing installed, and a bracket reached on a client opens nothing (a control)
--   R  an envelope with no tracked cell: no read (a control), the profile's skip counted
--   T  a throw from the native call: the bracket closes, the error and nothing else reach the engine
--
-- NOT HERE: Bob's literal row 5, a tracked cell only partly inside direct sowing's clear polygon keeping a
-- remainder, cannot arise on this bench: the modelled clearArea zeroes whole pixels (the centre rule) and a
-- typeless height reads empty. Group N exercises the same exclusion with a wrapped primitive whose cells stay
-- tracked and changed. In game (TESTING row): heap kept against heap removed, the nested util case, and the
-- read cost of a wide seeder over tracked heaps.
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, tools/test/lua/SG2-4b2-smoother_area_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGGroundBrush.lua, src/native/SGGroundArea.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua


local REAL = getmetatable(_G).__index
local M, GR, GO, NH, NA = SGNativeMaterialSave, SGGround, SGGroundObserver, SGNativeHost, SGNativeAdapters
local B, AR = SGGroundBrush, SGGroundArea
local WHEAT, BARLEY = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY
local HT = ENGINE_HT
local G_ = ENGINE_GROUND

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
local function has(lines, pattern) for _, l in ipairs(lines) do if l:find(pattern, 1, true) then return true end end return false end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir, opts)
    local m = setmetatable({ _server = true, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, time = 1000,
        terrainSize = 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND, tireTrackSystem = ENGINE_TIRE_TRACKS,
        weedSystem = ENGINE_WEED, userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = opts.index or 1, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

-- ── a property producer, as a domain owner registers one ─────────────────────
local PROP = "sg24b2.origin"
local function origin(value, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "sg24b2", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { o = value } }
end
local originSpec = { schemaVersion = 1, producerId = "sg24b2", residency = "STORED",
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total, w, known = 0, 0, 0
        for _, c in ipairs(contributions) do
            local p = c.properties[PROP]
            total = total + c.amount
            if p and p.payload then w = w + p.payload.o * c.amount known = known + c.amount end
        end
        if before then
            local p = before.properties[PROP]
            total = total + before.observedAmount
            if p and p.payload then w = w + p.payload.o * before.observedAmount known = known + before.observedAmount end
        end
        if total == 0 or known == 0 then return nil, "NO_MATERIAL" end
        local r = origin(w / known, known)
        r.basisAmount = total
        r.knowledge = known >= total - 1e-6 and "KNOWN" or "PARTIAL"
        return r
    end,
    transform = function() return nil end, disclosure = function(_, r) return r end }

--- Boot through main.lua's load path. opts.duringLoad(m) runs in the async load window:
--- after loadMission00Finished queued the placeable load (and main's append installed the
--- brackets), before the restore-complete barrier at onFinishedLoading.
local function boot(build, saveDir, opts)
    opts = opts or {}
    local m = newMission(saveDir or "save", opts)
    engine("g_server", {})
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local w = {}
    if build ~= nil then build(m, w) end
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    local lease = m.stockGuard.registerProperty(PROP, originSpec)
    Mission00.loadMission00Finished(m)
    if opts.duringLoad ~= nil then opts.duringLoad(m, w) end
    m:onFinishedLoading()
    return m, sg, NH.current, w, lease
end
local function vehicleIn(m, v) m._vehicles[#m._vehicles + 1] = v return v end
local function resetWorld()
    G_.reset()
    ENGINE_SMOOTH.reset()
    REAL.ENGINE_PREPARE_LOG, REAL.ENGINE_DIRECT_LOG, REAL.ENGINE_PREPARED = {}, {}, {}
    g_asyncTaskManager.tasks = {}
    ENGINE_RAYCASTS = {}
    g_densityMapHeightManager.convertingFillTypesAreas = {}
    M.deferral.depth, M.deferral.queue = 0, {}
end
engine("g_savegameController", SavegameController.new())

-- ── readers ────────────────────────────────────────────────────────────────
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function unitId(v, i) return cid(NA.fillUnitBinding(v, i or 1)) end
local function stockAt(sg, id) local c = sg.operations.carriers[id] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end
local function publish(m, sg, lease, id, value)
    local s = stockAt(sg, id)
    if s == nil then return "NO_STOCK" end
    return m.stockGuard.publishProperties(lease, { { stockRef = sg.operations:stockRef(s), expectedPropertyRevision = 0, record = origin(value, s.observedAmount) } })
end
--- The ground stock of pixel (x, z), or nil.
local function cellStock(sg, host, x, z)
    local s = host:groundSampler()
    local id = s ~= nil and s.tracked ~= nil and s.tracked[GR.cellKey(x, z)] or nil
    return id and stockAt(sg, id) or nil, id
end
local function propAt(sg, host, x, z)
    local st = cellStock(sg, host, x, z)
    if st == nil then return "none" end
    local p = st.properties[PROP]
    if p == nil then return tostring(st.knowledge) .. ":-" end
    return tostring(st.knowledge) .. ":" .. num(p.payload.o)
end
local function groundCount(sg)
    local n, total = 0, 0
    for _, c in pairs(sg.operations.carriers) do
        if NA.isGroundKey(c.binding.carrierKey) then
            n = n + 1
            local s = c.stockId and sg.operations.stocks[c.stockId] or nil
            total = total + (s and s.observedAmount or 0)
        end
    end
    return n, total
end
local function last(host)
    local ls = host.lastSettlement
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome) .. (ls and ls.reason and ("/" .. tostring(ls.reason)) or "")
end

-- ── the world builders ─────────────────────────────────────────────────────
-- Pixel (px, pz) has its centre at ((p + 0.5) * 0.5 - 128). The four pixels around the
-- corner (10, 10) are 275..276 on each axis; a brush centred on that corner with R = 0.5
-- holds exactly those four in its core.
local CX, CZ = 275, 275
local function centreOf(px, pz) return (px + 0.5) * 0.5 - 128, (pz + 0.5) * 0.5 - 128 end
--- A thin tipper whose unit carries o = `o`: its discharge lands on the one pixel under it.
local function dot(m, w, name, o)
    w[name] = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. name, { level = 400, fillType = WHEAT, at = { x = 0, z = 0 }, width = 0.01 }))
    w[name .. "O"] = o
end
local function tipOn(v, px, pz, liters)
    local node = v.spec_dischargeable.dischargeNodes[1].info.node
    node.x, node.z = centreOf(px, pz)
    ENGINE_TIP(v, liters)
end

-- ── the engine's sowing code (1.24, reduced; each reduction named) ──────────────────────
SowingMachine = SowingMachine or {}
SowingMachine.CLIENT_DM_UPDATE_RADIUS = SowingMachine.CLIENT_DM_UPDATE_RADIUS or 50
FertilizingSowingMachine = FertilizingSowingMachine or {}
FertilizingSowingMachine.CLIENT_DM_UPDATE_RADIUS = FertilizingSowingMachine.CLIENT_DM_UPDATE_RADIUS or 50
SprayType = SprayType or { FERTILIZER = 1 }
WorkAreaType = WorkAreaType or {}
WorkAreaType.SOWINGMACHINE = WorkAreaType.SOWINGMACHINE or 23

--- The stand-in for the path no source shows (see the header): nil, or function(sx, sz, wx, wz, hx, hz).
local unseen = nil
--- FSDensityMapUtil.updateSowingArea (:1998-2110): its body changes the weed, spray and displacement layers
--- and makes no height call, so none is modelled; `unseen` is the model of a write no source shows. Its two
--- returns (the changed and total area its callers add up, FertilizingSowingMachine.lua:113-115) are
--- modelled as the work area's four pixels.
function FSDensityMapUtil.updateSowingArea(fruitIndex, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
    if unseen ~= nil then unseen(startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ) end
    return 4, 4
end
--- FSDensityMapUtil.updateDirectSowingArea (:2111-2306) reduced to its height clear (:2303, VERBATIM): the
--- foliage, weed and spray work before it touches no height.
function FSDensityMapUtil.updateDirectSowingArea(fruitIndex, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
    DensityMapHeightUtil.clearArea(startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
    return 4, 4
end
--- The tire-track erase, the stone read and the spray update write other layers, never the height layer.
FSDensityMapUtil.eraseTireTrack = FSDensityMapUtil.eraseTireTrack or function() end
FSDensityMapUtil.getStoneArea = FSDensityMapUtil.getStoneArea or function() return 0 end
FSDensityMapUtil.updateSprayArea = FSDensityMapUtil.updateSprayArea or function() return 0, 0 end

--- SowingMachine:processSowingMachineArea (:362-430), its order kept. Reduced: the AI stops beside the
--- water and seed returns (no AI here), the field-type warning (:403-413, a HUD flag; the bench's fruits
--- name no seedRequiredFieldType) and updateMissionSowingWarning (:431-440, a HUD flag). The decompile
--- re-declares `local changedArea` before the util call (:415), which would make :424 add nil; it is read
--- as the util's two returns, as the fertilizing override's own body has them (:95-97, :113-117).
function SowingMachine:processSowingMachineArea(workArea, _)
    local spec = self.spec_sowingMachine
    local changedArea = 0
    local totalArea = 0
    spec.isWorking = self:getLastSpeed() > 0.5
    if spec.waterSeeding and not self.isInWater then
        spec.showWaterPlantingRequiredWarning = true
        return changedArea, totalArea
    end
    if not spec.waterSeeding and self.isInWater then
        spec.showWaterPlantingProhibitedWarning = true
        return changedArea, totalArea
    end
    if not spec.workAreaParameters.isActive then
        return changedArea, totalArea
    end
    if spec.workAreaParameters.seedsVehicle == nil then
        return changedArea, totalArea
    end
    if not spec.workAreaParameters.canFruitBePlanted then
        return changedArea, totalArea
    end
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    FSDensityMapUtil.eraseTireTrack(sx, sz, wx, wz, hx, hz)
    if not self.isServer and self.currentUpdateDistance > SowingMachine.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    spec.isProcessing = spec.isWorking
    if spec.useDirectPlanting then
        changedArea, totalArea = FSDensityMapUtil.updateDirectSowingArea(spec.workAreaParameters.seedsFruitType, sx, sz, wx, wz, hx, hz, spec.workAreaParameters.fieldGroundType, spec.workAreaParameters.ridgeSeeding, spec.workAreaParameters.angle, nil)
    else
        changedArea, totalArea = FSDensityMapUtil.updateSowingArea(spec.workAreaParameters.seedsFruitType, sx, sz, wx, wz, hx, hz, spec.workAreaParameters.fieldGroundType, spec.workAreaParameters.ridgeSeeding, spec.workAreaParameters.angle, nil)
    end
    if spec.isWorking then
        spec.stoneLastState = FSDensityMapUtil.getStoneArea(sx, sz, wx, wz, hx, hz)
    else
        spec.stoneLastState = 0
    end
    spec.workAreaParameters.lastChangedArea = spec.workAreaParameters.lastChangedArea + changedArea
    spec.workAreaParameters.lastStatsArea = spec.workAreaParameters.lastStatsArea + changedArea
    spec.workAreaParameters.lastTotalArea = spec.workAreaParameters.lastTotalArea + totalArea
    return changedArea, totalArea
end

--- FertilizingSowingMachine:processSowingMachineArea (:26-117), a full body with no superFunc call, its order
--- kept. Reduced as above, plus the AI spray-source check (:50-58) and the farm stats (:106-111).
function FertilizingSowingMachine:processSowingMachineArea(_, workArea, dt)
    local specSowingMachine = self.spec_sowingMachine
    local specSpray = self.spec_sprayer
    local sprayerParams = specSpray.workAreaParameters
    local sowingParams = specSowingMachine.workAreaParameters
    specSowingMachine.isWorking = self:getLastSpeed() > 0.5
    if specSowingMachine.waterSeeding and not self.isInWater then
        specSowingMachine.showWaterPlantingRequiredWarning = true
        return 0, 0
    end
    if not specSowingMachine.waterSeeding and self.isInWater then
        specSowingMachine.showWaterPlantingProhibitedWarning = true
        return 0, 0
    end
    if not sowingParams.isActive then
        return 0, 0
    end
    if sowingParams.seedsVehicle == nil then
        return 0, 0
    end
    if not sowingParams.canFruitBePlanted then
        return 0, 0
    end
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    FSDensityMapUtil.eraseTireTrack(sx, sz, wx, wz, hx, hz)
    if not self.isServer and self.currentUpdateDistance > FertilizingSowingMachine.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local sprayTypeIndex = SprayType.FERTILIZER
    if sprayerParams.sprayFillLevel <= 0 or self.spec_fertilizingSowingMachine.needsSetIsTurnedOn and not self:getIsTurnedOn() then
        sprayTypeIndex = nil
    end
    local cx, cz
    if specSowingMachine.useDirectPlanting then
        cx, cz = FSDensityMapUtil.updateDirectSowingArea(sowingParams.seedsFruitType, sx, sz, wx, wz, hx, hz, sowingParams.fieldGroundType, sowingParams.ridgeSeeding, sowingParams.angle, nil, sprayTypeIndex)
    else
        cx, cz = FSDensityMapUtil.updateSowingArea(sowingParams.seedsFruitType, sx, sz, wx, wz, hx, hz, sowingParams.fieldGroundType, sowingParams.ridgeSeeding, sowingParams.angle, nil, sprayTypeIndex)
    end
    specSowingMachine.isProcessing = specSowingMachine.isWorking
    if sprayTypeIndex ~= nil then
        local changed, total = FSDensityMapUtil.updateSprayArea(sx, sz, wx, wz, hx, hz, sprayTypeIndex, 1)
        sprayerParams.lastChangedArea = sprayerParams.lastChangedArea + changed
        sprayerParams.lastTotalArea = sprayerParams.lastTotalArea + total
        sprayerParams.isActive = true
    end
    sowingParams.lastChangedArea = sowingParams.lastChangedArea + cx
    sowingParams.lastStatsArea = sowingParams.lastStatsArea + cx
    sowingParams.lastTotalArea = sowingParams.lastTotalArea + cz
    return cx, cz
end

--- SowingMachine:onStartWorkAreaProcessing (:663-743), reduced to the parameters the process call reads, as
--- it sets them for a turned-on machine seeding WHEAT from its own tank in season.
function SowingMachine:onStartWorkAreaProcessing(_)
    local spec = self.spec_sowingMachine
    spec.isWorking, spec.isProcessing = false, false
    local p = spec.workAreaParameters
    p.isActive, p.canFruitBePlanted, p.seedsFruitType = true, true, FruitType.WHEAT
    p.fieldGroundType, p.ridgeSeeding, p.angle, p.seedsVehicle = spec.fieldGroundType, spec.ridgeSeeding, 0, self
    p.lastTotalArea, p.lastChangedArea, p.lastStatsArea = 0, 0, 0
end

--- A sowing machine as the engine builds its own type (vehicleTypes.xml, the header): a fill unit (the seed
--- tank), spec_workArea and spec_sowingMachine; the fertilizing type adds spec_sprayer and
--- spec_fertilizingSowingMachine, and its processSowingMachineArea is the override chained by
--- Utils.overwrittenFunction (SpecializationUtil.lua:49-60, Utils.lua:394-402) and copied onto the instance
--- (SpecializationUtil.lua:141-145). Its one work area covers the world box [9.5, 10.5] on both axes, the four
--- pixels around the corner (10, 10); opts.at shifts it along x, and opts.depth (metres) deepens it along z.
local function newSeeder(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = 0, capacity = 1000, supported = { [WHEAT] = true } })
    v.configFileName = opts.fertilizing and "data/vehicles/fertilizingSowingMachine.xml" or "data/vehicles/sowingMachine.xml"
    v.isServer, v.isInWater, v.currentUpdateDistance = true, false, 0
    v.getLastSpeed = function() return 5 end
    v.getIsTurnedOn = function() return true end
    v.spec_sowingMachine = { useDirectPlanting = opts.direct == true, waterSeeding = false, fieldGroundType = 1, ridgeSeeding = false, stoneLastState = 0,
        workAreaParameters = { lastChangedArea = 0, lastStatsArea = 0, lastTotalArea = 0 } }
    if opts.fertilizing then
        v.spec_sprayer = { workAreaParameters = { sprayFillLevel = 100, lastChangedArea = 0, lastTotalArea = 0 } }
        v.spec_fertilizingSowingMachine = { needsSetIsTurnedOn = false }
        v.processSowingMachineArea = Utils.overwrittenFunction(SowingMachine.processSowingMachineArea, FertilizingSowingMachine.processSowingMachineArea)
    else
        v.processSowingMachineArea = SowingMachine.processSowingMachineArea
    end
    local dx, depth = opts.at or 0, opts.depth or 1
    local wa = { index = 1, type = WorkAreaType.SOWINGMACHINE, functionName = "processSowingMachineArea",
                 start = { x = 9.5 + dx, y = 0, z = 9.5 }, width = { x = 10.5 + dx, y = 0, z = 9.5 }, height = { x = 9.5 + dx, y = 0, z = 9.5 + depth } }
    -- WorkArea.lua:266 VERBATIM: the loader captures the pointer the engine will call.
    wa.processingFunction = v[wa.functionName]
    v.spec_workArea = { workAreas = { wa } }
    return v, wa
end
--- One pass in the engine's order: the start event, then WorkArea.lua:183's call of the captured pointer.
local function pass(v, wa)
    SowingMachine.onStartWorkAreaProcessing(v, nil)
    return wa.processingFunction(v, wa, 16)
end

--- THE MODEL of an unseen native clear: the native modifiers written directly over the parallelogram, so no
--- Lua wrapper sees it (the 2026-10-03 clarification's "unseen C++ clear"; no API exists).
local function unseenClear(sx, sz, wx, wz, hx, hz)
    local h = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.heightFirstChannel, DensityMapHeightUtil.heightNumChannels)
    local t = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.typeFirstChannel, DensityMapHeightUtil.typeNumChannels)
    h:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    t:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    h:executeSet(0)
    t:executeSet(0)
end

--- The standard sown world: two dot tippers (o = 7, o = 3) and a seeder whose work area covers the corner
--- (10, 10), where the tippers then lay a tracked pile: 8 L on (CX, CZ) with o = 3, 8 L each on (CX, CZ + 1)
--- and (CX + 1, CZ + 1) with o = 7.
local function sown(index, opts)
    resetWorld()
    unseen = nil
    local m, sg, host, w, lease = boot(function(m, w)
        dot(m, w, "dot7", 7)
        dot(m, w, "dot3", 3)
        w.seeder, w.wa = newSeeder("vehicle:seeder", opts)
        vehicleIn(m, w.seeder)
    end, "s_save", { index = index })
    publish(m, sg, lease, unitId(w.dot7), 7)
    publish(m, sg, lease, unitId(w.dot3), 3)
    tipOn(w.dot7, CX + 1, CZ + 1, 8)
    tipOn(w.dot7, CX, CZ + 1, 8)
    tipOn(w.dot3, CX, CZ, 8)
    return m, sg, host, w, lease
end
--- The profile's and the util wrap's counters; a counter the code under test lacks reads 0.
local function snap()
    local s = AR.sowStats or {}
    return { calls = s.calls, removed = s.removed, abandoned = s.abandoned, untracked = s.untracked,
             native = s.refused and s.refused.NATIVE_ERROR or 0, areaRemoved = AR.stats.removed, areaAbandoned = AR.stats.abandoned }
end
local function delta(a, b, k)
    local x, y = a[k], b[k]
    if type(x) ~= "number" then x = 0 end
    if type(y) ~= "number" then y = 0 end
    return tostring(y - x)
end
local function legsOf(ao)
    local n, litres = 0, 0
    for _, l in ipairs(ao.report and ao.report.allocations or {}) do
        if l.destination.retire == true and l.result == "DESTROYED" then n = n + 1 litres = litres + l.sourceAmount end
    end
    return n .. "/" .. num(litres)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A MODELLED UNSEEN CLEAR UNDER PLAIN SOWING
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local m, sg, host, w = sown(81)
    local n0, l0 = groundCount(sg)
    local rec = w.wa._sgBrackets and w.wa._sgBrackets.processSowingMachineArea
    T.eq("E0 [reached] the host bracketed the work area's CAPTURED pointer at the barrier, over a tracked pile of 3 cells and 24 L",
        tostring(rec ~= nil and w.wa.processingFunction == rec.ours and rec.original == SowingMachine.processSowingMachineArea) .. "/" .. n0 .. "/" .. num(l0), "true/3/24")
    unseen = unseenClear
    local s0 = snap()
    local a, b = pass(w.seeder, w.wa)
    local s1 = snap()
    local ao = host.lastAreaOperation or {}
    T.eq("E1 NAMED [entry point]: a modelled unseen clear under plain sowing: one REMOVE retiring every tracked cell's actual litres as DESTROYED, the carriers withdrawn",
        tostring(ao.method) .. "/" .. tostring(ao.outcome) .. "/" .. num(ao.removed) .. "/" .. tostring(ao.evidence and ao.evidence.nativePath) .. "/" .. n0 .. ">" .. (groundCount(sg)),
        "processSowingMachineArea/COMMITTED/24/GROUND_SOWING_PROFILE/3>0")
    T.eq("E2 NAMED: exactly once: 3 DESTROYED legs of 24 L in the profile's one operation, and the util wrap saw no clear (the write bypassed every Lua wrapper)",
        legsOf(ao) .. "/" .. delta(s0, s1, "removed") .. "/" .. delta(s0, s1, "areaRemoved"), "3/24/1/0")
    T.eq("E3 the engine got the call's own returns through the bracket", tostring(a) .. "/" .. tostring(b), "4/4")
    FSBaseMission.delete(m)
    -- A deeper work area: a cell 1.75 m in, which only the parallelogram's height corner reaches.
    m, sg, host, w = sown(91, { depth = 2 })
    tipOn(w.dot7, CX, CZ + 3, 8)
    unseen = unseenClear
    pass(w.seeder, w.wa)
    ao = host.lastAreaOperation or {}
    T.eq("E4 NAMED: the envelope is the whole parallelogram: in a 2 m deep work area the cell only its far edge reaches is retired with the rest",
        num(ao.removed) .. "/" .. (groundCount(sg)), "32/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. PLAIN SOWING THAT CHANGES NOTHING
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local m, sg, host, w = sown(82)
    local q0, s0 = host.lastAreaOperation, snap()
    local a, b = pass(w.seeder, w.wa)
    local s1 = snap()
    T.eq("P1 [control] plain sowing that changes no height: nothing recorded, every cell keeps its stock and facts, the returns unchanged",
        tostring(host.lastAreaOperation == q0) .. "/" .. (groundCount(sg)) .. "/" .. propAt(sg, host, CX, CZ) .. "/" .. propAt(sg, host, CX + 1, CZ + 1) .. "/" .. tostring(a) .. "/" .. tostring(b),
        "true/3/KNOWN:3/KNOWN:7/4/4")
    T.eq("P2 NAMED: the profile read the pile before and after and booked nothing", delta(s0, s1, "calls") .. "/" .. delta(s0, s1, "removed") .. "/" .. delta(s0, s1, "abandoned"), "1/0/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. A CHANGE NO PRIMITIVE ACCOUNTS FOR IS UNKNOWN, NOT A RETIREMENT
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local m, sg, host, w = sown(83)
    local raw, raw2 = G_.raw(CX, CZ), G_.raw(CX + 1, CZ + 1)
    unseen = function()
        G_.put(CX, CZ, HT.WHEAT.index, math.floor(raw / 2))
        G_.put(CX + 1, CZ + 1, HT.BARLEY.index, raw2)
    end
    local s0 = snap()
    pass(w.seeder, w.wa)
    local s1 = snap()
    local ao = host.lastAreaOperation or {}
    T.eq("U1 NAMED: a partial height loss and a type change with no accounted primitive: both cells unknown (abandoned), none retired",
        tostring(ao.outcome) .. "/" .. tostring(ao.reason) .. "/" .. tostring(ao.cells) .. "/" .. delta(s0, s1, "abandoned") .. "/" .. delta(s0, s1, "removed"),
        "ABANDONED/UNACCOUNTED_CHANGE/2/1/0")
    T.eq("U2 NAMED: the core's abandon rule, as on #27's worked patch: the lowered cell's facts stay but are qualified as unproved (UNAVAILABLE), the retyped cell's new material is UNKNOWN and inherits nothing; the unchanged cell keeps its own; no carrier is withdrawn",
        propAt(sg, host, CX, CZ) .. "/" .. propAt(sg, host, CX + 1, CZ + 1) .. "/" .. propAt(sg, host, CX, CZ + 1) .. "/" .. (groundCount(sg)),
        "UNAVAILABLE:3/UNKNOWN:-/KNOWN:7/3")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. DIRECT SOWING: THE UTIL WRAP RETIRES, THE PROFILE BOOKS NOTHING MORE
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local m, sg, host, w = sown(84, { direct = true })
    local s0 = snap()
    pass(w.seeder, w.wa)
    local s1 = snap()
    local ao = host.lastAreaOperation or {}
    T.eq("D1 [control] direct sowing (useDirectPlanting): the util wrap's clearArea (:2303) retires the pile once, 24 L, the carriers withdrawn",
        tostring(ao.method) .. "/" .. num(ao.removed) .. "/" .. legsOf(ao) .. "/" .. (groundCount(sg)) .. "/" .. delta(s0, s1, "areaRemoved"), "clearArea/24/3/24/0/1")
    T.eq("D2 NAMED: the profile opened around it and booked nothing more: no second retirement, no unknown",
        delta(s0, s1, "calls") .. "/" .. delta(s0, s1, "removed") .. "/" .. delta(s0, s1, "abandoned"), "1/0/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. A WRAPPED PRIMITIVE THAT LEAVES ITS CELLS TRACKED AND CHANGED
-- ══════════════════════════════════════════════════════════════════════════
-- A MODEL of a future path, not a native claim: a wrapped util primitive called inside the sowing call whose
-- cells stay tracked and changed (a conversion with no registered basis, :280). "Is the cell still tracked
-- after the call" cannot tell these cells from unaccounted ones; the profile's accounted set can.
group("N", function()
    local m, sg, host, w = sown(85)
    unseen = function(sx, sz, wx, wz, hx, hz) DensityMapHeightUtil.changeFillTypeAtArea(sx, sz, wx, wz, hx, hz, WHEAT, BARLEY) end
    local s0 = snap()
    pass(w.seeder, w.wa)
    local s1 = snap()
    local ao = host.lastAreaOperation or {}
    T.eq("N1 NAMED: the inner wrapped conversion judged its cells (CONVERSION_UNREGISTERED) and they stay tracked; the profile opened and does not judge them again",
        tostring(ao.method) .. "/" .. tostring(ao.reason) .. "/" .. (groundCount(sg)) .. "/" .. delta(s0, s1, "areaAbandoned") .. "/" .. delta(s0, s1, "calls") .. "/" .. delta(s0, s1, "abandoned") .. "/" .. delta(s0, s1, "removed"),
        "changeFillTypeAtArea/CONVERSION_UNREGISTERED/3/1/1/0/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE FERTILIZING TYPE'S OVERRIDE
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m, sg, host, w = sown(86, { fertilizing = true })
    local rec = w.wa._sgBrackets and w.wa._sgBrackets.processSowingMachineArea
    T.eq("F0 [reached] the fertilizing type's captured pointer is the override chain, not SowingMachine's own function, and it is bracketed",
        tostring(rec ~= nil and rec.original ~= SowingMachine.processSowingMachineArea and w.wa.processingFunction == rec.ours), "true")
    unseen = unseenClear
    local s0 = snap()
    local a = pass(w.seeder, w.wa)
    local s1 = snap()
    local ao = host.lastAreaOperation or {}
    T.eq("F1 NAMED: plain fertilizing sowing under the modelled unseen clear: one REMOVE through the override's bracket, 24 L, once",
        tostring(ao.evidence and ao.evidence.nativePath) .. "/" .. num(ao.removed) .. "/" .. (groundCount(sg)) .. "/" .. delta(s0, s1, "removed") .. "/" .. tostring(a) .. "/" .. tostring(w.seeder.spec_sprayer.workAreaParameters.isActive),
        "GROUND_SOWING_PROFILE/24/0/1/4/true")
    FSBaseMission.delete(m)
    m, sg, host, w = sown(87, { fertilizing = true, direct = true })
    s0 = snap()
    pass(w.seeder, w.wa)
    s1 = snap()
    ao = host.lastAreaOperation or {}
    T.eq("F2 NAMED: direct fertilizing sowing: the util wrap retires once and the profile books nothing more",
        tostring(ao.method) .. "/" .. num(ao.removed) .. "/" .. delta(s0, s1, "calls") .. "/" .. delta(s0, s1, "removed") .. "/" .. delta(s0, s1, "abandoned"), "clearArea/24/1/0/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A CLIENT
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local m, sg, host, w = sown(88)
    local server = REAL.g_server
    REAL.g_server = nil
    local v2, wa2 = newSeeder("vehicle:clientSeeder", { at = 4 })
    local captured = wa2.processingFunction
    local okObs = pcall(GO.observeVehicle, v2)
    local s0 = snap()
    local ok, a = pcall(pass, w.seeder, w.wa)
    local s1 = snap()
    REAL.g_server = server
    T.eq("C1 [control] on a client the installer brackets nothing: the work area keeps its captured pointer",
        tostring(okObs) .. "/" .. tostring(wa2._sgBrackets == nil and wa2.processingFunction == captured), "true/true")
    T.eq("C2 [control] a bracket reached with no server opens no profile, and the call runs with its returns",
        tostring(ok) .. "/" .. tostring(a) .. "/" .. delta(s0, s1, "calls") .. "/" .. (groundCount(sg)), "true/4/0/3")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. AN ENVELOPE WITH NO TRACKED CELL
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    resetWorld()
    unseen = nil
    local m, sg, host, w = boot(function(m, w)
        w.seeder, w.wa = newSeeder("vehicle:seeder")
        vehicleIn(m, w.seeder)
    end, "r_save", { index = 89 })
    G_.put(CX, CZ, HT.WHEAT.index, 4)
    local q0, s0 = G_.queries, snap()
    pass(w.seeder, w.wa)
    local q1, s1 = G_.queries, snap()
    T.eq("R1 [control] an envelope holding no tracked cell (material the map holds, untracked): no ground query in the call, nothing recorded",
        tostring(q1 - q0) .. "/" .. tostring(host.lastAreaOperation), "0/nil")
    T.eq("R2 NAMED: the profile was reached and skipped on the tracked check", delta(s0, s1, "calls") .. "/" .. delta(s0, s1, "untracked"), "1/1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. A THROW FROM THE NATIVE CALL
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local m, sg, host, w = sown(90)
    unseen = function(sx, sz, wx, wz, hx, hz)
        unseenClear(sx, sz, wx, wz, hx, hz)
        error("bench: native sowing threw", 0)
    end
    local s0 = snap()
    local ok, err = pcall(pass, w.seeder, w.wa)
    local s1 = snap()
    T.eq("T1 NAMED: the throw reaches the engine unchanged, the bracket closed (no open profile), and nothing settled from the half-written state",
        tostring(ok) .. "/" .. tostring(err) .. "/" .. #(AR.profiles or {}) .. "/" .. delta(s0, s1, "removed") .. "/" .. delta(s0, s1, "native"),
        "false/bench: native sowing threw/0/0/1")
    T.eq("T2 the cleared cells were reconciled to native: their carriers withdrawn as empty", tostring((groundCount(sg))), "0")
    FSBaseMission.delete(m)
end)
