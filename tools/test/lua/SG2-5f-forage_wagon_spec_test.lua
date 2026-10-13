-- SG2-5f-forage_wagon_spec_test.lua
--
-- SG2-5 slice 5f (Bob's intake, Desk Office/Drafts/BOB-INTAKE-SG2-5F-FORAGE-WAGON-2026-10-07.md, and his
-- R-15 of 2026-10-09 with its appended readings; SG-2 v2.3 :144, :249, :288, :298, :344, :364, :370,
-- :653, :667): a ForageWagon's pickup call runs inside StockGuard's FORAGE frame, its fill inside a
-- FORAGE_FILL frame, and its one buffer (workAreaParameters.litersToFill) survives a save.
--   * the pickup call's lines admitted with Soil and captured ONCE at the call's close: the cells to the
--     buffer at what native PRODUCED (r_i x P / R), no conversion basis, the fold declared in the
--     evidence (NATIVE_FORAGE_WINDROW_FOLD, NATIVE_FORAGE_COALESCE_V1); the additive's debit its own
--     unit's decrease; one batch per removing line sealed at P, the account split over the cell legs;
--   * the fill: ONE TRANSFER at A, the fill call's own accepted delta; the trim a LOSS; a full unit's
--     remainder kept; another type in the unit discarded;
--   * the retarget: the pair's rename carried by the buffer's own leg, a rename outside it replaced
--     under FORAGE_RETARGET_UNPROVED before the pickup (the Tedder's form);
--   * the save: the buffer and its stock back after onLoad, a refused load leaving the stock history.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-5d-b bench's preamble and its Soil 5d
-- stand-ins VERBATIM (the recorder of Soil's published surface, the delivery's collection, Soil's
-- collected reader, the owner carrying Soil's account), the collection given to any collection machine
-- as Soil's isCollector does (GroundConditionAdmission.lua:496-497), plus the engine's ForageWagon
-- (VERBATIM through its quantity path) and Soil's own ForageWagon frame as a stand-in of its
-- admission-count rule.
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path wraps the live ForageWagon class (its fill
-- listener, its saver, its restore after onLoad) and the native host brackets the pickup's CAPTURED
-- pointer (WorkArea.lua:266) outside Soil's own wrapper; WorkArea's own order then runs a tick over grass
-- and hay windrows tippers laid. Group S's S1 drives the save path from the savegame controller to a
-- fresh mission's vehicle load. The two-sided bar against Soil's real ForageWagonCollection is the
-- joined run outside the repo (the PR body names it).
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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
local NAMES = { [WHEAT] = "WHEAT", [BARLEY] = "BARLEY", [4] = "GRASS", [5] = "STRAW", [GRASS] = "GRASS_WINDROW", [DRY] = "DRYGRASS_WINDROW", [STRAW_W] = "STRAW_WINDROW", [99] = "SILAGE_ADDITIVE" }
REAL.g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(NAMES) do if v == n then return i end end return nil end,
}
FillType.GRASS_WINDROW, FillType.DRYGRASS_WINDROW, FillType.STRAW_WINDROW = GRASS, DRY, STRAW_W
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

-- Inside one function: the preamble's file-level locals with this part's would pass Lua's 200-local
-- limit for a single function.
local function SG25F_BENCH()

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
        if type(result) == "table" and type(v) == "table" and (v.spec_baler ~= nil or v.spec_forageWagon ~= nil) and type(obs) == "table" and obs.ok and (obs.litresReturned or 0) < 0 then
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

-- ══════════════════════════════════════════════════════════════════════════
-- SG2-5f: the ForageWagon, its buffer and its save
-- ══════════════════════════════════════════════════════════════════════════
local ADD = 99
-- FillTypeManager:getFillTypesByNames, MODELED: space-separated names to their indices.
REAL.g_fillTypeManager.getFillTypesByNames = function(self, names)
    local out = {}
    for n in string.gmatch(names or "", "%S+") do local i = self:getFillTypeIndexByName(n) if i ~= nil then out[#out + 1] = i end end
    return out
end
-- SpecializationUtil.removeEventListener, MODELED: the class leaves the object's listener list.
REAL.SpecializationUtil = REAL.SpecializationUtil or {}
REAL.SpecializationUtil.removeEventListener = REAL.SpecializationUtil.removeEventListener or function(object, eventName, specClass)
    local list = object.eventListeners[eventName]
    for i = #(list or {}), 1, -1 do if list[i] == specClass then table.remove(list, i) end end
end

-- ── the engine's ForageWagon (vehicles/specializations/ForageWagon.lua) ─────────────────────────
-- :52-88 VERBATIM through the server's fields (the deprecated-element checks, the client's effects
-- :72-75, the UV scroll speeds and the effect fade read out; ValueBuffer.new(750) MODELED), :138-204
-- VERBATIM (the decompile's reused local names given their own: the search, the additive's test and
-- its level), :216-228 VERBATIM, :269-296 VERBATIM. The search loop walks pairs over the unit's
-- supportedFillTypes as the decompile does; this bench builds that table in a fixed insertion order.
local function newForageClass()
    local F = {}
    function F:onLoad(_)
        local spec = self.spec_forageWagon
        spec.isFilling = false
        spec.isFillingSent = false
        spec.lastFillType = FillType.UNKNOWN
        spec.lastFillTypeSent = FillType.UNKNOWN
        spec.fillTimer = 0
        spec.workAreaIndex = self.xmlFile:getValue("vehicle.forageWagon#workAreaIndex", 1)
        spec.fillUnitIndex = self.xmlFile:getValue("vehicle.forageWagon#fillUnitIndex", 1)
        spec.loadInfoIndex = self.xmlFile:getValue("vehicle.forageWagon#loadInfoIndex", 1)
        spec.additives = {}
        spec.additives.fillUnitIndex = self.xmlFile:getValue("vehicle.forageWagon.additives#fillUnitIndex")
        spec.additives.available = self:getFillUnitByIndex(spec.additives.fillUnitIndex) ~= nil
        spec.additives.usage = self.xmlFile:getValue("vehicle.forageWagon.additives#usage", 0.0000275)
        spec.additives.fillTypes = g_fillTypeManager:getFillTypesByNames(self.xmlFile:getValue("vehicle.forageWagon.additives#fillTypes", "GRASS_WINDROW"), "Warning: invalid fillType '%s'.")
        spec.maxPickupLitersPerSecond = self.xmlFile:getValue("vehicle.forageWagon#maxPickupLitersPerSecond", 500)
        spec.fillStartEffectDelay = self.xmlFile:getValue("vehicle.forageWagon.startFillEffect#fillStartDelay", 0) * 0.001
        spec.fillStartEffectTimer = 0
        spec.fillStartEffectFadeOff = self.xmlFile:getValue("vehicle.forageWagon.startFillEffect#fillStartFadeOff", 0)
        spec.workAreaParameters = {}
        spec.workAreaParameters.forcedFillType = FillType.UNKNOWN
        spec.workAreaParameters.lastPickupLiters = 0
        spec.workAreaParameters.litersToFill = 0
        spec.pickUpLitersBuffer = { add = function() end, get = function() return 0 end }
        if spec.startFillEffect == nil or #spec.startFillEffect == 0 then
            SpecializationUtil.removeEventListener(self, "onFillUnitFillLevelChanged", ForageWagon)
        end
        spec.dirtyFlag = self:getNextDirtyFlag()
    end
    function F:processForageWagonArea(workArea)
        local spec = self.spec_forageWagon
        local lsx, lsy, lsz, lex, ley, lez = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height)
        local pickupLiters = 0
        if spec.workAreaParameters.forcedFillType == FillType.UNKNOWN then
            local supportedFillTypes = self:getFillUnitSupportedFillTypes(spec.fillUnitIndex)
            if supportedFillTypes ~= nil then
                for fillType, state in pairs(supportedFillTypes) do
                    if state then
                        pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillType, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
                        if pickupLiters > 0 then
                            spec.workAreaParameters.forcedFillType = fillType
                            break
                        end
                    end
                end
            end
        else
            pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, spec.workAreaParameters.forcedFillType, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
            if spec.workAreaParameters.forcedFillType == FillType.GRASS_WINDROW then
                pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
            elseif spec.workAreaParameters.forcedFillType == FillType.DRYGRASS_WINDROW then
                pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.GRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
            end
        end
        if self.isServer and spec.additives.available then
            local supported = false
            for i = 1, #spec.additives.fillTypes, 1 do
                if spec.workAreaParameters.forcedFillType == spec.additives.fillTypes[i] then
                    supported = true
                    break
                end
            end
            if supported then
                local additivesFillLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
                if additivesFillLevel > 0 then
                    local usage = spec.additives.usage * pickupLiters
                    if usage > 0 then
                        pickupLiters = pickupLiters * (1 + 0.05 * math.min(additivesFillLevel / usage, 1))
                        self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                    end
                end
            end
        end
        workArea.lastPickUpLiters = pickupLiters
        workArea.pickupParticlesActive = pickupLiters > 0
        spec.workAreaParameters.lastPickupLiters = spec.workAreaParameters.lastPickupLiters + pickupLiters
        spec.workAreaParameters.litersToFill = spec.workAreaParameters.litersToFill + pickupLiters
        if spec.workAreaParameters.forcedFillType ~= FillType.UNKNOWN then
            spec.lastFillType = spec.workAreaParameters.forcedFillType
            if spec.lastFillType ~= spec.lastFillTypeSent then
                spec.lastFillTypeSent = spec.lastFillType
                self:raiseDirtyFlags(spec.dirtyFlag)
            end
        end
        local area, worked = 0, 0
        if self.movingDirection == 1 then
            area = MathUtil.vector3Length(lsx - lex, lsy - ley, lsz - lez) * self.lastMovedDistance
            worked = area
        end
        return area, worked
    end
    function F:fillForageWagon()
        local spec = self.spec_forageWagon
        local loadInfo = self:getFillVolumeLoadInfo(spec.loadInfoIndex)
        local filledLiters = self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, spec.workAreaParameters.litersToFill, spec.lastFillType, ToolType.UNDEFINED, loadInfo)
        if filledLiters + 0.01 < spec.workAreaParameters.litersToFill then
            self:setIsTurnedOn(false)
            self:setPickupState(false)
        end
        spec.workAreaParameters.litersToFill = spec.workAreaParameters.litersToFill - filledLiters
        if spec.workAreaParameters.litersToFill < 0.01 then
            spec.workAreaParameters.litersToFill = 0
        end
    end
    function F:onStartWorkAreaProcessing(_)
        local spec = self.spec_forageWagon
        spec.workAreaParameters.forcedFillType = FillType.UNKNOWN
        local fillLevel = self:getFillUnitFillLevel(spec.fillUnitIndex)
        if self:getFillTypeChangeThreshold(spec.fillUnitIndex) < fillLevel then
            spec.workAreaParameters.forcedFillType = self:getFillUnitFillType(spec.fillUnitIndex)
        end
        if fillLevel == 0 and (spec.fillStartEffectDelay > 0 and spec.fillStartEffectTimer <= 0) then
            spec.fillStartEffectTimer = spec.fillStartEffectDelay
        end
        spec.workAreaParameters.lastPickupLiters = 0
    end
    function F:onEndWorkAreaProcessing(dt, _)
        local spec = self.spec_forageWagon
        if self.isServer and spec.workAreaParameters.lastPickupLiters > 0 then
            local allowToFill = true
            if spec.fillStartEffectTimer > 0 then
                spec.fillStartEffectTimer = spec.fillStartEffectTimer - dt
                if spec.fillStartEffectTimer > 0 then
                    allowToFill = false
                end
            end
            if allowToFill then
                self:fillForageWagon()
            end
            spec.fillTimer = 500
        end
    end
    -- A re-sourced ForageWagon.lua makes new function values: each method in a closure of its own.
    local fresh = {}
    for k, f in pairs(F) do
        if type(f) == "function" then local inner = f fresh[k] = function(...) return inner(...) end else fresh[k] = f end
    end
    return fresh
