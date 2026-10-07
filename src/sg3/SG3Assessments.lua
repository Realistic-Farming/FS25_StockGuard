-- =========================================================
-- FS25_StockGuard - sg3.assessments, SG-3's derived Food/Feed assessment (SG-3 Part 2.1)
-- =========================================================
-- SG-3 brief :384-411, :501-513: the OWNER_RESOLVED property sg3.assessments, schema 1. It is
-- never stored: resolveResident reads the stock's qualityBasisV1 through SG-3's own consumer
-- sg3.assessmentInputs (query.propertyIds = { qualityBasisV1 }, so it never resolves itself, :397)
-- and returns { schemaVersion = 1, representation, food, feed } from evaluateUse, the one
-- evaluator assessMaterialUse also calls (:386).
--
-- REVISIONS (:401). getResidentRevision and every Result.readRevision are an opaque mission-local
-- counter, advanced when the private key (the stock's complete StockRef and the profile revision)
-- changes. They are never an encoding or hash of that key.
--
-- RELEASE LOCKED (:354, :458). Its PLAYER_VIEW projection is withheld behind SG3Profiles.RELEASE_LOCKED:
-- the disclosure answers nil, DISCLOSURE_DENIED, so SG-1's view omits the child entirely (SG-3 Part 1).
-- The owner projection (:403, :407) is built with the lock's release (SG-5's slice).
--
-- A BALE whose material is an admitted F215 forage or straw profile needs SOIL_BALE_CONDITION_V1 for
-- its current assessment (:254). That profile is bound in Part 3, so here its current assessment is
-- UNAVAILABLE with CONDITION_UNAVAILABLE, and its recorded quality shows as historical only.

SG3Assessments = SG3Assessments or {}
local A = SG3Assessments
local P = SG3Profiles
local E = SG3Evaluator

local function unitToken(unit)
    if SGRecords ~= nil and SGRecords.AMOUNT_UNITS[unit] then return unit end
    if unit == "l" or unit == "litre" or unit == "liter" then return "LITRE" end
    return unit
end

--- The opaque revision for a stock's current inputs: advanced only when its key changes.
function A.revisionFor(m, stockRef)
    if type(stockRef) ~= "table" or stockRef.stockId == nil then return nil end
    local key = tostring(stockRef.contentsGeneration) .. "|" .. tostring(stockRef.dataRevision) .. "|" .. P.REVISION
    local held = m.revisions[stockRef.stockId]
    if held == nil or held.key ~= key then
        m.nextRevision = m.nextRevision + 1
        held = { key = key, revision = m.nextRevision }
        m.revisions[stockRef.stockId] = held
    end
    return held.revision
end

--- The evaluator's snapshot of one SG-1 read record (readMaterial's snapshotStock).
function A.snapshotOf(m, rec, readRevision)
    local mat = rec.materialRef
    local name = type(mat) == "table" and mat.kind == "FILL_TYPE" and mat.fillTypeName or nil
    local isBale = SGNativeAdapters ~= nil and type(SGNativeAdapters.isBaleKey) == "function" and SGNativeAdapters.isBaleKey(rec.carrierKey)
    return {
        stockRef = rec.stockRef, amount = rec.observedAmount, amountUnit = unitToken(rec.amountUnit), materialName = name,
        materialSupported = name ~= nil and m:materialSupported(name),
        quality = rec.properties and rec.properties[P.QUALITY_PROPERTY] or nil,
        conditionRequired = isBale == true and name ~= nil and P.BALE_CONDITION_MATERIALS[name] == true,
        conditionAvailable = false,   -- SOIL_BALE_CONDITION_V1 is bound in Part 3
        readRevision = readRevision,
    }
end

--- One stock's current read through sg3.assessmentInputs, or nil and a reason.
function A.read(m, stockRef)
    if m.inputsLease == nil or type(m.handle.readMaterial) ~= "function" then return nil, "UNAVAILABLE" end
    local ok, res = pcall(m.handle.readMaterial, m.inputsLease, { stockRefs = { stockRef }, propertyIds = { P.QUALITY_PROPERTY }, purpose = "ASSESSMENT" })
    if not ok or type(res) ~= "table" or res.state ~= "READY" then return nil, "UNAVAILABLE" end
    local rec = res.records and res.records[1] or nil
    if type(rec) ~= "table" or rec.state ~= "READY" then return nil, "SOURCE_CHANGED" end
    return rec
end

--- resolveResident(context): the derived record for one stock, or nil and a reason.
function A.resolve(m, context)
    -- While the release is locked the player projection is withheld (:354), so SG-1's view, which
    -- resolves every resident property of a row before asking its disclosure, computes nothing here.
    if P.RELEASE_LOCKED and context.purpose == "PLAYER_VIEW" then return nil, "DISCLOSURE_DENIED" end
    local rec, why = A.read(m, context.stockRef)
    if rec == nil then return nil, why end
    local rev = A.revisionFor(m, rec.stockRef)
    local snap = A.snapshotOf(m, rec, rev)
    local food = E.evaluateUse(snap, P.FOOD, P.FOOD_PROFILE, P.REVISION)
    local feed = E.evaluateUse(snap, P.FEED, P.FEED_PROFILE, P.REVISION)
    return { propertyId = P.ASSESSMENTS_PROPERTY, schemaVersion = P.SCHEMA_VERSION, producerId = P.PRODUCER_ID, propertyRevision = rev,
             knowledge = "KNOWN", payload = { schemaVersion = 1, representation = P.UNIFORM, food = food, feed = feed } }
end

--- getResidentRevision(context): stable while the stock's inputs are unchanged.
function A.revision(m, context)
    return A.revisionFor(m, context.stockRef)
end

--- The property spec registered with SG-1.
function A.spec(m)
    return {
        schemaVersion = P.SCHEMA_VERSION, producerId = P.PRODUCER_ID, residency = "OWNER_RESOLVED",
        validate = function(record)
            local pl = type(record) == "table" and record.payload or nil
            return type(pl) == "table" and pl.schemaVersion == 1 and type(pl.food) == "table" and type(pl.feed) == "table", "PAYLOAD"
        end,
        -- Derived, never stored, so never carried on a contribution.
        combine = function() return nil, "DERIVED" end,
        transform = function() return nil, "DERIVED" end,
        disclosure = function() return nil, "DISCLOSURE_DENIED" end,
        resolveResident = function(context) return A.resolve(m, context) end,
        getResidentRevision = function(context) return A.revision(m, context) end,
    }
end
