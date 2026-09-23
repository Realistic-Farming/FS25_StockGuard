-- SG2-3a-harvest_capture_spec_test.lua
--
-- SG2-3a, the harvest capture (Bob's intake: Drafts/BOB-INTAKE-SG2-3-HARVEST-REFRESH-
-- 2026-09-23.md). A cut is ONE BIRTH into whatever the combine actually filled, from a
-- witness of the cutter's own calls; a delay slot or buffer draining into the hopper
-- is ONE TRANSFER; a full hopper's refusal is a LOSS leg.
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine models load first (SG2-2's, then the
-- harvest engine), then every module main.lua sources, then main.lua. The mission
-- loads through main's own appends; the combine and its header are in the mission's
-- vehicle list when the barrier runs (and one header is added later through
-- VehicleSystem:addVehicle); the header's work areas carry pointers CAPTURED the way
-- WorkArea captures them; and every frame is the engine's order: the header's class
-- start, each captured pointer, the class end calling the combine's INSTANCE
-- addCutterArea, then the combine's class update tick. Nothing here writes a witness,
-- a binding, a capture or an allocation.
--
-- Groups:
--   S  the entry-point bar: the installer wired; one cut is ONE BIRTH into the hopper
--      and the straw slot, from the two work areas' witness by their weights
--   D  delay slots: the cut is born into the slot; the due drain is ONE TRANSFER; a
--      full hopper refuses part, which is a LOSS leg
--   B  the buffer fill unit: born into the buffer, drained into the hopper
--   T  straw: born even when the grain path returns early (:1027-1028); the input
--      buffer's rotation is a straw TRANSFER
--   Z  SoilFertilizer's wrappers in both install orders: the zone-yield scalar per
--      call, and an RSF-741-shaped token that needs the live liters
--   W  a witness belongs to its own frame: a cutter end that raised leaves nothing behind
--   N  no witness: an UNKNOWN portion, never a guessed one
--   R  refusals: a client, a native error
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local NH, NA, HC = SGNativeHost, SGNativeAdapters, SGHarvestCapture
local WHEAT, STRAW = ENGINE_FT.WHEAT, ENGINE_FT.STRAW
local FRUIT = ENGINE_FRUIT.WHEAT

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── the world ──────────────────────────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission()
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = false }, time = 1000, terrainSize = 256, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

