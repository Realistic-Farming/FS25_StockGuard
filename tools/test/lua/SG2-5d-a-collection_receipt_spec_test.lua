-- SG2-5d-a-collection_receipt_spec_test.lua
--
-- SG2-5 slice 5d-a (Bob's 5d shape ruling, the seal and Q5; Desk's split): StockGuard's producer half
-- that does not depend on a machine (SGCollectionSeal, StockGuard.lua's handle). Inert: no frame calls
-- it until 5d-b.
--   * the F211 :76 apportionment: a target A over a tick's batches by what each produced
--     (A_b = P_b x F x A / W), each source q_bi = A_b x r_bi / R_b, the raw retained r_bi x A / W, the
--     final remainder on the last canonical part so the parts sum to A_b exactly;
--   * the bounded, transient seal store and the handle's readCollectionReceipt (SG-2 :358);
--   * the handle's read-only fillUnitStockRef (Bob's Q5).
--
-- THE ENTRY-POINT BAR IS GROUP E: main.lua's load path builds the mission's StockGuard handle, and
-- Soil's own collected reader, MaterialWetness:readCollectedCondition with resolveAllocation
-- (SoilFertilizer at 2dd42a22, :1411-1513, VERBATIM below), resolves StockGuard's receipt through that
-- handle exactly as it does in game. The joined run against Soil's real reader and real snapshots is a
-- throwaway outside the repo (the PR body names it).
--
--!env: modenv), on the SG2-4b world, with SG2-4c-1's recorder
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

local MW = setmetatable({}, { __index = MaterialWetness })
local CS = SGCollectionSeal
local REV = { epoch = 3, changeCounter = 41, ageThroughDay = 100, wetThroughDay = 100 }
--- Soil's snapshot (collectedSnapshot's shape) over sources { id, available, pct|nil, status }.
local function snapshot(id, sources)
    local parts = {}
    for _, s in ipairs(sources) do parts[s.id] = { available = s.available, status = s.status or (s.pct ~= nil and "KNOWN" or "UNKNOWN"), pct = s.pct } end
    return { id = id, basis = "COLLECTED_NATIVE_VOLUME_V1", revision = { epoch = REV.epoch, changeCounter = REV.changeCounter, ageThroughDay = REV.ageThroughDay, wetThroughDay = REV.wetThroughDay }, parts = parts }
