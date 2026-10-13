-- MAINT-208-ground_installs_without_fill_unit_spec_test.lua
--
-- MAINTENANCE row 208 (repairs SG2-5 5a, #31, and 5b, #32): the native host installed the ground
-- observer's hooks only after its fill-unit test (SGNativeHost:observeVehicle), and the engine's own
-- windrower and tedder types carry no fill unit (vehicleTypes.xml: `windrower`, `windrowerUnpowered` and
-- `tedder` stack baseGroundTool on baseAttachable and base, none of which names fillUnit; neither
-- specialization needs one, Windrower.lua:22-24, Tedder.lua:17-19). So their WINDROWER and TEDDER frames
-- never installed in play. The SG2-5a and SG2-5b benches built both machines on ENGINE_NEW_TRAILER, which
-- carries a fill unit, so no bar could see it. The host now runs SGGroundObserver.observeVehicle before
-- that test; each install there keeps its own spec guard.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world, with SG2-4c-1's recorder of
-- Soil's published surface and the SG2-5b bench's stand-in `soil.groundCondition` owner (the preamble of
-- the SG2-5b bench, verbatim, with its windrow types, its Tedder and the SG2-5a bench's Windrower).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path; a Windrower and a Tedder built as the engine
-- builds its OWN types (no spec_fillUnit), reached both ways the host observes a vehicle: in the
-- mission's vehicle list at the barrier (SGNativeHost.lua:135) and added later through
-- VehicleSystem.addVehicle (the class hook, onVehicleAdded). The engine's call order then runs each:
-- onStartWorkAreaProcessing and the captured pointer, over a windrow a tipper laid.
--
-- Groups:
--   E  the entry-point bar: both machines of the engine's own types, both ways in, framed and settled
--   O  one level outward: a vehicle with no fill unit and no ground spec gets no hook and no error; a
--      vehicle with a fill unit still gets the discharge capture and the fill-unit observer
--   D  a no-fill-unit tedder's live remainder still goes as destruction when it is removed
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local REAL = getmetatable(_G).__index
local M, GR, GS, GO, NH, NA = SGNativeMaterialSave, SGGround, SGGroundSampler, SGGroundObserver, SGNativeHost, SGNativeAdapters
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
local function printed(fn)
    local lines, orig = {}, print
    REAL.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(fn)
    REAL.print = orig
    if not ok then error(err, 0) end
    return lines
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
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = opts.index or 1, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

-- ── a property producer, as a domain owner registers one ─────────────────────
local PROP = "sg24b.origin"
local SEEN = { sources = {} }
local function origin(value, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "sg24b", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { o = value } }
end
local originSpec = { schemaVersion = 1, producerId = "sg24b", residency = "STORED",
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total, w, known = 0, 0, 0
        for _, c in ipairs(contributions) do
            SEEN.sources[#SEEN.sources + 1] = c.sourceStockRef and tostring(c.sourceStockRef.stockId) or "nil"
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

--- Boot through main.lua's load path, the world built first; the producer registers
--- between the load and the barrier, as a domain owner's own load would.
local function boot(build, saveDir, opts)
    opts = opts or {}
    SEEN.sources = {}
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
    m:onFinishedLoading()
    return m, sg, NH.current, w, lease
end
local function vehicleIn(m, v) m._vehicles[#m._vehicles + 1] = v return v end
local function nativeSave(m, dir)
    ENGINE_SAVE.finalDir = dir
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    ENGINE_RUN_FRAMES(nil)
end
local function reload(m, dir, build, opts)
    FSBaseMission.delete(m)
    return boot(build, dir, opts)
end
local function resetWorld()
    G_.reset()
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
local function level(v) return v:getFillUnitFillLevel(1) end
--- The ground carriers of the store: count, total litres, "x:z=L" sorted.
local function groundOf(sg)
    local n, total, cells = 0, 0, {}
    for id, c in pairs(sg.operations.carriers) do
        if NA.isGroundKey(c.binding.carrierKey) then
            n = n + 1
            local s = c.stockId and sg.operations.stocks[c.stockId] or nil
            local d = c.binding.sourceDescriptor
            total = total + (s and s.observedAmount or 0)
            cells[#cells + 1] = d.x .. ":" .. d.z .. "=" .. num(s and s.observedAmount or 0)
        end
    end
    table.sort(cells)
    return n, total, table.concat(cells, ",")
end
local function groundStocks(sg)
    local out = {}
    for id, c in pairs(sg.operations.carriers) do
        if NA.isGroundKey(c.binding.carrierKey) and c.stockId then out[#out + 1] = sg.operations.stocks[c.stockId] end
    end
    table.sort(out, function(a, b) return a.carrierId < b.carrierId end)
    return out
end
local function knowledgeOf(stocks)
    local seen = {}
    for _, s in ipairs(stocks) do seen[tostring(s.knowledge)] = true end
    local out = {}
    for k in pairs(seen) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ",")
end
local function head(host)
    local ls = host.lastSettlement
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome)
end
local function legs(host)
    local out = {}
    local n, loss = 0, 0
    for _, a in ipairs(host.lastSettlement and host.lastSettlement.report and host.lastSettlement.report.allocations or {}) do
        if a.result == "LOSS" then loss = loss + a.sourceAmount else n = n + 1 end
    end
    return n .. " moved, loss " .. num(loss)
end
local function totals(host)
    local ev = host.lastSettlement and host.lastSettlement.report and host.lastSettlement.report.outcomeEvidence or {}
    return num(ev.sourceTotal) .. "/" .. num(ev.destinationTotal) .. "/" .. num(ev.loss) .. "/" .. num(ev.unexplainedGain) .. " " .. tostring(ev.fillTypeName)
end
local function publish(m, sg, lease, id, value)
    local s = stockAt(sg, id)
    if s == nil then return "NO_STOCK" end
    return m.stockGuard.publishProperties(lease, { { stockRef = sg.operations:stockRef(s), expectedPropertyRevision = 0, record = origin(value, s.observedAmount) } })
end
local function propOf(s)
    if s == nil then return "nil" end
    local p = s.properties[PROP]
    if p == nil then return tostring(s.knowledge) .. ":none" end
    return tostring(s.knowledge) .. ":" .. num(p.payload.o) .. ":" .. num(p.knownAmount) .. "/" .. num(p.basisAmount)
end
local function envelopeAt(dir)
    local d = ENGINE_DISK[dir .. "/stockGuard.xml"]
    if d == nil then return nil end
    local tokens = {}
    for i = 1, d["stockGuard#count"] do tokens[i] = d[string.format("stockGuard.token(%d)#v", i - 1)] end
    return SGValues.decode(tokens)
end
local function payloadTree(dir)
    local p = GR.readPayload(dir .. "/" .. GR.PAYLOAD_FILE)
    return p and p.tree or nil
end

--- The standard tip world: a tipper of 600 L wheat over (10, 10).
local function tipWorld(m, w, opts)
    opts = opts or {}
    w.tipper = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:tipper", { level = opts.level or 600, fillType = opts.fillType or WHEAT, converter = opts.converter, at = opts.at or { x = 10, z = 10 }, width = opts.width }))
end

-- ── Soil's published surface, as a recorder ─────────────────────────────────
-- GroundConditionAdmission.lua (Soil, header :8-16): getCapabilities on the mission's
-- soilFertilityManager handle, and three PLAIN functions on its groundCondition table. Each
-- recorder function takes every argument (and counts them, so a colon call or a dropped
-- argument shows) and notes where in the call it ran: native line calls so far and the
-- sampler's ground reads so far.
local SOIL = {}
local function soilReset(opts)
    opts = opts or {}
    SOIL = { calls = {}, caps = 0, seq = 0, revision = opts.revision, refuse = opts.refuse, throwAt = opts.throwAt, noDeliver = opts.noDeliver }
    if SOIL.revision == nil then SOIL.revision = 2 end
end
local function note(fn, n, fields)
    fields.fn, fields.n, fields.lineCalls, fields.queries = fn, n, #G_.lineCalls, G_.queries
    SOIL.calls[#SOIL.calls + 1] = fields
    return fields
end
local function soilOn(m)
    local gc = {}
    gc.admitPrimitive = function(...)
        local footprint, kind, vehicle, workArea = ...
        note("admit", select("#", ...), { footprint = footprint, kind = kind, vehicle = vehicle, workArea = workArea })
        if SOIL.throwAt == "admit" then error("bench: admit threw", 0) end
        if SOIL.refuse then return { status = "REFUSED", reason = "BENCH_REFUSED" } end
        SOIL.seq = SOIL.seq + 1
        return { status = "ADMITTED", leaseToken = "SFGC-bench-" .. SOIL.seq }
    end
    if not SOIL.noDeliver then
        gc.deliverMovement = function(...)
            local token, obs = ...
            note("deliver", select("#", ...), { token = token, obs = obs })
            if SOIL.throwAt == "deliver" then error("bench: deliver threw", 0) end
            return { status = "OK" }
        end
    end
    gc.closePrimitive = function(...)
        local token = ...
        note("close", select("#", ...), { token = token })
        if SOIL.throwAt == "close" then error("bench: close threw", 0) end
        return true
    end
    m.soilFertilityManager = {
        groundCondition = gc,
        getCapabilities = function(self, ...)
            SOIL.caps = SOIL.caps + 1
            if SOIL.throwAt == "caps" then error("bench: getCapabilities threw", 0) end
            if SOIL.revision == false then return {} end
            return { groundCondition = { admissionRevision = SOIL.revision } }
        end,
    }
end
local function fns()
    local out = {}
    for _, c in ipairs(SOIL.calls) do out[#out + 1] = c.fn .. "(" .. c.n .. ")" end
    return table.concat(out, " ")
end
local function callOf(fn, i)
    local k = 0
    for _, c in ipairs(SOIL.calls) do
        if c.fn == fn then k = k + 1 if k == (i or 1) then return c end end
    end
    return nil
end
--- The util's own litres for the next tip line: a spy that passes every argument through.
local UTIL = {}
local REAL_UTIL_TIP = DensityMapHeightUtil.tipToGroundAroundLine
DensityMapHeightUtil.tipToGroundAroundLine = function(vehicle, delta, ...)
    local r = { REAL_UTIL_TIP(vehicle, delta, ...) }
    UTIL[#UTIL + 1] = { delta = delta, returned = r[1] }
    return unpack(r)
end
local function tipShovelLevelerWorld(m, w)
    soilOn(m)
    tipWorld(m, w, { at = { x = 0, z = 0 } })
    w.shovel = vehicleIn(m, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 0, z = 0 }, rate = 0.1 }))
    w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = 0, z = 0 } }))
end
local SC = SGSoilCondition

-- (SC is the preamble's SGSoilCondition.)

-- ── an OWNER_RESOLVED owner as `soil.groundCondition`, a stand-in recorder ───────────────────
-- Resident on ground; a GROUND_CELL footprint resolves to KNOWN with payload c = 7. Its combine
-- weights by amount over known inputs (the SG2-4c-0 bench's owner), so a pickup's stock carries it.
local PID = "soil.groundCondition"
local function record(ctx, c)
    return { propertyId = PID, schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN",
             knownAmount = ctx.amount, basisAmount = ctx.amount, amountUnit = "LITRE", payload = { c = c } }
end
local OWNER = {
    schemaVersion = 1, producerId = "soil", residency = "OWNER_RESOLVED", applicability = { residentStoreKinds = { "ground" } },
    validate = function() return true end,
    combine = function(_ctx, contributions, before)
        local total, w, known = 0, 0, 0
        for _, c in ipairs(contributions) do
            local p = c.properties[PID]
            total = total + c.amount
            if p and p.knowledge ~= "UNAVAILABLE" and p.payload then w = w + p.payload.c * c.amount known = known + c.amount end
        end
        if before ~= nil then
            local p = before.properties[PID]
            total = total + before.observedAmount
            if p and p.knowledge ~= "UNAVAILABLE" and p.payload then w = w + p.payload.c * before.observedAmount known = known + before.observedAmount end
        end
        if known == 0 then return nil, "NO_KNOWN_INPUT" end
        local r = record({ amount = known }, w / known)
        r.basisAmount = total
        r.knowledge = known >= total - 1e-6 and "KNOWN" or "PARTIAL"
        return r
    end,
    transform = function() return nil end, disclosure = function(_, r) return r end,
    resolveResident = function(ctx)
        local fp = ctx.footprint
        if type(fp) ~= "table" or fp.kind ~= "GROUND_CELL" then return nil, "NOT_RESIDENT" end
        return record(ctx, 7)
    end,
    getResidentRevision = function() return "rev:1" end,
}
--- The deliveries the recorder kept, in order.
local function delivers()
    local out = {}
    for _, c in ipairs(SOIL.calls) do if c.fn == "deliver" then out[#out + 1] = c end end
    return out
end
local function lastDeliver() local d = delivers() return d[#d] end
--- One contribution list as text: count, then litres-vs-returned, record id, knowledge and payload.
local function contribText(obs)
    local c = obs and obs.contributions
    if c == nil then return "none" end
    local parts = { tostring(#c) }
    for _, e in ipairs(c) do
        local r = e.record
        parts[#parts + 1] = (num(e.litres) == num(obs.litresReturned) and "litres=returned" or ("litres=" .. num(e.litres))) .. ":" ..
            (r == nil and "nil" or (tostring(r.propertyId) .. ":" .. tostring(r.knowledge) .. ":" .. num(r.payload and r.payload.c)))
    end
    return table.concat(parts, "/")
end


do
-- ── The windrow types (a model extension, as the SG2-5b bench) ──────────────────────────────
local GRASS, DRY = 6, 7
local NAMES = { [WHEAT] = "WHEAT", [BARLEY] = "BARLEY", [4] = "GRASS", [5] = "STRAW", [GRASS] = "GRASS_WINDROW", [DRY] = "DRYGRASS_WINDROW" }
REAL.g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(NAMES) do if v == n then return i end end return nil end,
}
FillType.GRASS_WINDROW, FillType.DRYGRASS_WINDROW = GRASS, DRY
do
    local hm = g_densityMapHeightManager
    for _, e in ipairs({ { GRASS, "GRASS_WINDROW" }, { DRY, "DRYGRASS_WINDROW" } }) do
        local ht = { index = #hm.heightTypes + 1, fillTypeIndex = e[1], fillTypeName = e[2], maxSurfaceAngle = math.rad(45), fillToGroundScale = 1,
                     canBeTipped = true, allowsSmoothing = true, collisionBaseOffset = 0 }
        hm.heightTypes[ht.index] = ht
        hm.fillTypeIndexToHeightType[e[1]] = ht
        hm.fillTypeNameToHeightType[e[2]] = ht
    end
end
MathUtil.vector3Length = MathUtil.vector3Length or function(x, y, z) return math.sqrt(x * x + y * y + z * z) end
-- DensityMapHeightUtil.lua:425-449 VERBATIM, and :450-455 (as the SG2-5a and SG2-5b benches carry them).
DensityMapHeightUtil.getLineByAreaDimensions = DensityMapHeightUtil.getLineByAreaDimensions or function(sx, sy, sz, wx, wy, wz, hx, hy, hz, radiusOverlap)
    local swDirX, swDirY, swDirZ = wx - sx, wy - sy, wz - sz
    local shDirX, shDirY, shDirZ = hx - sx, hy - sy, hz - sz
    local swLength = math.sqrt(swDirX * swDirX + swDirY * swDirY + swDirZ * swDirZ)
    local shLength = math.sqrt(shDirX * shDirX + shDirY * shDirY + shDirZ * shDirZ)
    shDirX, shDirY, shDirZ = shDirX / shLength, shDirY / shLength, shDirZ / shLength
    swDirX, swDirY, swDirZ = swDirX / swLength, swDirY / swLength, swDirZ / swLength
    if shLength < swLength then
        local radius = shLength * 0.5
        local shrink = radiusOverlap ~= nil and radiusOverlap and 0 or radius
        return sx + shDirX * shLength * 0.5 + swDirX * shrink, sy + shDirY * shLength * 0.5 + swDirY * shrink, sz + shDirZ * shLength * 0.5 + swDirZ * shrink, wx + shDirX * shLength * 0.5 - swDirX * shrink, wy + shDirY * shLength * 0.5 - swDirY * shrink, wz + shDirZ * shLength * 0.5 - swDirZ * shrink, radius
    else
        local radius = swLength * 0.5
        local shrink = radiusOverlap ~= nil and radiusOverlap and 0 or radius
        return sx + swDirX * swLength * 0.5 + shDirX * shrink, sy + swDirY * swLength * 0.5 + shDirY * shrink, sz + swDirZ * swLength * 0.5 + shDirZ * shrink, hx + swDirX * swLength * 0.5 - shDirX * shrink, hy + swDirY * swLength * 0.5 - shDirY * shrink, hz + swDirZ * swLength * 0.5 - shDirZ * shrink, radius
    end
end
DensityMapHeightUtil.getLineByArea = DensityMapHeightUtil.getLineByArea or function(start, width, height, radiusOverlap)
    local sx, sy, sz = getWorldTranslation(start)
    local wx, wy, wz = getWorldTranslation(width)
    local hx, hy, hz = getWorldTranslation(height)
    return DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, radiusOverlap)
end

-- ── The engine's Tedder (vehicles/specializations/Tedder.lua), as the SG2-5b bench ports it ────
Tedder = Tedder or {}
-- :360-362 VERBATIM.
function Tedder:onStartWorkAreaProcessing(_)
    self.spec_tedder.lastDroppedLiters = 0
end
-- :279-350 VERBATIM through the quantities (the SG2-5b bench's port, with its :294 note).
function Tedder:processTedderArea(workArea, _)
    local spec = self.spec_tedder
    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, true)
    for targetFillType, inputFillTypes in pairs(spec.fillTypeConvertersReverse) do
        local pickedUpLiters = 0
        for _, inputFillType in ipairs(inputFillTypes) do
            pickedUpLiters = pickedUpLiters + DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, inputFillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, nil, false, nil)
        end
        if pickedUpLiters == 0 and workArea.lastDropFillType ~= FillType.UNKNOWN then
            targetFillType = workArea.lastDropFillType
        end
        workArea.lastPickupLiters = -pickedUpLiters
        workArea.litersToDrop = workArea.litersToDrop + workArea.lastPickupLiters
        local dropArea = self.spec_workArea.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil and workArea.litersToDrop > 0 then
            local dropped = self:processDropArea(dropArea, targetFillType, workArea.litersToDrop)
            workArea.lastDropFillType = targetFillType
            workArea.lastDroppedLiters = dropped
            spec.lastDroppedLiters = spec.lastDroppedLiters + dropped
            workArea.litersToDrop = workArea.litersToDrop - dropped
        end
    end
    local area = MathUtil.vector3Length(lsx - lex, lsy - ley, lsz - lez) * self.lastMovedDistance
    return area, area
end
-- :351-358 VERBATIM (the client-distance guard is the server's always-pass branch).
function Tedder:processDropArea(dropArea, fillType, litersToDrop)
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height, true)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, litersToDrop, fillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset
    return dropped
end

-- ── The engine's Windrower (vehicles/specializations/Windrower.lua), as the SG2-5a bench ports it ──
Windrower = Windrower or {}
-- :285-290 VERBATIM.
function Windrower:onStartWorkAreaProcessing(_, workAreas)
    for _, workArea in pairs(workAreas) do
        workArea.lastValidPickupFillType = FillType.UNKNOWN
        workArea.lastPickupLiters = 0
        workArea.lastDroppedLiters = 0
    end
    self.spec_windrower.isWorking = false
end
-- :309-359 VERBATIM through the quantities; the stone, wear, test-area and effect lines out.
function Windrower:processWindrowerArea(workArea, _)
    local spec = self.spec_windrower
    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)
    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz)
    local pickupLiters = 0
    local pickupFillType = FillType.UNKNOWN
    if workArea.lastPickupLiters == 0 and (workArea.lastValidPickupFillType == FillType.UNKNOWN or workArea.litersToDrop < g_densityMapHeightManager:getMinValidLiterValue(workArea.lastValidPickupFillType)) then
        for _, fillTypeIndex in ipairs(spec.supportedFillTypes) do
            pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillTypeIndex, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, spec.limitToLineHeight, nil)
            if pickupLiters > 0 then
                pickupFillType = fillTypeIndex
                break
            end
        end
    else
        pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, workArea.lastValidPickupFillType, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        if workArea.lastValidPickupFillType == FillType.GRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        elseif workArea.lastValidPickupFillType == FillType.DRYGRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.GRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        end
        if pickupLiters > 0 then
            pickupFillType = workArea.lastValidPickupFillType
        end
    end
    if pickupFillType ~= FillType.UNKNOWN then
        workArea.lastValidPickupFillType = pickupFillType
    end
    workArea.lastPickupLiters = pickupLiters
    workArea.litersToDrop = workArea.litersToDrop + pickupLiters
    local area = 1
    if workArea.lastPickupLiters > 0 then
        local dropArea = self.spec_workArea.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil then
            local dropped = self:processDropArea(dropArea, workArea.lastPickupLiters, workArea.lastValidPickupFillType)
            workArea.lastDroppedLiters = dropped
            workArea.litersToDrop = workArea.litersToDrop - dropped
        end
    end
    return workArea.lastDroppedLiters, area
end
-- :393-397 VERBATIM.
function Windrower:processDropArea(dropArea, litersToDrop, fillType)
    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, litersToDrop, fillType, lsx, lsy, lsz, lex, ley, lez, radius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset
    return dropped
end

--- A vehicle as the engine builds one of its OWN tool types: vehicleTypes.xml `tedder` and `windrower`
--- name no fillUnit specialization, so the vehicle has no spec_fillUnit (SpecializationUtil.lua:146-161
--- makes a spec table only for the type's own specializations). Its functions COPIED into the instance.
local function engineVehicle(uid, configFileName)
    local v = { uniqueId = uid, configFileName = configFileName, ownerFarmId = 1, activeFarm = 1, isServer = true, rootNode = { x = 0, z = 0 } }
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.specClasses, v.specializations, v.specializationNames, v.eventListeners = {}, {}, {}, {}
    return v
end
--- Work area 1 picks up over x -1..1 at z = at; work area 2 drops at x 8..10 (index 3 when noDrop).
local function areas(at, noDrop, pickup)
    pickup.index, pickup.dropWindrowWorkAreaIndex = 1, noDrop and 3 or 2
    pickup.start, pickup.width, pickup.height = { x = -1, y = 0, z = at - 0.5 }, { x = 1, y = 0, z = at - 0.5 }, { x = -1, y = 0, z = at + 0.5 }
    local drop = { index = 2, functionName = "processDropArea", lineOffset = 0,
                   start = { x = 8, y = 0, z = at - 0.5 }, width = { x = 10, y = 0, z = at - 0.5 }, height = { x = 8, y = 0, z = at + 0.5 } }
    return { pickup, drop }
end
--- A tedder of the engine's own type: grass and dry grass windrow both feed dry grass (Tedder.lua:47-65).
local function newTedder(uid, at, opts)
    opts = opts or {}
    local v = engineVehicle(uid, "data/vehicles/tedder.xml")
    v.lastMovedDistance = 1
    v.processTedderArea, v.processDropArea = Tedder.processTedderArea, Tedder.processDropArea
    v.spec_tedder = { fillTypeConverters = { [GRASS] = { targetFillTypeIndex = DRY }, [DRY] = { targetFillTypeIndex = DRY } },
                      fillTypeConvertersReverse = { [DRY] = { GRASS, DRY } }, lastDroppedLiters = 0 }
    local pickup = { functionName = "processTedderArea", litersToDrop = 0, lastPickupLiters = 0, lastDropFillType = FillType.UNKNOWN, lastDroppedLiters = 0 }
    v.spec_workArea = { workAreas = areas(at, opts.noDrop, pickup) }
    pickup.processingFunction = v.processTedderArea
    return v, pickup
end
--- A windrower of the engine's own type, raking grass and dry grass windrow.
local function newWindrower(uid, at)
    local v = engineVehicle(uid, "data/vehicles/windrower.xml")
    v.processWindrowerArea, v.processDropArea = Windrower.processWindrowerArea, Windrower.processDropArea
    v.spec_windrower = { supportedFillTypes = { GRASS, DRY }, limitToLineHeight = false, isWorking = false }
    local pickup = { functionName = "processWindrowerArea", lastValidPickupFillType = FillType.UNKNOWN, lastPickupLiters = 0, lastDroppedLiters = 0, litersToDrop = 0 }
    v.spec_workArea = { workAreas = areas(at, false, pickup) }
    pickup.processingFunction = v.processWindrowerArea
    return v, pickup
end
--- WorkArea's tick for one area, in the engine's order: the start event, then the captured pointer.
local function tickTedder(v, wa) Tedder.onStartWorkAreaProcessing(v, nil) return wa.processingFunction(v, wa, 16) end
local function tickWindrower(v, wa) Windrower.onStartWorkAreaProcessing(v, nil, v.spec_workArea.workAreas) return wa.processingFunction(v, wa, 16) end
--- A tipper of `ft` over the pickup line at z = at, laying `litres` there.
local function layAt(m, w, key, ft, at)
    w[key] = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. key, { level = 100, fillType = ft, at = { x = 0, z = at }, supported = { [GRASS] = true, [DRY] = true } }))
end
--- The owner, with the SG2-5b bench's hay rule (#1076): transform carries combine's floor on the hay basis.
local HAY = "NATIVE_HAY_CONVERT_V1"
local TOWNER = {}
for k, v in pairs(OWNER) do TOWNER[k] = v end
TOWNER.transform = function(ctx, contributions, destinations)
    local hay = false
    for _, c in ipairs(contributions) do
        if c.conversionBasisId == HAY then hay = true elseif c.conversionBasisId ~= nil then return nil, "BASIS" end
    end
    if not hay then return nil, "NO_BASIS" end
    local d = destinations[1]
    return OWNER.combine(ctx, contributions, d and d.destinationBefore or nil)
end
local function opsOf(host)
    local out = {}
    for _, op in ipairs(host.lastGroundFrame and host.lastGroundFrame.operations or {}) do
        out[#out + 1] = tostring(op.evidence and op.evidence.nativePath) .. ":" .. tostring(op.outcome)
    end
    return table.concat(out, " ")
end
--- Is the work area's captured pointer StockGuard's bracket over the engine's own function?
local function bracketed(wa, name, native)
    local rec = wa._sgBrackets and wa._sgBrackets[name] or nil
    return rec ~= nil and rec.original == native and wa.processingFunction == rec.ours
end
--- One pass of each machine; returns "ops|drop record".
local function passText(host, kind, v, wa)
    soilReset()
    if kind == "tedder" then tickTedder(v, wa) else tickWindrower(v, wa) end
    local d = lastDeliver()
    return opsOf(host) .. "|" .. contribText(d and d.obs)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: THE ENGINE'S OWN TEDDER AND WINDROWER, BOTH WAYS IN
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        layAt(m, w, "grass", GRASS, 0)
        layAt(m, w, "dry", DRY, 20)
        w.tedder, w.tedderArea = newTedder("vehicle:tedder", 0)
        w.windrower, w.windrowerArea = newWindrower("vehicle:windrower", 20)
        vehicleIn(m, w.tedder)
        vehicleIn(m, w.windrower)
    end, "wmf_e", { index = 131 })
    m.stockGuard.registerProperty(PID, TOWNER)
    ENGINE_TIP(w.grass, 100)
    ENGINE_TIP(w.dry, 100)
    T.eq("E0 [entry point] at the barrier, a Tedder and a Windrower of the engine's own types (no spec_fillUnit) have their CAPTURED pointers bracketed",
        tostring(w.tedder.spec_fillUnit == nil and w.windrower.spec_fillUnit == nil) .. "/" .. tostring(bracketed(w.tedderArea, "processTedderArea", Tedder.processTedderArea))
            .. "/" .. tostring(bracketed(w.windrowerArea, "processWindrowerArea", Windrower.processWindrowerArea)),
        "true/true/true")
    T.eq("E1 NAMED [entry point] the Tedder's pass runs in its TEDDER frame: the pickup on the hay basis and the drop, both COMMITTED, the drop carrying the buffer's record",
        passText(host, "tedder", w.tedder, w.tedderArea), "GROUND_TEDDER:COMMITTED GROUND_TEDDER:COMMITTED|1/litres=returned:soil.groundCondition:KNOWN:7")
    T.eq("E2 NAMED [entry point] the Windrower's call runs in its WINDROWER frame: the pickup and the drop, both COMMITTED, the drop carrying the area's record",
        passText(host, "windrower", w.windrower, w.windrowerArea), "GROUND_WINDROWER:COMMITTED GROUND_WINDROWER:COMMITTED|1/litres=returned:soil.groundCondition:KNOWN:7")
    -- Bought later: the engine's addVehicle puts each in the vehicle list (VehicleSystem.lua:172), and the
    -- host's class hook on it (onVehicleAdded) observes it.
    local t2, t2a = newTedder("vehicle:tedder2", 40)
    local r2, r2a = newWindrower("vehicle:windrower2", 60)
    local g2, d2 = {}, {}
    layAt(m, g2, "grass", GRASS, 40)
    layAt(m, d2, "dry", DRY, 60)
    for _, v in ipairs({ g2.grass, d2.dry, t2, r2 }) do
        if v ~= g2.grass and v ~= d2.dry then vehicleIn(m, v) end
        VehicleSystem.addVehicle(m.vehicleSystem, v)
    end
    ENGINE_TIP(g2.grass, 100)
    ENGINE_TIP(d2.dry, 100)
    T.eq("E3 NAMED [entry point] bought later (VehicleSystem.addVehicle), the same two types are bracketed and their passes framed and settled",
        tostring(bracketed(t2a, "processTedderArea", Tedder.processTedderArea)) .. "/" .. tostring(bracketed(r2a, "processWindrowerArea", Windrower.processWindrowerArea))
            .. "|" .. passText(host, "tedder", t2, t2a) .. "|" .. passText(host, "windrower", r2, r2a),
        "true/true|GROUND_TEDDER:COMMITTED GROUND_TEDDER:COMMITTED|1/litres=returned:soil.groundCondition:KNOWN:7"
            .. "|GROUND_WINDROWER:COMMITTED GROUND_WINDROWER:COMMITTED|1/litres=returned:soil.groundCondition:KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. ONE LEVEL OUTWARD: EVERY OTHER INSTALL IN THE HOST'S OBSERVE
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        layAt(m, w, "tipper", WHEAT, 0)
        -- A tool of the engine's own type with no fill unit and no ground specialization (a dolly).
        w.dolly = vehicleIn(m, engineVehicle("vehicle:dolly", "data/vehicles/dolly.xml"))
    end, "wmf_o", { index = 132 })
    local ok, r = pcall(host.observeVehicle, host, w.dolly)
    T.eq("O1 NAMED: a vehicle with no fill unit and no ground specialization gets no hook (no tip, leveler or work-area install) and no error, at the barrier or observed again",
        tostring(ok) .. "/" .. tostring(r) .. "/" .. tostring(rawget(w.dolly, GO.TIP_MARKER)) .. "/" .. tostring(rawget(w.dolly, GO.LEVELER_MARKER))
            .. "/" .. tostring(rawget(w.dolly, SGDischargeCapture.MARKER)) .. "/" .. tostring(rawget(w.dolly, SGFillUnitObserver.MARKER)),
        "true/false/nil/nil/nil/nil")
    T.eq("O2 NAMED: a vehicle with a fill unit still gets every install it got before: the tip frame, the discharge capture and the fill-unit observer",
        tostring(rawget(w.tipper, GO.TIP_MARKER) ~= nil) .. "/" .. tostring(rawget(w.tipper, SGDischargeCapture.MARKER) ~= nil) .. "/" .. tostring(rawget(w.tipper, SGFillUnitObserver.MARKER) ~= nil),
        "true/true/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A NO-FILL-UNIT TEDDER'S REMAINDER GOES AS DESTRUCTION (SG-2 :136)
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        layAt(m, w, "grass", GRASS, 0)
        w.tedder, w.tedderArea = newTedder("vehicle:tedder", 0, { noDrop = true })
        vehicleIn(m, w.tedder)
    end, "wmf_d", { index = 133 })
    m.stockGuard.registerProperty(PID, TOWNER)
    ENGINE_TIP(w.grass, 100)
    tickTedder(w.tedder, w.tedderArea)
    local id = cid(NA.tedderBufferBinding(w.tedder, 1))
    local s = stockAt(sg, id)
    local held = s and s.observedAmount or 0
    VehicleSystem.removeVehicle(m.vehicleSystem, w.tedder)
    local ls = host.lastSettlement
    local a = ls and ls.report and ls.report.allocations and ls.report.allocations[1] or {}
    T.eq("D1 NAMED: removing the tedder (no fill unit) retires its remainder through a REMOVE with a DESTRUCTION leg of the whole amount, then withdraws the carrier",
        tostring(held > 0) .. "/" .. tostring(ls and ls.report and ls.report.outcomeEvidence and ls.report.outcomeEvidence.nativePath) .. "/" .. tostring(ls and ls.outcome)
            .. "/" .. tostring(a.result) .. "/" .. tostring(num(a.sourceAmount) == num(held)) .. "/" .. tostring(sg.operations.carriers[id] == nil),
        "true/TEDDER_BUFFER_DESTRUCTION/COMMITTED/DESTRUCTION/true/true")
    FSBaseMission.delete(m)
end)
end