--- Boot through main.lua's load path, the world built first.
local function boot(build)
    ENGINE_PLANE.cells = {}
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local w = {}
    build(m, w)
    Mission00.load(m)
    local sg = StockGuard.hostOf(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, sg, NH.current, w
end
local function combineIn(m, uid, opts)
    local v = ENGINE_NEW_COMBINE(uid, opts)
    m._vehicles[#m._vehicles + 1] = v
    return v
end
local function headerIn(m, uid, combine, opts)
    local v = ENGINE_NEW_HEADER(uid, combine, opts)
    m._vehicles[#m._vehicles + 1] = v
    return v
end

-- ── readers ───────────────────────────────────────────────────────────────
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function hopperId(v) return cid(NA.fillUnitBinding(v, 1)) end
local function bufferId(v) return cid(NA.fillUnitBinding(v, 2)) end
local function slotId(v, kind, i) return cid(NA.combineSlotBinding(v, kind, i)) end
local function stockAt(sg, id) local c = sg.operations.carriers[id] return c and c.stockId and sg.operations.stocks[c.stockId] or nil end
local function head(ls)
    local ev = ls and ls.report and ls.report.outcomeEvidence or {}
    return tostring(ev.nativePath) .. "/" .. tostring(ls and ls.outcome)
end
--- The allocations as "source>destination:amount:result"; birth slots print as "w<i>".
local function legsOf(ls, names)
    local out = {}
    for _, a in ipairs(ls and ls.report and ls.report.allocations or {}) do
        local src = a.source.slotId and ("w" .. (a.source.slotId:match(":w(%d+)") or a.source.slotId:match(":(%a+)$") or "?")) or (names[a.source.carrierId] or "?")
        local dst = a.destination.retire and "retire" or (names[a.destination.carrierId] or "?")
        out[#out + 1] = src .. ">" .. dst .. ":" .. num(a.sourceAmount) .. ":" .. tostring(a.result)
    end
    return table.concat(out, ",")
end
local function portionsOf(ls)
    local out = {}
    for _, p in ipairs(ls and ls.report and ls.report.outcomeEvidence and ls.report.outcomeEvidence.portions or {}) do
        -- A KNOWN portion names its growth state (SG2-3b); an UNKNOWN one its reason.
        out[#out + 1] = num(p.weight) .. ":" .. tostring(p.knowledge) .. ":" .. (p.knowledge == "KNOWN" and ("s" .. tostring(p.growthState)) or tostring(p.reason))
    end
    return table.concat(out, ",")
end
local function genericObservations(host, ids, fn)
    local n, real = 0, host.handle.observeCarrier
    host.handle.observeCarrier = function(lease, key, ...) if ids[key] then n = n + 1 end return real(lease, key, ...) end
    local ok, err = pcall(fn)
    host.handle.observeCarrier = real
    if not ok then error(err, 0) end
    return n
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:combine")
        w.header = headerIn(m, "vehicle:header", w.combine, { areas = 2, width = 4, depth = 1 })
        -- Area 1 cuts 4 ripe pixels (yield scale 1), area 2 four at state 3 (scale 0.5).
        ENGINE_PLANE.sow(FRUIT, 0, 0, 4, 1, 4)
        ENGINE_PLANE.sow(FRUIT, 4, 0, 8, 1, 3)
    end)
    T.ok("S1 [reached] main.lua's load path made the host live", host ~= nil and host.ready == true)
    local wa = w.header.spec_workArea.workAreas
    T.eq("S2 the installer is wired: both captured cutter pointers and the combine's instance slot carry StockGuard's bracket",
        tostring(wa[1]._sgBrackets ~= nil and wa[1]._sgBrackets.processCutterArea ~= nil) .. "/" .. tostring(wa[2]._sgBrackets ~= nil and wa[2]._sgBrackets.processCutterArea ~= nil) .. "/" .. tostring(HC.isCombineBracketed(w.combine)),
        "true/true/true")
    local hop, straw1 = hopperId(w.combine), slotId(w.combine, NA.KIND_STRAW_SLOT, 1)
    local generic = genericObservations(host, { [hop] = true, [straw1] = true }, function() ENGINE_HARVEST_TICK(w.header, w.combine, 16) end)
    T.eq("S3 [world] the engine's frame put 4 + 2 = 6 L of wheat in the hopper and 6 L of straw in the input buffer's slot",
        num(w.combine:getFillUnitFillLevel(1)) .. "/" .. num(w.combine.spec_combine.processing.inputBuffer.buffer[1].liters), "6/6")
    local ls = host.lastHarvest
    T.eq("S4 ONE BIRTH for the cut, committed", head(ls), "COMBINE_CUT/COMMITTED")
    T.eq("S5 its witness is the two cutter calls, weighed by what each added after every wrapper; since SG2-3b each a KNOWN portion of the state it cut",
        portionsOf(ls), "4:KNOWN:s4,2:KNOWN:s3")
    T.eq("S6 grain and straw each take the whole split: neither copies the other's litres",
        legsOf(ls, { [hop] = "hopper", [straw1] = "straw1" }), "w1>hopper:4:BORN,w2>hopper:2:BORN,w1>straw1:4:BORN,w2>straw1:2:BORN")
    local hs, ss = stockAt(sg, hop), stockAt(sg, straw1)
    T.eq("S7 the hopper and the straw slot hold stocks born of the cut", num(hs and hs.observedAmount) .. ":" .. tostring(hs and hs.materialRef.fillTypeName) .. "/" .. num(ss and ss.observedAmount) .. ":" .. tostring(ss and ss.materialRef.fillTypeName), "6:WHEAT/6:STRAW")
    T.eq("S8 nothing for the generic path: the observer's report of the hopper was consumed", generic .. "/" .. #host.dirtyOrder, "0/0")
    T.eq("S9 the context is at rest", SGOperationContext.isAtRest(host.context), true)

    -- A header added later through VehicleSystem.addVehicle is carried too.
    local late = ENGINE_NEW_HEADER("vehicle:late", w.combine, { areas = 1, width = 4, depth = 1, x0 = 10 })
    m._vehicles[#m._vehicles + 1] = late
    VehicleSystem.addVehicle(m.vehicleSystem, late)
    ENGINE_PLANE.sow(FRUIT, 10, 0, 14, 1, 4)
    ENGINE_HARVEST_TICK(late, w.combine, 16)
    T.eq("S10 a header added later is bracketed and its cut is one birth", tostring(late.spec_workArea.workAreas[1]._sgBrackets ~= nil) .. "/" .. head(host.lastHarvest) .. "/" .. portionsOf(host.lastHarvest),
        "true/COMBINE_CUT/COMMITTED/4:KNOWN:s4")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. DELAY SLOTS
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:delay", { loadingDelay = 100, hopperCapacity = 8 })
        w.header = headerIn(m, "vehicle:delayHeader", w.combine, { areas = 1, width = 6, depth = 1 })
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end)
    local hop, slot1 = hopperId(w.combine), slotId(w.combine, NA.KIND_DELAY_SLOT, 1)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    local slots = w.combine.spec_combine.loadingDelaySlots
    T.eq("D1 [world] with a loading delay the cut waits in the first free slot, not the hopper", tostring(slots[1].valid) .. "/" .. num(slots[1].fillLevelDelta) .. "/" .. num(w.combine:getFillUnitFillLevel(1)), "true/6/0")
    T.eq("D2 the cut is born into the slot's carrier", head(host.lastHarvest) .. "/" .. legsOf(host.lastHarvest, { [slot1] = "slot1", [hop] = "hopper", [slotId(w.combine, NA.KIND_STRAW_SLOT, 1)] = "straw1" }),
        "COMBINE_CUT/COMMITTED/w1>slot1:6:BORN,w1>straw1:6:BORN")
    local born = stockAt(sg, slot1)
    T.eq("D3 the slot holds a 6 L wheat stock", num(born and born.observedAmount) .. ":" .. tostring(born and born.materialRef.fillTypeName), "6:WHEAT")
    -- A second frame fills a second slot; then the field is empty and time passes.
    ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    local transfers = host.nextTransfer
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    T.eq("D4 [world] the next frame fills the next free slot", tostring(slots[2].valid) .. "/" .. num(slots[2].fillLevelDelta), "true/6")
    T.eq("D4b and its update tick, with slot 1 valid but not yet due, opens no drain", host.nextTransfer - transfers, 0)
    local bornId = born and born.stockId
    ENGINE_HARVEST_TICK(nil, w.combine, 200)
    local ld = host.lastDrain
    T.eq("D5 [world] the due slots drained: the hopper holds 8 of the 12 L (capacity 8), both slots cleared", num(w.combine:getFillUnitFillLevel(1)) .. "/" .. tostring(slots[1].valid) .. "/" .. tostring(slots[2].valid), "8/false/false")
    T.eq("D6 ONE TRANSFER: 8 L moved, the 4 L the full hopper refused a LOSS leg, split by each slot's share",
        head(ld) .. "/" .. legsOf(ld, { [slot1] = "slot1", [slotId(w.combine, NA.KIND_DELAY_SLOT, 2)] = "slot2", [hop] = "hopper" }),
        "COMBINE_DRAIN/COMMITTED/slot1>hopper:4:TRANSFERRED,slot1>retire:2:LOSS,slot2>hopper:4:TRANSFERRED,slot2>retire:2:LOSS")
    local retired = bornId and sg.operations.retiredStocks[bornId]
    T.eq("D7 the cleared slot's stock retired, and nothing re-births it", tostring(retired and retired.retireReason) .. "/" .. tostring(stockAt(sg, slot1)), "TRANSFERRED_OUT/nil")
    ENGINE_HARVEST_TICK(nil, w.combine, 16)
    T.eq("D8 an idle tick with no slot due opens nothing", host.lastDrain == ld, true)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE BUFFER FILL UNIT
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:buffered", { buffer = true, bufferCapacity = 100, bufferUnloadingTime = 1000 })
        w.header = headerIn(m, "vehicle:bufferHeader", w.combine, { areas = 1, width = 6, depth = 1 })
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end)
    local hop, buf = hopperId(w.combine), bufferId(w.combine)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    T.eq("B1 [world] the cut went into the buffer fill unit, which had room", num(w.combine:getFillUnitFillLevel(2)) .. "/" .. num(w.combine:getFillUnitFillLevel(1)), "6/0")
    T.eq("B2 born there", legsOf(host.lastHarvest, { [buf] = "buffer", [hop] = "hopper", [slotId(w.combine, NA.KIND_STRAW_SLOT, 1)] = "straw1" }), "w1>buffer:6:BORN,w1>straw1:6:BORN")
    -- A second cut while the buffer holds grain: the buffer does not drain while the
    -- cutters are working (:459), so its tick captures nothing.
    ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    local transfers = host.nextTransfer
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    T.eq("B2b a cutting tick with grain in the buffer opens no drain", tostring(host.nextTransfer - transfers) .. "/" .. num(w.combine:getFillUnitFillLevel(2)), "0/12")
    -- Idle long enough (ten ticks past the last cut), the buffer drains 0.1 L per ms:
    -- 2 L per 20 ms tick, so six ticks empty it.
    ENGINE_HARVEST_TICK(nil, w.combine, 200)
    ENGINE_HARVEST_TICK(nil, w.combine, 20)
    local ordinary = host.lastDrain
    T.eq("B3 an ordinary drain is ONE fill-unit to fill-unit TRANSFER", head(ordinary) .. "/" .. legsOf(ordinary, { [buf] = "buffer", [hop] = "hopper" }), "COMBINE_DRAIN/COMMITTED/buffer>hopper:2:TRANSFERRED")
    for _ = 1, 5 do ENGINE_HARVEST_TICK(nil, w.combine, 20) end
    local final = host.lastDrain
    -- The drain that empties the buffer hands the hopper the buffer's type read AFTER
    -- its debit (Combine.lua:462), which is UNKNOWN by then, and FillUnit refuses an
    -- unsupported type: native loses that last chunk.
    T.eq("B4 [world] the drain that empties the buffer is refused by the hopper: native loses its 2 L", num(w.combine:getFillUnitFillLevel(2)) .. "/" .. num(w.combine:getFillUnitFillLevel(1)), "0/10")
    T.eq("B5 so that drain is ONE TRANSFER whose 2 L is a LOSS leg, recorded rather than hidden", head(final) .. "/" .. legsOf(final, { [buf] = "buffer", [hop] = "hopper" }), "COMBINE_DRAIN/COMMITTED/buffer>retire:2:LOSS")
    local hs = stockAt(sg, hop)
    T.eq("B6 the hopper's stock holds the 10 L that arrived", num(hs and hs.observedAmount), "10")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. STRAW
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local m, sg, host, w = boot(function(m, w)
        -- A forage-style infinite hopper already holding grain, past its buffer time.
        w.combine = combineIn(m, "vehicle:infinite", { hopperCapacity = math.huge, hopperLevel = 50, slotDuration = 100 })
        w.header = headerIn(m, "vehicle:infiniteHeader", w.combine, { areas = 1, width = 6, depth = 1 })
        ENGINE_PLANE.sow(FRUIT, 0, 0, 6, 1, 4)
    end)
    local hop, s1, s2 = hopperId(w.combine), slotId(w.combine, NA.KIND_STRAW_SLOT, 1), slotId(w.combine, NA.KIND_STRAW_SLOT, 2)
    local ib = w.combine.spec_combine.processing.inputBuffer
    m.time = 10000
    ENGINE_HARVEST_TICK(w.header, nil, 16)
    local ev = host.lastHarvest and host.lastHarvest.report and host.lastHarvest.report.outcomeEvidence or {}
    T.eq("T1 [world] the grain path returned early (:1027-1028): the hopper unchanged, the straw already in the buffer", num(w.combine:getFillUnitFillLevel(1)) .. "/" .. num(ib.buffer[1].liters), "50/6")
    T.eq("T2 the straw is born anyway, the grain not at all", head(host.lastHarvest) .. "/" .. num(ev.grainBorn) .. "/" .. num(ev.strawBorn), "COMBINE_CUT/COMMITTED/0/6")
    -- The input buffer rotates: the drop slot's straw moves on (:442-458).
    ib.slotTimer = 10
    ib.dropIndex = 1
    ENGINE_HARVEST_TICK(nil, w.combine, 16)
    local ld = host.lastDrain
    T.eq("T3 [world] the rotation moved the straw from slot 1 to slot 2", num(ib.buffer[1].liters) .. "/" .. num(ib.buffer[2].liters), "0/6")
    T.eq("T4 as ONE straw TRANSFER", head(ld) .. "/" .. legsOf(ld, { [s1] = "straw1", [s2] = "straw2" }), "COMBINE_STRAW_ROTATION/COMMITTED/straw1>straw2:6:TRANSFERRED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. SOILFERTILIZER'S WRAPPERS, BOTH INSTALL ORDERS
-- ══════════════════════════════════════════════════════════════════════════
-- Shaped on SF's zone-yield cutter wrapper (it rescales ONE call's multiplier-area
-- delta by one scalar, SF HookManager installZoneYieldCutterHook) and on its harvest
-- hook with RSF-741's token (the cutter end sets a token the combine wrapper takes,
-- requiring the live liters to match within 1e-9).
local function sfWraps(header, combine, scalars, seen)
    for i, wa in ipairs(header.spec_workArea.workAreas) do
        local inner = wa.processingFunction
        wa.processingFunction = function(self, workArea, dt)
            local p = self.spec_cutter.workAreaParameters
            local before = p.lastMultiplierArea
            local r1, r2 = inner(self, workArea, dt)
            local added = p.lastMultiplierArea - before
            p.lastMultiplierArea = before + added * (scalars[i] or 1)
            return r1, r2
        end
    end
    local innerAdd = combine.addCutterArea
    combine.addCutterArea = function(self, area, liters, ...)
        local token = seen.token
        seen.token = nil
        seen.matched = token ~= nil and math.abs(token - liters) < 1e-9
        return innerAdd(self, area, liters, ...)
    end
end
local SFEnd = nil
local function sfTokenOnCutterEnd(seen)
    -- A class wrap, as RSF-741's cutter-end token is: it runs inside the end, before
    -- the combine is called, and reads the liters the end is about to pass.
    if SFEnd ~= nil then return end
    local original = Cutter.onEndWorkAreaProcessing
    SFEnd = original
    Cutter.onEndWorkAreaProcessing = function(self, ...)
        local p = self.spec_cutter.workAreaParameters
        seen.token = g_fruitTypeManager:getFruitTypeAreaLiters(p.lastFruitType, p.lastMultiplierArea, false) + p.lastLiters
        return original(self, ...)
    end
end

group("Z", function()
    local seen = {}
    sfTokenOnCutterEnd(seen)
    for _, order in ipairs({ "SF_INSIDE", "SF_OUTSIDE" }) do
        local m, sg, host, w = boot(function(m, w)
            w.combine = combineIn(m, "vehicle:z" .. order)
            w.header = headerIn(m, "vehicle:zh" .. order, w.combine, { areas = 2, width = 4, depth = 1 })
            ENGINE_PLANE.sow(FRUIT, 0, 0, 4, 1, 4)
            ENGINE_PLANE.sow(FRUIT, 4, 0, 8, 1, 3)
            -- SF installed BEFORE StockGuard: its wrappers sit inside StockGuard's.
            if order == "SF_INSIDE" then sfWraps(w.header, w.combine, { 1, 2 }, seen) end
        end)
        if order == "SF_OUTSIDE" then sfWraps(w.header, w.combine, { 1, 2 }, seen) end
        ENGINE_HARVEST_TICK(w.header, w.combine, 16)
        T.eq("Z1 [" .. order .. "] the witness weighs each call after SF's scalar (4 and 2 x 2): the post-chain weights, whichever wraps outside",
            portionsOf(host.lastHarvest), "4:KNOWN:s4,4:KNOWN:s3")
        T.eq("Z2 [" .. order .. "] SF's zone yield is ONE scalar per call, so a split by weight stays proportional: 8 L born 4:4",
            num(w.combine:getFillUnitFillLevel(1)) .. "/" .. legsOf(host.lastHarvest, { [hopperId(w.combine)] = "hopper", [slotId(w.combine, NA.KIND_STRAW_SLOT, 1)] = "straw1" }),
            "8/w1>hopper:4:BORN,w2>hopper:4:BORN,w1>straw1:4:BORN,w2>straw1:4:BORN")
        T.eq("Z3 [" .. order .. "] RSF-741's token round trip still matches the live liters", seen.matched, true)
        FSBaseMission.delete(m)
    end
    Cutter.onEndWorkAreaProcessing = SFEnd
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. A WITNESS BELONGS TO ITS OWN FRAME
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:wit")
        w.header = headerIn(m, "vehicle:witHeader", w.combine, { areas = 2, width = 4, depth = 1 })
        ENGINE_PLANE.sow(FRUIT, 0, 0, 8, 1, 4)
    end)
    -- A frame whose cutter end raises before it reaches the combine.
    local realFarm = w.header.getLastTouchedFarmlandFarmId
    w.header.getLastTouchedFarmlandFarmId = function() error("end boom") end
    local ok = pcall(ENGINE_HARVEST_TICK, w.header, nil, 16)
    w.header.getLastTouchedFarmlandFarmId = realFarm
    T.eq("W1 [world] that frame cut 8 L but its end raised before calling the combine", tostring(ok) .. "/" .. num(w.combine:getFillUnitFillLevel(1)), "false/0")
    ENGINE_PLANE.sow(FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(w.header, w.combine, 16)
    T.eq("W2 the next frame's cut carries only its own witness: the raised frame's calls do not ride on", portionsOf(host.lastHarvest), "4:KNOWN:s4")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. NO WITNESS
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:pickup")
    end)
    -- A call with no cutter end in the stack (a pickup header's ground material has
    -- no field witness; SG2-4 owns its source).
    w.combine:addCutterArea(0, 30, FRUIT, WHEAT, 0, 1, 1)
    T.eq("N1 the output is born whole from ONE UNKNOWN portion that says why", portionsOf(host.lastHarvest) .. "/" .. legsOf(host.lastHarvest, { [hopperId(w.combine)] = "hopper", [slotId(w.combine, NA.KIND_STRAW_SLOT, 1)] = "straw1" }),
        "1:UNKNOWN:NO_CUTTER/wunknown>hopper:30:BORN,wunknown>straw1:30:BORN")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. REFUSALS
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local m, sg, host, w = boot(function(m, w)
        w.combine = combineIn(m, "vehicle:boom")
        w.header = headerIn(m, "vehicle:boomHeader", w.combine, { areas = 1, width = 4, depth = 1 })
        ENGINE_PLANE.sow(FRUIT, 0, 0, 4, 1, 4)
    end)
    local realAdd = w.combine.addFillUnitFillLevel
    rawset(w.combine, "addFillUnitFillLevel", function() error("hopper boom") end)
    local ok, err = pcall(ENGINE_HARVEST_TICK, w.header, nil, 16)
    rawset(w.combine, "addFillUnitFillLevel", realAdd)
    T.eq("R1 a native error inside the cut reaches the engine unchanged, and the birth is abandoned",
        tostring(ok) .. "/" .. tostring(tostring(err):find("hopper boom", 1, true) ~= nil) .. "/" .. tostring(host.lastHarvest and host.lastHarvest.outcome) .. "/" .. tostring(host.lastHarvest and host.lastHarvest.reason),
        "false/true/ABANDONED/NATIVE_ERROR")
    T.eq("R2 the context is at rest and no cutter is left named", tostring(SGOperationContext.isAtRest(host.context)) .. "/" .. tostring(HC.currentCutter), "true/nil")
    w.combine.isServer = false
    local before = host.nextCut
    ENGINE_PLANE.sow(FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(w.header, nil, 16)
    T.eq("R3 a client combine's cut opens nothing", host.nextCut - before, 0)
    FSBaseMission.delete(m)
end)
