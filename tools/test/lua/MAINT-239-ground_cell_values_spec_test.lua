-- MAINT-239-ground_cell_values_spec_test.lua
--
-- MAINTENANCE row 239 (Bob's R-15 on SG-3 2.2 and his pre-build R-15 on this row, 2026-10-07; SG-2 v2.3
-- :160, "shared immutable property payloads ... Compression may change storage layout, never ...
-- property precision or separate contents"): the ground save keeps a record's coverage (knownAmount,
-- basisAmount) and its top-level numbers (SG-3's score pair) with the cell, out of the shared set, so
-- graded records share their sets again; the shared copy names what left so exactly that comes back.
--
-- WHY. Once a mown field's cells carry graded quality records (SG-3 Part 2.2), every cell's record holds
-- its own score pair and coverage. With Soil varying per value cell and a driven Mower whose drops
-- overlap, 914 cells saved 314 sets: the ground payload grew from 124,234 to 393,947 token bytes.
--
-- THE WORLD. The SG2-5c bench's preamble, verbatim (the engine's own Mower type, Soil's recorder, the
-- stand-in soil.groundCondition owner, the tip world and its sg24b.origin producer), as MAINT-237's bench
-- has it. SG-3's own Mower births are still its ungraded ORIGIN_UNPROVEN here (Part 2.2 grades them), so a
-- stand-in STORED birth producer grades each drop from its evidence portions' Soil in qualityBasisV1's
-- record shape: a score pair, coverage, a witness with masks and reasons. Soil varies per 2 m value cell.
--
-- THE ENTRY-POINT BAR IS GROUP S: main.lua's load path; the native host brackets the Mower's captured
-- pointer and its drop slot; the engine's own order mows and drops along driven swaths; the native save
-- controller saves and the ground section reloads. Nothing publishes a record or fills a payload by hand.
--
-- Groups:
--   S  the entry-point bar: every cell's every record round-trips byte-equal, its pair and coverage included
--   Z  sets and bytes before (development's own writer, run here) and after, on a first save and after a
--      reload, pinned
--   T  partial coverage (a carried record covering part of a cell) round-trips exactly
--   O  a payload in the layout before this row loads byte-exact
--   V  validCell refuses a malformed cell list
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
    SOIL = { calls = {}, caps = 0, seq = 0, revision = opts.revision, refuse = opts.refuse, refuseKind = opts.refuseKind, throwAt = opts.throwAt, noDeliver = opts.noDeliver }
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
        if SOIL.refuse or (SOIL.refuseKind ~= nil and kind == SOIL.refuseKind) then return { status = "REFUSED", reason = "BENCH_REFUSED" } end
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
-- The ground model has height types for WHEAT and BARLEY only; the Mower's own types are added here
-- exactly as its addHeightType builds one (SG2-4b-ground_model.lua:341-348), with their names.
local GRASS, DRY, STRAW_W = 6, 7, 8
local NAMES = { [WHEAT] = "WHEAT", [BARLEY] = "BARLEY", [4] = "GRASS", [5] = "STRAW", [GRASS] = "GRASS_WINDROW", [DRY] = "DRYGRASS_WINDROW", [STRAW_W] = "STRAW_WINDROW" }
REAL.g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(NAMES) do if v == n then return i end end return nil end,
}
FillType.GRASS_WINDROW, FillType.DRYGRASS_WINDROW = GRASS, DRY
do
    local hm = g_densityMapHeightManager
    for _, e in ipairs({ { GRASS, "GRASS_WINDROW" }, { DRY, "DRYGRASS_WINDROW" }, { STRAW_W, "STRAW_WINDROW" } }) do
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

-- ── The forage crop (a model extension) ──────────────────────────────────────────────────────
-- The model's WHEAT descriptor stands in for the meadow: harvestable at 3 (yield scale 0.5) and 4 (1),
-- cut to 6. As FruitType.MEADOW it also takes updateMowerArea's preparation (first regrowth state 3).
FruitType.MEADOW = FruitType.WHEAT
-- The fruits (FruitType indices; the preamble's WHEAT and BARLEY are FILL types).
local MEADOW_F, BARLEY_F = FruitType.WHEAT, FruitType.BARLEY
do
    local d = g_fruitTypeManager:getFruitTypeByIndex(FruitType.WHEAT)
    d.regrows, d.firstRegrowthState = true, 3
end
WorkAreaType = WorkAreaType or {}
WorkAreaType.MOWER, WorkAreaType.AUXILIARY = WorkAreaType.MOWER or 21, WorkAreaType.AUXILIARY or 22
--- FSBaseMission:getHarvestScaleMultiplier MODELED at 1 (the factors it reads are 1 in the model).
function Mission:getHarvestScaleMultiplier() return 1 end

-- ── The engine's Mower (vehicles/specializations/Mower.lua) ────────────────────────────────────
Mower = Mower or {}
Mower.CLIENT_DM_UPDATE_RADIUS = 50
--- The chord's two draws (math.random at :389 and :393, MODELED as the bench's fixed values).
ENGINE_MOWER = { draws = { 0.5, 0.5 } }
--- Mowable decorative foliage on 1 m fruit pixels ("px:pz" = true), for the meadow preparation.
ENGINE_DECO = {}
--- FSDensityMapUtil.lua:1886-1921 VERBATIM through the quantities. The preparation's multi-modifier
--- execute (:1916-1918) is C, MODELED: each fruit pixel whose centre lies in the parallelogram and
--- carries mowable decorative foliage takes the meadow at its first regrowth state.
function FSDensityMapUtil.updateMowerArea(fruitType, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, limitToField)
    local desc = g_fruitTypeManager:getFruitTypeByIndex(FruitType.MEADOW)
    if desc ~= nil and desc.terrainDataPlaneId ~= nil then
        if not limitToField and desc.regrows and desc.firstRegrowthState ~= nil then
            local x0, x1 = math.min(startWorldX, widthWorldX, heightWorldX), math.max(startWorldX, widthWorldX, heightWorldX)
            local z0, z1 = math.min(startWorldZ, widthWorldZ, heightWorldZ), math.max(startWorldZ, widthWorldZ, heightWorldZ)
            for key in pairs(ENGINE_DECO) do
                local px, pz = key:match("^(-?%d+):(-?%d+)$")
                px, pz = tonumber(px), tonumber(pz)
                local cx, cz = px + 0.5, pz + 0.5
                if cx >= x0 and cx < x1 and cz >= z0 and cz < z1 then ENGINE_PLANE.sow(FruitType.MEADOW, px, pz, px + 1, pz + 1, desc.firstRegrowthState) end
            end
        end
    end
    return FSDensityMapUtil.cutFruitArea(fruitType, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, true, false, nil, nil, limitToField)
