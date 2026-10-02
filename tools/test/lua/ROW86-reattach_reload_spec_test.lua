-- ROW86-reattach_reload_spec_test.lua
--
-- DESIGN-CHECK rows 86, 164 and 172's NOT CARRIED reattach (GCC v1.5 :62; SG-2 v2.3 :364): a
-- condition account StockGuard carries in a native buffer reattaches across a save and reload to
-- the exact physical identity, configuration and quantity, else it is unknown. Bob's intake
-- (Desk Office/Drafts/BOB-INTAKE-ROW86-REATTACH-2026-10-02.md) found the reattach already lives in
-- SG-1's restoreCore, and MAINTENANCE row 206 (#37) made it hold for a level the engine saves as a
-- float. This bench is the reload bar for the live case, a part-filled framed square chamber; it
-- changes no source.
--
-- THE ENTRY-POINT BAR IS GROUP E: SG2-5d-b's world (main.lua's install, the live Baler class's
-- listeners, WorkArea's order, Soil's 5d surface as a stand-in with Soil's reader verbatim), one
-- tick into a 150 L chamber, then the savegame controller's own save path (careerSavegame.xml and
-- every mission vehicle through Vehicle:saveToXMLFile's specialization loop, StockGuard's envelope
-- through its save hook), with the XML model's FLOAT paths written as the engine writes them and
-- read back by either reader; the mission deleted, a fresh one on the save directory, the Baler
-- rebuilt and its fill unit loaded by FillUnit's onPostLoad; the barrier's restore; then the next
-- finish, reading the chamber's record. On 2f92a77 (before #37) E1 and E3 come back
-- RESTORE_MISMATCH and the finish reads no restored account.
--
-- NOT HERE: the bale's own value through Soil's real BalerCollection, which needs Soil's half of
-- the readback fix (MAINTENANCE row 207, Soil #1081): the joined two-sided run is a throwaway, and
-- the PR body carries its numbers.
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
local function ROW86_BENCH()

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

-- ── one save and reload of a part-filled square chamber ──────────────────────────────────
local function keyOf(m, v)
    for i, x in ipairs(m._vehicles) do if x == v then return string.format("vehicles.vehicle(%d)", i - 1) end end
    return nil
end
local function vehiclesFile(dir)
    for k, d in pairs(ENGINE_DISK) do if k == dir .. "/vehicles.xml" then return d end end
    return nil
end
local function lineWith(lines, pattern) for _, l in ipairs(lines) do if l:find(pattern, 1, true) then return l end end return nil end
--- 100 L of grass picked at fillScale `scale` (100.37 L at 1.0037) into a 150 L chamber in one tick, saved through the engine's own
--- save path, the mission quit, and a fresh one loaded with the Baler rebuilt from vehicles.xml
--- (FillUnit's onPostLoad, FillUnit.lua:369-371). edit(file, key) may change the saved
--- vehicle before the load. The record before and after, the load line, and what the finish
--- read after `more` litres fill the chamber.
local function round(scale, reader, dir, index, edit, more)
    READER = reader
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ capacity = 150, fillScale = scale, lay = { { GRASS, 100, "grass" } } }, dir, index)
    tick(w.baler)
    local before = stockAt(sg, unitId(w.baler, 1))
    local saved = { id = before and before.stockId, text = chamberText(sg, w.baler) }
    local key = keyOf(m, w.baler)
    nativeSave(m, dir)
    local file = vehiclesFile(dir)
    local written = file and file[key .. ".fillUnit.unit(0)#fillLevel"]
    if edit ~= nil and file ~= nil then edit(file, key) end
    local m2, sg2, host2, w2
    local lines = printed(function()
        m2, sg2, host2, w2 = reload(m, dir, function(mm, ww)
            soilOn(mm) soil5dOn(mm)
            ww.baler = vehicleIn(mm, newBaler("vehicle:baler", { capacity = 150, fillScale = scale }))
            local xml = REAL.XMLFile.load("vehiclesXML", dir .. "/vehicles.xml", REAL.Vehicle.xmlSchemaSavegame)
            ENGINE_POST_LOAD_VEHICLE(ww.baler, { xmlFile = xml, key = key, resetVehicles = false })
        end, { index = index })
    end)
    if g_server ~= nil and g_server.broadcastEvent == nil then g_server.broadcastEvent = function() end end
    m2.stockGuard.registerProperty(PID, AOWNER)
    local after = stockAt(sg2, unitId(w2.baler, 1))
    local r = {
        written = written, level = w2.baler:getFillUnitFillLevel(1), saved = saved.text,
        reattached = after ~= nil and after.stockId == saved.id, after = stockText(after), line = lineWith(lines, "restored stocks:"),
    }
    if more ~= nil then
        local seen = probeFinish(sg2, w2.baler)
        relay(m2, w2, GRASS, more, "g2")
        tick(w2.baler)
        r.finish = seen[1]
        r.bales = #BALES.made
    end
    FSBaseMission.delete(m2)
    return r
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A PART-FILLED SQUARE CHAMBER THROUGH A SAVE AND A FRESH MISSION
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local a = round(1.0037, "float32", "r86e1", 201, nil, 50)
    T.eq("E0 [reached] one tick of 100 L at fillScale 1.0037 filled the chamber with 100.37 L known at 30 %, and the engine wrote its level as the float32 to six decimals",
        a.saved .. " / " .. tostring(a.written), "GRASS_WINDROW|100.37|KNOWN|KNOWN:7:100.37/100.37/0/0/30 / 100.370003")
    T.eq("E1 NAMED [entry point]: read back as a float32 (100.37000274658203), the chamber's stock REATTACHES with its record, and the load line counts it",
        string.format("%.17g", a.level) .. " " .. tostring(a.reattached) .. " " .. a.after .. " | " .. tostring(a.line and a.line:match("%d+ reattached, %d+ mismatched")),
        "100.37000274658203 true GRASS_WINDROW|100.37|KNOWN|KNOWN:7:100.37/100.37/0/0/30 | " .. "1 reattached, 0 mismatched")
    T.eq("E2 NAMED: the finish after the reload (50 L more at the same scale) reads the restored account: 150 L known at the pre-save 30 %, one bale",
        tostring(a.finish) .. "/" .. tostring(a.bales), "GRASS_WINDROW|150|KNOWN|KNOWN:7:150/150/0/0/30/1")
    local b = round(1.0037, "double", "r86e3", 202, nil, 50)
    T.eq("E3 NAMED: read back as a double (100.370003), the same reattach and the same finish",
        string.format("%.17g", b.level) .. " " .. tostring(b.reattached) .. " " .. tostring(b.finish), "100.370003 true GRASS_WINDROW|150|KNOWN|KNOWN:7:150/150/0/0/30")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. CONTROLS: A WHOLE-NUMBER LEVEL; A LEVEL OR A MATERIAL CHANGED BETWEEN THE SAVE AND THE LOAD
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local c1 = round(1, "float32", "r86c1", 203, nil, nil)
    T.eq("C1 [control] a whole-number chamber reattaches", tostring(c1.written) .. " " .. tostring(c1.reattached), "100.000000 true")
    local stepped = writeFloat(f32(100.37) + 2 ^ -17)
    local c2 = round(1.0037, "float32", "r86c2", 204, function(file, key) file[key .. ".fillUnit.unit(0)#fillLevel"] = stepped end, nil)
    T.eq("C2 a chamber one float32 step away at load (" .. stepped .. ") is RESTORE_MISMATCH: UNKNOWN, no record carried",
        tostring(c2.reattached) .. " " .. c2.after .. " | " .. tostring(c2.line and c2.line:match("%d+ reattached, %d+ mismatched")),
        "false GRASS_WINDROW|100.37|UNKNOWN|noRecord | 0 reattached, 1 mismatched")
    local c3 = round(1.0037, "float32", "r86c3", 205, function(file, key) file[key .. ".fillUnit.unit(0)#fillType"] = "DRYGRASS_WINDROW" end, nil)
    T.eq("C3 the same level of another material at load is RESTORE_MISMATCH", tostring(c3.reattached) .. " " .. tostring(c3.line and c3.line:match("%d+ reattached, %d+ mismatched")),
        "false 0 reattached, 1 mismatched")
end)
end
ROW86_BENCH()
end
