-- =========================================================
-- FS25_StockGuard - SG-3, the food and feed grading member (SG-3 Part 2.1)
-- =========================================================
-- SG-3 brief :29, :360, :384-401: SG-3 is a member inside StockGuard, installed at trusted server
-- initialisation after SG-1 (main.lua's native kernel install, before the restore barrier, so a
-- saved qualityBasisV1 finds its producer). It registers:
--   * qualityBasisV1, the STORED causal quality property (SG3Quality);
--   * sg3.assessments, the derived OWNER_RESOLVED assessment (SG3Assessments);
--   * sg3.assessmentInputs, its own SG-1 consumer reading qualityBasisV1 only (:397);
--   * CROP_FOOD_V1 and CROP_FEED_V1, through the member's own registerUseProfile (:244, :384).
-- and publishes g_currentMission.stockGuard.sg3: readiness and the server-local assessMaterialUse
-- (:386), which calls the same pure evaluateUse as the resident resolver.
--
-- SERVER ONLY. A client registers nothing; it learns an assessment only through the player view,
-- whose projection is LOCKED in this part.
--
-- NOT IN THIS PART (Bob's R-15, 2026-10-07): third-party use profiles (:384) are WITHHELD. The member
-- registers its two built-ins itself, and registerUseProfile is not published: a handle that took any
-- profile and then always answered UNSUPPORTED_PROFILE would mislead a mod that feature-detects it.
-- TMR_FEED_V1 follows; the mower's birth and the square-bale carry are Part 2.2, and the square bale's
-- condition profile SOIL_BALE_CONDITION_V1 is Part 3 (SG3Condition).

SG3 = SG3 or {}
local S = SG3
local P = SG3Profiles
local E = SG3Evaluator

S.current = nil
S.BUILTIN = {
    { id = P.FOOD_PROFILE, version = 1, definition = { use = P.FOOD, revision = P.REVISION } },
    { id = P.FEED_PROFILE, version = 1, definition = { use = P.FEED, revision = P.REVISION } },
}

local Member = {}
Member.__index = Member

local function log(msg) print("[StockGuard] SG-3: " .. tostring(msg)) end

--- The fill types the admitted crops' primary outputs are, by name (:155: resolved from the actual
--- fruit descriptors, never assumed). Built on first use from the live FruitTypeManager.
function Member:cropOutputs()
    if self.outputs ~= nil then return self.outputs end
    local out = {}
    local ftm = g_fruitTypeManager
    local list = ftm ~= nil and type(ftm.getFruitTypes) == "function" and ftm:getFruitTypes() or {}
    for _, desc in pairs(list) do
        if type(desc) == "table" and P.cropOf(desc.name) ~= nil and type(ftm.getFillTypeNameByFruitTypeIndex) == "function" then
            -- FruitTypeManager.lua:248-251: the descriptor's own fill type, by name.
            local name = ftm:getFillTypeNameByFruitTypeIndex(desc.index)
            if type(name) == "string" then out[name] = true end
        end
    end
    self.outputs = out
    return out
end

--- Is this material on the crop ladder at all: an admitted crop's primary output or a Feed-only output.
function Member:materialSupported(name)
    return P.FEED_ONLY[name] == true or self:cropOutputs()[name] == true
end

--- registerUseProfile(ownerId, id, version, definition) -> lease or nil, reason (:384). The member's
--- own, for its built-ins at install; not published while third-party profiles are WITHHELD. A
--- duplicate live id refuses.
function Member:registerUseProfile(ownerId, id, version, definition)
    if type(ownerId) ~= "string" or ownerId == "" or type(id) ~= "string" or id == "" then return nil, "INVALID_ID" end
    if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then return nil, "VERSION" end
    if type(definition) ~= "table" or (definition.use ~= P.FOOD and definition.use ~= P.FEED) or type(definition.revision) ~= "string" then return nil, "DEFINITION" end
    if self.useProfiles[id] ~= nil then return nil, "DUPLICATE_OWNER" end
    local lease = { ownerId = ownerId, id = id, version = version, use = definition.use, revision = definition.revision }
    self.useProfiles[id] = lease
    return lease
