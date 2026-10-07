-- SG3-2-1-grading_core_spec_test.lua
--
-- SG-3 Part 2.1 (SG-3 v1.2 build brief; Bob's SG-3 intake of 2026-10-06, Part 2; Desk's option B
-- split): the grading core and the harvest. qualityBasisV1 is born in the cutter's settle from the
-- cut's own evidence portions (SGHarvestCapture, SGCutState with U4's frozen RAW_MATURITY_V1 inputs),
-- carried by SG-1's combine, and read through sg3.assessments and assessMaterialUse, which call the
-- one pure evaluateUse. The player projection is LOCKED and the raw property is never disclosed.
--
-- THE ENTRY-POINT BAR IS GROUP S. As SG2-3b's: the engine models, then main.lua's modules and
-- main.lua; the mission through main's appends; a combine and header in the vehicle list at the
-- barrier; every frame in the engine's order. SG-3 is installed only by main.lua's native kernel
-- install; the fruit descriptor carries its own state tables and yield scales; Soil is reachable only
-- as the mission handle. Nothing here publishes a property, pre-fills a quality record, a catalogue or
-- a maturity class: the tank's qualityBasisV1 exists only because the settle asked SG-3's producer.
--
-- Groups:
--   S  the entry-point bar: the hopper's pair from the brief's formulas, Food and Feed B, the straw
--      Feed-only, the view withholds both properties, a second frame's UPDATE keeps one pair
--   N  the numbers: the 23 reasons, the calibration rows and aliases, pH, bands at their boundaries,
--      the unknown floor (500 L at 80 beside 500 L unknown has no score), a known mix averages
--   M  RAW_MATURITY_V1 through the real cut: withered, forage-ready, harvestable non-ready, a cut
--      state, missing descriptor tables; Soil absent or with no grain; grass precedence
--   F  the unknown floor through the real path: a known frame then a Soil-less frame, one hopper
--   D  a delay slot's drain: SG-1's combine carries the pair into the hopper unchanged
--   G  nativePath gating (Bob, 2026-10-07): only COMBINE_CUT is graded (and, since Part 2.2, the Mower's
--      GROUND_MOWER_CUT: SG3-2-2-mower_chain_spec_test.lua); any other birth is a named unknown, never
--      graded and never a throw; a refused cut profile is SOURCE_PARTIAL
--   T  the two native transforms keep the pair and make Feed-only; any other basis is unavailable
--   B  a bale needing SOIL_BALE_CONDITION_V1 (Part 3) is UNAVAILABLE with a historical letter
--   V  validate refuses a malformed payload
--   U  the handle (no third-party registration), the member's registerUseProfile, assessMaterialUse
--   A  revisions: stable while the inputs hold, advanced by a new birth; never the key itself
--   L  the lifecycle: a client installs nothing, the mission's end clears the member
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/sg3/SG3Profiles.lua, src/sg3/SG3Evaluator.lua, src/sg3/SG3Quality.lua, src/sg3/SG3Assessments.lua, src/sg3/SG3.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local NH, NA, HC, CS = SGNativeHost, SGNativeAdapters, SGHarvestCapture, SGCutState
local P, E, Q = SG3Profiles, SG3Evaluator, SG3Quality
local WHEAT_FRUIT = ENGINE_FRUIT.WHEAT
local QB = "qualityBasisV1"

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

