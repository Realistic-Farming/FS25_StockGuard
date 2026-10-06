-- SG2-5e-c-round_mirror_spec_test.lua
--
-- SG2-5e-c, Part 3a, the live half (Bob's 10-05 round-core intake, Part 3; his 10-06 split, Part 3a; his
-- :959 ruling, BOB-INTAKE-SG2-BALE-FAMILY-2026-10-06 section 6): SG-2 v2.3 :473's round mirror and REBIND.
--   * a live round finish (Baler.lua:1427-1436) mounts its bale and keeps the chamber whole: the bale is
--     the chamber's alias (aliasOf the chamber's carrier, its quantityBasisKey, ROUND_BALER_FORMING_V1),
--     never a second carrier; the adapter's resolveAlias names the chamber for it;
--   * the handover, dropBale then the chamber's clear in onUpdateTick (:919-935), is ONE REBIND: the
--     chamber's carrier becomes the bale with its stock and generation, and the clear consumes nothing
--     again;
--   * the REBIND's proof is the report's proved alias (SGOperations, the third branch at :959), which the
--     native adapter vouches for only while its mirror stands;
--   * no mirror, no REBIND: a partial bale (5e-d's), a reload's mounted bale (3b's, after TESTING row 478),
--     a drop outside the unload (Baler:onDelete) and a removed vehicle each keep 5e-b's (c);
--   * a handover that throws, or one the core refuses, falls back to 5e-b's (c);
--   * Soil's own Baler.onUpdateTick scope wraps under or over StockGuard's with the same result.
-- The core's five conditions, each failing alone, are barred in SG-1-core_spec_test.lua (G11d-m).
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv) on 2b's world, copied from
-- SG2-bale-2b-births_spec_test.lua at fc87dbf (ROW86's install, the live Baler class's listeners,
-- WorkArea's order, Soil's 5d surface as a stand-in, 2a's live Bale and the item system, the engine's load
-- order and save). Added to its Baler: the round unload, server paths, from Baler.lua at 1.24: the
-- :1740-1750 pickup gate, setIsUnloadingBale (:1322-1366), dropBale (:1571-1626) and onUpdateTick's unload
-- branch (:919-951), the drop time read from the unloading animation as the engine reads it (:921-922).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's install wraps Baler.onUpdateTick and onLoadFinished on the
-- live class; the Baler's own load wraps its instance finishBale, createBale and dropBale; WorkArea's order
-- runs a tick over a grass windrow a tipper laid and the add's event finishes the round bale; the player's
-- unload opens the door, and onUpdateTick, raised by name as the engine raises it, drops the bale past the
-- drop time. No binding, mirror, catalogue or carrier is written by hand.
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
local function SG25EC_BENCH()

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
    -- ── SG2-5e-c: the round unload (vehicles/specializations/Baler.lua at 1.24) ──────────────────
    B.UNLOADING_CLOSED, B.UNLOADING_OPENING, B.UNLOADING_OPEN, B.UNLOADING_CLOSING = 1, 2, 3, 4   -- :10-13
    --- :1740-1750, the part that bears on a Baler's pickup (the slot, turned-on and consumable tests
    --- abbreviated: always passing here): a full unit, then a round Baler (not non-stop) with a mounted
    --- bale or its door not closed, picks up nothing.
    function B:getIsWorkAreaActive(superFunc, workArea)
        local spec = self.spec_baler
        if self:getFillUnitFreeCapacity(spec.buffer.fillUnitIndex or spec.fillUnitIndex) == 0 then
            return false
        end
        if spec.hasUnloadingAnimation and (not spec.nonStopBaling and (#spec.bales > 0 or spec.unloadingState ~= Baler.UNLOADING_CLOSED)) then
            return false
        end
        return superFunc(self, workArea)
    end
    --- :1322-1366, the server path (the event, the displayed level and the sounds abbreviated). With no
    --- bale mounted and the unfinished-bale unload allowed over its threshold, the chamber is PADDED to
    --- capacity (:1343 lastBaleFillLevel, :1345 the add), and that add's own event finishes the bale;
    --- then the door's unloading animation plays (:1355). Closing plays the close animation (:1363).
    function B:setIsUnloadingBale(isUnloadingBale, noEventSend)
        local spec = self.spec_baler
        if spec.hasUnloadingAnimation then
            if isUnloadingBale then
                if spec.unloadingState ~= Baler.UNLOADING_OPENING then
                    if #spec.bales == 0 and spec.canUnloadUnfinishedBale then
                        local fillTypeIndex = self:getFillUnitFillType(spec.fillUnitIndex)
                        local fillLevel = self:getFillUnitFillLevel(spec.fillUnitIndex)
                        if spec.buffer.fillUnitIndex ~= nil then
                            fillLevel = fillLevel + self:getFillUnitFillLevel(spec.buffer.fillUnitIndex)
                            if fillTypeIndex == FillType.UNKNOWN then
                                fillTypeIndex = self:getFillUnitFillType(spec.buffer.fillUnitIndex)
                            end
                        end
                        if spec.unfinishedBaleThreshold < fillLevel then
                            local delta = self:getFillUnitFreeCapacity(spec.fillUnitIndex)
                            local mainFillLevel = math.min(fillLevel, self:getFillUnitCapacity(spec.fillUnitIndex))
                            spec.lastBaleFillLevel = mainFillLevel
                            self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, delta, fillTypeIndex, ToolType.UNDEFINED)
                            spec.buffer.unloadingStarted = false
                        end
                    end
                    spec.unloadingState = Baler.UNLOADING_OPENING
                    local baleType = spec.baleTypes[spec.currentBaleTypeIndex]
                    self:playAnimation(baleType.animations.unloading, baleType.animations.unloadingSpeed, nil, true)
                    return
                end
            elseif spec.unloadingState ~= Baler.UNLOADING_CLOSING and spec.unloadingState ~= Baler.UNLOADING_CLOSED then
                spec.unloadingState = Baler.UNLOADING_CLOSING
                self:playAnimation(spec.baleCloseAnimationName, spec.baleCloseAnimationSpeed, nil, true)
                return
            end
        end
    end
    --- :1571-1626, the server path (the mission bale, the joint, collisions, velocity, farm stats and the
    --- platform abbreviated): the bale unmounted, a partial bale given its real amount (:1599-1601),
    --- sellable and saved again (:1604-1605), then removed from the list (:1618).
    function B:dropBale(baleIndex)
        local spec = self.spec_baler
        local bale = spec.bales[baleIndex]
        if self.isServer then
            local baleObject = bale.baleObject
            baleObject:unmountKinematic()
            if spec.lastBaleFillLevel ~= nil and #spec.bales == 1 then
                baleObject:setFillLevel(spec.lastBaleFillLevel)
                spec.lastBaleFillLevel = nil
            end
            baleObject:setCanBeSold(true)
            baleObject:setNeedsSaving(true)
        end
        table.remove(spec.bales, baleIndex)
    end
    --- :919-951, the server path (the client's dummy bale, sounds and the unload animation nodes
    --- abbreviated). In UNLOADING_OPENING, while the unloading animation plays and has not reached its drop
    --- time nothing drops (:921-923); past it, or once it stops, the first bale drops and the chamber is
    --- cleared (:925-935); once it stops the door is OPEN (:937-938). CLOSING ends CLOSED once the close
    --- animation stops (:947-948). :956-964 (the automatic and AI drop) is not modelled: the bench unloads
    --- as the player does (Baler:handleUnloadingBaleEvent, :1277-1281, setIsUnloadingBale).
    function B:onUpdateTick(_)
        local spec = self.spec_baler
        if spec.unloadingState == Baler.UNLOADING_OPENING then
            local loadPercentage = spec.baleTypes[spec.currentBaleTypeIndex]
            local stopTime = self:getIsAnimationPlaying(loadPercentage.animations.unloading)
            if stopTime and self:getRealAnimationTime(loadPercentage.animations.unloading) < loadPercentage.animations.dropAnimationTime then
                -- g_animationManager:startAnimations(spec.unloadAnimationNodes), abbreviated
            else
                if #spec.bales > 0 then
                    self:dropBale(1)
                    if self.isServer then
                        self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, self:getFillUnitFillType(spec.fillUnitIndex), ToolType.UNDEFINED)
                        spec.buffer.unloadingStarted = false
                        for fillType, _ in pairs(spec.pickupFillTypes) do
                            spec.pickupFillTypes[fillType] = 0
                        end
                        if self:getFillUnitFillLevel(spec.fillUnitIndex) == 0 and spec.preSelectedBaleTypeIndex ~= spec.currentBaleTypeIndex then
                            self:setBaleTypeIndex(spec.preSelectedBaleTypeIndex, true)
                        end
                    end
                end
                if not stopTime then
                    spec.unloadingState = Baler.UNLOADING_OPEN
                end
            end
        elseif spec.unloadingState == Baler.UNLOADING_CLOSING and not self:getIsAnimationPlaying(spec.baleCloseAnimationName) then
            spec.unloadingState = Baler.UNLOADING_CLOSED
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
    -- SG2-5e-c: the round unload's registered functions, copied as the engine copies them (Baler.lua:157,
    -- :1322; getIsWorkAreaActive an overwritten function whose superFunc is WorkArea's own test), its
    -- listener, and the animation state the unload reads (AnimatedVehicle, a clock per animation).
    v.dropBale, v.setIsUnloadingBale, v.getIsWorkAreaActive = Baler.dropBale, Baler.setIsUnloadingBale, Baler.getIsWorkAreaActive
    v.getOwnerFarmId = v.getOwnerFarmId or function() return 1 end
    v.eventListeners.onUpdateTick = { Baler }
    v.anims = {}
    v.playAnimation = function(self, name, _speed, _time, _noEvent) self.anims[name] = { playing = true, t = 0 } end
    v.getIsAnimationPlaying = function(self, name) local a = self.anims[name] return a ~= nil and a.playing end
    v.getRealAnimationTime = function(self, name) local a = self.anims[name] return a ~= nil and a.t or 0 end
    v.spec_baler = {
        fillUnitIndex = 1, fillScale = opts.fillScale or 1, hasUnloadingAnimation = opts.round == true, nonStopBaling = opts.nonStop == true,
        pickupFillTypes = { [GRASS] = 0, [DRY] = 0, [STRAW_W] = 0 }, pickupOrder = opts.order or { GRASS, DRY, STRAW_W },
        workAreaParameters = { lastPickedUpLiters = 0 },
        additives = { available = opts.additives ~= nil, fillTypes = { GRASS, DRY }, usage = opts.additives and opts.additives.usage or 0, fillUnitIndex = 2 },
        -- SG2-5e-c: no buffer unit unless non-stop (buffer#fillUnitIndex, :434-435), as SG2-5e-b's bench,
        -- so the :1741 gate and the pad (:1330) read the main unit.
        fillUnitOverflowFillLevel = 0, buffer = { fillUnitIndex = opts.nonStop == true and 3 or nil, unloadingStarted = false },
        -- SG2-5e-c: the door (:374-375 canUnloadUnfinishedBale, unfinishedBaleThreshold, 2000 by default),
        -- the bale type's unloading animation and its drop time (:328), the close animation.
        unloadingState = 1, canUnloadUnfinishedBale = opts.canUnloadUnfinished == true, unfinishedBaleThreshold = opts.threshold or 2000,
        preSelectedBaleTypeIndex = 1, baleCloseAnimationName = "baleClose", baleCloseAnimationSpeed = 1,
        bales = {}, baleTypes = { { defaultBaleVariationId = 1, animations = { unloading = "unloadBale", unloadingSpeed = 1, dropAnimationTime = opts.dropTime or 400 } } },
        currentBaleTypeIndex = 1, currentBaleXMLFilename = "bale.xml",
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
    -- SG2-5e-c: :1741's gate on each area (WorkArea.lua:177-196 calls the processing pointer only for
    -- an active area); the superFunc is WorkArea's own test, always true here.
    for _, a in ipairs(wa) do
        if v:getIsWorkAreaActive(function() return true end, a) then a.processingFunction(v, a, 16) end
    end
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

-- ══════════════════════════════════════════════════════════════════════════
-- 5e-c's world: the door, the handover and its readers (one table: the bench function's locals are near
-- Lua's 200-local limit)
-- ══════════════════════════════════════════════════════════════════════════
local X = {}
X.ANIM_MS = { unloadBale = 1000, baleClose = 500 }
function X.copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, val in pairs(t) do out[k] = X.copy(val) end
    return out
end
--- AnimatedVehicle in effect: each playing animation advances `ms` and stops at its end.
function X.animate(v, ms)
    for name, a in pairs(v.anims) do
        if a.playing then
            a.t = a.t + ms
            if a.t >= X.ANIM_MS[name] then a.t, a.playing = X.ANIM_MS[name], false end
        end
    end
end
--- One update tick `ms` after the last: the animations advance, then onUpdateTick is raised by name.
function X.updateTick(v, ms) X.animate(v, ms or 0) ENGINE_RAISE(v, "onUpdateTick", 16) end
--- The player's unload (Baler:handleUnloadingBaleEvent, :1277-1281): the door opens.
function X.unload(v) v:setIsUnloadingBale(true) end
--- The handover in the engine's ticks: the door opened, two ticks before the drop time (100 and 300 ms of
--- a 400 ms drop time), the drop tick (500 ms), the animation's end (1000 ms: the door OPEN).
function X.handover(v)
    X.unload(v)
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    X.updateTick(v, 200)
    X.updateTick(v, 500)