end
--- :328-382 VERBATIM through the quantities; the effects' time stamp kept, the decompile's global
--- `pickup` at :363 made a local, and workAreaChanged left as the decompile returns it.
function Mower:processMowerArea(workArea, _)
    local spec = self.spec_mower
    if not self.isServer and self.currentUpdateDistance > Mower.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local xs, _, zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)
    if self:getLastSpeed() > 1 then
        spec.isWorking = true
        spec.stoneLastState = FSDensityMapUtil.getStoneArea(xs, zs, xw, zw, xh, zh)
    else
        spec.stoneLastState = 0
    end
    local workAreaChanged = 0
    local workAreaTotal = 0
    local limitToField = self:getIsAIActive()
    for inputFruitType, converterData in pairs(spec.fruitTypeConverters) do
        local changedArea, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState, _ = FSDensityMapUtil.updateMowerArea(inputFruitType, xs, zs, xw, zw, xh, zh, limitToField)
        if changedArea > 0 then
            local multiplier = g_currentMission:getHarvestScaleMultiplier(inputFruitType, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc)
            local litersToDrop = g_fruitTypeManager:getFruitTypeAreaLiters(inputFruitType, changedArea, true) * multiplier * converterData.conversionFactor
            workArea.lastPickupLiters = litersToDrop
            workArea.pickedUpLiters = litersToDrop
            local dropArea = self:getDropArea(workArea)
            if dropArea == nil then
                if spec.fillUnitIndex ~= nil and self.isServer then
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, litersToDrop, converterData.fillTypeIndex, ToolType.UNDEFINED)
                end
            else
                dropArea.litersToDrop = dropArea.litersToDrop + litersToDrop
                dropArea.fillType = converterData.fillTypeIndex
                dropArea.workAreaIndex = workArea.index
                if dropArea.fillType == FillType.GRASS_WINDROW then
                    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height, true)
                    local pickup
                    pickup, workArea.lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, workArea.lineOffset or 0, false, nil, false)
                    dropArea.litersToDrop = dropArea.litersToDrop - pickup
                end
                local lsy = dropArea.litersToDrop
                dropArea.litersToDrop = math.min(lsy, 1000)
            end
            spec.workAreaParameters.lastInputFruitType = inputFruitType
            spec.workAreaParameters.lastInputGrowthState = growthState
            spec.workAreaParameters.lastCutTime = g_time
            spec.workAreaParameters.lastChangedArea = spec.workAreaParameters.lastChangedArea + changedArea
            spec.workAreaParameters.lastStatsArea = spec.workAreaParameters.lastStatsArea + totalArea
            spec.workAreaParameters.lastTotalArea = spec.workAreaParameters.lastTotalArea + totalArea
            spec.workAreaParameters.lastUsedAreas = spec.workAreaParameters.lastUsedAreas + 1
            self:setTestAreaRequirements(inputFruitType)
            workAreaTotal = totalArea
        end
    end
    spec.workAreaParameters.lastUsedAreasSum = spec.workAreaParameters.lastUsedAreasSum + 1
    return workAreaChanged, workAreaTotal
end
--- :383-405 VERBATIM through the quantities; the two draws are ENGINE_MOWER's, and the decompile's
--- reused name at :393-395 (`ex` for the second draw and the end point) restored.
function Mower:processDropArea(dropArea, _)
    if self.isServer or self.currentUpdateDistance <= Mower.CLIENT_DM_UPDATE_RADIUS then
        if dropArea.litersToDrop > g_densityMapHeightManager:getMinValidLiterValue(dropArea.fillType) then
            local xs, _, zs = getWorldTranslation(dropArea.start)
            local xw, _, zw = getWorldTranslation(dropArea.width)
            local xh, _, zh = getWorldTranslation(dropArea.height)
            local f = ENGINE_MOWER.draws[1]
            local sx = xs + f * (xh - xs)
            local sz = zs + f * (zh - zs)
            local sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)
            local f2 = ENGINE_MOWER.draws[2]
            local ex = xw + f2 * (xh - xs)
            local ez = zw + f2 * (zh - zs)
            local ey = getTerrainHeightAtWorldPos(g_terrainNode, ex, 0, ez)
            local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, dropArea.litersToDrop, dropArea.fillType, sx, sy, sz, ex, ey, ez, 0, nil, dropArea.dropLineOffset, false, nil, false)
            dropArea.litersToDrop = dropArea.litersToDrop - dropped
            dropArea.dropLineOffset = lineOffset
            if dropped ~= 0 then
                self.spec_mower.lastDropTime = g_time
            end
        end
    end
