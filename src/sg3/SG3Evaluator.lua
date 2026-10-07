-- =========================================================
-- FS25_StockGuard - SG-3 evaluator: the pure grading arithmetic (SG-3 Part 2.1)
-- =========================================================
-- Pure functions over detached data (SG-3 brief :384-386): the local agronomy fit and the
-- earned score (:151, :180, :198), RAW_MATURITY_V1's classes (:194-196), the quantity-weighted
-- combine with its unknown floor (:51, :238, :252), and evaluateUse, the ONE evaluator the
-- server read and the player view both call (:386). Nothing here reads the game.
--
-- AN ENTRY is one positive quality-bearing contribution on its destination's basis:
--   { amount, earned?, remaining?, use = { FOOD = mask, FEED = mask },
--     cropKey?, calibrationKey?, nativeSourceMaterial?, lastTransform?, scoreReason? }
-- A mask is { eligible, ineligible, unknown, reasons } over that entry's own amount; the three
-- fractions sum to 1. An entry with no score pair is quality-bearing with unknown scores.

SG3Evaluator = SG3Evaluator or {}
local E = SG3Evaluator
local P = SG3Profiles

E.EPSILON = 1e-9

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
E.finite = finite
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

local function copyList(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = v end
    return out
end

-- Reasons are kept in the catalogue's own order, deduplicated (:238: "the stable deduplicated union").
local ORDER = {}
for i, code in ipairs(P.REASONS) do ORDER[code] = i end
local function sortReasons(set)
    local out = {}
    for code in pairs(set) do out[#out + 1] = code end
    table.sort(out, function(a, b) return (ORDER[a] or 1000) < (ORDER[b] or 1000) end)
    return out
end
local function addAll(set, list) for _, code in ipairs(list or {}) do set[code] = true end end

-- ── the agronomy fit (:151, :180) ────────────────────────────────────────────
--- fit = clamp((value - min) / (opt - min), 0, 1).
function E.fit(value, range)
    return clamp((value - range[1]) / (range[2] - range[1]), 0, 1)
end

--- pH fit: 100 at PH_OPTIMAL 6.5, linear to 0 at 5.0 and 7.5, clamped beyond.
function E.phFit(pH)
    local ph = P.PH
    if pH <= ph.min or pH >= ph.max then return 0 end
    if pH <= ph.opt then return 100 * (pH - ph.min) / (ph.opt - ph.min) end
    return 100 * (ph.max - pH) / (ph.max - ph.opt)
end

--- agronomyFit = .75 npkFit + .25 phFit, with npkFit = 100 (Nfit + Pfit + Kfit) / 3. nil when any of
--- the four local inputs is missing or not finite (:153: the positive portion is then unknown).
function E.agronomyFit(row, soil)
    if type(row) ~= "table" or type(soil) ~= "table" then return nil end
    local n, p, k, ph = soil.nitrogen, soil.phosphorus, soil.potassium, soil.pH
    if not (finite(n) and finite(p) and finite(k) and finite(ph)) then return nil end
    local npk = 100 * (E.fit(n, row.n) + E.fit(p, row.p) + E.fit(k, row.k)) / 3
    return P.WEIGHT.npk * npk + P.WEIGHT.ph * E.phFit(ph)
end

--- earnedScore = .60 agronomyFit + .40 maturityScore, in full precision (:198).
function E.earned(agronomy, maturity)
    return P.WEIGHT.agronomy * agronomy + P.WEIGHT.maturity * maturity
end

-- ── RAW_MATURITY_V1 (:194) ───────────────────────────────────────────────────
--- The class of one captured state, from its frozen descriptor inputs (SGCutState, U4):
--- { valid, stateName, harvestReady, withered, cut, forage, harvestable }. In the brief's exact order:
--- an invalid, zero or unmapped state, or a cut state, is UNSUPPORTED; under GRASS_QUALITY_V1 a named
--- greenMiddle or harvestReady state that is harvest-ready is HARVEST_READY before the withered test;
--- then WITHERED; HARVEST_READY; FORAGE_READY; HARVESTABLE_NONREADY; otherwise UNSUPPORTED. nil
--- (unknown) when the inputs are missing.
function E.classify(m, selector)
    if type(m) ~= "table" then return nil end
    if m.valid ~= true or m.cut == true then return "UNSUPPORTED" end
    if selector == "GRASS_QUALITY_V1" and m.harvestReady == true and type(m.stateName) == "string"
        and P.GRASS_READY_NAMES[string.lower(m.stateName)] then
        return "HARVEST_READY"
    end
    if m.withered == true then return "WITHERED" end
    if m.harvestReady == true then return "HARVEST_READY" end
    if m.forage == true then return "FORAGE_READY" end
    if m.harvestable == true then return "HARVESTABLE_NONREADY" end
    return "UNSUPPORTED"
end

-- ── entries ──────────────────────────────────────────────────────────────────
local function mask(eligible, ineligible, unknown, reasons) return { eligible = eligible, ineligible = ineligible, unknown = unknown, reasons = reasons or {} } end

--- A positive contribution whose quality is unknown, for one named reason.
function E.unknownEntry(amount, reason)
    return { amount = amount, use = { FOOD = mask(0, 0, 1, { reason }), FEED = mask(0, 0, 1, { reason }) } }
end

--- One cut portion (SGHarvestCapture's evidence portion) born into output `outputName` at `amount`.
function E.bornEntry(portion, amount, outputName)
    -- Prepared foliage the Mower could not attribute "remains unknown origin" (:192, :515; Bob's 2.2
    -- R-15): ORIGIN_UNPROVEN. Any other refused reading is SOURCE_PARTIAL.
    if type(portion) == "table" and portion.prepared == true then return E.unknownEntry(amount, "ORIGIN_UNPROVEN") end
    if type(portion) ~= "table" or portion.knowledge ~= "KNOWN" then return E.unknownEntry(amount, "SOURCE_PARTIAL") end
    local row, cropKey = P.cropOf(portion.fruitName)
    if row == nil then return E.unknownEntry(amount, "UNSUPPORTED_MATERIAL") end
    local entry = { amount = amount, cropKey = cropKey, calibrationKey = row.key, use = {} }
    if type(outputName) == "string" then entry.nativeSourceMaterial = { kind = "FILL_TYPE", fillTypeName = outputName } end
    local class = E.classify(portion.maturity, row.selector)
    local maturity = class ~= nil and P.MATURITY[class] or nil
    if maturity == nil then
        entry.use.FOOD = mask(0, 0, 1, { "MATURITY_UNAVAILABLE" })
        entry.use.FEED = mask(0, 0, 1, { "MATURITY_UNAVAILABLE" })
        return entry
    end
    -- :153: every value finite AND every grain finite and positive; SGCutState keys a group with no
    -- grain under the cell "none", so such a portion's Soil input is unavailable.
    local soil = (type(portion.soilCell) == "string" and portion.soilCell ~= "none") and portion.soil or nil
    local agronomy = E.agronomyFit(row, soil)
    local scoreReasons = {}
    if agronomy ~= nil then
        entry.earned = E.earned(agronomy, maturity)
        entry.remaining = entry.earned   -- genuine new output starts remaining = earned (:198)
    else
        scoreReasons[1] = "SOIL_UNAVAILABLE"
    end
    -- Food: a food crop's own primary output, harvest-ready (:246); everything else is Food-ineligible.
    local primary = type(outputName) == "string" and outputName == portion.primaryFillTypeName and not P.FEED_ONLY[outputName]
    if row.food and primary and class == "HARVEST_READY" then
        entry.use.FOOD = mask(1, 0, 0, copyList(scoreReasons))
    else
        local reasons = copyList(scoreReasons)
        reasons[#reasons + 1] = "FOOD_ORIGIN_INELIGIBLE"
        entry.use.FOOD = mask(0, 1, 0, reasons)
    end
    entry.use.FEED = mask(1, 0, 0, copyList(scoreReasons))
    return entry
end

--- The reason an absent or unavailable record stands for: its own catalogue code when SG-3 stored one
--- (a birth's transform answered nil and that code), else ORIGIN_UNPROVEN (no record, or SG-1's own
--- reason such as PRODUCER_ABSENT or TRANSFORM_ERROR, which is not a player-facing code).
function E.unavailableReason(record)
    if type(record) == "table" and type(record.reason) == "string" and P.REASON[record.reason] then return record.reason end
    return "ORIGIN_UNPROVEN"
end

--- A stored qualityBasisV1 record carried at `amount`. Returns the entry, or nil and PROFILE_MISMATCH
--- for a payload of another score meaning (:51: "different profile meanings need a declared transform").
function E.recordEntry(record, amount)
    if type(record) ~= "table" or type(record.payload) ~= "table" or record.knowledge == "UNAVAILABLE" then
        return E.unknownEntry(amount, E.unavailableReason(record))
    end
    if record.knowledge == "HISTORICAL" then return E.unknownEntry(amount, "QUALITY_HISTORICAL") end
    local pl = record.payload
    if pl.representation ~= P.UNIFORM or pl.profileId ~= P.SCORE_PROFILE then return nil, "PROFILE_MISMATCH" end
    local w = type(pl.sourceWitness) == "table" and pl.sourceWitness or {}
    local ou = type(w.originUse) == "table" and w.originUse or {}
    local function m(use)
        local u = ou[use]
        if type(u) ~= "table" then return mask(0, 0, 1, { "ORIGIN_UNPROVEN" }) end
        return mask(u.eligibleFraction or 0, u.ineligibleFraction or 0, u.unknownFraction or 1, copyList(u.reasons))
    end
    return { amount = amount, earned = pl.earnedScore, remaining = pl.remainingScore, cropKey = w.cropKey, calibrationKey = w.calibrationKey,
             nativeSourceMaterial = w.nativeSourceMaterial, lastTransform = w.lastTransform, use = { FOOD = m(P.FOOD), FEED = m(P.FEED) } }
end

-- ── the combine (:51, :238, :252) ────────────────────────────────────────────
local function sameValue(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not sameValue(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- Combine entries on one destination basis of `basisAmount`. Scores: separately quantity-weighted
--- earned and remaining sums over the whole quality-bearing total, omitted when any positive entry's
--- scores are unknown (:51: 500 L at 80 beside 500 L unknown has no whole score, never 40). Use masks:
--- quantity-weighted fractions, reasons the deduplicated union. cropKey, calibrationKey and
--- nativeSourceMaterial survive only when every positive entry carries the same value (:238). A plain
--- combine of several positive sources omits lastTransform; one source keeps it (:240), and a
--- performed transform supplies its own. Returns { payload, knowledge, knownAmount, basisAmount },
--- or nil and a reason when nothing is quality-bearing or nothing about it is known.
function E.combine(entries, basisAmount, performedTransform)
    local positive, total = {}, 0
    for _, e in ipairs(entries or {}) do
        if finite(e.amount) and e.amount > E.EPSILON then
            positive[#positive + 1] = e
            total = total + e.amount
        end
    end
    if total <= 0 then return nil, "NO_MATERIAL" end
    local sumE, sumR, knownQ, allKnown, informative, firstReason = 0, 0, 0, true, false, nil
    for _, e in ipairs(positive) do
        if finite(e.earned) and finite(e.remaining) then
            knownQ = knownQ + e.amount
            sumE = sumE + e.amount * e.earned
            sumR = sumR + e.amount * e.remaining
            informative = true
        else
            allKnown = false
        end
        for _, use in ipairs({ P.FOOD, P.FEED }) do
            local u = e.use[use]
            if u.eligible > 0 or u.ineligible > 0 then informative = true end
            if firstReason == nil and u.reasons[1] ~= nil then firstReason = u.reasons[1] end
        end
    end
    if not informative then return nil, firstReason or "ORIGIN_UNPROVEN" end
    local originUse = {}
    for _, use in ipairs({ P.FOOD, P.FEED }) do
        local el, inel, reasons = 0, 0, {}
        for _, e in ipairs(positive) do
            local u = e.use[use]
            el = el + e.amount * u.eligible
            inel = inel + e.amount * u.ineligible
            addAll(reasons, u.reasons)
        end
        el, inel = clamp(el / total, 0, 1), clamp(inel / total, 0, 1)
        originUse[use] = { eligibleFraction = el, ineligibleFraction = inel, unknownFraction = clamp(1 - el - inel, 0, 1), reasons = sortReasons(reasons) }
    end
    local witness = { schemaVersion = 1, originProfileId = P.SCORE_PROFILE, originProfileRevision = P.REVISION, originUse = originUse }
    for _, key in ipairs({ "cropKey", "calibrationKey", "nativeSourceMaterial" }) do
        local v, same = positive[1][key], true
        for i = 2, #positive do if not sameValue(v, positive[i][key]) then same = false break end end
        if same and v ~= nil then witness[key] = v end
    end
    if performedTransform ~= nil then
        witness.lastTransform = { profileId = performedTransform, profileRevision = P.REVISION }
    elseif #positive == 1 and positive[1].lastTransform ~= nil then
        witness.lastTransform = positive[1].lastTransform
    end
    local payload = { representation = P.UNIFORM, profileId = P.SCORE_PROFILE, profileRevision = P.REVISION, originKind = P.ORIGIN_KIND,
                      sourceWitness = witness, coveredConditionCoordinates = {}, coverageGaps = {} }
    if allKnown then
        local earned = clamp(sumE / total, 0, 100)
        payload.earnedScore = earned
        payload.remainingScore = math.min(clamp(sumR / total, 0, 100), earned)
    end
    local knowledge = (knownQ >= total - E.EPSILON) and "KNOWN" or (knownQ > 0 and "PARTIAL" or "UNKNOWN")
    local basis = finite(basisAmount) and basisAmount or total
    return { payload = payload, knowledge = knowledge, knownAmount = basis * math.min(1, knownQ / total), basisAmount = basis }
end

--- A performed native transform that leaves the material Feed-only (:263, :267): the eligible Food
--- share becomes ineligible with FOOD_ORIGIN_INELIGIBLE; scores and Feed are kept.
function E.feedOnly(payload)
    local food = payload.sourceWitness.originUse.FOOD
    if food.eligibleFraction > 0 then
        food.ineligibleFraction = clamp(food.ineligibleFraction + food.eligibleFraction, 0, 1)
        food.eligibleFraction = 0
    end
    if food.ineligibleFraction > 0 then
        local set = {}
        addAll(set, food.reasons)
        set.FOOD_ORIGIN_INELIGIBLE = true
        food.reasons = sortReasons(set)
    end
    return payload
end

-- ── evaluateUse (:384-388, :409) ─────────────────────────────────────────────
--- The band letter for a use's remainingScore, unrounded at the boundaries (:306).
function E.grade(use, score)
    local b = P.BANDS[use]
    if b == nil or not finite(score) then return nil end
    if score >= b.A then return "A" elseif score >= b.B then return "B" end
    return "C"
end

--- The recorded-only historical result (:388): the same use's evaluator over the recorded pair and
--- the original eligibility, with every current-condition conclusion excluded. nil when the recorded
--- inputs are insufficient.
local function historicalOf(payload, use, profileId)
    local u = payload.sourceWitness and payload.sourceWitness.originUse and payload.sourceWitness.originUse[use]
    if type(u) ~= "table" or not finite(payload.remainingScore) then return nil end
    local suitability = u.ineligibleFraction > 0 and "UNSUITABLE" or (u.unknownFraction > 0 and "UNKNOWN" or "SUITABLE")
    local h = { basis = "RECORDED_ONLY", use = use, earnedScore = payload.earnedScore, remainingScore = payload.remainingScore,
                profileId = profileId, profileRevision = P.REVISION, suitability = suitability }
    if suitability == "SUITABLE" then h.grade = E.grade(use, payload.remainingScore) end
    return h
end

--- evaluateUse(snapshot, use, profileId, profileRevision) -> Result.
--- snapshot: { stockRef, amount, amountUnit, materialName, materialSupported, quality (the
--- qualityBasisV1 record or nil), conditionRequired, conditionAvailable, readRevision }.
function E.evaluateUse(snap, use, profileId, profileRevision)
    local r = { representation = P.UNIFORM, use = use, profileId = profileId, profileRevision = profileRevision, reasons = {},
                readRevision = snap.readRevision, stockRefs = { snap.stockRef }, propertyRevisions = {} }
    local q = snap.quality
    if type(q) == "table" then r.propertyRevisions[1] = { propertyId = P.QUALITY_PROPERTY, propertyRevision = q.propertyRevision } end
    local function finish(state, knowledge, suitability, reasons)
        r.state, r.knowledge, r.suitability = state, knowledge, suitability
        local set = {}
        addAll(set, reasons)
        r.reasons = sortReasons(set)
        return r
    end
    if P.USE_PROFILE_FOR[use] ~= profileId or profileRevision ~= P.REVISION then
        return finish("UNSUPPORTED", "UNAVAILABLE", "UNAVAILABLE", { "UNSUPPORTED_PROFILE" })
    end
    if not finite(snap.amount) or snap.amount <= 0 then
        r.knownAmount, r.basisAmount, r.amountUnit = 0, 0, snap.amountUnit
        return finish("NO_MATERIAL", "KNOWN", "UNAVAILABLE", { "NO_MATERIAL" })
    end
    if snap.materialSupported ~= true then
        return finish("UNSUPPORTED", "UNAVAILABLE", "UNAVAILABLE", { "UNSUPPORTED_MATERIAL" })
    end
    if type(q) ~= "table" or type(q.payload) ~= "table" or q.knowledge == "UNAVAILABLE" then
        return finish("READY", "UNKNOWN", "UNKNOWN", { E.unavailableReason(q) })
    end
    local pl = q.payload
    if pl.representation ~= P.UNIFORM or pl.profileId ~= P.SCORE_PROFILE then
        return finish("UNSUPPORTED", "UNAVAILABLE", "UNAVAILABLE", { "UNSUPPORTED_PROFILE" })
    end
    if q.knowledge == "HISTORICAL" then
        r.historical = historicalOf(pl, use, profileId)
        return finish("READY", "HISTORICAL", "UNKNOWN", { "QUALITY_HISTORICAL" })
    end
    r.knownAmount, r.basisAmount, r.amountUnit = q.knownAmount, q.basisAmount, q.amountUnit
    -- A carrier whose current assessment needs a condition owner that is not bound (:254).
    if snap.conditionRequired == true and snap.conditionAvailable ~= true then
        r.historical = historicalOf(pl, use, profileId)
        return finish("UNAVAILABLE", "UNAVAILABLE", "UNAVAILABLE", { "CONDITION_UNAVAILABLE" })
    end
    local u = pl.sourceWitness and pl.sourceWitness.originUse and pl.sourceWitness.originUse[use]
    if type(u) ~= "table" then return finish("READY", "UNKNOWN", "UNKNOWN", { "ORIGIN_UNPROVEN" }) end
    local reasons = copyList(u.reasons)
    local suitability
    if u.ineligibleFraction > 0 or (use == P.FOOD and P.FEED_ONLY[snap.materialName or ""]) then
        suitability = "UNSUITABLE"
        if use == P.FOOD then reasons[#reasons + 1] = "FOOD_ORIGIN_INELIGIBLE" end
    elseif u.unknownFraction > 0 then
        suitability = "UNKNOWN"
    else
        suitability = "SUITABLE"
    end
    local knowledge = q.knowledge
    if knowledge == "KNOWN" and finite(pl.remainingScore) then
        -- A score and letter for this use only where the material is suitable for it (:388).
        if suitability == "SUITABLE" then
            r.remainingScore = pl.remainingScore
            r.grade = E.grade(use, pl.remainingScore)
        end
    else
        if knowledge == "KNOWN" then knowledge = "UNKNOWN" end
        reasons[#reasons + 1] = "QUALITY_PARTIAL"
    end
    return finish("READY", knowledge, suitability, reasons)
end
