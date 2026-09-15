-- =========================================================
-- FS25_StockGuard - command sessions and the one host admission path (SG-1 5)
-- =========================================================
-- The server issues one command session per (actor, route) bound to the
-- live connection or local-host context, user, acting farm and route. A
-- request carries protocolVersion 2 (SG_COMMAND_2), the session, an exact
-- positive decimal sequence, a phase (DIRECT, QUOTE, EXECUTE), the action,
-- target kind/id, expected generation/revision and arguments. One command
-- outstanding per session; the next sequence follows the acknowledged
-- result; a refused command consumes its sequence too; a duplicate of the
-- latest request returns its retained result without another mutation;
-- older or conflicting sequences refuse. Exhaustion opens a fresh session.
--
-- DIRECT is admitted only for DIRECT_DESIRED_STATE actions and reaches only
-- invoke. QUOTE calls only quoteAction, issues an opaque quoteToken bound
-- to actor, session, route, action, target revisions and payload, with the
-- earlier of owner validity and 30 real seconds (guarded getTimeSec reads,
-- non-backwards). EXECUTE requires the next sequence, the exact unused
-- token and a byte-equivalent payload; validateQuote runs before the token
-- is marked consumed and executeAction dispatched exactly once. Failure
-- before the effect is STALE_QUOTE or the owner's refusal; an exception
-- after dispatch is never proof that nothing happened.
-- =========================================================

SGCommands = SGCommands or {}
local C = SGCommands
local SGCommands_mt = { __index = C }

C.PROTOCOL_VERSION = 2
C.FORMAT = "SG_COMMAND_2"
C.SEQUENCE_LIMIT = 2147483647
C.QUOTE_SECONDS = 30
C.PHASES = { DIRECT = true, QUOTE = true, EXECUTE = true }
C.ROUTES = { STOCK = true, RECIPE_LIBRARY = true }
C.OUTCOMES = { APPLIED = true, ACCEPTED_PENDING = true, PARTIAL_UNAVAILABLE = true, REFUSED = true, STALE = true, UNAVAILABLE = true, QUOTED = true, STALE_QUOTE = true }

local copy = SGValues.copy
local isFinite = SGValues.isFinite
local nonempty = SGRecords.nonemptyString

function C.new(registry, timeSource)
    local self = setmetatable({}, SGCommands_mt)
    self.registry = registry
    self.timeSource = timeSource      -- function() -> seconds or nil
    self.sessions = {}                -- sessionId -> session
    self.byActor = {}                 -- actorKey|route -> sessionId
    self.nextSession = 0
    return self
end

local function now(self)
    local ok, t = pcall(self.timeSource)
    if not ok or not isFinite(t) or t < 0 then return nil end
    return t
end

local function actorKey(actor)
    return tostring(actor.connectionId or "local") .. "|" .. tostring(actor.userId or "") .. "|" .. tostring(actor.farmId or "")
end

-- ---------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------
--- Issue (or return) the live session for an actor on a route. Credentials
--- are only advertised on READY private views with an applicable capability.
function C:issueSession(actor, route)
    if not C.ROUTES[route] then return nil, "ROUTE" end
    local availability = SGViews.actorAvailability(actor)
    if availability ~= "READY" then return nil, "ACTOR_" .. availability end
    local key = actorKey(actor) .. "|" .. route
    local existing = self.byActor[key]
    if existing ~= nil and self.sessions[existing] ~= nil then return self.sessions[existing] end
    self.nextSession = self.nextSession + 1
    local session = {
        commandSessionId = "cs" .. tostring(self.nextSession), route = route, actorKey = key, farmId = actor.farmId, userId = actor.userId,
        connectionId = actor.connectionId, nextSequence = 1, outstanding = nil, latest = nil, quote = nil,
    }
    self.sessions[session.commandSessionId] = session
    self.byActor[key] = session.commandSessionId
    return session
end

function C:withdrawSession(sessionId, reason)
    local s = self.sessions[sessionId]
    if s == nil then return false end
    self.sessions[sessionId] = nil
    if self.byActor[s.actorKey] == sessionId then self.byActor[s.actorKey] = nil end
    s.withdrawn = reason or "WITHDRAWN"
    return true