end

--- The capability and readiness the member publishes (:360).
function Member:readiness()
    local profiles = {}
    for id, lease in pairs(self.useProfiles) do profiles[#profiles + 1] = { id = id, use = lease.use, revision = lease.revision } end
    table.sort(profiles, function(a, b) return a.id < b.id end)
    return { schema = "SG3_READINESS_1", ready = self.ready == true, qualityProfile = P.SCORE_PROFILE, qualityRevision = P.REVISION,
             useProfiles = profiles, playerProjection = P.RELEASE_LOCKED and "LOCKED" or "OPEN" }
end

--- assessMaterialUse(consumerLease, query, use, profileId) -> Result (:386). Server-local. The caller's
--- own registered consumer reads the material (it must admit qualityBasisV1); several stocks are one
--- composite on their combined basis, through the same combine.
function Member:assessMaterialUse(consumerLease, query, use, profileId)
    local profile = self.useProfiles[profileId]
    local revision = profile ~= nil and profile.use == use and profile.revision or nil
    local function unavailable(reason)
        return { state = "UNAVAILABLE", representation = P.UNIFORM, use = use, profileId = profileId, profileRevision = revision,
                 knowledge = "UNAVAILABLE", suitability = "UNAVAILABLE", reasons = { reason }, stockRefs = {}, propertyRevisions = {} }
    end
    local ok, res = pcall(self.handle.readMaterial, consumerLease, query)
    -- A lease that is not a live consumer, or a context its resolver refused, reads nothing (:386).
    if ok and type(res) == "table" and res.state == "DENIED" then return unavailable("DISCLOSURE_DENIED") end
    if not ok or type(res) ~= "table" or res.state ~= "READY" then return unavailable("SOURCE_CHANGED") end
    -- Every asked stock must be read as it is now: a stale or vanished one makes the whole answer
    -- unavailable, never a composite that silently left it out (:386, "identify every contributing snapshot").
    local snaps = {}
    for _, rec in ipairs(res.records or {}) do
        if rec.state ~= "READY" then return unavailable("SOURCE_CHANGED") end
        snaps[#snaps + 1] = SG3Assessments.snapshotOf(self, rec, SG3Assessments.revisionFor(self, rec.stockRef))
    end
    if #snaps == 0 then return unavailable("SOURCE_CHANGED") end
    if #snaps == 1 then return E.evaluateUse(snaps[1], use, profileId, revision) end
    -- Several stocks: their recorded qualities combined on the summed basis, then one evaluation.
    local entries, total, stockRefs, revisions, name, supported, condition = {}, 0, {}, {}, snaps[1].materialName, true, false
    for _, s in ipairs(snaps) do
        local e = E.recordEntry(s.quality, s.amount)
        if e == nil then e = E.unknownEntry(s.amount, "PROFILE_MISMATCH") end
        entries[#entries + 1] = e
        total = total + (E.finite(s.amount) and s.amount or 0)
        stockRefs[#stockRefs + 1] = s.stockRef
        if type(s.quality) == "table" then revisions[#revisions + 1] = { propertyId = P.QUALITY_PROPERTY, propertyRevision = s.quality.propertyRevision } end
        if s.materialName ~= name then name = nil end
        supported = supported and s.materialSupported
        condition = condition or s.conditionRequired
    end
    local composite = E.combine(entries, total, nil)
    local quality = composite ~= nil and { propertyId = P.QUALITY_PROPERTY, schemaVersion = 1, producerId = P.PRODUCER_ID, propertyRevision = 0,
        knowledge = composite.knowledge, knownAmount = composite.knownAmount, basisAmount = composite.basisAmount, amountUnit = snaps[1].amountUnit,
        payload = composite.payload } or nil
    self.nextRevision = self.nextRevision + 1
    local r = E.evaluateUse({ stockRef = snaps[1].stockRef, amount = total, amountUnit = snaps[1].amountUnit, materialName = name,
        materialSupported = supported, quality = quality, conditionRequired = condition, conditionAvailable = false, readRevision = self.nextRevision },
        use, profileId, revision)
    r.stockRefs, r.propertyRevisions = stockRefs, revisions
    return r
end

--- The trusted resolver of sg3.assessmentInputs: only actual current material references (:397).
local function inputsContext(query)
    if type(query) ~= "table" or type(query.stockRefs) ~= "table" then return nil, "QUERY" end
    for _, ref in ipairs(query.stockRefs) do
        if type(ref) ~= "table" or ref.stockId == nil then return nil, "STOCK_REF" end
    end
    return { stockRefs = query.stockRefs, purpose = query.purpose or "ASSESSMENT" }
end

--- Install on this mission's StockGuard handle. Server only. Returns the member, or nil and a reason.
function S.install(handle)
    if g_server == nil then return nil, "CLIENT" end
    if type(handle) ~= "table" or type(handle.registerProperty) ~= "function" then return nil, "NO_HANDLE" end
    local m = setmetatable({ handle = handle, useProfiles = {}, revisions = {}, nextRevision = 0, ready = false,
                             damageProfiles = {}, witnesses = {}, invalid = {}, inFlight = {} }, Member)
    local why
    m.qualityLease, why = handle.registerProperty(P.QUALITY_PROPERTY, SG3Quality.spec())
    if m.qualityLease == nil then return nil, "QUALITY_PROPERTY:" .. tostring(why) end
    m.assessmentsLease, why = handle.registerProperty(P.ASSESSMENTS_PROPERTY, SG3Assessments.spec(m))
    if m.assessmentsLease == nil then return nil, "ASSESSMENTS_PROPERTY:" .. tostring(why) end
    m.inputsLease, why = handle.registerConsumer(P.INPUTS_CONSUMER, { version = 1, requiredSchemas = { [P.QUALITY_PROPERTY] = 1 },
        materialKinds = { "FILL_TYPE", "NATIVE_GROUP" }, resolveReadContext = inputsContext })
    if m.inputsLease == nil then return nil, "INPUTS_CONSUMER:" .. tostring(why) end
    for _, b in ipairs(S.BUILTIN) do
        local lease, whyP = m:registerUseProfile(P.PRODUCER_ID, b.id, b.version, b.definition)
        if lease == nil then return nil, "USE_PROFILE:" .. tostring(whyP) end
    end
    -- [SG-3 Part 3] SOIL_BALE_CONDITION_V1 registered at trusted server initialization, then Soil's listener
    -- bound; a refusal is retried once at mission start (SG3Condition.installRetryHook).
    if SG3Condition ~= nil then
        local dl, whyD = SG3Condition.registerDamageProfile(m, SG3Condition.OWNER_ID, SG3Condition.PROFILE_ID, SG3Condition.PROFILE_VERSION, SG3Condition.definition())
        if dl == nil then return nil, "DAMAGE_PROFILE:" .. tostring(whyD) end
        S.current = m
        SG3Condition.bind(m)
        SG3Condition.installRetryHook()
    end
    m.ready = true
    handle.sg3 = {
        getReadiness = function() return m:readiness() end,
        assessMaterialUse = function(consumerLease, query, use, profileId) return m:assessMaterialUse(consumerLease, query, use, profileId) end,
    }
    S.current = m
    log("installed: qualityBasisV1 and sg3.assessments registered; player projection " .. (P.RELEASE_LOCKED and "LOCKED" or "OPEN"))
    return m
end

--- The member's end with its mission: readiness and caches cleared; stored records stay with SG-1.
function S.teardown(handle)
    if type(handle) == "table" then handle.sg3 = nil end
    if S.current ~= nil and SG3Condition ~= nil then SG3Condition.teardown(S.current) end
    if S.current ~= nil then
        S.current.ready = false
        S.current.revisions = {}
    end
    S.current = nil
end
