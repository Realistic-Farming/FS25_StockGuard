-- SG2-5c-mower_frame_spec_test.lua
--
-- SG2-5 slice 5c (Bob's Mower shape ruling, BOB-RULING-SG2-5C-MOWER-SHAPE-2026-10-02, on Soil #1082):
-- a Mower work area's one processMowerArea call runs inside a MOWER ground frame whose unit is its
-- drop area's PERSISTENT mowerBuffer carrier (SGNativeAdapters): litersToDrop exactly, as the area's
-- fillType. One operation per fruit converter: the cut's litres (lastPickupLiters) born from its
-- MOWER_STATE_VOLUME_V1 witness slots (SGCutState, the target the frame names) and its dry-grass
-- pickup's cells, captured together and settled after native's 1000 L cap, which is a LOSS from the
-- uniform mixture. The frame admits a MOWER_CUT with Soil before the call and closes it after; its
-- buffer keeps the fresh litres still waiting for Soil's birth at the deposit and names them in each
-- settle (pendingFresh). Each processDropArea call runs inside a MOWER_DROP frame, and its delivery
-- splits the drop into a birth and the stock's record. A changed type makes the remainder unknown;
-- the fill-unit branch is a birth into the unit with no Soil; a vehicle's live remainder goes as
-- destruction.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world, with SG2-4c-1's recorder of
-- Soil's published surface and a stand-in `soil.groundCondition` owner whose combine leaves the named
-- pending fresh litres out, as Soil #1082's does (the preamble of the SG2-5b bench, verbatim, with a
-- per-kind refusal added to the recorder).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path; the native host observes a Mower of the
-- engine's OWN type (vehicleTypes.xml `mower`: baseGroundTool's specializations and mower, no
-- fillUnit, so no spec_fillUnit) at the barrier; SGWorkAreaInstaller brackets the work area's
-- CAPTURED pointer (WorkArea.lua:266) and the drop slot is wrapped; the engine's own order then runs
-- it: onStartWorkAreaProcessing (Mower.lua:541-561), the captured pointer (processMowerArea :328-382,
-- updateMowerArea FSDensityMapUtil.lua:1886-1921) and onEndWorkAreaProcessing (the drop loop
-- :562-566, processDropArea :383-405), over a forage crop the plane holds and a dry windrow a tipper
-- laid. Group P runs the same pass on a self-propelled mower (vehicleTypes.xml selfPropelledMower,
-- which carries a fill unit). The two-sided bar against Soil's own mower carrier is the joined run
-- outside the repo (the PR body names it).
--
-- Groups:
--   E  the entry-point bar, on the engine's own Mower type
--   P  the same pass on a self-propelled Mower: Soil's calls in order, the one operation, the buffer's
--      record, the drop's birth and record, the withdrawn buffer
--   C  the cap: a LOSS from the uniform mixture, the remainder, the birth and the pickup alike
--   H  a remainder held across calls keeps its fresh litres to the drop
--   R  a changed type: the remainder unknown, only the new birth fresh
--   W  the witness: MOWER_STATE_VOLUME_V1 portions, a refused reading, prepared foliage
--   K  Soil: a refused MOWER_CUT, Soil absent, a client
--   U  the fill-unit branch: a birth into the unit, no Soil
--   O  the drop slot wrapped over or under a foreign wrapper
--   D  destruction, and the mission's end
--   N  the kind: native-backed, never restored, never enumerated
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
-- E. THE ENTRY-POINT BAR: THE ENGINE'S OWN MOWER TYPE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local r = pass("mower", "w5c_e", 101)
    T.eq("E0 [reached] on a Mower of the engine's own type (no spec_fillUnit), the native host bracketed the work area's CAPTURED pointer and wrapped its processDropArea slot",
        r.installed, "true/true")
    T.eq("E1 [world] native cut 400 L, took the dry windrow in and dropped it all; the pointer's returns are the engine's", r.native, EXPECT.native)
    T.eq("E2 [entry point] Soil was asked, in order: the MOWER_CUT before the call, the dry pickup's line, the cut's close after the call, then the drop's line",
        r.fns .. "|" .. r.kinds, EXPECT.fns .. "|" .. EXPECT.kinds)
    T.eq("E3 [entry point] the MOWER_CUT names the work area's own corners, the mower and the work area table native passes", r.cutAdmit, EXPECT.cutAdmit)
    T.eq("E4 [entry point] one operation for the converter (cut and pickup), then the drop, both COMMITTED", r.ops, EXPECT.ops)
    T.eq("E5 [entry point] the drop's delivery: the fresh 400 L as a MOWER birth, the old dry 200 L with the buffer's record (KNOWN 7)", r.drops, EXPECT.drops)
    T.ok("E6 [entry point] the first admitted MOWER_STATE_VOLUME_V1 cut says so once in the log", r.logged)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE SAME PASS ON A SELF-PROPELLED MOWER
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local r = pass("selfPropelled", "w5c_p", 102)
    T.eq("P0 [reached] the bracket and the drop slot", r.installed, "true/true")
    T.eq("P1 [world] native cut 400 L, took the dry windrow in and dropped it all; the returns are the engine's", r.native, EXPECT.native)
    T.eq("P2 NAMED: Soil was asked, in order: MOWER_CUT before the call, the pickup line, the cut's close after the call, then the drop line",
        r.fns .. "|" .. r.kinds, EXPECT.fns .. "|" .. EXPECT.kinds)
    T.eq("P3 NAMED: the MOWER_CUT's footprint is the work area's start, width and height corners; its owner and identity the mower and its work area", r.cutAdmit, EXPECT.cutAdmit)
    T.eq("P4 NAMED: one operation for the converter, cut and pickup together, then the drop", r.ops, EXPECT.ops)
    T.eq("P5 NAMED: its legs: the 400 L the cut produced born from the witness slot, the 200 L of dry grass moved in from the cells", r.legs, EXPECT.legs)
    T.eq("P6 NAMED: its evidence: produced 400, buffer before 0, picked 200, retained 600, no cap loss, fresh (MOWER_CUT admitted)", r.evidence, EXPECT.evidence)
    T.eq("P7 NAMED: the settle names the pending fresh litres: the birth's allocation (1) at 400, the remainder at 0", r.pending, EXPECT.pending)
    T.eq("P8 NAMED: the drop's delivery splits by the buffer's fresh fraction: 400 L birth, 200 L with the record KNOWN 7", r.drops, EXPECT.drops)
    T.eq("P9 the emptied buffer is withdrawn, nothing stays live; the ground holds the 600 L of grass and no dry grass", r.after, EXPECT.after)
    T.ok("P10 the first admitted MOWER_STATE_VOLUME_V1 cut says so once in the log", r.logged)
    T.eq("P14 NAMED: the emptied buffer's retired stock keeps its own class (mowerBuffer), never the core budget", r.retired, "mowerBuffer")
    -- the owner was handed the evidence and left the pending litres out
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ lay = { { DRY, 200, "dry" } } }, "w5c_p2", 103)
    sow(4)
    blockDrop(true)
    tick(host, w.mower, w.cut)
    T.eq("P11 NAMED: held (the drop blocked), the buffer holds 600 L of grass windrow whose record covers the 200 L of dry grass only (KNOWN 7, 200/200): the owner left the pending fresh 400 L out",
        bufferText(sg, w) .. "|" .. num(entryField(w, "fresh")), "GRASS_WINDROW/600/KNOWN:7:200/200|400")
    T.eq("P12 the buffer's native state is litersToDrop exactly, as the drop area's fillType, and it stays live", num(w.drop.litersToDrop) .. "/" .. liveBuffers(), "600/1")
    -- A drop the ground can take only part of: one raw unit a pixel per line call.
    blockDrop(false)
    ENGINE_GROUND.stepRaw = 1
    soilReset()
    tick(host, w.mower, w.cut)
    local d = lastDeliver()
    local born, total = 0, d and d.obs and d.obs.litresReturned or 0
    for _, c in ipairs(d and d.obs and d.obs.contributions or {}) do if c.birth ~= nil then born = born + c.litres end end
    local held = w.drop.litersToDrop
    T.eq("P13 NAMED: a drop that lands part of the buffer carries its fresh share (2/3 birth), and what it keeps holds the same share",
        tostring(total > 0 and held > 0) .. "/" .. num(total > 0 and born / total or nil) .. "/" .. num(held > 0 and (entryField(w, "fresh") or 0) / held or nil), "true/0.6667/0.6667")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE CAP: A LOSS FROM THE UNIFORM MIXTURE (Mower.lua:366-367)
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ converters = { [MEADOW_F] = { fillTypeIndex = GRASS, conversionFactor = 600 } }, lay = { { DRY, 200, "dry" } }, noTip = true }, "w5c_c", 104)
    sow(4)
    blockDrop(true)
    local f1 = tick(host, w.mower, w.cut)
    local op1 = f1 and f1.operations[1]
    T.eq("C1 NAMED: a 1200 L cut into an empty buffer: native keeps 1000; the slot's 1000 L is born and its 200 L is a LOSS (MOWER_BUFFER_CAP), never recreated",
        num(w.drop.litersToDrop) .. "|" .. legSums(op1) .. "|" .. num(op1 and op1.evidence.capLoss) .. "|" .. tostring(legText(op1):match("%(([%u_]+)%)")),
        "1000|slot>buffer:BORN=1000,slot>retire:LOSS=200|200|MOWER_BUFFER_CAP")
    T.eq("C2 the fresh litres are what the buffer kept of the birth: 1000", num(entryField(w, "fresh")), "1000")
    -- A second call over a dry windrow, the buffer full: every part keeps 1000 / 1800.
    ENGINE_TIP(w.dry, 200)
    w.mower.spec_mower.fruitTypeConverters = { [MEADOW_F] = { fillTypeIndex = GRASS, conversionFactor = 200 } }
    sow(4)
    local f2 = tick(host, w.mower, w.cut)
    local op2 = f2 and f2.operations[1]
    local pf = op2 and op2.evidence[PID] and op2.evidence[PID].pendingFresh or {}
    T.eq("C3 NAMED: a 400 L cut and a 200 L pickup into the full buffer: native keeps 1000 of 1600, so the remainder, the birth and the pickup each keep 5/8 and lose the rest",
        num(w.drop.litersToDrop) .. "|" .. legSums(op2),
        "1000|buffer>retire:LOSS=375,cell>buffer:TRANSFERRED=125,cell>retire:LOSS=75,slot>buffer:BORN=250,slot>retire:LOSS=150")
    T.eq("C4 NAMED: the pending fresh named: the remainder's 1000 at 5/8 (625) and the birth's 250; afterwards 875 L of the 1000 are fresh",
        num(pf.destinationBefore) .. "/" .. num(pf.allocations and pf.allocations[1] and pf.allocations[1].litres) .. "/" .. num(entryField(w, "fresh")),
        "625/250/875")
    T.eq("C5 NAMED: the buffer's record covers the dry grass it kept only: KNOWN 7 over 125 L", bufferText(sg, w), "GRASS_WINDROW/1000/KNOWN:7:125/125")
    blockDrop(false)
    soilReset()
    tick(host, w.mower, w.cut)
    T.eq("C6 NAMED: freed, the drop lands the 1000 L as 875 L birth and 125 L with the record", dropText(), "1000=875:birth:MOWER:GRASS_WINDROW+125:KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. TWO CONVERTERS CUTTING IN ONE CALL (Mower.lua:345-379)
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ converters = { [MEADOW_F] = { fillTypeIndex = GRASS, conversionFactor = 200 }, [BARLEY_F] = { fillTypeIndex = STRAW_W, conversionFactor = 50 } } }, "w5c_t", 121)
    ENGINE_PLANE.sow(MEADOW_F, -1, -1, 0, 0, 4)
    ENGINE_PLANE.sow(BARLEY_F, 0, -1, 1, 0, 4)
    blockDrop(true)
    local f = tick(host, w.mower, w.cut)
    local op1, op2 = f and f.operations[1], f and f.operations[2]
    local s = bufferStock(sg, w)
    T.eq("T1 NAMED: two converters cutting in one call (either order): two operations, each settled after its own add, the second retyping the first's output, and only the second birth fresh",
        opsText(f) .. "|" .. num(w.drop.litersToDrop) .. "/" .. num(s and s.observedAmount) .. "|" .. tostring(op1 and op1.evidence.retyped) .. "/" .. tostring(op2 and op2.evidence.retyped)
            .. "|" .. tostring(op2 ~= nil and num(entryField(w, "fresh")) == num(op2.evidence.produced)),
        "GROUND_MOWER_CUT:COMMITTED GROUND_MOWER_CUT:COMMITTED|250/250|nil/true|true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. A REMAINDER HELD ACROSS CALLS KEEPS ITS FRESH LITRES TO THE DROP
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({}, "w5c_h", 105)
    sow(4)
    blockDrop(true)
    tick(host, w.mower, w.cut)
    local held = num(w.drop.litersToDrop) .. "/" .. num(entryField(w, "fresh"))
    local f2 = tick(host, w.mower, w.cut)         -- nothing left to cut: no operation
    T.eq("H1 NAMED: a pure fresh cut held (the drop blocked) stays in the buffer, all of it fresh; a call that cuts nothing changes neither and makes no operation",
        held .. "|" .. num(w.drop.litersToDrop) .. "/" .. num(entryField(w, "fresh")) .. "|" .. opsText(f2), "400/400|400/400|")
    blockDrop(false)
    soilReset()
    tick(host, w.mower, w.cut)
    T.eq("H2 NAMED: freed later, the drop is all birth (no record part: the buffer holds no dry grass)", dropText(), "400=400:birth:MOWER:GRASS_WINDROW")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. A CHANGED TYPE: THE REMAINDER UNKNOWN, ONLY THE NEW BIRTH FRESH (SG-2 :296)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ lay = { { DRY, 200, "dry" } } }, "w5c_r", 106)
    sow(4)
    blockDrop(true)
    tick(host, w.mower, w.cut)                    -- 600 L grass windrow held, 400 fresh, record KNOWN 7 on 200
    -- The next call cuts BARLEY through a converter to straw windrow: native overwrites the area's type.
    w.mower.spec_mower.fruitTypeConverters = { [BARLEY_F] = { fillTypeIndex = STRAW_W, conversionFactor = 50 } }
    ENGINE_PLANE.sow(BARLEY_F, -1, -1, 1, 1, 4)
    local f = tick(host, w.mower, w.cut)
    local op = f and f.operations[1]
    T.eq("R1 NAMED: a 100 L straw cut retypes the held 600 L to straw windrow: a new stock with no record (the old one retired), only the new 100 L fresh, no remainder named",
        num(w.drop.litersToDrop) .. "/" .. tostring(op and op.evidence.retyped) .. "|" .. bufferText(sg, w) .. "|" .. num(entryField(w, "fresh"))
            .. "|" .. tostring(op and op.evidence[PID] and op.evidence[PID].pendingFresh and op.evidence[PID].pendingFresh.destinationBefore),
        "700/true|STRAW_WINDROW/700/noRecord|100|nil")
    blockDrop(false)
    soilReset()
    tick(host, w.mower, w.cut)
    T.eq("R2 NAMED: the drop carries the new birth and the rest with no record, so Soil lands the old grass unknown: never cleaned by the rename",
        dropText(), "700=100:birth:MOWER:STRAW_WINDROW+600:nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE WITNESS: MOWER_STATE_VOLUME_V1 (SG-2 :513-517)
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    local r = pass("selfPropelled", "w5c_w", 107)
    local p = r.op and r.op.evidence.portions[1] or {}
    T.eq("W1 NAMED: the birth's slot is the witness's portion: KNOWN, MOWER_STATE_VOLUME_V1, growth state 4, two pixels at yield scale 1",
        #(r.op and r.op.evidence.portions or {}) .. "/" .. table.concat({ tostring(p.knowledge), tostring(p.profile), tostring(p.growthState), tostring(p.pixels), num(p.yieldScale) }, "/"),
        "1/KNOWN/MOWER_STATE_VOLUME_V1/4/2/1")
    T.eq("W2 the frame's witness target is named only for its call: none outside it", tostring(SGCutState.target), "nil")
    -- A cut whose pixels disagree with native's own total: one UNKNOWN slot saying why (:517).
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({}, "w5c_w2", 108)
    sow(4)
    ENGINE_PLANE.bias = 0.5
    local f = tick(host, w.mower, w.cut)
    ENGINE_PLANE.bias = 0
    local op = f and f.operations[1]
    local q = op and op.evidence.portions[1] or {}
    T.eq("W3 NAMED: a reading that does not match native's area leaves one UNKNOWN slot with the reason (CUT_STATE_BASIS_MISMATCH); the output is still the cut's and still fresh",
        #(op and op.evidence.portions or {}) .. "/" .. tostring(q.knowledge) .. "/" .. tostring(q.reason) .. "|" .. legSums(op) .. "|" .. dropText(),
        "1/UNKNOWN/CUT_STATE_BASIS_MISMATCH|slot>buffer:BORN=500|500=500:birth:MOWER:GRASS_WINDROW")
    FSBaseMission.delete(m)
    -- Prepared foliage (:515): one pixel holds the meadow at state 3, the other only mowable decoration,
    -- which the preparation makes meadow at its first regrowth state, 3 as well.
    resetWorld()
    soilReset()
    m, sg, host, w = boot5c({}, "w5c_w3", 109)
    ENGINE_PLANE.sow(MEADOW_F, -1, -1, 0, 0, 3)
    ENGINE_DECO["0:-1"] = true
    f = tick(host, w.mower, w.cut)
    ENGINE_DECO = {}
    op = f and f.operations[1]
    local out = {}
    for _, pp in ipairs(op and op.evidence.portions or {}) do out[#out + 1] = tostring(pp.growthState) .. ":" .. tostring(pp.knowledge) .. ":" .. tostring(pp.reason) .. ":" .. num(pp.weight) end
    table.sort(out)
    T.eq("W4 NAMED: the pixel the preparation made meadow is counted at its state (native harvests both: 0.5 + 0.5 = 1) but has no origin: a portion of its own, UNKNOWN, PREPARED_FOLIAGE_UNATTRIBUTED, apart from the meadow pixel of the same state",
        table.concat(out, " ") .. "|" .. num(op and op.evidence.returnedArea), "3:KNOWN:nil:0.5 3:UNKNOWN:PREPARED_FOLIAGE_UNATTRIBUTED:0.5|1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. SOIL: A REFUSED MOWER_CUT, SOIL ABSENT, A CLIENT
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ lay = { { DRY, 200, "dry" } } }, "w5c_k", 110)
    sow(4)
    soilReset({ refuseKind = "MOWER_CUT" })
    local f = tick(host, w.mower, w.cut)
    T.eq("K1 NAMED: Soil refusing the MOWER_CUT: none of the call's lines is admitted, and the buffer's drop is not either (Soil's own carrier keeps the cut); StockGuard's own operations are unchanged",
        fns() .. "|" .. admitKinds() .. "|" .. opsText(f) .. "|" .. tostring(entryOf(w) == nil),
        "admit(4)|MOWER_CUT|GROUND_MOWER_CUT:COMMITTED|true")
    T.eq("K2 NAMED: that cut's birth names no pending litres and is not fresh",
        tostring(f and f.operations[1] and f.operations[1].evidence.fresh) .. "/" .. #(f and f.operations[1] and f.operations[1].evidence[PID] and f.operations[1].evidence[PID].pendingFresh.allocations or { 1 }), "false/0")
    FSBaseMission.delete(m)
    -- A buffer that took such a cut admits no drop until it empties; then it is StockGuard's again.
    resetWorld()
    soilReset()
    m, sg, host, w = boot5c({}, "w5c_k2", 111)
    sow(4)
    blockDrop(true)
    soilReset({ refuseKind = "MOWER_CUT" })
    tick(host, w.mower, w.cut)
    local framed = tostring(entryField(w, "soilFramed"))
    blockDrop(false)
    soilReset()
    tick(host, w.mower, w.cut)
    local dropped = fns()
    sow(4)
    soilReset()
    tick(host, w.mower, w.cut)
    T.eq("K3 NAMED: held after a refused cut, the buffer is not Soil's to receive (soilFramed false): its drop's line is not admitted (only that call's MOWER_CUT is asked); once emptied, the next cut's lines are admitted again",
        framed .. "|" .. dropped .. "|" .. admitKinds(), "false|admit(4) close(1)|MOWER_CUT,TIP_TO_GROUND_AROUND_LINE,TIP_TO_GROUND_AROUND_LINE")
    FSBaseMission.delete(m)
    -- Soil absent.
    resetWorld()
    soilReset()
    m, sg, host, w = boot5c({ noSoil = true, lay = { { DRY, 200, "dry" } } }, "w5c_k3", 112)
    sow(4)
    soilReset()
    local f1, f2 = tick(host, w.mower, w.cut)
    T.eq("K4 without Soil: nothing is asked, and StockGuard's own operations are the same", fns() .. "|" .. opsText(f1) .. " | " .. opsText(f2), "|" .. EXPECT.ops)
    FSBaseMission.delete(m)
    -- A client inside the update radius: the work area runs and no frame opens.
    resetWorld()
    soilReset()
    m, sg, host, w = boot5c({}, "w5c_k4", 113)
    sow(4)
    soilReset()
    local before = host.lastGroundFrame
    local server = REAL.g_server
    REAL.g_server = nil
    local ok = pcall(tick, host, w.mower, w.cut)
    REAL.g_server = server
    T.eq("K5 NAMED: on a client (Mower.lua:330-332) the work area runs, and no frame or lease opens", tostring(ok) .. "/" .. tostring(host.lastGroundFrame == before) .. "/" .. fns(), "true/true/")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE FILL-UNIT BRANCH: A BIRTH INTO THE UNIT, NO SOIL (Mower.lua:353-356)
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({ kind = "forageWagon" }, "w5c_u", 114)
    sow(4)
    soilReset()
    local f = tick(host, w.mower, w.cut)
    local op = f and f.operations[1]
    local s = stockAt(sg, unitId(w.mower))
    T.eq("U1 NAMED: with no drop area the cut is born into the mower's fill unit (400 L), its report consumed; Soil is asked nothing",
        num(level(w.mower)) .. "|" .. opsText(f) .. "|" .. legSums(op) .. "|" .. tostring(s and s.observedAmount == 400) .. "|" .. fns(),
        "400|GROUND_MOWER_CUT:COMMITTED|slot>buffer:BORN=400|true|")
    resetWorld()
    soilReset()
    m, sg, host, w = boot5c({ kind = "forageWagon", capacity = 300 }, "w5c_u2", 115)
    sow(4)
    f = tick(host, w.mower, w.cut)
    op = f and f.operations[1]
    T.eq("U2 NAMED: a unit with room for 300 takes 300; the 100 L its clamp refused is a LOSS (MOWER_UNIT_REFUSED)",
        num(level(w.mower)) .. "|" .. legSums(op) .. "|" .. tostring(legText(op):find("MOWER_UNIT_REFUSED", 1, true) ~= nil), "300|slot>buffer:BORN=300,slot>retire:LOSS=100|true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE DROP SLOT UNDER OR OVER A FOREIGN WRAPPER (Soil's drop frame, mechanism 2)
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    local seen = {}
    local function foreign(v)
        local inner = v.processDropArea
        v.processDropArea = function(self, dropArea, dt) seen[#seen + 1] = dropArea.litersToDrop return inner(self, dropArea, dt) end
    end
    local out = {}
    for _, order in ipairs({ "before", "after" }) do
        resetWorld()
        soilReset()
        local m, sg, host, w = boot(function(m, w)
            soilOn(m)
            lay(m, w, DRY, 200, "dry")
            w.mower, w.cut, w.drop = newMower("vehicle:mower")
            if order == "before" then foreign(w.mower) end
            vehicleIn(m, w.mower)
        end, "w5c_o_" .. order, { index = order == "before" and 116 or 117 })
        m.stockGuard.registerProperty(PID, MOWNER)
        ENGINE_TIP(w.dry, 200)
        if order == "after" then foreign(w.mower) end
        sow(4)
        seen = {}
        soilReset()
        tick(host, w.mower, w.cut)
        out[#out + 1] = order .. ":" .. #seen .. ":" .. dropText()
        FSBaseMission.delete(m)
    end
    T.eq("O1 NAMED: with a foreign wrapper under StockGuard's slot or over it, both run once per drop and the drop carries the same birth and record",
        table.concat(out, " "), "before:1:" .. EXPECT.drops .. " after:1:" .. EXPECT.drops)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. DESTRUCTION (SG-2 :136), AND THE MISSION'S END
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({}, "w5c_d", 118)
    sow(4)
    blockDrop(true)
    tick(host, w.mower, w.cut)
    local id = bufferId(w)
    local held = bufferId(w) ~= nil and bufferStock(sg, w) and bufferStock(sg, w).observedAmount or 0
    VehicleSystem.removeVehicle(m.vehicleSystem, w.mower)
    local ls = host.lastSettlement
    local a = ls and ls.report and ls.report.allocations and ls.report.allocations[1] or {}
    T.eq("D1 NAMED: removing the mower retires its remainder through a REMOVE with a DESTRUCTION leg of the whole amount, then withdraws the carrier",
        num(held) .. "/" .. tostring(ls and ls.report and ls.report.outcomeEvidence and ls.report.outcomeEvidence.nativePath) .. "/" .. tostring(ls and ls.outcome)
            .. "/" .. tostring(a.result) .. "/" .. tostring(a.reason) .. "/" .. num(a.sourceAmount) .. "/" .. tostring(id ~= nil and sg.operations.carriers[id] == nil) .. "/" .. liveBuffers(),
        "400/MOWER_BUFFER_DESTRUCTION/COMMITTED/DESTRUCTION/VEHICLE_REMOVED/400/true/0")
    FSBaseMission.delete(m)
    resetWorld()
    soilReset()
    m, sg, host, w = boot5c({}, "w5c_d2", 119)
    sow(4)
    blockDrop(true)
    tick(host, w.mower, w.cut)
    local live = liveBuffers()
    FSBaseMission.delete(m)
    T.eq("D2 NAMED: the mission's end (the host's teardown) drops every live Mower buffer entry and the vehicle it held", live .. "/" .. liveBuffers(), "1/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE KIND: NATIVE-BACKED, NEVER RESTORED, NEVER ENUMERATED
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5c({}, "w5c_n", 120)
    local spec = host.nativeLease.spec
    local binding = NA.mowerBufferBinding ~= nil and NA.mowerBufferBinding(w.mower, 2) or nil
    local function answer(fn, ...) local r = { pcall(fn, ...) } if not r[1] then return "RAISED" end return tostring(r[2]) .. "/" .. tostring(r[3]) end
    T.eq("N1 before its first cut the buffer resolves to nothing (NOT_BOUND)", answer(spec.resolveCarrier, binding), "nil/NOT_BOUND")
    sow(4)
    blockDrop(true)
    tick(host, w.mower, w.cut)
    local native = binding ~= nil and spec.resolveCarrier(binding) or nil
    local ns = native and spec.readNativeState(binding, native) or nil
    T.eq("N2 NAMED: bound, its native state is litersToDrop exactly, as the drop area's fillType, in a vehicle buffer",
        tostring(ns and ns.amount == w.drop.litersToDrop) .. "/" .. tostring(ns and ns.materialRef and ns.materialRef.fillTypeName) .. "/" .. tostring(ns and ns.storeKind),
        "true/GRASS_WINDROW/vehicle_buffer")
    T.eq("N3 NAMED: it is never restored and never enumerated (its save is 5bc-save, SG-2 :144, :247)",
        answer(spec.restoreBinding, binding, {}) .. "/" .. answer(function() return #spec.kinds[NA.KIND_MOWER_BUFFER].enumerateCarriers() end), "nil/NOT_RESTORABLE/0/nil")
    -- A sub-unit residue native keeps is the buffer's, exactly: no epsilon of its own (condition 1).
    -- Only the cut pointer runs (WorkArea.lua:182-183, no drop yet): the MOWER frame's own close brings
    -- the buffer to what native holds.
    w.drop.litersToDrop = 0.0004
    Mower.onStartWorkAreaProcessing(w.mower, nil)
    w.cut.processingFunction(w.mower, w.cut, 16)
    local s = bufferStock(sg, w)
    T.eq("N4 NAMED: a 0.0004 L residue native keeps is the buffer's, exactly: the MOWER frame's close reconciles it and leaves it bound (no epsilon of its own)",
        tostring(s ~= nil and s.observedAmount == 0.0004) .. "/" .. liveBuffers(), "true/1")
    FSBaseMission.delete(m)
end)
end