end
REAL.ForageWagon = newForageClass()

-- ── a ForageWagon as the engine builds it ─────────────────────────────────────────────────
-- A trailer's fill unit (the crop unit, 1; the additive unit, 2, when opts.additives) with FillUnit's
-- add VERBATIM in effect (fillUnitAdd) and :784-790's threshold VERBATIM; its registered functions
-- COPIED into the instance (Vehicle.lua:486), the pickup's pointer CAPTURED from the instance
-- (WorkArea.lua:266), its listeners raised by name at raise time (ENGINE_RAISE). One pickup work area
-- over x -1..1 at z 0. opts: capacity, unitLevel, unitType, types (the unit's supported types, in
-- order), delay (the config's fillStartDelay), additives = { level, usage, fillTypes }, configFileName.
local function configXml(values)
    return { getValue = function(_, k, d) local v = values[k] if v == nil then return d end return v end, getFilename = function() return "forageWagon.xml" end }
end
local function newForageWagon(uid, opts)
    opts = opts or {}
    local supported = {}
    for _, ft in ipairs(opts.types or { GRASS, DRY, STRAW_W }) do supported[ft] = true end
    local v = ENGINE_NEW_TRAILER(uid, { level = opts.unitLevel or 0, fillType = opts.unitType, capacity = opts.capacity or 10000, supported = supported })
    v.configFileName = opts.configFileName or "data/vehicles/forageWagon.xml"
    v.isServer, v.isClient = true, false
    if opts.additives ~= nil then
        v.spec_fillUnit.fillUnits[2] = { fillLevel = opts.additives.level or 0, capacity = 1000, fillType = ADD, lastValidFillType = ADD, supportedFillTypes = { [ADD] = true } }
    end
    v.addFillUnitFillLevel = fillUnitAdd
    v.getFillUnitByIndex = function(self, i) return i ~= nil and self.spec_fillUnit.fillUnits[i] or nil end
    v.getFillUnitSupportedFillTypes = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.supportedFillTypes or nil end
    v.getFillTypeChangeThreshold = function(self, fillUnitIndex)
        if fillUnitIndex == nil then
            return self.spec_fillUnit.fillTypeChangeThreshold
        else
            return (self:getFillUnitCapacity(fillUnitIndex) or 1) * self.spec_fillUnit.fillTypeChangeThreshold
        end
    end
    v.getFillVolumeLoadInfo = function() return nil end
    v.turnedOff = 0
    v.setIsTurnedOn = function(self, on) if on == false then self.turnedOff = self.turnedOff + 1 end end
    v.setPickupState = function() end
    v.raiseDirtyFlags = function() end
    v.getNextDirtyFlag = function() return 1 end
    v.movingDirection, v.lastMovedDistance = 1, 1
    v.processForageWagonArea, v.fillForageWagon = ForageWagon.processForageWagonArea, ForageWagon.fillForageWagon
    local cfg = { ["vehicle.forageWagon.startFillEffect#fillStartDelay"] = opts.delay }
    if opts.additives ~= nil then
        cfg["vehicle.forageWagon.additives#fillUnitIndex"] = 2
        cfg["vehicle.forageWagon.additives#usage"] = opts.additives.usage
        cfg["vehicle.forageWagon.additives#fillTypes"] = opts.additives.fillTypes
    end
    v.xmlFile = configXml(cfg)
    v.spec_forageWagon = {}
    v.specClasses = { ForageWagon }
    v.specializations = { ENGINE_FILLUNIT, ForageWagon }
    v.specializationNames = { "fillUnit", "forageWagon" }
    v.eventListeners.onLoad = { ForageWagon }
    v.eventListeners.onStartWorkAreaProcessing = { ForageWagon }
    v.eventListeners.onEndWorkAreaProcessing = { ForageWagon }
    v.eventListeners.onFillUnitFillLevelChanged = { ForageWagon }
    local wa = { index = 1, functionName = "processForageWagonArea",
                 start = { x = -1, y = 0, z = -0.5 }, width = { x = 1, y = 0, z = -0.5 }, height = { x = -1, y = 0, z = 0.5 } }
    wa.processingFunction = v.processForageWagonArea
    v.spec_workArea = { workAreas = { wa } }
    return v
end
--- The vehicle's load (Vehicle.lua:866 and :903-906): onLoad raised with the savegame through each
--- listener's class table, read when its task runs, then onPostLoad (FillUnit's levels back).
local function loadWagon(v, savegame)
    for _, spec in ipairs(v.eventListeners.onLoad) do spec.onLoad(v, savegame) end
    ENGINE_POST_LOAD_VEHICLE(v, savegame)
