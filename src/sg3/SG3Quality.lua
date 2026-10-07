-- =========================================================
-- FS25_StockGuard - qualityBasisV1, SG-3's stored quality property (SG-3 Part 2.1)
-- =========================================================
-- SG-3 brief :45-71, :234-252: the STORED causal property qualityBasisV1, schema 1, producer
-- sg3, registered through SG-1's registerProperty. Its callbacks are PURE (:96-100): SG-1 hands
-- them the detached settle context and they return one absolute PropertyRecord.
--
-- A BIRTH (SG-3 Part 1, birth = true). SG-1 asks this producer about every candidate holding new
-- material born from creation slots. Only the cutter's cut is graded in this part (Bob, 2026-10-07):
-- its outcomeEvidence names PATH_CUT and carries each slot's captured portion (fruit, state, Soil,
-- RAW_MATURITY_V1 inputs; SGHarvestCapture, SGCutState). Every other birth, the mower's included
-- (Part 2.2), is a named unknown origin: never graded, never a throw.
--
-- COMBINE (:51, :238). A move or mix of recorded material: the quantity-weighted pair with the
-- unknown floor, through SG3Evaluator.combine. A contribution without the property is unknown.
--
-- TRANSFORM (:263, :267). The two native transforms production reports: NATIVE_HAY_CONVERT_V1 (the
-- Tedder's reverse converter) and NATIVE_BALE_FEED_V1 (a bale's fermentation). Each keeps the pair,
-- makes the material Feed-only and records lastTransform (:240). Any other basis is unavailable.
--
-- DISCLOSURE (:88). nil, DISCLOSURE_DENIED for every player view, owner and admin included.
--
-- CAUSAL (:57, :65, :104). The full trio is registered now so the schema never changes; no damage
-- profile is bound in this part (SOIL_BALE_CONDITION_V1 is Part 3), so no SG-3 cause is accepted,
-- the floor travels as carried and there is nothing to compact.

SG3Quality = SG3Quality or {}
local Q = SG3Quality
local P = SG3Profiles
local E = SG3Evaluator

local function finite(n) return E.finite(n) end

--- The record SG-1 installs: canonical coverage on the destination basis, the payload, and the
--- canonical causal home with no branch yet (:65).
local function recordOf(res, unit)
    return { propertyId = P.QUALITY_PROPERTY, schemaVersion = P.SCHEMA_VERSION, producerId = P.PRODUCER_ID, propertyRevision = 0,
             knowledge = res.knowledge, knownAmount = res.knownAmount, basisAmount = res.basisAmount, amountUnit = unit or "LITRE",
             payload = res.payload, causalState = { schemaVersion = 1, branches = {} } }
end

--- The candidate a combine is for: the destination of its contributions' allocations.
local function candidateOf(ctx, contributions)
    local byRef = {}
    for _, a in ipairs(ctx.allocations or {}) do if a.allocationRef ~= nil then byRef[a.allocationRef] = a end end
    for _, c in ipairs(contributions or {}) do
        local a = byRef[c.allocationRef]
        local d = a ~= nil and a.destination or nil
        local key = d ~= nil and (d.carrierId or (d.slotId ~= nil and ("slot:" .. d.slotId))) or nil
        if key ~= nil and ctx.candidates ~= nil and ctx.candidates[key] ~= nil then return ctx.candidates[key] end
    end
    return nil
end

Q.mowerClassLogged = Q.mowerClassLogged or false

