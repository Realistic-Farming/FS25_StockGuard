-- =========================================================
-- FS25_StockGuard - SG-4 recipe library: the fixed schemas (SG-4 Part 2a)
-- =========================================================
-- SG-4 v2.4 build brief :381-383 (SG4_RECIPE_LIBRARY_1 rows, a profile's editor, and
-- SG4_RECIPE_DEFINITION_1) and :70 (finite, non-negative values on the profile's stated basis;
-- duplicate or conflicting roles, unknown ingredients, unsupported units, non-finite values and
-- incomplete totals refuse). These are compiled data-only checks, the same on the server and on a
-- client: the server checks a definition against the published profile before saving it, and the
-- library view's rows are checked on both sides (SGRegistry:registerRecipeLibraryView's validateRows).
-- No callback, lease or native object is ever part of a row.
--
-- Bounds that are not the brief's but keep a row inside the transport: a label of at most 64 bytes;
-- at most 32 roles, 64 ingredients per role and 64 ingredients in a definition.

SG4Schema = SG4Schema or {}
local S = SG4Schema

S.LIBRARY_SCHEMA = "SG4_RECIPE_LIBRARY_1"
S.LIBRARY_SCHEMA_VERSION = 1
S.DEFINITION_SCHEMA = "SG4_RECIPE_DEFINITION_1"
S.DEFINITION_SCHEMA_VERSION = 1
S.SAVE_ARGUMENTS = "SG4_SAVE_RECIPE_1"
S.RETIRE_ARGUMENTS = "SG4_RETIRE_RECIPE_1"
S.CURRENT = "@current"

S.MODES = { GUIDANCE = true, EXECUTABLE = true }
S.INTENTS = { DRAFT = true, GUIDANCE_TARGET = true, EXECUTABLE_TARGET = true }
S.GUIDANCE_INTENTS = { DRAFT = true, GUIDANCE_TARGET = true }
S.BASIS_KINDS = { PROPORTION = true, QUANTITY = true }
S.AVAILABILITY = { AVAILABLE = true, UNAVAILABLE = true }

S.MAX_LABEL_BYTES = 64
S.MAX_ROLES = 32
S.MAX_ROLE_INGREDIENTS = 64
S.MAX_DEFINITION_INGREDIENTS = 64
S.TOTAL_EPSILON = 1e-9

--- The reason codes SG-4 shows a player (each has sg4_reason_<lower case> in every translation file).
S.REASON = {
    LOADING = "LIBRARY_LOADING",
    UNAVAILABLE = "LIBRARY_UNAVAILABLE",
    NOT_OWNED = "LIBRARY_NOT_OWNED",
    RETIRED = "LIBRARY_RETIRED",
    FULL = "LIBRARY_FULL",
    NO_PROFILE = "NO_PROFILE",
    PROFILE_ABSENT = "PROFILE_ABSENT",
    PROFILE_UNAVAILABLE = "PROFILE_UNAVAILABLE",
    RECIPE_UNKNOWN = "RECIPE_UNKNOWN",
    RECIPE_RETIRED = "RECIPE_RETIRED",
    RECIPE_STALE = "RECIPE_STALE",
    DEFINITION_INVALID = "DEFINITION_INVALID",
    INGREDIENT_INVALID = "INGREDIENT_INVALID",
    VALUE_OUT_OF_BOUNDS = "VALUE_OUT_OF_BOUNDS",
    TOTAL_INCOMPLETE = "TOTAL_INCOMPLETE",
    REQUIRED_ROLE_MISSING = "REQUIRED_ROLE_MISSING",
    INTENT_UNSUPPORTED = "INTENT_UNSUPPORTED",
}

local nonempty = SGRecords.nonemptyString
local isFinite = SGValues.isFinite
local isInteger = SGValues.isInteger
local UNITS = SGRecords.AMOUNT_UNITS

local function isList(t, max)
    return type(t) == "table" and SGValues.isArray(t) and #t <= max
end

--- The l10n key of an SG-4 reason code.
function S.reasonKey(code)
    return "sg4_reason_" .. string.lower(tostring(code))
end

