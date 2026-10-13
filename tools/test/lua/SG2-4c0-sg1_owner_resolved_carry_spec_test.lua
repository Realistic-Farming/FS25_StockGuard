-- SG2-4c0-sg1_owner_resolved_carry_spec_test.lua
--
-- 2-4c-0, the SG-1 core change (the SG-1 brief :232; SG-2 v2.3 :326-330 and :343's carrying
-- half), on Bob's shape ruling Drafts/BOB-RULING-SG2-4C0-SHAPE-2026-10-02.md:
--   * the native state keeps a validated footprint, and the owner's resolve context names it;
--   * residency is declared by applicability.residentStoreKinds against the carrier's storeKind;
--   * a capture resolves the resident participants inside ONE owner stamp pair and the settle's
--     portions carry the records to the material that leaves; a resident destination installs
--     nothing; a non-resident stock reads its stored, carried record.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv), on the SG2-4b world (its preamble is
-- taken from SG2-4b-ground_observer_spec_test.lua as it stands).
--
-- THE ENTRY-POINT BAR IS GROUP F: main.lua's load path, an owner registered late through the
-- mission handle's registerProperty, then the engine's discharge, a Shovel's onUpdateTick and a
-- Leveler's onUpdate. The owner is a recorder: it takes and counts every argument, answers
-- resident only for a GROUND_CELL footprint, and returns a scalar revision. The real owner
-- (Soil's soil.groundCondition, 2-4c-3) is checked against this SG-1 in 2-4c-3's throwaway run.
--
-- Groups:
--   F  the entry-point bar: a tip asks nothing; a ground read is live with the cell's footprint;
--      a pickup carries the owner's combine result inside one stamp pair; the bucket reads its
--      carried record without a call; no ground stock or saved property set holds a copy
--   U  one stamp pair per capture: a revision that moves mid-batch leaves every portion unavailable
--   O  a registration that declares no residency keeps the older reading
--   N  the native state's footprint is validated and kept
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

-- ── an OWNER_RESOLVED owner, as a recorder ───────────────────────────────────
-- It answers resident only for a GROUND_CELL footprint (NOT_RESIDENT otherwise), keeps its live
-- fact per cell centre, and counts every call and its arguments. combine is the owner's own
-- rule (weighted by amount over known inputs); it notes the contributions it saw.
local CPID, OLDPID = "sg24c0.cond", "sg24c0.old"
local OWN = {}
local function ownerReset(opts)
    opts = opts or {}
    OWN = { resolves = {}, stamps = 0, stampArgs = {}, rev = 1, moveAfter = opts.moveAfter, combines = 0, seen = {}, oldResolves = 0 }
end
local function record(pid, ctx, c)
    return { propertyId = pid, schemaVersion = 1, producerId = "bench-owner", propertyRevision = 0, knowledge = "KNOWN",
             knownAmount = ctx.amount, basisAmount = ctx.amount, amountUnit = "LITRE", payload = { c = c } }
end
local function ownerSpec(pid, applicability)
    return {
        schemaVersion = 1, producerId = "bench-owner", residency = "OWNER_RESOLVED", applicability = applicability,
        validate = function() return true end,
        combine = function(ctx, contributions, before)
            OWN.combines = OWN.combines + 1
            local total, w, known = 0, 0, 0
            for _, c in ipairs(contributions) do
                local p = c.properties[pid]
                OWN.seen[#OWN.seen + 1] = p and (tostring(p.knowledge) .. ":" .. tostring(p.reason)) or "none"
                total = total + c.amount
                if p and p.knowledge ~= "UNAVAILABLE" and p.payload then w = w + p.payload.c * c.amount known = known + c.amount end
            end
            if before ~= nil then
                local p = before.properties[pid]
                total = total + before.observedAmount
                if p and p.knowledge ~= "UNAVAILABLE" and p.payload then w = w + p.payload.c * before.observedAmount known = known + before.observedAmount end
            end
            if known == 0 then return nil, "NO_KNOWN_INPUT" end
            local r = record(pid, { amount = known }, w / known)
            r.basisAmount = total
            r.knowledge = known >= total - 1e-6 and "KNOWN" or "PARTIAL"
            return r
        end,
        transform = function() return nil end, disclosure = function(_, r) return r end,
        resolveResident = function(...)
            local ctx = ...
            if pid == OLDPID then OWN.oldResolves = OWN.oldResolves + 1 end
            OWN.resolves[#OWN.resolves + 1] = { pid = pid, n = select("#", ...), ctx = ctx }
            if OWN.moveAfter ~= nil and #OWN.resolves == OWN.moveAfter then OWN.rev = OWN.rev + 1 end
            local fp = ctx.footprint
            if type(fp) ~= "table" or fp.kind ~= "GROUND_CELL" then return nil, "NOT_RESIDENT" end
            return record(pid, ctx, 7)
        end,
        getResidentRevision = function(...)
            OWN.stamps = OWN.stamps + 1
            OWN.stampArgs[#OWN.stampArgs + 1] = select("#", ...)
            return "rev:" .. OWN.rev
        end,
    }
end
local function resolvesOf(pid, purpose)
    local n = 0
    for _, r in ipairs(OWN.resolves) do if r.pid == pid and (purpose == nil or r.ctx.purpose == purpose) then n = n + 1 end end
    return n
end
--- A world with a tipper, a shovel and a leveler at (0, 0), the owner and a reader registered late.
local function ownerWorld(index, applicability)
    resetWorld()
    ownerReset()
    local m, sg, host, w, lease = boot(function(m, w)
        tipWorld(m, w, { at = { x = 0, z = 0 } })
        w.shovel = vehicleIn(m, ENGINE_NEW_SHOVEL("vehicle:shovel", { at = { x = 0, z = 0 }, rate = 0.1 }))
        w.leveler = vehicleIn(m, ENGINE_NEW_LEVELER("vehicle:leveler", { at = { x = 0, z = 0 } }))
    end, "c0_save", { index = index })
    local ownerLease = m.stockGuard.registerProperty(CPID, ownerSpec(CPID, applicability == nil and { residentStoreKinds = { "ground" } } or applicability))
    local oldLease = m.stockGuard.registerProperty(OLDPID, ownerSpec(OLDPID, nil))
    local reader = m.stockGuard.registerConsumer("sg24c0.reader", { version = 1, requiredSchemas = { [CPID] = 1, [OLDPID] = 1 }, materialKinds = { "FILL_TYPE" },
        resolveReadContext = function(q) return { purpose = "BENCH_READ", stockRefs = q.refs } end })
    return m, sg, host, w, { owner = ownerLease, old = oldLease, reader = reader, lease = lease }
end
local function readProps(m, sg, reader, stock)
    local r = m.stockGuard.readMaterial(reader, { refs = { sg.operations:stockRef(stock) } })
    return r.records[1].properties
end
local function prop(p) if p == nil then return "nil" end return tostring(p.knowledge) .. ":" .. (p.payload and num(p.payload.c) or tostring(p.reason)) end

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE ENTRY-POINT BAR: A TIP, A LIVE GROUND READ, A PICKUP THAT CARRIES, A DROP THAT DOES NOT STORE
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m, sg, host, w, L = ownerWorld(51)
    local reg = sg.registry:property(CPID)
    T.eq("F0 [reached] the owner registered late through the mission handle, its applicability kept as given", tostring(L.owner ~= nil) .. "/" .. tostring(reg and reg.spec.applicability.residentStoreKinds[1]), "true/ground")
    ENGINE_TIP(w.tipper, 100)
    T.eq("F1 NAMED: a tip (the fill unit is not resident, the empty cells have no stock) asks the owner nothing at capture", resolvesOf(CPID) .. "/" .. OWN.stamps, "0/0")
    local cells = groundStocks(sg)
    local cell = cells[1]
    local carrier = sg.operations.carriers[cell.carrierId]
    local d = carrier.binding.sourceDescriptor
    local sampler = sg.ground.groundSampler
    local cx, cz = sampler:cellCentre(d.x, d.z)
    local p = readProps(m, sg, L.reader, cell)[CPID]
    local r = OWN.resolves[#OWN.resolves]
    local fp = r and r.ctx.footprint or {}
    T.eq("F2 NAMED: a ground stock reads live, and the owner's context names the cell's footprint: kind, world centre, pixel size (the SG-1 brief :232)",
        prop(p) .. " " .. tostring(fp.kind) .. "/" .. num(fp.x) .. "," .. num(fp.z) .. "/" .. num(fp.size) .. "/" .. tostring(r and r.ctx.purpose) .. "/" .. num(r and r.ctx.amount) .. "/" .. tostring(r and r.n),
        "KNOWN:7 GROUND_CELL/" .. num(cx) .. "," .. num(cz) .. "/" .. num(sampler.pitch) .. "/BENCH_READ/" .. num(cell.observedAmount) .. "/1")
    -- The shovel's pickup: the capture resolves the resident sources inside one stamp pair.
    ownerReset()
    local before = level(w.shovel)
    ENGINE_RAISE(w.shovel, "onUpdateTick", 400)
    local bucket = stockAt(sg, unitId(w.shovel))
    local carried = bucket and bucket.properties[CPID] or nil
    T.eq("F3 NAMED: the pickup's capture resolved its resident cells (purpose CAPTURE) inside ONE owner stamp pair, and the bucket's stock carries the owner's combine result: KNOWN, 7, over what the bucket took",
        tostring(resolvesOf(CPID, "CAPTURE") > 0) .. "/" .. resolvesOf(CPID, "CAPTURE") .. "=" .. #OWN.resolves .. "/" .. OWN.stamps .. "/" .. prop(carried) .. "/" .. num(carried and carried.knownAmount) .. "/" .. num(level(w.shovel) - before),
        "true/" .. #OWN.resolves .. "=" .. #OWN.resolves .. "/2/KNOWN:7/" .. num(level(w.shovel) - before) .. "/" .. num(level(w.shovel) - before))
    local r0 = resolvesOf(CPID)
    local pb = readProps(m, sg, L.reader, bucket)[CPID]
    T.eq("F4 NAMED: the bucket is not resident: reading it makes no call to the owner that declares residency and returns the carried record (SG-2 :330)", (resolvesOf(CPID) - r0) .. "/" .. prop(pb), "0/KNOWN:7")
    local onGround = 0
    for _, s in ipairs(groundStocks(sg)) do if s.properties[CPID] ~= nil then onGround = onGround + 1 end end
    T.eq("F5 NAMED: no ground stock holds a stored copy of the owner's fact", onGround, 0)
    -- A pickup of one raw unit (2 L) from an 8 L cell: the cell keeps a 6 L remainder.
    ENGINE_RAISE(w.shovel, "onUpdateTick", 20)
    local remainder, copies = nil, 0
    for _, s in ipairs(groundStocks(sg)) do
        if math.abs(s.observedAmount - 6) < 1e-6 then remainder = s end
        if s.properties[CPID] ~= nil then copies = copies + 1 end
    end
    T.eq("F5b NAMED: a pickup that leaves a remainder: the cell keeps its stock (6 L), and neither it nor any ground stock holds a stored copy; the bucket still carries KNOWN 7",
        tostring(remainder ~= nil) .. "/" .. copies .. "/" .. prop(bucket.properties[CPID]), "true/0/KNOWN:7")
    -- The Leveler: a pickup onto its unit, then the drop back onto the ground.
    local lv = w.leveler
    lv.spec_fillUnit.fillUnits[1].fillLevel, lv.spec_fillUnit.fillUnits[1].fillType = 0, 0
    lv.spec_leveler.nodes[1].pickupActive = true
    ENGINE_RAISE(lv, "onUpdate", 16)
    local lvStock = stockAt(sg, unitId(lv))
    T.eq("F6 [reached] the Leveler's pickup carries the fact onto its unit", prop(lvStock and lvStock.properties[CPID]), "KNOWN:7")
    lv.spec_leveler.nodes[1].pickupActive = false
    lv.spec_leveler.nodes[1].dropActive = true
    lv.spec_leveler.nodes[1].node.x = 20
    local c0 = OWN.combines
    ENGINE_RAISE(lv, "onUpdate", 16)
    onGround = 0
    for _, s in ipairs(groundStocks(sg)) do if s.properties[CPID] ~= nil then onGround = onGround + 1 end end
    T.eq("F7 NAMED: the drop onto the ground (a resident destination) runs no combine for the owner's property and installs nothing on the cells (SG-2 :326)",
        (OWN.combines - c0) .. "/" .. onGround .. "/" .. tostring(host.lastGroundFrame.operations[1] and host.lastGroundFrame.operations[1].outcome), "0/0/COMMITTED")
    local _, props = sg.ground:groundRecords()
    local inSets = 0
    for _, shared in pairs(props) do if shared.properties[CPID] ~= nil then inSets = inSets + 1 end end
    T.eq("F8 NAMED: save weight: no property set the ground payload would save carries the owner's property", inSets, 0)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. ONE OWNER STAMP PAIR PER CAPTURE (SG-2 :328)
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local m, sg, host, w = ownerWorld(52)
    ENGINE_TIP(w.tipper, 100)
    ownerReset({ moveAfter = 1 })
    ENGINE_RAISE(w.shovel, "onUpdateTick", 400)
    local bucket = stockAt(sg, unitId(w.shovel))
    local allUnstable = #OWN.seen > 0
    for _, s in ipairs(OWN.seen) do if s ~= "UNAVAILABLE:RESIDENT_UNSTABLE" then allUnstable = false end end
    T.eq("U1 NAMED: the owner's revision moved during the capture's batch: two stamps for the whole capture, and every portion of the batch carries UNAVAILABLE / RESIDENT_UNSTABLE",
        tostring(#OWN.resolves > 1) .. "/" .. OWN.stamps .. "/" .. tostring(allUnstable), "true/2/true")
    T.eq("U2 so the bucket's record is not a confident value", tostring(bucket and bucket.properties[CPID] and bucket.properties[CPID].knowledge), "UNAVAILABLE")
    T.eq("U3 each stamp is called with its one context", table.concat(OWN.stampArgs, ","), "1,1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. A REGISTRATION THAT DECLARES NO RESIDENCY KEEPS THE OLDER READING
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    local m, sg, host, w, L = ownerWorld(53)
    ENGINE_TIP(w.tipper, 100)
    ownerReset()
    ENGINE_RAISE(w.shovel, "onUpdateTick", 400)
    T.eq("O1 a pickup's capture asks an owner that declares no residency nothing (no stamp, no resolve)", OWN.oldResolves .. "/" .. resolvesOf(OLDPID, "CAPTURE"), "0/0")
    local bucket = stockAt(sg, unitId(w.shovel))
    local p = readProps(m, sg, L.reader, bucket)
    T.eq("O2 NAMED: a read of a fill unit still asks it (every stock is resolved), and its NOT_RESIDENT answer reads as not resident: nothing stored, so NOT_RECORDED",
        OWN.oldResolves .. "/" .. tostring(p[OLDPID].knowledge) .. "/" .. tostring(p[OLDPID].reason), "1/UNAVAILABLE/NOT_RECORDED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE NATIVE STATE KEEPS A VALIDATED FOOTPRINT
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local ok = SGOperations.validateNativeState({ amount = 0, unit = "LITRE", storeKind = "ground", x = 1, z = 2, footprint = { kind = "GROUND_CELL", x = 1, z = 2, size = 0.5, extra = true } })
    T.eq("N1 a well-formed footprint is kept, its four fields only", tostring(ok and ok.footprint and ok.footprint.kind) .. "/" .. num(ok and ok.footprint.size) .. "/" .. tostring(ok and ok.footprint.extra), "GROUND_CELL/0.5/nil")
    local _, why1 = SGOperations.validateNativeState({ amount = 0, unit = "LITRE", footprint = { kind = "", x = 1, z = 2 } })
    local _, why2 = SGOperations.validateNativeState({ amount = 0, unit = "LITRE", footprint = { kind = "GROUND_CELL", x = 0 / 0, z = 2 } })
    local _, why3 = SGOperations.validateNativeState({ amount = 0, unit = "LITRE", footprint = { kind = "GROUND_CELL", x = 1, z = 2, size = -1 } })
    T.eq("N2 a footprint without a kind, with a non-finite centre or a non-positive size is refused", tostring(why1) .. "/" .. tostring(why2) .. "/" .. tostring(why3), "FOOTPRINT/FOOTPRINT/FOOTPRINT")
end)
