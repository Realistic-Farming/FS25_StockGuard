-- SG2-5a-windrower_frame_spec_test.lua
--
-- SG2-5 slice 5a (Bob's windrower shape ruling, BOB-RULING-SG2-5A-WINDROWER-SHAPE-2026-10-02, shape A
-- with conditions a-d): a Windrower work area's one processing call runs inside a WINDROWER ground
-- frame whose one unit is a LIVE-ONLY windrowerArea carrier (SGNativeAdapters): bound lazily,
-- empty, at the first pickup that removed material; its amount is the call's observed balance
-- (picked minus dropped, from the cells the line bracket saw change; never litersToDrop, SG-2
-- :294); each pickup and the drop are the ordinary per-primitive TRANSFERs, settled at the next
-- beforeLine and at the close; a remainder at the close is one REMOVE with a LOSS leg and the
-- picked, dropped and remainder litres; the carrier is withdrawn. Soil admits the frame's
-- primitives (SGSoilCondition), and the drop carries the area stock's record (5-0b).
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world, with SG2-4c-1's recorder
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


-- ── The engine's Windrower (vehicles/specializations/Windrower.lua) ─────────────────────────
-- WHEAT and BARLEY stand in for the windrow types (the ground model's two height types); the
-- dual branch's GRASS_WINDROW and DRYGRASS_WINDROW name them so it can be reached at all.
FillType.GRASS_WINDROW, FillType.DRYGRASS_WINDROW = WHEAT, BARLEY
-- DensityMapHeightUtil.lua:425-449 VERBATIM, and :450-455.
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
Windrower = Windrower or {}
-- :285-290 VERBATIM: the reset at every work-area tick's start.
function Windrower:onStartWorkAreaProcessing(_, workAreas)
    for _, workArea in pairs(workAreas) do
        workArea.lastValidPickupFillType = FillType.UNKNOWN
        workArea.lastPickupLiters = 0
        workArea.lastDroppedLiters = 0
    end
    self.spec_windrower.isWorking = false
end
-- :309-359 VERBATIM through the quantities; the stone, wear, test-area and effect lines out.
function Windrower:processWindrowerArea(workArea, _)
    local spec = self.spec_windrower
    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)
    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz)
    local pickupLiters = 0
    local pickupFillType = FillType.UNKNOWN
    if workArea.lastPickupLiters == 0 and (workArea.lastValidPickupFillType == FillType.UNKNOWN or workArea.litersToDrop < g_densityMapHeightManager:getMinValidLiterValue(workArea.lastValidPickupFillType)) then
        for _, fillTypeIndex in ipairs(spec.supportedFillTypes) do
            pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillTypeIndex, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, spec.limitToLineHeight, nil)
            if pickupLiters > 0 then
                pickupFillType = fillTypeIndex
                break
            end
        end
    else
        pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, workArea.lastValidPickupFillType, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        if workArea.lastValidPickupFillType == FillType.GRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        elseif workArea.lastValidPickupFillType == FillType.DRYGRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.GRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        end
        if pickupLiters > 0 then
            pickupFillType = workArea.lastValidPickupFillType
        end
    end
    if pickupFillType ~= FillType.UNKNOWN then
        workArea.lastValidPickupFillType = pickupFillType
    end
    workArea.lastPickupLiters = pickupLiters
    workArea.litersToDrop = workArea.litersToDrop + pickupLiters
    local area = 1
    if workArea.lastPickupLiters > 0 then
        local dropArea = self.spec_workArea.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil then
            local dropped = self:processDropArea(dropArea, workArea.lastPickupLiters, workArea.lastValidPickupFillType)
            workArea.lastDroppedLiters = dropped
            workArea.litersToDrop = workArea.litersToDrop - dropped
        end
    end
    return workArea.lastDroppedLiters, area
end
-- :393-397 VERBATIM.
function Windrower:processDropArea(dropArea, litersToDrop, fillType)
    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, litersToDrop, fillType, lsx, lsy, lsz, lex, ley, lez, radius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset
    return dropped
end
--- A rake: work area 1 picks up over x -1..1 at z 0 and drops into work area 2 at x 8..10.
--- WorkArea:onLoad's capture (WorkArea.lua:84 the index, :266 the pointer) as the engine leaves it.
local function newWindrower(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = 0, capacity = 0, supported = {} })
    v.configFileName = "data/vehicles/windrower.xml"
    v.isServer = true
    v.processWindrowerArea = Windrower.processWindrowerArea
    v.processDropArea = Windrower.processDropArea
    v.spec_windrower = { supportedFillTypes = opts.types or { WHEAT, BARLEY }, limitToLineHeight = false, isWorking = false }
    local pickup = { index = 1, functionName = "processWindrowerArea", dropWindrowWorkAreaIndex = opts.noDrop and 3 or 2,
                     start = { x = -1, y = 0, z = -0.5 }, width = { x = 1, y = 0, z = -0.5 }, height = { x = -1, y = 0, z = 0.5 },
                     lastValidPickupFillType = FillType.UNKNOWN, lastPickupLiters = 0, lastDroppedLiters = 0, litersToDrop = 0 }
    pickup.processingFunction = v.processWindrowerArea
    local drop = { index = 2, functionName = "processDropArea", lineOffset = 0,
                   start = { x = 8, y = 0, z = -0.5 }, width = { x = 10, y = 0, z = -0.5 }, height = { x = 8, y = 0, z = 0.5 } }
    v.spec_workArea = { workAreas = { pickup, drop } }
    return v, pickup