end
--- WorkArea:onUpdateTick's order (WorkArea.lua:124-206): the start event, the captured pointer, the end
--- event, each raised by name at raise time; dt 16 as the update passes it.
local function tickWagon(v)
    local was = v.spec_workArea.workAreas
    ENGINE_RAISE(v, "onStartWorkAreaProcessing", 16, was)
    for _, a in ipairs(was) do a.processingFunction(v, a, 16) end
    ENGINE_RAISE(v, "onEndWorkAreaProcessing", 16, true)
end
--- A tipper of `ft` over the pickup line at `at`, tipping `litres` there after the barrier.
local function layer(m, w, ft, litres, key, at)
    w[key] = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. key, { level = litres, fillType = ft, at = at or { x = 0, z = 0 },
        supported = { [GRASS] = true, [DRY] = true, [STRAW_W] = true, [WHEAT] = true } }))
end
local function admits() local n = 0 for _, c in ipairs(SOIL.calls) do if c.fn == "admit" then n = n + 1 end end return n end

-- ── Soil's own ForageWagon frame (a stand-in) ──────────────────────────────────────────────
-- ForageWagonCollection.makePickupWrapper (Soil 7341ea6d :62-85) on the captured pointer, installed
-- when the vehicle is added (inside StockGuard's bracket: production's order), with GroundNativeObserver's
-- admission-count rule (:45-55): per call the admissions Soil granted during the native call are the
-- inner slot's, one per primitive, and Soil stands aside for each (stoodAside); a call with none would
-- seal its own (own).
local SOILFC = { calls = 0, stoodAside = 0, own = 0 }
local function soilWagonWrap(v)
    local wa = v.spec_workArea.workAreas[1]
    local inner = wa.processingFunction
    wa.processingFunction = function(vehicle, workArea, ...)
        SOILFC.calls = SOILFC.calls + 1
        local before = admits()
        local r = { inner(vehicle, workArea, ...) }
        local moved = admits() - before
        if moved > 0 then SOILFC.stoodAside = SOILFC.stoodAside + moved else SOILFC.own = SOILFC.own + 1 end
        return unpack(r)
    end
end

--- Boot through main.lua's load path: the class hooks install at loadMission00Finished, then the
--- vehicles load (mission00.lua:604-612), then the barrier. opts: noSoil, index, split.
local function boot5f(build, dir, opts)
    opts = opts or {}
    soil5dReset(opts.split)
    SOILFC.calls, SOILFC.stoodAside, SOILFC.own = 0, 0, 0
    local m = newMission(dir, opts)
    engine("g_server", {})
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    if not opts.noSoil then soilOn(m) soil5dOn(m) end
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    if not opts.noSoil then m.stockGuard.registerProperty(PID, AOWNER) end
    Mission00.loadMission00Finished(m)
    local w = {}
    if build ~= nil then build(m, w) end
    m:onFinishedLoading()
    return m, sg, NH.current, w
