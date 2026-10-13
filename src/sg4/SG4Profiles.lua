-- =========================================================
-- FS25_StockGuard - SG-4 recipe library: the preparation profile registry (SG-4 Part 2a)
-- =========================================================
-- SG-4 v2.4 build brief :66-70 and :359. A supported owner registers a profile through the
-- server-local registerPreparationProfile(providerId, profileId, version, definition, callbacks)
-- and gets an opaque profile token; a conflicting provider cannot replace it. Registration is
-- code-owned (a Lua call from trusted initialization code), never a client request.
--
-- definition = { mode, labelKey, policyVersion?, editor } with the editor SG4Schema checks (:381).
-- callbacks  = { validate(definition) -> true | false, reason,
--                acceptSavedDefinition(definition, storedProfileVersion, storedPolicyVersion)
--                  -> "EXACT_ACCEPT" | "UNAVAILABLE", reason }
--
-- NOT IN THIS PART (Bob's R-15 of 2026-10-08, WITHHELD): the CARRIER resolution and native-access
-- callbacks arrive with arming (SG2-7), the execution callbacks with an EXECUTABLE process (EP-1).
-- An EXECUTABLE profile is refused until then: nothing here could execute it. The native mixer
-- GUIDANCE profile itself is SG-4 Part 2b, pending Design's answer on its labels.

SG4Profiles = SG4Profiles or {}
local P = SG4Profiles
local P_mt = { __index = P }

local S = SG4Schema
local copy = SGValues.copy
local nonempty = SGRecords.nonemptyString
local isInteger = SGValues.isInteger

--- onChanged(profileId) is called after every registration (the library re-reads its locked revisions).
function P.new(onChanged)
    local self = setmetatable({}, P_mt)
    self.byId = {}
    self.nextToken = 0
    self.onChanged = onChanged
    return self
end

--- registerPreparationProfile. Server only. Returns the opaque token, or nil and a reason.
function P:register(providerId, profileId, version, definition, callbacks)
    if g_server == nil then return nil, "NOT_SERVER" end
    if not nonempty(providerId, 64) or not nonempty(profileId, 64) then return nil, "INVALID_ID" end
    if not isInteger(version) or version < 1 then return nil, "VERSION" end
    if type(definition) ~= "table" or not S.MODES[definition.mode] then return nil, "MODE" end
    if definition.mode == "EXECUTABLE" then return nil, "EXECUTION_UNBUILT" end
    if type(definition.labelKey) ~= "string" then return nil, "LABEL" end
    if definition.policyVersion ~= nil and (not isInteger(definition.policyVersion) or definition.policyVersion < 1) then return nil, "POLICY_VERSION" end
    local okE, whyE = S.validateEditor(definition.editor, definition.mode)
    if not okE then return nil, "EDITOR:" .. tostring(whyE) end
    if type(callbacks) ~= "table" or type(callbacks.validate) ~= "function" or type(callbacks.acceptSavedDefinition) ~= "function" then return nil, "CALLBACKS" end
    local existing = self.byId[profileId]
    if existing ~= nil then return nil, existing.providerId == providerId and "DUPLICATE_PROFILE" or "PROFILE_CONFLICT" end
    self.nextToken = self.nextToken + 1
    local token = setmetatable({}, { __tostring = function() return "PreparationProfileToken" end })
    self.byId[profileId] = { providerId = providerId, profileId = profileId, version = version, policyVersion = definition.policyVersion,
                             definition = copy(definition), callbacks = callbacks, token = token }
    if self.onChanged ~= nil then pcall(self.onChanged, profileId) end
    return token
end

function P:get(profileId)
    return profileId ~= nil and self.byId[profileId] or nil
end

--- Every registered profile, ordered by id.
function P:list()
    local out = {}
    for _, entry in pairs(self.byId) do out[#out + 1] = entry end
    table.sort(out, function(a, b) return a.profileId < b.profileId end)
    return out
end

function P:count()
    local n = 0
    for _ in pairs(self.byId) do n = n + 1 end
    return n
end

--- A new or edited definition against its profile: SG4Schema's structural and bounds checks, then the
--- profile's own validation, which is authoritative (:381). Returns true or false, reason.
function P:validate(definition)
    local entry = self:get(type(definition) == "table" and definition.profileId or nil)
    if entry == nil then return false, S.REASON.PROFILE_ABSENT end
    local ok, why = S.validateDefinition(definition, entry)
    if not ok then return false, why end
    local okC, valid, reason = pcall(entry.callbacks.validate, copy(definition))
    if not okC then return false, S.REASON.PROFILE_UNAVAILABLE end
    if valid ~= true then return false, nonempty(reason, 64) and reason or S.REASON.DEFINITION_INVALID end
    return true
end

--- A saved definition's availability (:357, :359): its profile registered, and EXACT_ACCEPT from that
--- profile for the version and policy it was saved under. Returns true or false, reason.
function P:accept(definition)
    local entry = self:get(type(definition) == "table" and definition.profileId or nil)
    if entry == nil then return false, S.REASON.PROFILE_ABSENT end
    local ok, answer, reason = pcall(entry.callbacks.acceptSavedDefinition, copy(definition), definition.profileVersion, definition.policyVersion)
    if not ok then return false, S.REASON.PROFILE_UNAVAILABLE end
    if answer == "EXACT_ACCEPT" then return true end
    return false, nonempty(reason, 64) and reason or S.REASON.PROFILE_UNAVAILABLE
end

--- The PROFILE row of the library view (:381): a detached projection of the registration.
function P.row(entry)
    return { rowKind = "PROFILE", profileId = entry.profileId, profileVersion = entry.version, policyVersion = entry.policyVersion,
             labelKey = entry.definition.labelKey, mode = entry.definition.mode, availability = "AVAILABLE", reasonCode = "",
             editor = copy(entry.definition.editor) }
end
