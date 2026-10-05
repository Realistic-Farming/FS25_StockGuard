-- SG2-5d-b-baler_frame_spec_test.lua
--
-- SG2-5 slice 5d-b (Bob's 5d shape ruling with its addendum; conditions 1 and 3 of 09-30 and
-- condition 2 as rechecked 2026-10-02): a square Baler's work-area tick runs inside StockGuard's own
-- BALER frames, and switches Soil's admission on for its pickups.
--   * a tick per Baler from the inner onStartWorkAreaProcessing to the inner onEndWorkAreaProcessing,
--     its balerPickup carrier live only inside it; each processBalerArea call one BALER frame, each
--     pickup one TRANSFER from the cells to balerPickup at what native PRODUCED (Q1);
--   * the add in the inner fill-change listener, before the original: the seal of A over the tick's
--     batches by produced litres (F211 :76), Soil's published read of each share, ONE TRANSFER to the
--     chamber with the account named for its leg (Q2), the bale's finishBale reading that record;
--   * the overflow carried live (Q3): the second seal at O, the nested re-add, an overwrite's loss,
--     A = 0; C2's consumed reports, C3's replays, C4's machine filter, COALESCE_UNPROVED, the close's
--     loss, two map loads in one process (condition 2b) and the listener order (2c).
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world with the SG2-5b bench's
-- preamble verbatim (SG2-4c-1's recorder of Soil's published surface, the stand-in owner, the windrow
-- types as a model extension), plus Soil's 5d surface as a stand-in (the delivery's collection and the
-- published collected read, Soil's reader VERBATIM) and an owner carrying Soil's account by #1077's
-- rules.
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path wraps the live Baler class's listeners and the
-- native host brackets the pickup's CAPTURED pointer (WorkArea.lua:266); WorkArea's own order then
-- runs a tick (the start event, the captured pointer, the end event, each raised by name at raise
-- time) over a grass windrow a tipper laid. The two-sided bale bar against Soil's own BalerCollection
-- is the joined run outside the repo (the PR body names it).
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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
local function SG25DB_BENCH()

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

-- ── Bale (objects/Bale.lua), the parts createBale uses ───────────────────────
Bale = Bale or {}
local BALES = { next = 90000, made = {} }
function Bale.new(isServer, isClient)
    BALES.next = BALES.next + 1
    return setmetatable({ isServer = isServer, isClient = isClient, nodeId = BALES.next, fillLevel = 0 }, { __index = Bale })