end
--- A world: windrows laid (lay = { { ft, litres, key, at } }), the wagon (wagon = opts), loaded from
--- `savegame` when given; Soil's own frame on its pointer unless opts.noSoil.
local function wagonWorld(o, savegameFn)
    return function(m, w)
        for _, l in ipairs(o.lay or {}) do layer(m, w, l[1], l[2], l[3], l[4]) end
        w.wagon = vehicleIn(m, newForageWagon("vehicle:wagon", o.wagon))
        loadWagon(w.wagon, savegameFn ~= nil and savegameFn() or nil)
        if not o.noSoil then soilWagonWrap(w.wagon) end
    end
end
local function tipAll(o, w) for _, l in ipairs(o.lay or {}) do ENGINE_TIP(w[l[3]], l[2]) end end
local function boot(o, dir, index, savegameFn)
    local m, sg, host, w = boot5f(wagonWorld(o, savegameFn), dir, { noSoil = o.noSoil, index = index, split = o.split })
    tipAll(o, w)
    return m, sg, host, w
end
--- More windrow under the line between ticks.
local function relay(m, w, ft, litres, key, at)
    layer(m, w, ft, litres, key, at)
    ENGINE_TIP(w[key], litres)
end

-- ── readers ────────────────────────────────────────────────────────────────────────────
local function bufId(v) return cid(NA.forageBufferBinding(v)) end
local function held(v) return v.spec_forageWagon.workAreaParameters.litersToFill end
local function accText(a)
    if a == nil then return "none" end
    local pct = a.knownCarrierLitres > 0 and (a.knownWeightedPctSum / a.knownCarrierLitres) or nil
    return table.concat({ num(a.carrierLitres), num(a.knownCarrierLitres), num(a.unknownCarrierLitres), num(a.refusedCarrierLitres), num(pct) }, "/")
end
--- A stock's text: material, amount, knowledge, and its soil.groundCondition (c and account).
local function stockText(s)
    if s == nil then return "none" end
    local p = s.properties[PID]
    local mat = s.materialRef and (s.materialRef.fillTypeName or s.materialRef.groupId) or "nil"
    return table.concat({ tostring(mat), num(s.observedAmount), tostring(s.knowledge),
        p == nil and "noRecord" or (tostring(p.knowledge) .. ":" .. num(p.payload and p.payload.c) .. ":" .. accText(p.payload and p.payload.account)) }, "|")