end
--- :406-424 VERBATIM, the decompile's fall-through after an invalid index (:413-416) restored as an else.
function Mower:getDropArea(workArea)
    if not workArea.dropWindrow then
        return nil
    end
    local dropArea = nil
    if workArea.dropAreaIndex ~= nil then
        dropArea = self.spec_workArea.workAreas[workArea.dropAreaIndex]
        if dropArea == nil then
            workArea.dropAreaIndex = nil
        elseif dropArea.type ~= WorkAreaType.AUXILIARY then
            workArea.dropAreaIndex = nil
            dropArea = nil
        end
    end
    return dropArea
end
--- :541-561 VERBATIM through the quantities (the drop effects, :543-552, left out).
function Mower:onStartWorkAreaProcessing(_)
    local spec = self.spec_mower
    local workAreas = self:getTypedWorkAreas(WorkAreaType.MOWER)
    for i = 1, #workAreas do
        workAreas[i].pickedUpLiters = 0
    end
    spec.workAreaParameters.lastChangedArea = 0
    spec.workAreaParameters.lastStatsArea = 0
    spec.workAreaParameters.lastTotalArea = 0
    spec.isWorking = false
end
--- :562-566 VERBATIM (the drop loop; the effects, statistics and sound after it left out).
function Mower:onEndWorkAreaProcessing(dt, _)
    local spec = self.spec_mower
    for _, dropArea in ipairs(spec.dropAreas) do
        self:processDropArea(dropArea, dt)
    end
end

--- A Mower as the engine builds one, its functions COPIED into the instance (Vehicle.lua:486). Its
--- cut work area spans x -1..1, z -0.5..0.5 (two fruit pixels); its drop area x 20..22, so the drop's
--- line lands well away from the cut. opts.kind:
---   "mower"         vehicleTypes.xml `mower`: no fillUnit specialization, so no spec_fillUnit
---   "selfPropelled" `selfPropelledMower`: a fill unit (a tank of no use to the cut) beside the mower
---   "forageWagon"   `mowerForageWagon`: its cut drops no windrow, the output goes to fill unit 1
--- opts.converters: input fruit -> { fillTypeIndex, conversionFactor } (default WHEAT -> GRASS_WINDROW x200).
local function newMower(uid, opts)
    opts = opts or {}
    local kind = opts.kind or "selfPropelled"
    local v
    if kind == "mower" then
        v = { uniqueId = uid, ownerFarmId = 1, activeFarm = 1, isServer = true, rootNode = { x = 0, z = 0 } }
        v.getUniqueId = function(self) return self.uniqueId end
        v.getOwnerFarmId = function(self) return self.ownerFarmId end
        v.getActiveFarm = function(self) return self.activeFarm end
        v.specClasses, v.specializations, v.specializationNames, v.eventListeners = {}, {}, { "workArea", "mower" }, {}
    else
        v = ENGINE_NEW_TRAILER(uid, { level = 0, capacity = opts.capacity or (kind == "forageWagon" and 10000 or 0),
            supported = { [GRASS] = true, [STRAW_W] = true } })
    end
    v.configFileName = "data/vehicles/mower.xml"
    v.isServer = true
    v.getLastSpeed = function() return 0 end
    v.getIsAIActive = function() return false end
    v.setTestAreaRequirements = function() end
    v.getTypedWorkAreas = function(self, t)
        local out = {}
        for _, wa in ipairs(self.spec_workArea.workAreas) do if wa.type == t then out[#out + 1] = wa end end
        return out
    end
    v.processMowerArea, v.processDropArea, v.getDropArea = Mower.processMowerArea, Mower.processDropArea, Mower.getDropArea
    v.spec_mower = { fruitTypeConverters = opts.converters or { [MEADOW_F] = { fillTypeIndex = GRASS, conversionFactor = 200 } },
        dropAreas = {}, fillUnitIndex = kind == "forageWagon" and 1 or nil, isWorking = false, stoneLastState = 0, lastDropTime = 0,
        workAreaParameters = { lastInputGrowthState = 0, lastCutTime = 0, lastChangedArea = 0, lastStatsArea = 0, lastTotalArea = 0, lastUsedAreas = 0, lastUsedAreasSum = 0 } }
    local cut = { index = 1, type = WorkAreaType.MOWER, functionName = "processMowerArea", dropWindrow = kind ~= "forageWagon", dropAreaIndex = 2,
                  start = { x = -1, y = 0, z = -0.5 }, width = { x = 1, y = 0, z = -0.5 }, height = { x = -1, y = 0, z = 0.5 }, lastPickupLiters = 0, pickedUpLiters = 0 }
    cut.processingFunction = v.processMowerArea
    -- Mower:loadWorkAreaFromXML :481-487: an AUXILIARY area starts empty and joins dropAreas.
    local drop = { index = 2, type = WorkAreaType.AUXILIARY, litersToDrop = 0, dropLineOffset = 0,
                   start = { x = 20, y = 0, z = -0.5 }, width = { x = 22, y = 0, z = -0.5 }, height = { x = 20, y = 0, z = 0.5 } }
    v.spec_mower.dropAreas[1] = drop
    v.spec_workArea = { workAreas = { cut, drop } }
    return v, cut, drop
end
--- WorkArea's tick (WorkArea.lua:124-200): the start event, each active area's captured pointer, the
--- end event. Returns the MOWER frame and the MOWER_DROP frame the host closed last in each half.
local function tick(host, v, cut)
    local before = host.lastGroundFrame
    Mower.onStartWorkAreaProcessing(v, nil)
    local a1, a2 = cut.processingFunction(v, cut, 16)
    local cutFrame = host.lastGroundFrame ~= before and host.lastGroundFrame or nil
    Mower.onEndWorkAreaProcessing(v, 16, nil)
    local dropFrame = host.lastGroundFrame ~= cutFrame and host.lastGroundFrame or nil
    return cutFrame, dropFrame, a1, a2
end
--- The forage crop under the cut: WHEAT (the meadow) at `state` on the four pixels around the origin.
local function sow(state) ENGINE_PLANE.sow(MEADOW_F, -1, -1, 1, 1, state or 4) end
--- A tipper of `ft` over the cut's middle line, tipping `litres` there.
local function lay(m, w, ft, litres, key)
    w[key] = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. key, { level = litres, fillType = ft, at = { x = 0, z = 0 },
        supported = { [GRASS] = true, [DRY] = true, [STRAW_W] = true, [WHEAT] = true } }))