end
function Bale:loadFromConfigXML(filename) self.filename = filename return true end
function Bale:setFillType(ft) self.fillType = ft end
function Bale:setFillLevel(l) self.fillLevel = l end
function Bale:setVariationId(v) self.variationId = v end
function Bale:setOwnerFarmId(f) self.ownerFarmId = f end
function Bale:register() BALES.made[#BALES.made + 1] = self end
function Bale:mountKinematic() end
function Bale:setCanBeSold() end
function Bale:setNeedsSaving() end
REAL.BalerCreateBaleEvent = REAL.BalerCreateBaleEvent or { new = function(...) return { ... } end }
REAL.NetworkUtil = REAL.NetworkUtil or { getObjectId = function(o) return o and o.nodeId end }
if g_server ~= nil and g_server.broadcastEvent == nil then g_server.broadcastEvent = function() end end

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
    function B:createBale(baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId)
        local spec = self.spec_baler
        local baleTypeDef = spec.baleTypes[spec.currentBaleTypeIndex]
        local isValid = false
        local bale = { filename = xmlFilename or spec.currentBaleXMLFilename, time = baleTime, fillType = baleFillType, fillLevel = fillLevel }
        if self.isServer then
            local baleObject = Bale.new(self.isServer, self.isClient)
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
    v.eventListeners.onFillUnitFillLevelChanged = { Baler }
    v.eventListeners.onStartWorkAreaProcessing = { Baler }
    v.eventListeners.onEndWorkAreaProcessing = { Baler }
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

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: ONE BALER TICK OVER A GRASS WINDROW
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({}, "w5db_e", 101)
    local v = w.baler
    local wa = v.spec_workArea.workAreas[1]
    local held = SGClassHook.record(Baler, "onStartWorkAreaProcessing", GO_.HOOK_ID) ~= nil and SGClassHook.record(Baler, "onEndWorkAreaProcessing", GO_.HOOK_ID) ~= nil
        and SGClassHook.record(Baler, "onFillUnitFillLevelChanged", GO_.HOOK_ID) ~= nil
    T.ok("E0 [reached] main.lua's install wrapped the Baler's three listeners (SGClassHook, the live class) and bracketed the pickup's CAPTURED pointer (WorkArea.lua:266)",
        held and wa.processingFunction ~= Baler.processBalerArea and wa._sgBrackets ~= nil and wa._sgBrackets.processBalerArea ~= nil
            and wa._sgBrackets.processBalerArea.original == Baler.processBalerArea)
    soilReset()
    tick(v)
    T.eq("E1 NAMED [entry point]: Soil admitted the pickup line inside the BALER frame; StockGuard settled the pickup and the add, and the chamber's record carries the sealed account Soil's reader gave (100 L known at 30 %)",
        admits() .. "/" .. opsText(host) .. "|" .. chamberText(sg, v),
        "1/GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30")
    local add = opOf(host, "GROUND_BALER_ADD")
    local leg = add and add.report.allocations[1]
    T.eq("E2 NAMED: the add is one TRANSFER from balerPickup to the chamber, source P x A / W, destination A, its account named for that leg; Soil's reader resolved the seal through the mission handle",
        tostring(leg and leg.source.carrierId == pickupId(v)) .. "/" .. tostring(leg and leg.destination.carrierId == unitId(v, 1)) .. "/" .. num(leg and leg.sourceAmount) .. "/" .. num(leg and leg.destinationAmount)
            .. "/" .. tostring(add and add.evidence.seal and add.evidence.seal.read) .. "/" .. SOIL5D.reads,
        "true/true/100/100/1/1")
    T.eq("E3 the tick's carrier is gone after the close (withdrawn, nothing live), its remainder nothing, and the add's own report was consumed (none outstanding)",
        tostring(sg.operations.carriers[pickupId(v)] == nil) .. "/" .. liveCount(NA.balerPickups) .. "/" .. tostring(opOf(host, "GROUND_BALER_REMAINDER")) .. "/" .. #host.lastBalerTick.expected,
        "true/0/nil/0")
    T.eq("E4 native ran unchanged: the chamber holds 100 L, lastPickedUpLiters 100, the windrow is gone", num(v:getFillUnitFillLevel(1)) .. "/" .. num(v.spec_baler.workAreaParameters.lastPickedUpLiters), "100/100")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PICKUP: WHAT NATIVE PRODUCED, DECLARED (Q1)
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    resetWorld()
    soilReset()
    -- The silage additive: 0.1 L at usage 0.001 per litre covers the whole 100 L pickup: a 5 % boost.
    local m, sg, host, w = boot5db({ additives = { level = 0.1, usage = 0.001 } }, "w5db_p", 102)
    local v = w.baler
    tick(v)
    local pick = opOf(host, "GROUND_BALER")
    local d, s, based = 0, 0, false
    for _, a in ipairs(pick and pick.report.allocations or {}) do
        if a.destination.carrierId == pickupId(v) then d = d + a.destinationAmount s = s + a.sourceAmount end
        if a.conversionBasisId ~= nil then based = true end
    end
    T.eq("P1 NAMED: the pickup's legs take the cells' 100 L to 105 L on balerPickup (P_b, the boost, :1886-1910), with no conversion basis, and declare the gain",
        num(s) .. "/" .. num(d) .. "/" .. tostring(based) .. "/" .. num(pick and pick.evidence.nativeGain and pick.evidence.nativeGain.boost) .. "/" .. num(pick and pick.evidence.nativeGain and pick.evidence.nativeGain.fillScale),
        "100/105/false/5/1")
    T.eq("P2 NAMED: the boosted 105 L reach the chamber KNOWN with the source's condition: no unexplained excess, the account 105 L known at 30 %",
        chamberText(sg, v), "GRASS_WINDROW|105|KNOWN|KNOWN:7:105/105/0/0/30")
    T.eq("P3 the additive's own debit (:1895) replayed at the pickup frame's close: its record follows native", num(stockAt(sg, unitId(v, 2)) and stockAt(sg, unitId(v, 2)).observedAmount or 0) .. "/" .. num(v:getFillUnitFillLevel(2)), "0/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ADD: THE SEAL BY PRODUCED LITRES, THE ACCOUNT ON THE LEG
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    resetWorld()
    soilReset()
    -- fillScale 2 with the additive: W = 210 from 105 produced; A = 210.
    local m, sg, host, w = boot5db({ fillScale = 2, additives = { level = 0.1, usage = 0.001 } }, "w5db_a1", 103)
    local v = w.baler
    tick(v)
    local add = opOf(host, "GROUND_BALER_ADD")
    local leg = add and add.report.allocations[1]
    T.eq("A1 NAMED: at fillScale 2 the add's leg moves P x A / W = 105 of balerPickup into A = 210 in the chamber, KNOWN over the whole of A at the source's 30 %",
        num(leg and leg.sourceAmount) .. "/" .. num(leg and leg.destinationAmount) .. "|" .. chamberText(sg, v), "105/210|GRASS_WINDROW|210|KNOWN|KNOWN:7:210/210/0/0/30")
    FSBaseMission.delete(m)

    -- Two pickup work areas in one tick with different gains and conditions: the additive covers
    -- the first pickup only (0.1 L), so it produces 105 L and the second 100 L; Soil's sources read
    -- 20 % and 80 %. F211 :76: the 205 L split by what each PRODUCED (105 / 100).
    resetWorld()
    soilReset()
    local split = function(seq) return seq == 1 and { { id = "a", frac = 1, pct = 20 } } or { { id = "b", frac = 1, pct = 80 } } end
    m, sg, host, w = boot5db({ areas = 2, additives = { level = 0.1, usage = 0.001 }, split = split,
        lay = { { GRASS, 100, "g1", { x = 0, z = 0 } }, { GRASS, 100, "g2", { x = 0, z = 10 } } } }, "w5db_a2", 104)
    v = w.baler
    tick(v)
    T.eq("A2 NAMED: two pickups (105 L at 20 %, 100 L at 80 %) seal by produced litres into one account of 205 L at (105 x 20 + 100 x 80) / 205",
        chamberText(sg, v), "GRASS_WINDROW|205|KNOWN|KNOWN:7:205/205/0/0/" .. num((105 * 20 + 100 * 80) / 205))
    -- A second tick adds to the chamber's record: the accounts add by carrier litres.
    relay(m, w, GRASS, 100, "g3", { x = 0, z = 0 })
    tick(v)
    T.eq("A3 a later tick's add combines with what the chamber already held: 305 L, its account the sum",
        chamberText(sg, v), "GRASS_WINDROW|305|KNOWN|KNOWN:7:305/305/0/0/" .. num((105 * 20 + 100 * 80 + 100 * 80) / 305))
    FSBaseMission.delete(m)
end)

--- The add frame's fill-unit reports: cause:accepted:consumed, in order.
local function reportsText(host)
    local t = host.lastBalerTick
    local out = {}
    for _, obs in ipairs(t and t.reports or {}) do
        if obs.source == "FILL_UNIT" then out[#out + 1] = tostring(obs.cause) .. ":" .. num(obs.accepted) .. ":" .. tostring(obs.groundConsumed == true) end
    end
    return table.concat(out, " ")
end
--- Each Soil pickup's sources by delivery order: 20 %, 80 %, then 50 %.
local PCTS = function(seq) return { { id = "p", frac = 1, pct = seq == 1 and 20 or (seq == 2 and 80 or 50) } } end

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE OVERFLOW, CARRIED LIVE (Q3), AND THE BALE THAT READS THE CHAMBER (F211 :94)
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ capacity = 150, split = PCTS }, "w5db_o", 105)
    local v = w.baler
    local seen = probeFinish(sg, v)
    tick(v)                                                     -- 100 L at 20 %
    relay(m, w, GRASS, 100, "g2")
    tick(v)                                                     -- 100 L at 80 %: 50 fill the chamber, 50 overflow
    T.eq("O1 NAMED: the add that fills the chamber settles BEFORE the original, so finishBale reads the chamber's record: 150 L known at (100 x 20 + 50 x 80) / 150",
        #seen .. "/" .. tostring(seen[1]) .. "/" .. #BALES.made, "1/GRASS_WINDROW|150|KNOWN|KNOWN:7:150/150/0/0/" .. num((100 * 20 + 50 * 80) / 150) .. "/1")
    T.eq("O2 NAMED: the full branch's overflow O = D - A = 50, read after the original, is a second seal: the overflow carrier holds 50 L of NATIVE_BALER_OVERFLOW_V1 known at 80 %, and nothing is lost",
        opsText(host) .. "|" .. stockText(stockAt(sg, overflowId(v))),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED GROUND_BALER_OVERFLOW:COMMITTED|NATIVE_BALER_OVERFLOW_V1|50|KNOWN|KNOWN:7:50/50/0/0/80")
    T.eq("O3 the square clear in finishBale (:1438) replayed at the close: the chamber's record is gone with the native level; the add's own report was consumed, the retag's and the clear's replayed",
        chamberText(sg, v) .. "/" .. num(v:getFillUnitFillLevel(1)) .. "|" .. reportsText(host), "none/0|SET_FILL_TYPE:0:false ADD_FILL_LEVEL:-150:false ADD_FILL_LEVEL:50:true")
    relay(m, w, GRASS, 100, "g3")
    tick(v)                                                     -- 100 L at 50 %; the 50 L overflow re-added inside the add
    T.eq("O4 NAMED: the nested re-add (:1180-1182) is a TRANSFER from the overflow to the chamber before the nested original: the bale it finishes reads 100 L at 50 % and the 50 L at 80 %",
        #seen .. "/" .. tostring(seen[2]) .. "|" .. opsText(host),
        "2/GRASS_WINDROW|150|KNOWN|KNOWN:7:150/150/0/0/" .. num((100 * 50 + 50 * 80) / 150) .. "|GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED GROUND_BALER_READD:COMMITTED")
    T.eq("O5 the emptied overflow is withdrawn at the close, and native's overflow is 0", tostring(sg.operations.carriers[overflowId(v)] == nil) .. "/" .. liveCount(NA.balerOverflows) .. "/" .. num(v.spec_baler.fillUnitOverflowFillLevel), "true/0/0")
    FSBaseMission.delete(m)

    -- An overflow the full branch overwrites is retired as the native loss it is (F211 :88, :96).
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({ capacity = 150, split = PCTS }, "w5db_o2", 106)
    v = w.baler
    tick(v)
    relay(m, w, GRASS, 100, "g2")
    tick(v)                                                     -- the overflow holds 50 L at 80 %
    relay(m, w, GRASS, 200, "g3")
    tick(v)                                                     -- 200 L into the empty chamber: 150 accepted, a new 50 overflow
    local ow = opOf(host, "GROUND_BALER_OVERFLOW")
    T.eq("O6 NAMED: the old 50 L overflow the full branch overwrote is retired as LOSS first, then the new 50 L overflow is carried at its own 50 %",
        opsText(host) .. "|" .. stockText(stockAt(sg, overflowId(v))),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED GROUND_BALER_OVERFLOW:COMMITTED GROUND_BALER_OVERFLOW:COMMITTED|NATIVE_BALER_OVERFLOW_V1|50|KNOWN|KNOWN:7:50/50/0/0/50")
    local first = host.lastBalerTick.operations[3]
    local leg = first and first.report and first.report.allocations[1]
    T.eq("O7 the overwritten overflow's leg is a LOSS of its whole 50 L", tostring(leg and leg.result) .. "/" .. tostring(leg and leg.reason) .. "/" .. num(leg and leg.sourceAmount), "LOSS/BALER_OVERFLOW_OVERWRITTEN/50")
    FSBaseMission.delete(m)

    -- A full main not yet in physics keeps its bale for the next frame (:1172-1175): the next add
    -- raises the event with A = 0 and the full branch assigns O = D (Bob's addendum).
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({ capacity = 100, notInPhysics = true, split = PCTS }, "w5db_o3", 107)
    v = w.baler
    tick(v)                                                     -- the chamber full at 100 L, no bale yet
    relay(m, w, GRASS, 50, "g2")
    tick(v)                                                     -- 50 L more: A = 0, O = 50
    T.eq("O8 NAMED: an add with A = 0 makes no TRANSFER to the unit; the full branch's O = D is the second seal: the chamber keeps its 100 L, the overflow holds 50 L at 80 %",
        opsText(host) .. "|" .. chamberText(sg, v) .. "|" .. stockText(stockAt(sg, overflowId(v))),
        "GROUND_BALER:COMMITTED GROUND_BALER_OVERFLOW:COMMITTED|GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/20|NATIVE_BALER_OVERFLOW_V1|50|KNOWN|KNOWN:7:50/50/0/0/80")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. COALESCE_UNPROVED (Bob's guard; SG-2 :181)
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ areas = 2, lay = { { GRASS, 100, "g1", { x = 0, z = 0 } }, { DRY, 100, "d1", { x = 0, z = 10 } } } }, "w5db_g", 108)
    local v = w.baler
    tick(v)
    T.eq("G1 NAMED: a tick that picks grass on one area and dry grass on the other proves no mixture: the second line is reconciled unattributed, the add abandoned, the chamber's material qualified (UNKNOWN)",
        opsText(host) .. "|" .. tostring(stockAt(sg, unitId(v, 1)) and stockAt(sg, unitId(v, 1)).knowledge),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:ABANDONED:COALESCE_UNPROVED|UNKNOWN")
    FSBaseMission.delete(m)

    -- A chamber holding dry grass receives grass: FillUnit empties it first (:1142-1146).
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({ lay = { { DRY, 100, "d1" } } }, "w5db_g2", 109)
    v = w.baler
    tick(v)                                                     -- the chamber holds 100 L dry grass
    relay(m, w, GRASS, 150, "g1")
    tick(v)
    T.eq("G2 an add into a chamber holding another type is abandoned, never carried as one mixture; the pickup is debited by what entered (the new level), so nothing is left as a false loss",
        opsText(host) .. "|" .. tostring(stockAt(sg, unitId(v, 1)) and stockAt(sg, unitId(v, 1)).knowledge),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:ABANDONED:COALESCE_UNPROVED|UNKNOWN")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE CLOSE: WHAT THE ADD DID NOT TAKE IS NATIVE LOSS (F211 :88)
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ massLimit = 60 }, "w5db_l", 110)
    local v = w.baler
    tick(v)
    local rem = opOf(host, "GROUND_BALER_REMAINDER")
    local leg = rem and rem.report.allocations[1]
    T.eq("L1 NAMED: a mass-limited add takes D = 60 of the 100 L produced: the chamber 60 L known, and the 40 L balerPickup still holds is one LOSS at the close",
        chamberText(sg, v) .. "|" .. opsText(host) .. "|" .. tostring(leg and leg.result) .. ":" .. num(leg and leg.sourceAmount),
        "GRASS_WINDROW|60|KNOWN|KNOWN:7:60/60/0/0/30|GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED GROUND_BALER_REMAINDER:COMMITTED|LOSS:40")
    T.eq("L2 the carrier is withdrawn after its loss", tostring(sg.operations.carriers[pickupId(v)] == nil) .. "/" .. liveCount(NA.balerPickups), "true/0")
    FSBaseMission.delete(m)

    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({}, "w5db_l2", 111)
    v = w.baler
    v.spec_fillUnit.fillUnits[1].refuse = true
    tick(v)
    T.eq("L3 an early refusal (FillUnit returns 0 before any event, :1106-1124): no add, and the tick's 100 L retire as LOSS at the close",
        opsText(host) .. "|" .. chamberText(sg, v), "GROUND_BALER:COMMITTED GROUND_BALER_REMAINDER:COMMITTED|none")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. WHICH BALERS (Bob's C4)
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    for i, opts in ipairs({ { round = true }, { nonStop = true } }) do
        resetWorld()
        soilReset()
        local m, sg, host, w = boot5db(opts, "w5db_k" .. i, 111 + i)
        soilReset()
        tick(w.baler)
        T.eq(i == 1 and "K1 NAMED: a round Baler opens no tick: no BALER frame, no admission, Soil's standalone path keeps it" or "K2 NAMED: a non-stop Baler, the same",
            tostring(host.lastBalerTick) .. "/" .. admits(), "nil/0")
        FSBaseMission.delete(m)
    end
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({}, "w5db_k3", 114)
    w.baler.isServer = false
    soilReset()
    tick(w.baler)
    T.eq("K3 server only: a Baler that is not the server opens no tick", tostring(host.lastBalerTick) .. "/" .. admits(), "nil/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE PICKUP CARRIES SOIL'S RECORD (SG-1 calls an owner only for a property present)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    for i, unresolved in ipairs({ false, true }) do
        resetWorld()
        soilReset()
        local m, sg, host, w = boot5db({ unresolved = unresolved }, "w5db_r" .. i, 114 + i)
        local v = w.baler
        local before = nil
        local PROBE = { onEndWorkAreaProcessing = function(self) before = stockText(stockAt(sg, pickupId(self))) end }
        table.insert(v.eventListeners.onEndWorkAreaProcessing, 1, PROBE)
        tick(v)
        if not unresolved then
            T.eq("R1 NAMED: before the add, balerPickup's stock carries Soil's record from the cells' resident capture; the chamber then carries the account",
                tostring(before) .. "|" .. chamberText(sg, v), "GRASS_WINDROW|100|KNOWN|KNOWN:7:none|GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30")
        else
            T.eq("R2 NAMED: over cells Soil cannot resolve (UNAVAILABLE) the pickup carries Soil's qualified record, and the chamber's material is qualified rather than reading the account as known: Soil's bale read falls back",
                tostring(before) .. "|" .. chamberText(sg, v), "GRASS_WINDROW|100|UNAVAILABLE|UNAVAILABLE:nil:none|GRASS_WINDROW|100|UNAVAILABLE|UNAVAILABLE:nil:none")
        end
        FSBaseMission.delete(m)
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. SOIL ABSENT
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ noSoil = true }, "w5db_x", 117)
    soilReset()
    tick(w.baler)
    T.eq("X1 without Soil nothing is admitted or read, and StockGuard's own operations are the same", admits() .. "/" .. SOIL5D.reads .. "/" .. opsText(host) .. "|" .. chamberText(sg, w.baler),
        "0/0/GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|GRASS_WINDROW|100|UNKNOWN|noRecord")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. TWO MAP LOADS IN ONE PROCESS (Bob's condition 2b)
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({}, "w5db_m1", 118)
    tick(w.baler)
    local first = opsText(host)
    local oldTable = Baler
    FSBaseMission.delete(m)
    -- The next map load re-sources the specialization: a NEW Baler table (Baler.lua:7), StockGuard
    -- not re-sourced.
    REAL.Baler = newBalerClass()
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({}, "w5db_m2", 119)
    local rec = SGClassHook.record(Baler, "onFillUnitFillLevelChanged", GO_.HOOK_ID)
    tick(w.baler)
    local adds = 0
    for _, op in ipairs(host.lastBalerTick and host.lastBalerTick.operations or {}) do if op.evidence and op.evidence.nativePath == "GROUND_BALER_ADD" then adds = adds + 1 end end
    T.eq("M1 NAMED: on the second load's new Baler table StockGuard's listeners are live and run once per raise: one pickup, one add, the same as the first load",
        first .. "|" .. opsText(host) .. "|" .. adds, "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|1")
    T.eq("M2 the first table's record does not leak onto the second: its record wraps the second table's own listener",
        tostring(Baler ~= oldTable) .. "/" .. tostring(rec ~= nil and rec.original ~= SGClassHook.record(oldTable, "onFillUnitFillLevelChanged", GO_.HOOK_ID).original), "true/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. THE LISTENER ORDER (Bob's condition 2c): SOIL'S WRAP OUTSIDE STOCKGUARD'S, AND THE REVERSE
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    local NAMES3 = { "onStartWorkAreaProcessing", "onEndWorkAreaProcessing", "onFillUnitFillLevelChanged" }
    local function soilWrap(B, seen)
        for _, name in ipairs(NAMES3) do
            local inner = B[name]
            B[name] = function(self, ...) seen[name] = (seen[name] or 0) + 1 return inner(self, ...) end
        end
    end
    local results = {}
    for i, outside in ipairs({ true, false }) do
        REAL.Baler = newBalerClass()
        resetWorld()
        soilReset()
        local seen = {}
        if not outside then soilWrap(Baler, seen) end              -- installed before StockGuard's: inside
        local m, sg, host, w = boot5db({}, "w5db_z" .. i, 119 + i)
        if outside then soilWrap(Baler, seen) end                  -- Soil installs at mission start, later: outside
        tick(w.baler)
        results[i] = opsText(host) .. "|" .. chamberText(sg, w.baler) .. "|" .. tostring(seen.onStartWorkAreaProcessing) .. "/" .. tostring(seen.onEndWorkAreaProcessing) .. "/" .. tostring(seen.onFillUnitFillLevelChanged)
        FSBaseMission.delete(m)
    end
    T.eq("Z1 NAMED: with Soil's listener wraps outside StockGuard's (production's order), the tick settles as in E, each listener raised once",
        results[1], "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30|1/1/1")
    T.eq("Z2 and in the reverse order, the same", results[2], results[1])
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Q. A PICKUP THE BRACKET COULD NOT OBSERVE: THE ADD EXPLAINS ONLY THE OBSERVED SHARE
-- ══════════════════════════════════════════════════════════════════════════
group("Q", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ areas = 2, lay = { { GRASS, 100, "g1", { x = 0, z = 0 } }, { GRASS, 100, "g2", { x = 0, z = 10 } } } }, "w5db_q", 130)
    local v = w.baler
    -- Area 2's line runs with no ground sampler: native picks it, StockGuard cannot observe it.
    local wa2 = v.spec_workArea.workAreas[2]
    local bracketed = wa2.processingFunction
    wa2.processingFunction = function(...)
        host.groundSampler = function() return nil, "BENCH_NO_SAMPLER" end
        local r = { pcall(bracketed, ...) }
        host.groundSampler = nil
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2)
    end
    tick(v)
    local add = opOf(host, "GROUND_BALER_ADD")
    local leg = add and add.report.allocations[1]
    local acc = add and add.evidence[PID] and add.evidence[PID].collectedAccounts[1].account
    local s = stockAt(sg, unitId(v, 1))
    local p = s and s.properties[PID]
    T.eq("Q1 NAMED: of 200 L native produced StockGuard observed 100: the add explains 100 of A = 200 (source 100, destination 100, the account of 100); the chamber holds 200 with the other 100 unexplained (its record covers 100)",
        num(leg and leg.sourceAmount) .. "/" .. num(leg and leg.destinationAmount) .. "/" .. accText(acc) .. "|" .. num(s and s.observedAmount) .. "/" .. tostring(s and s.reason) .. "/" .. num(p and p.knownAmount),
        "100/100/100/100/0/0/30|200/UNEXPLAINED_DELTA/100")
    -- MAINTENANCE row 197: the chamber was empty, so the add BORE its stock, and half of it is
    -- unexplained. It reads PARTIAL, as an UPDATE would (SG-1 brief :90, :108).
    T.eq("Q2 NAMED [entry point, MAINTENANCE row 197]: the chamber born with 100 of its 200 L unexplained reads PARTIAL with reason UNEXPLAINED_DELTA, not KNOWN",
        tostring(s and s.knowledge) .. "/" .. tostring(s and s.reason), "PARTIAL/UNEXPLAINED_DELTA")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. A THROW INSIDE THE TICK
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({}, "w5db_t", 131)
    local v = w.baler
    -- processBalerArea throws after its pickup line (:1909 adds into a missing key); WorkArea has
    -- no pcall (WorkArea.lua:183), so the end event never runs and the tick stays open.
    local keep = v.spec_baler.pickupFillTypes
    v.spec_baler.pickupFillTypes = { [DRY] = 0, [STRAW_W] = 0 }
    local ok = pcall(tick, v)
    local stale = GO_.balerTicks[v]
    v.spec_baler.pickupFillTypes = keep
    relay(m, w, GRASS, 100, "g2")
    tick(v)
    local staleOps = {}
    for _, op in ipairs(stale and stale.operations or {}) do staleOps[#staleOps + 1] = tostring(op.evidence and op.evidence.nativePath) .. ":" .. tostring(op.outcome) .. ":" .. tostring(op.reason) end
    T.eq("T1 NAMED: the throw re-raises with the tick left open and its line abandoned (NATIVE_ERROR); the Baler's next onStart closes it (its carrier withdrawn) and the next tick runs as normal",
        tostring(ok) .. "/" .. tostring(stale ~= nil) .. "/" .. table.concat(staleOps, " ") .. "/" .. tostring(stale and stale.live == nil) .. "|" .. opsText(host) .. "|" .. liveCount(GO_.balerTicks),
        "false/true/GROUND_BALER:ABANDONED:NATIVE_ERROR/true|GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE OVERFLOW'S OTHER WAYS OUT
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    -- A re-add into another type than the overflow was produced as proves no mixture.
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ capacity = 150, split = PCTS }, "w5db_v1", 132)
    local v = w.baler
    tick(v)
    relay(m, w, GRASS, 100, "g2")
    tick(v)                                                     -- the overflow holds 50 L of grass
    relay(m, w, DRY, 50, "d3")
    tick(v)                                                     -- dry grass into the empty chamber, then the 50 L re-added as dry grass
    T.eq("V1 NAMED: the re-add of a grass overflow into dry grass is abandoned (COALESCE_UNPROVED), never carried as one mixture",
        opsText(host), "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED GROUND_BALER_READD:ABANDONED:COALESCE_UNPROVED")
    FSBaseMission.delete(m)

    -- A Baler removed with a live overflow: the overflow is destruction (SG-2 :136).
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({ capacity = 150, split = PCTS }, "w5db_v2", 133)
    v = w.baler
    tick(v)
    relay(m, w, GRASS, 100, "g2")
    tick(v)
    local id = overflowId(v)
    VehicleSystem.removeVehicle(m.vehicleSystem, v)
    local ls = host.lastSettlement
    local a = ls and ls.report and ls.report.allocations and ls.report.allocations[1] or {}
    T.eq("V2 NAMED: removing the Baler retires its 50 L overflow through a REMOVE with a DESTRUCTION leg, then withdraws the carrier",
        tostring(ls and ls.outcome) .. "/" .. tostring(a.result) .. "/" .. tostring(a.reason) .. "/" .. num(a.sourceAmount) .. "/" .. tostring(sg.operations.carriers[id] == nil) .. "/" .. liveCount(NA.balerOverflows),
        "COMMITTED/DESTRUCTION/VEHICLE_REMOVED/50/true/0")
    FSBaseMission.delete(m)

    -- The mission's end: no Baler entry outlives it or holds its vehicles.
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({ capacity = 150, split = PCTS }, "w5db_v3", 134)
    v = w.baler
    tick(v)
    relay(m, w, GRASS, 100, "g2")
    tick(v)
    local live = liveCount(NA.balerOverflows)
    FSBaseMission.delete(m)
    T.eq("V3 the mission's end empties the Baler's tables", live .. "/" .. liveCount(NA.balerOverflows) .. "/" .. liveCount(NA.balerPickups) .. "/" .. liveCount(GO_.balerTicks), "1/0/0/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE TWO KINDS: LIVE ONLY, NEVER RESTORED, NEVER ENUMERATED
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({}, "w5db_u", 135)
    local v = w.baler
    local spec = host.nativeLease.spec
    local pb, ob = NA.balerPickupBinding(v), NA.balerOverflowBinding(v)
    local function answer(fn, ...) local r = { pcall(fn, ...) } if not r[1] then return "RAISED" end return tostring(r[2]) .. "/" .. tostring(r[3]) end
    T.eq("U1 outside a tick the pickup resolves to nothing (NOT_LIVE), and an overflow never bound neither (NOT_BOUND)",
        answer(spec.resolveCarrier, pb) .. " " .. answer(spec.resolveCarrier, ob), "nil/NOT_LIVE nil/NOT_BOUND")
    -- SG2-5e-a (SG-2 :477) moved the overflow's half: its save extension puts the native scalar back
    -- at the load, so a restore keeps its saved binding (ROW86's group O is that bar). The pickup
    -- lives in one tick and is still never restored; neither is ever enumerated.
    T.eq("U2 NAMED: the pickup is never restored, the overflow keeps its saved binding at a restore (SG2-5e-a), and neither is ever enumerated",
        answer(spec.restoreBinding, pb, {}) .. " " .. tostring(spec.restoreBinding(ob, {}) == ob) .. "/" .. #spec.kinds[NA.KIND_BALER_PICKUP].enumerateCarriers() .. "/" .. #spec.kinds[NA.KIND_BALER_OVERFLOW].enumerateCarriers(),
        "nil/NOT_RESTORABLE true/0/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE PICKUP'S RETIREMENTS KEEP A BUDGET OF THEIR OWN (main.lua)
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetWorld()
    soilReset()
    local layList = {}
    for k = 0, 7 do layList[#layList + 1] = { GRASS, 100, "g" .. k, { x = 9 * k, z = 0 } } end
    local m, sg, host, w = boot5db({ lay = layList }, "w5db_c", 136)
    local v = w.baler
    local core0 = 0
    for _, s in pairs(sg.operations.retiredStocks) do if not NA.isBalerPickupKey(s.carrierKey) then core0 = core0 + 1 end end
    local limit = sg.operations.retiredLimit
    sg.operations.retiredLimit = 4
    local wa = v.spec_workArea.workAreas[1]
    for k = 0, 7 do
        wa.start.x, wa.width.x, wa.height.x = 9 * k - 1, 9 * k + 1, 9 * k - 1
        tick(v)
    end
    local mine, core = 0, 0
    for _, s in pairs(sg.operations.retiredStocks) do
        if NA.isBalerPickupKey(s.carrierKey) then mine = mine + 1 else core = core + 1 end
    end
    sg.operations.retiredLimit = limit
    T.eq("C1 NAMED: eight ticks retire their pickup stocks in their own class (held to its budget), and the tippers' retired history is never evicted",
        tostring(core0 >= 8) .. "/" .. tostring(mine >= 1 and mine <= 4) .. "/" .. tostring(core == core0), "true/true/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. AN UNREADABLE SHARE, AND THE MASS-LIMITED OVERFLOW
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({}, "w5db_w1", 137)
    SOIL5D.failRead = true
    tick(w.baler)
    T.eq("W1 NAMED: a share Soil's reader answers UNAVAILABLE for enters the account as unknown carrier litres, never dropped and never known (the reader's own contract)",
        chamberText(sg, w.baler), "GRASS_WINDROW|100|KNOWN|KNOWN:7:100/0/100/0/nil")
    FSBaseMission.delete(m)

    -- A mass limit of 80 L: native's D is 80 of the 100 produced; the second add fills the 150 L
    -- chamber with 70 and keeps D - A = 10 as overflow, never W - A = 30; the other 20 are loss.
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({ capacity = 150, massLimit = 80, split = PCTS }, "w5db_w2", 138)
    local v = w.baler
    tick(v)
    relay(m, w, GRASS, 100, "g2")
    tick(v)
    local rem = opOf(host, "GROUND_BALER_REMAINDER")
    T.eq("W2 NAMED: the overflow is native's D - A = 10, read after the original, and the 20 L the mass limit refused are the close's loss",
        num(v.spec_baler.fillUnitOverflowFillLevel) .. "|" .. stockText(stockAt(sg, overflowId(v))) .. "|" .. num(rem and rem.evidence.loss),
        "10|NATIVE_BALER_OVERFLOW_V1|10|KNOWN|KNOWN:7:10/10/0/0/80|20")
    FSBaseMission.delete(m)

    -- A chamber change the host is still coalescing at the tick's start: a fill from empty is a
    -- boundary and flushes at once; a mid-fill add waits for the next flush (SGNativeHost:markDirty).
    resetWorld()
    soilReset()
    m, sg, host, w = boot5db({}, "w5db_w3", 139)
    v = w.baler
    v:addFillUnitFillLevel(1, 1, 20, GRASS, ToolType.UNDEFINED)
    v:addFillUnitFillLevel(1, 1, 20, GRASS, ToolType.UNDEFINED)
    local pending = #host.dirtyOrder
    tick(v)
    local s = stockAt(sg, unitId(v, 1))
    T.eq("W3 NAMED: the chamber's record is brought to native at the tick's start, so a change still waiting in the host's coalescing is not taken for the add's: the add settles clean onto 40 L",
        pending .. "/" .. num(s and s.observedAmount) .. "/" .. tostring(s and s.reason) .. "/" .. accText(s and s.properties[PID] and s.properties[PID].payload.account),
        "1/140/nil/140/100/40/0/30")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- I. THE COST OF A TICK: WORKAREA RAISES ITS EVENTS EVERY UPDATE TICK (WorkArea.lua:124-126)
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ lay = {} }, "w5db_i", 140)
    local v = w.baler
    local refreshes = 0
    local realRefresh = host.handle.refreshCarrier
    host.handle.refreshCarrier = function(...) refreshes = refreshes + 1 return realRefresh(...) end
    host.lastBalerTick = nil
    local wa = v.spec_workArea.workAreas
    ENGINE_RAISE(v, "onStartWorkAreaProcessing", 16, wa)
    ENGINE_RAISE(v, "onEndWorkAreaProcessing", 16, wa)
    T.eq("I1 NAMED: an idle Baler (its events raised, no work area processed) opens no tick and refreshes nothing",
        tostring(host.lastBalerTick) .. "/" .. liveCount(GO_.balerTicks) .. "/" .. refreshes, "nil/0/0")
    tick(v)
    T.eq("I2 NAMED: a working tick over empty ground opens and closes its tick with no operation, no carrier and no refresh",
        tostring(host.lastBalerTick ~= nil) .. "/" .. #host.lastBalerTick.operations .. "/" .. liveCount(NA.balerPickups) .. "/" .. refreshes, "true/0/0/0")
    host.handle.refreshCarrier = realRefresh
    FSBaseMission.delete(m)
end)

end
SG25DB_BENCH()
end
