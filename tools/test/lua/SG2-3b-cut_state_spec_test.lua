-- SG2-3b-cut_state_spec_test.lua
--
-- SG2-3b, CUT_STATE_VOLUME_V1 (SG-2 :497-512, :539-544): each direct cutFruitArea call's
-- source, the pixels that actually made their harvest transition, by growth state and
-- Soil cell, admitted only when their weights sum to the native's own returned area.
--
-- THE ENTRY-POINT BAR IS GROUP S. As SG2-3a's: the engine models, then main.lua's
-- modules and main.lua; the mission through main's appends; a combine and header in
-- the vehicle list at the barrier; every frame in the engine's order. The producer is
-- reached only as production reaches it: the Cutter's processCutterArea calls
-- FSDensityMapUtil.cutFruitArea by table lookup (Cutter.lua:600), inside StockGuard's
-- cutter bracket. The fruit plane is the engine model's (its state channels at offset
-- 2, so the decode is exercised); nothing here writes a pixel count, a portion or a
-- weight.
--
-- Groups:
--   S  the entry-point bar: one call over two growth states is two KNOWN portions,
--      split by pixels x yield scale
--   L  Soil: present, the states split by Soil cell with a snapshot; absent or
--      unreadable, no Soil split and no invented snapshot
--   B  the native total disagrees with the pixels: one UNKNOWN portion, never a guess
--   R  a harvest target that could be recut: one UNKNOWN portion
--   Y  a source state with no yieldScales entry: one UNKNOWN portion, never a default
--   E  an envelope too large to read: one UNKNOWN portion
--   F  a pixel of another fruit inside the envelope is no source
--   X  a native error inside the cut is re-raised, nothing left active
--   O  a cutFruitArea call outside any cutter call is native, untouched
--   G  the in-game evidence: the first admission and each refusal logged once
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local NH, NA, HC, CS = SGNativeHost, SGNativeAdapters, SGHarvestCapture, SGCutState
local WHEAT_FRUIT, BARLEY_FRUIT = ENGINE_FRUIT.WHEAT, ENGINE_FRUIT.BARLEY

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