-- ── the world (as SG2-3b's) ─────────────────────────────────────────────────
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

-- Shaped on SoilFertilityManager:getSoilValueAtWorld (as SG2-3b's L group): a value and Soil's grain.
-- Published as g_currentMission.soilFertilityManager (SoilFertilizer main.lua:761), the only route.
local function soilStub(values, grain)
    return { getSoilValueAtWorld = function(_, key, x, z) return values[key], grain end }
end
-- Wheat's row is N 35/55, P 25/40, K 25/40: N 45 fits .5, P 40 fits 1, K 25 fits 0, so npkFit 50;
-- pH 6.5 is the optimum 100; agronomyFit = .75 x 50 + .25 x 100 = 62.5 (:180).
local SOIL = { nitrogen = 45, phosphorus = 40, potassium = 25, pH = 6.5 }

--- One combine with a one-area header over x 0..4, z 0..1, booted through main.lua.
local function boot(sow, opts)
    ENGINE_PLANE.cells = {}
    ENGINE_PLANE.bias = 0
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local combine = ENGINE_NEW_COMBINE("vehicle:combine", opts)
    local header = ENGINE_NEW_HEADER("vehicle:header", combine, { areas = 1, width = 4, depth = 1 })
    m._vehicles[1], m._vehicles[2] = combine, header
    sow()
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    m.soilFertilityManager = soilStub(SOIL, 2)
    return m, NH.current, combine, header
end

-- ── readers: everything through SG-1's own read, by a consumer of the bench's own ──────────────
local function cid(binding) return binding and SGRecords.carrierKeyString(binding.carrierKey) or nil end
local function sgOf(m) return StockGuard.hostOf(m) end
local function refOf(m, binding)
    local ops = sgOf(m).operations
    local c = ops.carriers[cid(binding)]
    local s = c ~= nil and c.stockId ~= nil and ops.stocks[c.stockId] or nil
    return s ~= nil and ops:stockRef(s) or nil
end
local function hopperRef(m, combine) return refOf(m, NA.fillUnitBinding(combine, 1)) end
local function strawRef(m, combine) return refOf(m, NA.combineSlotBinding(combine, NA.KIND_STRAW_SLOT, 1)) end

local readers = {}
local function reader(m)
    if readers[m] == nil then
        readers[m] = m.stockGuard.registerConsumer("bench.reader", { version = 1, requiredSchemas = { [QB] = 1, ["sg3.assessments"] = 1 },
            materialKinds = { "FILL_TYPE", "NATIVE_GROUP" }, resolveReadContext = function(q) return { stockRefs = q.stockRefs, purpose = "BENCH" } end })
    end
    return readers[m]
end
local function read(m, ref, pid)
    local res = m.stockGuard.readMaterial(reader(m), { stockRefs = { ref }, propertyIds = { pid } })
    local rec = res and res.records and res.records[1] or nil
    return rec and rec.properties and rec.properties[pid] or nil, rec
end

local function mask(u)
    if type(u) ~= "table" then return "?" end
    return num(u.eligibleFraction) .. "/" .. num(u.ineligibleFraction) .. "/" .. num(u.unknownFraction) .. "[" .. table.concat(u.reasons or {}, " ") .. "]"
end
--- A quality record as "KNOWLEDGE known/basis eE rR crop/cal/material food <mask> feed <mask>",
--- or "UNAVAILABLE:<reason>".
local function fq(q)
    if type(q) ~= "table" then return "none" end
    if q.knowledge == "UNAVAILABLE" then return "UNAVAILABLE:" .. tostring(q.reason) end
    local pl = q.payload or {}
    local w = pl.sourceWitness or {}
    local ou = w.originUse or {}
    local mat = type(w.nativeSourceMaterial) == "table" and w.nativeSourceMaterial.fillTypeName or "-"
    local s = tostring(q.knowledge) .. " " .. num(q.knownAmount) .. "/" .. num(q.basisAmount) .. " e" .. num(pl.earnedScore) .. " r" .. num(pl.remainingScore)
        .. " " .. tostring(w.cropKey or "-") .. "/" .. tostring(w.calibrationKey or "-") .. "/" .. mat .. " food " .. mask(ou.FOOD) .. " feed " .. mask(ou.FEED)
    if type(w.lastTransform) == "table" then s = s .. " last " .. tostring(w.lastTransform.profileId) end
    return s
end
--- A Result as "STATE KNOWLEDGE SUITABILITY grade score [reasons]" with " h:<grade>/<score>".
local function fr(r)
    if type(r) ~= "table" then return "none" end
    local s = tostring(r.state) .. " " .. tostring(r.knowledge) .. " " .. tostring(r.suitability) .. " " .. tostring(r.grade or "-") .. " " .. num(r.remainingScore or "-")
        .. " [" .. table.concat(r.reasons or {}, " ") .. "]"
    if type(r.historical) == "table" then s = s .. " h:" .. tostring(r.historical.grade or "-") .. "/" .. num(r.historical.remainingScore) end
    return s
end
local function assess(m, ref)
    local a = read(m, ref, "sg3.assessments")
    local pl = a and a.payload or {}
    return fr(pl.food) .. " | " .. fr(pl.feed), a
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    local h = m.stockGuard
    local rd = h.sg3 ~= nil and h.sg3.getReadiness() or {}
    local profiles = {}
    for _, p in ipairs(rd.useProfiles or {}) do profiles[#profiles + 1] = p.id .. ":" .. p.use end
    T.eq("S1 [reached] main.lua's native kernel install installed SG-3 on the mission handle: ready, both crop profiles, the player projection LOCKED",
        tostring(rd.ready) .. "/" .. table.concat(profiles, ",") .. "/" .. tostring(rd.playerProjection), "true/CROP_FEED_V1:FEED,CROP_FOOD_V1:FOOD/LOCKED")
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("S2 [world] the frame harvested 4 L of ripe wheat into the hopper", num(combine:getFillUnitFillLevel(1)), "4")
    local ref = hopperRef(m, combine)
    local q = read(m, ref, QB)
    -- earned = .60 x 62.5 + .40 x 100 (HARVEST_READY) = 77.5; new output remaining = earned (:198).
    T.eq("S3 the hopper's qualityBasisV1 was born in the cut's settle: the brief's pair 77.5/77.5, wheat's own primary output, Food and Feed eligible",
        fq(q), "KNOWN 4/4 e77.5 r77.5 wheat/wheat/WHEAT food 1/0/0[] feed 1/0/0[]")
    T.eq("S4 sg3.assessments reads it through SG-3's own consumer: Food B (70 <= 77.5 < 85), Feed B (60 <= 77.5 < 80)",
        (assess(m, ref)), "READY KNOWN SUITABLE B 77.5 [] | READY KNOWN SUITABLE B 77.5 []")
    local food = h.sg3.assessMaterialUse(reader(m), { stockRefs = { ref } }, "FOOD", "CROP_FOOD_V1")
    local feed = h.sg3.assessMaterialUse(reader(m), { stockRefs = { ref } }, "FEED", "CROP_FEED_V1")
    T.eq("S5 assessMaterialUse, through the caller's own consumer, is the same evaluator's answer (:386)", fr(food) .. " | " .. fr(feed), (assess(m, ref)))
    T.eq("S5b and it names the stock and the property revision it read",
        tostring(food.stockRefs[1] and food.stockRefs[1].stockId == ref.stockId) .. "/" .. tostring(food.propertyRevisions[1] and food.propertyRevisions[1].propertyId), "true/qualityBasisV1")
    local sref = strawRef(m, combine)
    T.eq("S6 the same cut's straw carries the cereal's pair, Feed only: straw is never Food-grain (:202)",
        fq((read(m, sref, QB))), "KNOWN 4/4 e77.5 r77.5 wheat/wheat/STRAW food 0/1/0[FOOD_ORIGIN_INELIGIBLE] feed 1/0/0[]")
    T.eq("S6b its assessment: Food UNSUITABLE with no letter, Feed B", (assess(m, sref)),
        "READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 77.5 []")
    -- The player's view: SG-1 asks each property's disclosure; both answer DISCLOSURE_DENIED (:88, :354).
    local page = h.getManagementView({ farmId = 1, userId = "host", actorState = "RESOLVED", connectionId = "local" }, { route = "STOCK", selectionKind = "FARM" })
    local seen, rows = {}, 0
    for _, row in ipairs(page and page.view and page.view.rows or {}) do
        if row.rowKind == "STOCK" then
            rows = rows + 1
            for _, p in ipairs(row.properties or {}) do seen[#seen + 1] = p.propertyId end
        end
    end
    T.eq("S7 the player view lists the stocks and no child of either SG-3 property: the raw record is never disclosed and the assessment is LOCKED",
        tostring(rows >= 2) .. "/" .. table.concat(seen, ","), "true/")
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    T.eq("S8 a second frame into the same hopper is an UPDATE birth: one pair over the 8 L, unchanged",
        fq((read(m, hopperRef(m, combine), QB))), "KNOWN 8/8 e77.5 r77.5 wheat/wheat/WHEAT food 1/0/0[] feed 1/0/0[]")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE NUMBERS (pure)
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local seen, dup = {}, 0
    for _, code in ipairs(P.REASONS) do if seen[code] then dup = dup + 1 end seen[code] = true end
    T.eq("N1 the finite reason vocabulary is the brief's 23 codes, each once (:409)", #P.REASONS .. "/" .. dup, "23/0")
    local function crop(name) local row, key = P.cropOf(name) return row and (row.key .. ":" .. key) or "nil" end
    T.eq("N2 the calibration table: 18 rows; aliases resolve to their row, a base native crop keeps its own key, an unlisted crop is unsupported",
        #P.CALIBRATION .. "/" .. crop("OATS") .. "/" .. crop("alfalfa") .. "/" .. crop("MEADOW") .. "/" .. crop("beetRoot") .. "/" .. crop("cotton"),
        "18/oat:oat/luzerne:luzerne/grass:grass/BASE_NATIVE_CROP_V1:beetroot/nil")
    local ph = {}
    for _, v in ipairs({ 4.5, 5.0, 5.75, 6.5, 7.0, 7.5, 8.0 }) do ph[#ph + 1] = num(E.phFit(v)) end
    T.eq("N3 pH fit: 100 at 6.5, linear to 0 at 5.0 and 7.5, clamped beyond (:180)", table.concat(ph, ","), "0,0,50,100,50,0,0")
    local g = {}
    for _, s in ipairs({ 85, 84.9999, 70, 69.9999, 0 }) do g[#g + 1] = E.grade("FOOD", s) end
    for _, s in ipairs({ 80, 79.9999, 60, 59.9999 }) do g[#g + 1] = E.grade("FEED", s) end
    T.eq("N4 bands on remainingScore, unrounded at every boundary: Food 85/70, Feed 80/60 (:306)", table.concat(g, ","), "A,B,B,C,C,A,B,B,C")
    local wheat = P.cropOf("wheat")
    local a = E.agronomyFit(wheat, SOIL)
    T.eq("N5 wheat at N45 P40 K25 pH6.5: agronomy 62.5; earned with maturity 100, 45 and 20",
        num(a) .. "/" .. num(E.earned(a, 100)) .. "/" .. num(E.earned(a, 45)) .. "/" .. num(E.earned(a, 20)), "62.5/77.5/55.5/45.5")
    -- N 80 is past its optimum (fit 1, not 2.25), P 10 below its minimum (fit 0, not -1): npk 66.67, so 75.
    T.eq("N5c each nutrient's fit is clamped to 0..1 beyond its minimum and optimum (:151)",
        num(E.agronomyFit(wheat, { nitrogen = 80, phosphorus = 10, potassium = 40, pH = 6.5 })), "75")
    T.eq("N5b a missing or non-finite local input is no fit at all, never a zero", tostring(E.agronomyFit(wheat, { nitrogen = 45, phosphorus = 40, potassium = 25 })) .. "/" .. tostring(E.agronomyFit(wheat, { nitrogen = 0 / 0, phosphorus = 40, potassium = 25, pH = 6.5 })), "nil/nil")
    local known = { amount = 500, earned = 80, remaining = 80, use = { FOOD = { eligible = 1, ineligible = 0, unknown = 0, reasons = {} }, FEED = { eligible = 1, ineligible = 0, unknown = 0, reasons = {} } } }
    local unknown = { amount = 500, use = { FOOD = { eligible = 1, ineligible = 0, unknown = 0, reasons = { "SOIL_UNAVAILABLE" } }, FEED = { eligible = 1, ineligible = 0, unknown = 0, reasons = { "SOIL_UNAVAILABLE" } } } }
    local floor = E.combine({ known, unknown }, 1000, nil)
    T.eq("N6 the unknown floor: 500 L at 80 beside 500 L of unknown quality has no whole score, never 40; half its basis known (:51)",
        tostring(floor.payload.earnedScore) .. "/" .. tostring(floor.payload.remainingScore) .. "/" .. floor.knowledge .. "/" .. num(floor.knownAmount), "nil/nil/PARTIAL/500")
    local other = { amount = 500, earned = 60, remaining = 50, use = known.use }
    local mix = E.combine({ known, other }, 1000, nil)
    T.eq("N7 two known portions combine by quantity, earned and remaining separately", num(mix.payload.earnedScore) .. "/" .. num(mix.payload.remainingScore) .. "/" .. mix.knowledge, "70/65/KNOWN")
    local foodOnly = { amount = 250, earned = 90, remaining = 90, use = { FOOD = { eligible = 0, ineligible = 1, unknown = 0, reasons = { "FOOD_ORIGIN_INELIGIBLE" } }, FEED = known.use.FEED } }
    local masks = E.combine({ known, foodOnly }, 750, nil).payload.sourceWitness.originUse
    T.eq("N8 eligibility fractions weigh by quantity, reasons are the union", mask(masks.FOOD) .. " " .. mask(masks.FEED), "0.6667/0.3333/0[FOOD_ORIGIN_INELIGIBLE] 1/0/0[]")
    local function with(fields) local e = SGValues.copy(known) for k, v in pairs(fields) do e[k] = v end return e end
    local same = E.combine({ with({ cropKey = "wheat" }), with({ cropKey = "wheat" }) }, 1000, nil).payload.sourceWitness
    local mixed = E.combine({ with({ cropKey = "wheat" }), with({ cropKey = "barley" }) }, 1000, nil).payload.sourceWitness
    T.eq("N9 a crop survives a combine only when every positive source names the same one (:238)", tostring(same.cropKey) .. "/" .. tostring(mixed.cropKey), "wheat/nil")
    local hay = { profileId = "NATIVE_HAY_CONVERT_V1", profileRevision = "1" }
    local one = E.combine({ with({ lastTransform = hay }) }, 500, nil).payload.sourceWitness
    local two = E.combine({ with({ lastTransform = hay }), known }, 1000, nil).payload.sourceWitness
    T.eq("N10 one source keeps its lastTransform; a plain combine of several omits it (:240)",
        tostring(one.lastTransform and one.lastTransform.profileId) .. "/" .. tostring(two.lastTransform), "NATIVE_HAY_CONVERT_V1/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. RAW_MATURITY_V1 THROUGH THE REAL CUT
-- ══════════════════════════════════════════════════════════════════════════
--- One frame over four ripe (state 4) pixels with `change` applied to the engine's own descriptor,
--- restored after. Returns the hopper's record and its assessment.
local function cutWith(change, soil)
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    if soil ~= nil then m.soilFertilityManager = soil.handle end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(WHEAT_FRUIT)
    local saved = {}
    for k, v in pairs(desc) do saved[k] = v end
    if change ~= nil then change(desc) end
    local ok, err = pcall(ENGINE_HARVEST_TICK, header, combine, 16)
    for k in pairs(desc) do desc[k] = nil end
    for k, v in pairs(saved) do desc[k] = v end
    if not ok then error(err, 0) end
    local ref = hopperRef(m, combine)
    local q = read(m, ref, QB)
    local a = assess(m, ref)
    FSBaseMission.delete(m)
    return fq(q), a
end

group("M", function()
    local q, a = cutWith(function(d) d.witheredState = 4 end)
    T.eq("M1 a withered state: maturity 20, so earned 45.5; Food-ineligible", q, "KNOWN 4/4 e45.5 r45.5 wheat/wheat/WHEAT food 0/1/0[FOOD_ORIGIN_INELIGIBLE] feed 1/0/0[]")
    T.eq("M1b Food UNSUITABLE, Feed C (45.5 < 60)", a, "READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE C 45.5 []")
    q, a = cutWith(function(d) d.harvestReadyTransitions = { [3] = 6 } end)
    T.eq("M2 not harvest-ready but inside the forage interval: FORAGE_READY, maturity 100, Food-ineligible",
        q .. " | " .. a, "KNOWN 4/4 e77.5 r77.5 wheat/wheat/WHEAT food 0/1/0[FOOD_ORIGIN_INELIGIBLE] feed 1/0/0[] | READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 77.5 []")
    q = cutWith(function(d) d.harvestReadyTransitions = { [3] = 6 } d.minForageGrowthState = 0 d.maxForageGrowthState = 0 end)
    T.eq("M3 harvestable but neither ready nor forage: HARVESTABLE_NONREADY, maturity 45, earned 55.5", q,
        "KNOWN 4/4 e55.5 r55.5 wheat/wheat/WHEAT food 0/1/0[FOOD_ORIGIN_INELIGIBLE] feed 1/0/0[]")
    q, a = cutWith(function(d) d.cutStates = { [4] = true, [6] = true } end)
    T.eq("M4 a cut state is UNSUPPORTED: no maturity, so the portion is unknown and nothing is graded", q .. " | " .. a,
        "UNAVAILABLE:MATURITY_UNAVAILABLE | READY UNKNOWN UNKNOWN - - [MATURITY_UNAVAILABLE] | READY UNKNOWN UNKNOWN - - [MATURITY_UNAVAILABLE]")
    q = cutWith(function(d) d.growthStateToName = nil end)
    T.eq("M5 a descriptor missing a required table freezes nothing: unknown, never a guessed class", q, "UNAVAILABLE:MATURITY_UNAVAILABLE")
    q = cutWith(function(d) d.growthStateToName = { "sown", "germinated", "ripening" } end)
    T.eq("M5b an unmapped state (no name) is UNSUPPORTED", q, "UNAVAILABLE:MATURITY_UNAVAILABLE")
    q, a = cutWith(nil, { handle = nil })
    T.eq("M6 Soil absent: the portion's scores are unknown, its eligibility is not", q,
        "UNKNOWN 0/4 enil rnil wheat/wheat/WHEAT food 1/0/0[SOIL_UNAVAILABLE] feed 1/0/0[SOIL_UNAVAILABLE]")
    T.eq("M6b so no letter for either use, and the reason says why", a,
        "READY UNKNOWN SUITABLE - - [SOIL_UNAVAILABLE QUALITY_PARTIAL] | READY UNKNOWN SUITABLE - - [SOIL_UNAVAILABLE QUALITY_PARTIAL]")
    q = cutWith(nil, { handle = soilStub(SOIL, nil) })
    T.eq("M7 Soil values with no grain are no local input (:153)", q,
        "UNKNOWN 0/4 enil rnil wheat/wheat/WHEAT food 1/0/0[SOIL_UNAVAILABLE] feed 1/0/0[SOIL_UNAVAILABLE]")
    local both = { valid = true, stateName = "harvestReady", harvestReady = true, withered = true }
    T.eq("M8 GRASS_QUALITY_V1: a named harvestReady state that is also withered is HARVEST_READY; any other crop reads WITHERED (:194, :204)",
        tostring(E.classify(both, "GRASS_QUALITY_V1")) .. "/" .. tostring(E.classify(both, nil)) .. "/" .. tostring(E.classify({ valid = true, stateName = "greenMiddle", harvestReady = false, withered = true }, "GRASS_QUALITY_V1")),
        "HARVEST_READY/WITHERED/WITHERED")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE UNKNOWN FLOOR THROUGH THE REAL PATH
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_HARVEST_TICK(header, combine, 16)
    m.soilFertilityManager = nil
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    local ref = hopperRef(m, combine)
    T.eq("F1 4 L at 77.5 then 4 L with Soil absent: half the basis known and no whole score",
        fq((read(m, ref, QB))), "PARTIAL 4/8 enil rnil wheat/wheat/WHEAT food 1/0/0[SOIL_UNAVAILABLE] feed 1/0/0[SOIL_UNAVAILABLE]")
    T.eq("F2 so no letter: READY PARTIAL, suitable, QUALITY_PARTIAL", (assess(m, ref)),
        "READY PARTIAL SUITABLE - - [SOIL_UNAVAILABLE QUALITY_PARTIAL] | READY PARTIAL SUITABLE - - [SOIL_UNAVAILABLE QUALITY_PARTIAL]")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A DELAY SLOT'S DRAIN: SG-1's combine carries the pair
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end, { loadingDelay = 100 })
    ENGINE_HARVEST_TICK(header, combine, 16)
    local slotRef = refOf(m, NA.combineSlotBinding(combine, NA.KIND_DELAY_SLOT, 1))
    T.eq("D1 the cut is born into the delay slot with its pair", fq((read(m, slotRef, QB))), "KNOWN 4/4 e77.5 r77.5 wheat/wheat/WHEAT food 1/0/0[] feed 1/0/0[]")
    ENGINE_HARVEST_TICK(nil, combine, 200)
    T.eq("D2 [world] the slot drained into the hopper", num(combine:getFillUnitFillLevel(1)), "4")
    T.eq("D3 the TRANSFER's combine carries the pair unchanged; one source keeps its material", fq((read(m, hopperRef(m, combine), QB))),
        "KNOWN 4/4 e77.5 r77.5 wheat/wheat/WHEAT food 1/0/0[] feed 1/0/0[]")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. nativePath GATING
-- ══════════════════════════════════════════════════════════════════════════
--- A detached birth context as SG-1 builds it (SGOperations interpretDestination): one slot
--- contribution born into one candidate, with outcomeEvidence as the native path reported it.
local function birthContext(evidence)
    local portion = { slotId = "s1", knowledge = "KNOWN", fruitName = "WHEAT", primaryFillTypeName = "WHEAT", soilCell = "64:64", soil = SOIL,
        maturity = { valid = true, stateName = "harvestReady", harvestReady = true, harvestable = true } }
    if evidence ~= nil and evidence.portions == true then evidence.portions = { portion } end
    local ctx = { allocations = { { allocationRef = "a1", destination = { carrierId = "c1" } } }, candidates = {}, report = { outcomeEvidence = evidence } }
    local inputs = { { allocationRef = "a1", slotId = "s1", amount = 10 } }
    local outputs = { { carrierId = "c1", amount = 10, unit = "LITRE", materialRef = { kind = "FILL_TYPE", fillTypeName = "WHEAT" } } }
    return ctx, inputs, outputs
end

group("G", function()
    local graded = select(1, Q.transform(birthContext({ nativePath = "COMBINE_CUT", portions = true })))
    T.eq("G1 the cutter's path grades its evidence portion", tostring(graded and graded.payload.earnedScore), "77.5")
    local out = {}
    for _, path in ipairs({ "MOWER_CUT", "WINDROWER", "TEDDER_DROP", "BALER_PICKUP" }) do
        local r, why = Q.transform(birthContext({ nativePath = path, portions = true }))
        out[#out + 1] = path .. "=" .. tostring(r) .. ":" .. tostring(why)
    end
    -- MOWER_CUT is no native path; the Mower's own, GROUND_MOWER_CUT, is graded since Part 2.2 (SG3-2-2's M).
    T.eq("G2 every other path is the named unknown ORIGIN_UNPROVEN even with a full portion: never graded",
        table.concat(out, ","), "MOWER_CUT=nil:ORIGIN_UNPROVEN,WINDROWER=nil:ORIGIN_UNPROVEN,TEDDER_DROP=nil:ORIGIN_UNPROVEN,BALER_PICKUP=nil:ORIGIN_UNPROVEN")
    local raised = {}
    local junk = { nil, {}, { nativePath = "COMBINE_CUT" }, { nativePath = "COMBINE_CUT", portions = "x" }, { nativePath = "COMBINE_CUT", portions = { 7, { slotId = "s1" } } },
                   { nativePath = 3, portions = true } }
    for i = 1, 6 do
        local ctx, inputs, outputs = birthContext(junk[i])
        if i == 1 then ctx.report = nil end
        local ok, r, why = pcall(Q.transform, ctx, inputs, outputs)
        raised[#raised + 1] = tostring(ok) .. ":" .. tostring(r ~= nil and r.knowledge or why)
    end
    T.eq("G3 malformed or missing evidence never throws (no TRANSFORM_ERROR) and never grades: a named unknown each time",
        table.concat(raised, ","), "true:ORIGIN_UNPROVEN,true:ORIGIN_UNPROVEN,true:SOURCE_PARTIAL,true:SOURCE_PARTIAL,true:SOURCE_PARTIAL,true:ORIGIN_UNPROVEN")
    -- Through the real cut: a profile refusal leaves the portion UNKNOWN, which grades nothing.
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_PLANE.bias = 1
    ENGINE_HARVEST_TICK(header, combine, 16)
    ENGINE_PLANE.bias = 0
    local ref = hopperRef(m, combine)
    T.eq("G4 a cut whose CUT_STATE_VOLUME_V1 reading was refused is SOURCE_PARTIAL, never a guessed grade",
        fq((read(m, ref, QB))) .. " | " .. (assess(m, ref)), "UNAVAILABLE:SOURCE_PARTIAL | READY UNKNOWN UNKNOWN - - [SOURCE_PARTIAL] | READY UNKNOWN UNKNOWN - - [SOURCE_PARTIAL]")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. THE NATIVE TRANSFORMS
-- ══════════════════════════════════════════════════════════════════════════
local function carried(basis, record)
    local ctx = { allocations = {}, candidates = {}, report = { outcomeEvidence = { nativePath = "TEDDER_DROP" } } }
    local inputs = { { allocationRef = "a1", amount = 10, conversionBasisId = basis, properties = { [QB] = record } } }
    local outputs = { { carrierId = "c1", amount = 10, unit = "LITRE", materialRef = { kind = "FILL_TYPE", fillTypeName = "DRYGRASS_WINDROW" } } }
    return ctx, inputs, outputs
end

group("T", function()
    local born = Q.transform(birthContext({ nativePath = "COMBINE_CUT", portions = true }))
    local hay = Q.transform(carried("NATIVE_HAY_CONVERT_V1", born))
    T.eq("T1 NATIVE_HAY_CONVERT_V1 keeps the pair, makes the output Feed-only and records lastTransform (:240, :263)", fq(hay),
        "KNOWN 10/10 e77.5 r77.5 wheat/wheat/WHEAT food 0/1/0[FOOD_ORIGIN_INELIGIBLE] feed 1/0/0[] last NATIVE_HAY_CONVERT_V1")
    T.eq("T2 NATIVE_BALE_FEED_V1 likewise (:267)", fq((Q.transform(carried("NATIVE_BALE_FEED_V1", born)))),
        "KNOWN 10/10 e77.5 r77.5 wheat/wheat/WHEAT food 0/1/0[FOOD_ORIGIN_INELIGIBLE] feed 1/0/0[] last NATIVE_BALE_FEED_V1")
    local r, why = Q.transform(carried("NATIVE_PIGFOOD_V1", born))
    local ctx, inputs, outputs = carried("NATIVE_HAY_CONVERT_V1", born)
    inputs[2] = { allocationRef = "a2", amount = 5, conversionBasisId = "NATIVE_BALE_FEED_V1", properties = { [QB] = born } }
    local r2, why2 = Q.transform(ctx, inputs, outputs)
    T.eq("T3 any other basis, or two bases at once, is unavailable, never guessed", tostring(r) .. ":" .. tostring(why) .. "/" .. tostring(r2) .. ":" .. tostring(why2),
        "nil:UNSUPPORTED_PROFILE/nil:UNSUPPORTED_PROFILE")
    T.eq("T4 the transformed record passes the producer's own validate", tostring((Q.validate(hay))), "true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A BALE NEEDING SOIL_BALE_CONDITION_V1 (Part 3)
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local born = Q.transform(birthContext({ nativePath = "COMBINE_CUT", portions = true }))
    local straw = Q.transform(carried("NATIVE_HAY_CONVERT_V1", born))
    local member = { materialSupported = function(_, name) return P.FEED_ONLY[name] == true end }
    local function snap(key, name)
        return SG3Assessments.snapshotOf(member, { stockRef = { stockId = "st:1" }, observedAmount = 10, amountUnit = "LITRE", carrierKey = key,
            materialRef = { kind = "FILL_TYPE", fillTypeName = name }, properties = { [QB] = straw } }, 1)
    end
    local baleKey = { adapterId = NA.NATIVE_ADAPTER_ID, componentKey = NA.KIND_BALE }
    local s = snap(baleKey, "STRAW")
    T.eq("B1 a straw bale's current Feed assessment is UNAVAILABLE with CONDITION_UNAVAILABLE, and its recorded pair a historical letter (:254, :388)",
        fr(E.evaluateUse(s, "FEED", "CROP_FEED_V1", "1")), "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_UNAVAILABLE] h:B/77.5")
    T.eq("B2 the same straw in a trailer needs no bale condition", fr(E.evaluateUse(snap({ adapterId = NA.NATIVE_ADAPTER_ID, componentKey = "fillUnit" }, "STRAW"), "FEED", "CROP_FEED_V1", "1")),
        "READY KNOWN SUITABLE B 77.5 []")
    T.eq("B3 the historical letter never names a current Food benefit: Food's recorded origin is ineligible, so no letter",
        fr(E.evaluateUse(s, "FOOD", "CROP_FOOD_V1", "1")), "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [CONDITION_UNAVAILABLE] h:-/77.5")
    -- SG-1 keeps a record HISTORICAL when its producer was absent at a carry (SGOperations interpretDestination).
    local past = SGValues.copy(born)
    past.knowledge = "HISTORICAL"
    local hs = snap({ adapterId = NA.NATIVE_ADAPTER_ID, componentKey = "fillUnit" }, "WHEAT")
    hs.quality, hs.materialSupported = past, true
    T.eq("B4 a HISTORICAL record gives no current grade, only the recorded letter (:388)",
        fr(E.evaluateUse(hs, "FOOD", "CROP_FOOD_V1", "1")), "READY HISTORICAL UNKNOWN - - [QUALITY_HISTORICAL] h:B/77.5")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. validate
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local good = Q.transform(birthContext({ nativePath = "COMBINE_CUT", portions = true }))
    local function bad(edit)
        local r = SGValues.copy(good)
        edit(r.payload)
        local ok, why = Q.validate(r)
        return tostring(ok) .. ":" .. tostring(why)
    end
    T.eq("V1 the born record is valid", tostring((Q.validate(good))), "true")
    T.eq("V2 another profile, remaining above earned, a lone score, fractions not summing to 1, an unknown reason: each refused",
        table.concat({ bad(function(p) p.profileId = "OTHER" end), bad(function(p) p.remainingScore = 90 end), bad(function(p) p.remainingScore = nil end),
            bad(function(p) p.sourceWitness.originUse.FOOD.unknownFraction = 0.5 end), bad(function(p) p.sourceWitness.originUse.FEED.reasons = { "SPOILED" } end) }, ","),
        "false:PROFILE,false:SCORE,false:SCORE_PAIR,false:ORIGIN_USE,false:REASON")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. USE PROFILES
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_HARVEST_TICK(header, combine, 16)
    local sg3 = m.stockGuard.sg3
    local keys = {}
    for k in pairs(sg3) do keys[#keys + 1] = k end
    table.sort(keys)
    T.eq("U0 the handle publishes readiness and assessMaterialUse only: third-party use profiles are WITHHELD (:384; Bob's R-15)",
        table.concat(keys, ",") .. "/" .. tostring(sg3.registerUseProfile), "assessMaterialUse,getReadiness/nil")
    -- The member's own registration, as its install registers the two built-ins.
    local member = SG3.current
    local _, dup = member:registerUseProfile("other", "CROP_FOOD_V1", 1, { use = "FOOD", revision = "1" })
    local _, badDef = member:registerUseProfile("other", "ODD_V1", 1, { use = "FUEL", revision = "1" })
    local lease = member:registerUseProfile("other", "PREMIUM_FOOD_V1", 1, { use = "FOOD", revision = "1" })
    T.eq("U1 the member's registration: a duplicate live id refuses; an unknown use refuses; a well-formed profile registers", tostring(dup) .. "/" .. tostring(badDef) .. "/" .. tostring(lease ~= nil), "DUPLICATE_OWNER/DEFINITION/true")
    local ref = hopperRef(m, combine)
    T.eq("U2 a profile with no interpretation contract in this part: UNSUPPORTED, never a borrowed grade",
        fr(sg3.assessMaterialUse(reader(m), { stockRefs = { ref } }, "FOOD", "PREMIUM_FOOD_V1")), "UNSUPPORTED UNAVAILABLE UNAVAILABLE - - [UNSUPPORTED_PROFILE]")
    T.eq("U3 a profile asked for the wrong use, or an unknown profile, is UNSUPPORTED",
        fr(sg3.assessMaterialUse(reader(m), { stockRefs = { ref } }, "FEED", "CROP_FOOD_V1")) .. " | " .. fr(sg3.assessMaterialUse(reader(m), { stockRefs = { ref } }, "FOOD", "NOPE")),
        "UNSUPPORTED UNAVAILABLE UNAVAILABLE - - [UNSUPPORTED_PROFILE] | UNSUPPORTED UNAVAILABLE UNAVAILABLE - - [UNSUPPORTED_PROFILE]")
    T.eq("U4 a lease that is not a live consumer reads nothing: UNAVAILABLE, DISCLOSURE_DENIED", fr(sg3.assessMaterialUse({}, { stockRefs = { ref } }, "FOOD", "CROP_FOOD_V1")),
        "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [DISCLOSURE_DENIED]")
    local gone = { stockId = "st:none", contentsGeneration = ref.contentsGeneration, dataRevision = ref.dataRevision }
    T.eq("U4b a composite naming a stock that is gone is unavailable, never the remaining stock alone",
        fr(sg3.assessMaterialUse(reader(m), { stockRefs = { ref, gone } }, "FEED", "CROP_FEED_V1")), "UNAVAILABLE UNAVAILABLE UNAVAILABLE - - [SOURCE_CHANGED]")
    -- Two stocks read together are one composite on their summed basis.
    local sref = strawRef(m, combine)
    T.eq("U5 two stocks are one composite: the hopper's grain and the straw together cannot be Food",
        fr(sg3.assessMaterialUse(reader(m), { stockRefs = { ref, sref } }, "FOOD", "CROP_FOOD_V1")) .. " | " .. fr(sg3.assessMaterialUse(reader(m), { stockRefs = { ref, sref } }, "FEED", "CROP_FEED_V1")),
        "READY KNOWN UNSUITABLE - - [FOOD_ORIGIN_INELIGIBLE] | READY KNOWN SUITABLE B 77.5 []")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. REVISIONS
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    local m, host, combine, header = boot(function() ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4) end)
    ENGINE_HARVEST_TICK(header, combine, 16)
    local _, a1 = assess(m, hopperRef(m, combine))
    local _, a2 = assess(m, hopperRef(m, combine))
    T.eq("A1 two reads with unchanged inputs give the same opaque integer revision", tostring(a1.propertyRevision) .. "/" .. tostring(a1.propertyRevision == a2.propertyRevision) .. "/" .. type(a1.propertyRevision), tostring(a1.propertyRevision) .. "/true/number")
    T.eq("A1b and each Result names it as its readRevision", tostring(a1.payload.food.readRevision == a1.propertyRevision), "true")
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    ENGINE_HARVEST_TICK(header, combine, 16)
    local _, a3 = assess(m, hopperRef(m, combine))
    T.eq("A2 a new birth into the stock advances it", tostring(a3.propertyRevision > a1.propertyRevision), "true")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE LIFECYCLE
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local m = boot(function() end)
    local h = m.stockGuard
    T.eq("L1 [reached] installed", tostring(h.sg3 ~= nil and SG3.current ~= nil), "true")
    FSBaseMission.delete(m)
    T.eq("L2 the mission's end clears the member and its handle entry", tostring(h.sg3) .. "/" .. tostring(SG3.current), "nil/nil")
    local server = g_server
    g_server = nil
    local r, why = SG3.install(h)
    g_server = server
    T.eq("L3 a client installs nothing", tostring(r) .. ":" .. tostring(why), "nil:CLIENT")
end)
