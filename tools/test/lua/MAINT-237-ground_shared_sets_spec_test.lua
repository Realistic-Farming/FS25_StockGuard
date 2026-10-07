-- MAINT-237-ground_shared_sets_spec_test.lua
--
-- MAINTENANCE row 237 (Bob's intake of 2026-10-07, BOB-INTAKE-SG-GROUND-SAVE-SHARED-SETS; SG-2 v2.3
-- :160, "shared immutable property payloads ... Compression may change storage layout, never ...
-- property precision or separate contents"): the ground save keys and stores each shared property
-- set without its records' materialRevision, and a cell keeps a revision of its own only where it
-- differs from the cell's dataRevision. Every record comes back from a reload exactly as it was saved.
--
-- WHY. An installed record carries its own stock's materialRevision (SGOperations installProperty), so
-- once a STORED property is born on every birth (SG-3's qualityBasisV1, Part 2.1), no two ground cells
-- shared a set: a deterministic mown field of 302 cells saved 302 sets in place of 1 (+130.6% payload).
--
-- THE WORLD. The SG2-5c bench's preamble, verbatim (the engine's own Mower type, Soil's recorder, the
-- stand-in soil.groundCondition owner, the tip world and its sg24b.origin producer), as that bench
-- copied SG2-5b's. A stand-in STORED producer that declares births and records every one as an
-- unavailable origin reproduces what SG-3 Part 2.1 does on the ground, without SG-3 on this branch.
--
-- THE ENTRY-POINT BAR IS GROUP S: main.lua's load path; the native host brackets the Mower's captured
-- pointer and its drop slot; the engine's own order mows and drops, and a second pass over the same
-- swaths makes UPDATE'd cells, whose records keep the revision from before their stock's bump. The
-- save and the reload are the native save controller's and the ground section's own.
--
-- Groups:
--   S  a mown field with UPDATE'd cells, saved and reloaded: every cell's every record byte-equal,
--      materialRevision included; the cell map holds exactly the revisions that differ
--   T  the tip world: a carried record (sg24b.origin, o = 7) tipped twice onto one pile, the same
--      round trip
--   Z  the size: the shared sets collapse, with the payload's figures pinned
--   O  a payload written in the old layout (each set carrying its records' revisions, no cell map)
--      loads to the same records
--   V  validCell refuses a malformed cell map
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
-- MAINTENANCE row 237: THE GROUND SAVE'S SHARED PROPERTY SETS
-- ══════════════════════════════════════════════════════════════════════════
-- A STORED producer that declares births and records each one as an unavailable origin: what SG-3
-- Part 2.1's qualityBasisV1 does for every birth it does not grade (the mower's among them).
local BIRTH = "bench.birthOrigin"
local birthSpec = { schemaVersion = 1, producerId = "benchBirth", residency = "STORED", birth = true,
    validate = function() return true end,
    combine = function() return nil, "UNKNOWN_ORIGIN" end,
    transform = function() return nil, "UNKNOWN_ORIGIN" end,
    disclosure = function() return nil, "DISCLOSURE_DENIED" end }
local FIELD_PASSES = 8

--- A field mown in FIELD_PASSES swaths 2 m apart (the Mower's cut and drop areas moved along z, the
--- meadow sown under the cut first), then `again` of those swaths mown a second time, so their cells
--- take a second drop: an UPDATE.
local function mownField(key, index, again)
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({}, key, index)
    m.stockGuard.registerProperty(BIRTH, birthSpec)
    local nodes = { w.cut.start, w.cut.width, w.cut.height, w.drop.start, w.drop.width, w.drop.height }
    local z0 = {}
    for i, n in ipairs(nodes) do z0[i] = n.z end
    local function swath(k)
        local dz = 2 * k
        for i, n in ipairs(nodes) do n.z = z0[i] + dz end
        ENGINE_PLANE.sow(MEADOW_F, -1, dz - 1, 1, dz + 1, 4)
        tick(host, w.mower, w.cut)
    end
    for k = 0, FIELD_PASSES - 1 do swath(k) end
    for k = 0, (again or 0) - 1 do swath(k) end
    return m, sg, host, w
end

--- Every ground stock's records, by stock id: the canonical key of its whole property map.
local function recordsOf(sg)
    local out, n = {}, 0
    for _, s in ipairs(groundStocks(sg)) do
        out[s.stockId] = SGValues.canonicalKey(s.properties)
        n = n + 1
    end
    return out, n
end
--- The ground stocks with a record whose materialRevision is not the stock's own dataRevision.
local function lagging(sg)
    local n = 0
    for _, s in ipairs(groundStocks(sg)) do
        for _, p in pairs(s.properties) do
            if p.materialRevision ~= s.dataRevision then n = n + 1 break end
        end
    end
    return n
end
--- "same/total" over the stocks saved before and read after.
local function compare(before, after)
    local same, total = 0, 0
    for id, key in pairs(before) do
        total = total + 1
        if after[id] == key then same = same + 1 end
    end
    return same .. "/" .. total
end
--- The payload's distinct sets and its cells carrying a revision map.
local function layout(dir)
    local t = payloadTree(dir)
    local sets, maps = 0, 0
    for _ in pairs(t and t.properties or {}) do sets = sets + 1 end
    for _, r in ipairs(t and t.runs or {}) do if r.materialRevisions ~= nil then maps = maps + r.n end end
    return sets, maps
end
local function tokenBytes(path, root)
    local d = ENGINE_DISK[path]
    if d == nil then return nil, 0 end
    local n = d[root .. "#count"] or 0
    local bytes = 0
    for i = 1, n do bytes = bytes + #tostring(d[string.format("%s.token(%d)#v", root, i - 1)] or "") end
    return bytes, n
end
local function mowerBuild(m2, w2)
    soilOn(m2)
    w2.mower, w2.cut, w2.drop = newMower("vehicle:mower", {})
    vehicleIn(m2, w2.mower)
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: A MOWN FIELD WITH UPDATE'D CELLS, SAVED AND RELOADED
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg = mownField("m237_s", 301, 2)
    local before, n = recordsOf(sg)
    local lag = lagging(sg)
    local born = 0
    for _, s in ipairs(groundStocks(sg)) do if s.properties[BIRTH] ~= nil then born = born + 1 end end
    T.ok("S0 [reached] the stand-in birth producer recorded every mown cell", n >= FIELD_PASSES and born == n)
    T.ok("S1 [world] a second pass over two swaths UPDATE'd their cells: their records keep the revision from before their stock's bump (SGOperations.lua:1302, :1305)",
        lag > 0 and lag < n)
    nativeSave(m, "m237_s")
    local sets, maps = layout("m237_s")
    T.eq("S2 the payload's cell map holds exactly the cells whose revision differs; a born cell writes nothing", tostring(maps), tostring(lag))
    local m2, sg2 = reload(m, "m237_s", mowerBuild, { index = 301 })
    local after, n2 = recordsOf(sg2)
    T.eq("S3 the reload restores every cell's every record byte-equal, materialRevision included",
        tostring(sg2.ground.lastRestore and sg2.ground.lastRestore.restored) .. "/" .. n2 .. "/" .. compare(before, after), n .. "/" .. n .. "/" .. n .. "/" .. n)
    -- SGOperations restoreCore's reattach bumps each restored stock's dataRevision (:2168, :2183), so
    -- after a reload every record's saved revision is behind its stock's: that is the core rule, kept.
    T.eq("S4 the reattach gives every restored stock a fresh dataRevision, and no record is restamped with it", tostring(lagging(sg2)), tostring(n))
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. A CARRIED RECORD: THE TIP WORLD
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetWorld()
    soilReset()
    local m, sg, host, w, lease = boot(function(m, w) tipWorld(m, w) end, "m237_t", { index = 302 })
    T.eq("T0 [world] the tipper's stock takes o = 7", tostring(publish(m, sg, lease, unitId(w.tipper), 7)), "APPLIED")
    ENGINE_TIP(w.tipper, 100)
    ENGINE_TIP(w.tipper, 100)
    local before, n = recordsOf(sg)
    local carried = 0
    for _, s in ipairs(groundStocks(sg)) do if s.properties[PROP] ~= nil and s.properties[PROP].payload.o == 7 then carried = carried + 1 end end
    T.ok("T1 [world] two tips onto one pile: every cell carries o = 7 and some took a second frame", n > 1 and carried == n)
    nativeSave(m, "m237_t")
    local m2, sg2 = reload(m, "m237_t", function(m3, w3) tipWorld(m3, w3, { level = level(w.tipper) }) end, { index = 302 })
    local after = recordsOf(sg2)
    T.eq("T2 the carried records round-trip byte-equal, materialRevision included", compare(before, after), n .. "/" .. n)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. THE SIZE
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    local m, sg = mownField("m237_z", 303, 0)
    local _, n = recordsOf(sg)
    local revs = {}
    for _, s in ipairs(groundStocks(sg)) do
        local p = s.properties[BIRTH]
        local k = p and tostring(p.propertyRevision) or "none"
        revs[k] = (revs[k] or 0) + 1
    end
    local split = {}
    for k, c in pairs(revs) do split[#split + 1] = "rev" .. k .. "=" .. c end
    table.sort(split)
    local lag = lagging(sg)
    nativeSave(m, "m237_z")
    local sets, maps = layout("m237_z")
    local bytes, tokens = tokenBytes("m237_z/" .. GR.PAYLOAD_FILE, GR.PAYLOAD_ROOT)
    T.ok("Z1 the field's cells share their sets again: far fewer sets than cells", sets < n)
    -- The 2.1 measurement's world (8 swaths, 302 cells): 302 sets before this row. Pinned, so a change
    -- to what a set or a cell carries is measured again.
    T.eq("Z2 THE MEASUREMENT: cells, saved sets, cells with a revision map, and the payload's token bytes",
        string.format("cells=%d sets=%d cell_maps=%d lagging=%d %s payload=%dB/%dtok", n, sets, maps, lag, table.concat(split, ","), bytes or -1, tokens),
        "cells=302 sets=2 cell_maps=98 lagging=98 rev1=204,rev2=98 payload=46112B/11247tok")
    -- Two sets, not one: the record's propertyRevision is 1 on 204 born cells and 2 on the 98 a
    -- neighbouring swath's drop UPDATEd (installProperty). Those same 98 lag their stock and carry the
    -- map; the born cells write nothing more. propertyRevision stays in the set (Bob's intake: carry it
    -- per cell only if the count stays high; it is 2).
    -- The save after a reload: restoreCore's reattach gives every stock a fresh dataRevision (:2168,
    -- :2183), so every record now lags its cell and every cell writes its map. Measured, not assumed.
    local m2, sg2 = reload(m, "m237_z", mowerBuild, { index = 303 })
    nativeSave(m2, "m237_z2")
    local sets2, maps2 = layout("m237_z2")
    local bytes2, tokens2 = tokenBytes("m237_z2/" .. GR.PAYLOAD_FILE, GR.PAYLOAD_ROOT)
    T.eq("Z3 THE SECOND SAVE, after a reload: the same field's saved sets, cells with a map, lagging cells and token bytes",
        string.format("sets=%d cell_maps=%d lagging=%d payload=%dB/%dtok", sets2, maps2, lagging(sg2), bytes2 or -1, tokens2),
        "sets=2 cell_maps=302 lagging=302 payload=54272B/12471tok")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. A PAYLOAD IN THE OLD LAYOUT
-- ══════════════════════════════════════════════════════════════════════════
-- The writer before this row, in substance: each cell's set is its stock's own serialized records and
-- causes, revisions included, deduplicated on the whole set, and no cell map (SGGround.lua:322-336 at
-- development 32821de).
local function oldGroundRecords(self)
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
            local shared = { properties = s.properties or {}, acceptedCauses = s.acceptedCauses or {} }
            local ck = SGValues.canonicalKey(shared)
            local pk = keys[ck]
            if pk == nil then
                n = n + 1
                pk = "p" .. tostring(n)
                keys[ck] = pk
                properties[pk] = shared
            end
            cells[GR.cellKey(d.x, d.z)] = { x = d.x, z = d.z, fillType = s.materialRef.fillTypeName, liters = s.observedAmount, generation = s.contentsGeneration,
                property = pk, stockId = s.stockId, dataRevision = s.dataRevision, knowledge = s.knowledge, reason = s.reason, lastGeneration = c.lastGeneration }
        end
    end
    return cells, properties, rec.historical
end

group("O", function()
    local m, sg = mownField("m237_o", 304, 2)
    local before, n = recordsOf(sg)
    local real = GR.groundRecords
    GR.groundRecords = oldGroundRecords
    local ok, err = pcall(nativeSave, m, "m237_o")
    GR.groundRecords = real
    if not ok then error(err, 0) end
    local sets, maps = layout("m237_o")
    T.eq("O1 [world] the old layout: one set per cell, no cell map", sets .. "/" .. maps, n .. "/0")
    local m2, sg2 = reload(m, "m237_o", mowerBuild, { index = 304 })
    local after = recordsOf(sg2)
    T.eq("O2 an old payload loads to the same records: the set's own revision stands", compare(before, after), n .. "/" .. n)
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. validCell
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local function cell(map) return { x = 1, z = 1, fillType = "GRASS_WINDROW", liters = 1, generation = 1, materialRevisions = map } end
    local out = {}
    for _, map in ipairs({ { ["p"] = "r:1" }, "r:1", { [""] = "r:1" }, { p = "" }, { p = string.rep("r", 65) }, { p = 7 } }) do
        local ok, why = GR.validCell(cell(map), {})
        out[#out + 1] = ok ~= nil and "ok" or tostring(why)
    end
    T.eq("V1 a cell map of property ids to revisions of 64 bytes or less is valid; anything else refuses the payload",
        table.concat(out, ","), "ok,MATERIAL_REVISIONS,MATERIAL_REVISIONS,MATERIAL_REVISIONS,MATERIAL_REVISIONS,MATERIAL_REVISIONS")
end)
end