end
local function bufText(sg, v) return stockText(stockAt(sg, bufId(v))) end
local function unitText(sg, v, i) return stockText(stockAt(sg, unitId(v, i or 1))) end
--- The last pickup operation and the last fill operation the host recorded.
local function pickOp(host) local gf = host.lastForageFrame return gf and gf.operations[#gf.operations] or nil end
local function fillOp(host) local gf = host.lastForageFill return gf and gf.operations[#gf.operations] or nil end
local function outcomeOf(op) return op == nil and "none" or (tostring(op.evidence and op.evidence.nativePath) .. ":" .. tostring(op.outcome) .. ((op.outcome ~= "COMMITTED" and op.reason) and (":" .. tostring(op.reason)) or "")) end
--- The pickup's legs: cell legs (count, sources, destinations), self legs, losses, any basis.
local function legText(op, v)
    local n, src, dst, self, loss, based = 0, 0, 0, 0, 0, false
    local buf = bufId(v)
    for _, a in ipairs(op and op.report and op.report.allocations or {}) do
        if a.conversionBasisId ~= nil then based = true end
        if a.result == "LOSS" then loss = loss + a.sourceAmount
        elseif a.source.carrierId == buf then self = self + 1
        else n = n + 1 src = src + a.sourceAmount dst = dst + a.destinationAmount end
    end
    return n .. " legs " .. num(src) .. ">" .. num(dst) .. " self " .. self .. " loss " .. num(loss) .. " basis " .. tostring(based)
end
--- Every named account adopted: each names a cell leg once, its litres that leg's.
local function namedText(op)
    local ev = op and op.evidence or {}
    local list = ev[PID] and ev[PID].collectedAccounts or {}
    local allocs = op and op.report and op.report.allocations or {}
    local ok, seen, sum = true, {}, nil
    for _, e in ipairs(list) do
        local a = allocs[e.allocation]
        if a == nil or seen[e.allocation] or math.abs(e.account.carrierLitres - a.destinationAmount) > 1e-9 * math.max(1, a.destinationAmount) then ok = false end
        seen[e.allocation] = true
        sum = sum or { carrierLitres = 0, knownCarrierLitres = 0, unknownCarrierLitres = 0, refusedCarrierLitres = 0, knownWeightedPctSum = 0 }
        for k, x in pairs(e.account) do sum[k] = sum[k] + x end
    end
    return #list .. " named " .. tostring(ok) .. " sum " .. accText(sum)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A FORCED-GRASS WAGON OVER GRASS AND HAY WINDROWS
-- ══════════════════════════════════════════════════════════════════════════
-- The unit is full of grass (forced type GRASS_WINDROW, :272-275), so the call removes grass and
-- then its hay twin (:156-158) and the fill takes nothing (A = 0): the buffer keeps the call's
-- litres and the sealed account, and the wagon turns itself off (:220-223).
local E_WORLD = { lay = { { GRASS, 100, "grass", { x = -0.25, z = 0 } }, { DRY, 40, "dry", { x = 0.25, z = 0 } } },
                  wagon = { capacity = 10000, unitLevel = 10000, unitType = GRASS } }
group("E", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(E_WORLD, "w5f_e", 201)
    local v = w.wagon
    local wa = v.spec_workArea.workAreas[1]
    T.ok("E0 [reached] main.lua's install wrapped ForageWagon's fill listener (SGClassHook, the live class), defined its saver, appended its restore after onLoad, and bracketed the pickup's CAPTURED pointer outside Soil's",
        SGClassHook.record(ForageWagon, "onEndWorkAreaProcessing", GO.HOOK_ID) ~= nil and type(ForageWagon.saveToXMLFile) == "function"
            and rawget(ForageWagon, SGFieldToolBufferSave.MARKER) ~= nil and rawget(ForageWagon, SGFieldToolBufferSave.MARKER).onLoad ~= nil
            and wa._sgBrackets ~= nil and wa._sgBrackets.processForageWagonArea ~= nil and wa._sgBrackets.processForageWagonArea.original ~= v.processForageWagonArea)
    soilReset()
    tickWagon(v)
    local op = pickOp(host)
    T.eq("E1 NAMED [entry point]: one call removed grass and its hay twin, Soil admitted both lines, and StockGuard settled ONE pickup: the cells' 140 L into the buffer, which holds them as grass, KNOWN, with the sealed account (140 L known at 30 %)",
        admits() .. "/" .. outcomeOf(op) .. "|" .. bufText(sg, v) .. "|" .. num(held(v)),
        "2/GROUND_FORAGE_PICKUP:COMMITTED|GRASS_WINDROW|140|KNOWN|KNOWN:7:140/140/0/0/30|140")
    T.eq("E2 NAMED: the legs take each cell's loss to the buffer, 140 L to 140 L, with no conversion basis on any leg (Bob's ruling 3), and the fold is declared in the evidence with both inputs and the representative name",
        legText(op, v) .. " | " .. num(op and op.evidence.fold and op.evidence.fold.inputs[g_fillTypeManager:getFillTypeNameByIndex(GRASS)]) .. "+" .. num(op and op.evidence.fold and op.evidence.fold.inputs[g_fillTypeManager:getFillTypeNameByIndex(DRY)])
            .. " as " .. tostring(op and op.evidence.fold and op.evidence.fold.representative) .. " " .. tostring(op and op.evidence.fold and op.evidence.fold.basis)
            .. " " .. tostring(op and op.evidence.fold and op.evidence.fold.coalesce),
        legText(op, v):match("^%d+") .. " legs 140>140 self 0 loss 0 basis false | 100+40 as GRASS_WINDROW NATIVE_FORAGE_WINDROW_FOLD NATIVE_FORAGE_COALESCE_V1")
    T.eq("E3 NAMED: the seal: one batch per removing line, both sealed and read through Soil's reader; every cell leg names an account of its own litres, and the accounts sum to the sealed one",
        tostring(op and op.evidence.seal.shares) .. "/" .. tostring(op and op.evidence.seal.sealed) .. "/" .. tostring(op and op.evidence.seal.read) .. " " .. namedText(op):gsub("^%d+", "n"),
        "2/2/2 n named true sum 140/140/0/0/30")
    T.eq("E4 NAMED: Soil's own ForageWagon frame stood aside for both of the call's primitives and sealed nothing of its own",
        SOILFC.calls .. "/" .. SOILFC.stoodAside .. "/" .. SOILFC.own, "1/2/0")
    T.eq("E5 the fill took nothing (the unit full, A = 0): no fill operation, the buffer's stock untouched, and the wagon turned itself off once (native, observed only)",
        outcomeOf(fillOp(host)) .. " " .. num(v:getFillUnitFillLevel(1)) .. " " .. v.turnedOff .. " " .. bufText(sg, v),
        "none 10000 1 GRASS_WINDROW|140|KNOWN|KNOWN:7:140/140/0/0/30")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE FILL: A FROM THE FILL CALL, THE TRIM, A FULL UNIT, ANOTHER TYPE IN THE UNIT
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    resetWorld()
    soilReset()
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000 } }
    local m, sg, host, w = boot(o, "w5f_f1", 202)
    local v = w.wagon
    tickWagon(v)
    local f = fillOp(host)
    local leg = f and f.report.allocations[1]
    T.eq("F1 NAMED: an empty unit, no delay: the pickup and then ONE TRANSFER from the buffer to the unit at A, the fill call's own accepted delta; the unit's stock carries the buffer's record and account",
        outcomeOf(pickOp(host)) .. " " .. outcomeOf(f) .. " " .. num(leg and leg.sourceAmount) .. ">" .. num(leg and leg.destinationAmount) .. " A=" .. num(f and f.evidence.accepted) .. " | " .. unitText(sg, v),
        "GROUND_FORAGE_PICKUP:COMMITTED FORAGE_FILL:COMMITTED 100>100 A=100 | GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30")
    T.eq("F2 NAMED: the emptied buffer is withdrawn (no carrier, no entry) and the fill's own report was consumed: the unit's stock is the transfer's, not a second change",
        tostring(sg.operations.carriers[bufId(v)] == nil) .. "/" .. tostring(NA.forageBuffers[bufId(v)] == nil) .. "/" .. num(stockAt(sg, unitId(v, 1)).observedAmount),
        "true/true/100")
    FSBaseMission.delete(m)

    -- The trim (:225-227): a unit of 99.995 L takes 99.995 of 100; the 0.005 L left is trimmed to 0.
    resetWorld()
    soilReset()
    o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 99.995 } }
    m, sg, host, w = boot(o, "w5f_f3", 203)
    v = w.wagon
    tickWagon(v)
    f = fillOp(host)
    local trim = 0
    for _, a in ipairs(f and f.report.allocations or {}) do if a.result == "LOSS" and a.reason == "FORAGE_TRIM" then trim = trim + a.sourceAmount end end
    T.eq("F3 NAMED: a remainder under 0.01 L that the fill trimmed is a LOSS leg of the same operation (FORAGE_TRIM), not output and not a saved residual; the wagon stays on",
        outcomeOf(f) .. " trim " .. num(trim) .. " held " .. num(held(v)) .. " off " .. v.turnedOff .. " buffer " .. tostring(sg.operations.carriers[bufId(v)] == nil),
        "FORAGE_FILL:COMMITTED trim 0.005 held 0 off 0 buffer true")
    FSBaseMission.delete(m)

    -- A full unit: 60 L of room for 100 L; the remainder stays in the buffer with the same mixture.
    resetWorld()
    soilReset()
    o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 60 } }
    m, sg, host, w = boot(o, "w5f_f4", 204)
    v = w.wagon
    tickWagon(v)
    f = fillOp(host)
    -- The remainder is a source that keeps its own record: SG-1 scales its coverage, never its payload
    -- (SGOperations settle step 7), and Soil reads the account at the litres the stock holds.
    local rest = stockAt(sg, bufId(v))
    local rp = rest and rest.properties[PID]
    T.eq("F4 NAMED: a full unit takes A = 60 of 100: the TRANSFER moves 60 with 60/100 of the account, the remainder keeps 40 L of the same mixture (its record's coverage 40 of 40, its account the same mixture), and the wagon turns itself off",
        outcomeOf(f) .. " " .. num(f and f.evidence.accepted) .. " off " .. v.turnedOff .. " | " .. unitText(sg, v) .. " | " .. bufText(sg, v) .. " " .. num(rp and rp.knownAmount) .. "/" .. num(rp and rp.basisAmount),
        "FORAGE_FILL:COMMITTED 60 off 1 | GRASS_WINDROW|60|KNOWN|KNOWN:7:60/60/0/0/30 | GRASS_WINDROW|40|KNOWN|KNOWN:7:100/100/0/0/30 40/40")
    FSBaseMission.delete(m)

    -- Another type in the unit: 1 L of straw windrow under the threshold (500 L), so no forced type; the
    -- fill empties it first (FillUnit's nested add) and fills the grass.
    resetWorld()
    soilReset()
    o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, unitLevel = 1, unitType = STRAW_W } }
    m, sg, host, w = boot(o, "w5f_f5", 205)
    v = w.wagon
    tickWagon(v)
    f = fillOp(host)
    local discard = 0
    for _, a in ipairs(f and f.report.allocations or {}) do if a.result == "LOSS" and a.reason == "FORAGE_UNIT_DISCARD" then discard = discard + a.sourceAmount end end
    T.eq("F5 NAMED: a unit holding another type: its old 1 L is a LOSS (FORAGE_UNIT_DISCARD, :667), the unit receives its whole 100 L of grass, and the litre native's count keeps in the buffer stays (unexplained to SG-1)",
        outcomeOf(f) .. " discard " .. num(discard) .. " received " .. num(f and f.evidence.received) .. " A=" .. num(f and f.evidence.accepted) .. " held " .. num(held(v)) .. " | " .. unitText(sg, v),
        "FORAGE_FILL:COMMITTED discard 1 received 100 A=99 held 1 | GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE ADDITIVE: RAW, PRODUCED AND THE DEBIT, SEPARATE
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    resetWorld()
    soilReset()
    -- 0.1 L of additive at usage 0.001 per litre covers the whole 100 L: a 5 % boost (:179).
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, additives = { level = 0.1, usage = 0.001, fillTypes = "GRASS_WINDROW" } } }
    local m, sg, host, w = boot(o, "w5f_g", 206)
    local v = w.wagon
    tickWagon(v)
    local op = pickOp(host)
    local ev = op and op.evidence or {}
    T.eq("G1 NAMED: the pickup's legs take the cells' 100 L to 105 L in the buffer with no basis; raw, produced and the additive debit are recorded separately and F is observed (1.05), never computed",
        legText(op, v):gsub("^%d+", "n") .. " | raw " .. num(ev.raw) .. " produced " .. num(ev.produced) .. " debit " .. num(ev.additiveDebit) .. " F " .. num(ev.nativeGain and ev.nativeGain.factor),
        "n legs 100>105 self 0 loss 0 basis false | raw 100 produced 105 debit 0.1 F 1.05")
    local addS = stockAt(sg, unitId(v, 2))
    T.eq("G2 NAMED: the additive's debit replayed as its own unit's decrease, never a leg into the crop: the additive stock follows native, and no leg of the pickup names the additive unit",
        num(addS and addS.observedAmount or 0) .. "/" .. num(v:getFillUnitFillLevel(2)) .. " " .. tostring((function()
            for _, a in ipairs(op and op.report.allocations or {}) do if a.source.carrierId == unitId(v, 2) or a.destination.carrierId == unitId(v, 2) then return "named" end end
            return "unnamed" end)()),
        "0/0 unnamed")
    T.eq("G3 NAMED: the boosted 105 L reach the unit KNOWN with the source's condition and the sealed account (105 L known at 30 %)",
        unitText(sg, v), "GRASS_WINDROW|105|KNOWN|KNOWN:7:105/105/0/0/30")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE START-FILL DELAY: A REMAINDER ACROSS TICKS