-- ---------------------------------------------------------
-- A profile's editor (:381), checked at registration and on every PROFILE row
-- ---------------------------------------------------------
--- { definitionSchemaVersion = 1, allowedIntents, basis, roles, dilution?, batch? }. Returns true or
--- false, reason. Optional absence means unsupported, not unrestricted.
function S.validateEditor(editor, mode)
    if type(editor) ~= "table" or editor.definitionSchemaVersion ~= S.DEFINITION_SCHEMA_VERSION then return false, "EDITOR_SCHEMA" end
    if not isList(editor.allowedIntents, 3) or #editor.allowedIntents == 0 then return false, "INTENTS" end
    for _, intent in ipairs(editor.allowedIntents) do
        if not S.INTENTS[intent] then return false, "INTENTS" end
        if mode == "GUIDANCE" and not S.GUIDANCE_INTENTS[intent] then return false, "INTENTS" end
    end
    local b = editor.basis
    if type(b) ~= "table" or not S.BASIS_KINDS[b.kind] or not UNITS[b.unit] or not isFinite(b.total) or b.total <= 0 then return false, "BASIS" end
    if not isList(editor.roles, S.MAX_ROLES) or #editor.roles == 0 then return false, "ROLES" end
    local roleIds = {}
    for _, role in ipairs(editor.roles) do
        if type(role) ~= "table" or not nonempty(role.roleId, 64) or roleIds[role.roleId] then return false, "ROLE" end
        roleIds[role.roleId] = true
        if type(role.labelKey) ~= "string" or type(role.required) ~= "boolean" then return false, "ROLE" end
        if not isList(role.ingredients, S.MAX_ROLE_INGREDIENTS) or #role.ingredients == 0 then return false, "ROLE_INGREDIENTS" end
        local seen = {}
        for _, ing in ipairs(role.ingredients) do
            if type(ing) ~= "table" or not nonempty(ing.ingredientId, 128) or seen[ing.ingredientId] then return false, "INGREDIENT" end
            seen[ing.ingredientId] = true
            if type(ing.labelKey) ~= "string" or not UNITS[ing.unit] then return false, "INGREDIENT" end
            if not isFinite(ing.min) or not isFinite(ing.max) or ing.min < 0 or ing.min > ing.max then return false, "INGREDIENT_BOUNDS" end
        end
    end
    if editor.dilution ~= nil then
        local d = editor.dilution
        if type(d) ~= "table" or not isList(d.diluentIds, 16) or #d.diluentIds == 0 then return false, "DILUTION" end
        for _, id in ipairs(d.diluentIds) do if not nonempty(id, 128) then return false, "DILUTION" end end
        if not isFinite(d.strengthMin) or not isFinite(d.strengthMax) or d.strengthMin < 0 or d.strengthMax > 1 or d.strengthMin > d.strengthMax then return false, "DILUTION" end
    end
    if editor.batch ~= nil then
        local bt = editor.batch
        if type(bt) ~= "table" or not UNITS[bt.unit] or not isFinite(bt.min) or not isFinite(bt.max) or bt.min <= 0 or bt.min > bt.max then return false, "BATCH" end
    end
    return true
end

-- ---------------------------------------------------------
-- SG4_RECIPE_DEFINITION_1 (:383)
-- ---------------------------------------------------------
--- The definition's own shape, with no profile: what a client checks on a RECIPE row.
function S.validateDefinitionShape(d)
    local R = S.REASON
    if type(d) ~= "table" or d.definitionSchemaVersion ~= S.DEFINITION_SCHEMA_VERSION then return false, R.DEFINITION_INVALID end
    if not nonempty(d.profileId, 64) or not isInteger(d.profileVersion) or d.profileVersion < 1 then return false, R.DEFINITION_INVALID end
    if d.policyVersion ~= nil and (not isInteger(d.policyVersion) or d.policyVersion < 1) then return false, R.DEFINITION_INVALID end
    if not nonempty(d.label, S.MAX_LABEL_BYTES) then return false, R.DEFINITION_INVALID end
    if not S.INTENTS[d.intent] then return false, R.INTENT_UNSUPPORTED end
    local b = d.basis
    if type(b) ~= "table" or not S.BASIS_KINDS[b.kind] or not UNITS[b.unit] or not isFinite(b.total) or b.total <= 0 then return false, R.DEFINITION_INVALID end
    if not isList(d.ingredients, S.MAX_DEFINITION_INGREDIENTS) then return false, R.DEFINITION_INVALID end
    for _, i in ipairs(d.ingredients) do
        if type(i) ~= "table" or not nonempty(i.ingredientId, 128) or not nonempty(i.roleId, 64) or not UNITS[i.unit] then return false, R.INGREDIENT_INVALID end
        if not isFinite(i.value) or i.value < 0 then return false, R.VALUE_OUT_OF_BOUNDS end
    end
    if d.dilution ~= nil and (type(d.dilution) ~= "table" or not nonempty(d.dilution.diluentId, 128) or not isFinite(d.dilution.strength)) then return false, R.DEFINITION_INVALID end
    if d.defaultBatchAmount ~= nil and (type(d.defaultBatchAmount) ~= "table" or not isFinite(d.defaultBatchAmount.value) or not UNITS[d.defaultBatchAmount.unit]) then
        return false, R.DEFINITION_INVALID
    end
    return true
end

