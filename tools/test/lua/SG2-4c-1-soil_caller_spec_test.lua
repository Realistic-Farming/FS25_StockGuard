-- SG2-4c-1-soil_caller_spec_test.lua
--
-- SG2-4c-1: the Soil caller (SG-2 v2.3 :354-362, GROUND-CONDITION-CONTRACT v1.5 section 7,
-- Iris' D2 answer and answer 2), for the line bracket's calls inside StockGuard's own TIP, WORK
-- and DROP frames. Bob's readings: Drafts/BOB-RULING-SG2-4C-READINGS-2026-10-02.md.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world (its preamble is
-- taken from SG2-4b-ground_observer_spec_test.lua as it stands).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path, a tipper observed at the barrier, then
-- the engine's Dischargeable:discharge in the GROUND state reaching the util and the engine
-- global inside the TIP frame. Soil's PUBLISHED SURFACE is a recorder (Bob's choice for this
-- bench, his reply of 2026-10-02): getCapabilities on the mission's soilFertilityManager
-- handle and the groundCondition table's three plain functions, each taking every argument and
-- counting them. The rows pin the literal arguments against what native received and what the
-- util returned. Soil's own response to the admission count (its observer standing aside) is
-- pinned by Soil's RSF-F208-s3c group D; the one-projection pair with both real modules in one
-- process was run once before the PR, not committed (the PR body names it).
--
-- Groups:
--   E  the entry-point bar: a real tip, admitted, delivered in LITRES, closed, in order
--   W  the WORK and DROP frames: a Shovel's pickup (negative litres), a Leveler's drop
--   U  unframed calls are never admitted (the Tedder's shape, a foreign global call), nor a
--      dry run inside a frame; a framed call StockGuard refuses as its own operation is still
--      admitted, typed by the height type's fill type
--   G  the gate: revision 1, no groundCondition, no Soil, a throwing capability, REFUSED, a
--      table missing a function
--   X  Soil never breaks native: a throw in admit, deliver or close; a native throw delivers
--      ok = false, closes, and is re-raised unchanged
--   D  the save boundary: a deferred call is not a primitive; the held drop is admitted later
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

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A REAL TIP, ADMITTED, DELIVERED IN LITRES, CLOSED
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    soilReset()
    UTIL = {}
    local m, sg, host, w, lease = boot(function(m, w) soilOn(m) tipWorld(m, w) end, "e_save", { index = 41 })
    T.ok("E0 [reached] main.lua sourced the Soil caller, and the line bracket is the value of the REAL global table's addDensityMapHeightAtWorldLine",
        has(ENGINE_SOURCED, "src/native/SGSoilCondition.lua") and GO.bracket ~= nil and rawget(REAL, "addDensityMapHeightAtWorldLine") == GO.bracket.wrapper)
    publish(m, sg, lease, unitId(w.tipper), 7)
    local q0, l0 = G_.queries, #G_.lineCalls
    ENGINE_TIP(w.tipper, 100)
    local native = G_.lineCalls[#G_.lineCalls]
    local gf = host.lastGroundFrame
    local a, d, c = callOf("admit"), callOf("deliver"), callOf("close")
    T.eq("E1 the engine's discharge reached the line inside the TIP frame: Soil was asked once, then given the observation, then closed, each a plain call with all its arguments",
        fns(), "admit(4) deliver(2) close(1)")
    T.eq("E1b the delivery and the close name the lease admitPrimitive returned", tostring(d and d.token) .. "/" .. tostring(c and c.token), "SFGC-bench-1/SFGC-bench-1")
    local fp = a and a.footprint or {}
    T.eq("E2 the footprint is the line native received, in Soil's v1 LINE shape, typed by the height type's fill type",
        tostring(fp.schemaVersion) .. "/" .. tostring(fp.kind) .. "/" .. num(fp.sx) .. "," .. num(fp.sz) .. "," .. num(fp.ex) .. "," .. num(fp.ez) .. "/" .. num(fp.innerRadius) .. "/" .. num(fp.radius) .. "/" .. tostring(fp.fillTypeIndex) .. "/" .. tostring(a and a.kind),
        "1/LINE/" .. num(native.sx) .. "," .. num(native.sz) .. "," .. num(native.ex) .. "," .. num(native.ez) .. "/" .. num(native.innerRadius) .. "/" .. num(native.radius) .. "/" .. tostring(WHEAT) .. "/TIP_TO_GROUND_AROUND_LINE")
    T.eq("E3 the vehicle is the tipper, the work area the TIP frame's callRef and the primitive's sequence",
        tostring(a and a.vehicle == w.tipper) .. "/" .. tostring(a and a.workArea ~= nil and a.workArea:sub(1, #gf.callRef + 1) == gf.callRef .. "#") .. "/" .. tostring(gf.kind), "true/true/TIP")
    local obs = d and d.obs or {}
    T.eq("E4 NAMED: the observation is in LITRES (Bob's build condition): the util's own delta and return, while native was handed half (fillToGroundScale 0.5)",
        tostring(obs.schemaVersion) .. "/" .. tostring(obs.primitiveKind) .. "/" .. tostring(obs.ok) .. "/" .. tostring(obs.fillTypeIndex) .. "/" .. num(obs.deltaRequested) .. "/" .. num(obs.litresReturned) .. "/" .. num(obs.lineOffset) .. " native " .. num(native.delta),
        "1/TIP_TO_GROUND_AROUND_LINE/true/" .. tostring(WHEAT) .. "/" .. num(UTIL[#UTIL].delta) .. "/" .. num(UTIL[#UTIL].returned) .. "/" .. num(native.lineOffset + 1) .. " native " .. num(UTIL[#UTIL].delta * 0.5))
    T.eq("E4b and the util's litres are what left the tipper", num(UTIL[#UTIL].returned) .. "/" .. num(600 - level(w.tipper)), "100/100")
    T.eq("E5 NAMED: admit ran before StockGuard's first ground read and before native; the delivery after native and after StockGuard's last read",
        tostring(a and a.queries == q0) .. "/" .. tostring(a and a.lineCalls == l0) .. "/" .. tostring(d and d.lineCalls == l0 + 1) .. "/" .. tostring(d and d.queries == G_.queries) .. "/" .. tostring(G_.queries > q0),
        "true/true/true/true/true")
    T.eq("E6 StockGuard's own operation is unchanged: ONE TRANSFER, GROUND_TIP, COMMITTED", head(host), "GROUND_TIP/COMMITTED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE WORK AND DROP FRAMES: A SHOVEL'S PICKUP AND A LEVELER'S DROP
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    resetWorld()
    soilReset()
    UTIL = {}
    local m, sg, host, w, lease = boot(tipShovelLevelerWorld, "w_save", { index = 42 })
    ENGINE_TIP(w.tipper, 100)
    soilReset()
    local before = level(w.shovel)
    ENGINE_RAISE(w.shovel, "onUpdateTick", 400)
    local gained = level(w.shovel) - before
    local a, d = callOf("admit"), callOf("deliver")
    local native = G_.lineCalls[#G_.lineCalls]
    T.eq("W1 a Shovel's pickup inside its WORK frame is admitted with the shovel as the vehicle, then delivered and closed",
        fns() .. "/" .. tostring(a and a.vehicle == w.shovel) .. "/" .. tostring(host.lastGroundFrame.kind), "admit(4) deliver(2) close(1)/true/WORK")
    T.eq("W2 NAMED: a pickup's observation is negative litres: the delta the util asked for, and exactly what the bucket gained (native handed half)",
        num(d and d.obs.deltaRequested) .. "/" .. num(d and d.obs.litresReturned) .. "/" .. num(-gained) .. " native " .. num(native.delta),
        num(native.delta / 0.5) .. "/" .. num(-gained) .. "/" .. num(-gained) .. " native " .. num(native.delta))
    -- The Leveler's drop, its raycast callback delivered later by name on the node.
    local lv = w.leveler
    lv.spec_fillUnit.fillUnits[1].fillLevel, lv.spec_fillUnit.fillUnits[1].fillType = 20, WHEAT
    host.handle.refreshCarrier(host.nativeLease, NA.fillUnitBinding(lv, 1), "BENCH")
    lv.spec_leveler.nodes[1].castActive = true
    lv.spec_leveler.nodes[1].node.x = -20
    soilReset()
    ENGINE_RAISE(lv, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(0)
    a = callOf("admit")
    T.eq("W3 a Leveler's raycast drop inside its DROP frame is admitted with the leveler as the vehicle and the DROP frame's callRef",
        fns() .. "/" .. tostring(a and a.vehicle == lv) .. "/" .. tostring(host.lastGroundFrame.kind) .. "/" .. tostring(a and a.workArea:sub(1, #host.lastGroundFrame.callRef) == host.lastGroundFrame.callRef),
        "admit(4) deliver(2) close(1)/true/DROP/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNFRAMED CALLS ARE NEVER ADMITTED (Bob's correction: Soil's carriers keep them)
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w) soilOn(m) tipWorld(m, w, { at = { x = 30, z = 30 } }) end, "u_save", { index = 43 })
    soilReset()
    local l0, u0 = #G_.lineCalls, SC.stats.unframed
    -- A Tedder's shape: the util called directly by a vehicle StockGuard has no frame for.
    DensityMapHeightUtil.tipToGroundAroundLine({ id = "tedder" }, 20, WHEAT, -30, 0, -30, -29, 0, -30, 0.5, 1, 0, false)
    T.eq("U1 NAMED: a util tip with no StockGuard frame (the Mower, Tedder and Windrower until SG2-5) runs native and asks Soil nothing at all, not even the capability",
        tostring(#G_.lineCalls - l0) .. "/" .. #SOIL.calls .. "/" .. SOIL.caps .. "/" .. tostring(SC.stats.unframed - u0), "1/0/0/1")
    REAL.addDensityMapHeightAtWorldLine(ENGINE_HEIGHT_UPDATER, -40, 0, -40, -39, 0, -40, 10, HT.WHEAT.index, 0.5, 1, false, 0, true, 5)
    T.eq("U2 a foreign call of the global, unframed: no Soil call", #SOIL.calls .. "/" .. SOIL.caps, "0/0")
    -- A frame opened on the tipper: a dry run inside it is still not a primitive.
    local frame = GO.openFrame(host, w.tipper, { kind = GO.TIP, units = { 1 }, expectType = WHEAT, dropsOnly = true, requested = 10 })
    REAL.addDensityMapHeightAtWorldLine(ENGINE_HEIGHT_UPDATER, 30, 0, 30, 31, 0, 30, 10, HT.WHEAT.index, 0.5, 1, false, 0, false, 5)
    T.eq("U3 a dry run (applyChanges false) inside a TIP frame is never admitted", tostring(frame ~= nil) .. "/" .. #SOIL.calls, "true/0")
    -- Inside the same frame, a line of grass windrow (fill type 7, height type index 3): the TIP frame
    -- expects wheat and refuses it as its own operation, and Soil is admitted all the same.
    local gw = HT.GRASS_WINDROW
    REAL.addDensityMapHeightAtWorldLine(ENGINE_HEIGHT_UPDATER, 30, 0, 30, 31, 0, 30, 10, gw.index, 0.5, 1, false, 0, true, 5)
    local a, d = callOf("admit"), callOf("deliver")
    T.eq("U4 NAMED: the footprint and the observation name the height type's FILL type (7), not its index (3); StockGuard refusing the call as its own operation does not stop Soil's",
        tostring(a and a.footprint.fillTypeIndex) .. "/" .. tostring(d and d.obs.fillTypeIndex) .. "/" .. tostring(gw.index) .. "/" .. tostring((frame.ground.refused or {})["CONVERTED_AT_GROUND"]),
        tostring(ENGINE_FT.GRASS_WINDROW) .. "/" .. tostring(ENGINE_FT.GRASS_WINDROW) .. "/3/1")
    GO.closeFrame(host, frame, true)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE GATE: ANYTHING BUT REVISION 2 IS SOIL ABSENT; REFUSED MINTS NO LEASE
-- ══════════════════════════════════════════════════════════════════════════
local function gateCase(opts, setup)
    resetWorld()
    soilReset(opts)
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        if setup then setup(m) end
        tipWorld(m, w, { at = { x = 50, z = 50 } })
    end, "g_save", { index = 44 })
    local before = level(w.tipper)
    ENGINE_TIP(w.tipper, 50)
    local out = { fns = fns(), caps = SOIL.caps, op = head(host), tipped = before - level(w.tipper) }
    FSBaseMission.delete(m)
    return out
end
group("G", function()
    local r1 = gateCase({ revision = 1 })
    T.eq("G1 NAMED: revision 1 is Soil absent (the D2 rule): the capability is read, nothing is admitted, and the tip runs as without Soil",
        r1.fns .. "/" .. r1.caps .. "/" .. r1.op .. "/" .. num(r1.tipped), "/1/GROUND_TIP/COMMITTED/50")
    local r2 = gateCase({ revision = false })
    T.eq("G2 a capability table with no groundCondition: nothing admitted", r2.fns .. "/" .. r2.caps .. "/" .. r2.op, "/1/GROUND_TIP/COMMITTED")
    local r3 = gateCase({}, function(m) m.soilFertilityManager = nil end)
    T.eq("G3 no Soil on the mission: nothing admitted, the tip unchanged", r3.fns .. "/" .. r3.op .. "/" .. num(r3.tipped), "/GROUND_TIP/COMMITTED/50")
    local r4 = gateCase({ throwAt = "caps" })
    T.eq("G4 a getCapabilities that throws is Soil absent, and native work is untouched", r4.fns .. "/" .. r4.op .. "/" .. num(r4.tipped), "/GROUND_TIP/COMMITTED/50")
    local r5 = gateCase({ refuse = true })
    T.eq("G5 NAMED: REFUSED mints no lease: no delivery and no close, and the tip unchanged", r5.fns .. "/" .. r5.op .. "/" .. num(r5.tipped), "admit(4)/GROUND_TIP/COMMITTED/50")
    local r6 = gateCase({ noDeliver = true })
    T.eq("G6 a published table missing deliverMovement is no interface: nothing admitted", r6.fns .. "/" .. r6.op, "/GROUND_TIP/COMMITTED")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. SOIL NEVER BREAKS NATIVE: A THROW ON EITHER SIDE
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local x1 = gateCase({ throwAt = "admit" })
    T.eq("X1 an admitPrimitive that throws: no delivery or close, the tip unchanged", x1.fns .. "/" .. x1.op .. "/" .. num(x1.tipped), "admit(4)/GROUND_TIP/COMMITTED/50")
    local x2 = gateCase({ throwAt = "deliver" })
    T.eq("X2 NAMED: a deliverMovement that throws: the lease is still closed, the tip unchanged", x2.fns .. "/" .. x2.op .. "/" .. num(x2.tipped), "admit(4) deliver(2) close(1)/GROUND_TIP/COMMITTED/50")
    local x3 = gateCase({ throwAt = "close" })
    T.eq("X3 a closePrimitive that throws: nothing raised, the tip unchanged", x3.fns .. "/" .. x3.op .. "/" .. num(x3.tipped), "admit(4) deliver(2) close(1)/GROUND_TIP/COMMITTED/50")
    -- Native throws: the observation says so, the lease closes, the error reaches the caller unchanged.
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w) soilOn(m) tipWorld(m, w, { at = { x = 60, z = 60 } }) end, "x_save", { index = 45 })
    G_.lineError = "bench: native line threw"
    local ok, err = pcall(REAL.addDensityMapHeightAtWorldLine, ENGINE_HEIGHT_UPDATER, 60, 0, 60, 61, 0, 60, 10, HT.WHEAT.index, 0.5, 1, false, 0, true, 5)
    G_.lineError = nil
    T.eq("X4 an unframed native throw asks Soil nothing and is re-raised unchanged", tostring(ok) .. "/" .. tostring(err) .. "/" .. #SOIL.calls, "false/bench: native line threw/0")
    local frame = GO.openFrame(host, w.tipper, { kind = GO.TIP, units = { 1 }, expectType = WHEAT, dropsOnly = true, requested = 10 })
    G_.lineError = "bench: native line threw"
    ok, err = pcall(REAL.addDensityMapHeightAtWorldLine, ENGINE_HEIGHT_UPDATER, 60, 0, 60, 61, 0, 60, 10, HT.WHEAT.index, 0.5, 1, false, 0, true, 5)
    G_.lineError = nil
    local d = callOf("deliver")
    T.eq("X5 NAMED: a native throw inside a frame delivers ok = false and nothing else, closes the lease, and is re-raised unchanged",
        tostring(ok) .. "/" .. tostring(err) .. "/" .. fns() .. "/" .. tostring(d and d.obs.ok) .. "/" .. tostring(d and d.obs.litresReturned) .. "/" .. tostring(d and d.obs.primitiveKind),
        "false/bench: native line threw/admit(4) deliver(2) close(1)/false/nil/TIP_TO_GROUND_AROUND_LINE")
    GO.closeFrame(host, frame, false)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE SAVE BOUNDARY: A DEFERRED CALL IS NOT A PRIMITIVE; THE HELD DROP IS, LATER
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    resetWorld()
    soilReset()
    local m, sg, host, w = boot(function(m, w)
        soilOn(m)
        tipWorld(m, w)
        w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = -40, z = 0 }, level = 20, fillType = WHEAT, cast = true }))
    end, "d_save", { index = 46 })
    soilReset()
    M.openDeferral()
    ENGINE_TIP(w.tipper, 100)
    ENGINE_RAISE(w.leveler, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(0)
    T.eq("D1 inside the save boundary the tip is deferred and the Leveler's callback held: Soil is asked nothing", #SOIL.calls .. "/" .. #M.deferral.queue, "0/1")
    M.closeDeferral()
    local a = callOf("admit")
    T.eq("D2 at the close the held callback runs once in its DROP frame and is admitted then, with the leveler; the refused tip is not",
        fns() .. "/" .. tostring(a and a.vehicle == w.leveler) .. "/" .. tostring(host.lastGroundFrame and host.lastGroundFrame.kind), "admit(4) deliver(2) close(1)/true/DROP")
    FSBaseMission.delete(m)
end)

DensityMapHeightUtil.tipToGroundAroundLine = REAL_UTIL_TIP
