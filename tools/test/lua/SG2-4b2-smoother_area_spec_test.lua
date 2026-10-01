-- SG2-4b2-smoother_area_spec_test.lua
--
-- SG2-4b2: the smoothing brush (SG-2 v2.3 :162, :217-229) with its two profiles,
-- NATIVE_WORKED_PATCH_V1 and NATIVE_WHEEL_REDISTRIBUTION_V1, and the DensityMapHeightUtil
-- polygon methods (:162, :176-177, :243, :253, :280). Bob's readings:
-- Drafts/BOB-RULING-SG2-4B2-READINGS-2026-10-01.md.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), as SG2-4b's bench does.
--
-- THE ENTRY-POINT BARS ARE GROUPS E AND A1. E: the engine models, main.lua's modules and
-- main.lua; the mission through main's appends (the brush bracket on the engine global, the
-- WHEEL slot, the area methods on the util table, at loadMission00Finished); a tipper that
-- lays a tracked pile through the real tip path; then a Leveler's real onUpdate raised by
-- the engine's event dispatch, whose smoothing (Leveler.lua:264) calls the util's
-- smoothAroundLine (VERBATIM), which calls the engine global. A1: the cultivator's real
-- path (FSDensityMapUtil.updateCultivatorArea, :746) calling DensityMapHeightUtil.clearArea
-- (VERBATIM) through the util table. Nothing writes a binding, a carrier, a stock or a cell
-- by hand: every tracked cell is laid by a real tip; the only fixture is a pile the map
-- already holds (ENGINE_GROUND.put), which is the native height layer.
--
-- Groups:
--   E  the entry bar: a worked patch over a tracked pile
--   K  the worked patch: the core stirs whole (Q1), the fringe, the balance, a type change,
--      a native throw, untracked ground, a pickup's pool kept apart
--   H  the wheel redistribution: decreases give to increases, unchanged cells keep theirs;
--      a new class on the next map load
--   U  unframed brushes
--   A  the polygon methods: destruction, a partial clear, the weeder, a circle, untracked
--      ground, a conversion with no basis (Q3), the bunker paths (Q2) and its restore
--   L  installation and teardown
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, tools/test/lua/SG2-4b2-smoother_area_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGGroundBrush.lua, src/native/SGGroundArea.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local REAL = getmetatable(_G).__index
local M, GR, GO, NH, NA = SGNativeMaterialSave, SGGround, SGGroundObserver, SGNativeHost, SGNativeAdapters
local B, AR = SGGroundBrush, SGGroundArea
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
        weedSystem = ENGINE_WEED, userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = opts.index or 1, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

-- ── a property producer, as a domain owner registers one ─────────────────────
local PROP = "sg24b2.origin"
local function origin(value, amount)
    return { propertyId = PROP, schemaVersion = 1, producerId = "sg24b2", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { o = value } }