-- ══════════════════════════════════════════════════════════════════════════
-- fillStartDelay 20000 (x 0.001 = 20) armed on an empty unit (:276-278); each tick that picked
-- something takes dt 16 off it (:285-289): tick 1 holds, tick 2 fills.
group("D", function()
    resetWorld()
    soilReset()
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, delay = 20000 } }
    local m, sg, host, w = boot(o, "w5f_d", 207)
    local v = w.wagon
    tickWagon(v)
    T.eq("D1 NAMED: during the delay the buffer keeps the call's 100 L across the tick: no fill, the stock KNOWN with the sealed account",
        outcomeOf(fillOp(host)) .. " " .. num(held(v)) .. " | " .. bufText(sg, v), "none 100 | GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30")
    local first = stockAt(sg, bufId(v))
    relay(m, w, GRASS, 50, "grass2")
    tickWagon(v)
    T.eq("D2 NAMED: the next tick's pickup joins the same stock (its before-state the remainder), then the fill moves all 150 L to the unit with their accounts",
        tostring(first ~= nil and pickOp(host).report.participantsAfter ~= nil) .. " " .. outcomeOf(fillOp(host)) .. " " .. num(fillOp(host) and fillOp(host).evidence.accepted) .. " | " .. unitText(sg, v),
        "true FORAGE_FILL:COMMITTED 150 | GRASS_WINDROW|150|KNOWN|KNOWN:7:150/150/0/0/30")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RETARGET: THE PAIR'S FOLD, AND A RENAME OUTSIDE IT