-- ── the world (as SG2-3a's) ─────────────────────────────────────────────────
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

--- One combine with a one-area header over x 0..4, z 0..1, booted through main.lua.
local function boot(sow)
    ENGINE_PLANE.cells = {}
    ENGINE_PLANE.bias = 0
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local combine = ENGINE_NEW_COMBINE("vehicle:combine")
    local header = ENGINE_NEW_HEADER("vehicle:header", combine, { areas = 1, width = 4, depth = 1 })
    m._vehicles[1], m._vehicles[2] = combine, header
    sow()
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    return m, NH.current, combine, header
end

-- ── readers ───────────────────────────────────────────────────────────────
--- Each portion as "weight:KNOWN:s<state>:<pixels>px:x<scale>[:cell][:N<n>]", or
--- "weight:UNKNOWN:<reason>".
local function portions(host)
    local out = {}
    local ev = host.lastHarvest and host.lastHarvest.report and host.lastHarvest.report.outcomeEvidence or {}
    for _, p in ipairs(ev.portions or {}) do
        if p.knowledge == "KNOWN" then
            local s = num(p.weight) .. ":KNOWN:s" .. tostring(p.growthState) .. ":" .. tostring(p.pixels) .. "px:x" .. num(p.yieldScale)
            if p.soilCell ~= nil and p.soilCell ~= "none" then s = s .. ":" .. p.soilCell end
            if p.soil ~= nil then s = s .. ":N" .. num(p.soil.nitrogen) end
            out[#out + 1] = s
        else
            out[#out + 1] = num(p.weight) .. ":" .. tostring(p.knowledge) .. ":" .. tostring(p.reason)
        end
    end
    return table.concat(out, ",")
end
--- The allocations into the hopper as "p<k>:<amount>" in order.
local function hopperLegs(host, combine)
    local hop = SGRecords.carrierKeyString(NA.fillUnitBinding(combine, 1).carrierKey)
    local out = {}
    for _, a in ipairs(host.lastHarvest and host.lastHarvest.report and host.lastHarvest.report.allocations or {}) do
        if a.destination.carrierId == hop then
            out[#out + 1] = (a.source.slotId:match(":(p%d+)$") or a.source.slotId:match(":(w%d+)$") or "?") .. ":" .. num(a.sourceAmount)
        end
    end
    return table.concat(out, ",")
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, host, combine, header = boot(function()
        -- Two ripe pixels (scale 1) and two at state 3 (scale 0.5) under one work area.
        ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 2, 1, 4)
        ENGINE_PLANE.sow(WHEAT_FRUIT, 2, 0, 4, 1, 3)
    end)
    T.ok("S1 [reached] main.lua's load path installed the producer on the engine's cutFruitArea", host ~= nil and host.ready and rawget(FSDensityMapUtil, "_sgCutState") ~= nil)
    local admitted = CS.stats.admitted
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("S2 [world] the frame harvested 2 + 1 = 3 L into the hopper", num(combine:getFillUnitFillLevel(1)), "3")
    T.eq("S3 the cut's source is the two states its pixels actually left, each counted and scaled",
        portions(host), "2:KNOWN:s4:2px:x1,1:KNOWN:s3:2px:x0.5")
    T.eq("S4 the birth splits the 3 L by those portions, 2 and 1", hopperLegs(host, combine), "p1:2,p2:1")
    local ev = host.lastHarvest.report.outcomeEvidence
    T.eq("S5 each portion names its profile", tostring(ev.portions[1].profile) .. "/" .. tostring(ev.portions[2].profile), "CUT_STATE_VOLUME_V1/CUT_STATE_VOLUME_V1")
    T.eq("S6 and the call was admitted on the native's own total", CS.stats.admitted - admitted, 1)
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("S7 a later frame over one state is one portion of it", portions(host), "4:KNOWN:s4:4px:x1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. SOIL CELLS
-- ══════════════════════════════════════════════════════════════════════════
-- Shaped on SoilFertilityManager:getSoilValueAtWorld (SF, :2556): a value and the Soil
-- grain in metres, nil when the value maps are unavailable.
local function soilStub(grain, readable)
    return { getSoilValueAtWorld = function(_, key, x, z)
        if not readable then return nil end
        local cell = math.floor((x + 128) / grain)
        local values = { nitrogen = cell == 64 and 10 or 20, phosphorus = 5, potassium = 6, pH = 6.5 }
        return values[key], grain
    end }
end

group("L", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    g_SoilFertilityManager = soilStub(2, true)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("L1 with Soil present the state splits by Soil cell, each with its pre-cut snapshot",
        portions(host), "2:KNOWN:s4:2px:x1:64:64:N10,2:KNOWN:s4:2px:x1:65:64:N20")
    g_SoilFertilityManager = nil
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("L2 with Soil absent the same strip is one portion, and no snapshot is invented", portions(host), "4:KNOWN:s4:4px:x1")
    g_SoilFertilityManager = soilStub(2, false)
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("L3 with Soil present but unreadable, likewise", portions(host), "4:KNOWN:s4:4px:x1")
    g_SoilFertilityManager = nil
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B, R, E. REFUSALS: one UNKNOWN portion that says why, and the cut still born
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_PLANE.bias = 1
    ENGINE_HARVEST_TICK(header, combine, 16)
    ENGINE_PLANE.bias = 0
    T.eq("B1 [world] the native reported 5 for 4 transitioned pixels", num(combine:getFillUnitFillLevel(1)), "5")
    T.eq("B2 so the profile is refused for that call: one UNKNOWN portion, never a guessed split", portions(host), "5:UNKNOWN:CUT_STATE_BASIS_MISMATCH")
    T.eq("B3 and the cut is still one birth of the 5 L", tostring(host.lastHarvest.outcome) .. "/" .. hopperLegs(host, combine), "COMMITTED/w1:5")
    FSBaseMission.delete(m)
end)

group("R", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    local desc = g_fruitTypeManager:getFruitTypeByIndex(WHEAT_FRUIT)
    local saved = desc.harvestTransitions[3]
    desc.harvestTransitions[3] = 4   -- state 3 would be cut to 4, which is itself cut
    ENGINE_HARVEST_TICK(header, combine, 16)
    desc.harvestTransitions[3] = saved
    T.eq("R1 a harvest target that is itself harvestable could be recut in one call: one UNKNOWN portion", portions(host), "4:UNKNOWN:RECUT_POSSIBLE")
    FSBaseMission.delete(m)
end)

-- FruitTypeDesc.lua:219-224 writes a yieldScales entry per harvest-ready state only, so a
-- forage-only state has none; getYieldScale's `or 1` (:800-801) is not evidence (SG-2 :495).
group("Y", function()
    local m, host, combine, header = boot(function()
        ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 2, 1, 4)
        ENGINE_PLANE.sow(WHEAT_FRUIT, 2, 0, 4, 1, 3)
    end)
    local desc = g_fruitTypeManager:getFruitTypeByIndex(WHEAT_FRUIT)
    local saved = desc.yieldScales[3]
    desc.yieldScales[3] = nil
    ENGINE_HARVEST_TICK(header, combine, 16)
    desc.yieldScales[3] = saved
    T.eq("Y1 [world] the native scaled the entry-less state by its default of 1: 4 L", num(combine:getFillUnitFillLevel(1)), "4")
    T.eq("Y2 a source state with no yieldScales entry refuses the call, though the default would have matched the native's total",
        portions(host), "4:UNKNOWN:YIELD_SCALE_UNAVAILABLE")
    FSBaseMission.delete(m)
end)

group("E", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    local saved = CS.MAX_PIXELS
    CS.MAX_PIXELS = 4
    ENGINE_HARVEST_TICK(header, combine, 16)
    CS.MAX_PIXELS = saved
    T.eq("E1 an envelope over the read limit is not read: one UNKNOWN portion", portions(host), "4:UNKNOWN:ENVELOPE_TOO_LARGE")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. ANOTHER FRUIT'S PIXEL
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m, host, combine, header = boot(function()
        ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
        ENGINE_PLANE.sow(BARLEY_FRUIT, 1, 0, 2, 1, 4)
    end)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("F1 [world] the wheat cut took its three pixels and left the barley one", tostring(ENGINE_PLANE.state(BARLEY_FRUIT, 1, 0)) .. "/" .. num(combine:getFillUnitFillLevel(1)), "4/3")
    T.eq("F2 and the barley pixel is no source of it", portions(host), "3:KNOWN:s4:3px:x1")
    -- A ripe wheat pixel just past the strip: inside the read margin, outside the cut.
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_PLANE.sow(WHEAT_FRUIT, 4, 0, 5, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("F3 a ripe pixel read in the margin but left standing by the cut is no source", tostring(ENGINE_PLANE.state(WHEAT_FRUIT, 4, 0)) .. "/" .. portions(host), "4/4:KNOWN:s4:4px:x1")
    -- A header that tries barley first: that call cuts nothing and is no source.
    header.spec_cutter.fruitTypeIndices = { BARLEY_FRUIT, WHEAT_FRUIT }
    header.spec_cutter.workAreaParameters.lastFruitType = nil
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("F4 a header that tries barley before cutting wheat: the zero-area barley call is no source", portions(host), "4:KNOWN:s4:4px:x1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. A NATIVE ERROR INSIDE THE CUT
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_PLANE.throwNext = true
    local refused = CS.stats.refused["CUT_STATE_BASIS_MISMATCH"] or 0
    local ok, err = pcall(ENGINE_HARVEST_TICK, header, combine, 16)
    T.eq("X1 a native error inside cutFruitArea reaches the engine unchanged, and no cutter call is left active",
        tostring(ok) .. "/" .. tostring(tostring(err):find("native cut failed", 1, true) ~= nil) .. "/" .. tostring(HC.activeEntry), "false/true/nil")
    T.eq("X2 and no refusal is counted against a cut that never happened", (CS.stats.refused["CUT_STATE_BASIS_MISMATCH"] or 0) - refused, 0)
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. OUTSIDE A CUTTER CALL
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    local calls = CS.stats.calls
    local area = FSDensityMapUtil.cutFruitArea(WHEAT_FRUIT, 0, 0, 4, 0, 0, 1, true, false, nil)
    T.eq("O1 a cutFruitArea call no cutter makes is the native's alone: it cut, and nothing was read around it", num(area) .. "/" .. tostring(CS.stats.calls - calls), "4/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE IN-GAME EVIDENCE
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    local lines = {}
    local realPrint = print
    print = function(s) lines[#lines + 1] = tostring(s) realPrint(s) end
    CS.logged = {}
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_HARVEST_TICK(header, combine, 16)
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    ENGINE_PLANE.bias = 1
    for _ = 1, 2 do
        ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
        ENGINE_HARVEST_TICK(header, combine, 16)
    end
    ENGINE_PLANE.bias = 0
    -- A second refusal reason, twice as well.
    local saved = CS.MAX_PIXELS
    CS.MAX_PIXELS = 4
    for _ = 1, 2 do
        ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
        ENGINE_HARVEST_TICK(header, combine, 16)
    end
    CS.MAX_PIXELS = saved
    print = realPrint
    local admitted, refused, envelope = 0, 0, 0
    for _, l in ipairs(lines) do
        if l:find("FIRST CUT_STATE_VOLUME_V1 CUT ADMITTED", 1, true) then admitted = admitted + 1 end
        if l:find("CUT_STATE_VOLUME_V1 refused a cut (CUT_STATE_BASIS_MISMATCH), observed 4 against native 5", 1, true) then refused = refused + 1 end
        if l:find("CUT_STATE_VOLUME_V1 refused a cut (ENVELOPE_TOO_LARGE)", 1, true) then envelope = envelope + 1 end
    end
    T.eq("G1 the first admitted cut says so once in log.txt, over two admitted frames", admitted, 1)
    T.eq("G2 a refusal says so once per reason with both totals, over two refused frames", refused, 1)
    T.eq("G3 a second reason gets its own once-only line", envelope, 1)
    FSBaseMission.delete(m)
end)