end
local originSpec = { schemaVersion = 1, producerId = "sg24b2", residency = "STORED",
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total, w, known = 0, 0, 0
        for _, c in ipairs(contributions) do
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

--- Boot through main.lua's load path. opts.duringLoad(m) runs in the async load window:
--- after loadMission00Finished queued the placeable load (and main's append installed the
--- brackets), before the restore-complete barrier at onFinishedLoading.
local function boot(build, saveDir, opts)
    opts = opts or {}
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
    if opts.duringLoad ~= nil then opts.duringLoad(m, w) end
    m:onFinishedLoading()
    return m, sg, NH.current, w, lease
end
local function vehicleIn(m, v) m._vehicles[#m._vehicles + 1] = v return v end
local function resetWorld()
    G_.reset()
    ENGINE_SMOOTH.reset()
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
local function publish(m, sg, lease, id, value)
    local s = stockAt(sg, id)
    if s == nil then return "NO_STOCK" end
    return m.stockGuard.publishProperties(lease, { { stockRef = sg.operations:stockRef(s), expectedPropertyRevision = 0, record = origin(value, s.observedAmount) } })
end
--- The ground stock of pixel (x, z), or nil.
local function cellStock(sg, host, x, z)
    local s = host:groundSampler()
    local id = s ~= nil and s.tracked ~= nil and s.tracked[GR.cellKey(x, z)] or nil
    return id and stockAt(sg, id) or nil, id
end
local function propAt(sg, host, x, z)
    local st = cellStock(sg, host, x, z)
    if st == nil then return "none" end
    local p = st.properties[PROP]
    if p == nil then return tostring(st.knowledge) .. ":-" end
    return tostring(st.knowledge) .. ":" .. num(p.payload.o)
end
local function groundCount(sg)
    local n, total = 0, 0
    for _, c in pairs(sg.operations.carriers) do
        if NA.isGroundKey(c.binding.carrierKey) then
            n = n + 1
            local s = c.stockId and sg.operations.stocks[c.stockId] or nil
            total = total + (s and s.observedAmount or 0)
        end
    end
    return n, total
end
local function last(host)
    local ls = host.lastSettlement
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome) .. (ls and ls.reason and ("/" .. tostring(ls.reason)) or "")
end

-- ── the world builders ─────────────────────────────────────────────────────
-- Pixel (px, pz) has its centre at ((p + 0.5) * 0.5 - 128). The four pixels around the
-- corner (10, 10) are 275..276 on each axis; a brush centred on that corner with R = 0.5
-- holds exactly those four in its core.
local CX, CZ = 275, 275
local function centreOf(px, pz) return (px + 0.5) * 0.5 - 128, (pz + 0.5) * 0.5 - 128 end
--- A thin tipper whose unit carries o = `o`: its discharge lands on the one pixel under it.
local function dot(m, w, name, o)
    w[name] = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:" .. name, { level = 400, fillType = WHEAT, at = { x = 0, z = 0 }, width = 0.01 }))
    w[name .. "O"] = o
end
local function tipOn(v, px, pz, liters)
    local node = v.spec_dischargeable.dischargeNodes[1].info.node
    node.x, node.z = centreOf(px, pz)
    ENGINE_TIP(v, liters)
end
--- A leveler whose one brush is centred on (wx, wz) with R = 0.5 (smoothAroundLine,
--- :491-506: width 1, radius 1, overlap 1 is one step of r 0.5).
local function brusher(m, w, wx, wz)
    w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = wx, z = wz }, level = 20, fillType = WHEAT, smooth = true }))
    local node = w.leveler.spec_leveler.nodes[1]
    node.width, node.smoothGroundRadius, node.smoothOverlap = 1, 1, 1
end
local function brush(w) ENGINE_RAISE(w.leveler, "onUpdate", 16) end
--- The standard world: two dot tippers (o = 7, o = 3) and a brusher on the corner (10, 10).
local function patchWorld(m, w)
    dot(m, w, "dot7", 7)
    dot(m, w, "dot3", 3)
    brusher(m, w, 10, 10)
