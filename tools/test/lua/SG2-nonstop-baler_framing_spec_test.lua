-- SG2-nonstop-baler_framing_spec_test.lua
--
-- SG2 non-stop baler framing, PR 2 (Bob's intake BOB-INTAKE-SG2-NONSTOP-BALER-FRAMING-2026-10-09; SG-2
-- v2.3 :471, RSF-F211 :76, :88, :94, :96, :100; src/native/SGBalerNonStop.lua): a non-stop Baler's buffer
-- is now framed. The gate (G.balerFramed) admits a non-stop Baler while SGBalerNonStop.lua is loaded; the
-- pickup tick's add settles on whichever fill unit native chose (buffer or main, :1979-1999); the overload
-- inside Baler:onUpdateTick (:996-1062) is one TRANSFER of the buffer's accepted debit to the chamber and a
-- transient before the main add's original listener, then the overflow and the transient's remainder after
-- it; the pad marker on setIsUnloadingBale keeps the automatic/partial-bale pad from being read as an
-- overload.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on SG2-5e-c's preamble and Baler model (copied
-- unedited from SG2-5e-c-round_mirror_spec_test.lua: ROW86's world, Soil's 5d surface as a stand-in, 2a's
-- live Bale and item system, the engine's load order and save, the round unload). Added to the model, each
-- transcribed from Baler.lua at 1.24 in native order: the buffer's own config fields (:434-442, :460-461);
-- the overload step inside onUpdateTick (:996-1064, the additive gain at :1023-1051, the main add at
-- :1052); the automatic drop's setIsUnloadingBale call inside onUpdateTick (:957-961, abbreviated to the
-- door-closed-with-a-bale test, isUnloadingAllowed and getIsAIActive assumed true); the pad's buffer debit
-- and main add inside setIsUnloadingBale (:1324-1347; the decompile shadows a local there, so the pad's
-- buffer debit is modelled as -(math.min(total, mainCapacity) - currentMainLevel) floored at 0 and the
-- main add as the main's free capacity, per Bob's intake's reading of that shadowing). getIsTurnedOn is
-- modelled true throughout: none of Bob's rows toggles it, so the overload's isTurnedOn gates are not
-- exercised either way. isUnloadingAllowed, getIsAIActive, platform and sound/animation paths are not in
-- this model: nothing here reads them.
--
-- THE ENTRY-POINT BAR IS GROUP N/O/M/P/S/C/K: main.lua's install wraps the live Baler class's onUpdateTick,
-- onFillUnitFillLevelChanged (through FillUnit's class listener) and onLoadFinished; the Baler's own load
-- wraps its instance finishBale, createBale, dropBale and setIsUnloadingBale; WorkArea's order runs real
-- pickup ticks over a grass windrow a tipper laid; the overload is driven by raising onUpdateTick by name,
-- as the engine raises it; the finish and the handover run through their real wraps. No hand-populated
-- record, buffer account, overflow entry or transient.
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGSoilCondition.lua, src/native/SGCollectionSeal.lua, src/native/SGFieldToolBufferSave.lua, src/native/SGBalerNonStop.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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
-- SG2 non-stop framing: MathUtil.round (shared/MathUtil.lua), used at Baler.lua:441 and in the model's
-- own overload step below (the same rounding on both sides of the gate, as the engine's own call is).
MathUtil.round = MathUtil.round or function(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end

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
local function SG2NS_BENCH()

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
    --- SG2 non-stop framing: :1339-1341's buffer debit, the decompiler's shadowed local renamed
    --- currentMainLevel so the debit is -(math.min(total, mainCapacity) - currentMainLevel), floored at 0
    --- by FillUnit's own clamp (Bob's intake's reading of that shadowing; the main add (:1345) stays the
    --- main's free capacity, read before either add).
    function B:setIsUnloadingBale(isUnloadingBale, noEventSend)
        local spec = self.spec_baler
        if spec.hasUnloadingAnimation then
            if isUnloadingBale then
                if spec.unloadingState ~= Baler.UNLOADING_OPENING then
                    if #spec.bales == 0 and spec.canUnloadUnfinishedBale then
                        local fillTypeIndex = self:getFillUnitFillType(spec.fillUnitIndex)
                        local currentMainLevel = self:getFillUnitFillLevel(spec.fillUnitIndex)
                        local fillLevel = currentMainLevel
                        if spec.buffer.fillUnitIndex ~= nil then
                            fillLevel = fillLevel + self:getFillUnitFillLevel(spec.buffer.fillUnitIndex)
                            if fillTypeIndex == FillType.UNKNOWN then
                                fillTypeIndex = self:getFillUnitFillType(spec.buffer.fillUnitIndex)
                            end
                        end
                        if spec.unfinishedBaleThreshold < fillLevel then
                            local delta = self:getFillUnitFreeCapacity(spec.fillUnitIndex)
                            local mainFillLevel = math.min(fillLevel, self:getFillUnitCapacity(spec.fillUnitIndex))
                            if spec.buffer.fillUnitIndex ~= nil then
                                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.buffer.fillUnitIndex, -math.max(mainFillLevel - currentMainLevel, 0), self:getFillUnitFillType(spec.buffer.fillUnitIndex), ToolType.UNDEFINED)
                            end
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
    --- animation stops (:947-948). The AI drop is not modelled (self:getIsAIActive() assumed false).
    --- SG2 non-stop framing: :957-965 (the automatic drop, isUnloadingAllowed and hasUnloadingAnimation
    --- assumed true) and the nonStopBaling overload (:996-1064), both inside `if self.isServer then`,
    --- transcribed in native order after the door handling above (dt taken as 16, this bench's tick step).
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
        if self.isServer then
            -- :957-961 ABBREVIATED: isUnloadingAllowed() and (hasUnloadingAnimation or allowsBaleUnloading)
            -- and getIsAIActive() assumed true/false as noted; spec.automaticDrop alone gates it here.
            -- NOT CONFIRMED AGAINST THE DECOMPILE: :959's own gate reads `#spec.bales > 0`, which excludes
            -- the pad's own `#spec.bales == 0` branch, so this bench cannot show the pad reached through
            -- THIS call with #bales > 0 (native's own text). spec.automaticDrop == "pad" bypasses that one
            -- clause (bales check only) so P0 can still drive setIsUnloadingBale from inside onUpdateTick,
            -- as Bob's intake names reachable at :960; reported as unverified rather than asserted as fact.
            if spec.automaticDrop and spec.unloadingState == Baler.UNLOADING_CLOSED and (#spec.bales > 0 or spec.automaticDrop == "pad") then
                self:setIsUnloadingBale(true)
            end
            -- :996-1064, the overload VERBATIM in effect (the effects, sounds and dirty flags abbreviated;
            -- dt is 16 for this bench's tick).
            if spec.nonStopBaling then
                local bufferLevel = self:getFillUnitFillLevel(spec.buffer.fillUnitIndex)
                if bufferLevel > 0 then
                    local bufferCapacity = self:getFillUnitCapacity(spec.buffer.fillUnitIndex)
                    if self:getIsTurnedOn() and MathUtil.round(bufferLevel / bufferCapacity, 2) >= spec.buffer.overloadingStartFillLevelPct then
                        local mainCapacity = self:getFillUnitCapacity(spec.fillUnitIndex)
                        if (mainCapacity == 0 or mainCapacity == math.huge or self:getFillUnitFreeCapacity(spec.fillUnitIndex) > 0)
                            and not spec.buffer.unloadingStarted and spec.unloadingState == Baler.UNLOADING_CLOSED then
                            spec.buffer.unloadingStarted = true
                            spec.buffer.overloadingTimer = 0
                        end
                    end
                    if spec.buffer.unloadingStarted then
                        spec.buffer.overloadingTimer = spec.buffer.overloadingTimer + 16
                        if spec.buffer.overloadingTimer >= spec.buffer.overloadingDelay and self:getFillUnitFreeCapacity(spec.fillUnitIndex) > 0 then
                            local perTick = self:getFillUnitCapacity(spec.buffer.fillUnitIndex) / spec.buffer.overloadingDuration * 16
                            local delta = math.min(perTick, bufferLevel)
                            local bufferFillType = self:getFillUnitFillType(spec.buffer.fillUnitIndex)
                            local debited = self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.buffer.fillUnitIndex, -delta, bufferFillType, ToolType.UNDEFINED)
                            local mainFillType = self:getFillUnitFillType(spec.fillUnitIndex)
                            if mainFillType ~= FillType.UNKNOWN then bufferFillType = mainFillType end
                            local overloadedLiters = -debited
                            if spec.additives.available and spec.additives.appliedByBufferOverloading then
                                local supported = false
                                for i = 1, #spec.additives.fillTypes do
                                    if bufferFillType == spec.additives.fillTypes[i] then supported = true break end
                                end
                                if supported then
                                    local additivesLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
                                    if additivesLevel > 0 then
                                        local usage = spec.additives.usage * overloadedLiters
                                        if usage > 0 then
                                            overloadedLiters = overloadedLiters * (1 + 0.05 * math.min(additivesLevel / usage, 1))
                                            self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                                        end
                                    end
                                end
                            end
                            self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, overloadedLiters, bufferFillType, ToolType.UNDEFINED)
                        end
                        if self:getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0 or not self:getIsTurnedOn() then
                            spec.buffer.unloadingStarted = false
                        end
                    end
                elseif not spec.buffer.fillMainUnitAfterOverload then
                    spec.buffer.unloadingStarted = false
                end
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
    -- SG2 non-stop framing: a non-stop Baler's buffer unit (buffer#fillUnitIndex, :434-435), so its
    -- pickup area is active under :1741's free-capacity test and its overload has something to move.
    if opts.nonStop == true then
        -- A real non-stop Baler has its additive unit 2 before the buffer; ipairs over the units (the vehicle save) needs no hole.
        if v.spec_fillUnit.fillUnits[2] == nil then
            v.spec_fillUnit.fillUnits[2] = { fillLevel = 0, capacity = 0, fillType = FillType.UNKNOWN, lastValidFillType = FillType.UNKNOWN, supportedFillTypes = {} }
        end
        v.spec_fillUnit.fillUnits[3] = { fillLevel = opts.bufferLevel or 0, capacity = opts.bufferCapacity or opts.capacity or 1000,
                                          fillType = FillType.UNKNOWN, lastValidFillType = FillType.UNKNOWN,
                                          supportedFillTypes = { [GRASS] = true, [DRY] = true, [STRAW_W] = true } }
    end
    v.addFillUnitFillLevel = fillUnitAdd
    v.getIsTurnedOn = function() return opts.turnedOn ~= false end
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
        additives = { available = opts.additives ~= nil, fillTypes = { GRASS, DRY }, usage = opts.additives and opts.additives.usage or 0, fillUnitIndex = 2,
                      appliedByBufferOverloading = opts.additives ~= nil and opts.additives.appliedByBufferOverloading == true },
        -- SG2-5e-c: no buffer unit unless non-stop (buffer#fillUnitIndex, :434-435), as SG2-5e-b's bench,
        -- so the :1741 gate and the pad (:1330) read the main unit. SG2 non-stop framing: the buffer's own
        -- config fields (:436-442, :461): overloadingStartFillLevelPct (round(,2), :441), overloadingDuration
        -- (default 1, :438), overloadingDelay (default 0, :439), fillMainUnitAfterOverload (default false,
        -- :442, read by the pickup receiver at :1979-1987 too).
        fillUnitOverflowFillLevel = 0, buffer = { fillUnitIndex = opts.nonStop == true and 3 or nil, unloadingStarted = opts.unloadingStarted == true, overloadingTimer = 0,
                                                   overloadingStartFillLevelPct = MathUtil.round(opts.overloadingStartFillLevelPct or 0.75, 2),
                                                   overloadingDuration = opts.overloadingDuration or 1, overloadingDelay = opts.overloadingDelay or 0,
                                                   fillMainUnitAfterOverload = opts.fillMainUnitAfterOverload == true },
        -- SG2 non-stop framing: the automatic drop's own flag (:957-958), abbreviated: isUnloadingAllowed
        -- and getIsAIActive are assumed true, so automaticDrop alone drives it.
        automaticDrop = opts.automaticDrop or false,
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
-- ── SG2 non-stop framing: readers over the overload scope (host.lastBalerOverload, SGBalerNonStop) ──
local function bufferId(v) return unitId(v, 3) end
local function bufferText(sg, v) return stockText(stockAt(sg, bufferId(v))) end
--- The overload's operations: nativePath:outcome[:reason] (host.lastBalerOverload, set at M.close).
local function ovOpsText(host)
    local ov = host.lastBalerOverload
    local out = {}
    for _, op in ipairs(ov and ov.operations or {}) do
        local e = op.evidence or {}
        out[#out + 1] = tostring(e.nativePath) .. ":" .. tostring(op.outcome) .. ((op.outcome ~= "COMMITTED" and op.reason) and (":" .. tostring(op.reason)) or "")
    end
    return table.concat(out, " ")
end
local function ovOpOf(host, path)
    local ov = host.lastBalerOverload
    for _, op in ipairs(ov and ov.operations or {}) do
        if op.evidence and op.evidence.nativePath == path then return op end
    end
    return nil
end
--- Did this tick arm, and did it settle (SGBalerNonStop.observe/settleOverload)?
local function ovState(host)
    local ov = host.lastBalerOverload
    if ov == nil then return "none" end
    return tostring(ov.armed) .. "/" .. tostring(ov.settled)
end
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
--- The handovers the current host recorded (host.rebindCount, absent before 5e-c, so a base run fails
--- on its rows, not on a nil).
function X.count() local h = NH.current return h ~= nil and h.rebindCount or 0 end
--- The handovers since this world was built (X.mounted sets X.n0) and the host's last one,
--- "<n>:<outcome>[:<reason>]", or "none": a row never reads another world's record.
function X.since()
    local n = X.count() - X.n0
    if n == 0 then return "none" end
    return n .. ":" .. X.rebindText(NH.current.lastRebind)
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
    X.n0 = X.count()
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
-- SETUP: a non-stop round Baler, one real pickup tick, ready for one onUpdateTick
-- ══════════════════════════════════════════════════════════════════════════
--- opts: boot5db's, plus bufferLitres (one windrow's litres laid at the pickup line, default 100).
--- Defaults chosen so the overload starts and drains the whole buffer in the one tick that follows
--- (overloadingDuration = 1, dt = 16: perTick = bufferCapacity * 16, always >= the buffer's own level).
local function nsReady(key, index, opts)
    resetWorld()
    soilReset()
    opts = opts or {}
    local o = {}
    for k, val in pairs(opts) do o[k] = val end
    o.round, o.nonStop = true, true
    o.bufferCapacity = o.bufferCapacity or 1000
    o.capacity = o.capacity or 1000
    o.overloadingStartFillLevelPct = o.overloadingStartFillLevelPct or 0.01
    o.overloadingDuration = o.overloadingDuration or 1
    o.overloadingDelay = o.overloadingDelay or 0
    o.lay = opts.lay or { { GRASS, opts.bufferLitres or 100, "grass" } }
    local m, sg, host, w = boot5db(o, key, index)
    soilReset()
    tick(w.baler)
    return m, sg, host, w
end

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE PICKUP TICK'S RECEIVER: BUFFER BY DEFAULT, MAIN ONLY WHEN THE NATIVE PATH SAYS SO
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    do
        local m0, sg0, host0, w0 = nsReady("ns_n0", 600)
        local v0 = w0.baler
        T.ok("N0 [reached] main.lua's install wrapped the live Baler class (SGClassHook) and the Baler's own load wrapped its instance setIsUnloadingBale with the pad marker: a non-stop Baler is framed (gate true)",
            SGClassHook.record(Baler, "onUpdateTick", GO_.HOOK_ID) ~= nil and SGClassHook.record(Baler, "onLoadFinished", GO_.HOOK_ID) ~= nil
            and v0.setIsUnloadingBale ~= Baler.setIsUnloadingBale and GO_.balerFramed(v0) == true)
        FSBaseMission.delete(m0)
    end
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        lay = { { GRASS, 100, "grass" } } }, "ns_n1", 601)
    soilReset()
    tick(w.baler)
    local v = w.baler
    local addOp = opOf(host, "GROUND_BALER_ADD")
    T.eq("N1 NAMED: a pickup into the buffer is one TRANSFER balerPickup to the buffer at the event's A, with the sealed account (Soil's pickup stood aside: Soil sealed nothing)",
        opsText(host) .. "|" .. tostring(addOp ~= nil and addOp.evidence.receiver) .. "|" .. num(v:getFillUnitFillLevel(3)) .. "|" .. num(v:getFillUnitFillLevel(1))
            .. "|" .. admits() .. "|" .. bufferText(sg, v),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|BUFFER|100|0|1|" .. ACC)
    FSBaseMission.delete(m)

    resetWorld()
    soilReset()
    local m2, sg2, host2, w2 = boot5db({ round = true, nonStop = true, bufferCapacity = 40, capacity = 1000,
        lay = { { GRASS, 100, "grass" } } }, "ns_n2", 602)
    soilReset()
    tick(w2.baler)
    local v2 = w2.baler
    T.eq("N2 NAMED: a full buffer: A below W, the remainder is the tick's LOSS",
        opsText(host2) .. "|" .. num(v2:getFillUnitFillLevel(3)),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED GROUND_BALER_REMAINDER:COMMITTED|40")
    FSBaseMission.delete(m2)

    resetWorld()
    soilReset()
    local m3, sg3, host3, w3 = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        fillMainUnitAfterOverload = true, unloadingStarted = true, lay = { { GRASS, 100, "grass" } } }, "ns_n3", 603)
    soilReset()
    tick(w3.baler)
    local v3 = w3.baler
    local addOp3 = opOf(host3, "GROUND_BALER_ADD")
    T.eq("N3 NAMED: fillMainUnitAfterOverload with unloadingStarted and main free: the pickup takes today's main path, unchanged (no receiver field)",
        opsText(host3) .. "|" .. tostring(addOp3 ~= nil and addOp3.evidence.receiver) .. "|" .. num(v3:getFillUnitFillLevel(1)) .. "|" .. num(v3:getFillUnitFillLevel(3)),
        "GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|nil|100|0")
    FSBaseMission.delete(m3)
    -- N4: a change to the buffer that the host is still coalescing at the tick's start (5d-b's W3, on the buffer):
    -- a fill from empty is a boundary and flushes at once; a mid-fill add waits for the next flush. balerEnd
    -- brings the buffer's record to native, so the pickup's add settles clean and is not taken with the 40 L.
    resetWorld()
    soilReset()
    local m4, sg4, host4, w4 = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        lay = { { GRASS, 100, "grass" } } }, "ns_n4", 604)
    soilReset()
    local v4 = w4.baler
    v4:addFillUnitFillLevel(1, 3, 20, GRASS, ToolType.UNDEFINED)
    v4:addFillUnitFillLevel(1, 3, 20, GRASS, ToolType.UNDEFINED)
    local pending4 = #host4.dirtyOrder
    tick(v4)
    T.eq("N4 NAMED: the buffer's record is brought to native at the tick's start, so a change still waiting in the host's coalescing is not taken for the add's: the add settles clean onto the buffer's 140 L",
        pending4 .. "|" .. opsText(host4) .. "|" .. num(v4:getFillUnitFillLevel(3)) .. "|" .. bufferText(sg4, v4),
        "1|GROUND_BALER:COMMITTED GROUND_BALER_ADD:COMMITTED|140|GRASS_WINDROW|140|PARTIAL|PARTIAL:7:140/100/40/0/30")
    FSBaseMission.delete(m4)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE OVERLOAD: ONE TRANSFER BEFORE THE ORIGINAL LISTENER, THE OVERFLOW AND THE RE-ADD AFTER IT
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    -- O1: no gain.
    local m, sg, host, w = nsReady("ns_o1", 610)
    local v = w.baler
    local lines = printed(function() X.updateTick(v, 0) end)
    local op = ovOpOf(host, "GROUND_BALER_OVERLOAD")
    T.eq("O1 NAMED: an overload with no gain: the chamber's account equals the buffer's scaled to A; the buffer's record falls by Ub; no unexplained change on either unit; no balerPadOutsideTick line",
        tostring(op ~= nil and op.outcome) .. "|" .. num(v:getFillUnitFillLevel(3)) .. "|" .. num(v:getFillUnitFillLevel(1))
            .. "|" .. num(op ~= nil and op.evidence.nativeGain.factor) .. "|" .. chamberText(sg, v) .. "|" .. tostring(has(lines, "outside a pickup tick"))
            .. "|" .. bufferText(sg, v),
        "COMMITTED|0|100|1|" .. ACC .. "|false|none")
    FSBaseMission.delete(m)

    -- O9: an overload that drains only part of the buffer: the debit report the scope consumed at settle is
    -- not replayed at the close, so the buffer keeps its remaining record with no unexplained decrease.
    local m9, sg9, host9, w9 = nsReady("ns_o9", 620, { overloadingDuration = 320 })
    local v9 = w9.baler
    X.updateTick(v9, 0)
    local op9 = ovOpOf(host9, "GROUND_BALER_OVERLOAD")
    T.eq("O9 NAMED: an overload that drains only part of the buffer consumes its own debit report at the settle: the buffer keeps its remaining record with no unexplained decrease (Ub = 50 L of the 100 L it held)",
        tostring(op9 ~= nil and op9.outcome) .. "|" .. num(op9 ~= nil and op9.evidence.bufferDebit) .. "|" .. num(v9:getFillUnitFillLevel(3)) .. "|" .. num(v9:getFillUnitFillLevel(1))
            .. "|" .. bufferText(sg9, v9) .. "|" .. chamberText(sg9, v9),
        "COMMITTED|50|50|50|GRASS_WINDROW|50|KNOWN|KNOWN:7:100/100/0/0/30|GRASS_WINDROW|50|KNOWN|KNOWN:7:50/50/0/0/30")
    FSBaseMission.delete(m9)
    -- O7: a chamber change the host is still coalescing when the overload scope opens (5d-b's W3, at the
    -- scope): the scope reads the dirty record first, so the overload's TRANSFER captures the chamber as it is.
    local m7, sg7, host7, w7 = nsReady("ns_o7", 618)
    local v7 = w7.baler
    -- These two direct adds are outside a pickup tick and a scope, so they log balerPadOutsideTick once per process;
    -- the log-once record is restored so P0, which pins that log, still sees it first.
    local loggedBefore = {}
    for k, val in pairs(GO_.logged) do loggedBefore[k] = val end
    v7:addFillUnitFillLevel(1, 1, 20, GRASS, ToolType.UNDEFINED)
    v7:addFillUnitFillLevel(1, 1, 20, GRASS, ToolType.UNDEFINED)
    for k in pairs(GO_.logged) do GO_.logged[k] = nil end
    for k, val in pairs(loggedBefore) do GO_.logged[k] = val end
    local pending7 = #host7.dirtyOrder
    X.updateTick(v7, 0)
    local op7 = ovOpOf(host7, "GROUND_BALER_OVERLOAD")
    T.eq("O7 NAMED: a chamber change still waiting in the host's coalescing when the scope opens is read first: the overload settles clean onto the chamber's 140 L",
        pending7 .. "|" .. tostring(op7 ~= nil and op7.outcome) .. "|" .. num(v7:getFillUnitFillLevel(3)) .. "|" .. num(v7:getFillUnitFillLevel(1)) .. "|" .. chamberText(sg7, v7),
        "1|COMMITTED|0|140|GRASS_WINDROW|140|PARTIAL|PARTIAL:7:140/100/40/0/30")
    FSBaseMission.delete(m7)

    -- O8: a second writer debits the buffer inside the scope, between the overload's debit (:1017) and its main add
    -- (:1052) (what else writes this: any mod hooking the buffer unit). Only the overload's own debit arms the scope;
    -- the other 10 L is nobody's overload and reconciles as an unexplained decrease. Modelled: the writer is a wrap of
    -- the instance addFillUnitFillLevel that debits the buffer once, just before the Baler's main add.
    local m8, sg8, host8, w8 = nsReady("ns_o8", 619, { overloadingDuration = 320 })
    local v8 = w8.baler
    local realAdd8, injected8 = v8.addFillUnitFillLevel, false
    v8.addFillUnitFillLevel = function(self, farmId, idx, delta, ft, tool, ...)
        if not injected8 and idx == 1 and delta > 0 then
            injected8 = true
            realAdd8(self, farmId, 3, -10, GRASS, ToolType.UNDEFINED)
        end
        return realAdd8(self, farmId, idx, delta, ft, tool, ...)
    end
    X.updateTick(v8, 0)
    local op8 = ovOpOf(host8, "GROUND_BALER_OVERLOAD")
    T.eq("O8 NAMED: a second writer's debit of the buffer inside the scope does not re-arm it: the overload's TRANSFER keeps its own debit Ub = 50 L (gain 1), the other 10 L is an unexplained decrease",
        tostring(injected8) .. "|" .. tostring(op8 ~= nil and op8.outcome) .. "|" .. num(op8 ~= nil and op8.evidence.bufferDebit) .. "|" .. num(op8 ~= nil and op8.evidence.nativeGain.factor)
            .. "|" .. num(v8:getFillUnitFillLevel(3)) .. "|" .. num(v8:getFillUnitFillLevel(1)) .. "|" .. bufferText(sg8, v8) .. "|" .. chamberText(sg8, v8),
        "true|COMMITTED|50|1|40|50|GRASS_WINDROW|40|PARTIAL|KNOWN:7:100/100/0/0/30|GRASS_WINDROW|50|KNOWN|KNOWN:7:50/50/0/0/30")
    FSBaseMission.delete(m8)

    -- O2: appliedByBufferOverloading (the gain).
    local m2, sg2, host2, w2 = nsReady("ns_o2", 611, { additives = { level = 1000, usage = 0.1, appliedByBufferOverloading = true } })
    local v2 = w2.baler
    local bufferBefore = v2:getFillUnitFillLevel(3)
    X.updateTick(v2, 0)
    local op2 = ovOpOf(host2, "GROUND_BALER_OVERLOAD")
    T.eq("O2 NAMED: an overload with appliedByBufferOverloading: the chamber's litres carry the gain at the buffer's percent; nativeGain names Ub, D and D/Ub; the additive unit's decrease replays; that Baler's pickups show no gain (the buffer held exactly 100 L before the overload, not 105)",
        num(bufferBefore) .. "|" .. tostring(op2 ~= nil and op2.outcome) .. "|" .. num(v2:getFillUnitFillLevel(1)) .. "|" .. num(v2:getFillUnitFillLevel(2))
            .. "|" .. tostring(op2 ~= nil and (num(op2.evidence.nativeGain.source) .. "/" .. num(op2.evidence.nativeGain.destination) .. "/" .. num(op2.evidence.nativeGain.factor))),
        "100|COMMITTED|105|990|100/105/1.05")
    FSBaseMission.delete(m2)

    -- O3: fills the main; the nested finish; O lands on balerOverflow, read after the original.
    local m3, sg3, host3, w3 = nsReady("ns_o3", 612, { capacity = 60 })
    local v3 = w3.baler
    local probe = probeFinish(sg3, v3)
    X.updateTick(v3, 0)
    local opOv3 = ovOpOf(host3, "GROUND_BALER_OVERLOAD")
    local opFlow3 = ovOpOf(host3, "GROUND_BALER_OVERLOAD_OVERFLOW")
    T.eq("O3 NAMED: an overload that fills the main: the nested finish reads a chamber record that includes this overload; O lands on balerOverflow, read after the original",
        tostring(opOv3 ~= nil and opOv3.outcome) .. "|" .. num(v3:getFillUnitFillLevel(1)) .. "|" .. tostring(listed(v3)[1] ~= nil and listed(v3)[1].mounted)
            .. "|" .. probe[1] .. "|" .. tostring(opFlow3 ~= nil and opFlow3.outcome) .. "|" .. num(opFlow3 ~= nil and opFlow3.evidence.overflowAmount)
            .. "|" .. stockText(stockAt(sg3, overflowId(v3))),
        "COMMITTED|60|true|GRASS_WINDROW|60|KNOWN|KNOWN:7:60/60/0/0/30|COMMITTED|40|NATIVE_BALER_OVERFLOW_V1|40|KNOWN|KNOWN:7:40/40/0/0/30")
    FSBaseMission.delete(m3)

    -- O4: an overload with an old overflow: the nested re-add is one TRANSFER overflow to main under the scope.
    local m4, sg4, host4, w4 = nsReady("ns_o4", 617, { capacity = 60 })
    local v4 = w4.baler
    X.updateTick(v4, 0)
    X.handover(v4)
    X.close(v4)
    relay(m4, w4, GRASS, 100, "g2")
    tick(v4)
    local oldOverflow4 = stockText(stockAt(sg4, overflowId(v4)))
    v4.spec_fillUnit.fillUnits[1].capacity = 1000   -- a larger bale size for the next bale (fillUnitCapacity follows the bale type)
    X.updateTick(v4, 0)
    T.eq("O4 NAMED: an overload while an old overflow stands, into a main with room: the original's nested re-add moves the old overflow into the main as one TRANSFER inside the scope; the overflow is emptied and withdrawn, the main holds the overload and the old overflow",
        oldOverflow4 .. "|" .. ovOpsText(host4) .. "|" .. num(v4:getFillUnitFillLevel(1)) .. "|" .. num(v4.spec_baler.fillUnitOverflowFillLevel)
            .. "|" .. chamberText(sg4, v4) .. "|" .. stockText(stockAt(sg4, overflowId(v4))),
        "NATIVE_BALER_OVERFLOW_V1|40|KNOWN|KNOWN:7:40/40/0/0/30|GROUND_BALER_OVERLOAD:COMMITTED GROUND_BALER_READD:COMMITTED|140|0|GRASS_WINDROW|140|KNOWN|KNOWN:7:140/140/0/0/30|none")
    FSBaseMission.delete(m4)

    -- O5: into a main holding another type (COALESCE_UNPROVED).
    resetWorld()
    soilReset()
    local m5, sg5, host5, w5 = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        fillMainUnitAfterOverload = true, unloadingStarted = true, overloadingStartFillLevelPct = 0.01,
        lay = { { DRY, 50, "dry" } } }, "ns_o5", 613)
    soilReset()
    tick(w5.baler)
    local v5 = w5.baler
    -- Reconfigure to the general (buffer-destined) pickup path for the GRASS leg that will overload.
    v5.spec_baler.buffer.fillMainUnitAfterOverload, v5.spec_baler.buffer.unloadingStarted = false, false
    relay(m5, w5, GRASS, 100, "grass")
    tick(v5)
    local beforeMain5 = stockText(stockAt(sg5, unitId(v5, 1)))
    X.updateTick(v5, 0)
    local opOv5 = ovOpOf(host5, "GROUND_BALER_OVERLOAD")
    T.eq("O5 NAMED: an overload into a main holding another type: COALESCE_UNPROVED abandon, the material unknown, nothing minted",
        beforeMain5 .. "|" .. tostring(opOv5 ~= nil and opOv5.outcome) .. "|" .. tostring(opOv5 ~= nil and opOv5.reason) .. "|" .. num(v5:getFillUnitFillLevel(1)),
        "DRYGRASS_WINDROW|50|KNOWN|KNOWN:7:50/50/0/0/30|ABANDONED|COALESCE_UNPROVED|150")
    FSBaseMission.delete(m5)

    -- O6a: the original listener throws after the overload's TRANSFER (another mod's code failing inside
    -- it): what the transient still holds (the 40 L that did not fit) is native loss, retired as LOSS.
    local m6, sg6, host6, w6 = nsReady("ns_o6a", 614, { capacity = 60 })
    local v6 = w6.baler
    local realFree = v6.getFillUnitFreeCapacity
    v6.getFillUnitFreeCapacity = function(self, i, ...)
        if i == self.spec_baler.fillUnitIndex and self.spec_fillUnit.fillUnits[1].fillLevel > 0 then error("bench: the listener failed after the add", 0) end
        return realFree(self, i, ...)
    end
    local ok6 = pcall(X.updateTick, v6, 0)
    v6.getFillUnitFreeCapacity = realFree
    local rem6 = ovOpOf(host6, "GROUND_BALER_OVERLOAD_REMAINDER")
    T.eq("O6a NAMED: a main add whose listener fails after the add: the tick raised, the overload's TRANSFER stands, and the transient's remainder (D - A = 40 L) is retired as one LOSS",
        tostring(ok6) .. "|" .. ovOpsText(host6) .. "|" .. num(rem6 ~= nil and rem6.evidence.remainder) .. "|" .. num(v6:getFillUnitFillLevel(1)),
        "false|GROUND_BALER_OVERLOAD:COMMITTED GROUND_BALER_OVERLOAD_REMAINDER:COMMITTED|40|60")
    FSBaseMission.delete(m6)

    -- O6c: the main refuses the add (no event at all): nothing settles, nothing is minted, the buffer's
    -- debit is an unexplained decrease.
    local m7, sg7, host7, w7 = nsReady("ns_o6c", 616, {})
    local v7 = w7.baler
    v7.spec_fillUnit.fillUnits[1].refuse = true
    X.updateTick(v7, 0)
    local ov7 = host7.lastBalerOverload
    local refused7 = {}
    for k, n in pairs(ov7 ~= nil and ov7.refused or {}) do refused7[#refused7 + 1] = k .. "=" .. n end
    table.sort(refused7)
    T.eq("O6c NAMED: a main that refuses the overload's add: no event, no TRANSFER, no REMAINDER; the scope armed and never settled (OVERLOAD_UNSETTLED); the chamber has no stock and the buffer's debit stands as the native fact",
        ovOpsText(host7) .. "|" .. table.concat(refused7, ",") .. "|" .. chamberText(sg7, v7) .. "|" .. num(v7:getFillUnitFillLevel(3)) .. "|" .. num(v7:getFillUnitFillLevel(1)) .. "|" .. bufferText(sg7, v7),
        "|OVERLOAD_UNSETTLED=1|none|0|0|none")
    FSBaseMission.delete(m7)

    -- O6b: a short add that fills the main and assigns overflow loses nothing (reuses O3's shape).
    local m6b, sg6b, host6b, w6b = nsReady("ns_o6b", 615, { capacity = 60 })
    local v6b = w6b.baler
    X.updateTick(v6b, 0)
    T.eq("O6b a short add that assigns overflow loses nothing: no REMAINDER line, the overflow holds exactly O",
        ovOpsText(host6b) .. "|" .. num(stockAt(sg6b, overflowId(v6b)) and stockAt(sg6b, overflowId(v6b)).observedAmount),
        "GROUND_BALER_OVERLOAD:COMMITTED GROUND_BALER_OVERLOAD_OVERFLOW:COMMITTED|40")
    FSBaseMission.delete(m6b)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. A ROUND BALER WITH ITS BALE MOUNTED: PICKUPS STILL GO TO THE BUFFER
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    local m, sg, host, w = nsReady("ns_m1", 620, { capacity = 100, bufferCapacity = 100, overloadingStartFillLevelPct = 0.5 })
    local v = w.baler
    X.updateTick(v, 0)
    local bale = listed(v)[1]
    local mirror = bale ~= nil and NA.roundMirrorOf(bale) or nil
    local chamberBefore = stockText(stockAt(sg, unitId(v, 1)))
    relay(m, w, GRASS, 100, "g2")
    tick(v)
    local chamberAfter = stockText(stockAt(sg, unitId(v, 1)))
    local mirrorStill = bale ~= nil and NA.roundMirrorOf(bale) == mirror
    X.n0 = X.count()
    local mountedBefore = bale ~= nil and bale.mounted
    X.handover(v)
    local s = baleStock(sg, bale)
    T.eq("M1 NAMED: round, bale mounted: pickups go to the buffer, the alias and the chamber stay whole, and the handover REBIND commits as 5e-c's does; the handover tick runs no overload",
        tostring(mountedBefore) .. "|" .. chamberBefore .. "|" .. num(v:getFillUnitFillLevel(3)) .. "|" .. chamberAfter .. "|" .. tostring(mirrorStill)
            .. "|" .. X.since() .. "|" .. tostring(s ~= nil and s.quantityBasisKey == baleId(bale)) .. "|" .. tostring(host.lastBalerOverload ~= nil and host.lastBalerOverload.armed),
        "true|GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30|100|GRASS_WINDROW|100|KNOWN|KNOWN:7:100/100/0/0/30|true|1:COMMITTED|true|false")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PAD MARKER: A PAD INSIDE onUpdateTick IS NOT AN OVERLOAD
-- ══════════════════════════════════════════════════════════════════════════
-- NOT CONFIRMED AGAINST THE DECOMPILE: see the automaticDrop == "pad" note at B:onUpdateTick above. The
-- pad itself (setIsUnloadingBale, :1324-1347) and SGBalerNonStop's marker around it are real; only the
-- specific in-tick trigger used to reach it here (bypassing :959's `#spec.bales > 0`) is a bench drive.
group("P", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 2000,
        overloadingStartFillLevelPct = 0.5, automaticDrop = "pad", canUnloadUnfinished = true, threshold = 30,
        lay = { { GRASS, 50, "grass" } } }, "ns_p0", 630)
    soilReset()
    tick(w.baler)
    local v = w.baler
    local lines = printed(function() X.updateTick(v, 0) end)
    local bale = listed(v)[1]
    local ov = host.lastBalerOverload
    T.eq("P0 NAMED: a pad inside onUpdateTick (the automatic unload) is not an overload: no TRANSFER of the pad; the buffer debit reconciles as an unexplained decrease, the pad add logs through balerPadOutsideTick, the partial bale has no StockGuard record",
        num(v:getFillUnitFillLevel(3)) .. "|" .. num(v:getFillUnitFillLevel(1)) .. "|" .. tostring(bale ~= nil and bale.mounted) .. "|" .. num(bale ~= nil and bale.fillLevel)
            .. "|" .. chamberText(sg, v) .. "|" .. tostring(has(lines, "outside a pickup tick")) .. "|" .. tostring(ov ~= nil and ov.armed) .. "|" .. ovOpsText(host) .. "|" .. bufferText(sg, v),
        "0|2000|true|2000|GRASS_WINDROW|2000|UNKNOWN|noRecord|true|false||none")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. SAVE AND RELOAD: THE BUFFER'S RECORD REATTACHES; A NON-STOP OVERFLOW TOO (5e-a's participant)
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg, host, w, bale = X.mounted("ns_s1a", 640, { nonStop = true, bufferCapacity = 1000, capacity = 1000, overloadingStartFillLevelPct = 0.99 })
    -- X.mounted's own tick finishes a 100 L bale on the MAIN unit (its own default lay); a second, real
    -- pickup tick now fills the buffer, since every pickup lands there on a non-stop Baler (N1).
    relay(m, w, GRASS, 100, "g2")
    tick(w.baler)
    local before = bufferText(sg, w.baler)
    local m2, sg2, host2, w2, lines2, keys2 = reload2b(m, w, "ns_s1a_save", 641, { nonStop = true, bufferCapacity = 1000, capacity = 1000, round = true })
    T.eq("S1a NAMED: the buffer's record reattaches after a save and a fresh mission",
        before .. "|" .. bufferText(sg2, w2.baler), "GRASS_WINDROW|200|KNOWN|KNOWN:7:200/200/0/0/30|GRASS_WINDROW|200|KNOWN|KNOWN:7:200/200/0/0/30")
    FSBaseMission.delete(m2)

    local m3, sg3, host3, w3 = nsReady("ns_s1b", 642, { capacity = 60 })
    X.updateTick(w3.baler, 0)
    local overflowBefore = stockText(stockAt(sg3, overflowId(w3.baler)))
    local m4, sg4, host4, w4, lines4 = reload2b(m3, w3, "ns_s1b_save", 643, { nonStop = true, bufferCapacity = 1000, capacity = 60, round = true })
    T.eq("S1b NAMED: a non-stop overflow saves and restores through 5e-a's participant",
        overflowBefore .. "|" .. stockText(stockAt(sg4, overflowId(w4.baler))),
        "NATIVE_BALER_OVERFLOW_V1|40|KNOWN|KNOWN:7:40/40/0/0/30|NATIVE_BALER_OVERFLOW_V1|40|KNOWN|KNOWN:7:40/40/0/0/30")
    FSBaseMission.delete(m4)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. ON A CLIENT NOTHING FRAMES AND NO SCOPE OPENS
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        lay = { { GRASS, 100, "grass" } } }, "ns_c1", 650)
    w.baler.isServer = false
    soilReset()
    tick(w.baler)
    X.updateTick(w.baler, 0)
    T.eq("C1 NAMED: on a client nothing frames and no scope opens",
        tostring(host.lastBalerTick) .. "|" .. admits() .. "|" .. tostring(host.lastBalerOverload),
        "nil|0|nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE GATE'S FLIP, TWO-SIDED; THE CONTROL: THE SCOPE OPENS ONLY WHILE THE BUFFER HOLDS ANYTHING
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        lay = { { GRASS, 100, "grass" } } }, "ns_k2a", 660)
    tick(w.baler)
    T.eq("K2a NAMED: with SGBalerNonStop loaded a non-stop Baler is framed: the gate true, a tick opens",
        tostring(GO_.balerFramed(w.baler)) .. "|" .. tostring(host.lastBalerTick ~= nil),
        "true|true")
    FSBaseMission.delete(m)

    local saved = SGBalerNonStop
    SGBalerNonStop = nil
    resetWorld()
    soilReset()
    local m2, sg2, host2, w2 = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000,
        lay = { { GRASS, 100, "grass" } } }, "ns_k2b", 661)
    tick(w2.baler)
    local gateOff = tostring(GO_.balerFramed(w2.baler))
    SGBalerNonStop = saved
    T.eq("K2b NAMED: SGBalerNonStop set to nil in the same process: the gate false, the tick is native's alone",
        gateOff .. "|" .. tostring(host2.lastBalerTick),
        "false|nil")
    FSBaseMission.delete(m2)

    resetWorld()
    soilReset()
    local m3, sg3, host3, w3 = boot5db({ round = true, nonStop = true, bufferCapacity = 1000, capacity = 1000, lay = {} }, "ns_ctrl1", 662)
    X.updateTick(w3.baler, 0)
    X.updateTick(w3.baler, 0)
    T.eq("CTRL1 NAMED [control]: a non-stop Baler whose buffer is still empty opens no overload scope on its onUpdateTick",
        tostring(host3.lastBalerOverload), "nil")
    FSBaseMission.delete(m3)

    resetWorld()
    soilReset()
    local m4, sg4, host4, w4 = boot5db({ round = true, lay = { { GRASS, 100, "grass" } } }, "ns_ctrl2", 663)
    tick(w4.baler)
    X.updateTick(w4.baler, 0)
    X.updateTick(w4.baler, 0)
    T.eq("CTRL2 NAMED [control]: a plain (not non-stop) Baler's onUpdateTick opens no overload scope: host.lastBalerOverload unchanged across its ticks",
        tostring(host4.lastBalerOverload), "nil")
    FSBaseMission.delete(m4)
end)
end
SG2NS_BENCH()
end
