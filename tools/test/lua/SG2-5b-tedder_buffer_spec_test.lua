-- SG2-5b-tedder_buffer_spec_test.lua
--
-- SG2-5 slice 5b (Bob's tedder shape ruling, BOB-RULING-SG2-5B-TEDDER-SHAPE-2026-10-02): a Tedder work
-- area's one processing call runs inside a TEDDER ground frame whose unit is the work area's
-- PERSISTENT tedderBuffer carrier (SGNativeAdapters): bound at the first pickup that removed
-- material, live across calls, its amount workArea.litersToDrop exactly plus the current pass's
-- pickups native has not folded yet (Tedder.lua:296-297), its material the target type of what it
-- holds. Each pickup feeds its converter's target; a GRASS_WINDROW pickup into dry grass carries
-- the profile's basis NATIVE_HAY_CONVERT_V1 on the buffer's leg (SG-2 :652), an input already of
-- the target's type carries none, any other converting pair is UNAVAILABLE, and a retarget of a
-- held remainder is unknown (SG-2 :199). The drop carries the buffer stock's record (5-0b). An
-- emptied buffer is withdrawn at the close; a vehicle's live remainder goes as destruction
-- through a REMOVE (SG-2 :136).
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world, with SG2-4c-1's recorder
-- of Soil's published surface and a stand-in `soil.groundCondition` owner whose transform carries
-- combine's floor under the hay basis, as Soil #1076 does (the preamble of the SG2-5a bench,
-- verbatim, plus the windrow types as a model extension).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path; the native host observes a Tedder at the
-- barrier and SGWorkAreaInstaller brackets the work area's CAPTURED processing pointer (WorkArea.lua
-- :266); the engine's own call order then runs it: onStartWorkAreaProcessing (Tedder.lua:360-362,
-- verbatim) and the captured pointer (processTedderArea :279-350 and processDropArea :351-358,
-- verbatim through the quantities) over a grass windrow a tipper laid. The two-sided bar against
-- Soil's own tedder carrier and HayBet is the joined run outside the repo (the PR body names it).
--
--!env: modenv), on the SG2-4b world, with SG2-4c-1's recorder
-- of Soil's published surface and 5-0b's stand-in soil.groundCondition owner (the preamble of the
-- SG2-5-0b bench, verbatim).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path; the native host observes a Windrower at the
-- barrier and SGWorkAreaInstaller brackets the work area's CAPTURED processing pointer (WorkArea.lua
-- :266); the engine's own call order then runs it: onStartWorkAreaProcessing (Windrower.lua:285-290,
-- verbatim) and the captured pointer (processWindrowerArea :309-359 and processDropArea :393-397,
-- verbatim through the quantities; the stone, wear, test-area and effect lines left out) over a
-- windrow the tipper laid. WHEAT and BARLEY stand in for the windrow types: the ground model has
-- height types for those two only.
--
-- Groups:
--   E  the entry-point bar: one call, picked and dropped, Soil admitted, the drop carrying the area's
--      record, the area withdrawn, the returns preserved, litersToDrop the engine's own
--   R  a remainder the drop did not take is one REMOVE with a LOSS leg (picked, dropped, remainder)
--   C  the area's retirements keep their own budget: many calls never evict a trailer's history
--   U  the live-only kind: nothing outside a frame, never restored, never enumerated
--   G  the unproved coalesce: a second pickup type in one call (the dual branch, :336-341, reached
--      only by skipping the engine's reset) is refused and the drop sends no contributions
--   S  Soil absent: StockGuard's own operations are unchanged
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
Tedder = Tedder or {}
-- :360-362 VERBATIM.
function Tedder:onStartWorkAreaProcessing(_)
    self.spec_tedder.lastDroppedLiters = 0
end
-- :279-350 VERBATIM through the quantities; the effect, sound, dirty-flag and stone lines out. The
-- decompile prints `local targetFillType = workArea.lastDropFillType` at :294, a shadow that would do
-- nothing; SG-2 :199 names the zero-pickup lastDropFillType substitution, so this port assigns it.
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

--- A tedder: work area 1 picks up over x -1..1 at z 0 and drops into work area 2 at x 8..10.
--- The converters as Tedder:onLoad builds them (:47-65): forward, and reverse by target. `targets`
--- lists the targets in the order the bench needs (each a list of its inputs).
local function newTedder(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = 0, capacity = 0, supported = {} })
    v.configFileName = "data/vehicles/tedder.xml"
    v.isServer = true
    v.lastMovedDistance = 1
    v.processTedderArea = Tedder.processTedderArea
    v.processDropArea = Tedder.processDropArea
    local forward, reverse = {}, {}
    for _, t in ipairs(opts.targets or { { DRY, { GRASS, DRY } } }) do
        reverse[t[1]] = {}
        for _, input in ipairs(t[2]) do
            forward[input] = { targetFillTypeIndex = t[1] }
            table.insert(reverse[t[1]], input)
        end
    end
    v.spec_tedder = { fillTypeConverters = forward, fillTypeConvertersReverse = reverse, lastDroppedLiters = 0 }
    local pickup = { index = 1, functionName = "processTedderArea", dropWindrowWorkAreaIndex = opts.noDrop and 3 or 2,
                     start = { x = -1, y = 0, z = -0.5 }, width = { x = 1, y = 0, z = -0.5 }, height = { x = -1, y = 0, z = 0.5 },
                     litersToDrop = 0, lastPickupLiters = 0, lastDropFillType = FillType.UNKNOWN, lastDroppedLiters = 0 }
    pickup.processingFunction = v.processTedderArea
    local drop = { index = 2, functionName = "processDropArea", lineOffset = 0,
                   start = { x = 8, y = 0, z = -0.5 }, width = { x = 10, y = 0, z = -0.5 }, height = { x = 8, y = 0, z = 0.5 } }
    v.spec_workArea = { workAreas = { pickup, drop } }
    return v, pickup