-- ══════════════════════════════════════════════════════════════════════════
-- An empty unit forces no type (:271-275), so during the delay each tick's search picks the first type
-- it can remove (:142-152): tick 1 grass, tick 2 the other windrow; native renames the buffer (:190-191).
group("R", function()
    resetWorld()
    soilReset()
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, delay = 20000 } }
    local m, sg, host, w = boot(o, "w5f_r1", 208)
    local v = w.wagon
    tickWagon(v)
    relay(m, w, DRY, 50, "dry")
    tickWagon(v)
    local op = pickOp(host)
    T.eq("R1 NAMED: within the pair the rename is the fold: the buffer's own leg carries its 100 L through SG-1's new generation, and the unit receives 150 L of hay KNOWN with the whole account",
        legText(op, v):gsub("^%d+", "n") .. " | " .. tostring(op and op.evidence.retarget and op.evidence.retarget.form) .. " " .. num(op and op.evidence.retarget and op.evidence.retarget.remainder) .. " | " .. unitText(sg, v),
        "n legs 50>50 self 1 loss 0 basis false | NATIVE_FORAGE_WINDROW_FOLD 100 | DRYGRASS_WINDROW|150|KNOWN|KNOWN:7:150/150/0/0/30")
    FSBaseMission.delete(m)

    resetWorld()
    soilReset()
    -- A delay of 40 holds the buffer through both ticks, so its stock is read right after the pickup.
    o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, delay = 40000 } }
    m, sg, host, w = boot(o, "w5f_r2", 209)
    v = w.wagon
    tickWagon(v)
    local grassStock = stockAt(sg, bufId(v))
    relay(m, w, STRAW_W, 50, "straw")
    tickWagon(v)
    op = pickOp(host)
    T.eq("R2 NAMED: outside the pair no form is declared: the 100 L remainder's stock is replaced under FORAGE_RETARGET_UNPROVED before the pickup, no leg carries it, and the buffer's 150 L of straw windrow hold 50 L known and 100 L unknown",
        legText(op, v):gsub("^%d+", "n") .. " | " .. tostring(op and op.evidence.retarget and op.evidence.retarget.reason) .. " " .. tostring(sg.operations.retiredStocks[grassStock and grassStock.stockId or "?"] and sg.operations.retiredStocks[grassStock.stockId].retireReason)
            .. " | " .. bufText(sg, v),
        "n legs 50>50 self 0 loss 0 basis false | FORAGE_RETARGET_UNPROVED FORAGE_RETARGET_UNPROVED | STRAW_WINDROW|150|PARTIAL|PARTIAL:7:150/50/100/0/30")
    FSBaseMission.delete(m)

    -- Bob's bar on the withheld read: the retarget's refresh raises; the flag must still be cleared, so
    -- the buffer's next read is native's whole litersToFill, never short of the call's litres.
    resetWorld()
    soilReset()
    -- A delay of 40 holds the buffer through both ticks (40 - 16 - 16 > 0), so it is read before any fill.
    o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, delay = 40000 } }
    m, sg, host, w = boot(o, "w5f_r3", 222)
    v = w.wagon
    tickWagon(v)
    relay(m, w, STRAW_W, 50, "straw")
    local realRefresh = host.handle.refreshCarrier
    host.handle.refreshCarrier = function(lease, binding, reason, ...)
        if reason == GO.FORAGE_RETARGET_REASON then error("bench: the retarget's refresh raised", 0) end
        return realRefresh(lease, binding, reason, ...)
    end
    tickWagon(v)
    host.handle.refreshCarrier = realRefresh
    local entry = NA.forageBuffers[bufId(v)]
    local ns = GO.readNow(host, NA.forageBufferBinding(v))
    T.eq("R3 NAMED (Bob's bar): when the retarget's refresh raises, the call goes unattributed and the withheld read is cleared: the buffer reads all 150 L native holds",
        tostring(entry ~= nil and entry.withheld) .. " " .. num(ns and ns.amount) .. "=" .. num(held(v)) .. " " .. tostring(host.lastForageFrame and host.lastForageFrame.refused and next(host.lastForageFrame.refused)),
        "nil 150=150 RETARGET_REFRESH:bench: the retarget's refresh raised")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SAVE: A REMAINDER SURVIVES WITH ITS STOCK, OR IS REFUSED
