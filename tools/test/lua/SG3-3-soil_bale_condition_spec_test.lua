-- SG3-3-soil_bale_condition_spec_test.lua
--
-- SG-3 Part 3 (SG-3 v1.2 build brief, "Damage witness intake owned by SG-3" and "Exact SG3 / F215 condition read
-- and notification contract"; Bob's R-15 of 2026-10-08, Desk Office/Drafts/BOB-R15-SG3-PART3-SOIL-BALE-CONDITION-
-- 2026-10-08.md): SOIL_BALE_CONDITION_V1 joins a square bale's quality to Soil's bale condition. The square finish's
-- operation is open while its original runs (readOpenOperation), Soil echoes it at the bale's BIRTH, SG-3 queues the
-- paired event under it and the finish collects it into its settle, where the bale takes the birth handicap r(C1)
-- from C0 = 0 once; each daily ADVANCE is then published through publishProperties under the stream's cause.
--
-- THE ENTRY-POINT BAR IS GROUP J: 2.2's chain world (bale-2b's world VERBATIM, the field tool model's Mower and
-- Tedder ported, the meadow its own descriptor; SG3-2-2-mower_chain_spec_test.lua), every machine installed by
-- main.lua's own load path, with Soil's YardLadder, MaterialDown and provider VERBATIM (tools/test/lua/soil_fixture,
-- at Soil's c410ac01) armed in the order Soil's own mission load arms them, and Soil's birth door on the Baler (a
-- stand-in of BalerCollection's createBale wrap; Soil's own bench drives the real one). Nothing pre-fills a record,
-- a coverage, a cause or a portion: each exists because a native call or Soil's own code made it.
--
-- Groups:
--   J  the entry-point bar: the bale's handicap, its coverage, a graded current assessment, the join line once;
--      a daily ADVANCE once, its replay ALREADY_APPLIED; a missed ADVANCE closed cumulatively under the delta rule,
--      and not when the deltas differ
--   O  the open operation: none outside the bracket (RETIRE), a colon call refuses, an id SG-1 does not hold open
--      reads nil, a throw in the original leaves the stack empty, an event naming an operation that is not open
--      queues nothing
--   E  a crossed epoch is unavailable; a throw inside SG-3's after never blocks Soil
--   B  the bind order (the provider arms after StockGuard's install, the mission-start retry binds); no provider
--   F  a wrapped grass bale's fermentation keeps its coverage
--   S  a save and a reload: no re-birth, the accepted cause kept
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, tools/test/lua/soil_fixture/soil_world.lua, tools/test/lua/soil_fixture/MaterialDown.lua, tools/test/lua/soil_fixture/YardLadder.lua, tools/test/lua/soil_fixture/SoilBaleConditionProvider.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGNativeHost.lua, src/sg3/SG3Profiles.lua, src/sg3/SG3Evaluator.lua, src/sg3/SG3Quality.lua, src/sg3/SG3Assessments.lua, src/sg3/SG3Condition.lua, src/sg3/SG3.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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
    m.objectsToClassName = {}
    -- SG2 bale family 2b: every mission has an item system (the bench's model, below).
    if NEW_ITEM_SYSTEM ~= nil then m.itemSystem = NEW_ITEM_SYSTEM(m) end
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
-- ── The windrow types (a model extension) ───────────────────────────────────
-- The ground model has height types for WHEAT and BARLEY only; the Tedder's own types are added here
-- exactly as its addHeightType builds one (SG2-4b-ground_model.lua:341-348), with their names, so the
-- profile's pair (SG-2 :652, GRASS_WINDROW into DRYGRASS_WINDROW) is named as it is in game.
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

-- ── The engine's Tedder (vehicles/specializations/Tedder.lua) ───────────────────────────────
-- DensityMapHeightUtil.lua:425-449 VERBATIM, and :450-455 (as the SG2-5a bench carries them).
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

-- ══════════════════════════════════════════════════════════════════════════
-- SG2-5d-b: the Baler, FillUnit's add, and Soil's 5d surface
-- ══════════════════════════════════════════════════════════════════════════
-- Inside one function: the preamble's file-level locals with this part's would pass Lua's
-- 200-local limit for a single function.
local function SG2B_BENCH()

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

-- ── THE ENGINE'S FLOAT WRITER AND ITS TWO POSSIBLE READERS, MODELLED (as MAINT-206's bench) ──
-- Measured from the save files: an XMLValueType.FLOAT is written as its float32 to six decimals,
-- ties to even (MAINT-206's bench pins the 52 engine-written pairs). Within this file the XML
-- model's FLOAT paths are written that way and read back by either reader the C side might be.
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

-- ── fill types: the world's, with SILAGE (a fermented bale's output) ──────────────
local SILAGE = 11
do
    local fm = g_fillTypeManager
    local byIndex, byName = fm.getFillTypeNameByIndex, fm.getFillTypeIndexByName
    fm.getFillTypeNameByIndex = function(self, i) if i == SILAGE then return "SILAGE" end return byIndex(self, i) end
    fm.getFillTypeIndexByName = function(self, n) if n == "SILAGE" then return SILAGE end return byName(self, n) end
    --- FillTypeManager:getFillTypeByName, as Baler:onPostLoad reads a listed bale's type (Baler.lua:548).
    fm.getFillTypeByName = function(self, n) local i = self:getFillTypeIndexByName(n) return i ~= nil and { index = i } or nil end
end

-- ── objects/Bale.lua at 1.24, the parts the Baler, the item system, the wrapper and 2b reach ─────
-- MountableObject is the base (Bale.lua:6); Bale.new registers the class name (:34) and starts with
-- needsSaving true (:37); loadFromConfigXML applies a given uniqueId (:269-271), then adds the bale to
-- the item system (:272), which gives one with no id a fresh one (ItemSystem.lua:209-211); delete stops
-- fermentation (:69-71, abbreviated) and removes it from the item system (:75). setFillType sets the
-- type and, for a type that ferments unwrapped, starts fermenting (:494-514, the BaleManager
-- registration abbreviated to the flag); setWrappingState starts it for a type that needs wrapping
-- (abbreviated likewise); onFermentationEnd (:702-711) VERBATIM. saveToXMLFile writes the uniqueId
-- (:417) into a vehicle's XML (the wrapper's own save), or gives the item system its record.
-- BALES.failLoad makes loadFromConfigXML refuse (a config file that does not load).
local MountableObject = engineClass({})
local BaleModel, Bale_mt = engineClass({}, MountableObject)
local BALES = { next = 90000, made = {}, failLoad = false }
local FERMENTING = { [GRASS] = { outputFillTypeIndex = SILAGE, requiresWrapping = true } }
function BaleModel.new(isServer, isClient, customMt)
    BALES.next = BALES.next + 1
    local self = setmetatable({ isServer = isServer, isClient = isClient, nodeId = BALES.next, fillLevel = 0, needsSaving = true,
                                wrappingState = 0, isFermenting = false }, customMt or Bale_mt)
    REAL.registerObjectClassName(self, "Bale")
    return self
end
function BaleModel:loadFromConfigXML(filename, _x, _y, _z, _rx, _ry, _rz, uniqueId)
    if BALES.failLoad then return false end
    self.filename = filename
    if uniqueId ~= nil then self:setUniqueId(uniqueId) end
    g_currentMission.itemSystem:addItem(self)
    return true
end
function BaleModel:getUniqueId() return self.uniqueId end
function BaleModel:setUniqueId(id) self.uniqueId = id end
function BaleModel:getFillType() return self.fillType end
function BaleModel:getFillLevel() return self.fillLevel end
function BaleModel:getFillTypeInfo(ft) return { fermenting = FERMENTING[ft] } end
function BaleModel:setFillType(ft)
    self.fillType = ft
    local f = FERMENTING[ft]
    if self.isServer and f ~= nil and not f.requiresWrapping then self.isFermenting = true end
end
function BaleModel:setWrappingState(state)
    self.wrappingState = state
    local f = FERMENTING[self.fillType]
    if self.isServer and state > 0 and f ~= nil and f.requiresWrapping then self.isFermenting = true end