end
--- WorkArea's tick for one area, in the engine's order: the start event, then the captured pointer.
local function tick(v, workArea)
    Tedder.onStartWorkAreaProcessing(v, nil)
    return workArea.processingFunction(v, workArea, 16)
end
--- A tipper of `ft` over the pickup line, tipping `litres` there.
local function lay(m, w, ft, litres, key)
    local t = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. key, { level = litres, fillType = ft, at = { x = 0, z = 0 },
        supported = { [GRASS] = true, [DRY] = true, [STRAW_W] = true, [WHEAT] = true } }))
    w[key] = t
end
local function tedderWorld(opts)
    return function(m, w)
        soilOn(m)
        for _, l in ipairs(opts.lay or { { GRASS, 100, "grass" } }) do lay(m, w, l[1], l[2], l[3]) end
        w.tedder, w.area = newTedder("vehicle:tedder", opts)
        vehicleIn(m, w.tedder)
    end
end
local function opsOf(host)
    local out = {}
    for _, op in ipairs(host.lastGroundFrame and host.lastGroundFrame.operations or {}) do
        out[#out + 1] = tostring(op.evidence and op.evidence.nativePath) .. ":" .. tostring(op.outcome)
    end
    return table.concat(out, " ")
end
local function groundTotal(sg)
    local t = 0
    for _, s in ipairs(groundStocks(sg)) do t = t + s.observedAmount end
    return t
end
local function bufferId(w) return cid(NA.tedderBufferBinding(w.tedder, 1)) end
local function bufferStock(sg, w) return stockAt(sg, bufferId(w)) end
local function bufferText(sg, w)
    local s = bufferStock(sg, w)
    if s == nil then return "none" end
    local p = s.properties[PID]
    return table.concat({ tostring(s.materialRef and s.materialRef.fillTypeName), num(s.observedAmount), tostring(s.knowledge),
        p == nil and "noRecord" or (tostring(p.knowledge) .. ":" .. num(p.payload and p.payload.c)) }, "/")
end
local function liveBuffers() local n = 0 for _ in pairs(NA.tedderBuffers) do n = n + 1 end return n end
--- The distinct bases on the legs of the frame's operations into the buffer ("none" for a leg with
--- none), and whether there was any such leg.
local function basesOf(host, w)
    local seen, out, n = {}, {}, 0
    for _, op in ipairs(host.lastGroundFrame and host.lastGroundFrame.operations or {}) do
        for _, a in ipairs(op.report and op.report.allocations or {}) do
            if a.destination.carrierId == bufferId(w) then
                n = n + 1
                local b = a.conversionBasisId == nil and "none" or a.conversionBasisId
                if not seen[b] then seen[b] = true out[#out + 1] = b end
            end
        end
    end
    table.sort(out)
    return (n > 0 and "legs" or "nolegs") .. ":" .. table.concat(out, ",")
end
--- Soil's stand-in, with #1076's rule: transform carries combine's floor when at least one contribution
--- is on the hay basis and none on another (GroundConditionProperty.carriesThroughConversion).
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
local function boot5b(opts, key, index)
    local m, sg, host, w = boot(tedderWorld(opts or {}), key, { index = index })
    m.stockGuard.registerProperty(PID, TOWNER)
    for _, l in ipairs((opts or {}).lay or { { GRASS, 100, "grass" } }) do ENGINE_TIP(w[l[3]], l[2]) end
    return m, sg, host, w
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: ONE TEDDER CALL OVER A GRASS WINDROW
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({}, "w5b_e", 81)
    local wa = w.area
    T.ok("E0 [reached] the native host bracketed the Tedder work area's CAPTURED pointer (WorkArea.lua:266)",
        wa.processingFunction ~= Tedder.processTedderArea and wa._sgBrackets ~= nil and wa._sgBrackets.processTedderArea ~= nil
            and wa._sgBrackets.processTedderArea.original == Tedder.processTedderArea)
    local onGround0 = groundTotal(sg)
    soilReset()
    local a1, a2 = tick(w.tedder, wa)
    T.eq("E1 [world] the pass picked the grass windrow, dropped it as dry grass, and kept nothing; the pointer's returns are the engine's",
        tostring(wa.lastPickupLiters > 0) .. "/" .. tostring(wa.lastDropFillType == DRY) .. "/" .. num(wa.litersToDrop) .. "/" .. tostring(a1 == a2 and a1 > 0),
        "true/true/0/true")
    T.eq("E2 NAMED: Soil was asked for each primitive inside the TEDDER frame: the two pickups (grass, then dry grass) and the drop",
        fns() .. "/" .. tostring(host.lastGroundFrame.kind), "admit(4) deliver(2) close(1) admit(4) deliver(2) close(1) admit(4) deliver(2) close(1)/TEDDER")
    T.eq("E3 NAMED: StockGuard's own operations: the grass pickup into the buffer on the hay basis, then the drop, both COMMITTED",
        opsOf(host) .. "|" .. basesOf(host, w), "GROUND_TEDDER:COMMITTED GROUND_TEDDER:COMMITTED|legs:" .. HAY)
    local d = lastDeliver()
    T.eq("E4 NAMED: the drop carries the buffer stock's record, carried through the conversion by the owner's transform: KNOWN 7",
        contribText(d and d.obs), "1/litres=returned:soil.groundCondition:KNOWN:7")
    T.eq("E5 the emptied buffer is withdrawn at the close, nothing stays live, and the ground holds what it held",
        tostring(sg.operations.carriers[bufferId(w)] == nil) .. "/" .. liveBuffers() .. "/" .. num(groundTotal(sg)), "true/0/" .. num(onGround0))
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PERSISTENT BUFFER: A REMAINDER RIDES INTO THE NEXT CALL
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    resetWorld()
    soilReset()
    -- The drop area cannot take it all: the line's overflow lands nowhere (the ground model drops
    -- only where it has room), so native keeps a remainder in litersToDrop.
    local m, sg, host, w = boot5b({ noDrop = true }, "w5b_p", 82)
    local wa = w.area
    tick(w.tedder, wa)
    local held = wa.litersToDrop
    T.eq("P1 NAMED: with no drop area, the pass's pickup stays in the buffer: a persistent carrier holding exactly litersToDrop, as dry grass, KNOWN 7",
        tostring(held > 0) .. "/" .. tostring(bufferStock(sg, w) ~= nil and bufferStock(sg, w).observedAmount == held) .. "/" .. bufferText(sg, w),
        "true/true/DRYGRASS_WINDROW/" .. num(held) .. "/KNOWN/KNOWN:7")
    T.eq("P2 it stays live after the close (not withdrawn), unlike the Windrower's area", tostring(sg.operations.carriers[bufferId(w)] ~= nil) .. "/" .. liveBuffers(), "true/1")
    -- The next call, with the drop area back: the remainder drops with the new pickup.
    w.tedder.spec_workArea.workAreas[1].dropWindrowWorkAreaIndex = 2
    soilReset()
    tick(w.tedder, wa)
    T.eq("P3 NAMED: the next call's pass drops the remainder it carried; the buffer empties and is withdrawn",
        num(wa.litersToDrop) .. "/" .. tostring(sg.operations.carriers[bufferId(w)] == nil) .. "/" .. liveBuffers(), "0/true/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. AN INPUT ALREADY OF THE TARGET'S TYPE IS A PLAIN TRANSFER; ONE PASS MIXES BOTH
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({ lay = { { DRY, 100, "dry" } } }, "w5b_t1", 83)
    tick(w.tedder, w.area)
    T.eq("T1 NAMED: dry grass picked into a dry-grass pass moves with no basis (a TRANSFER), and the drop carries KNOWN 7",
        basesOf(host, w) .. "|" .. contribText(lastDeliver() and lastDeliver().obs), "legs:none|1/litres=returned:soil.groundCondition:KNOWN:7")
    FSBaseMission.delete(m)
    resetWorld()
    soilReset()
    m, sg, host, w = boot5b({ lay = { { GRASS, 100, "grass" }, { DRY, 100, "dry" } } }, "w5b_t2", 84)
    tick(w.tedder, w.area)
    T.eq("T2 NAMED: one pass over grass and dry grass: the grass legs carry the hay basis, the dry-grass legs none, and the whole drop lands KNOWN 7",
        basesOf(host, w) .. "|" .. contribText(lastDeliver() and lastDeliver().obs), "legs:" .. HAY .. ",none|1/litres=returned:soil.groundCondition:KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. A CONVERTER PAIR THE PROFILE DOES NOT ADMIT
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    resetWorld()
    soilReset()
    -- A map or mod converter: straw windrow into dry grass. Not :652's pair.
    local m, sg, host, w = boot5b({ lay = { { STRAW_W, 100, "straw" } }, targets = { { DRY, { STRAW_W } } } }, "w5b_x", 85)
    tick(w.tedder, w.area)
    local first = host.lastGroundFrame.operations[1]
    T.eq("X1 NAMED: the unadmitted pair's pickup is refused at its settle (CONVERTER_PAIR_UNADMITTED): its quantity is UNAVAILABLE, never carried on the hay basis",
        tostring(first and first.outcome) .. "/" .. tostring(first and first.reason) .. "|" .. basesOf(host, w), "ABANDONED/CONVERTER_PAIR_UNADMITTED|nolegs:")
    local d = lastDeliver()
    T.eq("X2 the drop then carries no record for that material, so Soil lands it unknown", contribText(d and d.obs), "1/litres=returned:nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. A FOREIGN PICKUP INSIDE A TEDDER CALL; TWO PASSES IN ONE CALL
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    resetWorld()
    soilReset()
    -- A type with no converter target joins the pass's line calls (another mod's pickup in the same
    -- call; here a reverse list naming an input with no forward converter): it is no Tedder input.
    local m, sg, host, w = boot5b({ lay = { { GRASS, 100, "grass" }, { WHEAT, 100, "wheat" } }, targets = { { DRY, { GRASS } } } }, "w5b_f", 96)
    table.insert(w.tedder.spec_tedder.fillTypeConvertersReverse[DRY], WHEAT)
    tick(w.tedder, w.area)
    local first = host.lastGroundFrame.operations[1]
    local d = lastDeliver()
    local r = d and d.obs and d.obs.contributions and d.obs.contributions[1] and d.obs.contributions[1].record or nil
    T.eq("F1 NAMED: the foreign pickup is refused (NO_CONVERTER_TARGET) and starts no pass: the grass pickup settles whole into the buffer, and the wheat native added is unexplained there (the drop is PARTIAL, never KNOWN)",
        tostring(host.lastGroundFrame.refused.NO_CONVERTER_TARGET) .. "/" .. tostring(first and first.outcome) .. "/" .. num(first and first.evidence and first.evidence.loss) .. "|" .. tostring(r and r.knowledge),
        "1/COMMITTED/0|PARTIAL")
    FSBaseMission.delete(m)
    resetWorld()
    soilReset()
    m, sg, host, w = boot5b({ lay = { { GRASS, 100, "grass" }, { STRAW_W, 100, "straw" } }, targets = { { DRY, { GRASS } }, { STRAW_W, { STRAW_W } } } }, "w5b_m", 97)
    soilReset()
    tick(w.tedder, w.area)
    local ds = delivers()
    local out = {}
    for _, dd in ipairs(ds) do if dd.obs and (dd.obs.litresReturned or 0) > 0 then out[#out + 1] = contribText(dd.obs) end end
    T.eq("M1 NAMED: two passes in one call (dry grass, then straw, either order): each drops its own pickup KNOWN 7, and the second pass takes the empty buffer with no retarget",
        tostring(host.lastGroundFrame.tedder.retargets) .. "|" .. table.concat(out, " "),
        "0|1/litres=returned:soil.groundCondition:KNOWN:7 1/litres=returned:soil.groundCondition:KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- RT. A RETARGET BETWEEN UNLIKE TARGETS IS UNKNOWN, BOTH WAYS (SG-2 :199)
-- ══════════════════════════════════════════════════════════════════════════
local function retarget(fromTarget, fromInput, toTarget, toInput, key, index)
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({ noDrop = true, lay = { { fromInput, 100, "first" }, { toInput, 100, "second" } },
        targets = { { fromTarget, { fromInput } } } }, key, index)
    -- The first call's converter lists only its own input, so the second windrow stays for the second call.
    tick(w.tedder, w.area)
    local st = bufferStock(sg, w)
    local p = st and st.properties[PID] or nil
    local held = tostring(st and st.materialRef and st.materialRef.fillTypeName) .. "/" .. tostring(st and st.knowledge) .. "/" .. tostring(p and p.knowledge)
    -- The next call runs the other target's pass over a fresh windrow, with its drop area back.
    w.tedder.spec_tedder.fillTypeConverters = { [toInput] = { targetFillTypeIndex = toTarget } }
    w.tedder.spec_tedder.fillTypeConvertersReverse = { [toTarget] = { toInput } }
    w.tedder.spec_workArea.workAreas[1].dropWindrowWorkAreaIndex = 2
    soilReset()
    tick(w.tedder, w.area)
    local d = lastDeliver()
    local c = d and d.obs and d.obs.contributions and d.obs.contributions[1] or nil
    local r = c and c.record or nil
    -- The remainder's litres are not known after the retarget: the record covers the new pass's only.
    local share = (r ~= nil and r.basisAmount ~= nil and r.basisAmount > 0) and (r.knownAmount / r.basisAmount) or nil
    local out = held .. "|" .. tostring(host.lastGroundFrame.tedder.retargets) .. "|" .. tostring(r and r.knowledge) .. ":" .. tostring(share ~= nil and share < 0.99)
    FSBaseMission.delete(m)
    return out
end
group("RT", function()
    T.eq("RT1 NAMED: a dry-grass remainder taken by a straw pass is retargeted once and its litres are unknown at the drop (the record covers the straw only), never carried as straw",
        retarget(DRY, GRASS, STRAW_W, STRAW_W, "w5b_rt1", 86), "DRYGRASS_WINDROW/KNOWN/KNOWN|1|PARTIAL:true")
    T.eq("RT2 NAMED: a straw remainder taken by a dry-grass pass is retargeted once and unknown at the drop the same way",
        retarget(STRAW_W, STRAW_W, DRY, GRASS, "w5b_rt2", 87), "STRAW_WINDROW/KNOWN/KNOWN|1|PARTIAL:true")
    -- A retarget AT A DROP: the last drop was straw, then a no-drop dry-grass pass leaves a dry-grass
    -- remainder, then a straw pass that picks nothing drops it under the last drop's type, straw.
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({ lay = { { STRAW_W, 100, "straw" }, { GRASS, 100, "grass" } }, targets = { { STRAW_W, { STRAW_W } } } }, "w5b_rt3", 95)
    local wa = w.area
    tick(w.tedder, wa)                                                         -- straw dropped: lastDropFillType = STRAW
    w.tedder.spec_tedder.fillTypeConverters = { [GRASS] = { targetFillTypeIndex = DRY } }
    w.tedder.spec_tedder.fillTypeConvertersReverse = { [DRY] = { GRASS } }
    w.tedder.spec_workArea.workAreas[1].dropWindrowWorkAreaIndex = 3
    tick(w.tedder, wa)                                                         -- a dry-grass remainder, no drop
    local held = wa.litersToDrop
    w.tedder.spec_tedder.fillTypeConverters = { [STRAW_W] = { targetFillTypeIndex = STRAW_W } }
    w.tedder.spec_tedder.fillTypeConvertersReverse = { [STRAW_W] = { STRAW_W } }
    w.tedder.spec_workArea.workAreas[1].dropWindrowWorkAreaIndex = 2
    soilReset()
    tick(w.tedder, wa)
    local d = lastDeliver()
    T.eq("RT3 NAMED: a dry-grass remainder dropped under the last drop's type (straw) is retargeted before the drop and lands with no record (unknown at Soil)",
        tostring(held > 0) .. "/" .. tostring(wa.lastDropFillType == STRAW_W) .. "/" .. tostring(host.lastGroundFrame.tedder.retargets) .. "|" .. contribText(d and d.obs),
        "true/true/1|1/litres=returned:nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. THE ZERO-PICKUP SUBSTITUTION IS NOT A RETARGET (Tedder.lua:293-295, SG-2 :199)
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({}, "w5b_z", 88)
    local wa = w.area
    tick(w.tedder, wa)                                   -- dropped as dry grass: lastDropFillType = DRY
    w.tedder.spec_workArea.workAreas[1].dropWindrowWorkAreaIndex = 3
    w.grass.spec_fillUnit.fillUnits[1].fillLevel, w.grass.spec_fillUnit.fillUnits[1].fillType = 100, GRASS
    ENGINE_TIP(w.grass, 100)
    tick(w.tedder, wa)                                   -- no drop area: a dry-grass remainder stays
    local held = wa.litersToDrop
    -- A straw pass that picks nothing: native drops the remainder under the LAST drop's type.
    w.tedder.spec_tedder.fillTypeConverters = { [STRAW_W] = { targetFillTypeIndex = STRAW_W } }
    w.tedder.spec_tedder.fillTypeConvertersReverse = { [STRAW_W] = { STRAW_W } }
    w.tedder.spec_workArea.workAreas[1].dropWindrowWorkAreaIndex = 2
    soilReset()
    tick(w.tedder, wa)
    local d = lastDeliver()
    T.eq("Z1 NAMED: a straw pass that picks nothing drops the dry-grass remainder as dry grass, its condition carried (no false retarget)",
        tostring(held > 0) .. "/" .. tostring(wa.lastDropFillType == DRY) .. "/" .. tostring(host.lastGroundFrame.tedder.retargets) .. "|" .. contribText(d and d.obs),
        "true/true/0|1/litres=returned:soil.groundCondition:KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A VEHICLE'S LIVE REMAINDER GOES AS DESTRUCTION (SG-2 :136)
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({ noDrop = true }, "w5b_d", 89)
    tick(w.tedder, w.area)
    local id = bufferId(w)
    local held = bufferStock(sg, w) and bufferStock(sg, w).observedAmount or 0
    VehicleSystem.removeVehicle(m.vehicleSystem, w.tedder)
    local ls = host.lastSettlement
    local a = ls and ls.report and ls.report.allocations and ls.report.allocations[1] or {}
    T.eq("D1 NAMED: removing the tedder retires its remainder through a REMOVE with a DESTRUCTION leg of the whole amount, then withdraws the carrier",
        tostring(held > 0) .. "/" .. tostring(ls and ls.report and ls.report.outcomeEvidence and ls.report.outcomeEvidence.nativePath) .. "/" .. tostring(ls and ls.outcome)
            .. "/" .. tostring(a.result) .. "/" .. tostring(a.reason) .. "/" .. tostring(num(a.sourceAmount) == num(held)) .. "/" .. tostring(sg.operations.carriers[id] == nil) .. "/" .. liveBuffers(),
        "true/TEDDER_BUFFER_DESTRUCTION/COMMITTED/DESTRUCTION/VEHICLE_REMOVED/true/true/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. NATIVE'S NUMBER, EXACTLY: A RESIDUE STAYS
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({ noDrop = true }, "w5b_n", 90)
    local wa = w.area
    tick(w.tedder, wa)
    -- A drop that falls 0.0004 L short of a raw unit leaves native that residue (DensityMapHeightUtil
    -- returns what it placed when the shortfall is not under 0.001 L, :296-299). The bench's ground
    -- moves whole raw units, so the residue is set as such a drop would leave it.
    wa.litersToDrop = 0.0004
    -- The next call admits no line (its one input has no converter target: a foreign type), so only
    -- the close brings the buffer to what native holds.
    w.tedder.spec_tedder.fillTypeConverters = {}
    w.tedder.spec_tedder.fillTypeConvertersReverse = { [DRY] = { WHEAT } }
    tick(w.tedder, wa)
    local s = bufferStock(sg, w)
    T.eq("N1 NAMED: a sub-unit residue native keeps is the buffer's, exactly: at the close the carrier holds 0.0004 L and stays bound (no epsilon of its own)",
        tostring(host.lastGroundFrame.refused.NO_CONVERTER_TARGET) .. "/" .. tostring(sg.operations.carriers[bufferId(w)] ~= nil) .. "/" .. tostring(s ~= nil and s.observedAmount == 0.0004) .. "/" .. liveBuffers(),
        "1/true/true/1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE BUFFER'S RETIREMENTS KEEP THEIR OWN BUDGET
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({}, "w5b_c", 91)
    local tipperRetired = 0
    for _, s in pairs(sg.operations.retiredStocks) do if s.carrierId == unitId(w.grass) then tipperRetired = tipperRetired + 1 end end
    local limit = sg.operations.retiredLimit
    sg.operations.retiredLimit = 4
    for _ = 1, 8 do
        tick(w.tedder, w.area)
        -- Move the dropped windrow back under the pickup: the next call has material again.
        local wa, dropArea = w.area, w.tedder.spec_workArea.workAreas[2]
        wa.start.x, wa.width.x, wa.height.x = wa.start.x + 9, wa.width.x + 9, wa.height.x + 9
        dropArea.start.x, dropArea.width.x, dropArea.height.x = dropArea.start.x + 9, dropArea.width.x + 9, dropArea.height.x + 9
    end
    local mine, tipperKept = 0, 0
    for _, s in pairs(sg.operations.retiredStocks) do
        if NA.isTedderBufferKey(s.carrierKey) then mine = mine + 1 end
        if s.carrierId == unitId(w.grass) then tipperKept = tipperKept + 1 end
    end
    sg.operations.retiredLimit = limit
    T.eq("C1 NAMED: every emptying drop retires a buffer stock in its own class (held to its budget), and the tipper's retired history is never evicted",
        tostring(tipperRetired >= 1) .. "/" .. tostring(mine >= 1 and mine <= 4) .. "/" .. tostring(tipperKept == tipperRetired), "true/true/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE KIND: NATIVE-BACKED, NEVER RESTORED, NEVER ENUMERATED
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({ noDrop = true }, "w5b_u", 92)
    local spec = host.nativeLease.spec
    local binding = NA.tedderBufferBinding(w.tedder, 1)
    local function answer(fn, ...) local r = { pcall(fn, ...) } if not r[1] then return "RAISED" end return tostring(r[2]) .. "/" .. tostring(r[3]) end
    T.eq("U1 before its first pickup the buffer resolves to nothing (NOT_BOUND)", answer(spec.resolveCarrier, binding), "nil/NOT_BOUND")
    tick(w.tedder, w.area)
    local native = spec.resolveCarrier(binding)
    local ns = native and spec.readNativeState(binding, native) or nil
    T.eq("U2 NAMED: bound, its native state is litersToDrop exactly, as the target's material, in a vehicle buffer",
        tostring(ns and ns.amount == w.area.litersToDrop) .. "/" .. tostring(ns and ns.materialRef and ns.materialRef.fillTypeName) .. "/" .. tostring(ns and ns.storeKind),
        "true/DRYGRASS_WINDROW/vehicle_buffer")
    T.eq("U3 NAMED: it is never restored and never enumerated (SG-2 :144's save is a later slice)",
        answer(spec.restoreBinding, binding, {}) .. "/" .. #spec.kinds[NA.KIND_TEDDER_BUFFER].enumerateCarriers(), "nil/NOT_RESTORABLE/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. SERVER ONLY; SOIL ABSENT
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5b({}, "w5b_k", 93)
    soilReset()
    local before = host.lastGroundFrame
    local server = REAL.g_server
    REAL.g_server = nil
    local ok = pcall(tick, w.tedder, w.area)
    REAL.g_server = server
    T.eq("K1 NAMED: on a client (inside the update radius, Tedder.lua:281-283) the work area runs, and no frame or lease opens",
        tostring(ok) .. "/" .. tostring(host.lastGroundFrame == before) .. "/" .. fns(), "true/true/")
    FSBaseMission.delete(m)
    resetWorld()
    soilReset()
    m, sg, host, w = boot(function(m, w)
        lay(m, w, GRASS, 100, "grass")
        w.tedder, w.area = newTedder("vehicle:tedder")
        vehicleIn(m, w.tedder)
    end, "w5b_alone", { index = 94 })
    ENGINE_TIP(w.grass, 100)
    soilReset()
    tick(w.tedder, w.area)
    T.eq("K2 without Soil: nothing is asked, and StockGuard's own operations are the same", fns() .. "/" .. opsOf(host), "/GROUND_TEDDER:COMMITTED GROUND_TEDDER:COMMITTED")
    FSBaseMission.delete(m)
end)
end