end
local function marked(m, sg, lease, w)
    publish(m, sg, lease, unitId(w.dot7), 7)
    publish(m, sg, lease, unitId(w.dot3), 3)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY BAR: A WORKED PATCH OVER A TRACKED PILE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    local m, sg, host, w, lease = boot(patchWorld, "e_save", { index = 51 })
    T.ok("E1 [reached] main.lua sourced the brush and the area modules; the brush bracket is the value of the REAL global table's smoothDensityMapHeightAtWorldPos, the mod environment holds no copy, and the util's four polygon methods are wrapped",
        has(ENGINE_SOURCED, "src/native/SGGroundBrush.lua") and has(ENGINE_SOURCED, "src/native/SGGroundArea.lua")
        and B.bracket ~= nil and rawget(REAL, "smoothDensityMapHeightAtWorldPos") == B.bracket.wrapper and rawget(_G, "smoothDensityMapHeightAtWorldPos") == nil
        and AR.wraps ~= nil and DensityMapHeightUtil.clearArea == AR.wraps.entries.clearArea.wrapper and DensityMapHeightUtil.changeFillTypeAtArea == AR.wraps.entries.changeFillTypeAtArea.wrapper)
    T.eq("E1b the WheelDestruction class slot carries the WHEEL frame", tostring(rawget(WheelDestruction, B.CLASS_MARKER) ~= nil and WheelDestruction.smoothHeightAtPosition == rawget(WheelDestruction, B.CLASS_MARKER).smoothHeightAtPosition.wrapper), "true")
    marked(m, sg, lease, w)
    tipOn(w.dot7, CX + 1, CZ + 1, 8)
    tipOn(w.dot7, CX, CZ + 1, 8)
    tipOn(w.dot3, CX, CZ, 8)
    local n0, total0 = groundCount(sg)
    T.eq("E2 [world] three tracked cells laid by real tips: 8 L each, o = 7, 7 and 3", n0 .. "/" .. num(total0) .. "/" .. propAt(sg, host, CX + 1, CZ + 1) .. "/" .. propAt(sg, host, CX, CZ), "3/24/KNOWN:7/KNOWN:3")
    brush(w)
    local call = ENGINE_SMOOTH.log[#ENGINE_SMOOTH.log]
    T.eq("E3 [entry point] the Leveler's onUpdate smoothed through smoothAroundLine into the engine global: one brush, centre (10, 10), R 0.5, outer 1.7, and it settled as a worked patch, COMMITTED",
        #ENGINE_SMOOTH.log .. "/" .. num(call.x) .. "," .. num(call.z) .. "/" .. num(call.radius) .. "/" .. num(call.outerRadius) .. "/" .. last(host),
        "1/10,10/0.5/1.7/GROUND_NATIVE_WORKED_PATCH_V1/COMMITTED")
    local n1, total1 = groundCount(sg)
    local ev = host.lastSettlement.report.outcomeEvidence
    T.eq("E4 the native moved one raw unit (2 L) inside the core: the pool is the whole core before (24 L), the outputs the whole core after (24 L), and the store matches native (" .. n1 .. " cells, 24 L)",
        num(ev.pool) .. "/" .. num(ev.output) .. "/" .. num(total1) .. "/" .. num(G_.totalRaw(HT.WHEAT.index) * 2), "24/24/24/24")
    T.eq("E5 every core cell takes the pool's mixture, (7 x 16 + 3 x 8) / 24 = 5.6667, the unchanged ones too (:221-223)",
        propAt(sg, host, CX, CZ) .. " " .. propAt(sg, host, CX + 1, CZ) .. " " .. propAt(sg, host, CX, CZ + 1) .. " " .. propAt(sg, host, CX + 1, CZ + 1),
        "KNOWN:5.6667 KNOWN:5.6667 KNOWN:5.6667 KNOWN:5.6667")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE WORKED PATCH
-- ══════════════════════════════════════════════════════════════════════════
local function patched(index, setup)
    resetWorld()
    local m, sg, host, w, lease = boot(patchWorld, "k_save", { index = index })
    marked(m, sg, lease, w)
    tipOn(w.dot7, CX + 1, CZ + 1, 8)
    tipOn(w.dot7, CX, CZ + 1, 8)
    tipOn(w.dot3, CX, CZ, 8)
    if setup ~= nil then setup(m, sg, host, w) end
    return m, sg, host, w, lease
end
group("K", function()
    -- A fringe cell, unchanged by the brush, keeps its own facts; an empty fringe cell the
    -- brush raises is born with the pool's mixture.
    local m, sg, host, w = patched(52, function(m, sg, host, w) tipOn(w.dot3, CX + 3, CZ + 1, 8) end)
    ENGINE_SMOOTH.fringe = true
    brush(w)
    local known = { [GR.cellKey(CX, CZ)] = true, [GR.cellKey(CX + 1, CZ)] = true, [GR.cellKey(CX, CZ + 1)] = true, [GR.cellKey(CX + 1, CZ + 1)] = true, [GR.cellKey(CX + 3, CZ + 1)] = true }
    local born = "none"
    for key in pairs(host:groundSampler().tracked) do
        if not known[key] then
            local bx, bz = key:match("^(%d+):(%d+)")
            born = propAt(sg, host, tonumber(bx), tonumber(bz))
        end
    end
    local ev = host.lastSettlement.report.outcomeEvidence
    T.eq("K1 a unit leaves the core for an empty fringe cell: the core's remainder and the new fringe cell carry the pool's mixture; the unchanged fringe cell keeps o = 3",
        last(host) .. "/" .. num(ev.pool) .. "/" .. num(ev.output) .. "/" .. propAt(sg, host, CX, CZ) .. "/" .. born .. "/" .. propAt(sg, host, CX + 3, CZ + 1),
        "GROUND_NATIVE_WORKED_PATCH_V1/COMMITTED/24/24/KNOWN:5.6667/KNOWN:5.6667/KNOWN:3")
    FSBaseMission.delete(m)

    -- A fringe decrease contributes its portion; its remainder keeps its own facts.
    m, sg, host, w = patched(53, function(m, sg, host, w) tipOn(w.dot3, CX + 2, CZ + 1, 8) end)
    ENGINE_SMOOTH.fromFringe = true
    brush(w)
    ev = host.lastSettlement.report.outcomeEvidence
    T.eq("K2 a unit leaves a fringe cell (o = 3) into the core: the pool is the core (24 L) plus that 2 L, the fringe remainder keeps o = 3, the core takes (7 x 16 + 3 x 10) / 26",
        last(host) .. "/" .. num(ev.pool) .. "/" .. num(ev.output) .. "/" .. propAt(sg, host, CX + 2, CZ + 1) .. "/" .. propAt(sg, host, CX + 1, CZ + 1),
        "GROUND_NATIVE_WORKED_PATCH_V1/COMMITTED/26/26/KNOWN:3/KNOWN:" .. num((7 * 16 + 3 * 10) / 26))
    FSBaseMission.delete(m)

    -- The balance (:225): a shortage and a surplus are abandoned, never rescaled.
    m, sg, host, w = patched(54)
    ENGINE_SMOOTH.loseRaw = 1
    brush(w)
    local n, total = groundCount(sg)
    T.eq("K3 the native lost a unit: LOCAL_OPERATION_MISMATCH, every tracked core cell qualified UNAVAILABLE at native's actual quantity (20 L), no loss leg; the 2 L it moved into an empty cell stays untracked (native holds 22 L)",
        tostring(host.lastSettlement.outcome) .. "/" .. tostring(host.lastSettlement.reason) .. "/" .. propAt(sg, host, CX + 1, CZ + 1) .. "/" .. num(total) .. "/" .. num(G_.totalRaw(HT.WHEAT.index) * 2) .. "/" .. propAt(sg, host, CX + 1, CZ),
        "ABANDONED/LOCAL_OPERATION_MISMATCH/UNAVAILABLE:7/20/22/none")
    FSBaseMission.delete(m)
    m, sg, host, w = patched(55)
    ENGINE_SMOOTH.gainRaw = 1
    brush(w)
    T.eq("K4 the native gained a unit: abandoned the same way", tostring(host.lastSettlement.outcome) .. "/" .. tostring(host.lastSettlement.reason), "ABANDONED/LOCAL_OPERATION_MISMATCH")
    FSBaseMission.delete(m)

    -- A type change needs a declared conversion (:223).
    m, sg, host, w = patched(56)
    ENGINE_SMOOTH.typeTo = HT.BARLEY.index
    brush(w)
    local refusedType = host.lastGroundFrame and host.lastGroundFrame.refused.TYPE_CHANGED
    T.eq("K5 the receiving cell came out barley: TYPE_CHANGED, every core cell's facts qualified (the unchanged ones too, as a mismatch does), nothing mixed",
        tostring(refusedType) .. "/" .. propAt(sg, host, CX + 1, CZ + 1) .. "/" .. propAt(sg, host, CX, CZ), "1/UNAVAILABLE:7/UNAVAILABLE:3")
    FSBaseMission.delete(m)

    -- A native throw: the brush is reconciled through the generic path, and the error passes on.
    m, sg, host, w = patched(57)
    ENGINE_SMOOTH.error = "smooth failed"
    local ok, err = pcall(brush, w)
    T.eq("K6 a native throw passes to the caller; the frame records NATIVE_ERROR and the tracked cells are reconciled to native, not mixed",
        tostring(ok) .. "/" .. tostring(err) .. "/" .. tostring(host.lastGroundFrame and host.lastGroundFrame.refused.NATIVE_ERROR) .. "/" .. propAt(sg, host, CX + 1, CZ + 1),
        "false/smooth failed/1/KNOWN:7")
    FSBaseMission.delete(m)

    -- Untracked ground: a pile the map already holds.
    resetWorld()
    m, sg, host, w = boot(patchWorld, "k_save", { index = 58 })
    G_.put(CX, CZ, HT.WHEAT.index, 4)
    G_.put(CX + 1, CZ + 1, HT.WHEAT.index, 4)
    local reads, untracked = G_.queries, B.stats.untracked
    brush(w)
    T.eq("K7 a brush over ground StockGuard does not track is not read at all, and binds nothing", tostring(G_.queries == reads) .. "/" .. (B.stats.untracked - untracked) .. "/" .. (groundCount(sg)), "true/1/0")
    FSBaseMission.delete(m)
    -- A tracked cell inside the envelope that the brush does not involve: the participants are
    -- all untracked, so nothing is bound.
    resetWorld()
    local lease10
    m, sg, host, w, lease10 = boot(patchWorld, "k_save", { index = 74 })
    marked(m, sg, lease10, w)
    G_.put(CX, CZ, HT.WHEAT.index, 4)
    G_.put(CX + 1, CZ + 1, HT.WHEAT.index, 4)
    tipOn(w.dot7, CX + 3, CZ + 1, 8)
    local before10 = groundCount(sg)
    brush(w)
    T.eq("K10 a brush whose envelope reaches a tracked fringe cell it leaves unchanged, over a core of untracked material: read, but nothing is bound and the tracked cell keeps its facts",
        before10 .. ">" .. (groundCount(sg)) .. "/" .. propAt(sg, host, CX + 3, CZ + 1), "1>1/KNOWN:7")
    -- One tracked cell among untracked ones: every participant is bound, the untracked as UNKNOWN.
    FSBaseMission.delete(m)
    m, sg, host, w = patched(59, function(m, sg, host, w)
        G_.put(CX + 1, CZ, HT.WHEAT.index, 4)
    end)
    brush(w)
    T.eq("K8 a core that holds untracked material besides tracked cells: the untracked cell enters as UNKNOWN, so the mixture is PARTIAL on every core cell",
        last(host) .. "/" .. propAt(sg, host, CX, CZ):sub(1, 7) .. "/" .. propAt(sg, host, CX + 1, CZ):sub(1, 7), "GROUND_NATIVE_WORKED_PATCH_V1/COMMITTED/PARTIAL/PARTIAL")
    FSBaseMission.delete(m)

    -- A shovel's pickup and its brush in one tick: two operations, the brush's pool without the unit.
    resetWorld()
    m, sg, host, w = boot(function(m, w)
        dot(m, w, "dot7", 7)
        w.shovel = vehicleIn(m, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 10, z = 10 }, level = 0, smooth = true, rate = 0.25 }))
    end, "k_save", { index = 60 })
    for dx = 0, 1 do for dz = 0, 1 do tipOn(w.dot7, CX + dx, CZ + dz, 8) end end
    ENGINE_RAISE(w.shovel, "onUpdateTick", 16)
    local frame = host.lastGroundFrame
    local kinds = {}
    for _, op in ipairs(frame.operations) do kinds[#kinds + 1] = tostring(op.evidence and op.evidence.nativePath) end
    T.eq("K9 the Shovel's tick: the pickup line settles as its own TRANSFER first (with the unit), then the brush as a worked patch whose pool holds ground cells only (:251)",
        table.concat(kinds, ",") .. "/" .. tostring(frame.operations[#frame.operations].report.allocations[1].source.carrierId ~= unitId(w.shovel)),
        "GROUND_WORK," .. "GROUND_NATIVE_WORKED_PATCH_V1/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE WHEEL REDISTRIBUTION
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    local m, sg, host, w = patched(61)
    local wd = ENGINE_NEW_WHEEL(w.leveler)
    ENGINE_WHEEL_SMOOTH(wd, 10, 10)
    local ev = host.lastSettlement.report.outcomeEvidence
    T.eq("H1 a wheel's brush (WheelDestruction:update through self) runs in a WHEEL frame and settles as a wheel redistribution: the 2 L that left one cell went to the one that rose",
        last(host) .. "/" .. num(ev.pool) .. "/" .. num(ev.output) .. "/" .. tostring(host.lastGroundFrame and host.lastGroundFrame.kind),
        "GROUND_NATIVE_WHEEL_REDISTRIBUTION_V1/COMMITTED/2/2/" .. B.WHEEL_FRAME)
    T.eq("H2 unchanged contact cells are not stirred: they keep o = 7; the remainder of the source keeps o = 3, and the raised cell received o = 3",
        propAt(sg, host, CX + 1, CZ + 1) .. " " .. propAt(sg, host, CX, CZ + 1) .. " " .. propAt(sg, host, CX, CZ) .. " " .. propAt(sg, host, CX + 1, CZ),
        "KNOWN:7 KNOWN:7 KNOWN:3 KNOWN:3")
    ENGINE_SMOOTH.loseRaw = 1
    ENGINE_WHEEL_SMOOTH(wd, 10, 10)
    T.eq("H3 a wheel brush that does not balance is abandoned (no loss leg)", tostring(host.lastSettlement.outcome) .. "/" .. tostring(host.lastSettlement.reason), "ABANDONED/LOCAL_OPERATION_MISMATCH")
    FSBaseMission.delete(m)
    -- The next map load re-sources the class; the new table takes the WHEEL frame at install.
    resetWorld()
    ENGINE_LOAD_WHEELDESTRUCTION()
    local fresh = WheelDestruction
    m, sg, host, w = patched(62)
    local marks = rawget(fresh, B.CLASS_MARKER)
    local entry = marks ~= nil and marks.smoothHeightAtPosition or nil
    T.eq("H4 a second map load in one session: the new WheelDestruction class (read live at install) carries the WHEEL frame",
        tostring(fresh == WheelDestruction and entry ~= nil and fresh.smoothHeightAtPosition == entry.wrapper), "true")
    ENGINE_WHEEL_SMOOTH(ENGINE_NEW_WHEEL(w.leveler), 10, 10)
    T.eq("H5 and its brush settles in that frame", last(host), "GROUND_NATIVE_WHEEL_REDISTRIBUTION_V1/COMMITTED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNFRAMED BRUSHES
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local m, sg, host, w = patched(63)
    local before = B.stats.unframed
    REAL.smoothDensityMapHeightAtWorldPos(ENGINE_HEIGHT_UPDATER, 10, 0, 10, 1, HT.WHEAT.index, 0, 0.5, 1.7, 5)
    T.eq("U1 a brush outside any frame (a foreign caller, :227): no worked patch; the tracked cells that changed are reconciled to native and keep their own facts",
        (B.stats.unframed - before) .. "/" .. propAt(sg, host, CX, CZ) .. "/" .. propAt(sg, host, CX + 1, CZ + 1), "1/PARTIAL:3/KNOWN:7")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE POLYGON METHODS
-- ══════════════════════════════════════════════════════════════════════════
local function retired(sg, reason)
    local n = 0
    for _, s in pairs(sg.operations.retired or {}) do if s.retireReason == reason or s.reason == reason then n = n + 1 end end
    return n
end
group("A", function()
    local m, sg, host, w = patched(64)
    local n0, total0 = groundCount(sg)
    FSDensityMapUtil.updateCultivatorArea(9, 9, 11, 9, 9, 11)
    local ao = host.lastAreaOperation or {}
    local n1, total1 = groundCount(sg)
    T.eq("A1 [entry point] the cultivator's real path (:746) through the util's clearArea (VERBATIM): one REMOVE operation retiring every tracked cell's actual litres as DESTROYED; the carriers are withdrawn",
        tostring(ao.method) .. "/" .. tostring(ao.outcome) .. "/" .. num(ao.removed) .. "/" .. tostring(ao.evidence and ao.evidence.nativePath) .. "/" .. n0 .. ">" .. n1 .. "/" .. num(G_.totalRaw()),
        "clearArea/COMMITTED/24/GROUND_AREA_CLEARAREA/3>0/0")
    local destroyed, leg = 0, 0
    for _, a in ipairs(ao.report and ao.report.allocations or {}) do
        if a.destination.retire == true and a.result == "DESTROYED" and a.reason == "clearArea" then destroyed = destroyed + 1 leg = leg + a.sourceAmount end
    end
    T.eq("A1b each cell's removal is a retire leg with result DESTROYED, no sale, pickup or product (:177): 3 legs, 24 L", destroyed .. "/" .. num(leg) .. "/" .. #(ao.report and ao.report.allocations or {}), "3/24/3")
    FSBaseMission.delete(m)

    m, sg, host, w = patched(65)
    DensityMapHeightUtil.clearArea(9.5, 10, 10.5, 10, 9.5, 10.5)
    T.eq("A2 a clear over part of the pile retires only the cells it covered; the rest keep their stock and facts",
        num(host.lastAreaOperation.removed) .. "/" .. (groundCount(sg)) .. "/" .. propAt(sg, host, CX, CZ), "16/1/KNOWN:3")
    FSBaseMission.delete(m)

    m, sg, host, w = patched(66, function(m, sg, host, w) tipOn(w.dot7, CX + 4, CZ + 1, 8) end)
    DensityMapHeightUtil.clear(DensityMapCircle.createCircle(10, 10, 2, 8))
    T.eq("A3 a destructible's restore clears a circle (DensityMapHeightUtil.clear, :385): DESTROYED the same way, out to its radius (a cell 1.75 m from the centre)",
        tostring(host.lastAreaOperation.method) .. "/" .. num(host.lastAreaOperation.removed) .. "/" .. (groundCount(sg)), "clear/32/0")
    FSBaseMission.delete(m)

    m, sg, host, w = patched(73, function(m, sg, host, w) tipOn(w.dot7, CX + 1, CZ + 5, 8) end)
    DensityMapHeightUtil.clearArea(10, 6, 14, 10, 6, 10)
    T.eq("A11 a rotated parallelogram: its fourth corner (x1 + x2 - x0, z1 + z2 - z0) bounds the envelope too, so a tracked cell only that corner reaches is retired with the rest",
        num(host.lastAreaOperation.removed) .. "/" .. (groundCount(sg)), "32/0")
    FSBaseMission.delete(m)

    -- Untracked ground.
    resetWorld()
    m, sg, host, w = boot(patchWorld, "a_save", { index = 67 })
    G_.put(CX, CZ, HT.WHEAT.index, 4)
    local reads, untracked = G_.queries, AR.stats.untracked
    DensityMapHeightUtil.clearArea(9, 9, 11, 9, 9, 11)
    T.eq("A4 a clear over ground StockGuard does not track is not read and records nothing", tostring(G_.queries == reads) .. "/" .. (AR.stats.untracked - untracked) .. "/" .. tostring(host.lastAreaOperation), "true/1/nil")
    FSBaseMission.delete(m)

    -- A conversion with no registered basis (Q3, :280).
    m, sg, host, w = patched(68)
    DensityMapHeightUtil.changeFillTypeAtArea(9, 9, 11, 9, 9, 11, WHEAT, BARLEY)
    local st = cellStock(sg, host, CX + 1, CZ + 1)
    T.eq("A5 changeFillTypeAtArea: each converted tracked cell is abandoned as CONVERSION_UNREGISTERED; its new barley stock is UNKNOWN and inherits nothing of the wheat's facts",
        tostring(host.lastAreaOperation.reason) .. "/" .. tostring(st and st.materialRef and st.materialRef.fillTypeName) .. "/" .. tostring(st and st.knowledge) .. "/" .. tostring(st and st.properties[PROP] ~= nil),
        "CONVERSION_UNREGISTERED/BARLEY/UNKNOWN/false")
    FSBaseMission.delete(m)

    -- The weeder over a tracked windrow.
    resetWorld()
    m, sg, host, w = boot(function(m, w)
        w.windrow = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:windrow", { level = 300, fillType = ENGINE_FT.GRASS_WINDROW, supported = { [ENGINE_FT.GRASS_WINDROW] = true }, at = { x = 30, z = 30 } }))
    end, "a_save", { index = 69 })
    ENGINE_TIP(w.windrow, 40)
    local nW = groundCount(sg)
    FSDensityMapUtil.updateWeederArea(27, 27, 33, 27, 27, 33, false)
    T.eq("A6 the weeder's real path (:1637-1638) over a tracked windrow: removeFromGroundByArea retires its actual litres as DESTROYED (the typeless height it leaves holds none)",
        tostring(nW > 0) .. "/" .. tostring(host.lastAreaOperation.method) .. "/" .. num(host.lastAreaOperation.removed) .. "/" .. (groundCount(sg)), "true/removeFromGroundByArea/40/0")
    FSBaseMission.delete(m)

    -- The bunker (Q2).
    local function bunkerWorld(m, w)
        w.chaff = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:chaff", { level = 300, fillType = ENGINE_FT.CHAFF, supported = { [ENGINE_FT.CHAFF] = true }, at = { x = 50, z = 50 } }))
        w.silo = ENGINE_NEW_BUNKER(48, 48, 52, 52, ENGINE_FT.CHAFF, ENGINE_FT.FERMENTING, ENGINE_FT.SILAGE)
    end
    resetWorld()
    local calls, wrapped, ready
    m, sg, host, w = boot(bunkerWorld, "b_save", { index = 70, duringLoad = function(m, w)
        G_.put(197 + 160, 197 + 160, HT.FERMENTING.index, 4)
        calls = AR.stats.calls
        wrapped = DensityMapHeightUtil.removeFromGroundByArea == AR.wraps.entries.removeFromGroundByArea.wrapper
        ready = NH.current ~= nil and NH.current.ready
        w.silo:loadFromXMLFile(true)
    end })
    T.eq("A7 a bunker's XML restore (loadFromXMLFile, :285-293) runs in the placeable load: the brackets are already installed (end of loadMission00Finished) but the host is not ready until the barrier, so it writes no operation",
        tostring(wrapped) .. "/" .. tostring(ready) .. "/" .. tostring(AR.stats.calls == calls) .. "/" .. tostring(host.lastAreaOperation), "true/false/true/nil")
    ENGINE_TIP(w.chaff, 40)
    local nB = groundCount(sg)
    w.silo:close()
    T.eq("A8 closing the silo converts chaff to fermenting (:448): no registered basis, so CONVERSION_UNREGISTERED", tostring(nB > 0) .. "/" .. tostring(host.lastAreaOperation.reason), "true/CONVERSION_UNREGISTERED")
    w.silo:clearSiloArea()
    T.eq("A9 clearSiloArea (:580-585) is actual clearing (:243, :253): the silo's tracked cells retire as DESTROYED", tostring(host.lastAreaOperation.method) .. "/" .. tostring(host.lastAreaOperation.outcome) .. "/" .. (groundCount(sg)), "clearArea/COMMITTED/0")
    ENGINE_TIP(w.chaff, 40)
    w.silo.fermentingFillType = ENGINE_FT.CHAFF
    w.silo:drainResidue()
    T.eq("A10 the drain residue (:412-413) is actual emptying: DESTROYED", tostring(host.lastAreaOperation.method) .. "/" .. num(host.lastAreaOperation.removed) .. "/" .. (groundCount(sg)), "removeFromGroundByArea/40/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. INSTALLATION AND TEARDOWN
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    resetWorld()
    local m = boot(patchWorld, "l_save", { index = 71 })
    local native = B.bracket.original
    local nativeChange = AR.wraps.entries.changeFillTypeAtArea.original
    local ours = DensityMapHeightUtil.clearArea
    DensityMapHeightUtil.clearArea = function(...) return ours(...) end
    local laterClear = DensityMapHeightUtil.clearArea
    FSBaseMission.delete(m)
    T.eq("L1 teardown restores the engine global and every util method still ours; one under a later wrapper stays, the later wrapper untouched",
        tostring(rawget(REAL, "smoothDensityMapHeightAtWorldPos") == native) .. "/" .. tostring(B.bracket) .. "/" .. tostring(DensityMapHeightUtil.clearArea == laterClear)
            .. "/" .. tostring(DensityMapHeightUtil.changeFillTypeAtArea == nativeChange),
        "true/nil/true/true")
    local m2, sg2, host2, w2 = boot(patchWorld, "l_save", { index = 72 })
    tipOn(w2.dot7, CX, CZ, 8)
    local calls, writes = AR.stats.calls, G_.writes or 0
    DensityMapHeightUtil.clearArea(9, 9, 11, 9, 9, 11)
    T.eq("L2 the next mission never stacks a second area wrapper over ours left under a later one: one call is observed once and reaches native once (two channel writes)",
        (AR.stats.calls - calls) .. "/" .. ((G_.writes or 0) - writes) .. "/" .. (groundCount(sg2)), "1/2/0")
    FSBaseMission.delete(m2)
end)