end
--- The door closed again (:1360-1365), then CLOSING ends CLOSED (:947-948).
function X.close(v) v:setIsUnloadingBale(false) X.updateTick(v, 500) end
function X.rebindText(r) return tostring(r.outcome) .. (r.reason and (":" .. tostring(r.reason)) or "") end
--- Every handover recorded since this world was built (X.mounted sets X.n0), in order, or "none": a
--- row never reads another world's record.
--- The handover record (absent before 5e-c, so a base run fails on its rows, not on a nil).
function X.list() return GO_.rebinds or {} end
function X.since()
    local out = {}
    for i = X.n0 + 1, #X.list() do out[#out + 1] = X.rebindText(X.list()[i]) end
    return #out == 0 and "none" or table.concat(out, ",")
end
--- The reason a call returned second, nil included (a carrier alone is no reason).
function X.why(...) local _, w = ... return tostring(w) end
function X.mirrors() local n = 0 for _ in pairs(NA.roundMirrors) do n = n + 1 end return n end
function X.carrier(sg, id) return id ~= nil and sg.operations.carriers[id] or nil end
--- A round Baler after one tick of 100 L into its 100 L chamber: the bale finished and mounted.
--- Returns the mission, StockGuard, host, world and the mounted bale.
function X.mounted(key, index, opts)
    resetWorld()
    soilReset()
    local o = { capacity = 100, round = true }
    for k, val in pairs(opts or {}) do o[k] = val end
    local m, sg, host, w = boot2b(o, key, index)
    tick(w.baler)
    X.n0 = #X.list()
    return m, sg, host, w, listed(w.baler)[1]