end
--- Fill (or clear) the drop line's whole reach with BARLEY at the most raw units a pixel holds: the
--- model drops only onto empty pixels or its own type, so nothing lands and native keeps its litres.
local function blockDrop(on)
    local maxRaw = 2 ^ ENGINE_MAPS[ENGINE_HEIGHT_ID].heightNumChannels - 1
    local x0, z0 = ENGINE_GROUND.cellOf(15.5, -4.5)
    local x1, z1 = ENGINE_GROUND.cellOf(26.5, 4.5)
    for x = x0, x1 do for z = z0, z1 do ENGINE_GROUND.put(x, z, ENGINE_HT.BARLEY.index, on and maxRaw or 0) end end
end

-- ── the owner: Soil #1082's pending rule, a stand-in recorder ─────────────────────────────────
-- The preamble's owner, with Soil's 5c-soil rule (GroundConditionProperty.combine): litres a settle
-- names as pending fresh (per allocation ref, and the destination's own remainder) are left out of the
-- floor and the coverage; zero litres import nothing. It keeps every pendingFresh it was handed.
local PENDING = {}
local MOWNER = {}
for k, v in pairs(OWNER) do MOWNER[k] = v end
MOWNER.combine = function(ctx, contributions, before)
    local mine = ctx and ctx.report and ctx.report.outcomeEvidence and ctx.report.outcomeEvidence[PID] or nil
    local pf = mine and mine.pendingFresh or nil
    PENDING[#PENDING + 1] = pf or false
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
    local r = record({ amount = known }, w / known)
    r.basisAmount = total
    r.knowledge = known >= total - 1e-6 and "KNOWN" or "PARTIAL"
    return r
end

--- Boot a world with one Mower and the owner registered; `lay` lists the windrows to tip first.
local function boot5c(opts, key, index)
    opts = opts or {}
    PENDING = {}
    local m, sg, host, w = boot(function(m, w)
        if not opts.noSoil then soilOn(m) end
        for _, l in ipairs(opts.lay or {}) do lay(m, w, l[1], l[2], l[3]) end
        w.mower, w.cut, w.drop = newMower("vehicle:mower", opts)
        vehicleIn(m, w.mower)
    end, key, { index = index })
    m.stockGuard.registerProperty(PID, MOWNER)
    if not opts.noTip then for _, l in ipairs(opts.lay or {}) do ENGINE_TIP(w[l[3]], l[2]) end end
    return m, sg, host, w
end
local function bufferId(w) return NA.mowerBufferBinding ~= nil and cid(NA.mowerBufferBinding(w.mower, 2)) or nil end
local function bufferStock(sg, w) local id = bufferId(w) return id ~= nil and stockAt(sg, id) or nil end
local function entryOf(w) local id = bufferId(w) return id ~= nil and NA.mowerBuffers ~= nil and NA.mowerBuffers[id] or nil end
local function liveBuffers() local n = 0 for _ in pairs(NA.mowerBuffers or {}) do n = n + 1 end return n end
--- A field of the buffer entry, or nil.
local function entryField(w, k) local e = entryOf(w) if e == nil then return nil end return e[k] end
--- A buffer stock as "type/litres/record": record knowledge:payload:known/basis, or noRecord.
local function bufferText(sg, w)
    local s = bufferStock(sg, w)
    if s == nil then return "none" end
    local p = s.properties[PID]
    return table.concat({ tostring(s.materialRef and s.materialRef.fillTypeName), num(s.observedAmount),
        p == nil and "noRecord" or (tostring(p.knowledge) .. ":" .. num(p.payload and p.payload.c) .. ":" .. num(p.knownAmount) .. "/" .. num(p.basisAmount)) }, "/")
end
--- A frame's operations as "path:outcome".
local function opsText(frame)
    local out = {}
    for _, op in ipairs(frame and frame.operations or {}) do out[#out + 1] = tostring(op.evidence and op.evidence.nativePath) .. ":" .. tostring(op.outcome) end
    return table.concat(out, " ")
end
--- An operation's legs as "result:reason=litres", in report order.
local function legText(op)
    local out = {}
    for _, a in ipairs(op and op.report and op.report.allocations or {}) do
        local from = a.source.slotId ~= nil and "slot" or (NA.isGroundKey and a.source.carrierId and a.source.carrierId:find("ground:", 1, true) and "cell" or "buffer")
        out[#out + 1] = from .. ">" .. (a.destination.retire and "retire" or "buffer") .. ":" .. tostring(a.result) .. (a.reason and ("(" .. a.reason .. ")") or "") .. "=" .. num(a.sourceAmount)
    end
    return table.concat(out, ",")
end
--- Legs folded by kind: "slot>buffer:BORN=litres,..." summed per key, sorted.
local function legSums(op)
    local sums, keys = {}, {}
    for _, a in ipairs(op and op.report and op.report.allocations or {}) do
        local from = a.source.slotId ~= nil and "slot" or (tostring(a.source.carrierId):find("ground:", 1, true) and "cell" or "buffer")
        local key = from .. ">" .. (a.destination.retire and "retire" or "buffer") .. ":" .. tostring(a.result)
        if sums[key] == nil then sums[key] = 0 keys[#keys + 1] = key end
        sums[key] = sums[key] + (a.destination.retire and a.sourceAmount or a.destinationAmount)
    end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. num(sums[k]) end
    return table.concat(out, ",")
end
--- The drop deliveries' contributions: "n/litres:birth kind:type | litres:record knowledge:c".
local function dropText()
    local out = {}
    for _, d in ipairs(delivers()) do
        local obs = d.obs
        if obs and (obs.litresReturned or 0) > 0 then
            local parts = {}
            for _, c in ipairs(obs.contributions or {}) do
                if c.birth ~= nil then
                    parts[#parts + 1] = num(c.litres) .. ":birth:" .. tostring(c.birth.kind) .. ":" .. tostring(NAMES[c.birth.fillTypeIndex])
                else
                    local r = c.record
                    parts[#parts + 1] = num(c.litres) .. ":" .. (r == nil and "nil" or (tostring(r.knowledge) .. ":" .. num(r.payload and r.payload.c)))
                end
            end
            out[#out + 1] = num(obs.litresReturned) .. "=" .. (obs.contributions == nil and "none" or table.concat(parts, "+"))
        end
    end
    return table.concat(out, " ")
end
--- The kinds Soil was asked to admit, in order.
local function admitKinds()
    local out = {}
    for _, c in ipairs(SOIL.calls) do if c.fn == "admit" then out[#out + 1] = tostring(c.kind) end end
    return table.concat(out, ",")
end
local function groundOf(sg, ft)
    local t = 0
    for _, c in pairs(sg.operations.carriers) do
        if NA.isGroundKey(c.binding.carrierKey) and c.stockId then
            local s = sg.operations.stocks[c.stockId]
            if s and s.materialRef and s.materialRef.fillTypeName == ft then t = t + s.observedAmount end
        end
    end
    return t
end

-- ══════════════════════════════════════════════════════════════════════════
-- THE PASS, run on a Mower of the given kind: a forage cut over an old dry windrow
-- ══════════════════════════════════════════════════════════════════════════
local function pass(kind, key, index)
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ kind = kind, lay = { { DRY, 200, "dry" } } }, key, index)
    sow(4)
    soilReset()
    local r = {}
    local cut = w.cut
    r.installed = tostring(cut._sgBrackets ~= nil and cut._sgBrackets.processMowerArea ~= nil and cut._sgBrackets.processMowerArea.original == Mower.processMowerArea)
        .. "/" .. tostring(GO.MOWER_DROP_MARKER ~= nil and rawget(w.mower, GO.MOWER_DROP_MARKER) ~= nil)
    -- The witness's once-per-session log lines, fresh for this pass (each pass is its own session).
    SGCutState.logged = {}
    local lines = printed(function()
        r.cutFrame, r.dropFrame, r.a1, r.a2 = tick(host, w.mower, cut)
    end)
    r.logged = has(lines, "FIRST MOWER_STATE_VOLUME_V1 CUT ADMITTED: 1 state/Soil portion(s) matched the native's own area 2")
    r.native = num(cut.lastPickupLiters) .. "/" .. num(w.drop.litersToDrop) .. "/" .. tostring(NAMES[w.drop.fillType]) .. "/" .. tostring(r.a1) .. ":" .. tostring(r.a2)
    r.fns, r.kinds = fns(), admitKinds()
    local cutAdmit = callOf("admit", 1)
    local fp = cutAdmit and cutAdmit.footprint or {}
    r.cutAdmit = tostring(cutAdmit and cutAdmit.kind) .. "/" .. tostring(fp.kind) .. ":" .. table.concat({ num(fp.x0), num(fp.z0), num(fp.x1), num(fp.z1), num(fp.x2), num(fp.z2) }, ",")
        .. "/" .. tostring(cutAdmit and cutAdmit.vehicle == w.mower) .. "/" .. tostring(cutAdmit and cutAdmit.workArea == cut)
    r.ops = opsText(r.cutFrame) .. " | " .. opsText(r.dropFrame)
    local op = r.cutFrame and r.cutFrame.operations and r.cutFrame.operations[1] or nil
    r.op = op
    r.legs = legSums(op)
    local ev = op and op.evidence or {}
    r.evidence = table.concat({ num(ev.produced), num(ev.before), num(ev.pickup and ev.pickup.picked), num(ev.retained), num(ev.capLoss), tostring(ev.fresh) }, "/")
    local pf = ev[PID] and ev[PID].pendingFresh or nil
    r.pending = pf == nil and "none" or (num(pf.destinationBefore) .. "|" .. (pf.allocations[1] and (pf.allocations[1].allocation .. ":" .. num(pf.allocations[1].litres)) or "-"))
    r.drops = dropText()
    local classes = {}
    for _, st in pairs(sg.operations.retiredStocks) do
        if NA.isMowerBufferKey ~= nil and NA.isMowerBufferKey(st.carrierKey) then classes[#classes + 1] = tostring(st.retiredClass) end
    end
    r.retired = table.concat(classes, ",")
    r.after = tostring(bufferId(w) ~= nil and sg.operations.carriers[bufferId(w)] == nil) .. "/" .. liveBuffers() .. "/" .. num(groundOf(sg, "GRASS_WINDROW")) .. "/" .. num(groundOf(sg, "DRYGRASS_WINDROW"))
    FSBaseMission.delete(m)
    return r
end
local EXPECT = {
    native = "400/0/GRASS_WINDROW/0:2",
    fns = "admit(4) admit(4) deliver(2) close(1) close(1) admit(4) deliver(2) close(1)",
    kinds = "MOWER_CUT,TIP_TO_GROUND_AROUND_LINE,TIP_TO_GROUND_AROUND_LINE",
    cutAdmit = "MOWER_CUT/AREA:-1,-0.5,1,-0.5,-1,0.5/true/true",
    ops = "GROUND_MOWER_CUT:COMMITTED | GROUND_MOWER_DROP:COMMITTED",
    legs = "cell>buffer:TRANSFERRED=200,slot>buffer:BORN=400",
    evidence = "400/0/200/600/0/true",
    pending = "0|1:400",
    drops = "600=400:birth:MOWER:GRASS_WINDROW+200:KNOWN:7",
    after = "true/0/600/0",
}

-- ══════════════════════════════════════════════════════════════════════════
-- MAINTENANCE row 239: PER-CELL VALUES IN THE GROUND SAVE
-- ══════════════════════════════════════════════════════════════════════════
-- A stand-in STORED producer that declares births and grades each from its evidence portions' Soil, in
-- qualityBasisV1's record shape (SG3Quality): a score pair, full coverage, a witness with Food and Feed
-- masks and reasons. Its combine weighs the pair by quantity, as SG-3's does.
local GRADED = "bench.graded"
local function gradedRecord(earned, remaining, known, basis)
    return { propertyId = GRADED, schemaVersion = 1, producerId = "benchGraded", propertyRevision = 0, knowledge = known >= basis - 1e-9 and "KNOWN" or "PARTIAL",
             knownAmount = known, basisAmount = basis, amountUnit = "LITRE",
             payload = { representation = "UNIFORM", earnedScore = earned, remainingScore = remaining,
                         sourceWitness = { schemaVersion = 1, cropKey = "grass", originUse = {
                             FOOD = { eligibleFraction = 0, ineligibleFraction = 1, unknownFraction = 0, reasons = { "FOOD_ORIGIN_INELIGIBLE" } },
                             FEED = { eligibleFraction = 1, ineligibleFraction = 0, unknownFraction = 0, reasons = {} } } } } }
end
local gradedSpec = { schemaVersion = 1, producerId = "benchGraded", residency = "STORED", birth = true,
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total, w = 0, 0
        local function add(amount, rec)
            if amount == nil or amount <= 0 then return end
            total = total + amount
            if rec ~= nil and rec.payload ~= nil and rec.payload.earnedScore ~= nil then w = w + rec.payload.earnedScore * amount end
        end
        for _, c in ipairs(contributions) do add(c.amount, c.properties and c.properties[GRADED]) end
        if before ~= nil then add(before.observedAmount, before.properties and before.properties[GRADED]) end
        if total <= 0 or w <= 0 then return nil, "NO_KNOWN_INPUT" end
        return gradedRecord(w / total, w / total, total, total)
    end,
    transform = function(ctx, inputs, outputs)
        local out = outputs[1]
        local ev = ctx.report and ctx.report.outcomeEvidence or {}
        local sum, wsum = 0, 0
        for _, p in ipairs(type(ev.portions) == "table" and ev.portions or {}) do
            if p.soil ~= nil and p.weight ~= nil then
                sum = sum + (p.soil.nitrogen + p.soil.phosphorus + p.soil.potassium) / 3 * p.weight
                wsum = wsum + p.weight
            end
        end
        local before = out.destinationBefore
        local b = before ~= nil and before.properties and before.properties[GRADED] or nil
        local born = 0
        for _, c in ipairs(inputs) do if c.slotId ~= nil then born = born + (c.amount or 0) end end
        if wsum <= 0 then return nil, "NO_SOIL" end
        local score = sum / wsum
        if b ~= nil and b.payload ~= nil and b.payload.earnedScore ~= nil and (before.observedAmount or 0) > 0 then
            score = (score * born + b.payload.earnedScore * before.observedAmount) / (born + before.observedAmount)
        end
        return gradedRecord(score, score, out.amount, out.amount)
    end,
    disclosure = function() return nil, "DISCLOSURE_DENIED" end }

--- Soil varying per 2 m value cell, as a real field's value maps do.
local function gradient(m)
    m.soilFertilityManager.getSoilValueAtWorld = function(_, key, x, z)
        local cx, cz = math.floor((x + 128) / 2), math.floor((z + 128) / 2)
        local v = { nitrogen = 30 + (cx % 7) * 3 + (cz % 5), phosphorus = 25 + (cz % 7) * 2, potassium = 25 + ((cx + cz) % 6) * 2, pH = 5.8 + (cx % 4) * 0.2 }
        return v[key], 2
    end
end

--- A driven field: SWATHS swaths 2 m apart, 10 ticks a swath, the Mower's cut and drop moved 1 m a tick,
--- so drops overlap and cells mix several ticks' grades. (The battery runs a copy with fewer swaths.)
local SWATHS = 8
local function drivenField(key, index)
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({}, key, index)
    m.stockGuard.registerProperty(GRADED, gradedSpec)
    gradient(m)
    local nodes = { w.cut.start, w.cut.width, w.cut.height, w.drop.start, w.drop.width, w.drop.height }
    local x0, z0 = {}, {}
    for i, n in ipairs(nodes) do x0[i], z0[i] = n.x, n.z end
    for k = 0, SWATHS - 1 do
        for t = 0, 9 do
            local dx, dz = t, 2 * k
            for i, n in ipairs(nodes) do n.x, n.z = x0[i] + dx, z0[i] + dz end
            ENGINE_PLANE.sow(MEADOW_F, -1 + dx, dz - 1, 1 + dx, dz + 1, 4)
            tick(host, w.mower, w.cut)
        end
    end
    return m, sg, host, w
end

local function recordsOf(sg)
    local out, n = {}, 0
    for _, s in ipairs(groundStocks(sg)) do
        out[s.stockId] = SGValues.canonicalKey(s.properties)
        n = n + 1
    end
    return out, n
end
local function compare(before, after)
    local same, total = 0, 0
    for id, key in pairs(before) do
        total = total + 1
        if after[id] == key then same = same + 1 end
    end
    return same .. "/" .. total
end
local function measure(dir)
    local t = payloadTree(dir)
    local sets, maps = 0, 0
    for _ in pairs(t and t.properties or {}) do sets = sets + 1 end
    for _, r in ipairs(t and t.runs or {}) do if r.cellValues ~= nil then maps = maps + r.n end end
    local d = ENGINE_DISK[dir .. "/" .. GR.PAYLOAD_FILE]
    local bytes, tok = 0, d and d[GR.PAYLOAD_ROOT .. "#count"] or 0
    for i = 1, tok do bytes = bytes + #tostring(d[string.format("%s.token(%d)#v", GR.PAYLOAD_ROOT, i - 1)] or "") end
    return sets, maps, bytes, tok
end
local function mowerBuild(m2, w2)
    soilOn(m2)
    w2.mower, w2.cut, w2.drop = newMower("vehicle:mower", {})
    vehicleIn(m2, w2.mower)
end

-- The writer before this row (development 453e07b, after MAINTENANCE 237), VERBATIM but for its name.
local copy = SGValues.copy
local function devGroundRecords(self)
    local ops = self.host ~= nil and self.host.operations or nil
    if ops == nil then return {}, {}, {} end
    local rec = ops:collectRecords(GR.ownsCarrier)
    local stockBy = {}
    for _, s in ipairs(rec.stocks) do stockBy[s.stockId] = s end
    local cells, properties, keys, n = {}, {}, {}, 0
    for _, c in ipairs(rec.carriers) do
        local d = c.binding.sourceDescriptor
        local s = c.stockId ~= nil and stockBy[c.stockId] or nil
        if s ~= nil and type(d) == "table" and s.materialRef ~= nil and s.materialRef.kind == "FILL_TYPE" then
            -- MAINTENANCE row 237: the set is shared without each record's materialRevision; the
            -- cell keeps a revision only where it differs from its own dataRevision.
            local records, revisions = {}, nil
            for i, p in ipairs(s.properties or {}) do
                local r = copy(p)
                if r.materialRevision ~= nil and r.materialRevision ~= s.dataRevision then
                    revisions = revisions or {}
                    revisions[r.propertyId] = r.materialRevision
                end
                r.materialRevision = nil
                records[i] = r
            end
            local shared = { properties = records, acceptedCauses = s.acceptedCauses or {} }
            local ck = SGValues.canonicalKey(shared)
            local pk = keys[ck]
            if pk == nil then
                n = n + 1
                pk = "p" .. tostring(n)
                keys[ck] = pk
                properties[pk] = shared
            end
            cells[GR.cellKey(d.x, d.z)] = { x = d.x, z = d.z, fillType = s.materialRef.fillTypeName, liters = s.observedAmount, generation = s.contentsGeneration,
                property = pk, stockId = s.stockId, dataRevision = s.dataRevision, knowledge = s.knowledge, reason = s.reason, lastGeneration = c.lastGeneration,
                materialRevisions = revisions }
        end
    end
    return cells, properties, rec.historical
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: AN EXACT ROUND-TRIP
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg = drivenField("m239_s", 401)
    local before, n = recordsOf(sg)
    local graded, scores = 0, {}
    for _, s in ipairs(groundStocks(sg)) do
        local q = s.properties[GRADED]
        if q ~= nil and q.payload ~= nil and q.payload.earnedScore ~= nil then
            graded = graded + 1
            scores[string.format("%.17g", q.payload.earnedScore)] = true
        end
    end
    local distinct = 0
    for _ in pairs(scores) do distinct = distinct + 1 end
    T.ok("S0 [world] a driven field: every mown cell carries a graded record, with well over a hundred distinct score pairs among them", n > 300 and graded == n and distinct > 100)
    nativeSave(m, "m239_s")
    local m2, sg2 = reload(m, "m239_s", mowerBuild, { index = 401 })
    local after, n2 = recordsOf(sg2)
    T.eq("S1 [entry point] the reload restores every cell's every record byte-equal, its score pair and coverage included",
        tostring(sg2.ground.lastRestore and sg2.ground.lastRestore.restored) .. "/" .. n2 .. "/" .. compare(before, after), n .. "/" .. n .. "/" .. n .. "/" .. n)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. THE MEASUREMENT
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    local cellCount
    local function run(writer, key, index)
        local real = GR.groundRecords
        if writer ~= nil then GR.groundRecords = writer end
        local result
        local ok, err = pcall(function()
            local m, sg = drivenField(key, index)
            cellCount = #groundStocks(sg)
            nativeSave(m, key)
            local s1, c1, b1 = measure(key)
            local m2 = reload(m, key, mowerBuild, { index = index })
            nativeSave(m2, key .. "b")
            local s2, c2, b2 = measure(key .. "b")
            FSBaseMission.delete(m2)
            result = { s1 = s1, c1 = c1, b1 = b1, s2 = s2, c2 = c2, b2 = b2 }
        end)
        GR.groundRecords = real
        if not ok then error(err, 0) end
        return result
    end
    local dev = run(devGroundRecords, "m239_zdev", 402)
    local now = run(nil, "m239_znow", 403)
    T.ok("Z1 the shared sets collapse: far fewer than before", now.s1 * 10 < dev.s1 and now.s2 * 10 < dev.s2)
    -- Pinned. A measurement, not an acceptance bound: the PR body carries it for Bob and Desk.
    T.eq("Z2 THE MEASUREMENT: cells; first save sets and token bytes, before and after; after a reload, the same",
        string.format("cells=%d first: before sets=%d %dB, after sets=%d maps=%d %dB | reload: before sets=%d %dB, after sets=%d maps=%d %dB",
            cellCount, dev.s1, dev.b1, now.s1, now.c1, now.b1, dev.s2, dev.b2, now.s2, now.c2, now.b2),
        "cells=914 first: before sets=227 261321B, after sets=8 maps=914 200140B | reload: before sets=227 264832B, after sets=8 maps=914 203651B")
    -- What a cell keeps now is its own values list: the two full-precision scores and its coverage marks,
    -- the floor for an exact save. Sets left: 8, one per propertyRevision (1 to 8: a cell's record gains a
    -- revision with each later drop onto it), measured. This stand-in's masks never vary; a drop mixing in
    -- an unknown portion would split its own sets too (Bob's watch point), which 2.2 measures with SG-3.
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. PARTIAL COVERAGE
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetWorld()
    soilReset()
    -- Two tippers onto one pile: the first carries sg24b.origin over its whole load, the second none, so
    -- the cells it tops up hold a record covering only part of their litres.
    local m, sg, host, w, lease = boot(function(m, w)
        tipWorld(m, w)
        w.plain = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:plain", { level = 600, fillType = WHEAT, at = { x = 10, z = 10 } }))
    end, "m239_t", { index = 404 })
    T.eq("T0 [world] the first tipper's stock takes o = 7", tostring(publish(m, sg, lease, unitId(w.tipper), 7)), "APPLIED")
    ENGINE_TIP(w.tipper, 100)
    ENGINE_TIP(w.plain, 100)
    local before, n = recordsOf(sg)
    local partial = 0
    for _, s in ipairs(groundStocks(sg)) do
        local p = s.properties[PROP]
        if p ~= nil and p.knownAmount ~= nil and p.knownAmount < s.observedAmount then partial = partial + 1 end
    end
    T.ok("T1 [world] some cells hold a record covering only part of their litres", partial > 0)
    nativeSave(m, "m239_t")
    local m2, sg2 = reload(m, "m239_t", function(m3, w3)
        tipWorld(m3, w3, { level = level(w.tipper) })
        w3.plain = vehicleIn(m3, ENGINE_NEW_TIPPER("vehicle:plain", { level = level(w.plain), fillType = WHEAT, at = { x = 10, z = 10 } }))
    end, { index = 404 })
    T.eq("T2 partial coverage round-trips exactly", compare(before, (recordsOf(sg2))), n .. "/" .. n)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. A PAYLOAD IN THE LAYOUT BEFORE THIS ROW
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    local m, sg = drivenField("m239_o", 405)
    local before, n = recordsOf(sg)
    local real = GR.groundRecords
    GR.groundRecords = devGroundRecords
    local ok, err = pcall(nativeSave, m, "m239_o")
    GR.groundRecords = real
    if not ok then error(err, 0) end
    local t = payloadTree("m239_o")
    local marked = 0
    for _, set in pairs(t and t.properties or {}) do
        for _, r in ipairs(set.properties or {}) do
            if r[GR.CELL_RECORD_MARK] ~= nil or r[GR.CELL_PAYLOAD_MARK] ~= nil then marked = marked + 1 end
        end
    end
    T.eq("O1 [world] the old layout: no marker in any set", tostring(marked), "0")
    local m2, sg2 = reload(m, "m239_o", mowerBuild, { index = 405 })
    T.eq("O2 an old payload loads byte-exact", compare(before, (recordsOf(sg2))), n .. "/" .. n)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. validCell
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local function cell(map) return { x = 1, z = 1, fillType = "GRASS_WINDROW", liters = 1, generation = 1, cellValues = map } end
    local out = {}
    for _, map in ipairs({
        { { false, 0.5, 70, 70 } },
        { false, { 70 } },
        "x",
        {},
        { { 70 }, nil, { 70 } },
        { "x" },
        { {} },
        { { "70" } },
        { { 0 / 0 } },
        { [2] = { 70 } },
    }) do
        local ok, why = GR.validCell(cell(map), {})
        out[#out + 1] = ok ~= nil and "ok" or tostring(why)
    end
    T.eq("V1 a cell list (per record: false, or finite numbers and false) is valid; anything else refuses the payload",
        table.concat(out, ","), "ok,ok,CELL_VALUES,CELL_VALUES,CELL_VALUES,CELL_VALUES,CELL_VALUES,CELL_VALUES,CELL_VALUES,CELL_VALUES")
end)
end