end
function BaleModel:setFillLevel(l) self.fillLevel = l end
function BaleModel:setVariationId(v) self.variationId = v end
function BaleModel:getVariationId() return tostring(self.variationId) end
function BaleModel:setOwnerFarmId(f) self.ownerFarmId = f end
function BaleModel:getOwnerFarmId() return self.ownerFarmId or 1 end
function BaleModel:register() BALES.made[#BALES.made + 1] = self end
function BaleModel:mountKinematic() self.mounted = true end
function BaleModel:unmountKinematic() self.mounted = false end
function BaleModel:setCanBeSold(v) self.canBeSold = v end
function BaleModel:setNeedsSaving(v) self.needsSaving = v end
function BaleModel:getNeedsSaving() return self.needsSaving end
function BaleModel:raiseDirtyFlags() end
function BaleModel:delete()
    if self.isDeleted then return end
    self.isDeleted = true
    local system = g_currentMission ~= nil and g_currentMission.itemSystem or nil
    if system ~= nil and system.itemsToSave[self] ~= nil then system:removeItem(self) end
end
function BaleModel:onFermentationEnd()
    if self.isServer and self.isFermenting then
        local fillTypeInfo = self:getFillTypeInfo(self.fillType)
        if fillTypeInfo ~= nil and fillTypeInfo.fermenting ~= nil then
            self:setFillType(fillTypeInfo.fermenting.outputFillTypeIndex)
        end
        self.isFermenting = false
        self:raiseDirtyFlags(self.fermentingDirtyFlag)
    end
end
function BaleModel:saveToXMLFile(xmlFile, key)
    if xmlFile == nil then
        return { uniqueId = self.uniqueId, filename = self.filename, fillType = self.fillType, fillLevel = writeFloat(self.fillLevel), wrappingState = self.wrappingState }
    end
    xmlFile:setValue(key .. "#uniqueId", self.uniqueId)
    xmlFile:setValue(key .. "#filename", self.filename)
    xmlFile:setValue(key .. "#fillType", g_fillTypeManager:getFillTypeNameByIndex(self.fillType))
    xmlFile:setValue(key .. "#fillLevel", self.fillLevel)
    xmlFile:setValue(key .. "#wrappingState", self.wrappingState)
end
--- Bale.registerSavegameXMLPaths, abbreviated to the attributes the bench's load reads back.
function BaleModel.registerSavegameXMLPaths(schema, key)
    schema:register(XMLValueType.STRING, key .. "#uniqueId", "Bale unique id")
    schema:register(XMLValueType.STRING, key .. "#filename", "Bale config file")
    schema:register(XMLValueType.STRING, key .. "#fillType", "Bale fill type")
    schema:register(XMLValueType.FLOAT, key .. "#fillLevel", "Bale fill level")
    schema:register(XMLValueType.FLOAT, key .. "#wrappingState", "Bale wrapping state")
end
engine("Bale", BaleModel)
engine("registerObjectClassName", function(object, className) g_currentMission.objectsToClassName[object] = className end)
REAL.BalerCreateBaleEvent = REAL.BalerCreateBaleEvent or { new = function(...) return { ... } end }
REAL.NetworkUtil = REAL.NetworkUtil or { getObjectId = function(o) return o and o.nodeId end }
if g_server ~= nil and g_server.broadcastEvent == nil then g_server.broadcastEvent = function() end end

-- ── misc/ItemSystem.lua at 1.24 (the 2a bench's model): getItemByUniqueId (:156-158), addItem
-- (:194-221) in effect, removeItem (:222-232); its save keeps an item whose getNeedsSaving is true
-- (:170), and its load gives each saved bale its uniqueId back (Bale.lua:346, applied :320). The XML
-- I/O is abbreviated to a table on the model's disk. Every mission gets one (newMission's hook below).
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
            b:setWrappingState(e.data.wrappingState or 0)
        end
    end
end
--- BaseMission:delete empties the item system (BaseMission.lua:144-145): each item's own delete.
function ItemSystemModel:deleteAll()
    local list = {}
    for _, e in ipairs(self.sortedItemsToSave) do list[#list + 1] = e.item end
    for _, item in ipairs(list) do item:delete() end
end
NEW_ITEM_SYSTEM = function(m) return ItemSystemModel.new(m) end

-- ── the Baler (vehicles/specializations/Baler.lua) ──────────────────────────
-- :1155-1184 VERBATIM for the main unit on the server (the dummy bale and animations abbreviated),
-- :1427-1454 VERBATIM, :1455-1570's server path (the bale record, Bale.new, the fill, register,
-- appended when valid; the decompile's lost `baleTypeDef` restored), :1863-1915 VERBATIM (the
-- additive effect's client half abbreviated; the pickup types are tried in a fixed order, `pickupOrder`,
-- where the decompile walks pairs over pickupFillTypes, whose order Lua leaves open), :1954-1959 VERBATIM (`spec` restored), and :1960-2009
-- VERBATIM for the quantity path (the decompile's reused locals renamed: the receiver is
-- `fillUnitIndex`; the loading-state animation and dirty flags abbreviated).
local function newBalerClass()
    local B = { CLIENT_DM_UPDATE_RADIUS = 50 }
    --- Baler.lua:29-42 in effect: the Baler's savegame paths (the platform, buffer and mission paths
    --- abbreviated), registered on the schema Vehicle.init made, as initSpecialization does.
    function B.initSpecialization()
        local schemaSavegame = Vehicle.xmlSchemaSavegame
        schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).baler#numBales", "Number of bales")
        schemaSavegame:register(XMLValueType.STRING, "vehicles.vehicle(?).baler.bale(?)#filename", "XML Filename of bale")
        schemaSavegame:register(XMLValueType.STRING, "vehicles.vehicle(?).baler.bale(?)#variationId", "Variation ID of the bale")
        schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).baler.bale(?)#ownerFarmId", "Owner of the bale")
        schemaSavegame:register(XMLValueType.STRING, "vehicles.vehicle(?).baler.bale(?)#fillType", "Bale fill type index")
        schemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?).baler.bale(?)#fillLevel", "Bale fill level")
        schemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?).baler.bale(?)#baleTime", "Bale time")
        schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).baler#baleTypeIndex", "Current bale type index", 1)
        schemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?).baler#fillUnitCapacity", "Current baler capacity depending on bale size")
    end
    --- Baler.lua:621-641 VERBATIM, :642-654 ABBREVIATED (the bale type and the capacity; the platform,
    --- mission and buffer fields are not in this world): the bale list is written whenever the Baler is
    --- square or not full, with no uniqueId.
    function B:saveToXMLFile(xmlFile, key, _)
        local spec = self.spec_baler
        if not spec.hasUnloadingAnimation or self:getFillUnitFreeCapacity(spec.fillUnitIndex) > 0 then
            xmlFile:setValue(key .. "#numBales", #spec.bales)
            for k, bale in ipairs(spec.bales) do
                local baleKey = string.format("%s.bale(%d)", key, k - 1)
                xmlFile:setValue(baleKey .. "#filename", bale.filename)
                xmlFile:setValue(baleKey .. "#variationId", bale.baleObject:getVariationId())
                xmlFile:setValue(baleKey .. "#ownerFarmId", bale.baleObject:getOwnerFarmId())
                local fillTypeStr = "UNKNOWN"
                if bale.fillType ~= FillType.UNKNOWN then
                    fillTypeStr = g_fillTypeManager:getFillTypeNameByIndex(bale.fillType)
                end
                xmlFile:setValue(baleKey .. "#fillType", fillTypeStr)
                xmlFile:setValue(baleKey .. "#fillLevel", bale.fillLevel)
                if spec.baleAnimCurve ~= nil then
                    xmlFile:setValue(baleKey .. "#baleTime", bale.time)
                end
            end
        end
        xmlFile:setValue(key .. "#baleTypeIndex", spec.currentBaleTypeIndex)
        xmlFile:setValue(key .. "#fillUnitCapacity", self:getFillUnitCapacity(spec.fillUnitIndex))
    end
    --- Baler.lua:532-558 at 1.24 (the pickup types, :533-538, are the model spec's own): the saved bale
    --- list read back into balesToLoad, an entry without a filename or with a type this game does not
    --- know dropped (:548-549). The decompile's lost `local bale = {}` restored.
    function B:onPostLoad(savegame)
        local spec = self.spec_baler
        if savegame ~= nil and not savegame.resetVehicles then
            local numBales = savegame.xmlFile:getValue(savegame.key .. ".baler#numBales")
            if numBales ~= nil then
                spec.balesToLoad = {}
                for i = 1, numBales do
                    local baleKey = string.format("%s.baler.bale(%d)", savegame.key, i - 1)
                    local bale = {}
                    bale.filename = savegame.xmlFile:getValue(baleKey .. "#filename")
                    local fillTypeStr = savegame.xmlFile:getValue(baleKey .. "#fillType")
                    local fillType = g_fillTypeManager:getFillTypeByName(fillTypeStr)
                    if bale.filename ~= nil and fillType ~= nil then
                        bale.fillType = fillType.index
                        bale.fillLevel = savegame.xmlFile:getValue(baleKey .. "#fillLevel")
                        bale.baleTime = savegame.xmlFile:getValue(baleKey .. "#baleTime")
                        bale.variationId = savegame.xmlFile:getValue(baleKey .. "#variationId")
                        bale.ownerFarmId = savegame.xmlFile:getValue(baleKey .. "#ownerFarmId")
                        table.insert(spec.balesToLoad, bale)
                    end
                end
            end
        end
    end
    --- Baler.lua:570-583 VERBATIM: the deferred finish first, then the saved list recreated.
    function B:onLoadFinished(_)
        local spec = self.spec_baler
        if self.isServer and (spec.createBaleNextFrame ~= nil and spec.createBaleNextFrame) then
            self:finishBale()
            spec.createBaleNextFrame = nil
        end
        if spec.balesToLoad ~= nil then
            for _, v in ipairs(spec.balesToLoad) do
                if self:createBale(v.fillType, v.fillLevel, nil, v.baleTime, v.filename, v.ownerFarmId, v.variationId, true) then
                    self:setBaleTime(#spec.bales, v.baleTime, true)
                end
            end
            spec.balesToLoad = nil
        end
    end
    --- Baler.lua:815-818 VERBATIM: the deferred finish once the Baler is in physics.
    function B:onUpdate(dt)
        local spec = self.spec_baler
        if self.isServer then
            if self.isAddedToPhysics and (spec.createBaleNextFrame ~= nil and spec.createBaleNextFrame) then
                self:finishBale()
                spec.createBaleNextFrame = nil
            end
        end
    end
    --- Baler.lua:1397 ABBREVIATED: the bale's position on its curve; nothing here reads it.
    function B:setBaleTime(i, baleTime, noEventSend) end
    function B:onFillUnitFillLevelChanged(fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, _, appliedDelta)
        local spec = self.spec_baler
        if fillUnitIndex == spec.fillUnitIndex then
            if self.isServer and fillLevelDelta > 0 then
                if self:getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0 then
                    if self.isAddedToPhysics then
                        self:finishBale()
                    else
                        spec.createBaleNextFrame = true
                    end
                    spec.fillUnitOverflowFillLevel = fillLevelDelta - appliedDelta
                    return
                end
                if spec.fillUnitOverflowFillLevel > 0 and fillLevelDelta > 0 then
                    local overflow = spec.fillUnitOverflowFillLevel
                    spec.fillUnitOverflowFillLevel = 0
                    spec.fillUnitOverflowFillLevel = overflow - self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, overflow, fillTypeIndex, toolType)
                    return
                end
            end
        end
    end
    function B:finishBale()
        local spec = self.spec_baler
        if spec.baleTypes ~= nil then
            local fillTypeIndex = self:getFillUnitFillType(spec.fillUnitIndex)
            if spec.hasUnloadingAnimation then
                if self:createBale(fillTypeIndex, self:getFillUnitCapacity(spec.fillUnitIndex)) then
                    g_server:broadcastEvent(BalerCreateBaleEvent.new(self, fillTypeIndex, 0, NetworkUtil.getObjectId(spec.bales[#spec.bales].baleObject)), nil, nil, self)
                    return
                end
            else
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, fillTypeIndex, ToolType.UNDEFINED)
                spec.buffer.unloadingStarted = false
                for fillType, _ in pairs(spec.pickupFillTypes) do
                    spec.pickupFillTypes[fillType] = 0
                end
                if not self:createBale(fillTypeIndex, self:getFillUnitCapacity(spec.fillUnitIndex)) then
                    return
                end
                g_server:broadcastEvent(BalerCreateBaleEvent.new(self, fillTypeIndex, spec.bales[#spec.bales].time), nil, nil, self)
            end
        end
    end
    function B:createBale(baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId, loadFromSavegame)
        local spec = self.spec_baler
        local baleTypeDef = spec.baleTypes[spec.currentBaleTypeIndex]
        local isValid = false
        local bale = { filename = xmlFilename or spec.currentBaleXMLFilename, time = baleTime, fillType = baleFillType, fillLevel = fillLevel }
        if self.isServer then
            local baleObject = Bale.new(self.isServer, self.isClient)
            -- :1481 and :1528, each with no uniqueId: loadFromConfigXML adds the bale to the item system,
            -- which gives it a fresh id (ItemSystem.lua:209-211), a reload's recreation included.
            if baleObject:loadFromConfigXML(bale.filename, 0, 0, 0, 0, 0, 0) then
                baleObject:setFillType(baleFillType)
                baleObject:setFillLevel(fillLevel)
                baleObject:setVariationId(variationId or baleTypeDef.defaultBaleVariationId)
                baleObject:setOwnerFarmId(ownerFarmId or 1, true)
                baleObject:register()
                if spec.hasUnloadingAnimation then baleObject:mountKinematic() else baleObject:setCanBeSold(false) baleObject:setNeedsSaving(false) end
                bale.baleObject = baleObject
                isValid = true
            end
        end
        if isValid then table.insert(spec.bales, bale) end
        return isValid
    end
    function B:processBalerArea(workArea, _)
        local spec = self.spec_baler
        if not self.isServer and self.currentUpdateDistance > B.CLIENT_DM_UPDATE_RADIUS then
            return 0, 0
        end
        local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height)
        if self.isServer then
            spec.fillEffectType = FillType.UNKNOWN
        end
        for _, fillTypeIndex in ipairs(spec.pickupOrder) do
            local pickedUpLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillTypeIndex, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, nil, false, nil)
            if pickedUpLiters > 0 then
                if self.isServer then
                    spec.fillEffectType = fillTypeIndex
                    if spec.additives.available and not spec.additives.appliedByBufferOverloading then
                        local fillTypeSupported = false
                        for i = 1, #spec.additives.fillTypes do
                            if fillTypeIndex == spec.additives.fillTypes[i] then
                                fillTypeSupported = true
                                break
                            end
                        end
                        if fillTypeSupported then
                            local additivesFillLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
                            if additivesFillLevel > 0 then
                                local usage = spec.additives.usage * pickedUpLiters
                                if usage > 0 then
                                    pickedUpLiters = pickedUpLiters * (1 + 0.05 * math.min(additivesFillLevel / usage, 1))
                                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                                end
                            end
                        end
                    end
                end
                spec.pickupFillTypes[fillTypeIndex] = spec.pickupFillTypes[fillTypeIndex] + pickedUpLiters
                spec.workAreaParameters.lastPickedUpLiters = spec.workAreaParameters.lastPickedUpLiters + pickedUpLiters
                return pickedUpLiters, pickedUpLiters
            end
        end
        return 0, 0
    end
    function B:onStartWorkAreaProcessing(_)
        local spec = self.spec_baler
        if self.isServer then
            spec.lastAreaBiggerZero = false
            spec.workAreaParameters.lastPickedUpLiters = 0
        end
    end
    function B:onEndWorkAreaProcessing(_, _)
        local spec = self.spec_baler
        if self.isServer then
            local maxFillType = FillType.UNKNOWN
            local maxFillTypeFillLevel = 0
            for fillTypeIndex, fillLevel in pairs(spec.pickupFillTypes) do
                if maxFillTypeFillLevel < fillLevel then
                    maxFillType = fillTypeIndex
                    maxFillTypeFillLevel = fillLevel
                end
            end
            local pickedUpLiters = spec.workAreaParameters.lastPickedUpLiters
            if pickedUpLiters > 0 then
                spec.lastAreaBiggerZero = true
                local deltaLevel = pickedUpLiters * spec.fillScale
                local fillUnitIndex = spec.fillUnitIndex
                if spec.nonStopBaling then
                    if spec.buffer.fillMainUnitAfterOverload and spec.buffer.unloadingStarted then
                        if self:getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0 then
                            fillUnitIndex = spec.buffer.fillUnitIndex
                        end
                    else
                        fillUnitIndex = spec.buffer.fillUnitIndex
                    end
                end
                self:setFillUnitFillType(fillUnitIndex, maxFillType)
                self:addFillUnitFillLevel(self:getOwnerFarmId(), fillUnitIndex, deltaLevel, maxFillType, ToolType.UNDEFINED)
            end
        end
    end
    -- A re-sourced Baler.lua makes new function values (Baler.lua:7, one chunk per map load). Lua 5.3
    -- reuses a closure with no upvalues, so each method is wrapped in a closure of its own here.
    local fresh = {}
    for k, f in pairs(B) do
        if type(f) == "function" then local inner = f fresh[k] = function(...) return inner(...) end else fresh[k] = f end
    end
    return fresh
end
REAL.Baler = newBalerClass()

-- ── a Baler as the engine builds it ──────────────────────────────────────────
-- Its registered functions COPIED into the instance (SpecializationUtil.copyTypeFunctionsInto, :141),
-- the pickup work area's pointer CAPTURED from the instance (WorkArea.lua:266), listeners raised by
-- name on the Baler class at raise time (ENGINE_RAISE). One pickup work area over x -1..1 at z 0
-- (the pickup line), or two (opts.areas = 2, the second at z 10, clear of the first's windrow). opts: capacity, round, nonStop,
-- fillScale, massLimit, additives = { level, usage }, order = { pickup types }.
local function newBaler(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = 0, capacity = opts.capacity or 1000,
        supported = { [GRASS] = true, [DRY] = true, [STRAW_W] = true } })
    v.configFileName = "data/vehicles/baler.xml"
    v.isServer, v.isClient, v.currentUpdateDistance, v.isAddedToPhysics = true, false, 0, opts.notInPhysics ~= true
    v.spec_fillUnit.fillUnits[1].massLimit = opts.massLimit
    if opts.additives ~= nil then
        v.spec_fillUnit.fillUnits[2] = { fillLevel = opts.additives.level or 0, capacity = 100000, fillType = 99, lastValidFillType = 99, supportedFillTypes = { [99] = true } }
    end
    v.addFillUnitFillLevel = fillUnitAdd
    v.setFillUnitFillType = function(self, i, ft) local u = self.spec_fillUnit.fillUnits[i] if u and u.fillLevel <= 0 then u.fillType = ft end end
    v.processBalerArea, v.finishBale, v.createBale = Baler.processBalerArea, Baler.finishBale, Baler.createBale
    v.specClasses = { Baler }
    -- vehicleTypes.xml: baseFillable's fillUnit precedes baler, so FillUnit's onPostLoad runs first.
    v.specializations[#v.specializations + 1] = Baler
    v.specializationNames[#v.specializationNames + 1] = "baler"
    v.eventListeners.onPostLoad = { ENGINE_FILLUNIT, Baler }
    v.eventListeners.onFillUnitFillLevelChanged = { Baler }
    v.eventListeners.onStartWorkAreaProcessing = { Baler }
    v.eventListeners.onEndWorkAreaProcessing = { Baler }
    v.eventListeners.onLoadFinished = { Baler }
    v.eventListeners.onUpdate = { Baler }
    v.setBaleTime = Baler.setBaleTime
    v.spec_baler = {
        fillUnitIndex = 1, fillScale = opts.fillScale or 1, hasUnloadingAnimation = opts.round == true, nonStopBaling = opts.nonStop == true,
        pickupFillTypes = { [GRASS] = 0, [DRY] = 0, [STRAW_W] = 0 }, pickupOrder = opts.order or { GRASS, DRY, STRAW_W },
        workAreaParameters = { lastPickedUpLiters = 0 },
        additives = { available = opts.additives ~= nil, fillTypes = { GRASS, DRY }, usage = opts.additives and opts.additives.usage or 0, fillUnitIndex = 2 },
        fillUnitOverflowFillLevel = 0, buffer = { fillUnitIndex = 3, unloadingStarted = false },
        bales = {}, baleTypes = { { defaultBaleVariationId = 1 } }, currentBaleTypeIndex = 1, currentBaleXMLFilename = "bale.xml",
    }
    local areas = {}
    for i = 1, opts.areas or 1 do
        local z = (i - 1) * 10
        local wa = { index = i, functionName = "processBalerArea",
                     start = { x = -1, y = 0, z = z - 0.5 }, width = { x = 1, y = 0, z = z - 0.5 }, height = { x = -1, y = 0, z = z + 0.5 } }
        wa.processingFunction = v.processBalerArea
        areas[i] = wa
    end
    v.spec_workArea = { workAreas = areas }
    return v
end
--- WorkArea:onUpdateTick's order (WorkArea.lua:175-200): the start event, each area's captured
--- pointer, the end event, both raised by name at raise time.
local function tick(v)
    local wa = v.spec_workArea.workAreas
    ENGINE_RAISE(v, "onStartWorkAreaProcessing", 16, wa)
    for _, a in ipairs(wa) do a.processingFunction(v, a, 16) end
    ENGINE_RAISE(v, "onEndWorkAreaProcessing", 16, wa)
end
--- A tipper of `ft` over the pickup line (area `at`), tipping `litres` there.
local function lay(m, w, ft, litres, key, at)
    local t = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. key, { level = litres, fillType = ft, at = at or { x = 0, z = 0 },
        supported = { [GRASS] = true, [DRY] = true, [STRAW_W] = true, [WHEAT] = true } }))
    w[key] = t
end

-- ── Soil's 5d surface (a stand-in) ──────────────────────────────────────────
-- Soil's admission (5d-soil) names a collector's pickup collection in its delivery result, and its
-- published readCollectedCondition runs Soil's collected reader on that capture. The stand-in keeps
-- one COLLECTED snapshot per Baler pickup: its parts are the pickup's litres split by SOIL5D.split
-- (each with its source's pct), and the reader is MaterialWetness:readCollectedCondition with
-- resolveAllocation, VERBATIM (Soil 2dd42a22 :1411-1513, as the SG2-5d-a bench carries it), so
-- StockGuard's receipt is resolved through the mission handle's own readCollectionReceipt.
local SOIL5D = { snapshots = {}, seq = 0, split = nil, reads = 0 }
local function soil5dReset(split) SOIL5D.snapshots, SOIL5D.seq, SOIL5D.split, SOIL5D.reads, SOIL5D.failRead = {}, 0, split, 0, false end
local REV = { epoch = 1, changeCounter = 9, ageThroughDay = 100, wetThroughDay = 100 }
local function soil5dOn(m)
    local gc = m.soilFertilityManager.groundCondition
    local deliver = gc.deliverMovement
    gc.deliverMovement = function(...)
        local token, obs = ...
        local result = deliver(...)
        local admit = nil
        for i = #SOIL.calls, 1, -1 do local c = SOIL.calls[i] if c.fn == "admit" then admit = c break end end
        local v = admit and admit.vehicle or nil
        if type(result) == "table" and type(v) == "table" and v.spec_baler ~= nil and type(obs) == "table" and obs.ok and (obs.litresReturned or 0) < 0 then
            local litres = -obs.litresReturned
            SOIL5D.seq = SOIL5D.seq + 1
            local id = "COLLECTED_NATIVE_VOLUME_V1#" .. SOIL5D.seq
            local snap = { id = id, basis = "COLLECTED_NATIVE_VOLUME_V1", revision = { epoch = REV.epoch, changeCounter = REV.changeCounter, ageThroughDay = REV.ageThroughDay, wetThroughDay = REV.wetThroughDay }, parts = {} }
            local parts = {}
            local split = SOIL5D.split
            if type(split) == "function" then split = split(SOIL5D.seq) end
            for _, s in ipairs(split or { { id = "c", frac = 1, pct = 30 } }) do
                local pid = SOIL5D.seq .. ":" .. s.id
                snap.parts[pid] = { available = litres * s.frac, status = s.pct ~= nil and "KNOWN" or "UNKNOWN", pct = s.pct }
                parts[#parts + 1] = { id = pid, raw = litres * s.frac }
            end
            SOIL5D.snapshots[id] = snap
            result.collection = { snapshotRef = id, basis = snap.basis, parts = parts,
                                  revision = { epoch = REV.epoch, changeCounter = REV.changeCounter, ageThroughDay = REV.ageThroughDay, wetThroughDay = REV.wetThroughDay } }
        end
        return result
    end
    gc.readCollectedCondition = function(...)
        local snapshotRef, receiptRef = ...
        SOIL5D.reads = SOIL5D.reads + 1
        local snap = SOIL5D.snapshots[snapshotRef]
        if snap == nil or SOIL5D.failRead then return { status = "unavailable", reason = "SNAPSHOT_UNKNOWN", carrierLitres = 0, knownCarrierLitres = 0, unknownCarrierLitres = 0, refusedCarrierLitres = 0, knownWeightedPctSum = 0 } end
        return MaterialWetness:readCollectedCondition(snap, receiptRef)
    end
end

-- ── Soil's collected reader, VERBATIM (SoilFertilizer src/MaterialWetness.lua at 2dd42a22) ──────

-- ── Soil's collected reader, the consumer (SoilFertilizer src/MaterialWetness.lua at 2dd42a22) ──────
-- The constants (:175-204), finiteNumber (:1116), coverageResult (:1275), bandForPct (:1052) and
-- GroundConditionCoordinator.revisionsEqual (src/ground/GroundConditionCoordinator.lua:644-650) as Soil
-- has them; then resolveAllocation and readCollectedCondition (:1411-1513) VERBATIM below. Soil's
-- isArmed is always true here. The snapshot is Soil's collectedSnapshot shape (:1186-1201): the parts
-- by id with each source's availability, status and pct, and the owner revision.
MaterialWetness = {}
MaterialWetness.RESULT = { OK = "ok", REFUSAL = "refusal", NO_MATERIAL = "noMaterial", UNAVAILABLE = "unavailable" }
MaterialWetness.BANDS = { { name = "soaked", floor = 60 }, { name = "damp", floor = 40 }, { name = "curing", floor = 25 }, { name = "fit", floor = 0 } }
MaterialWetness.BASIS = { AREA_SAMPLE = "AREA_SAMPLE_V1", STANDING = "STANDING_NATIVE_VOLUME_V1", COLLECTED = "COLLECTED_NATIVE_VOLUME_V1" }
MaterialWetness.SOURCE = { KNOWN = "KNOWN", UNKNOWN = "UNKNOWN", REFUSAL = "REFUSAL" }
local function finiteNumber(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function coverageResult(basis, status, reason)
    return { status = status, reason = reason, basis = basis,
             carrierLitres = 0, knownCarrierLitres = 0, unknownCarrierLitres = 0,
             refusedCarrierLitres = 0, knownWeightedPctSum = 0 }
end
function MaterialWetness.bandForPct(pct)
    for _, band in ipairs(MaterialWetness.BANDS) do
        if pct >= band.floor then return band.name end
    end
    return MaterialWetness.BANDS[#MaterialWetness.BANDS].name
end
GroundConditionCoordinator = GroundConditionCoordinator or {}
function GroundConditionCoordinator.revisionsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.epoch == b.epoch
       and a.changeCounter == b.changeCounter
       and a.ageThroughDay == b.ageThroughDay
       and a.wetThroughDay == b.wetThroughDay
end
function MaterialWetness:isArmed() return true end
-- :1411-1513 VERBATIM.
function MaterialWetness:resolveAllocation(receipt)
    local mission = g_currentMission
    local sg = mission ~= nil and mission.stockGuard or nil
    if sg ~= nil and type(sg.readCollectionReceipt) == "function" then
        local ok, allocation = pcall(sg.readCollectionReceipt, receipt)
        if ok and type(allocation) == "table" then return allocation, "STOCKGUARD" end
        return nil, "STOCKGUARD"
    end
    if type(receipt) ~= "table" or type(receipt.allocationId) ~= "string" then return nil, "SOIL" end
    return self.allocations[receipt.allocationId], "SOIL"
end

--- THE COLLECTED READ: the receipt resolved against the producer's sealed allocation
--- (never the caller's own figures), each portion weighted by its sealed carrier litres
--- and classified by its source's condition at capture. Always returns the coverage for
--- a valid physical receipt. A malformed or unmatchable receipt is UNAVAILABLE: its
--- caller accounts the independently observed accepted amount as unknown rather than
--- dropping those litres. A caller cannot lower the total or delete a portion to hide
--- material. RSF-F211's reference model, with the RESULT constants.
function MaterialWetness:readCollectedCondition(snapshot, receipt)
    local R, B, S = MaterialWetness.RESULT, MaterialWetness.BASIS, MaterialWetness.SOURCE
    local function unavailable(reason) return coverageResult(B.COLLECTED, R.UNAVAILABLE, reason) end
    local function refusal(reason) return coverageResult(B.COLLECTED, R.REFUSAL, reason) end
    if not self:isArmed() then return unavailable("NOT_ARMED") end
    if type(snapshot) ~= "table" or type(receipt) ~= "table" then return unavailable("MALFORMED") end
    if type(snapshot.id) ~= "string" or snapshot.id == "" or type(receipt.snapshotId) ~= "string" or receipt.snapshotId == "" then
        return unavailable("INVALID_SNAPSHOT_ID")
    end
    if snapshot.basis ~= B.COLLECTED or receipt.basis ~= B.COLLECTED then return unavailable("BASIS_MISMATCH") end
    if snapshot.revision == nil or receipt.revision == nil then return unavailable("REVISION_MISMATCH") end
    if snapshot.id ~= receipt.snapshotId then return unavailable("SNAPSHOT_MISMATCH") end
    if GroundConditionCoordinator == nil or not GroundConditionCoordinator.revisionsEqual(snapshot.revision, receipt.revision) then
        return unavailable("REVISION_MISMATCH")
    end
    if type(snapshot.parts) ~= "table" or type(receipt.parts) ~= "table" then return unavailable("PARTS_MISSING") end

    local producer = self:resolveAllocation(receipt)
    if type(producer) ~= "table" or producer.sealed ~= true then return unavailable("PRODUCER_SEAL_MISSING") end
    if producer.snapshotId ~= nil and producer.snapshotId ~= snapshot.id then return unavailable("SNAPSHOT_MISMATCH") end
    local accepted = producer.acceptedCarrierLitres
    if not finiteNumber(accepted) or accepted <= 0 or type(producer.parts) ~= "table" then
        return unavailable("INVALID_PRODUCER_ACCEPTANCE")
    end
    local total = receipt.total
    if not finiteNumber(total) or total <= 0 then return refusal("INVALID_TOTAL") end
    if total ~= accepted then return unavailable("CALLER_ACCEPTANCE_MISMATCH") end

    local seen, claimed = {}, {}
    for _, portion in ipairs(receipt.parts) do
        if type(portion) ~= "table" or type(portion.id) ~= "string" or seen[portion.id] then
            return unavailable("DUPLICATE_OR_MALFORMED_PORTION")
        end
        seen[portion.id] = true
        if not finiteNumber(portion.q) or portion.q < 0 then return refusal("INVALID_PORTION_QUANTITY") end
        claimed[portion.id] = portion.q
    end

    local out = coverageResult(B.COLLECTED, nil, nil)
    local sealedSeen, rawTotal = {}, 0
    for _, portion in ipairs(producer.parts) do
        if type(portion) ~= "table" or type(portion.id) ~= "string" or sealedSeen[portion.id] then
            return unavailable("DUPLICATE_OR_MALFORMED_PRODUCER_PORTION")
        end
        sealedSeen[portion.id] = true
        local q, raw = portion.carrierLitres, portion.rawLitres
        if not finiteNumber(q) or q < 0 then return unavailable("INVALID_PRODUCER_CARRIER_QUANTITY") end
        if not finiteNumber(raw) or raw < 0 then return unavailable("INVALID_RAW_SOURCE_QUANTITY") end
        local source = snapshot.parts[portion.id]
        if type(source) ~= "table" or not finiteNumber(source.available) or source.available < 0 or raw > source.available then
            return unavailable("SOURCE_AVAILABILITY")
        end
        if claimed[portion.id] == nil or claimed[portion.id] ~= q then return unavailable("CALLER_ALLOCATION_MISMATCH") end
        if q > 0 then
            out.carrierLitres = out.carrierLitres + q
            rawTotal = rawTotal + raw
            -- A positive carrier with no raw source is explicitly unknown produced material.
            if raw == 0 or source.status == S.UNKNOWN then
                out.unknownCarrierLitres = out.unknownCarrierLitres + q
            elseif source.status == S.REFUSAL then
                out.refusedCarrierLitres = out.refusedCarrierLitres + q
            elseif source.status == S.KNOWN then
                if not finiteNumber(source.pct) or source.pct < 0 or source.pct > 100 then return unavailable("SOURCE_VALUE") end
                out.knownCarrierLitres = out.knownCarrierLitres + q
                out.knownWeightedPctSum = out.knownWeightedPctSum + q * source.pct
            else
                out.unknownCarrierLitres = out.unknownCarrierLitres + q
            end
        end
    end
    for id in pairs(claimed) do
        if not sealedSeen[id] then return unavailable("CALLER_ALLOCATION_MISMATCH") end
    end
    if out.carrierLitres ~= accepted or out.carrierLitres ~= total then return unavailable("RECEIPT_TOTAL_MISMATCH") end
    out.rawSourceLitres = rawTotal
    if out.unknownCarrierLitres > 0 or out.refusedCarrierLitres > 0 then
        out.status, out.reason = R.REFUSAL, "POSITIVE_UNKNOWN_OR_REFUSAL"
    else
        out.status, out.reason = R.OK, "COMPLETE_KNOWN_COVERAGE"
        out.pct = out.knownWeightedPctSum / out.carrierLitres
        out.band = MaterialWetness.bandForPct(out.pct)
    end
    return out
end

-- ── `soil.groundCondition` carrying Soil's collected account (a stand-in of Soil #1077) ──
-- Resident on ground: a GROUND_CELL footprint resolves KNOWN with payload c = 7 (the preamble's
-- owner), or UNAVAILABLE where the bench says Soil cannot resolve the cell (UNRESOLVED), as Soil's
-- resolve does for an unavailable cell (GroundConditionProperty.lua :184-215). Its combine
-- weights c by amount over known inputs, and carries the ACCOUNT by Soil's rules
-- (GroundConditionProperty.lua at 2dd42a22 :250-366, VERBATIM in effect): a settle report names a
-- leg's account by allocation (outcomeEvidence["soil.groundCondition"].collectedAccounts); the named
-- leg's account is adopted only when well formed and of that leg's litres, else its litres are
-- unknown; a part whose record holds an account scales it to its litres; accounts add by carrier
-- litres, a part without one adding its litres as unknown.
local FIELDS = { "carrierLitres", "knownCarrierLitres", "unknownCarrierLitres", "refusedCarrierLitres", "knownWeightedPctSum" }
local ACC_TOL = 1e-6
local UNRESOLVED = {}
local function accountProblem(acc)
    if type(acc) ~= "table" then return "ACCOUNT" end
    for _, f in ipairs(FIELDS) do if type(acc[f]) ~= "number" or acc[f] ~= acc[f] or acc[f] < 0 then return "ACCOUNT" end end
    local parts = acc.knownCarrierLitres + acc.unknownCarrierLitres + acc.refusedCarrierLitres
    if math.abs(parts - acc.carrierLitres) > ACC_TOL * math.max(1, acc.carrierLitres) then return "ACCOUNT_SUM" end
    if acc.knownWeightedPctSum > 100 * acc.knownCarrierLitres + ACC_TOL * math.max(1, acc.knownCarrierLitres) then return "ACCOUNT_PCT" end
    return nil
end
local function accountFor(rec, litres)
    if type(rec) ~= "table" or type(rec.payload) ~= "table" or (rec.knowledge ~= "KNOWN" and rec.knowledge ~= "UNKNOWN") then return nil end
    local acc = rec.payload.account
    if acc == nil or accountProblem(acc) ~= nil or acc.carrierLitres <= 0 then return nil end
    local f, out = litres / acc.carrierLitres, {}
    for _, k in ipairs(FIELDS) do out[k] = acc[k] * f end
    return out
end
local function evidenceAccounts(ctx)
    local out = {}
    if type(ctx) ~= "table" or type(ctx.operationId) ~= "string" then return out end
    local ev = type(ctx.report) == "table" and ctx.report.outcomeEvidence or nil
    local mine = type(ev) == "table" and ev[PID] or nil
    local list = type(mine) == "table" and mine.collectedAccounts or nil
    for _, e in ipairs(type(list) == "table" and list or {}) do
        if type(e) == "table" and type(e.allocation) == "number" and e.allocation >= 1 then
            local ref = ctx.operationId .. ":a" .. tostring(e.allocation)
            if out[ref] == nil then out[ref] = e.account else out[ref] = false end
        end
    end
    return out
end
local function adoptedAccount(acc, litres)
    if acc ~= false and accountProblem(acc) == nil and math.abs(acc.carrierLitres - litres) <= ACC_TOL * math.max(1, litres) then
        local out = {}
        for _, k in ipairs(FIELDS) do out[k] = acc[k] end
        return out
    end
    return { carrierLitres = litres, knownCarrierLitres = 0, unknownCarrierLitres = litres, refusedCarrierLitres = 0, knownWeightedPctSum = 0 }
end
local AOWNER = {}
for k, val in pairs(OWNER) do AOWNER[k] = val end
AOWNER.resolveResident = function(ctx)
    local fp = ctx.footprint
    if type(fp) ~= "table" or fp.kind ~= "GROUND_CELL" then return nil, "NOT_RESIDENT" end
    if UNRESOLVED.all then return nil, "UNAVAILABLE" end
    return record(ctx, 7)
end
AOWNER.combine = function(ctx, contributions, before)
    local named = evidenceAccounts(ctx)
    local parts = {}
    local function add(litres, rec, evidence)
        litres = tonumber(litres) or 0
        if not (litres > 0) then return end
        local account
        if evidence ~= nil then account = adoptedAccount(evidence, litres) else account = accountFor(rec, litres) end
        parts[#parts + 1] = { litres = litres, rec = rec, account = account }
    end
    if before ~= nil then add(before.observedAmount, before.properties[PID], nil) end
    for _, c in ipairs(contributions) do
        local evidence = nil
        if type(c.allocationRef) == "string" then evidence = named[c.allocationRef] end
        add(c.amount, c.properties[PID], evidence)
    end
    local total, w, known = 0, 0, 0
    for _, p in ipairs(parts) do
        total = total + p.litres
        local r = p.rec
        if r and r.knowledge ~= "UNAVAILABLE" and type(r.payload) == "table" and type(r.payload.c) == "number" then w = w + r.payload.c * p.litres known = known + p.litres end
    end
    if total == 0 or known == 0 then return nil, "NO_KNOWN_INPUT" end
    local acc, any = nil, false
    for _, p in ipairs(parts) do if p.account ~= nil then any = true end end
    if any then
        acc = {}
        for _, k in ipairs(FIELDS) do acc[k] = 0 end
        for _, p in ipairs(parts) do
            if p.account ~= nil then
                for _, k in ipairs(FIELDS) do acc[k] = acc[k] + p.account[k] end
            else
                acc.carrierLitres = acc.carrierLitres + p.litres
                acc.unknownCarrierLitres = acc.unknownCarrierLitres + p.litres
            end
        end
    end
    local r = record({ amount = known }, w / known)
    r.basisAmount = total
    r.knowledge = known >= total - 1e-6 and "KNOWN" or "PARTIAL"
    r.payload.account = acc
    return r
end

-- ── readers ────────────────────────────────────────────────────────────────
local GO_ = SGGroundObserver
local function pickupId(v) return cid(NA.balerPickupBinding(v)) end
local function overflowId(v) return cid(NA.balerOverflowBinding(v)) end
local function accText(a)
    if a == nil then return "none" end
    local pct = a.knownCarrierLitres > 0 and (a.knownWeightedPctSum / a.knownCarrierLitres) or nil
    return table.concat({ num(a.carrierLitres), num(a.knownCarrierLitres), num(a.unknownCarrierLitres), num(a.refusedCarrierLitres), num(pct) }, "/")
end
--- A stock's text: material, amount, knowledge, and its soil.groundCondition (c and account).
local function stockText(s)
    if s == nil then return "none" end
    local p = s.properties[PID]
    local m = s.materialRef and (s.materialRef.fillTypeName or s.materialRef.groupId) or "nil"
    return table.concat({ tostring(m), num(s.observedAmount), tostring(s.knowledge),
        p == nil and "noRecord" or (tostring(p.knowledge) .. ":" .. num(p.payload and p.payload.c) .. ":" .. accText(p.payload and p.payload.account)) }, "|")
end
local function chamberText(sg, v) return stockText(stockAt(sg, unitId(v, 1))) end
--- The tick's operations: nativePath:outcome[:reason].
local function opsText(host)
    local t = host.lastBalerTick
    local out = {}
    for _, op in ipairs(t and t.operations or {}) do
        local e = op.evidence or {}
        out[#out + 1] = tostring(e.nativePath) .. ":" .. tostring(op.outcome) .. ((op.outcome ~= "COMMITTED" and op.reason) and (":" .. tostring(op.reason)) or "")
    end
    return table.concat(out, " ")
end
local function opOf(host, path)
    for _, op in ipairs(host.lastBalerTick and host.lastBalerTick.operations or {}) do
        if op.evidence and op.evidence.nativePath == path then return op end
    end
    return nil
end
local function admits() local n = 0 for _, c in ipairs(SOIL.calls) do if c.fn == "admit" then n = n + 1 end end return n end
--- What the bale saw: the chamber's SG-1 record at the moment finishBale ran (F211 :94).
local function probeFinish(sg, v)
    local probe = {}
    local real = v.finishBale
    v.finishBale = function(self, ...)
        local s = stockAt(sg, unitId(self, 1))
        probe[#probe + 1] = stockText(s)
        return real(self, ...)
    end
    return probe
end
local function liveCount(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

--- A Baler world: Soil's recorder and its 5d surface, the windrows tipped under the pickup.
--- opts: lay = { { ft, litres, key, at } }, noSoil, baler options.
local function balerWorld(opts)
    return function(m, w)
        if not opts.noSoil then soilOn(m) soil5dOn(m) end
        for _, l in ipairs(opts.lay or { { GRASS, 100, "grass" } }) do lay(m, w, l[1], l[2], l[3], l[4]) end
        w.baler = vehicleIn(m, newBaler("vehicle:baler", opts))
    end
end
local function boot5db(opts, key, index)
    opts = opts or {}
    soil5dReset(opts.split)
    UNRESOLVED.all = opts.unresolved == true
    local m, sg, host, w = boot(balerWorld(opts), key, { index = index })
    -- boot installs a fresh g_server; the bale's broadcast (Baler.lua:1433, :1449) needs its stub.
    if g_server ~= nil and g_server.broadcastEvent == nil then g_server.broadcastEvent = function() end end
    if not opts.noSoil then m.stockGuard.registerProperty(PID, AOWNER) end
    for _, l in ipairs(opts.lay or { { GRASS, 100, "grass" } }) do ENGINE_TIP(w[l[3]], l[2]) end
    return m, sg, host, w
end
--- Tip more windrow under the pickup line between ticks.
local function relay(m, w, ft, litres, key, at)
    lay(m, w, ft, litres, key, at)
    ENGINE_TIP(w[key], litres)
end


local XML = REAL.XMLFile
local createXml, loadXml = XML.create, XML.load
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
XML.create = function(...) return faithful(createXml(...)) end
XML.load = function(...) return faithful(loadXml(...)) end
XML.loadIfExists = XML.load

-- ══════════════════════════════════════════════════════════════════════════
-- 2b's world: the wrapper, the mission's load in the engine's order, the save and the reload
-- ══════════════════════════════════════════════════════════════════════════
--- ROW86's: the vehicle's key in vehicles.xml (the save loop's order), the file on the model's disk,
--- and the first printed line holding a pattern.
local function keyOf(m, v)
    for i, x in ipairs(m._vehicles) do if x == v then return string.format("vehicles.vehicle(%d)", i - 1) end end
    return nil
end
local function vehiclesFile(dir)
    for k, d in pairs(ENGINE_DISK) do if k == dir .. "/vehicles.xml" then return d end end
    return nil
end
local function lineWith(lines, pattern) for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then return l end end return nil end

-- ── the wrapper (vehicles/specializations/BaleWrapper.lua at 1.24, byte-identical to 1.21.1.0) ──
-- :1137-1154 the grab keeps the SAME bale object, mounted, not for sale, and out of the item system's
-- save (setNeedsSaving(false), :1152); :1158-1173 the move to the wrapper keeps it again (:1169); a
-- wrap sets its wrapping state; :698-711 the wrapper's own save writes the bale through
-- bale:saveToXMLFile, its uniqueId among the attributes; :264-276 the post-load reads them back;
-- :623-640 onLoadFinished recreates the bale WITH that uniqueId (:631) and grabs it again.
-- ABBREVIATED to those paths: one bale, no animation, no network.
local BW = {}
function BW.initSpecialization()
    BaleModel.registerSavegameXMLPaths(Vehicle.xmlSchemaSavegame, "vehicles.vehicle(?).baleWrapper.bale")
    Vehicle.xmlSchemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?).baleWrapper#wrapperTime", "Wrapper time")
end
function BW.grab(self, bale)
    bale:mountKinematic()
    bale:setCanBeSold(false)
    bale:setNeedsSaving(false)
    self.spec_baleWrapper.currentBale = bale
end
function BW.wrap(self, t)
    self.spec_baleWrapper.currentBale:setWrappingState(t)
    self.spec_baleWrapper.currentTime = t
end
function BW:saveToXMLFile(xmlFile, key, _)
    local spec = self.spec_baleWrapper
    xmlFile:setValue(key .. "#wrapperTime", spec.currentTime or 0)
    if spec.currentBale ~= nil then spec.currentBale:saveToXMLFile(xmlFile, key .. ".bale") end
end
function BW:onPostLoad(savegame)
    if savegame == nil then return end
    local k = savegame.key .. ".baleWrapper.bale"
    local uniqueId = savegame.xmlFile:getValue(k .. "#uniqueId")
    if uniqueId == nil then return end
    self.spec_baleWrapper.baleToLoad = { filename = savegame.xmlFile:getValue(k .. "#filename"), wrapperTime = savegame.xmlFile:getValue(savegame.key .. ".baleWrapper#wrapperTime"),
        attributes = { uniqueId = uniqueId, fillType = g_fillTypeManager:getFillTypeIndexByName(savegame.xmlFile:getValue(k .. "#fillType")),
                       fillLevel = savegame.xmlFile:getValue(k .. "#fillLevel"), wrappingState = savegame.xmlFile:getValue(k .. "#wrappingState") } }
end
function BW:onLoadFinished(_)
    local spec = self.spec_baleWrapper
    if spec.baleToLoad ~= nil then
        local v = spec.baleToLoad
        spec.baleToLoad = nil
        local baleObject = Bale.new(self.isServer, self.isClient)
        if baleObject:loadFromConfigXML(v.filename, 0, 0, 0, 0, 0, 0, v.attributes.uniqueId) then
            -- applyBaleAttributes (Bale.lua), abbreviated: the type, the level, the wrapping state.
            baleObject:setFillType(v.attributes.fillType)
            baleObject:setFillLevel(v.attributes.fillLevel)
            baleObject:setWrappingState(v.attributes.wrappingState or 0)
            baleObject:register()
            BW.grab(self, baleObject)
            spec.currentTime = v.wrapperTime
        end
    end
end
local function newWrapper(uid)
    local v = ENGINE_NEW_TRAILER(uid, { level = 0, capacity = 1 })
    v.configFileName = "data/vehicles/baleWrapper.xml"
    v.specializations[#v.specializations + 1] = BW
    v.specializationNames[#v.specializationNames + 1] = "baleWrapper"
    v.eventListeners.onPostLoad = { BW }
    v.eventListeners.onLoadFinished = { BW }
    v.spec_baleWrapper = {}
    return v
end

--- A world bale as the item system holds one: Bale.new, loadFromConfigXML (into the item system),
--- its type and level.
local function worldBale(ft, litres)
    local b = BaleModel.new(true, false)
    b:loadFromConfigXML("data/objects/bales/roundbale.xml", 0, 0, 0, 0, 0, 0)
    b:setFillType(ft)
    b:setFillLevel(litres)
    return b
end

--- A mission in the engine's order: the world built, Mission00.load, the kernel at
--- loadMission00Finished, then the vehicles each loaded where Mission00:loadVehicles' subtasks load them
--- (Mission00.lua:603-628, after loadMission00Finished returns): the post-load (Vehicle.lua:903-906)
--- then onLoadFinished (:1035), a Baler going into physics after; then the items (:654-657); then the
--- barrier. `load` gives each vehicle its savegame and the items file. opts: the Baler's, plus lay,
--- build(m, w), stayOutOfPhysics.
local function boot2b(opts, key, index, load)
    opts = opts or {}
    soil5dReset(opts.split)
    UNRESOLVED.all = false
    SEEN.sources = {}
    local m = newMission(key, { index = index })
    engine("g_server", { broadcastEvent = function() end })
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    Baler.initSpecialization()
    BW.initSpecialization()
    local w = {}
    soilOn(m) soil5dOn(m)
    for _, l in ipairs(opts.lay or { { GRASS, 100, "grass" } }) do lay(m, w, l[1], l[2], l[3], l[4]) end
    local bopts = {}
    for k, val in pairs(opts) do bopts[k] = val end
    bopts.notInPhysics = true
    w.baler = vehicleIn(m, newBaler("vehicle:baler", bopts))
    if opts.build ~= nil then opts.build(m, w) end
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    m.stockGuard.registerProperty(PROP, originSpec)
    Mission00.loadMission00Finished(m)
    for _, v in ipairs(m._vehicles) do
        if v.eventListeners.onLoadFinished ~= nil then
            local savegame = load ~= nil and load.savegame(v) or nil
            ENGINE_POST_LOAD_VEHICLE(v, savegame)
            ENGINE_RAISE(v, "onLoadFinished", savegame)
            if v.spec_baler ~= nil and not opts.stayOutOfPhysics then v.isAddedToPhysics = true end
        end
    end
    if load ~= nil and load.items ~= nil then m.itemSystem:loadItems(load.items) end
    m:onFinishedLoading()
    m.stockGuard.registerProperty(PID, AOWNER)
    for _, l in ipairs(opts.lay or { { GRASS, 100, "grass" } }) do ENGINE_TIP(w[l[3]], l[2]) end
    return m, sg, NH.current, w
end
--- The savegame controller's own save, the item system's save in the career chain
--- (FSCareerMissionInfo.lua:350, through the model's ENGINE_CAREER_HOOK).
local function save2b(m, dir)
    ENGINE_SAVE.finalDir = dir
    REAL.ENGINE_CAREER_HOOK = function(mi) m.itemSystem:save(mi.savegameDirectory .. "/items.xml") end
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    ENGINE_RUN_FRAMES(nil)
    REAL.ENGINE_CAREER_HOOK = nil
end
--- Save `m` to `dir`, quit it as the engine does (the host torn down by main.lua's prepend, then the
--- item system emptied, BaseMission.lua:144-145), and load a fresh mission from the save: the same
--- vehicles rebuilt and loaded from vehicles.xml, the items from items.xml. edit(file, keys) may change
--- vehicles.xml first. Returns the new mission, its StockGuard, host, world and the printed lines.
local function reload2b(m, w, dir, index, opts, edit)
    local keys = { baler = keyOf(m, w.baler), wrapper = w.wrapper ~= nil and keyOf(m, w.wrapper) or nil }
    save2b(m, dir)
    local file = vehiclesFile(dir)
    if edit ~= nil and file ~= nil then edit(file, keys) end
    FSBaseMission.delete(m)
    m.itemSystem:deleteAll()
    local xml = nil
    local load = {
        items = dir .. "/items.xml",
        savegame = function(v)
            if xml == nil then xml = REAL.XMLFile.load("vehiclesXML", dir .. "/vehicles.xml", REAL.Vehicle.xmlSchemaSavegame) end
            local key = (v.uniqueId == "vehicle:baler" and keys.baler) or (v.uniqueId == "vehicle:wrapper" and keys.wrapper) or nil
            return key ~= nil and { xmlFile = xml, key = key, resetVehicles = false } or nil
        end,
    }
    local o = { lay = {} }
    for k, val in pairs(opts or {}) do o[k] = val end
    local m2, sg2, host2, w2
    local lines = printed(function() m2, sg2, host2, w2 = boot2b(o, dir, index, load) end)
    return m2, sg2, host2, w2, lines, keys
end

-- ── readers ────────────────────────────────────────────────────────────────
local function baleId(bale) return cid(NA.baleBinding(bale)) end
local function baleStock(sg, bale) return stockAt(sg, baleId(bale)) end
local function lastFinish() return GO_.finishes[#GO_.finishes] end
--- A live finish: outcome / the leg's result[:reason] / source litres / destination litres.
local function finishText(f)
    if f == nil then return "none" end
    local a = f.report and f.report.allocations and f.report.allocations[1] or nil
    return tostring(f.outcome) .. "/" .. tostring(a and a.result) .. ((a and a.reason) and (":" .. a.reason) or "") .. "/" .. num(a and a.sourceAmount) .. "/" .. num(a and a.destinationAmount)
end
--- The objects in a Baler's bale list.
local function listed(v) local out = {} for _, b in ipairs(v.spec_baler.bales) do out[#out + 1] = b.baleObject end return out end
--- Did the tick's frames replay a negative report of the chamber (the clear, :1438)?
local function clearReplayed(host, v)
    for _, obs in ipairs(host.lastBalerTick and host.lastBalerTick.reports or {}) do
        if obs.vehicle == v and obs.fillUnitIndex == 1 and type(obs.accepted) == "number" and obs.accepted < 0 then return true end
    end
    return false
end
--- The count of bale carriers holding a stock.
local function baleStocks(sg)
    local n = 0
    for _, c in pairs(sg.operations.carriers) do if NA.isBaleKey(c.binding.carrierKey) and c.stockId ~= nil then n = n + 1 end end
    return n
end
--- A Baler finishes two square bales of 100 L: two ticks over 100 L each into a 100 L chamber.
local function twoBales(m, w)
    tick(w.baler)
    relay(m, w, GRASS, 100, "g2")
    tick(w.baler)
end
--- The reader of the chamber's record inside finishBale (Soil's #1077 reads it there), installed on
--- the slot as it is: under StockGuard's wrap when installed first, over it when installed after.
local function chamberReader(v, seen)
    local inner = v.finishBale
    v.finishBale = function(self, ...)
        seen[#seen + 1] = stockText(stockAt(StockGuard.hostOf(g_currentMission), unitId(self, 1)))
        return inner(self, ...)
    end
end
local ACC = "GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30"

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- SG-3 Part 2.2: the Mower and the Tedder (SG2-5bc-field_tool_model.lua:63-486, ported unchanged but for
-- the windrow types, which are this world's own GRASS and DRY), then the chain groups. Inside one more
-- function: 2b's locals with this part's would pass Lua's 200-local limit for a single function.
-- ════════════════════════════════════════════════════════════════════════════════════════════
local function CHAIN_BENCH()
-- ── The forage crop (a model extension, as the SG2-5c bench) ──────────────────────────────────
-- The model's WHEAT descriptor stands in for the meadow: harvestable at 3 (yield scale 0.5) and 4 (1).
FruitType.MEADOW = FruitType.WHEAT
do
    local d = g_fruitTypeManager:getFruitTypeByIndex(FruitType.WHEAT)
    d.regrows, d.firstRegrowthState = true, 3
end
-- WorkAreaType (WorkAreaTypeManager): the four types these two classes read, by value.
WorkAreaType = WorkAreaType or {}
WorkAreaType.DEFAULT = WorkAreaType.DEFAULT or 20
WorkAreaType.MOWER = WorkAreaType.MOWER or 21
WorkAreaType.AUXILIARY = WorkAreaType.AUXILIARY or 22
WorkAreaType.TEDDER = WorkAreaType.TEDDER or 23
-- A work area of a type neither class reads (a roller's, say), for a config whose drop binding names it.
WorkAreaType.OTHER = WorkAreaType.OTHER or 99

-- ── WorkArea (vehicles/specializations/WorkArea.lua), what these two read ─────────────────────
-- The workArea specialization's class: nothing of it saves a buffer. Its loadWorkAreaFromXML is
-- MODELED as far as the two overrides read it: the area's type from its config (DEFAULT when
-- unset). The index is the area's place in load order and the captured processing pointer is the
-- instance function the type names (WorkArea.lua:266), both set by ENGINE_LOAD_WORK_AREAS.
ENGINE_WORKAREA = {}
function ENGINE_WORKAREA.loadWorkAreaFromXML(_self, workArea, xmlFile, key)
    workArea.type = xmlFile:getValue(key .. "#type", WorkAreaType.DEFAULT)
    return true
end
--- A vehicle config's work areas, as a stand-in XML: one value per "<key>#<attr>".
local function configXml(values)
    return { getValue = function(_, k, d) local v = values[k] if v == nil then return d end return v end }
end
--- Load `defs` ({ type?, start, width, height, attrs }) through `class.loadWorkAreaFromXML` (an
--- overwritten function, so WorkArea's is its superFunc), in order, then capture each area's
--- processing pointer by the name its type gives (WorkArea.lua:266).
local function loadWorkAreas(v, class, defs, functionByType)
    local values = {}
    for i, def in ipairs(defs) do
        local key = string.format("vehicle.workAreas.workArea(%d)", i - 1)
        if def.type ~= nil then values[key .. "#type"] = def.type end
        for attr, value in pairs(def.attrs or {}) do values[key .. attr] = value end
    end
    local xml = configXml(values)
    v.spec_workArea = { workAreas = {} }
    for i, def in ipairs(defs) do
        local wa = { index = i, start = def.start, width = def.width, height = def.height }
        class.loadWorkAreaFromXML(v, ENGINE_WORKAREA.loadWorkAreaFromXML, wa, xml, string.format("vehicle.workAreas.workArea(%d)", i - 1))
        v.spec_workArea.workAreas[i] = wa
    end
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        wa.functionName = functionByType[wa.type]
        if wa.functionName ~= nil then wa.processingFunction = v[wa.functionName] end
    end
end
local function corners(x0, x1, z) return { x = x0, y = 0, z = z - 0.5 }, { x = x1, y = 0, z = z - 0.5 }, { x = x0, y = 0, z = z + 0.5 } end
local function baseVehicle(uid, configFileName)
    local v = { uniqueId = uid, configFileName = configFileName, ownerFarmId = 1, activeFarm = 1, isServer = true, currentUpdateDistance = 0, rootNode = { x = 0, z = 0 } }
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getTypedWorkAreas = function(self, t)
        local out = {}
        for _, wa in ipairs(self.spec_workArea.workAreas) do if wa.type == t then out[#out + 1] = wa end end
        return out
    end
    return v
end

-- ── The engine's Tedder (vehicles/specializations/Tedder.lua) ───────────────────────────────
Tedder = Tedder or {}
Tedder.CLIENT_DM_UPDATE_RADIUS = 50
--- :3-16 MODELED: it registers vehicle-xml paths only, no savegame path.
function Tedder.initSpecialization() end
--- :104-124 MODELED: the effects' work areas and the client's update listener; it reads no buffer.
function Tedder:onPostLoad(_) end
--- :238-254 VERBATIM.
function Tedder:loadWorkAreaFromXML(superFunc, workArea, xmlFile, key)
    local retValue = superFunc(self, workArea, xmlFile, key)
    if workArea.type == WorkAreaType.DEFAULT then
        workArea.type = WorkAreaType.TEDDER
    end
    if workArea.type == WorkAreaType.TEDDER then
        workArea.dropWindrowWorkAreaIndex = xmlFile:getValue(key .. ".tedder#dropWindrowWorkAreaIndex", 1)
        workArea.litersToDrop = 0
        workArea.lastPickupLiters = 0
        workArea.lastDropFillType = FillType.UNKNOWN
        workArea.lastDroppedLiters = 0
        workArea.tedderParticlesActive = false
        workArea.tedderParticlesActiveSent = false
        local spec = self.spec_tedder
        if spec.tedderWorkAreaFillTypes == nil then
            spec.tedderWorkAreaFillTypes = {}
        end
        table.insert(spec.tedderWorkAreaFillTypes, FruitType.UNKNOWN)
        workArea.tedderWorkAreaIndex = #spec.tedderWorkAreaFillTypes
    end
    return retValue
end
-- :360-362 VERBATIM.
function Tedder:onStartWorkAreaProcessing(_)
    self.spec_tedder.lastDroppedLiters = 0
end
-- :279-350 VERBATIM through the quantities (the SG2-5b bench's port): the effect, sound, dirty-flag
-- and stone lines out. The decompile prints `local targetFillType = workArea.lastDropFillType` at
-- :294, a shadow that would do nothing; SG-2 :199 names the zero-pickup lastDropFillType
-- substitution, so this port assigns it.
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

--- A tedder (vehicleTypes.xml `tedder`: baseGroundTool, turnOnVehicle, workMode, tedder; no fill
--- unit), its functions COPIED into the instance (Vehicle.lua:486), built through Tedder:onLoad
--- (:49-55, the converters as :47-65 and the SG2-5b bench build them, forward and reverse) and its
--- work areas through Tedder:loadWorkAreaFromXML. The pickup spans x -1..1 at z = opts.z (default
--- 30) and drops into its AUXILIARY drop area at x 8..10. opts.extraPickup adds a second TEDDER area
--- (a changed layout); opts.dropTo = 3 binds the pickup to a third area of another type (a changed
--- drop binding in the same layout); opts.configFileName another configuration.
function ENGINE_NEW_TEDDER(uid, opts)
    opts = opts or {}
    local z = opts.z or 30
    local v = baseVehicle(uid, opts.configFileName or "data/vehicles/tedder.xml")
    v.lastMovedDistance = 1
    v.processTedderArea, v.processDropArea = Tedder.processTedderArea, Tedder.processDropArea
    local forward, reverse = {}, {}
    for _, t in ipairs(opts.targets or { { DRY, { GRASS, DRY } } }) do
        reverse[t[1]] = {}
        for _, input in ipairs(t[2]) do
            forward[input] = { targetFillTypeIndex = t[1] }
            table.insert(reverse[t[1]], input)
        end
    end
    v.spec_tedder = { fillTypeConverters = forward, fillTypeConvertersReverse = reverse, lastDroppedLiters = 0 }
    local ps, pw, ph = corners(-1, 1, z)
    local ds, dw, dh = corners(8, 10, z)
    local defs = { { start = ps, width = pw, height = ph, attrs = { [".tedder#dropWindrowWorkAreaIndex"] = opts.dropTo or 2 } },
                   { type = WorkAreaType.AUXILIARY, start = ds, width = dw, height = dh } }
    if opts.dropTo ~= nil then
        local os_, ow, oh = corners(12, 14, z)
        defs[3] = { type = WorkAreaType.OTHER, start = os_, width = ow, height = oh }
    end
    if opts.extraPickup then
        local es, ew, eh = corners(-1, 1, z + 3)
        defs[3] = { start = es, width = ew, height = eh, attrs = { [".tedder#dropWindrowWorkAreaIndex"] = 2 } }
    end
    loadWorkAreas(v, Tedder, defs, { [WorkAreaType.TEDDER] = "processTedderArea" })
    v.specClasses = { Tedder }
    v.specializations = { ENGINE_WORKAREA, Tedder }
    v.specializationNames = { "workArea", "tedder" }
    v.eventListeners = { onPostLoad = { Tedder } }
    return v
end
--- WorkArea's tick for a Tedder (WorkArea.lua:124-200): the start event, then each TEDDER area's
--- captured pointer.
function ENGINE_TEDDER_TICK(v)
    Tedder.onStartWorkAreaProcessing(v, nil)
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        if wa.processingFunction ~= nil then wa.processingFunction(v, wa, 16) end
    end
end

-- ── The engine's Mower (vehicles/specializations/Mower.lua) ────────────────────────────────────
Mower = Mower or {}
Mower.CLIENT_DM_UPDATE_RADIUS = 50
--- The chord's two draws (math.random at :389 and :393, MODELED as fixed values).
ENGINE_MOWER = { draws = { 0.5, 0.5 } }
--- Mowable decorative foliage on 1 m fruit pixels ("px:pz" = true), for the meadow preparation.
ENGINE_DECO = {}
--- :3-39 MODELED: it registers vehicle-xml paths only, no savegame path.
function Mower.initSpecialization() end
--- :167-180 VERBATIM (the drop effects are the config's; the model has none).
function Mower:onPostLoad(_)
    local spec = self.spec_mower
    spec.workAreas = self:getTypedWorkAreas(WorkAreaType.MOWER)
    for i = 1, #spec.workAreas do
        local workArea = spec.workAreas[i]
        workArea.dropEffects = {}
        for _, dropEffect in pairs(spec.dropEffects) do
            if dropEffect.workAreaIndex == workArea.index then
                table.insert(workArea.dropEffects, dropEffect)
            end
        end
    end
end
--- :477-496 VERBATIM.
function Mower:loadWorkAreaFromXML(superFunc, workArea, xmlFile, key)
    local retValue = superFunc(self, workArea, xmlFile, key)
    if workArea.type == WorkAreaType.DEFAULT then
        workArea.type = WorkAreaType.MOWER
    end
    if workArea.type == WorkAreaType.MOWER then
        workArea.dropWindrow = xmlFile:getValue(key .. ".mower#dropWindrow", true)
        workArea.dropAreaIndex = xmlFile:getValue(key .. ".mower#dropAreaIndex", 1)
        workArea.lastPickupLiters = 0
        workArea.pickedUpLiters = 0
    end
    if workArea.type == WorkAreaType.AUXILIARY then
        workArea.litersToDrop = 0
        if self.spec_mower.dropAreas == nil then
            self.spec_mower.dropAreas = {}
        end
        table.insert(self.spec_mower.dropAreas, workArea)
    end
    return retValue
end
--- FSDensityMapUtil.lua:1886-1921 VERBATIM through the quantities (the SG2-5c bench's port). The
--- preparation's multi-modifier execute (:1916-1918) is C, MODELED: each fruit pixel whose centre
--- lies in the parallelogram and carries mowable decorative foliage takes the meadow at its first
--- regrowth state.
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
--- :328-382 VERBATIM through the quantities (the SG2-5c bench's port); the decompile's global
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
                if dropArea.fillType == FillType.GRASSINDROW then
                    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height, true)
                    local pickup
                    pickup, workArea.lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASSINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, workArea.lineOffset or 0, false, nil, false)
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
--- :383-405 VERBATIM through the quantities (the SG2-5c bench's port); the two draws are
--- ENGINE_MOWER's, and the decompile's reused name at :393-395 restored.
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
--- :406-424 VERBATIM, the decompile's fall-through after an invalid index (:413-416) restored as
--- an else (the SG2-5c bench's port).
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

--- A mower (vehicleTypes.xml `mower`: baseGroundTool, turnOnVehicle, fruitExtraObjects, mower,
--- workMode; no fill unit, so no spec_fillUnit), its functions COPIED into the instance
--- (Vehicle.lua:486), built through Mower:onLoad (abbreviated to the converters, the drop effects
--- and the work-area parameters) and its work areas through Mower:loadWorkAreaFromXML: the cut at
--- x -1..1, z -0.5..0.5 (two fruit pixels, the SG2-5c bench's), dropping into its AUXILIARY drop
--- area at x 20..22, the meadow converted to grass windrow at 200.37 L per scaled square metre.
--- opts.factor another conversion factor; opts.cutDropsTo = 3 binds the cut to a third area of another
--- type (a changed binding in the same layout); opts.extraDrop adds a second AUXILIARY area (a changed layout);
--- opts.configFileName another configuration.
function ENGINE_NEW_MOWER(uid, opts)
    opts = opts or {}
    local v = baseVehicle(uid, opts.configFileName or "data/vehicles/mower.xml")
    v.getLastSpeed = function() return 0 end
    v.getIsAIActive = function() return false end
    v.setTestAreaRequirements = function() end
    v.processMowerArea, v.processDropArea, v.getDropArea = Mower.processMowerArea, Mower.processDropArea, Mower.getDropArea
    -- The converter's factor is not a round number, so its litres are no float32 and the save's FLOAT
    -- rounding shows (the SG2-5c bench's 200, with .37 added).
    v.spec_mower = { fruitTypeConverters = opts.converters or { [FruitType.MEADOW] = { fillTypeIndex = GRASS, conversionFactor = opts.factor or 200.37 } },
        dropEffects = {}, isWorking = false, stoneLastState = 0, lastDropTime = 0,
        workAreaParameters = { lastInputGrowthState = 0, lastCutTime = 0, lastChangedArea = 0, lastStatsArea = 0, lastTotalArea = 0, lastUsedAreas = 0, lastUsedAreasSum = 0 } }
    local cs, cw, ch = corners(-1, 1, 0)
    local ds, dw, dh = corners(20, 22, 0)
    local defs = { { start = cs, width = cw, height = ch, attrs = { [".mower#dropAreaIndex"] = opts.cutDropsTo or 2 } },
                   { type = WorkAreaType.AUXILIARY, start = ds, width = dw, height = dh } }
    if opts.cutDropsTo ~= nil then
        local os_, ow, oh = corners(30, 32, 0)
        defs[3] = { type = WorkAreaType.OTHER, start = os_, width = ow, height = oh }
    end
    if opts.extraDrop then
        local es, ew, eh = corners(30, 32, 0)
        defs[3] = { type = WorkAreaType.AUXILIARY, start = es, width = ew, height = eh }
    end
    loadWorkAreas(v, Mower, defs, { [WorkAreaType.MOWER] = "processMowerArea" })
    v.specClasses = { Mower }
    v.specializations = { ENGINE_WORKAREA, Mower }
    v.specializationNames = { "workArea", "mower" }
    v.eventListeners = { onPostLoad = { Mower } }
    return v
end
--- WorkArea's tick for a Mower (WorkArea.lua:124-200): the start event, each MOWER area's
--- captured pointer, the end event (the drop loop).
function ENGINE_MOWER_TICK(v)
    Mower.onStartWorkAreaProcessing(v, nil)
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        if wa.processingFunction ~= nil then wa.processingFunction(v, wa, 16) end
    end
    Mower.onEndWorkAreaProcessing(v, 16, nil)
end

--- FSBaseMission:getHarvestScaleMultiplier MODELED at 1, as the SG2-5c bench (the factors it reads are 1 here).
function Mission:getHarvestScaleMultiplier() return 1 end

local QB = "qualityBasisV1"
local Q3 = SG3Quality

-- ── The meadow (a model extension; Bob's 2.2 build R-15) ──────────────────────────────────────
-- The shipped Mower converts GRASS and MEADOW to GRASS_WINDROW and WHEAT, BARLEY, OAT, CANOLA and
-- SOYBEAN to STRAW (maps_fruitTypes.xml:59-67). The engine model has WHEAT and BARLEY only, and the
-- field tool model stands the meadow in with WHEAT, a pair the shipped Mower never makes. So the meadow
-- is its own descriptor here, named MEADOW (SG-3's grass row, GRASS_QUALITY_V1), shaped as the brief
-- describes the shipped meadow (SG-3 :204, citing meadowEU/meadow.xml:43): greenMiddle (3) and
-- harvestReady (4) are the ordinary mowing states, both harvest-ready transitions at yield scales .5 and
-- 1, and harvestReady is flagged withered as well. GRASS_QUALITY_V1's precedence (:194) reads it
-- HARVEST_READY before the withered test; without it, it would be WITHERED. The other state names are
-- the model's. It regrows from 3, so the preparation (updateMowerArea) makes mowable decoration
-- greenMiddle meadow.
FruitType.MEADOW = 13
ENGINE_FRUIT_DESCS[FruitType.MEADOW] = setmetatable({ index = FruitType.MEADOW, name = "MEADOW",
    fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName("GRASS"), windrowFillTypeIndex = GRASS, literPerSqm = 1, windrowLiterPerSqm = 1, hasWindrow = true,
    minHarvestingGrowthState = 3, maxHarvestingGrowthState = 4, minForageGrowthState = 3, maxForageGrowthState = 4, cutState = 6,
    harvestTransitions = { [3] = 6, [4] = 6 }, yieldScales = { [3] = 0.5, [4] = 1 }, terrainDataPlaneId = 1,
    densityTypeIndex = 3, startStateChannel = 2, numStateChannels = 3,
    growthStateToName = { "sown", "greenSmall", "greenMiddle", "harvestReady", "withered", "cut" },
    harvestReadyTransitions = { [3] = 6, [4] = 6 }, cutStates = { [6] = true }, witheredState = 4, regrows = true, firstRegrowthState = 3 },
    getmetatable(ENGINE_FRUIT_DESCS[FruitType.WHEAT]))

-- ── Soil's values on the mission handle ───────────────────────────────────────────────────────
-- Shaped on SoilFertilityManager:getSoilValueAtWorld (a value and Soil's grain), published as
-- g_currentMission.soilFertilityManager (SoilFertilizer main.lua:761), the only route; added beside the
-- 5d surface soilOn publishes. Wheat's row is N 35/55, P 25/40, K 25/40: N 45 fits .5, P 40 fits 1,
-- K 25 fits 0, so npkFit 50; pH 6.5 is the optimum 100; agronomyFit = .75 x 50 + .25 x 100 = 62.5 (:180).
-- A harvest-ready cut earns .6 x 62.5 + .4 x 100 = 77.5 (:180-198); Feed's bands 80/60 make it a B.
-- The grass row is N 30/50, P 25/40, K 20/40: N 45 fits .75, P 40 fits 1, K 25 fits .25, so npkFit
-- 66.67 and agronomyFit 75; a harvest-ready (or greenMiddle) meadow cut earns .6 x 75 + .4 x 100 = 85,
-- Feed's A.
local SOILV = { nitrogen = 45, phosphorus = 40, potassium = 25, pH = 6.5 }
local function chainSoil(m) m.soilFertilityManager.getSoilValueAtWorld = function(_, key, x, z) return SOILV[key], 2 end end

--- Move a work area to x0..x1 at z, the field tool model's corners (its nodes are plain tables).
local function place(wa, x0, x1, z)
    wa.start.x, wa.width.x, wa.height.x = x0, x1, x0
    wa.start.z, wa.width.z, wa.height.z = z - 0.5, z - 0.5, z + 0.5
end

-- Straw on the ground is FillType STRAW in FS25 (BaleMission.lua:312 tests a windrow's type against
-- FillType.STRAW and DRYGRASS_WINDROW; the scripts name no STRAW_WINDROW). The ground model has no height
-- type for it, so it is added here exactly as the windrow types are (SG2-4b-ground_model.lua:341-348).
local STRAW_FT = g_fillTypeManager:getFillTypeIndexByName("STRAW")
do
    local hm = g_densityMapHeightManager
    if hm.fillTypeIndexToHeightType[STRAW_FT] == nil then
        local ht = { index = #hm.heightTypes + 1, fillTypeIndex = STRAW_FT, fillTypeName = "STRAW", maxSurfaceAngle = math.rad(45), fillToGroundScale = 1,
                     canBeTipped = true, allowsSmoothing = true, collisionBaseOffset = 0 }
        hm.heightTypes[ht.index] = ht
        hm.fillTypeIndexToHeightType[STRAW_FT] = ht
        hm.fillTypeNameToHeightType.STRAW = ht
    end
end

--- The chain's world on 2b's boot: the Mower (cut x -1..1, drop x 20..22, both at z 0) and, for hay, a
--- Tedder whose pickup lies on the Mower's drop and whose drop lies at x 40..42, where the Baler's pickup
--- is moved; for silage, the Baler's pickup on the Mower's drop and a bale wrapper. Every machine is in
--- the vehicle list before the barrier, so StockGuard's sweep brackets each one's captured pointer
--- (SGWorkAreaInstaller.install). The engine raises onPostLoad and onLoadFinished for every vehicle
--- (Vehicle.lua:903-906, :1035); 2b's boot raises them for a vehicle listing onLoadFinished, so the
--- Mower and the Tedder list it empty. Nothing pre-fills a record, a carrier or a stock.
local function chainBuild(kind)
    return function(m, w)
        chainSoil(m)
        -- "straw": the shipped Mower's WHEAT -> STRAW converter (maps_fruitTypes.xml:62; NATIVE_MOWER_STRAW_V1,
        -- SG-2 :185, SG-3 :320), the same factor as the meadow's.
        local mopts = kind == "straw" and { converters = { [FruitType.WHEAT] = { fillTypeIndex = STRAW_FT, conversionFactor = 200.37 } } } or nil
        w.mower = vehicleIn(m, ENGINE_NEW_MOWER("vehicle:mower", mopts))
        w.mower.eventListeners.onLoadFinished = {}
        if kind == "hay" then
            w.tedder = vehicleIn(m, ENGINE_NEW_TEDDER("vehicle:tedder", { z = 0 }))
            w.tedder.eventListeners.onLoadFinished = {}
            local tw = w.tedder.spec_workArea.workAreas
            place(tw[1], 20, 22, 0)
            place(tw[2], 40, 42, 0)
            place(w.baler.spec_workArea.workAreas[1], 40, 42, 0)
        elseif kind == "silage" then
            place(w.baler.spec_workArea.workAreas[1], 20, 22, 0)
            w.wrapper = vehicleIn(m, newWrapper("vehicle:wrapper"))
        end
    end
end
local function chainBoot(kind, key, index)
    return boot2b({ capacity = 100, lay = {}, build = chainBuild(kind) }, key, index)
end
--- The meadow (the model's WHEAT, FruitType.MEADOW) harvest-ready at 4 under the cut's two pixels.
local function sowMeadow(state) ENGINE_PLANE.sow(FruitType.MEADOW, -1, -1, 1, 1, state or 4) end

-- ── readers: everything through SG-1's own read, by a consumer of the bench's own (as 2.1's) ────
local readers = {}
local function reader(m)
    if readers[m] == nil then
        readers[m] = m.stockGuard.registerConsumer("bench.reader", { version = 1, requiredSchemas = { [QB] = 1, ["sg3.assessments"] = 1 },
            materialKinds = { "FILL_TYPE", "NATIVE_GROUP" }, resolveReadContext = function(q) return { stockRefs = q.stockRefs, purpose = "BENCH" } end })
    end
    return readers[m]
end
local function read(m, ref, pid)
    local res = m.stockGuard.readMaterial(reader(m), { stockRefs = { ref }, propertyIds = { pid } })
    local rec = res and res.records and res.records[1] or nil
    return rec and rec.properties and rec.properties[pid] or nil, rec
end
local function refOfStock(sg, s) return s ~= nil and sg.operations:stockRef(s) or nil end
local function mask(u)
    if type(u) ~= "table" then return "?" end
    return num(u.eligibleFraction) .. "/" .. num(u.ineligibleFraction) .. "/" .. num(u.unknownFraction) .. "[" .. table.concat(u.reasons or {}, " ") .. "]"
end
--- A quality record as "KNOWLEDGE known/basis eE rR crop/cal/material food <mask> feed <mask> [last X]",
--- or "UNAVAILABLE:<reason>" (2.1's fq).
local function fq(q)
    if type(q) ~= "table" then return "none" end
    if q.knowledge == "UNAVAILABLE" then return "UNAVAILABLE:" .. tostring(q.reason) end
    local pl = q.payload or {}
    local wt = pl.sourceWitness or {}
    local ou = wt.originUse or {}
    local mat = type(wt.nativeSourceMaterial) == "table" and wt.nativeSourceMaterial.fillTypeName or "-"
    local s = tostring(q.knowledge) .. " " .. num(q.knownAmount) .. "/" .. num(q.basisAmount) .. " e" .. num(pl.earnedScore) .. " r" .. num(pl.remainingScore)
        .. " " .. tostring(wt.cropKey or "-") .. "/" .. tostring(wt.calibrationKey or "-") .. "/" .. mat .. " food " .. mask(ou.FOOD) .. " feed " .. mask(ou.FEED)
    if type(wt.lastTransform) == "table" then s = s .. " last " .. tostring(wt.lastTransform.profileId) end
    return s
end
--- A Result as "STATE KNOWLEDGE SUITABILITY grade score [reasons]" with " h:<grade>/<score>" (2.1's fr).
local function fr(r)
    if type(r) ~= "table" then return "none" end
    local s = tostring(r.state) .. " " .. tostring(r.knowledge) .. " " .. tostring(r.suitability) .. " " .. tostring(r.grade or "-") .. " " .. num(r.remainingScore or "-")
        .. " [" .. table.concat(r.reasons or {}, " ") .. "]"
    if type(r.historical) == "table" then s = s .. " h:" .. tostring(r.historical.grade or "-") .. "/" .. num(r.historical.remainingScore) end
    return s
end
local function assess(m, ref)
    local a = read(m, ref, "sg3.assessments")
    local pl = a and a.payload or {}
    return fr(pl.food) .. " | " .. fr(pl.feed)
end
--- Every ground cell's record through the read, as "<fq> x<count>" in first-seen order, and the litres.
local function cellsText(m, sg)
    local kinds, order, litres = {}, {}, 0
    for _, s in ipairs(groundStocks(sg)) do
        litres = litres + (s.observedAmount or 0)
        local k = fq((read(m, refOfStock(sg, s), QB)))
        if kinds[k] == nil then kinds[k] = 0 order[#order + 1] = k end
        kinds[k] = kinds[k] + 1
    end
    local parts = {}
    for _, k in ipairs(order) do parts[#parts + 1] = k .. " x" .. kinds[k] end
    return table.concat(parts, "; "), litres, #groundStocks(sg)
end
local function first(lines, pattern) for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then return l end end return nil end
local function count(lines, pattern) local n = 0 for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then n = n + 1 end end return n end

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- SG-3 Part 3: Soil's ladder and provider (soil_fixture, VERBATIM), and the condition join's groups. Inside
-- one more function: the chain's locals with this part's would pass Lua's 200-local limit.
-- ════════════════════════════════════════════════════════════════════════════════════════════
local function PART3_BENCH()
local C3 = SG3Condition
local PROFILE = "SOIL_BALE_CONDITION_V1"
-- The engine's FSBaseMission:onStartMission (FSBaseMission.lua:365-377); the model has none. SG-3's
-- mission-start retry wraps it at install, so it is in place before any boot here.
FSBaseMission.onStartMission = FSBaseMission.onStartMission or function(mission) end

-- ── Soil's mission load (a new career), the order its own loadMission00Finished arms it in ───────────
local SOILW = {}
--- The store on the engine's value maps, the ladder on the store, the provider's methods on the manager Soil
--- publishes (SoilFertilizer main.lua:761), then the mission started (YardLadder:onMissionStarted).
local function soilArm(m)
    local md = MaterialDown.new()
    md:arm(SOIL_FIXTURE.valueMaps())
    md.newCareer = true   -- the bridge's beginLoad on a career never saved (SoilMaterialDownBridge)
    local yl = YardLadder.new()
    yl:arm(md, nil, nil)
    local mgr = m.soilFertilityManager
    mgr.soilSystem = { yardLadder = yl }
    for _, k in ipairs({ "getBaleConditionCapabilities", "registerBaleConditionListener", "unregisterBaleConditionListener",
                         "getBaleConditionPortions", "getConditionPortionsForNode" }) do
        mgr[k] = SoilFertilityManager[k]
    end
    yl:onMissionStarted()
    SOILW.yl, SOILW.md = yl, md
    return yl
end
-- The chamber's collected wetness at birth: 21%, one point over the fit line, so the ruled birth condition is
-- (21 - 20) x 6 = 6 (YardLadder.birthCondition) and r(6) = 0.94.
local WETNESS = 21
--- The chain's world (2.2's chainBuild) with Soil armed in it and its birth door on the Baler, unless
--- opts.lateSoil (Soil arms after StockGuard's install) or opts.noSoil.
local function part3Build(kind, opts)
    opts = opts or {}
    local base = chainBuild(kind)
    return function(m, w)
        base(m, w)
        if not opts.lateSoil and not opts.noSoil then
            local yl = soilArm(m)
            SOIL_FIXTURE.door(w.baler, yl, WETNESS)
        end
    end
end
local function part3Boot(kind, key, index, opts)
    return boot2b({ capacity = 100, lay = {}, build = part3Build(kind, opts) }, key, index)
end
--- A bench listener beside SG-3's: every after event Soil notifies, in order.
local function benchListener(m)
    local rec = { events = {} }
    m.soilFertilityManager:registerBaleConditionListener("bench", {
        beforeChange = function() return {} end,
        afterChange = function(ev) rec.events[#rec.events + 1] = ev end,
        invalidate = function() end })
    return rec
end
local function eventsText(rec, from)
    local out = {}
    for i = (from or 0) + 1, #rec.events do
        local e = rec.events[i]
        out[#out + 1] = tostring(e.kind) .. "=" .. tostring(e.operationId and "op" or "nil")
    end
    return table.concat(out, ",")
end
local function payloadOf(m, sg, bale) local q = read(m, refOfStock(sg, baleStock(sg, bale)), QB) return q and q.payload or {} end
--- The record's covered coordinates for its one stream, as "seq/rev C" (or "none").
local function coveredText(pl)
    local n, out = 0, "none"
    for _, c in pairs(pl.coveredConditionCoordinates or {}) do
        n = n + 1
        out = num(c.eventSequence) .. "/" .. num(c.portionRevision) .. " C" .. num(c.condition)
    end
    return n > 1 and ("x" .. n) or out
end
--- Soil's current portion for a bale, as "STATE seq/rev C".
local function soilText(uid)
    local r = SOILW.yl:getConditionPortions(uid)
    local p = r.portions and r.portions[1] or {}
    return tostring(r.state) .. " " .. num(p.eventSequence) .. "/" .. num(p.portionRevision) .. " C" .. num(p.condition)
end
local function day(n) SOILW.yl:onLadderPass({ monotonicDay = n, boundariesCrossed = 1 }) end
--- The hay chain to one square bale: mow the meadow, ted it, bale it.
local function hayBale(m, sg, w)
    sowMeadow(4)
    ENGINE_MOWER_TICK(w.mower)
    ENGINE_TEDDER_TICK(w.tedder)
    local lines = printed(function() tick(w.baler) end)
    return listed(w.baler)[1], lines
end

-- ══════════════════════════════════════════════════════════════════════════
-- J. THE ENTRY-POINT BAR: A SQUARE BALE JOINED TO SOIL'S BALE CONDITION
-- ══════════════════════════════════════════════════════════════════════════
group("J", function()
    resetWorld()
    soilReset()
    C3.joinLogged = false   -- a new launch
    local m, sg, host, w = part3Boot("hay", "c3j", 501)
    local member = SG3.current
    T.ok("J0 [reached] main.lua's load path installed SG-3 with SOIL_BALE_CONDITION_V1 registered and Soil's listener bound at install",
        member ~= nil and member.damageProfiles[PROFILE] ~= nil and member.listenerLease ~= nil and member.provider == m.soilFertilityManager)
    local rec = benchListener(m)
    local bale, lines = hayBale(m, sg, w)
    local uid = bale and bale:getUniqueId()
    local pl = payloadOf(m, sg, bale)
    T.eq("J1 [entry point] NAMED (SG-3 Part 3): the square finish's bale holds the pair with the birth handicap r(C1) from C0 = 0, once (85 x 0.94), its covered coordinates are Soil's portion, and its current Feed assessment grades",
        num(pl.earnedScore) .. " r" .. num(pl.remainingScore) .. " | " .. coveredText(pl) .. " | " .. soilText(uid) .. " | " .. assess(m, refOfStock(sg, baleStock(sg, bale))),
        "85 r79.9 | 1/1 C6 | READY 1/1 C6 | READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 79.9 []")
    T.eq("J2 Soil's BIRTH carried the finish's open operation, and nothing is open or queued after the finish (the stack empty, the read nil, no witness left)",
        eventsText(rec) .. " " .. #host.openOperations .. " " .. tostring(m.stockGuard.readOpenOperation()) .. " " .. tostring(next(member.witnesses)),
        "BIRTH=op 0 nil nil")
    T.eq("J3 the join's line, once per launch, names the birth condition and its retention",
        tostring(first(lines, "[StockGuard] SG-3: first square bale joined")),
        "[StockGuard] SG-3: first square bale joined to Soil's bale condition (condition 6.00, retention 0.9400). Logged once per launch.")
    -- A: the daily ladder (a dry day, +1): route 2, published under the stream's cause. A listener registered
    -- after SG-3's reads the bale's assessment in its own beforeChange: Soil calls every before, then the
    -- change, then every after (YardLadder:_notifyChange), so that read falls inside SG-3's in-flight window.
    local inFlightRead = nil
    m.soilFertilityManager:registerBaleConditionListener("benchInFlight", {
        beforeChange = function(ev)
            if ev.kind == "ADVANCE" and inFlightRead == nil then inFlightRead = assess(m, refOfStock(sg, baleStock(sg, bale))) end
            return {}
        end,
        afterChange = function() end, invalidate = function() end })
    day(101)
    T.eq("A0 while Soil's ADVANCE is in flight the bale's current assessment does not grade: CONDITION_PENDING",
        tostring(inFlightRead),
        "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_PENDING] h:-/79.9 | UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_PENDING] h:B/79.9")
    pl = payloadOf(m, sg, bale)
    T.eq("A1 a daily ADVANCE (C 6 to 7) applies r(7)/r(6) once through publishProperties: 79.9 x 0.93/0.94, the coverage at sequence 2, still graded",
        "r" .. num(pl.remainingScore) .. " | " .. coveredText(pl) .. " | " .. soilText(uid) .. " | " .. assess(m, refOfStock(sg, baleStock(sg, bale))),
        "r79.05 | 2/2 C7 | READY 2/2 C7 | READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 79.05 []")
    -- The same ADVANCE delivered again to SG-3's callbacks (Soil's event as it carried it).
    local adv = rec.events[#rec.events]
    local before = { kind = adv.kind, carrierEventSequence = adv.carrierEventSequence, nativeIds = adv.nativeIds, portionsBefore = adv.portionsBefore }
    local cb = C3.callbacks(member)
    -- Delivered through the listener's own pair (beforeChange, then afterChange), its route-2 status read off C.advance.
    local status
    local realAdvance = C3.advance
    C3.advance = function(...) status = realAdvance(...) return status end
    cb.afterChange(adv, cb.beforeChange(before))
    C3.advance = realAdvance
    T.eq("A2 a replay of that ADVANCE is ALREADY_APPLIED by SG-1's cause cursor: the score unchanged, the bale still current, nothing left in flight",
        tostring(status) .. " r" .. num(payloadOf(m, sg, bale).remainingScore) .. " " .. tostring(member.invalid[uid]) .. " " .. tostring(member.inFlight[uid]),
        "ALREADY_APPLIED r79.05 nil nil")
    -- R: the listener misses one ADVANCE, then the next closes it cumulatively.
    m.soilFertilityManager:unregisterBaleConditionListener(member.listenerLease)
    member.listenerLease = nil
    day(102)   -- C 7 to 8, unseen
    C3.bind(member)
    T.ok("R0 (bound again, the record is behind Soil's portion: CONDITION_GAP until the next ADVANCE)",
        assess(m, refOfStock(sg, baleStock(sg, bale))):find("CONDITION_GAP", 1, true) ~= nil)
    day(103)   -- C 8 to 9: the covered 7 at sequence 2, Soil before at 3/3: deltas 1 and 1
    pl = payloadOf(m, sg, bale)
    T.eq("R1 the next ADVANCE closes the missed one cumulatively under the delta rule: r(9)/r(7) once from the covered condition, the coverage at sequence 4",
        "r" .. num(pl.remainingScore) .. " | " .. coveredText(pl) .. " | " .. assess(m, refOfStock(sg, baleStock(sg, bale))),
        "r" .. num(79.05 * 0.91 / 0.93) .. " | 4/4 C9 | READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B " .. num(79.05 * 0.91 / 0.93) .. " []")
    -- A missed stretch whose revision moved more than its sequence (what a storage REBIND does, which this
    -- world's bale has no storage for) is delivered to SG-3's callbacks: the covered 4/4, Soil before at 5/6,
    -- the deltas 1 and 2 differ, so it is not guessed.
    local fake = { kind = "ADVANCE", carrierEventSequence = 99, nativeIds = { uid }, result = "APPLIED",
                   portionsBefore = { SGValues.copy(rec.events[#rec.events].portionsAfter[1]) },
                   portionsAfter = { SGValues.copy(rec.events[#rec.events].portionsAfter[1]) } }
    fake.portionsBefore[1].eventSequence = fake.portionsBefore[1].eventSequence + 1
    fake.portionsBefore[1].portionRevision = fake.portionsBefore[1].portionRevision + 2
    fake.portionsBefore[1].condition = fake.portionsBefore[1].condition + 1
    fake.portionsAfter[1].eventSequence = fake.portionsAfter[1].eventSequence + 2
    fake.portionsAfter[1].portionRevision = fake.portionsAfter[1].portionRevision + 3
    fake.portionsAfter[1].condition = fake.portionsAfter[1].condition + 2
    local t2 = cb.beforeChange({ kind = "ADVANCE", carrierEventSequence = 99, nativeIds = { uid }, portionsBefore = fake.portionsBefore })
    cb.afterChange(fake, t2)
    T.eq("R2 a lag whose sequence and revision deltas differ is not recovered: unavailable (CONDITION_GAP), the score untouched",
        tostring(member.invalid[uid]) .. " r" .. num(payloadOf(m, sg, bale).remainingScore), "CONDITION_GAP r" .. num(79.05 * 0.91 / 0.93))
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE OPEN OPERATION: ONLY THE FINISH'S, ONLY WHILE ITS ORIGINAL RUNS
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("hay", "c3o", 502)
    local member = SG3.current
    local rec = benchListener(m)
    -- The finish's settle (SGGroundObserver.finishClose, called after the original returns) reads the
    -- operation the way Soil would, through the handle.
    local readInSettle = "not called"
    local realClose = SGGroundObserver.finishClose
    SGGroundObserver.finishClose = function(h, o) readInSettle = tostring(m.stockGuard.readOpenOperation()) return realClose(h, o) end
    local bale, joinLines = hayBale(m, sg, w)
    SGGroundObserver.finishClose = realClose
    T.eq("O0 the launch's next joined bale logs no second join line, and nothing reads the finish's operation during its settle",
        count(joinLines, "first square bale joined") .. " " .. readInSettle .. " " .. coveredText(payloadOf(m, sg, bale)), "0 nil 1/1 C6")
    local mark = #rec.events
    -- The bale leaves: StockGuard's delete bracket settles before the original (SGNativeHost:onBaleDeleted), then
    -- Soil's door retires its row.
    bale:delete()
    SOILW.yl:onBaleRemoved(bale.nodeId, bale)
    T.eq("O1 a RETIRE outside any bracket carries no operation, and SG-3 keeps nothing for the bale", eventsText(rec, mark) .. " " .. tostring(member.invalid[bale:getUniqueId()]),
        "RETIRE=nil nil")
    local viaColon = { m.stockGuard:readOpenOperation() }
    T.eq("O2 the read is a dot call: a colon call refuses", tostring(viaColon[1]) .. "/" .. tostring(viaColon[2]), "nil/CALLED_WITH_COLON")
    -- A finish whose original throws: the stack is emptied on the way out.
    host:pushOpenOperation("op:bench")
    local seen = m.stockGuard.readOpenOperation()
    host:popOpenOperation("op:bench")
    T.eq("O3 (an id on the stack that SG-1 does not hold open reads nil)", tostring(seen), "nil")
    local okThrow = pcall(function()
        w.baler.createBale = function() error("bench: createBale threw", 0) end
        sowMeadow(4)
        ENGINE_MOWER_TICK(w.mower)
        ENGINE_TEDDER_TICK(w.tedder)
        tick(w.baler)
    end)
    T.eq("O4 a throw inside the finish's original leaves the stack empty and the next read nil", #host.openOperations .. " " .. tostring(m.stockGuard.readOpenOperation()), "0 nil")
    -- An operation id the read did not come from an open bracket: Soil echoes what the read says.
    local realRead = m.stockGuard.readOpenOperation
    m.stockGuard.readOpenOperation = function() return { operationId = "op:9:9" } end
    local queued = 0
    for _ in pairs(member.witnesses) do queued = queued + 1 end
    local b2 = Bale.new(true, false)
    b2:loadFromConfigXML("bale.xml", 0, 0, 0, 0, 0, 0, "stray1")
    b2:setFillType(g_fillTypeManager:getFillTypeIndexByName("DRYGRASS_WINDROW"))
    b2:setFillLevel(100)
    SOILW.yl:onBaleCreated(b2.nodeId, b2, "DRYGRASS_WINDROW", 100, 1, 100, nil)
    m.stockGuard.readOpenOperation = realRead
    local after = 0
    for _ in pairs(member.witnesses) do after = after + 1 end
    T.eq("O5 an afterChange naming an operation that is not open queues nothing and invalidates its bale", (after - queued) .. " " .. tostring(member.invalid.stray1),
        "0 OPERATION_NOT_OPEN")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. A CROSSED EPOCH, AND A LISTENER THAT THROWS
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("hay", "c3e", 503)
    local member = SG3.current
    local bale = hayBale(m, sg, w)
    local uid = bale:getUniqueId()
    -- A store whose epoch is not the one the record covered (Soil's sourceEpoch is per store, MaterialDown).
    SOILW.md.baleConditionMeta.sourceEpoch = "sfse_other"
    day(101)
    T.eq("E1 an ADVANCE on another epoch is unavailable: CONDITION_GAP, the score untouched",
        tostring(member.invalid[uid]) .. " r" .. num(payloadOf(m, sg, bale).remainingScore) .. " | " .. assess(m, refOfStock(sg, baleStock(sg, bale))),
        "CONDITION_GAP r79.9 | UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_GAP] h:-/79.9 | UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_GAP] h:B/79.9")
    FSBaseMission.delete(m)

    resetWorld()
    soilReset()
    m, sg, host, w = part3Boot("hay", "c3e2", 504)
    member = SG3.current
    bale = hayBale(m, sg, w)
    uid = bale:getUniqueId()
    local realRead = SG3Assessments.read
    SG3Assessments.read = function() error("bench: SG-3's read threw", 0) end
    local okDay = pcall(day, 101)
    SG3Assessments.read = realRead
    T.eq("E2 a throw inside SG-3's after never blocks Soil: the ADVANCE is done, and Soil's invalidate marks the bale unavailable",
        tostring(okDay) .. " " .. soilText(uid) .. " " .. tostring(member.invalid[uid]), "true READY 2/2 C7 LISTENER_AFTER_FAILED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE BIND ORDER, AND NO PROVIDER
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("hay", "c3b", 505, { lateSoil = true })
    local member = SG3.current
    local boundAtInstall = member.listenerLease ~= nil
    local yl = soilArm(m)   -- Soil's mission load after StockGuard's install
    SOIL_FIXTURE.door(w.baler, yl, WETNESS)
    local lines = printed(function() FSBaseMission.onStartMission(m) end)
    T.eq("B1 the provider arms after StockGuard's install: the install's bind refuses, the mission-start retry binds, and logs nothing",
        tostring(boundAtInstall) .. " " .. tostring(member.listenerLease ~= nil) .. " " .. #lines, "false true 0")
    local bale = hayBale(m, sg, w)
    T.eq("B2 and the next square bale joins", coveredText(payloadOf(m, sg, bale)), "1/1 C6")
    FSBaseMission.delete(m)

    resetWorld()
    soilReset()
    m, sg, host, w = part3Boot("hay", "c3b2", 506, { noSoil = true })
    member = SG3.current
    lines = printed(function() FSBaseMission.onStartMission(m) end)
    local again = printed(function() FSBaseMission.onStartMission(m) end)
    bale = hayBale(m, sg, w)
    T.eq("B3 a provider that never arms: the retry refuses, logs once (never twice), and the square bale reads CONDITION_UNAVAILABLE with its recorded letter",
        tostring(first(lines, "[StockGuard] SG-3: Soil's bale condition provider is not available")) .. " | " .. #again .. " | "
        .. assess(m, refOfStock(sg, baleStock(sg, bale))),
        "[StockGuard] SG-3: Soil's bale condition provider is not available (NO_PROVIDER); square bales read CONDITION_UNAVAILABLE | 0 | "
        .. "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_UNAVAILABLE] h:-/85 | UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_UNAVAILABLE] h:A/85")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. SILAGE: THE FERMENTATION KEEPS THE COVERAGE
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("silage", "c3f", 507)
    sowMeadow(4)
    ENGINE_MOWER_TICK(w.mower)
    tick(w.baler)
    local bale = listed(w.baler)[1]
    BW.grab(w.wrapper, bale)
    BW.wrap(w.wrapper, 1)
    bale:onFermentationEnd()
    local s = baleStock(sg, bale)
    local pl = payloadOf(m, sg, bale)
    T.eq("F1 a wrapped grass bale's fermentation (NATIVE_BALE_FEED_V1, the bale onto itself) keeps its pair and its covered coordinates, so the silage bale still grades",
        tostring(s and s.materialRef and s.materialRef.fillTypeName) .. " r" .. num(pl.remainingScore) .. " | " .. coveredText(pl) .. " | " .. assess(m, refOfStock(sg, s)),
        "SILAGE r79.9 | 1/1 C6 | READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 79.9 []")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. A SAVE AND A RELOAD: NO RE-BIRTH
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("hay", "c3s", 508)
    local bale = hayBale(m, sg, w)
    day(101)
    local s = baleStock(sg, bale)
    local before = SGValues.copy(s.properties[QB])
    local causes = 0
    for _ in pairs(s.acceptedCauses or {}) do causes = causes + 1 end
    local m2, sg2, host2, w2 = reload2b(m, w, "c3s", 509, { capacity = 100, lay = {}, build = part3Build("hay", { noSoil = true }) })
    local s2 = baleStock(sg2, listed(w2.baler)[1])
    local kept = 0
    for k, acc in pairs(s2 and s2.acceptedCauses or {}) do if s.acceptedCauses[k] ~= nil and acc.sequence == s.acceptedCauses[k].sequence then kept = kept + 1 end end
    T.eq("S1 a save and a reload keep the bale's record exactly (the handicap and the day applied once, never again) and its accepted cause",
        tostring(s2 ~= nil and SGValues.equal(s2.properties[QB], before)) .. " r" .. num(s2 and s2.properties[QB].payload.remainingScore) .. " " .. causes .. "/" .. kept,
        "true r79.05 1/1")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. TWO BIRTHS UNDER ONE FINISH: ONLY THE FINISH'S OWN BALE IS APPLIED
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("hay", "c3w", 511)
    -- Inside the finish's original, before its own createBale, Soil births another bale (23% wet: C 18), so the
    -- finish's queue holds that BIRTH first and its own bale's second.
    local inner = w.baler.createBale
    w.baler.createBale = function(self, ...)
        local stray = Bale.new(true, false)
        stray:loadFromConfigXML("bale.xml", 0, 0, 0, 0, 0, 0, "stray2")
        stray:setFillType(g_fillTypeManager:getFillTypeIndexByName("DRYGRASS_WINDROW"))
        stray:setFillLevel(100)
        SOILW.yl:onBaleCreated(stray.nodeId, stray, "DRYGRASS_WINDROW", 100, 1, 100, { collected = true, wetnessPct = 23 })
        return inner(self, ...)
    end
    local bale = hayBale(m, sg, w)
    local pl = payloadOf(m, sg, bale)
    T.eq("W1 a BIRTH of another bale under the same finish is not applied: the finish's bale takes its own birth condition (85 x 0.94)",
        "r" .. num(pl.remainingScore) .. " | " .. coveredText(pl) .. " | " .. soilText("stray2"), "r79.9 | 1/1 C6 | READY 1/1 C18")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE JOIN'S OWN GUARDS, ON THE MEMBER A REAL BOOT INSTALLED
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = part3Boot("hay", "c3u", 510)
    local member = SG3.current
    local bale = hayBale(m, sg, w)
    local uid = bale:getUniqueId()
    local cb = C3.callbacks(member)
    local function r4(x) return x == nil and "nil" or string.format("%.4f", x) end
    T.eq("U1 r(C1)/r(C0): the birth from 0, a day, a bale at or past 100 keeps zero, a fall is refused",
        r4(C3.ratio(0, 6)) .. " " .. r4(C3.ratio(6, 7)) .. " " .. r4(C3.ratio(100, 120)) .. " " .. r4(C3.ratio(7, 6)), "0.9400 0.9894 0.0000 nil")
    local dup = { C3.registerDamageProfile(member, C3.OWNER_ID, PROFILE, C3.PROFILE_VERSION, C3.definition()) }
    -- A client: no g_server in the mod's environment or in the engine's table under it, each restored exactly.
    local envServer, engineServer = rawget(_G, "g_server"), REAL.g_server
    rawset(_G, "g_server", nil)
    REAL.g_server = nil
    local client = { C3.registerDamageProfile({ damageProfiles = {} }, C3.OWNER_ID, "OTHER_V1", 1, C3.definition()) }
    REAL.g_server = engineServer
    rawset(_G, "g_server", envServer)
    T.eq("U2 the profile registers once, and on the server only",
        tostring(dup[1]) .. "/" .. tostring(dup[2]) .. " " .. tostring(client[1]) .. "/" .. tostring(client[2]), "nil/DUPLICATE_PROFILE nil/NOT_SERVER")
    local t1 = cb.beforeChange({ kind = "ADVANCE", carrierEventSequence = 40, nativeIds = { "pair1" } })
    cb.afterChange({ kind = "ADVANCE", carrierEventSequence = 41, nativeIds = { "pair1" }, result = "APPLIED" }, t1)
    local t2 = cb.beforeChange({ kind = "ADVANCE", carrierEventSequence = 42, nativeIds = { "result1" } })
    cb.afterChange({ kind = "ADVANCE", carrierEventSequence = 42, nativeIds = { "result1" }, result = "REFUSED" }, t2)
    for i, kind in ipairs({ "REBIND", "RESET", "BIRTH" }) do
        local ev = { kind = kind, carrierEventSequence = 42 + i, nativeIds = { kind:lower() .. "1" }, result = "APPLIED" }
        cb.afterChange(ev, cb.beforeChange(ev))
    end
    T.eq("U3 an after paired with another event's before, reporting a result other than APPLIED, or a REBIND, RESET or BIRTH no operation joined, is not guessed",
        tostring(member.invalid.pair1) .. " " .. tostring(member.invalid.result1) .. " " .. tostring(member.invalid.rebind1) .. " " .. tostring(member.invalid.reset1)
        .. " " .. tostring(member.invalid.birth1),
        "PAIR_MISMATCH RESULT_REFUSED REBIND_UNJOINED RESET_UNSUPPORTED BIRTH_UNJOINED")
    -- An operation id SG-1 holds open, set by hand for this guard alone and removed straight after.
    sg.operations.openHandles["op:u4"] = {}
    local heldOnly = C3.isOpen("op:u4")
    host:pushOpenOperation("op:u4")
    local both = C3.isOpen("op:u4")
    sg.operations.openHandles["op:u4"] = nil
    local stackOnly = C3.isOpen("op:u4")
    host:popOpenOperation("op:u4")
    T.eq("U4 an operation is open to the join only while it is both on the native bracket stack and held open by SG-1",
        tostring(heldOnly) .. " " .. tostring(both) .. " " .. tostring(stackOnly), "false true false")
    local function vc(extra, accepted)
        local c = { ownerId = C3.OWNER_ID, profileId = PROFILE, profileVersion = C3.PROFILE_VERSION }
        for k, v in pairs(extra) do c[k] = v end
        local ok, why = C3.validateCause(c, accepted, nil)
        return tostring(ok) .. "/" .. tostring(why)
    end
    T.eq("U5 a stamp is accepted only as this profile's, continuing the covered sequence by one or closing it cumulatively from the accepted base",
        vc({ sequence = 3 }, { sequence = 2 }) .. " " .. vc({ sequence = 3, profileId = "OTHER_V1" }, { sequence = 2 }) .. " "
        .. vc({ sequence = 4 }, { sequence = 2 }) .. " " .. vc({ sequence = 4, cumulative = true, coveredSequence = 2 }, { sequence = 2 }) .. " "
        .. vc({ sequence = 4, cumulative = true, coveredSequence = 1 }, { sequence = 2 }) .. " " .. vc({ sequence = 3 }, nil),
        "true/nil nil/PROFILE nil/SEQUENCE_GAP true/nil nil/SEQUENCE_GAP nil/UNCOVERED")
    -- Route 2's refusals on the real bale: an ADVANCE one day on from Soil's current portion, delivered to the
    -- listener's own pair with one thing wrong; each refusal read, then cleared for the next case.
    local function refused(seq, spoilTicket, spoilEvent)
        local cur = SOILW.yl:getConditionPortions(uid).portions[1]
        local ev = { kind = "ADVANCE", carrierEventSequence = seq, nativeIds = { uid }, result = "APPLIED",
                     portionsBefore = { SGValues.copy(cur) }, portionsAfter = { SGValues.copy(cur) } }
        local a = ev.portionsAfter[1]
        a.eventSequence, a.portionRevision, a.condition = a.eventSequence + 1, a.portionRevision + 1, a.condition + 1
        local ticket = cb.beforeChange({ kind = "ADVANCE", carrierEventSequence = seq, nativeIds = { uid }, portionsBefore = ev.portionsBefore })
        if spoilTicket ~= nil then spoilTicket(ticket) end
        if spoilEvent ~= nil then spoilEvent(ev) end
        pcall(cb.afterChange, ev, ticket)
        local why = member.invalid[uid]
        member.invalid[uid] = nil
        return tostring(why)
    end
    local refusals = refused(50, nil, function(ev)
            ev.portionsBefore[2] = SGValues.copy(ev.portionsBefore[1])
            ev.portionsAfter[2] = SGValues.copy(ev.portionsAfter[1])
        end)
        .. " " .. refused(51, function(t) t.stockRef = nil end)
        .. " " .. refused(52, function(t) t.stockRef = SGValues.copy(t.stockRef) t.stockRef.contentsGeneration = t.stockRef.contentsGeneration + 1 end)
        .. " " .. refused(53, nil, function(ev) ev.portionsAfter[1].conditionGeneration = ev.portionsAfter[1].conditionGeneration + 1 end)
        .. " " .. refused(54, nil, function(ev)
            ev.portionsBefore[1].conditionGeneration = ev.portionsBefore[1].conditionGeneration + 1
            ev.portionsAfter[1].conditionGeneration = ev.portionsAfter[1].conditionGeneration + 1
        end)
    T.eq("U6 an ADVANCE with no operation is not guessed when portioned, without its before, onto another binding, across a branch, or on a generation the record never covered; the score is untouched",
        refusals .. " r" .. num(payloadOf(m, sg, bale).remainingScore), "PORTIONED BEFORE_MISSING BINDING_CHANGED BRANCH_CHANGED CONDITION_GAP r79.9")
    -- Soil's invalidate (an after that threw): the bale is marked though its coverage still matches Soil's portion.
    cb.invalidate(uid, "LISTENER_AFTER_FAILED")
    T.eq("U7 a bale Soil invalidated reads CONDITION_GAP even while its coverage matches Soil's portion",
        assess(m, refOfStock(sg, baleStock(sg, bale))),
        "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_GAP] h:-/79.9 | UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_GAP] h:B/79.9")
    day(101)
    T.eq("U8 the next ADVANCE that proves its coverage again clears the mark: graded at the day's ratio",
        tostring(member.invalid[uid]) .. " | " .. assess(m, refOfStock(sg, baleStock(sg, bale))),
        "nil | READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 79.05 []")
    -- Soil's answer in its other states (a stand-in provider for this guard alone, then the real one again).
    local q = read(m, refOfStock(sg, baleStock(sg, bale)), QB)
    local realProvider = member.provider
    local function stateOf(answer)
        member.provider = { getBaleConditionPortions = function() return answer end }
        local _, why = C3.currentFor(member, uid, q)
        return tostring(why)
    end
    local live = SOILW.yl:getConditionPortions(uid)
    local condemned = SGValues.copy(live)
    condemned.portions[1].condemned = true
    local two = SGValues.copy(live)
    two.portions[2] = SGValues.copy(live.portions[1])
    local states = stateOf({ state = "RESTORING", portions = {} }) .. " " .. stateOf(condemned) .. " " .. stateOf(two) .. " "
        .. stateOf({ state = "UNAVAILABLE", reason = "NO_ROW", portions = {} })
    member.provider = realProvider
    T.eq("U9 Soil's answer bounds the assessment: restoring is pending; a condemned portion, a portioned bale and an unavailable one do not grade",
        states, "CONDITION_PENDING CONDITION_CONDEMNED CONDITION_UNAVAILABLE CONDITION_UNAVAILABLE")
    local realCaps = m.soilFertilityManager.getBaleConditionCapabilities
    m.soilFertilityManager.getBaleConditionCapabilities = function(self)
        local caps = realCaps(self)
        caps.version = caps.version + 1
        return caps
    end
    local fresh = { damageProfiles = {}, witnesses = {}, invalid = {}, inFlight = {} }
    local bound = { C3.bind(fresh) }
    m.soilFertilityManager.getBaleConditionCapabilities = realCaps
    T.eq("U10 a provider of another schema version is not bound", tostring(bound[1]) .. "/" .. tostring(bound[2]) .. " " .. tostring(fresh.listenerLease), "false/SCHEMA nil")
    -- The bale's own record as two sources (what a mixer would make of two bales; SG-4 builds that) and as one.
    local E3 = SG3Evaluator
    local two = E3.combine({ E3.recordEntry(q, 50), E3.recordEntry(q, 50) }, 100, nil)
    local one = E3.combine({ E3.recordEntry(q, 100) }, 100, nil)
    T.eq("U12 one source carries its covered coordinates into a combine; several cannot be one UNIFORM coverage, so theirs is dropped",
        coveredText(two.payload) .. " " .. coveredText(one.payload), "none 2/2 C7")
    local yl = SOILW.yl
    FSBaseMission.delete(m)
    local left = 0
    for _, l in ipairs(yl._listeners) do if l.id == C3.LISTENER_ID then left = left + 1 end end
    T.eq("U11 the mission's end unbinds SG-3's listener from Soil", tostring(left), "0")
end)
end
PART3_BENCH()
end
CHAIN_BENCH()
end
SG2B_BENCH()
end
