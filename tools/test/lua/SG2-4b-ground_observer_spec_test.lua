-- SG2-4b-ground_observer_spec_test.lua
--
-- SG2-4b: the per-pixel ground observer and producer (SG-2 v2.3 :158-177, :225-231,
-- :251, :257-272, :563-577), the line bracket on the real engine global, the tip, the
-- Shovel and Leveler pickups and drops as TRANSFERs, and the Leveler and tip deferrals.
-- Bob's readings: Drafts/BOB-RULING-SG2-4B-READINGS-2026-10-01.md; Desk's scope call (a).
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv): the engine models and the C
-- functions live in the real global table, the mod's src and this file in an environment
-- whose _G is itself; engine globals are set in the real table.
--
-- THE ENTRY-POINT BAR IS GROUP E. The engine models, then main.lua's modules and
-- main.lua; the mission through main's appends (the class hooks, the native adapter, the
-- ground and the line bracket at loadMission00Finished); a tipper in the mission's vehicle
-- list, observed at the barrier the way every vehicle is; then one server frame of the
-- engine's Dischargeable:discharge in the GROUND state, which calls dischargeToGround
-- through self, which calls DensityMapHeightUtil.tipToGroundAroundLine, which calls the
-- engine global. Then the modeled SavegameController's own save and a fresh mission on the
-- final directory. Nothing writes a binding, a carrier, a stock, a cell or a payload by
-- hand; the one fixture is the pile a map already holds (ENGINE_GROUND.put), which is the
-- native height layer, not StockGuard's record.
--
-- Groups:
--   E  the entry-point bar: tip, then save and reload
--   S  the sampler: one pixel proved; cardinality, type and index refusals; blocks
--   L  the line bracket: dry run, unframed births and pickups, a gain on a tracked cell,
--      a native throw, every return, removal
--   T  the tip's admission and its quantization (Bob R2, R6)
--   W  the WORK and DROP frames: Shovel and Leveler pickups and drops (Bob R3, Desk (a))
--   D  the deferrals (R4)
--   R  the records: the core leaves ground out, the payload carries it, the history bound
--      (R5), drift read again at the boundary
--   Y  typeless height (index 0): the weeder's removal leaves it, the sampler reads it as
--      no material, a tip onto it settles, a tracked windrow it replaced retires at the save
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

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

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetWorld()
    local lines, m, sg, host, w, lease
    lines = printed(function() m, sg, host, w, lease = boot(tipWorld, "e_save", { index = 31 }) end)
    T.ok("E1 [reached] main.lua sourced the sampler and the observer; the line bracket is the value of the REAL global table's addDensityMapHeightAtWorldLine and the mod environment holds no copy of its own",
        has(ENGINE_SOURCED, "src/native/SGGroundSampler.lua") and has(ENGINE_SOURCED, "src/native/SGGroundObserver.lua")
        and GO.bracket ~= nil and rawget(REAL, "addDensityMapHeightAtWorldLine") == GO.bracket.wrapper and rawget(_G, "addDensityMapHeightAtWorldLine") == nil)
    T.eq("E1b the tipper's dischargeToGround instance slot is the tip frame, installed when the barrier observed it", tostring(rawget(w.tipper, GO.TIP_MARKER) ~= nil and w.tipper.dischargeToGround == rawget(w.tipper, GO.TIP_MARKER).wrapper), "true")
    local recLU, recSU = SGClassHook.record(Leveler, "onUpdate", GO.HOOK_ID), SGClassHook.record(Shovel, "onUpdateTick", GO.HOOK_ID)
    T.eq("E1c the Leveler and Shovel class slots carry the work frames, each one SGClassHook record whose wrapper is the live method",
        tostring(recLU ~= nil and Leveler.onUpdate == recLU.wrapper) .. "/" .. tostring(recSU ~= nil and Shovel.onUpdateTick == recSU.wrapper), "true/true")
    local uid = unitId(w.tipper)
    T.eq("E2 the unit has a stock; the producer marks it (o = 7)", tostring(publish(m, sg, lease, uid, 7)), "APPLIED")
    ENGINE_TIP(w.tipper, 100)
    local n, total = groundOf(sg)
    T.eq("E3 ONE TRANSFER: the engine's discharge in the GROUND state reached dischargeToGround, the util and the line; the op settled as GROUND_TIP and COMMITTED",
        head(host), "GROUND_TIP/COMMITTED")
    T.eq("E4 the unit lost 100 L, the ground gained 100 L (50 raw of wheat) over " .. n .. " cells, each a ground carrier with its stock", num(level(w.tipper)) .. "/" .. num(total) .. "/" .. num(G_.totalRaw(HT.WHEAT.index)) .. "/" .. tostring(n > 1), "500/100/50/true")
    T.eq("E5 source and destination agree: every cell moved from the unit, no loss, nothing unexplained", totals(host) .. " " .. legs(host), "100/100/0/0 WHEAT " .. n .. " moved, loss 0")
    local st = groundStocks(sg)
    local allKnown = true
    for _, s in ipairs(st) do if s.properties[PROP] == nil or s.properties[PROP].payload.o ~= 7 or s.knowledge ~= "KNOWN" then allKnown = false end end
    T.eq("E6 the unit's history followed the goods: every cell's stock carries o = 7, KNOWN, combined from the unit's stock", tostring(allKnown) .. "/" .. tostring(SEEN.sources[1] == stockAt(sg, uid).stockId), "true/true")
    T.eq("E6b a ground cell's hasAccess is false, and it did not stop the settlement (R1)", tostring(host.nativeLease.spec.hasAccess(sg.operations.carriers[st[1].carrierId].binding, { actorState = "RESOLVED", farmId = 1 })), "false")
    ENGINE_TIP(w.tipper, 100)
    local n2, total2 = groundOf(sg)
    T.eq("E7 a second frame onto the same pile: one more TRANSFER, 200 L on the ground, the cells that were already there keep their stock identity",
        head(host) .. "/" .. num(total2) .. "/" .. tostring(stockAt(sg, st[1].carrierId) ~= nil and stockAt(sg, st[1].carrierId).stockId == st[1].stockId), "GROUND_TIP/COMMITTED/200/true")
    -- Save, then a fresh mission on the final directory.
    lines = printed(function() nativeSave(m, "e_final") end)
    local e = envelopeAt("e_final")
    local groundInCore = 0
    for _, c in ipairs(e.coreValues.carriers) do if NA.isGroundKey(c.binding.carrierKey) then groundInCore = groundInCore + 1 end end
    local tree = payloadTree("e_final")
    local cells = 0
    for _, r in ipairs(tree.runs) do cells = cells + r.n end
    T.eq("E8 the save: the envelope's coreValues hold no ground carrier; the payload holds every occupied cell once, with its stock identity", groundInCore .. "/" .. cells .. "/" .. n2, "0/" .. n2 .. "/" .. n2)
    local build = function(m2, w2) tipWorld(m2, w2, { level = level(w.tipper) }) end
    local m2, sg2
    lines = printed(function() m2, sg2 = reload(m, "e_final", build, { index = 31 }) end)
    local n3, total3 = groundOf(sg2)
    local st2 = groundStocks(sg2)
    local reattached = true
    for i, s in ipairs(st2) do
        local before = nil
        for _, old in ipairs(groundStocks(sg)) do if old.carrierId == s.carrierId then before = old end end
    end
    local sameIds, props = 0, true
    local oldIds = {}
    for _, s in ipairs(st) do oldIds[s.stockId] = true end
    for _, s in ipairs(st2) do
        if oldIds[s.stockId] then sameIds = sameIds + 1 end
        if s.properties[PROP] == nil or s.properties[PROP].payload.o ~= 7 then props = false end
    end
    T.eq("E9 the reload: every cell reattached to its pixel through the core's own restore, its stock identity and o = 7 intact, " .. num(total3) .. " L",
        tostring(sg2.ground.lastRestore and sg2.ground.lastRestore.restored) .. "/" .. n3 .. "/" .. tostring(sameIds >= #st) .. "/" .. tostring(props) .. "/" .. num(total3),
        tostring(n2) .. "/" .. n2 .. "/true/true/200")
    T.ok("E9b and it said so once", has(lines, "restored: " .. n2 .. " cell(s)"))
    REAL.addDensityMapHeightAtWorldLine(ENGINE_HEIGHT_UPDATER, 9, 0, 10, 11, 0, 10, -1000, HT.WHEAT.index, 0.5, 8, false, 0, true, 5)
    T.eq("E10 the restored cells are tracked: a foreign pickup that empties them after the reload retires and withdraws every one", (groundOf(sg2)) .. "/" .. G_.totalRaw(), "0/0")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SAMPLER
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    resetWorld()
    local m, sg, host = boot(nil, "s_save", { index = 32 })
    local s = host:groundSampler()
    T.eq("S1 the grid: 512 pixels of 0.5 m over the 256 m terrain, centred", tostring(s.size) .. "/" .. num(s.pitch) .. "/" .. num(s.half), "512/0.5/128")
    G_.put(300, 260, HT.WHEAT.index, 5)
    local c = s:readCell(300, 260)
    T.eq("S2 one pixel proved: its raw height, its type through the height manager, litres as raw x getMinValidLiterValue", c.raw .. "/" .. c.fillTypeName .. "/" .. num(c.liters), "5/WHEAT/10")
    local e = s:readCell(301, 260)
    T.eq("S3 an empty pixel reads as empty, with no material", e.raw .. "/" .. num(e.liters) .. "/" .. tostring(e.fillTypeName), "0/0/nil")
    local wx, wz = s:cellCentre(300, 260)
    T.eq("S4 world and grid agree: the pixel's centre falls back in the pixel", table.concat({ s:cellOfWorld(wx, wz) }, ","), "300,260")
    G_.expand = 1
    T.eq("S5 a rounding that takes a neighbour is refused, never summed (totalNumPixels must be 1)", tostring(({ s:readCell(300, 260) })[2]), "CARDINALITY")
    G_.expand = 0
    T.eq("S5b a cardinality failure latches that binding; each proof row below reads through a fresh one", tostring(s.fault and s.fault.reason), "CARDINALITY")
    s = GS.bind(m)
    G_.typedLie = G_.key(300, 260)
    T.eq("S6 the type channel and the typed positive-height query must agree", tostring(({ s:readCell(300, 260) })[2]), "TYPE_UNVERIFIED")
    G_.typedLie = nil
    s = GS.bind(m)
    G_.types[G_.key(300, 260)] = 9
    T.eq("S7 an index the height manager does not know is refused", tostring(({ s:readCell(300, 260) })[2]), "UNKNOWN_TYPE_INDEX")
    T.eq("S7b an unknown type index does not latch", tostring(s.fault), "nil")
    G_.put(300, 260, HT.WHEAT.index, 5)
    G_.put(310, 270, HT.BARLEY.index, 3)
    local before = G_.queries
    local rect = s:sampleRect(290, 250, 329, 289)
    local keys = {}
    for k in pairs(rect) do keys[#keys + 1] = k end
    table.sort(keys)
    T.eq("S8 a 40 x 40 block reads only its occupied pixels; empty blocks are proved empty with one query each", table.concat(keys, ",") .. "/" .. tostring(G_.queries - before < 200), "300:260,310:270/true")
    local x0, z0, x1, z1 = s:lineEnvelope(10, 10, 12, 10, 0.5, 4)
    T.eq("S9 the envelope: the segment widened by the inner AND outer radius together (the conservative superset), one pixel of margin", table.concat({ x0, z0, x1, z1 }, ","), "266,266,290,286")
    T.eq("S10 an envelope above 16384 cells is not a finite supported envelope", tostring(select(2, s:lineEnvelope(-60, 0, 60, 0, 0, 40))), "ENVELOPE_TOO_LARGE")
    local other = NA.groundBindingOf({ mapKey = "MapUS", layerDescriptor = s.identity.layerDescriptor .. ";other" }, 300, 260)
    T.eq("S11 a ground binding of another layer resolves nothing: a changed layer cannot inherit this one's cells", tostring(({ host.nativeLease.spec.resolveCarrier(other) })[2]), "LAYER_CHANGED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE LINE BRACKET
-- ══════════════════════════════════════════════════════════════════════════
local function foreignLine(delta, heightType, x, z, apply, radius)
    return REAL.addDensityMapHeightAtWorldLine(ENGINE_HEIGHT_UPDATER, x, 0, z, x + 1, 0, z, delta, heightType.index, 0.5, radius or 1, false, 0, apply, 5)
end
--- Does every tracked cell's stock hold its pixel's native litres now?
local function storeMatchesNative(sg)
    for id, c in pairs(sg.operations.carriers) do
        if NA.isGroundKey(c.binding.carrierKey) then
            local d = c.binding.sourceDescriptor
            local s = c.stockId and sg.operations.stocks[c.stockId] or nil
            local native = G_.raw(d.x, d.z) * 2
            if (s and s.observedAmount or 0) ~= native then return false end
        end
    end
    return true
end
group("L", function()
    resetWorld()
    local m, sg, host, w, lease = boot(function(m, w) tipWorld(m, w, { at = { x = 20, z = 20 } }) end, "l_save", { index = 33 })
    local q = G_.queries
    local r1, r2 = foreignLine(6, HT.WHEAT, 40, 40, false)
    T.eq("L1 a dry run (applyChanges false) is no operation: the native answer passes through and nothing is sampled", num(r1) .. "/" .. num(r2) .. "/" .. tostring(G_.queries == q) .. "/" .. (groundOf(sg)), "6/1/true/0")
    local a1, a2 = foreignLine(6, HT.WHEAT, 40, 40, true)
    T.eq("L2 a foreign line on untracked ground outside any frame: native wrote its 6 raw units, both returns are the native's, and nothing is bound (no UNKNOWN record per pixel)",
        num(a1) .. "/" .. num(a2) .. "/" .. G_.totalRaw() .. "/" .. (groundOf(sg)), "6/1/6/0")
    -- Tracked cells with a known history: the unit is marked o = 3 and tips onto the ground.
    publish(m, sg, lease, unitId(w.tipper), 3)
    ENGINE_TIP(w.tipper, 100)
    local before = {}
    for _, st in ipairs(groundStocks(sg)) do before[st.carrierId] = { amount = st.observedAmount, known = st.properties[PROP] and st.properties[PROP].knownAmount } end
    local trackedBefore = groundOf(sg)
    foreignLine(40, HT.WHEAT, 19, 20, true, 4)
    local gained, allPartial = 0, true
    for id, b in pairs(before) do
        local st = stockAt(sg, id)
        if st ~= nil and st.observedAmount > b.amount then
            gained = gained + 1
            local p = st.properties[PROP]
            if st.knowledge ~= "PARTIAL" or p == nil or p.knownAmount ~= b.known or p.basisAmount ~= st.observedAmount then allPartial = false end
        end
    end
    T.eq("L3 a gain on tracked KNOWN cells from an unknown writer enters with unknown coverage: each such cell's basis grows to its litres, its known amount does not, KNOWN becomes PARTIAL (Bob R3)",
        tostring(gained > 0) .. "/" .. tostring(allPartial) .. "/" .. tostring(storeMatchesNative(sg)), "true/true/true")
    T.eq("L3b the untracked pixels that writer filled stay untracked", tostring((groundOf(sg)) == trackedBefore), "true")
    foreignLine(-1000, HT.WHEAT, 19, 20, true, 6)
    T.eq("L4 a foreign pickup that empties the tracked cells: their stocks retire and their carriers are withdrawn (the store holds occupied cells only); the untracked pile elsewhere is untouched",
        trackedBefore .. " > " .. (groundOf(sg)) .. "/" .. G_.totalRaw(), trackedBefore .. " > 0/6")
    ENGINE_TIP(w.tipper, 100)
    G_.lineError = "native line failed"
    local ok, err = pcall(foreignLine, 20, HT.WHEAT, 19, 20, true, 4)
    G_.lineError = nil
    T.eq("L5 a native throw is re-raised unchanged after the observation, and the tracked cells it wrote before throwing are reconciled to their native litres",
        tostring(ok) .. "/" .. tostring(err) .. "/" .. tostring(storeMatchesNative(sg)), "false/native line failed/true")
    local later = function(...) return REAL.__sgLaterOriginal(...) end
    REAL.__sgLaterOriginal = rawget(REAL, "addDensityMapHeightAtWorldLine")
    rawset(REAL, "addDensityMapHeightAtWorldLine", later)
    T.eq("L6 a later wrapper above ours is never erased: removal leaves the chain and reports it", tostring(GO.remove()) .. "/" .. tostring(rawget(REAL, "addDensityMapHeightAtWorldLine") == later), "false/true")
    rawset(REAL, "addDensityMapHeightAtWorldLine", REAL.__sgLaterOriginal)
    REAL.__sgLaterOriginal = nil
    FSBaseMission.delete(m)
    T.eq("L7 teardown removes ours while it is the current value: the engine global is the C function again", tostring(GO.bracket) .. "/" .. tostring(rawget(REAL, "addDensityMapHeightAtWorldLine") == addDensityMapHeightAtWorldLine), "nil/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. THE TIP'S ADMISSION AND ITS QUANTIZATION
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    resetWorld()
    local m, sg, host, w = boot(function(m, w)
        tipWorld(m, w)
        w.converting = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:converting", { level = 600, fillType = WHEAT, at = { x = -30, z = -30 },
            converter = { [WHEAT] = { targetFillTypeIndex = WHEAT, conversionFactor = 2 } } }))
        w.retype = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:retype", { level = 600, fillType = WHEAT, at = { x = -30, z = 30 },
            converter = { [WHEAT] = { targetFillTypeIndex = BARLEY, conversionFactor = 1 } } }))
        w.wide = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:wide", { level = 600, fillType = WHEAT, at = { x = 50, z = -50 }, length = 40 }))
    end, "t_save", { index = 34 })
    local frames = host.nextDischarge
    ENGINE_TIP(w.converting, 50)
    T.eq("T1 a node converter at factor 2 opens no frame: the line is observed unframed and binds nothing on untracked ground", tostring(host.nextDischarge == frames) .. "/" .. (groundOf(sg)) .. "/" .. G_.totalRaw(HT.WHEAT.index), "true/0/50")
    ENGINE_TIP(w.retype, 50)
    T.eq("T2 a converter that changes the type at factor 1 opens no frame either", tostring(host.nextDischarge == frames), "true")
    -- A converting area inside the util retargets wheat to barley before the line.
    local area = { start = { x = 8, z = 8 }, width = { x = 14, z = 8 }, height = { x = 8, z = 14 } }
    g_densityMapHeightManager.convertingFillTypesAreas[area] = { fillTypes = { [WHEAT] = true }, fillTypeTarget = BARLEY }
    local barleyBefore = G_.totalRaw(HT.BARLEY.index)
    ENGINE_TIP(w.tipper, 50)
    local gf = host.lastGroundFrame
    T.eq("T3 a converting area retargets the type inside the util: the frame refuses that line as CONVERTED_AT_GROUND and the cells are reconciled, not transferred",
        tostring(gf.refused.CONVERTED_AT_GROUND) .. "/" .. #gf.operations .. "/" .. num(G_.totalRaw(HT.BARLEY.index) - barleyBefore), "1/0/25")
    g_densityMapHeightManager.convertingFillTypesAreas = {}
    local unitBefore = level(w.wide)
    ENGINE_TIP(w.wide, 50)
    gf = host.lastGroundFrame
    host:flush()
    local wideStock = stockAt(sg, unitId(w.wide))
    T.eq("T4 an envelope above the cap is not admitted: native ran, the frame records ENVELOPE_TOO_LARGE, and the unit's report replays to the per-side path (its stock follows the native 550 L)",
        num(unitBefore - level(w.wide)) .. "/" .. tostring(gf.refused["ENVELOPE:ENVELOPE_TOO_LARGE"]) .. "/" .. #gf.operations .. "/" .. num(wideStock and wideStock.observedAmount), "50/1/0/550")
    -- A cell that loses material during a tip abandons the operation (the fault domain).
    resetWorld()
    FSBaseMission.delete(m)
    m, sg, host, w = boot(tipWorld, "t_save2", { index = 35 })
    G_.put(279, 280, HT.WHEAT.index, 3)
    ENGINE_TIP(w.tipper, 20)
    local victim = cid(NA.groundBinding(host:groundSampler(), 279, 280))
    G_.onWrite = function() G_.heights[G_.key(279, 280)] = 1 end
    ENGINE_TIP(w.tipper, 20)
    G_.onWrite = nil
    T.eq("T5 a cell that loses material during a tip: ABANDONED GROUND_DECREASE; the cell's stock is qualified and its actual 2 L stand",
        tostring(host.lastSettlement.outcome) .. "/" .. tostring(host.lastSettlement.reason) .. "/" .. tostring(stockAt(sg, victim) and stockAt(sg, victim).knowledge) .. "/" .. num(stockAt(sg, victim) and stockAt(sg, victim).observedAmount),
        "ABANDONED/GROUND_DECREASE/UNAVAILABLE/2")
    G_.onWrite = function()
        for k, t in pairs(G_.types) do if t == HT.WHEAT.index and G_.heights[k] ~= nil and k ~= G_.key(279, 280) then G_.types[k] = HT.BARLEY.index break end end
    end
    ENGINE_TIP(w.tipper, 20)
    G_.onWrite = nil
    T.eq("T5b a cell that holds another material after a tip: ABANDONED GROUND_MATERIAL", tostring(host.lastSettlement.outcome) .. "/" .. tostring(host.lastSettlement.reason), "ABANDONED/GROUND_MATERIAL")
    -- Quantization (Bob R6): float noise either way settles clean; a whole unit does not.
    ENGINE_TIP(w.tipper, 100.0004 - w.tipper.spec_dischargeable.dischargeNodes[1].litersToDrop)
    T.eq("T6 source-side noise under the tolerance (the util debits the request when the shortfall is under 0.001 L): a clean TRANSFER, no loss leg",
        head(host) .. " " .. legs(host), "GROUND_TIP/COMMITTED " .. (host.lastSettlement.report and #host.lastSettlement.report.allocations or 0) .. " moved, loss 0")
    G_.roundUp = true
    ENGINE_TIP(w.tipper, 99.9995 - w.tipper.spec_dischargeable.dischargeNodes[1].litersToDrop)
    G_.roundUp = false
    local partial = 0
    for _, s in ipairs(groundStocks(sg)) do if s.reason == "UNEXPLAINED_DELTA" then partial = partial + 1 end end
    T.eq("T7 destination-side noise (the engine wrote 0.0005 L more than it was asked): a clean TRANSFER, nothing unexplained", head(host) .. "/" .. num(host.lastSettlement.report.outcomeEvidence.unexplainedGain) .. "/" .. partial, "GROUND_TIP/COMMITTED/0/0")
    G_.extraRaw = 1
    ENGINE_TIP(w.tipper, 40 - w.tipper.spec_dischargeable.dischargeNodes[1].litersToDrop)
    G_.extraRaw = 0
    partial = 0
    for _, s in ipairs(groundStocks(sg)) do if s.reason == "UNEXPLAINED_DELTA" then partial = partial + 1 end end
    T.eq("T8 a whole raw unit more on the ground than the unit paid for is beyond the tolerance: the receiving cell is qualified UNEXPLAINED_DELTA",
        num(host.lastSettlement.report.outcomeEvidence.unexplainedGain) .. "/" .. tostring(partial >= 1), "2/true")
    G_.shortRaw = 1
    ENGINE_TIP(w.tipper, 40 - w.tipper.spec_dischargeable.dischargeNodes[1].litersToDrop)
    G_.shortRaw = 0
    T.eq("T9 the unit paid a whole unit more than the ground received: that part is a LOSS leg, retired as the native's loss", head(host) .. " " .. legs(host):match("loss .*"), "GROUND_TIP/COMMITTED loss 2")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE WORK AND DROP FRAMES
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    resetWorld()
    local m, sg, host, w, lease = boot(function(m, w)
        tipWorld(m, w, { at = { x = 0, z = 0 } })
        w.shovel = vehicleIn(m, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 0, z = 0 }, rate = 0.1 }))
        w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = 0, z = 0 } }))
    end, "w_save", { index = 36 })
    publish(m, sg, lease, unitId(w.tipper), 5)
    ENGINE_TIP(w.tipper, 100)
    local _, pile = groundOf(sg)
    ENGINE_RAISE(w.shovel, "onUpdateTick", 400)
    local gf = host.lastGroundFrame
    local shovelStock = stockAt(sg, unitId(w.shovel))
    local _, pileAfter = groundOf(sg)
    T.eq("W1 the Shovel's pickup is ONE TRANSFER inside its onUpdateTick frame: the cells that lost to the unit that gained, " .. num(level(w.shovel)) .. " L",
        tostring(gf.kind) .. "/" .. #gf.operations .. "/" .. tostring(gf.operations[1].outcome) .. "/" .. num(pile - pileAfter) .. "/" .. num(level(w.shovel)), "WORK/1/COMMITTED/" .. num(level(w.shovel)) .. "/" .. num(level(w.shovel)))
    T.eq("W2 the bucket's goods carry the heap's history: o = 5, KNOWN, from the actual removed portions (not UNKNOWN)", propOf(shovelStock):sub(1, 7), "KNOWN:5")
    -- The Leveler: a drop then its callback.
    local lv = w.leveler
    lv.spec_fillUnit.fillUnits[1].fillLevel, lv.spec_fillUnit.fillUnits[1].fillType = 0, 0
    lv.spec_leveler.nodes[1].pickupActive = true
    ENGINE_RAISE(lv, "onUpdate", 16)
    gf = host.lastGroundFrame
    local lvStock = stockAt(sg, unitId(lv))
    T.eq("W3 the Leveler's pickup is a TRANSFER in its onUpdate frame and its unit carries the heap's history", tostring(gf.kind) .. "/" .. tostring(gf.operations[1] and gf.operations[1].outcome) .. "/" .. propOf(lvStock):sub(1, 7), "WORK/COMMITTED/KNOWN:5")
    lv.spec_leveler.nodes[1].pickupActive = false
    lv.spec_leveler.nodes[1].dropActive = true
    lv.spec_leveler.nodes[1].node.x = 20
    local lvLevel = level(lv)
    ENGINE_RAISE(lv, "onUpdate", 16)
    gf = host.lastGroundFrame
    T.eq("W4 the Leveler's drop is a TRANSFER unit to cells, settled when its debit landed", tostring(gf.operations[1] and gf.operations[1].outcome) .. "/" .. tostring(gf.operations[1] and gf.operations[1].evidence.direction) .. "/" .. num(lvLevel - level(lv)),
        "COMMITTED/DROP/" .. num(lvLevel - level(lv)))
    -- The tiny drop: the Leveler debits the whole bucket when the rest is under one raw unit.
    lv.spec_fillUnit.fillUnits[1].fillLevel = 3
    lv.spec_fillUnit.fillUnits[1].fillType = WHEAT
    host.handle.refreshCarrier(host.nativeLease, NA.fillUnitBinding(lv, 1), "BENCH")
    ENGINE_RAISE(lv, "onUpdate", 16)
    gf = host.lastGroundFrame
    local ev = gf.operations[1] and gf.operations[1].evidence or {}
    T.eq("W5 the Leveler's tiny drop (:231-234): 3 L left the bucket, 2 L reached the ground; the 1 L is a LOSS leg, not stock",
        num(ev.sourceTotal) .. "/" .. num(ev.destinationTotal) .. "/" .. num(ev.loss) .. "/" .. num(lv.spec_leveler.litersToPickup), "3/2/1/1")
    -- The async drop: the callback runs later, by name on the node, in a DROP frame.
    lv.spec_fillUnit.fillUnits[1].fillLevel = 20
    lv.spec_fillUnit.fillUnits[1].fillType = WHEAT
    host.handle.refreshCarrier(host.nativeLease, NA.fillUnitBinding(lv, 1), "BENCH")
    lv.spec_leveler.nodes[1].dropActive = false
    lv.spec_leveler.nodes[1].castActive = true
    lv.spec_leveler.nodes[1].node.x = -20
    ENGINE_RAISE(lv, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(1)
    T.eq("W6a a cast blocked by an object on its way makes no transfer (:268)", tostring(host.lastGroundFrame.kind) .. "/" .. #host.lastGroundFrame.operations .. "/" .. num(level(lv)), "DROP/0/20")
    ENGINE_RAISE(lv, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(0)
    gf = host.lastGroundFrame
    T.eq("W6 the raycast callback's drop, delivered later by name on the node: a DROP frame over the node's current unit, one TRANSFER",
        tostring(gf.kind) .. "/" .. #gf.operations .. "/" .. tostring(gf.operations[1] and gf.operations[1].outcome) .. "/" .. num(level(lv)), "DROP/1/COMMITTED/0")
    -- Drift on a tracked pile before a pickup is the store's, not the pickup's (:231).
    ENGINE_TIP(w.tipper, 100)
    -- the occupied wheat cell nearest the shovel's line (x -1..1, z 0): the first it takes from
    local driftCell, best = nil, math.huge
    for k, raw in pairs(G_.heights) do
        if raw >= 2 and G_.types[k] == HT.WHEAT.index then
            local cx, cz = k:match("(%d+):(%d+)")
            local wx, wz = G_.centre(tonumber(cx), tonumber(cz))
            local d = math.abs(wz) + math.max(0, math.abs(wx) - 1)
            if d < best or (d == best and k < driftCell) then driftCell, best = k, d end
        end
    end
    local _, pileBefore = groundOf(sg)
    G_.heights[driftCell] = G_.heights[driftCell] - 1
    local shovelBefore = level(w.shovel)
    ENGINE_RAISE(w.shovel, "onUpdateTick", 100)
    gf = host.lastGroundFrame
    ev = gf.operations[1] and gf.operations[1].evidence or {}
    T.eq("W7 a tracked cell an unobserved writer lowered is read again before the next pickup: the TRANSFER moves only what the pickup took",
        tostring(gf.operations[1] and gf.operations[1].outcome) .. "/" .. num(ev.sourceTotal) .. "/" .. num(level(w.shovel) - shovelBefore), "COMMITTED/" .. num(level(w.shovel) - shovelBefore) .. "/" .. num(level(w.shovel) - shovelBefore))
    FSBaseMission.delete(m)
    -- A two-node shovel: node 1 picks up, node 2 (inactive) resets its own unit in the same tick.
    resetWorld()
    m, sg, host, w, lease = boot(function(m, w)
        tipWorld(m, w, { at = { x = 0, z = 0 } })
        w.twin = vehicleIn(m, ENGINE_NEW_SHOVEL("vehicle:twin", { at = { x = 0, z = 0 }, rate = 0.1, secondUnitLevel = 50 }))
    end, "w_save2", { index = 39 })
    ENGINE_TIP(w.tipper, 100)
    ENGINE_RAISE(w.twin, "onUpdateTick", 400)
    gf = host.lastGroundFrame
    host:flush()
    local second = stockAt(sg, unitId(w.twin, 2))
    T.eq("W8 two nodes in one tick: the pickup settles on its own unit's report (COMMITTED), and the other node's reset replays to the per-side path (its stock retires)",
        tostring(gf.operations[1] and gf.operations[1].outcome) .. "/" .. #gf.operations .. "/" .. num(w.twin:getFillUnitFillLevel(2)) .. "/" .. tostring(second), "COMMITTED/1/0/nil")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE DEFERRALS
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    resetWorld()
    local m, sg, host, w = boot(function(m, w)
        tipWorld(m, w)
        w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = -40, z = 0 }, level = 20, fillType = WHEAT, cast = true }))
    end, "d_save", { index = 37 })
    M.openDeferral()
    local r = { ENGINE_TIP(w.tipper, 100) }
    local dump = G_.dump()
    T.eq("D1 inside the boundary a tip line writes nothing and answers 0: the unit is not debited and the ground is untouched", num(r[1]) .. "/" .. level(w.tipper) .. "/" .. dump .. "/" .. GO.stats.deferred, "0/600//" .. GO.stats.deferred)
    ENGINE_RAISE(w.leveler, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(0)
    T.eq("D2 the Leveler callback arriving inside the boundary is held on the node's field, not run", tostring(#M.deferral.queue) .. "/" .. level(w.leveler), "1/20")
    M.closeDeferral()
    T.eq("D3 at the close the held callback runs once, inside a DROP frame, and the refused tip is NOT replayed (no ground the unit did not pay for)",
        tostring(host.lastGroundFrame and host.lastGroundFrame.kind) .. "/" .. level(w.leveler) .. "/" .. level(w.tipper) .. "/" .. num(G_.totalRaw()), "DROP/0/600/10")
    local wLU, oLU = Leveler.onUpdate, SGClassHook.record(Leveler, "onUpdate", GO.HOOK_ID).original
    T.eq("D4 a second install wraps nothing new on the same class table", tostring(GO.installClassHooks({ Leveler = Leveler, Shovel = Shovel })), "false")
    local recAfter = SGClassHook.record(Leveler, "onUpdate", GO.HOOK_ID)
    T.eq("D4b it REBINDS the record (MAINTENANCE row 187): the live method is the same one wrapper, over the same engine method, no second layer",
        tostring(Leveler.onUpdate == wLU and recAfter.wrapper == wLU and recAfter.original == oLU and oLU ~= wLU), "true")
    local foreign = ENGINE_NEW_LEVELER("vehicle:foreign", {})
    local mine = function() end
    foreign.spec_leveler.nodes[1].onLevelerRaycastCallback = mine
    T.eq("D5 a node whose callback another mod replaced is left alone", GO.installLeveler(foreign) .. "/" .. tostring(foreign.spec_leveler.nodes[1].onLevelerRaycastCallback == mine), "0/true")
    local late = ENGINE_NEW_LEVELER("vehicle:late", {})
    T.eq("D6 a leveler built after the class wrap holds the class wrapper in its node and takes no node wrap of its own: the native read is the record's original, not the live class slot",
        GO.installLeveler(late) .. "/" .. tostring(late.spec_leveler.nodes[1].onLevelerRaycastCallback == Leveler.onLevelerRaycastCallback), "0/true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RECORDS
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    resetWorld()
    local m, sg, host, w, lease = boot(function(m, w)
        tipWorld(m, w, { at = { x = 0, z = 0 } })
        w.shovel = vehicleIn(m, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 0, z = 0 }, rate = 10, capacity = 5000 }))
    end, "r_save", { index = 38 })
    ENGINE_TIP(w.tipper, 100)
    local core = sg.operations:serializeCore(sg.save:sectionOwnedCarriers())
    local pending = sg.operations:serializePending(sg.save:sectionOwnedCarriers())
    local groundPending = 0
    for _, r in ipairs(pending.rows) do if r.carrierKey and NA.isGroundKey(r.carrierKey) then groundPending = groundPending + 1 end end
    local groundCore = 0
    for _, c in ipairs(core.carriers) do if NA.isGroundKey(c.binding.carrierKey) then groundCore = groundCore + 1 end end
    T.eq("R1 the ordinary envelope leaves the ground out: no ground carrier in coreValues, no ground row in the pending collection", groundCore .. "/" .. groundPending .. "/" .. tostring(#core.carriers >= 1), "0/0/true")
    local cells, props = sg.ground:groundRecords()
    local nc, np = 0, 0
    for _ in pairs(cells) do nc = nc + 1 end
    for _ in pairs(props) do np = np + 1 end
    T.eq("R2 the payload's cells share one property entry when their property records and causes are the same", nc .. " cells/" .. np .. " shared", (groundOf(sg)) .. " cells/1 shared")
    -- Tip, pick up everything, tip again: the record count returns to the occupied cells.
    for _ = 1, 20 do ENGINE_RAISE(w.shovel, "onUpdateTick", 1000) end
    local afterPickup = groundOf(sg)
    ENGINE_TIP(w.tipper, 100)
    nativeSave(m, "r_final")
    local tree = payloadTree("r_final")
    local runs = 0
    for _, r in ipairs(tree.runs) do runs = runs + r.n end
    T.eq("R3 tip, pick up all, tip again: the emptied cells retired and withdrew; the payload holds the occupied cells and no history (R5 bound)",
        afterPickup .. "/" .. runs .. "/" .. #tree.historical .. "/" .. tostring(runs == (groundOf(sg))), "0/" .. (groundOf(sg)) .. "/0/true")
    -- Drift: an unobserved writer (the smoother, 2-4b2's) moves material; the freeze reads it again.
    local lv = ENGINE_NEW_LEVELER("vehicle:smoother", { at = { x = 0, z = 0 }, smooth = true })
    for _ = 1, 3 do DensityMapHeightUtil.smoothAroundLine(lv.spec_leveler.nodes[1].node, 2, 0.5, 1.5, 1, true) end
    nativeSave(m, "r_final2")
    local build = function(m2, w2)
        tipWorld(m2, w2, { at = { x = 0, z = 0 }, level = level(w.tipper) })
        w2.shovel = vehicleIn(m2, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 0, z = 0 }, rate = 10, capacity = 5000, level = level(w.shovel), fillType = WHEAT }))
    end
    local m2, sg2 = reload(m, "r_final2", build, { index = 38 })
    local lr = sg2.ground.lastRestore or {}
    T.eq("R4 drift left by an unobserved writer was read again at the boundary: every saved cell reattaches, none becomes history",
        tostring(G_.smoothCalls > 0) .. "/" .. tostring(lr.restored) .. "/" .. tostring(lr.unknown) .. "/" .. tostring(lr.historical), "true/" .. (groundOf(sg2)) .. "/0/0")
    -- A pixel changed between the save and the load: the core's rule keeps its facts as history.
    FSBaseMission.delete(m2)
    local some = nil
    for k in pairs(G_.heights) do some = k break end
    G_.heights[some] = G_.heights[some] + 1
    -- The trailer's unit changed too, so the core keeps one unresolved history of its own.
    local build3 = function(m3, w3)
        tipWorld(m3, w3, { at = { x = 0, z = 0 }, level = level(w.tipper) + 2 })
        w3.shovel = vehicleIn(m3, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 0, z = 0 }, rate = 10, capacity = 5000, level = level(w.shovel), fillType = WHEAT }))
    end
    SGOperations.RETIRED_LIMIT = 1
    local okBoot, m3, sg3 = pcall(boot, build3, "r_final2", { index = 38 })
    SGOperations.RETIRED_LIMIT = 256
    if not okBoot then error(m3, 0) end
    local groundHist, coreHist = 0, 0
    for _, s in pairs(sg3.operations.retiredStocks) do
        if s.historical then if NA.isGroundKey(s.carrierKey) then groundHist = groundHist + 1 else coreHist = coreHist + 1 end end
    end
    T.eq("R7 ground history keeps a budget of its own: with every budget at 1, the ground's mismatched cell and the trailer's mismatched unit both keep their history (SG-2 :259)",
        groundHist .. "/" .. coreHist, "1/1")
    local lr3 = sg3.ground.lastRestore or {}
    T.eq("R5 a pixel that changed after the save: that cell starts UNKNOWN and its saved facts stay historical; the others reattach",
        tostring(lr3.unknown) .. "/" .. tostring(lr3.historical == 0 and lr3.unknown == 1) .. "/" .. tostring(lr3.restored), "1/true/" .. tostring((groundOf(sg3)) - 1))
    T.eq("R7b the ground's history still travels on with ground's own budget in place", tostring(groundHist), "1")
    nativeSave(m3, "r_final3")
    T.eq("R6 the mismatched cell's saved facts travel on in the next payload as history (bounded by the core's retired-stock rule)", tostring(#payloadTree("r_final3").historical), "1")
    FSBaseMission.delete(m3)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE FAULT LATCH (:164, :257, :261)
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    resetWorld()
    local m, sg, host, w = boot(tipWorld, "k_save", { index = 40 })
    ENGINE_TIP(w.tipper, 100)
    local tracked = {}
    for _, st in ipairs(groundStocks(sg)) do tracked[#tracked + 1] = st.carrierId end
    G_.expand = 1
    ENGINE_TIP(w.tipper, 20)
    G_.expand = 0
    local gf = host.lastGroundFrame
    local sampler = host:groundSampler()
    local qualified = 0
    for _, id in ipairs(tracked) do local st = stockAt(sg, id) if st ~= nil and st.knowledge == "UNAVAILABLE" then qualified = qualified + 1 end end
    T.eq("K1 a failed cardinality proof latches the binding: that primitive is refused, and every tracked cell in its envelope is marked uncertain",
        tostring(sampler.fault and sampler.fault.reason) .. "/" .. tostring(gf.refused["BEFORE:CARDINALITY"]) .. "/" .. #gf.operations .. "/" .. tostring(qualified == #tracked and qualified > 0), "CARDINALITY/1/0/true")
    local unitBefore = level(w.tipper)
    ENGINE_TIP(w.tipper, 20)
    gf = host.lastGroundFrame
    T.eq("K2 the latch holds with the proof passing again: the next tip is refused as BINDING_FAULT, native still ran and the unit was debited",
        tostring(gf.refused.BINDING_FAULT) .. "/" .. #gf.operations .. "/" .. num(unitBefore - level(w.tipper)), "1/0/20")
    T.eq("K3 the ground's readiness reports the fault", tostring(sg.ground:getReadiness().reason), "BINDING_FAULT:CARDINALITY")
    local anyCell = sg.operations.carriers[tracked[1]]
    T.eq("K8 once latched, the adapter reads nothing through the faulted grid: refreshCarrier is refused with BINDING_FAULT",
        tostring(({ host.handle.refreshCarrier(host.nativeLease, anyCell.binding, "BENCH") })[2]), "UNREADABLE:BINDING_FAULT")
    nativeSave(m, "k_final")
    T.eq("K4 and claims no support at the save: the ground participant answers UNAVAILABLE, no READY image", tostring(sg.nativeSave.lastAttempt.results.sg2Ground.state) .. "/" .. tostring(sg.nativeSave.lastAttempt.results.sg2Ground.reason),
        "UNAVAILABLE/BINDING_FAULT:CARDINALITY")
    FSBaseMission.delete(m)
    -- An unknown type index refuses that primitive and does not latch.
    resetWorld()
    m, sg, host, w = boot(tipWorld, "k_save2", { index = 41 })
    local x, z = ENGINE_GROUND.cellOf(10, 10)
    G_.heights[G_.key(x, z + 2)], G_.types[G_.key(x, z + 2)] = 3, 9
    ENGINE_TIP(w.tipper, 20)
    gf = host.lastGroundFrame
    local s2 = host:groundSampler()
    T.eq("K5 an unknown type index refuses that primitive and does not latch the binding", tostring(gf.refused["BEFORE:UNKNOWN_TYPE_INDEX"]) .. "/" .. tostring(s2.fault), "1/nil")
    G_.heights[G_.key(x, z + 2)], G_.types[G_.key(x, z + 2)] = nil, nil
    ENGINE_TIP(w.tipper, 20)
    T.eq("K6 and the next tip is admitted again", head(host), "GROUND_TIP/COMMITTED")
    -- A failed proof met on the save boundary's own re-read (through the adapter) latches too.
    G_.expand = 1
    nativeSave(m, "k_final2")
    G_.expand = 0
    T.eq("K7 a proof failure met through the adapter's read at the save boundary latches the binding, and the freeze claims no support",
        tostring(s2.fault and s2.fault.reason) .. "/" .. tostring(sg.nativeSave.lastAttempt.results.sg2Ground.reason), "CARDINALITY/BINDING_FAULT:CARDINALITY")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. A SECOND MAP LOAD IN ONE SESSION (Bob's R-15 item 1)
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    resetWorld()
    -- The engine re-sources the specializations at every savegame start; StockGuard is not
    -- sourced again (mods.lua:976-977).
    ENGINE_RESOURCE_DISCHARGEABLE()
    ENGINE_LOAD_LEVELER()
    ENGINE_LOAD_SHOVEL()
    local m, sg, host, w = boot(function(m, w)
        tipWorld(m, w)
        w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = -40, z = 0 }, level = 20, fillType = WHEAT, cast = true }))
    end, "m_save", { index = 42 })
    T.eq("M1 on the second map load the tip frame installs on the new class's dischargeToGround (read from the live class at install)",
        tostring(rawget(w.tipper, GO.TIP_MARKER) ~= nil and w.tipper.dischargeToGround == rawget(w.tipper, GO.TIP_MARKER).wrapper) .. "/" .. tostring(GO.nativeDischargeToGround == Dischargeable.dischargeToGround), "true/true")
    ENGINE_TIP(w.tipper, 100)
    T.eq("M2 and the tip is one TRANSFER again", head(host), "GROUND_TIP/COMMITTED")
    local node = w.leveler.spec_leveler.nodes[1]
    T.eq("M3 the Leveler node's field, copied from the new class, is wrapped", tostring(rawget(node, GO.LEVELER_MARKER) ~= nil), "true")
    M.openDeferral()
    ENGINE_RAISE(w.leveler, "onUpdate", 16)
    ENGINE_DELIVER_RAYCASTS(0)
    local held = #M.deferral.queue
    M.closeDeferral()
    T.eq("M4 and it holds inside the save boundary, then replays in a DROP frame", held .. "/" .. tostring(host.lastGroundFrame and host.lastGroundFrame.kind) .. "/" .. num(level(w.leveler)), "1/DROP/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Y. TYPELESS HEIGHT (index 0): the weeder's removal leaves it, and it reads empty
-- ══════════════════════════════════════════════════════════════════════════
group("Y", function()
    resetWorld()
    local m, sg, host, w = boot(function(m, w)
        m.weedSystem = ENGINE_WEED
        tipWorld(m, w)
        w.wheat = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:wheatOnResidue", { level = 600, fillType = WHEAT, at = { x = -30, z = -30 } }))
        w.windrow = vehicleIn(m, ENGINE_NEW_TIPPER("vehicle:windrow", { level = 300, fillType = ENGINE_FT.GRASS_WINDROW,
            supported = { [ENGINE_FT.GRASS_WINDROW] = true }, at = { x = 30, z = 30 } }))
    end, "y_save", { index = 43 })
    local s = host:groundSampler()
    -- A windrow the map already holds, untracked, under the wheat tipper.
    local px, pz = G_.cellOf(-30, -30)
    local residue = {}
    for dx = 0, 2 do
        G_.put(px + dx, pz, HT.GRASS_WINDROW.index, 6)
        residue[#residue + 1] = { x = px + dx, z = pz }
    end
    local faultsBefore = GO.stats.faults.UNKNOWN_TYPE_INDEX
    local removed = FSDensityMapUtil.updateWeederArea(-32, -32, -28, -32, -32, -28, false)
    local left = {}
    for _, c in ipairs(residue) do left[#left + 1] = G_.typeAt(c.x, c.z) .. "/" .. G_.raw(c.x, c.z) end
    T.eq("Y1 [entry point] the weeder's real path (FSDensityMapUtil.updateWeederArea, :1637-1638) through removeFromGroundByArea (VERBATIM): the type is cleared before the height under the same filter, so the windrow's height stays under type 0",
        table.concat(left, ",") .. "/" .. num(removed), "0/6,0/6,0/6/0")
    local cell, whyCell = s:readCell(px, pz)
    local rect, whyRect = s:sampleRect(px - 2, pz - 2, px + 4, pz + 2)
    T.eq("Y2 the sampler reads typeless height as no material: the pixel's raw is kept, 0 litres, no fill type, no refusal; a sample of the area holds no cell and latches nothing",
        (cell ~= nil and (cell.raw .. "/" .. num(cell.liters) .. "/" .. tostring(cell.fillTypeName)) or ("refused:" .. tostring(whyCell)))
            .. "/" .. (rect ~= nil and tostring(next(rect)) or ("refused:" .. tostring(whyRect))) .. "/" .. tostring(s.fault),
        "6/0/nil/nil/nil")
    local ns = cell ~= nil and NA.groundState(s, cell) or nil
    T.eq("Y3 its native state is empty: amount 0 and no material (keyed on the fill type, not on the raw height)",
        ns ~= nil and (num(ns.amount) .. "/" .. tostring(ns.materialRef)) or "no state", "0/nil")
    ENGINE_TIP(w.wheat, 100)
    local gained = 0
    for _, c in ipairs(residue) do if G_.typeAt(c.x, c.z) == HT.WHEAT.index then gained = gained + 6 * 2 end end
    local ev = host.lastSettlement and host.lastSettlement.report and host.lastSettlement.report.outcomeEvidence or {}
    T.eq("Y4 a tip onto the residue is observed and settles: the residue the wheat now covers shows as unexplained gain (" .. num(gained) .. " L), nothing refused and no fault counted",
        head(host) .. "/" .. tostring(gained > 0) .. "/" .. num(ev.unexplainedGain) .. "/" .. tostring(next(host.lastGroundFrame.refused)) .. "/" .. tostring(GO.stats.faults.UNKNOWN_TYPE_INDEX == faultsBefore),
        "GROUND_TIP/COMMITTED/true/" .. num(gained) .. "/nil/true")
    -- A windrow StockGuard tracks, removed by the weeder, read again at the save.
    ENGINE_TIP(w.windrow, 100)
    local function windrows()
        local n = 0
        for _, st in ipairs(groundStocks(sg)) do if st.materialRef ~= nil and st.materialRef.fillTypeName == "GRASS_WINDROW" then n = n + 1 end end
        return n
    end
    local tracked = windrows()
    FSDensityMapUtil.updateWeederArea(27, 27, 33, 27, 27, 33, false)
    nativeSave(m, "y_final")
    T.eq("Y5 a tracked windrow (" .. tracked .. " cells) the weeder removed: the save's boundary read finds every cell empty and retires it, and the ground participant is READY",
        tostring(tracked > 0) .. "/" .. windrows() .. "/" .. tostring(sg.nativeSave.lastAttempt.results.sg2Ground.state), "true/0/READY")
    FSBaseMission.delete(m)
end)
