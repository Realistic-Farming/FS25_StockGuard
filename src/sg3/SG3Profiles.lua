-- =========================================================
-- FS25_StockGuard - SG-3 profiles: the versioned grading tables (SG-3 Part 2.1)
-- =========================================================
-- SG-3 v1.2 build brief (Office Tyson/StockGuard-First-Family-2026-09-15/implementation/
-- SG-3-BUILD-BRIEF.md). Every number here is the brief's retained starting calibration,
-- approved by Arissani on 2026-09-12 (:488): game design values, not real-world food-quality
-- measurements (:27). SG-3 owns this table (:151): it never reads a SoilConstants global,
-- and a changed rubric is a new profile revision, never a silent change to a saved score.
--
-- PURE DATA. Nothing here reads the game; SG3Evaluator applies it.

SG3Profiles = SG3Profiles or {}
local P = SG3Profiles

P.QUALITY_PROPERTY = "qualityBasisV1"
P.ASSESSMENTS_PROPERTY = "sg3.assessments"
P.INPUTS_CONSUMER = "sg3.assessmentInputs"
P.PRODUCER_ID = "sg3"
P.SCHEMA_VERSION = 1

-- The one saved score profile for every admitted crop or grass pair (:73), and its revision
-- token (:250: revisions are the lossless string "1").
P.SCORE_PROFILE = "LOCAL_AGRONOMY_AT_CUT_V1"
P.REVISION = "1"
P.ORIGIN_KIND = "CROP_DERIVED"   -- :71
P.UNIFORM = "UNIFORM"

-- The use profiles shipped (:244). TMR_FEED_V1 needs NATIVE_TMR_FEED_V1, out of this part.
P.FOOD = "FOOD"
P.FEED = "FEED"
P.FOOD_PROFILE = "CROP_FOOD_V1"
P.FEED_PROFILE = "CROP_FEED_V1"
P.USE_PROFILE_FOR = { FOOD = P.FOOD_PROFILE, FEED = P.FEED_PROFILE }

-- The native transforms this part interprets (:263, :267); any other basis is unavailable.
P.TRANSFORMS = { NATIVE_HAY_CONVERT_V1 = true, NATIVE_BALE_FEED_V1 = true }