-- ══════════════════════════════════════════════════════════════════════════
--- Launch A: the delay's first tick leaves 100 L in the buffer; then the save. Returns its world.
local function saved(dir, index, o)
    resetWorld()
    soilReset()
    o = o or { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, delay = 20000 } }
    local m, sg, host, w = boot(o, dir, index)
    tickWagon(w.wagon)
    local stock = stockAt(sg, bufId(w.wagon))
    nativeSave(m, dir)
    local keys = {}
    for i, v in ipairs(m._vehicles) do keys[v.uniqueId] = string.format("vehicles.vehicle(%d)", i - 1) end
    local element = {}
    local d = ENGINE_DISK[dir .. "/vehicles.xml"] or {}
    local prefix = keys["vehicle:wagon"] .. ".forageWagon.stockGuardBuffer"
    for k, val in pairs(d) do if k:sub(1, #prefix) == prefix then element[k:sub(#prefix + 1)] = val end end
    FSBaseMission.delete(m)
    return { stock = stock, keys = keys, element = element }
end
--- Launch B on the same directory: the wagon loaded from its saved key (opts: wagon, reset, edit).
local function reloaded(dir, index, a, opts)
    opts = opts or {}
    resetWorld()
    soilReset()
    if opts.edit ~= nil then
        local file = ENGINE_DISK[dir .. "/vehicles.xml"]
        for k, val in pairs(opts.edit) do file[a.keys["vehicle:wagon"] .. ".forageWagon.stockGuardBuffer" .. k] = val end
    end
    local o = { lay = opts.lay or {}, wagon = opts.wagon or { capacity = 10000, delay = 20000 } }
    local lines = {}
    local m, sg, host, w
    lines = printed(function()
        m, sg, host, w = boot(o, dir, index, function()
            local xml = REAL.XMLFile.load("vehiclesXML", dir .. "/vehicles.xml", REAL.Vehicle.xmlSchemaSavegame)
            return { xmlFile = xml, key = a.keys["vehicle:wagon"], resetVehicles = opts.reset == true }
        end)
    end)
    return m, sg, host, w, lines
end
group("S", function()
    local DIR = "w5f_s"
    local a = saved(DIR, 210)
    T.eq("S0 [reached] the save wrote the wagon's element under its spec key: version, configuration, layout, the fill unit's index and identity, the buffer, its type and the token",
        table.concat({ tostring(a.element["#version"]), tostring(a.element["#configFileName"]), tostring(a.element["#areaCount"]), tostring(a.element["#fillUnitIndex"]),
            tostring(a.element["#fillTypes"]), num(a.element["#litersToFill"]), tostring(a.element["#lastFillType"]), tostring(a.element["#token"] == bufId({ uniqueId = "vehicle:wagon", configFileName = "data/vehicles/forageWagon.xml" })) }, " "),
        "1 data/vehicles/forageWagon.xml 1 1 DRYGRASS_WINDROW GRASS_WINDROW STRAW_WINDROW 100 GRASS_WINDROW true")
    local m, sg, host, w, lines = reloaded(DIR, 210, a, { lay = { { GRASS, 20, "grass" } }, wagon = { capacity = 10000 } })
    local v = w.wagon
    T.eq("S1 NAMED [entry point]: a fresh mission loads the wagon from its saved key: the buffer is back where onLoad zeroed it, its type set, and SG-1 reattaches the saved stock (the same id, KNOWN, its account)",
        num(held(v)) .. " " .. tostring(g_fillTypeManager:getFillTypeNameByIndex(v.spec_forageWagon.lastFillType)) .. " " .. tostring(stockAt(sg, bufId(v)) ~= nil and a.stock ~= nil and stockAt(sg, bufId(v)).stockId == a.stock.stockId)
            .. " | " .. bufText(sg, v) .. " | " .. tostring(has(lines, "FIRST FORAGEWAGON BUFFER RESTORED")),
        "100 GRASS_WINDROW true | GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30 | true")
    tickWagon(v)
    T.eq("S2 NAMED: the restored remainder then fills with the next pickup: the unit receives 120 L KNOWN with the whole account",
        outcomeOf(fillOp(host)) .. " | " .. unitText(sg, v), "FORAGE_FILL:COMMITTED | GRASS_WINDROW|120|KNOWN|KNOWN:7:120/120/0/0/30")
    FSBaseMission.delete(m)

    local function refused(index, opts)
        local dir = "w5f_s" .. index
        local aa = saved(dir, index)
        local mm, ssg, _, ww, ll = reloaded(dir, index, aa, opts)
        local vv = ww.wagon
        local restore = vv.spec_forageWagon.sgBufferRestore
        local out = num(held(vv)) .. "/" .. tostring(NA.forageBuffers[bufId(vv)] ~= nil) .. " " .. tostring(restore and table.concat(restore.unresolved, ",")) .. " "
            .. tostring(ssg.operations.retiredStocks[aa.stock.stockId] ~= nil) .. " " .. tostring(has(ll, "a saved forageWagon buffer could not be restored"))
        FSBaseMission.delete(mm)
        return out
    end
    T.eq("S3 NAMED: another configuration at the load restores nothing, seeds nothing, logs once, and SG-1 keeps the saved stock as history",
        refused(211, { wagon = { capacity = 10000, delay = 20000, configFileName = "data/vehicles/forageWagonXL.xml" } }), "0/false CONFIGURATION true true")
    T.eq("S4 NAMED: a fill unit that supports other types restores nothing (FILL_UNIT_TYPES)",
        refused(212, { wagon = { capacity = 10000, delay = 20000, types = { GRASS, DRY } } }), "0/false FILL_UNIT_TYPES true true")
    T.eq("S5 NAMED: a saved fill unit index naming no unit restores nothing (FILL_UNIT)", refused(213, { edit = { ["#fillUnitIndex"] = 3 } }), "0/false FILL_UNIT true true")
    T.eq("S6 NAMED: an unknown type, and a type the unit does not support, restore nothing",
        refused(214, { edit = { ["#lastFillType"] = "NO_SUCH_TYPE" } }) .. " | " .. refused(215, { edit = { ["#lastFillType"] = "WHEAT" } }),
        "0/false FILL_TYPE true true | 0/false FILL_TYPE_UNSUPPORTED true true")
    T.eq("S7 NAMED: bad values restore nothing", refused(216, { edit = { ["#litersToFill"] = -5 } }), "0/false AREA_VALUES true true")
    T.eq("S8 NAMED: a savegame flagged resetVehicles restores nothing and says nothing", refused(217, { reset = true }), "0/false nil true false")
    -- A remainder StockGuard never bound (no token) restores natively and seeds nothing.
    local b = saved("w5f_s218", 218)
    local mm, ssg, _, ww = reloaded("w5f_s218", 218, b, { edit = { ["#token"] = "sgNative:somewhere-else" } })
    T.eq("S9 NAMED: a saved buffer whose token is not this wagon's buffer restores natively and seeds nothing: SG-1's saved stock stays history",
        num(held(ww.wagon)) .. "/" .. tostring(NA.forageBuffers[bufId(ww.wagon)] ~= nil) .. "/" .. tostring(ssg.operations.retiredStocks[b.stock.stockId] ~= nil), "100/false/true")
    FSBaseMission.delete(mm)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. SOIL ABSENT: THE SAME CHAIN, STOCKGUARD ALONE
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    resetWorld()
    soilReset()
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000 }, noSoil = true }
    local m, sg, host, w = boot(o, "w5f_a", 219)
    local v = w.wagon
    tickWagon(v)
    T.eq("A1 NAMED: with Soil absent nothing is admitted or read; the pickup and the fill settle as before and the unit's 100 L carry no Soil record",
        admits() .. "/" .. SOIL5D.reads .. " " .. outcomeOf(pickOp(host)) .. " " .. outcomeOf(fillOp(host)) .. " | " .. unitText(sg, v),
        "0/0 GROUND_FORAGE_PICKUP:COMMITTED FORAGE_FILL:COMMITTED | GRASS_WINDROW|100|UNKNOWN|noRecord")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. THE WAGON GOES: A REMAINDER IS DESTRUCTION
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    resetWorld()
    soilReset()
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000, delay = 20000 } }
    local m, sg, host, w = boot(o, "w5f_x", 220)
    local v = w.wagon
    tickWagon(v)
    local s = stockAt(sg, bufId(v))
    host:onVehicleRemoved(v)
    T.eq("X1 NAMED: a removed wagon's live remainder is retired through a REMOVE as destruction, then the carrier withdrawn",
        tostring(host.lastSettlement and host.lastSettlement.report.outcomeEvidence.nativePath) .. "/" .. tostring(host.lastSettlement and host.lastSettlement.outcome) .. "/"
            .. tostring(sg.operations.carriers[bufId(v)] == nil) .. "/" .. tostring(NA.forageBuffers[bufId(v)] == nil) .. "/" .. tostring(s ~= nil and sg.operations.retiredStocks[s.stockId] ~= nil),
        "FORAGE_BUFFER_DESTRUCTION/COMMITTED/true/true/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A CLIENT'S WAGON: NO FRAME
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetWorld()
    soilReset()
    local o = { lay = { { GRASS, 100, "grass" } }, wagon = { capacity = 10000 } }
    local m, sg, host, w = boot(o, "w5f_c", 221)
    local v = w.wagon
    v.isServer = false
    tickWagon(v)
    T.eq("C1 NAMED: a wagon that is not the server's opens no frame and binds nothing (both brackets check the server)",
        outcomeOf(pickOp(host)) .. "/" .. outcomeOf(fillOp(host)) .. "/" .. tostring(sg.operations.carriers[bufId(v)] == nil), "none/none/true")
    FSBaseMission.delete(m)
end)

end
SG25F_BENCH()
end
