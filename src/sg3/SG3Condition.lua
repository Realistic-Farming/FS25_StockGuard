-- =========================================================
-- FS25_StockGuard - SOIL_BALE_CONDITION_V1, SG-3's damage witness intake (SG-3 Part 3)
-- =========================================================
-- SG-3 brief, "Damage witness intake owned by SG-3" and "Exact SG3 / F215 condition read and
-- notification contract"; Bob's R-15 of 2026-10-08 (Desk Office/Drafts/BOB-R15-SG3-PART3-SOIL-BALE-
-- CONDITION-2026-10-08.md). Soil is the condition owner (F215's YardLadder): it publishes each bale
-- portion's irreversible condition C. SG-3 interprets it into qualityBasisV1's remainingScore with
-- r(C) = max(0, 1 - min(C,100)/100): a change from C0 to C1 multiplies remainingScore by r(C1)/r(C0),
-- and a portion at r(C0) = 0 keeps zero.
--
-- THE PROFILE. registerDamageProfile is server-local and member-internal, never on the handle: SG3.install
-- registers ("sg3", "SOIL_BALE_CONDITION_V1", 1) before it binds Soil's listener.
--
-- THE LISTENER. Bound at the member's install (trusted server initialization). Soil arms its provider in its
-- own mission load, and the two mods' order is not guaranteed, so a refusal is retried once at mission
-- start (FSBaseMission.onStartMission); a second refusal is logged once and every bale that needs this
-- profile reads CONDITION_UNAVAILABLE. Never saved.
--
-- ROUTE 1, A JOINED OPERATION (Soil's event carries the open StockGuard operation, today the square
-- baler's finish): the paired event is queued under that operation, transient; the finish bracket
-- collects the queue into its outcomeEvidence (sg3ConditionWitnesses) before its one settle, and
-- SG3Quality's combine applies the birth handicap from C0 = 0 to the bale it made, once, while its
-- transformCausalState seeds the bale's accepted cause. An event naming an operation that is not open
-- queues nothing and invalidates its bale.
--
-- ROUTE 2, NO OPERATION, a daily ADVANCE with the binding, type and quantity unchanged: the absolute record
-- is published through publishProperties under the stream's cause, ALREADY_APPLIED for a replay. Missed
-- ADVANCEs are closed by the cumulative ratio only inside the next ADVANCE, and only under the brief's
-- delta rule. Anything else (a missing before, a changed binding, a REBIND or RETIRE with no operation, a
-- RESET) is not guessed: the bale's current assessment is unavailable until coverage is proved again.
--
-- THE CAUSE KEY. SG-1 keys a cause by its sourceStreamId and an INTEGER epoch (SGOperations
-- publishProperties). Soil's sourceEpoch is a string token, so it rides in the stream key
-- ("<sourceEpoch>|<sourceStreamId>") and SG-1's epoch slot carries the portion's conditionGeneration.

SG3Condition = SG3Condition or {}
local C = SG3Condition
local P = SG3Profiles
local E = SG3Evaluator

C.OWNER_ID = "sg3"
C.PROFILE_ID = "SOIL_BALE_CONDITION_V1"
C.PROFILE_VERSION = 1
C.LISTENER_ID = "sg3"
C.SOURCE_SCHEMA = "SG_SOIL_CONDITION_1"
C.SOURCE_VERSION = 1
C.HOOK_ID = "sg3ConditionBind"
C.joinLogged = C.joinLogged or false

local function log(msg) print("[StockGuard] SG-3: " .. tostring(msg)) end
local function finite(n) return E.finite(n) end
local function deep(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep(x) end
    return out
end

-- ── the interpretation ─────────────────────────────────────────────────────────
--- r(C): the share of quality a condition C leaves.
function C.retention(c)
    if not finite(c) then return nil end
    return math.max(0, 1 - math.min(c, 100) / 100)
end

--- r(C1)/r(C0) for an irreversible increase C0 to C1; zero stays zero; nil for a fall or a non-number.
function C.ratio(c0, c1)
    local r0, r1 = C.retention(c0), C.retention(c1)
    if r0 == nil or r1 == nil or c1 < c0 then return nil end
    if r0 <= 0 then return 0 end
    return r1 / r0
end

--- The definition SG3.install registers.
function C.definition()
    return { materials = P.BALE_CONDITION_MATERIALS, sourceSchema = C.SOURCE_SCHEMA, sourceVersion = C.SOURCE_VERSION,
             requiredForCurrent = true, cumulative = "EQUAL_DELTA", transform = C.ratio }
end

--- registerDamageProfile(ownerId, id, version, definition) -> lease or nil, reason. Member-internal.
function C.registerDamageProfile(m, ownerId, id, version, definition)
    if g_server == nil then return nil, "NOT_SERVER" end
    if type(ownerId) ~= "string" or ownerId == "" or type(id) ~= "string" or id == "" then return nil, "INVALID_ID" end
    if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then return nil, "VERSION" end
    if type(definition) ~= "table" or type(definition.transform) ~= "function" or type(definition.materials) ~= "table"
        or type(definition.sourceSchema) ~= "string" or type(definition.requiredForCurrent) ~= "boolean" then
        return nil, "DEFINITION"
    end
    if m.damageProfiles[id] ~= nil then return nil, "DUPLICATE_PROFILE" end
    local lease = { ownerId = ownerId, id = id, version = version, definition = definition }
    m.damageProfiles[id] = lease
    return lease
end

-- ── coordinates, keys and the fingerprint ───────────────────────────────────────
--- The stream key a portion's coordinates sit under (Soil's epoch is a string; see THE CAUSE KEY).
function C.streamKey(p)
    if type(p) ~= "table" or type(p.sourceEpoch) ~= "string" or type(p.sourceStreamId) ~= "string" then return nil end
    return p.sourceEpoch .. "|" .. p.sourceStreamId
end

--- The covered coordinates kept on qualityBasisV1 for one portion.
function C.coordinates(p)
    return { historyId = p.historyId, sourceStreamId = p.sourceStreamId, sourceEpoch = p.sourceEpoch,
             conditionGeneration = p.conditionGeneration, eventSequence = p.eventSequence,
             portionRevision = p.portionRevision, condition = p.condition }
end

local function sameBranch(a, b)
    return type(a) == "table" and type(b) == "table" and a.historyId == b.historyId and a.sourceStreamId == b.sourceStreamId
        and a.sourceEpoch == b.sourceEpoch and a.conditionGeneration == b.conditionGeneration
end

--- The canonical witness fingerprint (SG_VALUES_2, SGValues.canonicalKey) of a portion after its change.
function C.fingerprint(p)
    if SGValues == nil then return nil end
    return SGValues.canonicalKey({ owner = C.OWNER_ID, profile = C.PROFILE_ID, version = C.PROFILE_VERSION,
        historyId = tostring(p.historyId), stream = tostring(p.sourceStreamId), epoch = tostring(p.sourceEpoch),
        generation = p.conditionGeneration, sequence = p.eventSequence, revision = p.portionRevision, condition = p.condition })
end

local function integerGeneration(p) return type(p.conditionGeneration) == "number" and p.conditionGeneration >= 1 and p.conditionGeneration % 1 == 0 end

-- ── the bale's carrier and stock ────────────────────────────────────────────────
local function baleCarrierId(uid)
    if type(uid) ~= "string" or uid == "" or SGNativeAdapters == nil or SGRecords == nil then return nil end
    return SGRecords.carrierKeyString({ adapterId = SGNativeAdapters.NATIVE_ADAPTER_ID, nativeOwnerKey = uid,
                                        componentKey = SGNativeAdapters.KIND_BALE })
end

local function operations()
    local sg = StockGuard ~= nil and type(StockGuard.hostOf) == "function" and StockGuard.hostOf(g_currentMission) or nil
    return sg ~= nil and sg.operations or nil
end

--- The bale's current StockRef from its native unique id, or nil.
function C.stockRefOf(uid)
    local ops, cid = operations(), baleCarrierId(uid)
    local carrier = ops ~= nil and cid ~= nil and ops.carriers[cid] or nil
    local stock = carrier ~= nil and carrier.stockId ~= nil and ops.stocks[carrier.stockId] or nil
    if stock == nil then return nil end
    return ops:stockRef(stock)
end

--- Is this operation the open native bracket's (on the host's bracket stack and still open in SG-1)?
function C.isOpen(operationId)
    if type(operationId) ~= "string" then return false end
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    local stack = host ~= nil and host.openOperations or nil
    local onStack = false
    for _, id in ipairs(stack or {}) do if id == operationId then onStack = true break end end
    local ops = operations()
    return onStack and ops ~= nil and ops.openHandles[operationId] ~= nil
end

-- ── the listener ───────────────────────────────────────────────────────────────
local function uidOf(ev)
    return type(ev) == "table" and type(ev.nativeIds) == "table" and ev.nativeIds[1] or nil
end

function C.invalidate(m, uid, reason)
    if type(uid) == "string" then m.invalid[uid] = reason or "INVALIDATED" end
end

--- beforeChange: the transient in-flight mark and a ticket. A no-operation ADVANCE also captures the bale's
--- current StockRef, so its after can be published against exactly that material.
function C.before(m, ev)
    local uid = uidOf(ev)
    if uid ~= nil then m.inFlight[uid] = true end
    local ticket = { kind = ev.kind, carrierEventSequence = ev.carrierEventSequence, beforeCarrierRevision = ev.beforeCarrierRevision,
                     uid = uid, operationId = ev.operationId }
    if ev.kind == "ADVANCE" and ev.operationId == nil and uid ~= nil then ticket.stockRef = C.stockRefOf(uid) end
    return ticket
end

--- afterChange: paired with its before, then one of the two routes, or invalidation.
function C.after(m, ev, ticket)
    local uid = uidOf(ev)
    if uid ~= nil then m.inFlight[uid] = nil end
    if type(ticket) ~= "table" or ticket.kind ~= ev.kind or ticket.carrierEventSequence ~= ev.carrierEventSequence
        or ticket.operationId ~= ev.operationId then
        return C.invalidate(m, uid, "PAIR_MISMATCH")
    end
    if ev.result ~= "APPLIED" then return C.invalidate(m, uid, "RESULT_" .. tostring(ev.result)) end
    if ev.operationId ~= nil then
        -- Route 1: queued under the open operation, for its own bracket to collect before its settle.
        if not C.isOpen(ev.operationId) then return C.invalidate(m, uid, "OPERATION_NOT_OPEN") end
        local list = m.witnesses[ev.operationId] or {}
        list[#list + 1] = { kind = ev.kind, nativeBaleUniqueId = uid, carrierEventSequence = ev.carrierEventSequence,
                            portionsBefore = deep(ev.portionsBefore or {}), portionsAfter = deep(ev.portionsAfter or {}) }
        m.witnesses[ev.operationId] = list
        return
    end
    if ev.kind == "ADVANCE" then return C.advance(m, ev, ticket) end
    if ev.kind == "RETIRE" then
        m.invalid[uid or ""] = nil   -- the bale is gone; nothing remains to assess
        return
    end
    -- A BIRTH, REBIND or RESET with no joined operation (a bale born outside the square finish, a storage move):
    -- not guessed (route 2 covers ADVANCE only here).
    local why = (ev.kind == "BIRTH" and "BIRTH_UNJOINED") or (ev.kind == "REBIND" and "REBIND_UNJOINED") or "RESET_UNSUPPORTED"
    return C.invalidate(m, uid, why)
end

--- The listener's callbacks for one member.
function C.callbacks(m)
    return {
        beforeChange = function(ev) return C.before(m, ev) end,
        afterChange = function(ev, ticket) C.after(m, ev, ticket) end,
        invalidate = function(uid, reason) C.invalidate(m, uid, reason) end,
    }
end

-- ── route 1: the collection the finish bracket makes before its settle ─────────
--- Every witness queued under this operation, removed from the queue (settle and abandon both clear it).
--- Internal: the live SG-2 integration closure calls it, never a handle method.
function C.collect(operationId)
    local m = SG3 ~= nil and SG3.current or nil
    if m == nil or type(operationId) ~= "string" then return nil end
    local list = m.witnesses[operationId]
    m.witnesses[operationId] = nil
    return list
end

--- The BIRTH witness for a bale candidate in a settle context, or nil. The finish bracket tags its
--- witnesses with the bale's slot and native id (outcomeEvidence.sg3ConditionWitnesses).
function C.birthWitness(ctx, cand)
    local ev = ctx ~= nil and ctx.report ~= nil and ctx.report.outcomeEvidence or nil
    local cw = type(ev) == "table" and ev.sg3ConditionWitnesses or nil
    if type(cw) ~= "table" or cand == nil or cand.slotId == nil or cand.slotId ~= cw.slotId then return nil end
    for _, w in ipairs(cw.witnesses or {}) do
        if w.kind == "BIRTH" and w.nativeBaleUniqueId == cw.nativeBaleUniqueId and #(w.portionsBefore or {}) == 0
            and #(w.portionsAfter or {}) == 1 then
            local p = w.portionsAfter[1]
            if C.streamKey(p) ~= nil and integerGeneration(p) and finite(p.condition) then return p end
        end
    end
    return nil
end

--- Apply the birth handicap r(C1)/r(0) to a freshly combined payload, once, and record its coverage.
function C.applyBirth(payload, p)
    if type(payload) ~= "table" or not finite(payload.remainingScore) then return false end
    local ratio = C.ratio(0, p.condition)
    if ratio == nil then return false end
    payload.remainingScore = payload.remainingScore * ratio
    payload.coveredConditionCoordinates = { [C.streamKey(p)] = C.coordinates(p) }
    if not C.joinLogged then
        C.joinLogged = true
        log(string.format("first square bale joined to Soil's bale condition (condition %.2f, retention %.4f). Logged once per launch.", p.condition, ratio))
    end
    return true
end

--- qualityBasisV1's transformCausalState: a joined bale birth seeds the stream's accepted cause at its
--- sequence; every other candidate keeps the floor as carried (nil).
function C.transformCausalState(ctx, _sources, candidate)
    local ref = type(candidate) == "table" and candidate.stockRef or nil
    if ref == nil or ctx == nil or type(ctx.candidates) ~= "table" then return nil end
    for _, cand in pairs(ctx.candidates) do
        if type(cand.stockRef) == "table" and cand.stockRef.stockId == ref.stockId then
            local p = C.birthWitness(ctx, cand)
            if p == nil then return nil end
            local fp = C.fingerprint(p)
            if fp == nil then return nil end
            return { [C.streamKey(p) .. "/" .. tostring(p.conditionGeneration)] = { sequence = p.eventSequence, fingerprint = fp } }
        end
    end
    return nil
end

-- ── route 2: a daily ADVANCE with no operation ─────────────────────────────────
--- qualityBasisV1's validateCause: only this profile's stamp, registered, continuing the stream it
--- covered (the next sequence, or a cumulative close whose base is the accepted one).
function C.validateCause(cause, accepted, _target)
    local m = SG3 ~= nil and SG3.current or nil
    if m == nil or m.damageProfiles[C.PROFILE_ID] == nil then return nil, "NO_DAMAGE_PROFILE" end
    if type(cause) ~= "table" or cause.ownerId ~= C.OWNER_ID or cause.profileId ~= C.PROFILE_ID or cause.profileVersion ~= C.PROFILE_VERSION then
        return nil, "PROFILE"
    end
    if type(accepted) ~= "table" then return nil, "UNCOVERED" end
    if cause.sequence == accepted.sequence + 1 then return true end
    if cause.cumulative == true and cause.coveredSequence == accepted.sequence and cause.sequence > accepted.sequence then return true end
    return nil, "SEQUENCE_GAP"
end

--- The ADVANCE's absolute record, published once under its cause.
function C.advance(m, ev, ticket)
    local uid = uidOf(ev)
    local b = ev.portionsBefore and ev.portionsBefore[1] or nil
    local a = ev.portionsAfter and ev.portionsAfter[1] or nil
    if #(ev.portionsBefore or {}) ~= 1 or #(ev.portionsAfter or {}) ~= 1 then return C.invalidate(m, uid, "PORTIONED") end
    if ticket.stockRef == nil then return C.invalidate(m, uid, "BEFORE_MISSING") end
    local ref = C.stockRefOf(uid)
    if ref == nil or ref.stockId ~= ticket.stockRef.stockId or ref.contentsGeneration ~= ticket.stockRef.contentsGeneration then
        return C.invalidate(m, uid, "BINDING_CHANGED")
    end
    if not sameBranch(a, b) or C.streamKey(a) == nil or not integerGeneration(a) or not finite(a.condition) or not finite(b.condition) then
        return C.invalidate(m, uid, "BRANCH_CHANGED")
    end
    local rec = SG3Assessments.read(m, ref)
    local q = rec ~= nil and rec.properties ~= nil and rec.properties[P.QUALITY_PROPERTY] or nil
    if type(q) ~= "table" or q.knowledge ~= "KNOWN" or type(q.payload) ~= "table" or not finite(q.payload.remainingScore) then
        return C.invalidate(m, uid, "QUALITY_UNKNOWN")
    end
    local key = C.streamKey(a)
    local cov = type(q.payload.coveredConditionCoordinates) == "table" and q.payload.coveredConditionCoordinates[key] or nil
    if not sameBranch(cov, b) or not finite(cov.condition) then return C.invalidate(m, uid, "CONDITION_GAP") end
    local cause = { ownerId = C.OWNER_ID, profileId = C.PROFILE_ID, profileVersion = C.PROFILE_VERSION, sourceStreamId = key,
                    epoch = a.conditionGeneration, sequence = a.eventSequence, fingerprint = C.fingerprint(a) }
    if cov.eventSequence == a.eventSequence and cov.portionRevision == a.portionRevision then
        -- A replay of the event this record already covers: the same cause, unchanged, for SG-1 to answer
        -- (ALREADY_APPLIED for the same fingerprint, CAUSE_CONFLICT for another).
        local ok, status = pcall(m.handle.publishProperties, m.qualityLease,
            { { stockRef = ref, record = q, expectedPropertyRevision = q.propertyRevision } }, cause)
        if ok and status == "ALREADY_APPLIED" then return status end
        C.invalidate(m, uid, "PUBLISH_" .. tostring(ok and status or "ERROR"))
        return status
    end
    local c0, cumulative = nil, false
    if cov.eventSequence == b.eventSequence and cov.portionRevision == b.portionRevision then
        c0 = b.condition
    elseif type(cov.eventSequence) == "number" and cov.eventSequence < b.eventSequence
        and (b.eventSequence - cov.eventSequence) == (b.portionRevision - cov.portionRevision) then
        -- The cumulative recovery: the missed ADVANCEs closed from the covered condition, once.
        c0, cumulative = cov.condition, true
    else
        return C.invalidate(m, uid, "CONDITION_GAP")
    end
    local ratio = C.ratio(c0, a.condition)
    if ratio == nil then return C.invalidate(m, uid, "CONDITION_FELL") end
    local payload = deep(q.payload)
    payload.remainingScore = payload.remainingScore * ratio
    payload.coveredConditionCoordinates[key] = C.coordinates(a)
    local record = { propertyId = P.QUALITY_PROPERTY, schemaVersion = P.SCHEMA_VERSION, producerId = P.PRODUCER_ID, propertyRevision = q.propertyRevision,
                     knowledge = q.knowledge, knownAmount = q.knownAmount, basisAmount = q.basisAmount, amountUnit = q.amountUnit, payload = payload }
    cause.cumulative, cause.coveredSequence = cumulative or nil, cov.eventSequence
    local ok, status = pcall(m.handle.publishProperties, m.qualityLease,
        { { stockRef = ref, record = record, expectedPropertyRevision = q.propertyRevision } }, cause)
    if ok and (status == "APPLIED" or status == "ALREADY_APPLIED") then   -- SGOperations O.PUBLISH
        m.invalid[uid] = nil
        return status
    end
    C.invalidate(m, uid, "PUBLISH_" .. tostring(ok and status or "ERROR"))
    return status
end

-- ── the current-assessment bound ───────────────────────────────────────────────
--- For a bale whose material needs this profile: whether its current assessment may grade, and the
--- reason when not. `quality` is the bale's qualityBasisV1 record.
function C.currentFor(m, uid, quality)
    if m == nil or m.damageProfiles[C.PROFILE_ID] == nil or m.listenerLease == nil or m.provider == nil then
        return false, "CONDITION_UNAVAILABLE"
    end
    if type(uid) ~= "string" then return false, "CONDITION_UNAVAILABLE" end
    if m.inFlight[uid] then return false, "CONDITION_PENDING" end
    if m.invalid[uid] ~= nil then return false, "CONDITION_GAP" end
    local ok, r = pcall(m.provider.getBaleConditionPortions, m.provider, uid)
    if not ok or type(r) ~= "table" then return false, "CONDITION_UNAVAILABLE" end
    if r.state == "RESTORING" then return false, "CONDITION_PENDING" end
    if r.state ~= "READY" or type(r.portions) ~= "table" or #r.portions ~= 1 then return false, "CONDITION_UNAVAILABLE" end
    local p = r.portions[1]
    if p.condemned == true then return false, "CONDITION_CONDEMNED" end
    local pl = type(quality) == "table" and quality.payload or nil
    local key = C.streamKey(p)
    local cov = key ~= nil and type(pl) == "table" and type(pl.coveredConditionCoordinates) == "table" and pl.coveredConditionCoordinates[key] or nil
    if not sameBranch(cov, p) or cov.eventSequence ~= p.eventSequence or cov.portionRevision ~= p.portionRevision then
        return false, "CONDITION_GAP"
    end
    return true, nil
end

-- ── binding and its one retry ──────────────────────────────────────────────────
--- Bind Soil's provider, once. Returns true, or false and a reason.
function C.bind(m)
    if m.listenerLease ~= nil then return true end
    local sfm = g_currentMission ~= nil and g_currentMission.soilFertilityManager or nil
    if type(sfm) ~= "table" or type(sfm.registerBaleConditionListener) ~= "function" or type(sfm.getBaleConditionCapabilities) ~= "function" then
        return false, "NO_PROVIDER"
    end
    local okC, caps = pcall(sfm.getBaleConditionCapabilities, sfm)
    if not okC or type(caps) ~= "table" then return false, "UNAVAILABLE" end
    if caps.schema ~= C.SOURCE_SCHEMA or caps.version ~= C.SOURCE_VERSION then return false, "SCHEMA" end
    local ok, lease, why = pcall(sfm.registerBaleConditionListener, sfm, C.LISTENER_ID, C.callbacks(m))
    if not ok then return false, "ERROR" end
    if lease == nil then return false, why or "REFUSED" end
    m.listenerLease, m.provider = lease, sfm
    return true
end

--- The mission-start retry: one more bind; a second refusal is logged once.
function C.onStartMission()
    local m = SG3 ~= nil and SG3.current or nil
    if m == nil or m.listenerLease ~= nil or m.bindRetried then return end
    m.bindRetried = true
    local ok, why = C.bind(m)
    if not ok then log("Soil's bale condition provider is not available (" .. tostring(why) .. "); square bales read CONDITION_UNAVAILABLE") end
end

--- Install the mission-start retry once per process (SGClassHook rebinds a re-sourced install).
function C.installRetryHook()
    if SGClassHook == nil or FSBaseMission == nil or type(FSBaseMission.onStartMission) ~= "function" then return false end
    SGClassHook.append(FSBaseMission, "onStartMission", C.HOOK_ID, function() C.onStartMission() end, SG3Condition)
    return true
end

--- The member's end: the listener unbound, the transient state dropped.
function C.teardown(m)
    if m == nil then return end
    if m.listenerLease ~= nil and m.provider ~= nil and type(m.provider.unregisterBaleConditionListener) == "function" then
        pcall(m.provider.unregisterBaleConditionListener, m.provider, m.listenerLease)
    end
    m.listenerLease, m.provider = nil, nil
    m.witnesses, m.invalid, m.inFlight = {}, {}, {}
end