end
--- Soil's delivery collection for a pickup (5d-soil's result.collection): the litres each cell lost.
local function collection(snap, raws)
    local parts = {}
    for _, r in ipairs(raws) do parts[#parts + 1] = { id = r[1], raw = r[2] } end
    return { snapshotRef = snap.id, basis = snap.basis, revision = { epoch = REV.epoch, changeCounter = REV.changeCounter, ageThroughDay = REV.ageThroughDay, wetThroughDay = REV.wetThroughDay }, parts = parts }
end
local function cov(c)
    if c == nil then return "nil" end
    return table.concat({ tostring(c.status), tostring(c.reason), num(c.carrierLitres), num(c.knownCarrierLitres), num(c.unknownCarrierLitres), num(c.pct) }, "/")
end
--- A world with a mission whose StockGuard handle is main.lua's own.
local function bootBare(key, index)
    resetWorld()
    soilReset()
    return boot(function(m, w) tipWorld(m, w, { at = { x = 0, z = 0 }, level = 200 }) end, key, { index = index })
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: SOIL'S READER RESOLVES STOCKGUARD'S SEAL THROUGH THE HANDLE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local m, sg = bootBare("w5da_e", 101)
    T.eq("E0 [entry point] main.lua's load path put readCollectionReceipt and fillUnitStockRef on the mission's StockGuard handle",
        type(m.stockGuard.readCollectionReceipt) .. "/" .. type(m.stockGuard.fillUnitStockRef) .. "/" .. tostring(sg.collectionSeals ~= nil), "function/function/true")
    -- One pickup batch: two cells, 60 L of grass at 20 % and 40 L at 80 %, produced 100 L (no boost).
    local snap = snapshot("COLLECTED#1", { { id = "8:8", available = 60, pct = 20 }, { id = "9:8", available = 40, pct = 80 } })
    local shares, W = CS.sealTarget(sg.collectionSeals, { { collection = collection(snap, { { "8:8", 60 }, { "9:8", 40 } }), produced = 100 } }, 1, 100)
    local c = MW:readCollectedCondition(snap, shares[1] and shares[1].receipt)
    T.eq("E1 NAMED [entry point]: Soil's reader resolves the receipt through the mission's handle (MaterialWetness:resolveAllocation) and reads the sealed allocation: complete, 100 L, the litre-weighted 44 %",
        num(W) .. "|" .. cov(c), "100|ok/COMPLETE_KNOWN_COVERAGE/100/100/0/44")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE APPORTIONMENT (F211 :76, :86)
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    local m, sg = bootBare("w5da_a", 102)
    local store = sg.collectionSeals
    -- F211 :86's example: 100 raw litres become 105 carrier litres and the chamber accepts 10.
    local s1 = snapshot("COLLECTED#2", { { id = "1:1", available = 100, pct = 30 } })
    local shares = CS.sealTarget(store, { { collection = collection(s1, { { "1:1", 100 } }), produced = 105 } }, 1, 10)
    local a = store.allocations[shares[1].receipt.allocationId]
    T.eq("A1 NAMED: of 105 produced from 100 raw, a 10 L acceptance seals 10 carrier litres with a raw retained equivalent of 100 x 10 / 105, and reads with the source's condition",
        num(a.acceptedCarrierLitres) .. "/" .. num(a.parts[1].carrierLitres) .. "/" .. num(a.parts[1].rawLitres) .. "|" .. cov(MW:readCollectedCondition(s1, shares[1].receipt)),
        "10/10/" .. num(100 * 10 / 105) .. "|ok/COMPLETE_KNOWN_COVERAGE/10/10/0/30")
    -- fillScale 2: 210 produced; a 10 + 200 split keeps the same condition on both.
    local s2 = snapshot("COLLECTED#3", { { id = "1:1", available = 100, pct = 30 } })
    local b2 = { { collection = collection(s2, { { "1:1", 100 } }), produced = 105 } }
    local ten = CS.sealTarget(store, b2, 2, 10)
    local twoHundred = CS.sealTarget(store, b2, 2, 200)
    T.eq("A2 at fillScale 2 the 10 L accepted and the 200 L kept elsewhere are each sealed in full, both of the source's condition",
        cov(MW:readCollectedCondition(s2, ten[1].receipt)) .. " " .. cov(MW:readCollectedCondition(s2, twoHundred[1].receipt)),
        "ok/COMPLETE_KNOWN_COVERAGE/10/10/0/30 ok/COMPLETE_KNOWN_COVERAGE/200/200/0/30")
    -- Two batches of different gains (F211 :86): 105 L produced at 20 % and 100 L at 80 %.
    local sa = snapshot("COLLECTED#4", { { id = "1:1", available = 100, pct = 20 } })
    local sb = snapshot("COLLECTED#5", { { id = "2:1", available = 100, pct = 80 } })
    local two = CS.sealTarget(store, { { collection = collection(sa, { { "1:1", 100 } }), produced = 105 },
                                       { collection = collection(sb, { { "2:1", 100 } }), produced = 100 } }, 1, 205)
    local ca, cb = MW:readCollectedCondition(sa, two[1].receipt), MW:readCollectedCondition(sb, two[2].receipt)
    local weighted = (ca.knownWeightedPctSum + cb.knownWeightedPctSum) / (ca.carrierLitres + cb.carrierLitres)
    T.eq("A3 NAMED: the target is split by what each batch PRODUCED (A_b = P_b x F x A / W, not by raw litres), so the mixture weighs (105 x 20 + 100 x 80) / 205",
        num(two[1].A_b) .. "/" .. num(two[2].A_b) .. "/" .. num(weighted), "105/100/" .. num((105 * 20 + 100 * 80) / 205))
    T.eq("A4 the shares sum to the target exactly", tostring(two[1].A_b + two[2].A_b == 205), "true")
    -- Seven batches of equal production over 0.1 L: sevenths do not sum to 0.1 unless the last batch takes the remainder.
    local seven = {}
    for i = 1, 7 do
        local sn = snapshot("COLLECTED#3" .. i, { { id = "1:" .. i, available = 1, pct = 10 } })
        seven[i] = { collection = collection(sn, { { "1:" .. i, 1 } }), produced = 1 }
    end
    local t7 = CS.sealTarget(store, seven, 1, 0.1)
    local sum7 = 0
    for _, sh in ipairs(t7) do sum7 = sum7 + sh.A_b end
    T.eq("A5 NAMED: seven equal batches over 0.1 L: the last batch takes the remainder, so the shares sum to exactly 0.1",
        #t7 .. "/" .. tostring(sum7 == 0.1), "7/true")
    -- One cell crossed twice in a tick: its two losses are one source of 30 raw litres.
    local sd = snapshot("COLLECTED#40", { { id = "1:1", available = 30, pct = 20 }, { id = "2:1", available = 10, pct = 60 } })
    local twice = CS.sealTarget(store, { { collection = collection(sd, { { "1:1", 10 }, { "2:1", 10 }, { "1:1", 20 } }), produced = 40 } }, 1, 40)
    local ad = store.allocations[twice[1].receipt.allocationId]
    T.eq("A6 a cell named twice in one collection is one part holding both losses (30 of 40), and reads (30 x 20 + 10 x 60) / 40",
        #ad.parts .. "/" .. ad.parts[1].id .. "=" .. num(ad.parts[1].carrierLitres) .. "|" .. cov(MW:readCollectedCondition(sd, twice[1].receipt)),
        "2/1:1=30|ok/COMPLETE_KNOWN_COVERAGE/40/40/0/30")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE REMAINDER: SOIL'S READER COMPARES THE SUM BY EQUALITY (MaterialWetness.lua:1503)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local m, sg = bootBare("w5da_r", 103)
    -- Seven equal sources over a 0.1 L target: summed naively, 0.1 / 7 seven times is 0.10000000000000002.
    local sources, raws = {}, {}
    for k = 7, 1, -1 do sources[#sources + 1] = { id = "1:" .. k, available = 1, pct = 10 } raws[#raws + 1] = { "1:" .. k, 1 } end
    local snap = snapshot("COLLECTED#6", sources)
    local shares = CS.sealTarget(sg.collectionSeals, { { collection = collection(snap, raws), produced = 7 } }, 1, 0.1)
    local a = sg.collectionSeals.allocations[shares[1].receipt.allocationId]
    local s, ids = 0, {}
    for _, p in ipairs(a.parts) do s = s + p.carrierLitres ids[#ids + 1] = p.id end
    local c = MW:readCollectedCondition(snap, shares[1].receipt)
    T.eq("R1 NAMED: seven sevenths of 0.1 L sum to exactly 0.1 in the canonical order (the final remainder on the last part), and Soil's reader accepts them",
        table.concat(ids, ",") .. "/" .. tostring(s == 0.1) .. "|" .. tostring(c.status) .. "/" .. tostring(c.carrierLitres == 0.1),
        "1:1,1:2,1:3,1:4,1:5,1:6,1:7/true|ok/true")
    -- 123.456 L over raws 1, 5 and 10: the sum of the first two shares is an odd multiple of half
    -- 123.456's unit in the last place, so no last part alone can close the sum on 123.456.
    local s2 = snapshot("COLLECTED#9", { { id = "1:1", available = 1, pct = 10 }, { id = "1:2", available = 5, pct = 30 }, { id = "1:3", available = 10, pct = 60 } })
    local sh2 = CS.sealTarget(sg.collectionSeals, { { collection = collection(s2, { { "1:1", 1 }, { "1:2", 5 }, { "1:3", 10 } }), produced = 200 } }, 1, 123.456)
    local a2 = sh2[1].receipt ~= nil and sg.collectionSeals.allocations[sh2[1].receipt.allocationId] or nil
    local t2, off = 0, 0
    for i, p in ipairs(a2 ~= nil and a2.parts or {}) do
        t2 = t2 + p.carrierLitres
        off = math.max(off, math.abs(p.carrierLitres - 123.456 * ({ 1, 5, 10 })[i] / 16))
    end
    local c2 = MW:readCollectedCondition(s2, sh2[1].receipt)
    T.eq("R2 NAMED: 123.456 L over raws 1, 5 and 10 seals parts summing to exactly 123.456, each within 123.456 x 2^-40 of its share, and Soil's reader accepts them",
        tostring(sh2[1].unknown) .. "/" .. tostring(t2 == 123.456) .. "/" .. tostring(off <= 123.456 * 2 ^ -40) .. "|" .. tostring(c2.status) .. "/" .. tostring(c2.reason),
        "nil/true/true|ok/COMPLETE_KNOWN_COVERAGE")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. WHAT CANNOT BE SEALED IS UNKNOWN, NEVER INVENTED
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    local m, sg = bootBare("w5da_z", 104)
    local store = sg.collectionSeals
    local snap = snapshot("COLLECTED#7", { { id = "1:1", available = 10, pct = 50 } })
    local col = collection(snap, { { "1:1", 10 } })
    T.eq("Z1 a zero target seals nothing (F211 :50: zero-A calls create no material result)", #CS.sealTarget(store, { { collection = col, produced = 10 } }, 1, 0) .. "/" .. #store.order, "0/0")
    T.eq("Z2 nothing produced seals nothing", #CS.sealTarget(store, { { collection = col, produced = 0 } }, 1, 5) .. "/" .. #store.order, "0/0")
    local s = CS.sealTarget(store, { { collection = nil, produced = 10 } }, 1, 5)
    T.eq("Z3 a batch with no collection is unknown produced material for its whole share", tostring(s[1].unknown) .. "/" .. tostring(s[1].reason) .. "/" .. num(s[1].A_b), "true/NO_COLLECTION/5")
    local empty = collection(snap, {})
    s = CS.sealTarget(store, { { collection = empty, produced = 10 } }, 1, 5)
    T.eq("Z4 a collection with no source litres is unknown too", tostring(s[1].unknown) .. "/" .. tostring(s[1].reason), "true/NO_SOURCE")
    local other = collection(snap, { { "1:1", 10 } })
    other.basis = "STANDING_NATIVE_VOLUME_V1"
    s = CS.sealTarget(store, { { collection = other, produced = 10 } }, 1, 5)
    local noRef, noRev = collection(snap, { { "1:1", 10 } }), collection(snap, { { "1:1", 10 } })
    noRef.snapshotRef = nil
    noRev.revision = nil
    local function why(c) local r = CS.sealTarget(store, { { collection = c, produced = 10 } }, 1, 5) return tostring(r[1].unknown) .. "/" .. tostring(r[1].reason) end
    T.eq("Z5 a reference that is not a COLLECTED snapshot, one naming no snapshot and one with no revision are not sealed",
        tostring(s[1].unknown) .. "/" .. tostring(s[1].reason) .. " " .. why(noRef) .. " " .. why(noRev), "true/COLLECTION true/COLLECTION true/COLLECTION")
    local r6, why6 = CS.sealBatch(store, col, 0, 1)
    T.eq("Z6 a batch share of nothing is not sealed and stores nothing", tostring(r6) .. "/" .. tostring(why6) .. "/" .. #store.order, "nil/NO_TARGET/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE STORE AND THE RECEIPT CALL
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg = bootBare("w5da_s", 105)
    local store = sg.collectionSeals
    local snap = snapshot("COLLECTED#8", { { id = "1:1", available = 10, pct = 50 } })
    local function seal() return CS.sealTarget(store, { { collection = collection(snap, { { "1:1", 10 } }), produced = 10 } }, 1, 10)[1].receipt end
    local keep = CS.MAX_ALLOCATIONS
    CS.MAX_ALLOCATIONS = 2
    local r1, r2, r3 = seal(), seal(), seal()
    CS.MAX_ALLOCATIONS = keep
    local function answer(...) local r = { pcall(m.stockGuard.readCollectionReceipt, ...) } if not r[1] then return "RAISED" end return tostring(r[2] ~= nil) .. "/" .. tostring(r[3]) end
    T.eq("S1 NAMED: the store is bounded, oldest first: the first receipt is no longer resolvable, the later two are",
        answer(r1) .. " " .. answer(r2) .. " " .. answer(r3), "false/UNAVAILABLE true/nil true/nil")
    local got = m.stockGuard.readCollectionReceipt(r3)
    got.parts[1].carrierLitres = 999
    got.acceptedCarrierLitres = 999
    local again = m.stockGuard.readCollectionReceipt(r3)
    T.eq("S2 NAMED: the answer is detached: a caller writing to it changes no sealed fact", num(again.acceptedCarrierLitres) .. "/" .. num(again.parts[1].carrierLitres), "10/10")
    T.eq("S3 a colon call is refused", tostring(select(2, m.stockGuard:readCollectionReceipt(r3))), "CALLED_WITH_COLON")
    local forged = { allocationId = r3.allocationId, snapshotId = "COLLECTED#other" }
    T.eq("S4 a receipt naming another snapshot is refused, and a malformed one too", answer(forged) .. " " .. answer("x"), "false/SNAPSHOT_MISMATCH false/RECEIPT")
    -- The handle's server check is the mission's own (StockGuard.lua SG:isServer, getIsServer).
    m._server = false
    local client = { pcall(m.stockGuard.readCollectionReceipt, r3) }
    m._server = true
    T.eq("S5 server only: a client gets nothing", tostring(client[2]) .. "/" .. tostring(client[3]), "nil/NOT_SERVER")
    FSBaseMission.delete(m)
    T.eq("S6 the mission's end empties the store (transient, never saved)", tostring(next(store.allocations)) .. "/" .. #sg.collectionSeals.order, "nil/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE READ-ONLY STOCK LOOKUP (Bob's Q5)
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local m, sg, host, w = bootBare("w5da_l", 106)
    local opened0 = 0
    for _ in pairs(sg.operations.openHandles) do opened0 = opened0 + 1 end
    local seq0 = sg.operations.revision
    local ref, why = m.stockGuard.fillUnitStockRef(w.tipper, 1)
    local stock = stockAt(sg, unitId(w.tipper))
    T.eq("L1 NAMED: a bound unit holding material answers its current stock reference, exactly SG-1's",
        tostring(ref ~= nil and stock ~= nil and SGValues.equal(ref, sg.operations:stockRef(stock))) .. "/" .. tostring(why), "true/nil")
    local opened = 0
    for _ in pairs(sg.operations.openHandles) do opened = opened + 1 end
    T.eq("L2 NAMED: it opens no operation and changes no record (read only)", (opened - opened0) .. "/" .. tostring(sg.operations.revision == seq0), "0/true")
    ENGINE_TIP(w.tipper, 200)   -- the tipper empties: its stock retires
    --- Both answers of a lookup, or RAISED: the lookup must answer, never throw.
    local function look(...) local r = { pcall(m.stockGuard.fillUnitStockRef, ...) } if not r[1] then return "RAISED" end return tostring(r[2]) .. "/" .. tostring(r[3]) end
    T.eq("L3 an emptied unit has no stock", look(w.tipper, 1), "nil/NO_STOCK")
    T.eq("L4 a vehicle StockGuard never bound, or a fill unit it does not have, is not bound",
        look({ uniqueId = "nobody" }, 1) .. " " .. look(w.tipper, 9) .. " " .. look(nil, 1), "nil/NOT_BOUND nil/NOT_BOUND nil/NOT_BOUND")
    T.eq("L5 a colon call is refused", tostring(select(2, m.stockGuard:fillUnitStockRef(w.tipper, 1))), "CALLED_WITH_COLON")
    m._server = false
    local client = { pcall(m.stockGuard.fillUnitStockRef, w.tipper, 1) }
    m._server = true
    T.eq("L6 server only: a client gets nothing", tostring(client[2]) .. "/" .. tostring(client[3]), "nil/NOT_SERVER")
    FSBaseMission.delete(m)
end)