--- [SG-3 Part 2.2, Bob's R-15] The in-game evidence for GRASS_QUALITY_V1's named states (:204), which no
--- offline source can check: the first graded Mower birth of a launch says, once, each captured state
--- name and the RAW_MATURITY_V1 class it read, one entry per distinct pair (a cut has a portion per
--- state and Soil cell, so a wide mower would otherwise repeat the same pair many times).
local function logMowerClasses(portions)
    if Q.mowerClassLogged then return end
    local parts, seen, fruit = {}, {}, nil
    for _, p in ipairs(portions) do
        if type(p) == "table" and p.knowledge == "KNOWN" and type(p.maturity) == "table" then
            local row = P.cropOf(p.fruitName)
            fruit = fruit or p.fruitName
            local part = "state " .. tostring(p.maturity.stateName) .. " " .. tostring(row ~= nil and E.classify(p.maturity, row.selector) or "UNSUPPORTED_MATERIAL")
            if not seen[part] then
                seen[part] = true
                parts[#parts + 1] = part
            end
        end
    end
    if #parts == 0 then return end
    table.sort(parts)
    Q.mowerClassLogged = true
    print("[StockGuard] SG-3: first graded mower cut (fruit " .. tostring(fruit) .. "): " .. table.concat(parts, ", ") .. ". Logged once per launch.")
end

--- The entries a set of contributions and the destination's own remainder make. A slot contribution
--- is a birth: graded from its evidence portion on the cutter's path, a named unknown origin on any
--- other. A carried contribution brings its own record.
local function entriesOf(ctx, contributions, destinationBefore, outputName)
    local ev = ctx.report and ctx.report.outcomeEvidence or {}
    local graded = type(ev.nativePath) == "string" and P.GRADED_BIRTH_PATHS[ev.nativePath] == true
    local bySlot = {}
    if graded then
        for _, p in ipairs(type(ev.portions) == "table" and ev.portions or {}) do
            if type(p) == "table" and p.slotId ~= nil then bySlot[p.slotId] = p end
        end
        if ev.nativePath == "GROUND_MOWER_CUT" and type(ev.portions) == "table" then logMowerClasses(ev.portions) end
    end
    local entries = {}
    for _, c in ipairs(contributions or {}) do
        if c.slotId ~= nil then
            if graded then
                entries[#entries + 1] = E.bornEntry(bySlot[c.slotId], c.amount, outputName)
            else
                entries[#entries + 1] = E.unknownEntry(c.amount, "ORIGIN_UNPROVEN")
            end
        else
            local e, why = E.recordEntry(c.properties and c.properties[P.QUALITY_PROPERTY] or nil, c.amount)
            if e == nil then return nil, why end
            entries[#entries + 1] = e
        end
    end
    if type(destinationBefore) == "table" then
        local e, why = E.recordEntry(destinationBefore.properties and destinationBefore.properties[P.QUALITY_PROPERTY] or nil, destinationBefore.observedAmount)
        if e == nil then return nil, why end
        entries[#entries + 1] = e
    end
    return entries
end

--- The one conversion basis the contributions declare, or nil; false when they declare several.
local function basisOf(contributions)
    local basis = nil
    for _, c in ipairs(contributions or {}) do
        if c.conversionBasisId ~= nil then
            if basis ~= nil and basis ~= c.conversionBasisId then return false end
            basis = c.conversionBasisId
        end
    end
    return basis
end

-- ── the property's callbacks ─────────────────────────────────────────────────
function Q.combine(ctx, contributions, destinationBefore)
    local cand = candidateOf(ctx, contributions)
    local outputName = cand ~= nil and cand.materialRef ~= nil and cand.materialRef.fillTypeName or nil
    local entries, why = entriesOf(ctx, contributions, destinationBefore, outputName)
    if entries == nil then return nil, why end
    local res, reason = E.combine(entries, cand ~= nil and cand.amount or nil, nil)
    if res == nil then return nil, reason end
    return recordOf(res, cand ~= nil and cand.unit or nil)
end

function Q.transform(ctx, inputs, outputs)
    local out = type(outputs) == "table" and outputs[1] or nil
    if type(out) ~= "table" then return nil, "SOURCE_CHANGED" end
    local basis = basisOf(inputs)
    if basis == false or (basis ~= nil and not P.TRANSFORMS[basis]) then return nil, "UNSUPPORTED_PROFILE" end
    local outputName = out.materialRef ~= nil and out.materialRef.fillTypeName or nil
    local entries, why = entriesOf(ctx, inputs, out.destinationBefore, outputName)
    if entries == nil then return nil, why end
    local res, reason = E.combine(entries, out.amount, basis)
    if res == nil then return nil, reason end
    if basis ~= nil then E.feedOnly(res.payload) end
    return recordOf(res, out.unit)
end

--- A record's payload is the exact UNIFORM schema-1 shape (:57, :250); an unavailable placeholder
--- carries none.
function Q.validate(record)
    if type(record) ~= "table" then return false, "RECORD" end
    local pl = record.payload
    if pl == nil then return record.knowledge == "UNAVAILABLE", "PAYLOAD" end
    if type(pl) ~= "table" or pl.representation ~= P.UNIFORM then return false, "REPRESENTATION" end
    if pl.profileId ~= P.SCORE_PROFILE or pl.profileRevision ~= P.REVISION or pl.originKind ~= P.ORIGIN_KIND then return false, "PROFILE" end
    if (pl.earnedScore == nil) ~= (pl.remainingScore == nil) then return false, "SCORE_PAIR" end
    if pl.earnedScore ~= nil then
        if not finite(pl.earnedScore) or not finite(pl.remainingScore) then return false, "SCORE" end
        if pl.earnedScore < 0 or pl.earnedScore > 100 or pl.remainingScore < 0 or pl.remainingScore > pl.earnedScore then return false, "SCORE" end
    end
    local w = pl.sourceWitness
    if type(w) ~= "table" or w.schemaVersion ~= 1 or w.originProfileId ~= P.SCORE_PROFILE or w.originProfileRevision ~= P.REVISION then return false, "WITNESS" end
    for _, use in ipairs({ P.FOOD, P.FEED }) do
        local u = type(w.originUse) == "table" and w.originUse[use] or nil
        if type(u) ~= "table" or type(u.reasons) ~= "table" then return false, "ORIGIN_USE" end
        local sum = 0
        for _, f in ipairs({ u.eligibleFraction, u.ineligibleFraction, u.unknownFraction }) do
            if not finite(f) or f < 0 or f > 1 then return false, "ORIGIN_USE" end
            sum = sum + f
        end
        if math.abs(sum - 1) > 1e-6 then return false, "ORIGIN_USE" end
        for _, code in ipairs(u.reasons) do if not P.REASON[code] then return false, "REASON" end end
    end
    if type(pl.coveredConditionCoordinates) ~= "table" or type(pl.coverageGaps) ~= "table" then return false, "CONDITION" end
    return true
end

--- The property spec registered with SG-1.
function Q.spec()
    return {
        schemaVersion = P.SCHEMA_VERSION, producerId = P.PRODUCER_ID, residency = "STORED", birth = true,
        validate = Q.validate,
        combine = Q.combine,
        transform = Q.transform,
        disclosure = function() return nil, "DISCLOSURE_DENIED" end,
        validateCause = function() return nil, "NO_DAMAGE_PROFILE" end,
        transformCausalState = function() return nil end,
        compactCausalState = function() return nil end,
    }
end
