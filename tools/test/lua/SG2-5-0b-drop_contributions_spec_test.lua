-- SG2-5-0b-drop_contributions_spec_test.lua
--
-- SG2-5 slice 5-0b (SG-2 v2.3 :345, Bob's G1 ruling of 2026-10-02): a drop StockGuard delivers to
-- Soil carries the condition of the material it drops, as `observation.contributions =
-- { { litres, record } }`, where `record` is the `soil.groundCondition` record SG-1 carries on
-- the frame unit's stock (src/native/SGSoilCondition.lua, S.dropContributions). Soil's receiving
-- half is Soil #1074 (merged).
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world, with SG2-4c-1's
-- recorder of Soil's published surface (its preamble, verbatim).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path, an owner registered late through the
-- mission handle as `soil.groundCondition` (resident on ground), then the engine's discharge
-- (TIP), a Shovel's onUpdateTick (WORK) and a Leveler's pickup and raycast drop (DROP), each
-- reaching the engine global through the line bracket. The owner is a stand-in recorder, not
-- Soil's property: StockGuard passes the record through unread, so its payload is opaque here,
-- and Soil's own reading of the real property's records is pinned by Soil's
-- SG2-5-0-drop_contributions bench. The rows pin the observation's literal contributions against
-- the stock SG-1 holds and what the util returned.
--
-- Groups:
--   E  the entry-point bar: a tip carries its unit's record (none: litres with no record), a pickup
--      carries nothing, a Leveler's drop carries the KNOWN record its pickup captured
--   S  the source rules on StockGuard's own frame shape: no capture of this call, another call's
--      capture, no unit of the dropped material, two units of it, a unit stock with no record
--
-- NOT RUN, and why:
--   - a delivery that throws: SG2-4c-1's X group pins every Soil throw, and the contributions are
--     built before the call.
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

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    UTIL = {}
    local m, sg, host, w, lease = boot(tipShovelLevelerWorld, "c5_save", { index = 61 })
    local owner = m.stockGuard.registerProperty(PID, OWNER)
    T.ok("E0 [reached] the owner registered late through the mission handle as soil.groundCondition, and Soil's surface is the recorder",
        owner ~= nil and sg.registry:property(PID) ~= nil and m.soilFertilityManager ~= nil)
    local carried0 = SC.stats.carried
    ENGINE_TIP(w.tipper, 100)
    local d = lastDeliver()
    T.eq("E1 NAMED: a tip carries its unit's record: one contribution, the litres the util returned, and no record (the tipper's material came from no ground)",
        tostring(d and d.obs.litresReturned > 0) .. " " .. contribText(d and d.obs), "true 1/litres=returned:nil")
    -- Two shovel pickups: the second starts from a bucket that already holds the material.
    soilReset()
    ENGINE_RAISE(w.shovel, "onUpdateTick", 400)
    -- A small second pickup (one raw unit), so material stays on the ground for the Leveler.
    ENGINE_RAISE(w.shovel, "onUpdateTick", 20)
    local p1, p2 = delivers()[1], delivers()[2]
    T.eq("E2 NAMED: a pickup carries nothing, even from a bucket that already holds the material",
        tostring(p2 and p2.obs.litresReturned < 0) .. " " .. contribText(p1 and p1.obs) .. " " .. contribText(p2 and p2.obs), "true none none")
    local bucket = stockAt(sg, unitId(w.shovel))
    T.eq("E2b [world] the bucket's stock carries the owner's record off the ground", tostring(bucket and bucket.properties[PID] and bucket.properties[PID].knowledge), "KNOWN")
    -- The Leveler: a pickup onto its unit, then the raycast drop back onto the ground.
    local lv = w.leveler
    lv.spec_fillUnit.fillUnits[1].fillLevel, lv.spec_fillUnit.fillUnits[1].fillType = 0, 0
    lv.spec_leveler.nodes[1].pickupActive = true
    ENGINE_RAISE(lv, "onUpdate", 16)
    local lvStock = stockAt(sg, unitId(lv))
    local held = lvStock and lvStock.properties[PID] or nil
    T.eq("E3 [world] the Leveler's pickup carries the record onto its unit", tostring(held and held.knowledge) .. ":" .. num(held and held.payload.c), "KNOWN:7")
    lv.spec_leveler.nodes[1].pickupActive = false
    lv.spec_leveler.nodes[1].dropActive = true
    lv.spec_leveler.nodes[1].node.x = 20
    soilReset()
    ENGINE_RAISE(lv, "onUpdate", 16)
    d = lastDeliver()
    local rec = d and d.obs.contributions and d.obs.contributions[1].record or nil
    T.eq("E4 NAMED: the Leveler's drop in its WORK frame carries the record SG-1 holds on its unit: one contribution, the litres the util returned, soil.groundCondition KNOWN 7",
        tostring(host.lastGroundFrame.kind) .. " " .. tostring(d and d.obs.litresReturned > 0) .. " " .. contribText(d and d.obs), "WORK true 1/litres=returned:soil.groundCondition:KNOWN:7")
    T.eq("E5 the record is a copy of what SG-1 holds, field for field, never the stock's own table",
        tostring(rec ~= nil and rec ~= held) .. "/" .. tostring(rec ~= nil and SGValues.equal(rec, held)), "true/true")
    T.eq("E6 StockGuard's own operations are unchanged, and two drops carried", head(host) .. "/" .. (SC.stats.carried - carried0), "GROUND_WORK/COMMITTED/2")
    -- The raycast drop: the node's callback delivered later by name, inside the DROP frame.
    lv.spec_leveler.nodes[1].dropActive = false
    lv.spec_leveler.nodes[1].pickupActive = true
    -- Pick the moved material up again where the WORK drop left it (x 20).
    ENGINE_RAISE(lv, "onUpdate", 16)
    lv.spec_leveler.nodes[1].pickupActive = false
    lv.spec_leveler.nodes[1].castActive = true
    lv.spec_leveler.nodes[1].node.x = -20
    soilReset()
    ENGINE_RAISE(lv, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(0)
    d = lastDeliver()
    T.eq("E7 NAMED: a Leveler's raycast drop, inside its DROP frame, carries the same record",
        tostring(host.lastGroundFrame.kind) .. " " .. tostring(d and d.obs.litresReturned > 0) .. " " .. contribText(d and d.obs), "DROP true 1/litres=returned:soil.groundCondition:KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SOURCE RULES, ON STOCKGUARD'S OWN FRAME SHAPE
-- ══════════════════════════════════════════════════════════════════════════
-- The frame and capture are the shape SGGroundObserver builds (openFrame :644-650, captureOperation
-- :537-539, the SG-1 snapshot SGOperations.lua:605-611 and :537-548), made here so each rule can be
-- reached on its own.
local function unit(cid) return { fillUnitIndex = 1, carrierId = cid } end
local function stockOf(name, props) return { materialRef = { kind = "FILL_TYPE", fillTypeName = name }, properties = props or {} } end
local function frameWith(units, carriers, call, otherCall)
    local gf = { units = units }
    gf.pending = { pre = { call = otherCall or call }, capture = { before = { carriers = carriers } } }
    return { frame = gf, call = call }
end
group("S", function()
    local call = { fillTypeName = "WHEAT" }
    local rec = { propertyId = PID, knowledge = "KNOWN", payload = { c = 3 } }
    local none = { frame = { units = { unit("u1") }, pending = nil }, call = call }
    T.eq("S1 no capture of this call: nothing, NO_CAPTURE", tostring(select(2, SC.dropContributions(none, 10))), "NO_CAPTURE")
    local other = frameWith({ unit("u1") }, { u1 = { stock = stockOf("WHEAT", { [PID] = rec }) } }, call, { fillTypeName = "WHEAT" })
    T.eq("S2 the frame's pending capture belongs to another call: nothing, NO_CAPTURE", tostring(select(2, SC.dropContributions(other, 10))), "NO_CAPTURE")
    local wrong = frameWith({ unit("u1"), unit("u2") }, { u1 = { stock = stockOf("BARLEY", { [PID] = rec }) }, u2 = { stock = nil } }, call)
    T.eq("S3 no frame unit holds the dropped material: nothing, NO_SOURCE", tostring(select(2, SC.dropContributions(wrong, 10))), "NO_SOURCE")
    local two = frameWith({ unit("u1"), unit("u2") }, { u1 = { stock = stockOf("WHEAT", { [PID] = rec }) }, u2 = { stock = stockOf("WHEAT", {}) } }, call)
    T.eq("S4 two frame units hold it: nothing, AMBIGUOUS_SOURCE", tostring(select(2, SC.dropContributions(two, 10))), "AMBIGUOUS_SOURCE")
    local bare = frameWith({ unit("u1") }, { u1 = { stock = stockOf("WHEAT", {}) } }, call)
    local c = SC.dropContributions(bare, 10)
    T.eq("S5 the one source carries no record: its litres go with none", tostring(c and #c) .. "/" .. num(c and c[1].litres) .. "/" .. tostring(c and c[1].record), "1/10/nil")
    local one = frameWith({ unit("u1"), unit("u2") }, { u1 = { stock = stockOf("WHEAT", { [PID] = rec }) }, u2 = { stock = stockOf("BARLEY", {}) } }, call)
    local c2 = SC.dropContributions(one, 10)
    T.eq("S6 one source among the frame's units: its record", tostring(c2 and #c2) .. "/" .. tostring(c2 and c2[1].record and c2[1].record.payload.c), "1/3")
end)