end
--- WorkArea's tick for one area, in the engine's order: the start event, then the captured pointer.
local function tick(v, workArea, opts)
    opts = opts or {}
    if not opts.noReset then Windrower.onStartWorkAreaProcessing(v, nil, v.spec_workArea.workAreas) end
    return workArea.processingFunction(v, workArea, 16)
end
local function windrowWorld(m, w)
    soilOn(m)
    tipWorld(m, w, { at = { x = 0, z = 0 } })
    w.windrower, w.area = newWindrower("vehicle:windrower")
    vehicleIn(m, w.windrower)
end
local function areaCarriers(sg)
    local n = 0
    for id in pairs(sg.operations.carriers) do if id:find("windrowerArea:", 1, true) then n = n + 1 end end
    return n
end
local function liveAreas() local n = 0 for _ in pairs(NA.windrowerAreas) do n = n + 1 end return n end
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

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: ONE WINDROWER CALL, PICKED AND DROPPED
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    local m, sg, host, w, lease = boot(windrowWorld, "w5a_save", { index = 71 })
    local owner = m.stockGuard.registerProperty(PID, OWNER)
    local wa = w.area
    T.ok("E0 [reached] the native host bracketed the Windrower work area's CAPTURED pointer; the owner registered as soil.groundCondition",
        wa.processingFunction ~= Windrower.processWindrowerArea and wa._sgBrackets ~= nil and wa._sgBrackets.processWindrowerArea ~= nil
            and wa._sgBrackets.processWindrowerArea.original == Windrower.processWindrowerArea and owner ~= nil)
    ENGINE_TIP(w.tipper, 100)
    local onGround0 = groundTotal(sg)
    soilReset()
    local dropped, area = tick(w.windrower, wa)
    T.eq("E1 [world] the call picked the windrow and dropped what it picked; the pointer's two returns are the engine's",
        tostring(wa.lastPickupLiters > 0) .. "/" .. tostring(dropped == wa.lastPickupLiters) .. "/" .. tostring(area) .. "/" .. num(wa.litersToDrop), "true/true/1/0")
    T.eq("E2 NAMED: Soil was asked for each primitive inside the WINDROWER frame: the pickup and the drop, each admitted, delivered and closed",
        fns() .. "/" .. tostring(host.lastGroundFrame.kind), "admit(4) deliver(2) close(1) admit(4) deliver(2) close(1)/WINDROWER")
    T.eq("E3 NAMED: StockGuard's own operations: the pickup (cells to the area) and the drop (the area to cells), both COMMITTED, no remainder",
        opsOf(host), "GROUND_WINDROWER:COMMITTED GROUND_WINDROWER:COMMITTED")
    local d = delivers()[2]
    T.eq("E4 NAMED: the drop carries the area stock's record: one contribution of the litres the util returned, soil.groundCondition KNOWN 7",
        contribText(d and d.obs), "1/litres=returned:soil.groundCondition:KNOWN:7")
    T.eq("E5 NAMED: the area carrier is withdrawn at the close and nothing stays live; the ground holds what it held",
        areaCarriers(sg) .. "/" .. liveAreas() .. "/" .. num(groundTotal(sg)), "0/0/" .. num(onGround0))
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. A REMAINDER IS NATIVE LOSS
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        tipWorld(m, w, { at = { x = 0, z = 0 } })
        w.windrower, w.area = newWindrower("vehicle:windrower", { noDrop = true })
        vehicleIn(m, w.windrower)
    end, "w5a_rem", { index = 72 })
    ENGINE_TIP(w.tipper, 100)
    local wa = w.area
    tick(w.windrower, wa)
    local gf = host.lastGroundFrame
    local rem = gf.operations[#gf.operations]
    local ev = rem and rem.evidence or {}
    T.eq("R1 NAMED: a call whose drop area is missing (native drops nothing) retires the picked litres as one REMOVE with a LOSS leg naming picked, dropped and remainder",
        tostring(rem and rem.outcome) .. "/" .. tostring(ev.nativePath) .. "/" .. tostring(num(ev.picked) == num(wa.lastPickupLiters)) .. "/" .. num(ev.dropped) .. "/" .. tostring(num(ev.remainder) == num(wa.lastPickupLiters))
            .. "/" .. tostring(rem and rem.report.allocations[1].result),
        "COMMITTED/GROUND_WINDROWER_REMAINDER/true/0/true/LOSS")
    T.eq("R2 the area is withdrawn and the native counter keeps the remainder it always kept", areaCarriers(sg) .. "/" .. liveAreas() .. "/" .. tostring(wa.litersToDrop > 0), "0/0/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE AREA'S RETIREMENTS KEEP THEIR OWN BUDGET
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        tipWorld(m, w, { at = { x = 0, z = 0 }, level = 100 })
        w.windrower, w.area = newWindrower("vehicle:windrower")
        vehicleIn(m, w.windrower)
    end, "w5a_cls", { index = 73 })
    ENGINE_TIP(w.tipper, 100)   -- the 100 L tipper empties: its stock retires in the core class
    local tipperRetired = 0
    for _, s in pairs(sg.operations.retiredStocks) do if s.carrierId == unitId(w.tipper) then tipperRetired = tipperRetired + 1 end end
    local limit = sg.operations.retiredLimit
    sg.operations.retiredLimit = 4
    local calls = 0
    for _ = 1, 8 do
        tick(w.windrower, w.area)
        calls = calls + 1
        -- Move the dropped windrow back under the pickup: the next call has material again.
        w.area.start.x, w.area.width.x, w.area.height.x = w.area.start.x + 9, w.area.width.x + 9, w.area.height.x + 9
        local dropArea = w.windrower.spec_workArea.workAreas[2]
        dropArea.start.x, dropArea.width.x, dropArea.height.x = dropArea.start.x + 9, dropArea.width.x + 9, dropArea.height.x + 9
    end
    local mine, core, tipperKept = 0, 0, 0
    for _, s in pairs(sg.operations.retiredStocks) do
        if NA.isWindrowerAreaKey(s.carrierKey) then mine = mine + 1 else core = core + 1 end
        if s.carrierId == unitId(w.tipper) then tipperKept = tipperKept + 1 end
    end
    sg.operations.retiredLimit = limit
    T.eq("C1 NAMED: many calls retire their area stocks in their own class (held to its budget), and the tipper's retired history is never evicted",
        tostring(calls == 8) .. "/" .. tostring(tipperRetired >= 1) .. "/" .. tostring(mine <= 4 and mine >= 1) .. "/" .. tostring(tipperKept == tipperRetired),
        "true/true/true/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE LIVE-ONLY KIND
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(windrowWorld, "w5a_kind", { index = 74 })
    local spec = host.nativeLease.spec
    local binding = NA.windrowerAreaBinding(w.windrower, 1)
    --- Both answers of a call, or RAISED: the adapter must answer, never throw.
    local function answer(fn, ...) local r = { pcall(fn, ...) } if not r[1] then return "RAISED" end return tostring(r[2]) .. "/" .. tostring(r[3]) end
    T.eq("U1 NAMED: outside a frame the area resolves to nothing (NOT_LIVE), so it has no native state", answer(spec.resolveCarrier, binding), "nil/NOT_LIVE")
    T.eq("U2 NAMED: it is never restored and never enumerated", answer(spec.restoreBinding, binding, {}) .. "/" .. #spec.kinds[NA.KIND_WINDROWER_AREA].enumerateCarriers(),
        "nil/NOT_RESTORABLE/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE UNPROVED COALESCE (SG-2 :197)
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(windrowWorld, "w5a_dual", { index = 75 })
    m.stockGuard.registerProperty(PID, OWNER)
    ENGINE_TIP(w.tipper, 100)
    -- A second windrow of the other type under the same pickup line.
    w.tipper.spec_fillUnit.fillUnits[1].fillLevel, w.tipper.spec_fillUnit.fillUnits[1].fillType = 100, BARLEY
    ENGINE_TIP(w.tipper, 100)
    -- The dual branch (:336-341), reached only by skipping the reset the engine always does.
    local wa = w.area
    wa.lastValidPickupFillType, wa.lastPickupLiters, wa.litersToDrop = WHEAT, 1, 1000
    soilReset()
    tick(w.windrower, wa, { noReset = true })
    local gf = host.lastGroundFrame
    local d = lastDeliver()
    T.eq("G1 NAMED: the second pickup type is refused as the unproved coalesce, and the drop sends no contributions (it lands unknown at Soil)",
        tostring(gf.refused.COALESCE_UNPROVED) .. "/" .. tostring(gf.area.unproved) .. "/" .. contribText(d and d.obs), "1/true/none")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. SOIL ABSENT
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        tipWorld(m, w, { at = { x = 0, z = 0 } })
        w.windrower, w.area = newWindrower("vehicle:windrower")
        vehicleIn(m, w.windrower)
    end, "w5a_alone", { index = 76 })
    ENGINE_TIP(w.tipper, 100)
    tick(w.windrower, w.area)
    T.eq("S1 without Soil: nothing is asked, and StockGuard's own operations are the same", fns() .. "/" .. opsOf(host), "/GROUND_WINDROWER:COMMITTED GROUND_WINDROWER:COMMITTED")
    FSBaseMission.delete(m)
end)