--- A definition checked against the published profile it names (:70, :381, :383): the profile and
--- its version, an admitted intent, the profile's own basis, every ingredient admitted in its role,
--- on its unit and inside its bounds, no duplicate, every required role present, the complete total
--- on a PROPORTION basis, and dilution and a default batch only where the profile supports them.
--- The profile's own domain validation runs after this (SG4Profiles), and is authoritative.
function S.validateDefinition(d, profile)
    local R = S.REASON
    local ok, why = S.validateDefinitionShape(d)
    if not ok then return false, why end
    if profile == nil or d.profileId ~= profile.profileId then return false, R.PROFILE_ABSENT end
    if d.profileVersion ~= profile.version or d.policyVersion ~= profile.policyVersion then return false, R.PROFILE_UNAVAILABLE end
    local editor = profile.definition.editor
    local admitted = false
    for _, intent in ipairs(editor.allowedIntents) do if intent == d.intent then admitted = true end end
    if not admitted then return false, R.INTENT_UNSUPPORTED end
    local b = editor.basis
    if d.basis.kind ~= b.kind or d.basis.unit ~= b.unit or math.abs(d.basis.total - b.total) > S.TOTAL_EPSILON then return false, R.DEFINITION_INVALID end
    local roles = {}
    for _, role in ipairs(editor.roles) do
        local ings = {}
        for _, ing in ipairs(role.ingredients) do ings[ing.ingredientId] = ing end
        roles[role.roleId] = { role = role, ingredients = ings }
    end
    local seen, present, sum = {}, {}, 0
    for _, i in ipairs(d.ingredients) do
        local r = roles[i.roleId]
        local ing = r ~= nil and r.ingredients[i.ingredientId] or nil
        if ing == nil or i.unit ~= ing.unit then return false, R.INGREDIENT_INVALID end
        local key = i.roleId .. "\0" .. i.ingredientId
        if seen[key] then return false, R.INGREDIENT_INVALID end
        seen[key] = true
        if i.value < ing.min or i.value > ing.max then return false, R.VALUE_OUT_OF_BOUNDS end
        present[i.roleId] = true
        sum = sum + i.value
    end
    for _, role in ipairs(editor.roles) do
        if role.required and not present[role.roleId] then return false, R.REQUIRED_ROLE_MISSING end
    end
    if b.kind == "PROPORTION" and math.abs(sum - b.total) > S.TOTAL_EPSILON * math.max(1, b.total) then return false, R.TOTAL_INCOMPLETE end
    if d.dilution ~= nil then
        local dil = editor.dilution
        if dil == nil then return false, R.DEFINITION_INVALID end
        local known = false
        for _, id in ipairs(dil.diluentIds) do if id == d.dilution.diluentId then known = true end end
        if not known then return false, R.INGREDIENT_INVALID end
        if d.dilution.strength < dil.strengthMin or d.dilution.strength > dil.strengthMax then return false, R.VALUE_OUT_OF_BOUNDS end
    end
    if d.defaultBatchAmount ~= nil then
        local bt = editor.batch
        if bt == nil then return false, R.DEFINITION_INVALID end
        if d.defaultBatchAmount.unit ~= bt.unit then return false, R.INGREDIENT_INVALID end
        if d.defaultBatchAmount.value < bt.min or d.defaultBatchAmount.value > bt.max then return false, R.VALUE_OUT_OF_BOUNDS end
    end
    return true
end

-- ---------------------------------------------------------
-- SG4_RECIPE_LIBRARY_1 rows (:381), checked on both sides
-- ---------------------------------------------------------
local function validAction(a)
    return type(a) == "table" and nonempty(a.actionId, 64)
end

--- A READY library view's rows: exactly one LIBRARY row, then RECIPE and PROFILE rows. Returns true or
--- false, reason.
function S.validateRows(rows)
    if type(rows) ~= "table" or not SGValues.isArray(rows) then return false, "ROWS" end
    local libraries = 0
    for _, r in ipairs(rows) do
        if type(r) ~= "table" then return false, "ROW" end
        if r.rowKind == "LIBRARY" then
            libraries = libraries + 1
            if not nonempty(r.libraryId, 128) or not nonempty(r.libraryRevision, 64) or type(r.retired) ~= "boolean" then return false, "LIBRARY_ROW" end
            if r.actions ~= nil then
                if type(r.actions) ~= "table" then return false, "LIBRARY_ROW" end
                for _, a in ipairs(r.actions) do if not validAction(a) then return false, "LIBRARY_ROW" end end
            end
        elseif r.rowKind == "RECIPE" then
            if not nonempty(r.libraryId, 128) or not nonempty(r.recipeId, 128) or not nonempty(r.recipeRevision, 64) then return false, "RECIPE_ROW" end
            if type(r.current) ~= "boolean" or type(r.retired) ~= "boolean" or not S.AVAILABILITY[r.availability] or type(r.reasonCode) ~= "string" then return false, "RECIPE_ROW" end
            if not S.validateDefinitionShape(r.definition) then return false, "RECIPE_DEFINITION" end
        elseif r.rowKind == "PROFILE" then
            if not nonempty(r.profileId, 64) or not isInteger(r.profileVersion) or r.profileVersion < 1 then return false, "PROFILE_ROW" end
            if r.policyVersion ~= nil and not isInteger(r.policyVersion) then return false, "PROFILE_ROW" end
            if type(r.labelKey) ~= "string" or not S.MODES[r.mode] or not S.AVAILABILITY[r.availability] or type(r.reasonCode) ~= "string" then return false, "PROFILE_ROW" end
            if not S.validateEditor(r.editor, r.mode) then return false, "PROFILE_EDITOR" end
        else
            return false, "ROW_KIND"
        end
    end
    if libraries ~= 1 or rows[1].rowKind ~= "LIBRARY" then return false, "LIBRARY_ROW_COUNT" end
    return true
end