end

--- Actor, farm, permission or owner change: withdraw the matching sessions.
function C:withdrawActor(actor, reason)
    for route in pairs(C.ROUTES) do
        local key = actorKey(actor) .. "|" .. route
        local id = self.byActor[key]
        if id ~= nil then self:withdrawSession(id, reason) end
    end
end

function C:withdrawAll(reason)
    for id in pairs(self.sessions) do self:withdrawSession(id, reason) end
end

function C:credentialsFor(actor, route)
    local s = self:issueSession(actor, route)
    if s == nil then return nil end
    return { commandSessionId = s.commandSessionId, nextSequence = tostring(s.outstanding and s.outstanding.sequence or s.nextSequence) }
end

-- ---------------------------------------------------------
-- Request validation
-- ---------------------------------------------------------
local function parseSequence(s)
    if type(s) == "number" then s = string.format("%d", s) end
    if not SGValues.isCanonicalDecimal(s) or #s > 10 then return nil end
    local n = tonumber(s)
    if n == nil or n > C.SEQUENCE_LIMIT then return nil end
    return n
end
C.parseSequence = parseSequence

local function result(session, req, outcome, reasonCode, extra)
    local r = {
        protocolVersion = C.PROTOCOL_VERSION, route = req and req.route or (session and session.route) or "",
        commandSessionId = session and session.commandSessionId or "", sequence = req and tostring(req.sequence or "") or "",
        phase = req and req.phase or "", actionId = req and req.actionId or "", outcome = outcome, reasonCode = reasonCode or "",
        nextSequence = session and tostring(session.outstanding and session.outstanding.sequence or session.nextSequence) or "",
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

function C.validateRequest(req)
    if type(req) ~= "table" then return nil, "MALFORMED" end
    if req.protocolVersion ~= C.PROTOCOL_VERSION then return nil, "UNSUPPORTED_PROTOCOL" end
    if not C.ROUTES[req.route] then return nil, "ROUTE" end
    if not nonempty(req.commandSessionId, 64) then return nil, "SESSION" end
    if parseSequence(req.sequence) == nil then return nil, "SEQUENCE" end
    if not C.PHASES[req.phase] then return nil, "PHASE" end
    if not nonempty(req.actionId, 64) or not SGRegistry.TARGET_KINDS[req.targetKind] or not nonempty(req.targetId, 512) then return nil, "TARGET" end
    if req.expectedRevision ~= nil and not nonempty(req.expectedRevision, 64) then return nil, "EXPECTED_REVISION" end
    if req.expectedGeneration ~= nil and not nonempty(req.expectedGeneration, 64) then return nil, "EXPECTED_GENERATION" end
    if req.phase == "EXECUTE" and not nonempty(req.quoteToken, 128) then return nil, "QUOTE_TOKEN_REQUIRED" end
    if req.phase ~= "EXECUTE" and req.quoteToken ~= nil then return nil, "QUOTE_TOKEN_UNEXPECTED" end
    if req.arguments ~= nil and (type(req.arguments) ~= "table" or not SGRecords.isPayloadTree(req.arguments)) then return nil, "ARGUMENTS" end
    return req
end

--- Find the registered owner and action for a target.
function C:resolveAction(req, actor)
    for ownerId, lease in self.registry:each(SGRegistry.KIND_MANAGEMENT) do
        local supported = false
        for _, k in ipairs(lease.spec.targetKinds) do if k == req.targetKind then supported = true end end
        if supported then
            local okR, binding = pcall(lease.spec.resolveTarget, req.targetId)
            if okR and binding ~= nil then
                local okA, allowed = pcall(lease.spec.hasAccess, binding, copy(actor))
                if not okA or allowed ~= true then return nil, nil, nil, "UNAUTHORIZED" end
                local okG, list = pcall(lease.spec.getActions, binding, copy(actor))
                if okG and type(list) == "table" then
                    for _, a in ipairs(list) do
                        if type(a) == "table" and a.actionId == req.actionId then
                            local v = SGRegistry.validateAction(lease.spec, a)
                            if v == nil then return nil, nil, nil, "ACTION_MALFORMED" end
                            return lease, binding, v, nil
                        end
                    end
                end
                return nil, nil, nil, "ACTION_UNKNOWN"
            end
        end
    end
    return nil, nil, nil, "TARGET_UNKNOWN"
end

-- ---------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------
function C:handle(actor, req)
    local valid, why = C.validateRequest(req)
    if valid == nil then return result(nil, req, "REFUSED", why) end
    local session = self.sessions[req.commandSessionId]
    if session == nil or session.actorKey ~= actorKey(actor) .. "|" .. req.route or session.route ~= req.route then
        return result(nil, req, "REFUSED", "SESSION_INVALID")
    end
    local sequence = parseSequence(req.sequence)
    -- Outstanding pending command: only its duplicate is admitted.
    if session.outstanding ~= nil then
        if sequence == session.outstanding.sequence and session.latest ~= nil and session.latest.fingerprint == C.fingerprint(req) then
            return copy(session.latest.result)
        end
        return result(session, req, "REFUSED", "COMMAND_PENDING")
    end
    if session.latest ~= nil and sequence == session.latest.sequence then
        if session.latest.fingerprint == C.fingerprint(req) then return copy(session.latest.result) end
        return result(session, req, "REFUSED", "SEQUENCE_CONFLICT")
    end
    if sequence ~= session.nextSequence then
        return result(session, req, "REFUSED", sequence < session.nextSequence and "SEQUENCE_OLD" or "SEQUENCE_AHEAD")
    end
    local out = self:_dispatch(session, actor, req)
    -- Advance on every terminal result; ACCEPTED_PENDING keeps the sequence.
    if out.outcome == "ACCEPTED_PENDING" then
        session.outstanding = { sequence = sequence, pendingId = out.actualPendingId }
    else
        self:_advance(session, actor)
    end
    out.nextSequence = tostring(session.outstanding and session.outstanding.sequence or session.nextSequence)
    if session.commandSessionId ~= req.commandSessionId then out.commandSessionId = session.commandSessionId end
    session.latest = { sequence = sequence, fingerprint = C.fingerprint(req), result = copy(out) }
    return out
end

function C:_advance(session, actor)
    if session.nextSequence >= C.SEQUENCE_LIMIT then
        -- Exhaustion opens a fresh session instead of wrapping.
        self:withdrawSession(session.commandSessionId, "SEQUENCE_EXHAUSTED")
        local fresh = self:issueSession(actor, session.route)
        if fresh ~= nil then
            session.commandSessionId = fresh.commandSessionId
            session.nextSequence = fresh.nextSequence
            session.exhaustedInto = fresh.commandSessionId
        end
        return
    end
    session.nextSequence = session.nextSequence + 1
end

--- Byte-equivalent request fingerprint through the canonical codec.
function C.fingerprint(req)
    return SGValues.canonicalKey({ route = req.route, session = req.commandSessionId, sequence = tostring(req.sequence), phase = req.phase, actionId = req.actionId,
        targetKind = req.targetKind, targetId = req.targetId, expectedRevision = req.expectedRevision, expectedGeneration = req.expectedGeneration,
        quoteToken = req.quoteToken, arguments = req.arguments }) or ""
end

function C:_dispatch(session, actor, req)
    local lease, binding, action, why = self:resolveAction(req, actor)
    if lease == nil then return result(session, req, why == "UNAUTHORIZED" and "REFUSED" or "UNAVAILABLE", why) end
    if not action.available then return result(session, req, "UNAVAILABLE", action.reasonCode) end
    if req.targetKind == "STOCK" and req.expectedGeneration == nil then return result(session, req, "REFUSED", "EXPECTED_GENERATION_REQUIRED") end
    if req.expectedRevision == nil then return result(session, req, "REFUSED", "EXPECTED_REVISION_REQUIRED") end
    if req.expectedRevision ~= action.expectedRevision or (action.expectedGeneration ~= nil and req.expectedGeneration ~= action.expectedGeneration) then
        return result(session, req, "STALE", "TARGET_REVISION", { currentTarget = C.currentTarget(lease, binding, actor, req) })
    end
    if req.phase == "DIRECT" then
        if action.admission ~= "DIRECT_DESIRED_STATE" then return result(session, req, "REFUSED", "QUOTE_REQUIRED") end
        local ok, outcome, detail = pcall(lease.spec.invoke, binding, copy(actor), copy(action), copy(req.arguments or {}))
        if not ok then return result(session, req, "UNAVAILABLE", "OWNER_ERROR") end
        return C.ownerResult(session, req, outcome, detail)
    elseif req.phase == "QUOTE" then
        if action.admission ~= "QUOTED" then return result(session, req, "REFUSED", "NOT_QUOTABLE") end
        local t = now(self)
        if t == nil then return result(session, req, "UNAVAILABLE", "TIME_UNAVAILABLE") end
        local ok, quote, reason = pcall(lease.spec.quoteAction, binding, copy(actor), copy(req.arguments or {}))
        if not ok then return result(session, req, "UNAVAILABLE", "OWNER_ERROR") end
        if type(quote) ~= "table" or type(quote.offer) ~= "table" then return result(session, req, "REFUSED", tostring(reason or "QUOTE_REFUSED")) end
        local offer, whyO = C.validateOffer(quote.offer)
        if offer == nil then return result(session, req, "UNAVAILABLE", "OFFER_INVALID:" .. whyO) end
        local validity = isFinite(quote.validitySeconds) and math.max(0, math.min(C.QUOTE_SECONDS, quote.validitySeconds)) or C.QUOTE_SECONDS
        self.nextQuote = (self.nextQuote or 0) + 1
        local token = "q" .. tostring(self.nextQuote) .. "." .. session.commandSessionId
        -- At most one unused quote per session: a new quote replaces it.
        session.quote = {
            token = token, issuedAt = t, validity = validity, actionId = req.actionId, targetKind = req.targetKind, targetId = req.targetId,
            expectedRevision = req.expectedRevision, expectedGeneration = req.expectedGeneration, payloadKey = SGValues.canonicalKey(req.arguments or {}),
            ownerQuoteRef = quote.ownerQuoteRef, readSet = quote.readSet, offer = offer, consumed = false, ownerId = lease.ownerId,
        }
        return result(session, req, "QUOTED", "", { quoteToken = token, offer = offer, validityRemainingMs = math.floor(validity * 1000) })
    else -- EXECUTE
        local q = session.quote
        if q == nil or q.token ~= req.quoteToken or q.consumed then return result(session, req, "STALE_QUOTE", "QUOTE_UNKNOWN") end
        local t = now(self)
        if t == nil or t < q.issuedAt or (t - q.issuedAt) >= q.validity then
            session.quote = nil
            return result(session, req, "STALE_QUOTE", "QUOTE_EXPIRED")
        end
        if q.actionId ~= req.actionId or q.targetKind ~= req.targetKind or q.targetId ~= req.targetId or q.expectedRevision ~= req.expectedRevision
            or q.expectedGeneration ~= req.expectedGeneration or q.payloadKey ~= SGValues.canonicalKey(req.arguments or {}) or q.ownerId ~= lease.ownerId then
            session.quote = nil
            return result(session, req, "STALE_QUOTE", "QUOTE_MISMATCH")
        end
        local okV, still, reason = pcall(lease.spec.validateQuote, binding, copy(actor), copy(req.arguments or {}), q.ownerQuoteRef, copy(q.readSet))
        if not okV or still ~= true then
            session.quote = nil
            return result(session, req, "STALE_QUOTE", tostring(okV and (reason or "QUOTE_INVALID") or "OWNER_ERROR"))
        end
        q.consumed = true
        local dispatchIdentity = { commandSessionId = session.commandSessionId, sequence = tostring(req.sequence), quoteToken = q.token }
        local ok, outcome, detail = pcall(lease.spec.executeAction, binding, copy(actor), copy(req.arguments or {}), q.ownerQuoteRef, dispatchIdentity)
        session.quote = nil
        if not ok then
            -- After dispatch an exception is not proof that nothing happened.
            return result(session, req, "UNAVAILABLE", "OWNER_ERROR_AFTER_DISPATCH")
        end
        return C.ownerResult(session, req, outcome, detail)
    end
end

--- Map an owner's outcome into the typed result.
function C.ownerResult(session, req, outcome, detail)
    detail = type(detail) == "table" and detail or {}
    if outcome == "APPLIED" then
        return result(session, req, "APPLIED", tostring(detail.reasonCode or ""), { resultingRevision = detail.resultingRevision, currentTarget = detail.currentTarget })
    elseif outcome == "ACCEPTED_PENDING" then
        if not nonempty(detail.pendingId, 128) then return result(session, req, "UNAVAILABLE", "PENDING_ID_MISSING") end
        return result(session, req, "ACCEPTED_PENDING", tostring(detail.reasonCode or ""), { actualPendingId = detail.pendingId })
    elseif outcome == "PARTIAL_UNAVAILABLE" then
        return result(session, req, "PARTIAL_UNAVAILABLE", tostring(detail.reasonCode or ""), { currentTarget = detail.currentTarget })
    elseif outcome == "REFUSED" then
        return result(session, req, "REFUSED", tostring(detail.reasonCode or "OWNER_REFUSED"))
    elseif outcome == "STALE" then
        return result(session, req, "STALE", tostring(detail.reasonCode or "OWNER_STALE"), { currentTarget = detail.currentTarget })
    end
    return result(session, req, "UNAVAILABLE", "OWNER_OUTCOME_UNKNOWN")
end

--- SG_CURRENT_TARGET_1 for a resolved target, or nil.
function C.currentTarget(lease, binding, actor, req)
    local ok, row = pcall(lease.spec.readTarget, binding)
    if not ok or type(row) ~= "table" then return { schemaVersion = 1, targetKind = req.targetKind, targetId = req.targetId, availability = "UNAVAILABLE", reasonCode = "TARGET_UNREADABLE", effects = { knowledge = "UNAVAILABLE", changes = {} } } end
    return { schemaVersion = 1, targetKind = req.targetKind, targetId = req.targetId, availability = "READY", reasonCode = "", row = copy(row), effects = { knowledge = "KNOWN", changes = {} } }
end

--- SG_QUOTE_OFFER_1 validation.
function C.validateOffer(o)
    if type(o) ~= "table" or o.schemaVersion ~= 1 then return nil, "SCHEMA" end
    if not nonempty(o.actionId, 64) or not SGRegistry.TARGET_KINDS[o.targetKind] or not nonempty(o.targetId, 512) or type(o.targetLabel) ~= "string" then return nil, "TARGET" end
    if not nonempty(o.expectedRevision, 64) then return nil, "REVISION" end
    if type(o.cost) ~= "table" or not ({ NOT_APPLICABLE = true, KNOWN = true, UNAVAILABLE = true })[o.cost.state] then return nil, "COST" end
    if o.cost.state == "KNOWN" and not SGRecords.isAmount(o.cost.amount) then return nil, "COST_AMOUNT" end
    if o.cost.state ~= "KNOWN" and o.cost.amount ~= nil then return nil, "COST_AMOUNT" end
    if o.cost.state == "UNAVAILABLE" then return nil, "COST_UNAVAILABLE" end
    if type(o.duration) ~= "table" or not ({ NOT_APPLICABLE = true, KNOWN = true, UNAVAILABLE = true })[o.duration.state] then return nil, "DURATION" end
    if o.duration.state == "KNOWN" and (not SGRecords.isAmount(o.duration.value) or not ({ GAME_HOUR = true, REAL_SECOND = true })[o.duration.unit]) then return nil, "DURATION_VALUE" end
    if type(o.inputs) ~= "table" or type(o.warnings) ~= "table" then return nil, "LISTS" end
    for _, i in ipairs(o.inputs) do
        if type(i) ~= "table" or type(i.label) ~= "string" or type(i.amount) ~= "table" or not SGRecords.isAmount(i.amount.value) or not SGRecords.AMOUNT_UNITS[i.amount.unit] then return nil, "INPUT" end
        if i.materialRef ~= nil and not SGRecords.isMaterialRef(i.materialRef) then return nil, "INPUT_MATERIAL" end
    end
    for _, w in ipairs(o.warnings) do
        if type(w) ~= "table" or not nonempty(w.code, 64) or not nonempty(w.labelKey, 128) then return nil, "WARNING" end
    end
    return copy(o)
end