end
--- The handover's REBIND report, built as G.rebindClose builds it, for the mounted bale over the chamber.
function X.report(chamber, bale, alias)
    return { participantsAfter = { [chamber] = { materialRef = { kind = "FILL_TYPE", fillTypeName = "GRASS_WINDROW" }, amount = 100, unit = NA.UNIT, storeKind = NA.BALE_STORE } },
             replacements = { { carrierId = chamber, binding = NA.baleBinding(bale) } }, provedAliases = { X.copy(alias) } }
end
--- Soil's Baler.onUpdateTick scope, a stand-in of BalerCollection.aroundTick (SoilFertilizer
--- src/ground/BalerCollection.lua:616-625, installed by HookManager.lua:5706-5712 on the class): a scope
--- held while the original runs. `seen` counts its calls and notes whether dropBale ran inside it.
function X.soilTick(class, seen)
    local origTick = class.onUpdateTick
    class.onUpdateTick = function(balerSelf, ...)
        seen.calls = seen.calls + 1
        seen.scope = true
        local packed = { pcall(origTick, balerSelf, ...) }
        seen.scope = false
        if not packed[1] then error(packed[2], 0) end
        return unpack(packed, 2)
    end
end
--- One handover with Soil's scope in a given order on a fresh Baler class (a map load re-sources
--- Baler.lua, Baler.lua:7): "under" installs it before main.lua's install, "over" after. Returns its text.
function X.soilOrder(order, key, index)
    local seen = { calls = 0, scope = false, dropInScope = nil }
    REAL.Baler = X.newClass()
    if order == "under" then X.soilTick(Baler, seen) end
    local m, sg, host, w, bale = X.mounted(key, index)
    if order == "over" then X.soilTick(Baler, seen) end
    local v = w.baler
    local stockId = stockAt(sg, unitId(v)).stockId
    local drop = v.dropBale
    v.dropBale = function(self, ...) seen.dropInScope = seen.scope return drop(self, ...) end
    X.handover(v)
    local s = baleStock(sg, bale)
    local text = X.since() .. "|" .. stockText(s) .. "|" .. tostring(s ~= nil and s.stockId == stockId) .. "|" .. tostring(X.carrier(sg, unitId(v)))
        .. "|" .. seen.calls .. "|" .. tostring(seen.dropInScope)
    FSBaseMission.delete(m)
    return text