-- The native path whose birth this part grades: the cutter's cut (SGHarvestCapture.PATH_CUT).
-- Every other birth (the mower's is 2.2) is a named unknown origin, never graded.
P.GRADED_BIRTH_PATH = "COMBINE_CUT"

-- ── the calibration table (:157-178) ─────────────────────────────────────────
-- key: the row's calibrationKey; names: its admitted names, case normalised; n/p/k: {min, opt}
-- on Soil's internal 0..100 scale; food: CROP_FOOD_V1 admits the row's primary output (:246);
-- selector: the calibration within LOCAL_AGRONOMY_AT_CUT_V1 (:73).
P.CALIBRATION = {
    { key = "wheat",     names = { "wheat" },             n = { 35, 55 }, p = { 25, 40 }, k = { 25, 40 }, food = true },
    { key = "barley",    names = { "barley" },            n = { 25, 45 }, p = { 20, 35 }, k = { 20, 35 }, food = true },
    { key = "maize",     names = { "maize" },             n = { 40, 60 }, p = { 25, 40 }, k = { 30, 45 }, food = true },
    { key = "canola",    names = { "canola" },            n = { 45, 65 }, p = { 30, 45 }, k = { 30, 45 }, food = true },
    { key = "soybean",   names = { "soybean" },           n = { 15, 30 }, p = { 30, 50 }, k = { 35, 55 }, food = true },
    { key = "sunflower", names = { "sunflower" },         n = { 35, 55 }, p = { 25, 40 }, k = { 35, 55 }, food = true },
    { key = "potato",    names = { "potato" },            n = { 45, 65 }, p = { 35, 55 }, k = { 60, 80 }, food = true },
    { key = "sugarbeet", names = { "sugarbeet" },         n = { 45, 65 }, p = { 35, 55 }, k = { 65, 85 }, food = true },
    { key = "oat",       names = { "oat", "oats" },       n = { 25, 45 }, p = { 20, 35 }, k = { 20, 35 }, food = true },
    { key = "rye",       names = { "rye" },               n = { 25, 45 }, p = { 20, 35 }, k = { 20, 35 }, food = true },
    { key = "triticale", names = { "triticale" },         n = { 35, 55 }, p = { 25, 40 }, k = { 25, 40 }, food = true },
    { key = "sorghum",   names = { "sorghum" },           n = { 30, 50 }, p = { 20, 35 }, k = { 25, 40 }, food = true },
    { key = "peas",      names = { "peas", "pea" },       n = { 15, 30 }, p = { 25, 45 }, k = { 30, 50 }, food = true },
    { key = "beans",     names = { "beans", "greenbean" }, n = { 15, 30 }, p = { 25, 45 }, k = { 30, 50 }, food = true },
    { key = "luzerne",   names = { "luzerne", "alfalfa" }, n = { 10, 20 }, p = { 25, 45 }, k = { 30, 50 }, food = false },
    { key = "clover",    names = { "clover" },            n = { 10, 20 }, p = { 25, 45 }, k = { 30, 50 }, food = false },
    { key = "grass",     names = { "grass", "meadow" },   n = { 30, 50 }, p = { 25, 40 }, k = { 20, 40 }, food = false, selector = "GRASS_QUALITY_V1" },
    { key = "BASE_NATIVE_CROP_V1", names = { "rice", "ricelonggrain", "carrot", "parsnip", "beetroot", "spinach", "sugarcane", "grape", "olive" },
      n = { 30, 50 }, p = { 25, 40 }, k = { 20, 40 }, food = true, selector = "BASE_NATIVE_CROP_V1" },
}

-- name (lower case) -> { row, cropKey }. An alias names its row's canonical crop; a base
-- native crop is its own crop under the BASE_NATIVE_CROP_V1 row.
P.CROP_BY_NAME = {}
for _, row in ipairs(P.CALIBRATION) do
    for _, name in ipairs(row.names) do
        P.CROP_BY_NAME[name] = { row = row, cropKey = row.selector == "BASE_NATIVE_CROP_V1" and name or row.names[1] }
    end
end

--- The calibration row and crop key for a fruit descriptor's name, or nil (unsupported, :155).
function P.cropOf(fruitName)
    if type(fruitName) ~= "string" then return nil end
    local hit = P.CROP_BY_NAME[string.lower(fruitName)]
    if hit == nil then return nil end
    return hit.row, hit.cropKey
end

-- pH fit (:180): 100 at the optimum, linear to 0 at the minimum and the maximum, clamped.
P.PH = { min = 5.0, opt = 6.5, max = 7.5 }
-- agronomyFit = .75 npkFit + .25 phFit; earnedScore = .60 agronomyFit + .40 maturityScore (:180, :198).
P.WEIGHT = { npk = 0.75, ph = 0.25, agronomy = 0.60, maturity = 0.40 }

-- RAW_MATURITY_V1's classes and their maturity scores (:196). UNSUPPORTED supplies none.
P.MATURITY = { HARVEST_READY = 100, FORAGE_READY = 100, HARVESTABLE_NONREADY = 45, WITHERED = 20 }
-- The grass calibration's ordinary mowing states counted HARVEST_READY first (:194, :204).
P.GRASS_READY_NAMES = { greenmiddle = true, harvestready = true }

-- Approved starting bands (:306), applied to remainingScore without rounding.
P.BANDS = { FOOD = { A = 85, B = 70 }, FEED = { A = 80, B = 60 } }

-- Materials that are Feed-only by output mapping (:80, :202, :246-248): Food is UNSUITABLE.
P.FEED_ONLY = { STRAW = true, GRASS_WINDROW = true, DRYGRASS_WINDROW = true, CHAFF = true, SILAGE = true }

-- The bale materials whose current assessment needs SOIL_BALE_CONDITION_V1 (:254; F215's
-- admitted forage and straw profiles). Until that profile is bound (Part 3) it is unavailable.
P.BALE_CONDITION_MATERIALS = { STRAW = true, GRASS_WINDROW = true, DRYGRASS_WINDROW = true, SILAGE = true }

-- The finite reason vocabulary (:409, :511), in the brief's order. Codes only.
P.REASONS = {
    "NO_MATERIAL", "UNSUPPORTED_MATERIAL", "UNSUPPORTED_PROFILE", "ORIGIN_UNPROVEN", "SOIL_UNAVAILABLE",
    "SOURCE_PARTIAL", "MATURITY_UNAVAILABLE", "FOOD_ORIGIN_INELIGIBLE", "QUALITY_PARTIAL", "QUALITY_HISTORICAL",
    "CONDITION_UNAVAILABLE", "CONDITION_PENDING", "CONDITION_CONDEMNED", "CONDITION_GAP", "FOREIGN_CONDITION_UNCOVERED",
    "PROCESS_PENDING", "RECIPE_NOT_READY", "GROUPED_PORTIONS", "MIXED_PORTION_GRADES", "SOURCE_CHANGED",
    "DISCLOSURE_DENIED", "PROFILE_MISMATCH", "COMPOSITION_UNKNOWN",
}
P.REASON = {}
for _, code in ipairs(P.REASONS) do P.REASON[code] = code end
--- The l10n key a reason code is shown under (the 27 translation files carry each).
function P.reasonTextKey(code) return "sg3_reason_" .. string.lower(code) end

-- The release gate (:354, :458): LOCKED. sg3.assessments' PLAYER_VIEW projection stays withheld
-- behind this one constant until release acceptance; qualityBasisV1 is never disclosed (:88).
P.RELEASE_LOCKED = true