end
X.newClass = newBalerClass

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A ROUND BALE'S HANDOVER IS ONE REBIND
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local m, sg, host, w, bale = X.mounted("b3ae", 401)
    local v = w.baler
    local rec = rawget(v, GO_.FINISH_MARKER)
    T.ok("E0 [reached] main.lua's install wrapped the live Baler class's onUpdateTick and onLoadFinished (SGClassHook), and the Baler's own load raised onLoadFinished: its instance dropBale, like finishBale and createBale, is StockGuard's wrapper over the copy the engine made",
        SGClassHook.record(Baler, "onUpdateTick", GO_.HOOK_ID) ~= nil and SGClassHook.record(Baler, "onLoadFinished", GO_.HOOK_ID) ~= nil
            and rec ~= nil and v.dropBale == rec.dropWrapper and rec.drop == Baler.dropBale and v.finishBale == rec.finishWrapper)
    local chamber = unitId(v)
    local before = stockAt(sg, chamber)
    local mirror = bale ~= nil and NA.roundMirrorOf(bale) or nil
    local a = mirror ~= nil and mirror.alias or {}
    local chamberBasis = X.carrier(sg, chamber) and X.carrier(sg, chamber).binding.quantityBasisKey or nil
    T.eq("E1 NAMED: the tick's add filled the 100 L round chamber and its event finished the bale, mounted, the chamber whole (5e-b's (a)); the finish noted the mirror: the bale's own key, aliasOf the chamber's carrier, the chamber's quantityBasisKey, ROUND_BALER_FORMING_V1 in its sourceDescriptor; the bale is no carrier",
        stockText(before) .. "|" .. tostring(bale ~= nil and bale.mounted) .. "|" .. tostring(a.aliasOf == chamber) .. "/" .. tostring(chamberBasis ~= nil and a.quantityBasisKey == chamberBasis)
            .. "/" .. tostring(a.sourceDescriptor and a.sourceDescriptor.profile) .. "/" .. tostring(bale ~= nil and SGValues.equal(a.carrierKey, NA.baleBinding(bale).carrierKey))
            .. "|" .. tostring(bale ~= nil and baleStock(sg, bale)) .. "|" .. tostring(bale ~= nil and X.carrier(sg, baleId(bale))),
        ACC .. "|true|true/true/ROUND_BALER_FORMING_V1/true|nil|nil")
    local stockId, generation = before and before.stockId, before and before.contentsGeneration
    X.unload(v)
    local n0 = #X.list()
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    T.eq("E2 the door opening: two ticks before the unloading animation's drop time drop nothing, so nothing opens: no REBIND, the mirror stands, the bale still mounted, the chamber's stock whole",
        (#X.list() - n0) .. "|" .. tostring(NA.roundMirrorOf(bale) ~= nil) .. "|" .. tostring(bale.mounted) .. "|" .. stockText(stockAt(sg, chamber)),
        "0|true|true|" .. ACC)
    X.updateTick(v, 200)
    local s = baleStock(sg, bale)
    T.eq("E3 NAMED [entry point]: the tick past the drop time dropped the bale and cleared the chamber (:926-928), ONE REBIND, committed: the chamber's carrier moved to the bale's own binding with the SAME stock and generation and its account (SG-1 :224); the stock's quantity is the bale's own; the clear's report was the REBIND's, so nothing rebound the empty chamber (5e-b's replay would have)",
        X.since() .. "|" .. stockText(s) .. "|" .. tostring(s ~= nil and s.stockId == stockId and s.contentsGeneration == generation)
            .. "|" .. tostring(s ~= nil and s.quantityBasisKey == baleId(bale)) .. "|" .. tostring(X.carrier(sg, chamber)),
        "COMMITTED|" .. ACC .. "|true|true|nil")
    T.eq("E4 the alias retired with the handover: the mirror is gone, the alias names nothing now (resolveAlias refuses it: ALIAS_ERROR), and the bale is the world bale's carrier (2a)",
        X.mirrors() .. "|" .. X.why(m.stockGuard.refreshCarrier(host.nativeLease, a, "TEST")) .. "|" .. tostring(bale.mounted) .. "|" .. tostring(X.carrier(sg, baleId(bale)) ~= nil),
        "0|ALIAS_ERROR|false|true")
    X.updateTick(v, 500)
    X.close(v)
    relay(m, w, GRASS, 100, "g2")
    tick(v)
    local bale2 = listed(v)[1]
    X.handover(v)
    local s2 = bale2 ~= nil and baleStock(sg, bale2) or nil
    T.eq("E5 the next bale: with the door closed the pickup runs again, the empty chamber is bound afresh, and the second bale's handover is a second REBIND: it holds a NEW stock with its own account; the first bale's is unchanged",
        X.since() .. "|" .. stockText(s2) .. "|" .. tostring(s2 ~= nil and s2.stockId ~= stockId) .. "|" .. stockText(baleStock(sg, bale)),
        "COMMITTED,COMMITTED|" .. ACC .. "|true|" .. ACC)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ALIAS IS NEVER A SECOND CARRIER (SG-2 :473: one material, counted once)
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    local m, sg, host, w, bale = X.mounted("b3aa", 402)
    local v = w.baler
    local alias = NA.roundMirrorOf(bale).alias
    local c, why = m.stockGuard.refreshCarrier(host.nativeLease, X.copy(alias), "TEST")
    T.eq("A1 NAMED: the core's join, asked with the alias binding, gets the chamber's own carrier back, never a second carrier for the mounted bale: no bale carrier exists",
        tostring(c ~= nil and c.carrierId == unitId(v)) .. "|" .. tostring(why) .. "|" .. baleStocks(sg) .. "|" .. tostring(X.carrier(sg, baleId(bale))),
        "true|nil|0|nil")
    local otherOf = X.copy(alias)
    otherOf.aliasOf = "another carrier"
    local otherBasis = X.copy(alias)
    otherBasis.quantityBasisKey = baleId(bale)
    local loose = worldBale(GRASS, 50)
    local unmirrored = NA.roundAliasBinding(loose, NA.fillUnitBinding(v, 1))
    T.eq("A2 the adapter vouches only for its own mirror's alias: an alias of another carrier, one over another quantity basis, and one of a bale it never mirrored are each refused (ALIAS_ERROR), never bound as themselves",
        X.why(m.stockGuard.refreshCarrier(host.nativeLease, otherOf, "TEST")) .. "|" .. X.why(m.stockGuard.refreshCarrier(host.nativeLease, otherBasis, "TEST"))
            .. "|" .. X.why(m.stockGuard.refreshCarrier(host.nativeLease, unmirrored, "TEST")) .. "|" .. baleStocks(sg),
        "ALIAS_ERROR|ALIAS_ERROR|ALIAS_ERROR|0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PROOF THROUGH THE NATIVE ADAPTER: VOUCHED ONLY WHILE THE MIRROR STANDS (condition 4)
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local m, sg, host, w, bale = X.mounted("b3ap", 403)
    local chamber = unitId(w.baler)
    local stockId = stockAt(sg, chamber).stockId
    local cap = m.stockGuard.captureOperation(host.nativeLease, "REBIND", { { carrierId = chamber } })
    local out, why = m.stockGuard.settleOperation(cap.handle, X.report(chamber, bale, NA.roundMirrorOf(bale).alias))
    T.eq("P0 the handover's report, settled by hand while the mirror stands: COMMITTED, the chamber's stock on the bale's carrier",
        tostring(out) .. ":" .. tostring(why) .. "|" .. tostring(baleStock(sg, bale) ~= nil and baleStock(sg, bale).stockId == stockId), "COMMITTED:nil|true")
    FSBaseMission.delete(m)
    m, sg, host, w, bale = X.mounted("b3ap2", 404)
    chamber = unitId(w.baler)
    local alias = X.copy(NA.roundMirrorOf(bale).alias)
    NA.retireRoundMirror(bale)
    cap = m.stockGuard.captureOperation(host.nativeLease, "REBIND", { { carrierId = chamber } })
    out, why = m.stockGuard.settleOperation(cap.handle, X.report(chamber, bale, alias))
    T.eq("P1 NAMED (condition 4): the same report once the mirror has retired is refused: the adapter no longer resolves the alias to the chamber, so the alias proves nothing",
        tostring(out) .. ":" .. tostring(why) .. "|" .. tostring(baleStock(sg, bale)), "UNRESOLVED:REPLACEMENT_UNPROVED|nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. A HANDOVER THAT FAILS FALLS BACK TO 5e-b's (c)
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m, sg, host, w, bale = X.mounted("b3af", 405)
    local v = w.baler
    local chamber = unitId(v)
    -- Another mod's code failing inside the clear (:928), before any level changes.
    local add = v.addFillUnitFillLevel
    v.addFillUnitFillLevel = function(self, farmId, index, delta, ...)
        if delta == -math.huge then error("a listener failed in the clear", 0) end
        return add(self, farmId, index, delta, ...)
    end
    X.unload(v)
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    local okTick, err = pcall(X.updateTick, v, 200)
    v.addFillUnitFillLevel = add
    local s = stockAt(sg, chamber)
    T.eq("F1 NAMED: a tick that throws before the clear leaves the chamber full under a dropped bale: abandoned (QUALIFIED), the error reaches the engine unchanged, the mirror retires, the bale gets no record, and the chamber's stock is qualified, never moved",
        X.since() .. "|" .. tostring(okTick) .. ":" .. tostring(err) .. "|" .. X.mirrors() .. "|" .. tostring(baleStock(sg, bale)) .. "|" .. tostring(s ~= nil and s.reason),
        "ABANDONED:QUALIFIED|false:a listener failed in the clear|0|nil|ABANDONED:REBIND_UNPROVED")
    FSBaseMission.delete(m)
    m, sg, host, w, bale = X.mounted("b3af1b", 414)
    v = w.baler
    chamber = unitId(v)
    -- The same failure AFTER the clear: native has handed the bale over.
    add = v.addFillUnitFillLevel
    v.addFillUnitFillLevel = function(self, farmId, index, delta, ...)
        local applied = add(self, farmId, index, delta, ...)
        if delta == -math.huge then error("a listener failed after the clear", 0) end
        return applied
    end
    X.unload(v)
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    okTick, err = pcall(X.updateTick, v, 200)
    v.addFillUnitFillLevel = add
    T.eq("F1b a tick that throws AFTER the clear: native dropped the bale and cleared the chamber, so native's state decides, as 2b's finish: ONE REBIND, committed; the error still reaches the engine unchanged",
        X.since() .. "|" .. tostring(okTick) .. ":" .. tostring(err) .. "|" .. X.mirrors() .. "|" .. stockText(baleStock(sg, bale)) .. "|" .. tostring(X.carrier(sg, chamber)),
        "COMMITTED|false:a listener failed after the clear|0|" .. ACC .. "|nil")
    FSBaseMission.delete(m)
    -- Another mod's overwritten dropBale (as BaleCounter.lua:21, :112 overwrites it) failing before the
    -- unmount; installed before StockGuard's install, so StockGuard's wrap sits over it.
    m, sg, host, w, bale = X.mounted("b3af3", 415, { build = function(_, wb)
        local drop = wb.baler.dropBale
        wb.baler.dropBale = function(self, i, ...)
            if self.failDrop then error("an overwritten dropBale failed", 0) end
            return drop(self, i, ...)
        end
    end })
    v = w.baler
    chamber = unitId(v)
    v.failDrop = true
    X.unload(v)
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    okTick, err = pcall(X.updateTick, v, 200)
    s = stockAt(sg, chamber)
    T.eq("F3 a drop that throws before the unmount leaves the bale on: abandoned (QUALIFIED), the error unchanged, the mirror retired, the bale still mounted and no carrier, the chamber's stock qualified",
        X.since() .. "|" .. tostring(okTick) .. ":" .. tostring(err) .. "|" .. X.mirrors() .. "|" .. tostring(bale.mounted) .. "|" .. tostring(X.carrier(sg, baleId(bale))) .. "|" .. tostring(s ~= nil and s.reason),
        "ABANDONED:QUALIFIED|false:an overwritten dropBale failed|0|true|nil|ABANDONED:REBIND_UNPROVED")
    FSBaseMission.delete(m)
    -- An overwritten dropBale that never calls the original: the clear still runs under a bale left on.
    m, sg, host, w, bale = X.mounted("b3af4", 416, { build = function(_, wb) wb.baler.dropBale = function() end end })
    v = w.baler
    X.unload(v)
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    X.updateTick(v, 200)
    T.eq("F4 a drop that never unmounts while the chamber is still cleared: no REBIND can be proved (the bale cannot be read while mounted), so it is abandoned, the clear's report replays and ends the chamber's stock as 5e-b's (c), and the mirror retires",
        X.since() .. "|" .. X.mirrors() .. "|" .. tostring(bale.mounted) .. "|" .. chamberText(sg, v) .. "|" .. tostring(X.carrier(sg, baleId(bale))),
        "ABANDONED:QUALIFIED|0|true|none|nil")
    FSBaseMission.delete(m)
    m, sg, host, w, bale = X.mounted("b3af2", 406)
    v = w.baler
    chamber = unitId(v)
    -- A report the core refuses: the proof withheld on its way in.
    local settle = m.stockGuard.settleOperation
    m.stockGuard.settleOperation = function(h, report)
        if type(report) == "table" and report.replacements ~= nil then report.provedAliases = nil end
        return settle(h, report)
    end
    X.handover(v)
    m.stockGuard.settleOperation = settle
    T.eq("F2 NAMED: a REBIND the core refuses consumes nothing: the clear's report replays and ends the chamber's stock as before 5e-c (the chamber bound empty), the bale gets no record, the mirror retires",
        X.since() .. "|" .. tostring(X.carrier(sg, chamber) ~= nil) .. "|" .. chamberText(sg, v) .. "|" .. tostring(baleStock(sg, bale)) .. "|" .. X.mirrors(),
        "UNRESOLVED:REPLACEMENT_UNPROVED|true|none|nil|0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. NO MIRROR, NO REBIND: THE PARTIAL BALE (5e-d's), A DROP OUTSIDE THE UNLOAD, A REMOVED VEHICLE
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local m, sg, host, w = X.mounted("b3an", 407, { canUnloadUnfinished = true, threshold = 30, lay = { { GRASS, 50, "grass" } } })
    local v = w.baler
    local n0 = #X.list()
    local held = num(level(v)) .. "/" .. #v.spec_baler.bales
    X.unload(v)
    local bale = listed(v)[1]
    local padded = num(level(v)) .. "/" .. tostring(bale ~= nil and bale.mounted) .. "/" .. X.mirrors()
    X.updateTick(v, 100)
    X.updateTick(v, 200)
    X.updateTick(v, 200)
    T.eq("N1 NAMED: 50 L, then the unload of an unfinished bale: the pad (:1343-1345) finished a bale inside its add, and that finish is 5e-d's, not mirrored; its drop is no REBIND: the bale takes its real 50 L (:1599-1601), the clear ends the chamber's stock as 5e-b's (c), and the bale has no record",
        held .. "|" .. padded .. "|" .. (#X.list() - n0) .. "|" .. num(bale and bale:getFillLevel()) .. "|" .. chamberText(sg, v) .. "|" .. tostring(bale and baleStock(sg, bale)),
        "50/0|100/true/0|0|50|none|nil")
    FSBaseMission.delete(m)
    local bale2
    m, sg, host, w, bale2 = X.mounted("b3an2", 408)
    v = w.baler
    n0 = #X.list()
    v:dropBale(1)
    T.eq("N2 a drop outside the unload tick (Baler:onDelete drops its bales so, :594) is no REBIND and only retires the mirror; the chamber, not cleared, keeps its stock; the bale has no record",
        (#X.list() - n0) .. "|" .. X.mirrors() .. "|" .. chamberText(sg, v) .. "|" .. tostring(bale2.mounted) .. "|" .. tostring(baleStock(sg, bale2)),
        "0|0|" .. ACC .. "|false|nil")
    FSBaseMission.delete(m)
    m, sg, host, w = X.mounted("b3an3", 409)
    v = w.baler
    local had = X.mirrors()
    VehicleSystem.removeVehicle(m.vehicleSystem, v)
    T.eq("N3 a Baler removed with its bale mounted takes its mirror with it (SGNativeHost.onVehicleRemoved), as its chamber's carrier",
        had .. "|" .. X.mirrors() .. "|" .. tostring(X.carrier(sg, unitId(v))), "1|0|nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. A RELOAD'S MOUNTED BALE: NO MIRROR UNTIL PART 3b (after TESTING row 478)
-- ══════════════════════════════════════════════════════════════════════════
-- Whether native also saves the mounted bale as a world item (row 478) is not asserted here: the
-- model's item save keeps it as it keeps any bale whose needsSaving is true (ItemSystem.lua:170), and
-- what that duplicate means is 3b's.
group("R", function()
    local m, sg, host, w = X.mounted("b3ar", 410)
    local m2, sg2, host2, w2 = reload2b(m, w, "b3ar_save", 411, { capacity = 100, round = true })
    local v = w2.baler
    local bale = listed(v)[1]
    local n0 = #X.list()
    local restored = chamberText(sg2, v) .. "|" .. tostring(bale ~= nil and bale.mounted) .. "|" .. X.mirrors()
    X.handover(v)
    T.eq("R1 NAMED: the chamber saved full reloads with its record and the reload's finish (:570-575, before the barrier) mounts a bale with NO mirror; its handover is no REBIND: the clear ends the chamber's stock as 5e-b's (c), and the bale has no record (Bob's 3a/3b split)",
        restored .. "|" .. (#X.list() - n0) .. "|" .. chamberText(sg2, v) .. "|" .. tostring(bale and baleStock(sg2, bale)),
        ACC .. "|true|0|0|none|nil")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. SOIL'S OWN Baler.onUpdateTick SCOPE, UNDER AND OVER STOCKGUARD'S (Bob's 5e intake, Part 3)
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local saved = REAL.Baler
    local under = X.soilOrder("under", "b3as1", 412)
    local over = X.soilOrder("over", "b3as2", 413)
    REAL.Baler = saved
    T.eq("S1 NAMED: Soil's tick scope installed before main.lua's install (under StockGuard's wrap) and after it (over): the same one REBIND, the same stock moved, the chamber unbound, Soil's scope run on each of the four ticks with the drop inside it",
        under .. "||" .. over,
        "COMMITTED|" .. ACC .. "|true|nil|4|true||COMMITTED|" .. ACC .. "|true|nil|4|true")
end)
end
SG25EC_BENCH()
end
