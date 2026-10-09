-- =========================================================
-- FS25_StockGuard - SG-4 recipe library: the management owner (SG-4 Part 2a)
-- =========================================================
-- SG-4 v2.4 build brief :112-120 and :345. SG-4's registered management owner holds target kind
-- LIBRARY (identity: the libraryId). SAVE_RECIPE and RETIRE_RECIPE are QUOTED because they advance the
-- library revision, each with the full quote, validate and execute triple, ORDINARY control, argument
-- schemas SG4_SAVE_RECIPE_1 and SG4_RETIRE_RECIPE_1, and an argumentContext listing the published
-- profiles and the editable recipes at that revision. They reach a client only through SG_COMMAND_2 on
-- the RECIPE_LIBRARY route. There is no cross-farm recovery context: the trusted actor is built by the
-- server for one farm, and only that farm's live library is reachable.
--
-- SG-1 hands every quote, validate and execute the request's arguments stamped with the resolved
-- action's argumentSchemaId (SGCommands normalizedArgs), so the owner knows which of its two actions it
-- answers.
--
--   SG4_SAVE_RECIPE_1   = { definition = SG4_RECIPE_DEFINITION_1, recipeId?, recipeRevision? }
--                         (an edit names the recipe and the revision it was made from)
--   SG4_RETIRE_RECIPE_1 = { recipeId, recipeRevision }
--
-- A quote creates nothing and reserves nothing. The private ownerQuoteRef keeps the library revision it
-- was made at, and validateQuote refuses on any drift. A duplicate EXECUTE is SG-1's: it returns the
-- retained result and never calls the owner again.
--
-- LIBRARY_FULL: a save that would take the library's view past the private view's row budget
-- (SGViews.PAGE_TOKEN_BUDGET) refuses, so the library never becomes a view the transport cannot carry.

SG4Owner = SG4Owner or {}
local O = SG4Owner

local S = SG4Schema
local copy = SGValues.copy
local nonempty = SGRecords.nonemptyString

O.OWNER_ID = "sg4"
O.SAVE = "SAVE_RECIPE"
O.RETIRE = "RETIRE_RECIPE"

local function libraryOf(m, b)
    return type(b) == "table" and m.library.libraries[b.libraryId] or nil
end

--- The actor reaches only its own farm's live library.
function O.hasAccess(m, b, actor)
    local lib = libraryOf(m, b)
    if lib == nil or lib.retired then return false end
    if SGViews.actorAvailability(actor) ~= "READY" then return false end
    return actor.farmId == lib.ownerFarmId
end

local function editable(lib)
    local out = {}
    for rid, r in pairs(lib.recipes) do
        if not r.retired then out[#out + 1] = { recipeId = rid, recipeRevision = tostring(r.currentRevision) } end
    end
    table.sort(out, function(a, b) return a.recipeId < b.recipeId end)
    return out
end

--- The registered action table for one library.
function O.actions(m, b, actor)
    local lib = libraryOf(m, b)
    if lib == nil then return {} end
    local revision = tostring(lib.libraryRevision)
    local profileIds = {}
    for _, p in ipairs(m.profiles:list()) do profileIds[#profileIds + 1] = p.profileId end
    local recipes = editable(lib)
    local saveOk, retireOk = #profileIds > 0, #recipes > 0
    return {
        { actionId = O.SAVE, targetKind = "LIBRARY", targetId = b.libraryId, expectedRevision = revision, argumentSchemaId = S.SAVE_ARGUMENTS,
          argumentContext = { profiles = profileIds, recipes = recipes }, controlKind = "ORDINARY", admission = "QUOTED",
          available = saveOk, reasonCode = saveOk and "" or S.REASON.NO_PROFILE },
        { actionId = O.RETIRE, targetKind = "LIBRARY", targetId = b.libraryId, expectedRevision = revision, argumentSchemaId = S.RETIRE_ARGUMENTS,
          argumentContext = { recipes = recipes }, controlKind = "ORDINARY", admission = "QUOTED",
          available = retireOk, reasonCode = retireOk and "" or S.REASON.RECIPE_UNKNOWN },
    }
end

--- The encoded size of the library's view rows if `definition` were saved as `recipeId` (nil: new).
local function viewTokensAfter(m, libraryId, recipeId, definition)
    local rows = { m.library:libraryRow(libraryId) }
    local replaced = false
    for _, r in ipairs(m.library:recipeRows(libraryId)) do
        if recipeId ~= nil and r.recipeId == recipeId then
            r.definition = definition
            replaced = true
        end
        rows[#rows + 1] = r
    end
    if not replaced then
        rows[#rows + 1] = { rowKind = "RECIPE", libraryId = libraryId, recipeId = "r" .. tostring(m.library.nextSerial + 1), recipeRevision = "1", current = true,
                            retired = false, availability = "AVAILABLE", reasonCode = "", definition = definition }
    end
    for _, p in ipairs(m.profiles:list()) do rows[#rows + 1] = SG4Profiles.row(p) end
    local tokens = SGValues.encode(rows)
    return tokens ~= nil and #tokens or math.huge
end

--- Check a request against the library as it stands now. Returns true, or false and a reason.
local function check(m, b, args)
    local lib = libraryOf(m, b)
    if lib == nil or lib.retired then return false, S.REASON.RETIRED end
    if args.argumentSchemaId == S.SAVE_ARGUMENTS then
        if type(args.definition) ~= "table" then return false, S.REASON.DEFINITION_INVALID end
        if args.recipeId ~= nil then
            local r = nonempty(args.recipeId, 128) and lib.recipes[args.recipeId] or nil
            if r == nil then return false, S.REASON.RECIPE_UNKNOWN end
            if r.retired then return false, S.REASON.RECIPE_RETIRED end
            if args.recipeRevision ~= tostring(r.currentRevision) then return false, S.REASON.RECIPE_STALE end
        elseif args.recipeRevision ~= nil then
            return false, S.REASON.DEFINITION_INVALID
        end
        local ok, why = m.profiles:validate(args.definition)
        if not ok then return false, why end
        if viewTokensAfter(m, b.libraryId, args.recipeId, args.definition) > SGViews.PAGE_TOKEN_BUDGET then return false, S.REASON.FULL end
        return true
    elseif args.argumentSchemaId == S.RETIRE_ARGUMENTS then
        local r = nonempty(args.recipeId, 128) and lib.recipes[args.recipeId] or nil
        if r == nil then return false, S.REASON.RECIPE_UNKNOWN end
        if r.retired then return false, S.REASON.RECIPE_RETIRED end
        if args.recipeRevision ~= tostring(r.currentRevision) then return false, S.REASON.RECIPE_STALE end
        return true
    end
    return false, S.REASON.DEFINITION_INVALID
end
O.check = check

--- quoteAction: the detached offer and the private ref. Returns quote, or nil and a reason.
function O.quote(m, b, actor, args)
    if not O.hasAccess(m, b, actor) then return nil, S.REASON.NOT_OWNED end
    local ok, why = check(m, b, args)
    if not ok then return nil, why end
    local lib = libraryOf(m, b)
    local save = args.argumentSchemaId == S.SAVE_ARGUMENTS
    local label = save and args.definition.label or m.library:definitionOf(b.libraryId, args.recipeId, lib.recipes[args.recipeId].currentRevision).label
    local offer = { schemaVersion = 1, actionId = save and O.SAVE or O.RETIRE, targetKind = "LIBRARY", targetId = b.libraryId, targetLabel = label,
                    expectedRevision = tostring(lib.libraryRevision), cost = { state = "NOT_APPLICABLE" }, duration = { state = "NOT_APPLICABLE" },
                    inputs = {}, warnings = {} }
    local ref = { libraryId = b.libraryId, libraryRevision = lib.libraryRevision, argumentSchemaId = args.argumentSchemaId }
    return { offer = offer, ownerQuoteRef = ref, readSet = { libraryRevision = lib.libraryRevision } }
end

--- validateQuote: the library unchanged since the quote, the actor's access, and the request still good.
function O.validateQuote(m, b, actor, args, ref)
    if not O.hasAccess(m, b, actor) then return false, S.REASON.NOT_OWNED end
    local lib = libraryOf(m, b)
    if type(ref) ~= "table" or ref.libraryId ~= b.libraryId or ref.libraryRevision ~= lib.libraryRevision or ref.argumentSchemaId ~= args.argumentSchemaId then
        return false, S.REASON.RECIPE_STALE
    end
    return check(m, b, args)
end

--- executeAction: the owner operation, after SG-1 consumed the token.
function O.execute(m, b, actor, args, ref)
    local lib = libraryOf(m, b)
    if args.argumentSchemaId == S.SAVE_ARGUMENTS then
        m.library:saveRecipe(b.libraryId, args.recipeId, args.definition)
    elseif args.argumentSchemaId == S.RETIRE_ARGUMENTS then
        m.library:retireRecipe(b.libraryId, args.recipeId)
    else
        return "REFUSED", { reasonCode = S.REASON.DEFINITION_INVALID }
    end
    return "APPLIED", { resultingRevision = tostring(lib.libraryRevision), reasonCode = "" }
end

--- The owner's registration spec.
function O.spec(m)
    return {
        version = 1, targetKinds = { "LIBRARY" },
        -- Library rows travel on the RECIPE_LIBRARY route (SG4's view), never as STOCK-route targets.
        enumerateTargets = function() return { state = "READY", targets = {}, exhausted = true } end,
        resolveTarget = function(targetId)
            if type(targetId) == "string" and m.library.libraries[targetId] ~= nil then return { libraryId = targetId } end
            return nil
        end,
        readTarget = function(b) return m.library.libraries[b.libraryId] ~= nil and m.library:libraryRow(b.libraryId) or nil end,
        hasAccess = function(b, actor) return O.hasAccess(m, b, actor) end,
        getActions = function(b, actor) return O.actions(m, b, actor) end,
        invoke = function() return "REFUSED", { reasonCode = "NOT_DIRECT" } end,
        quoteAction = function(b, actor, args) return O.quote(m, b, actor, args) end,
        validateQuote = function(b, actor, args, ref) return O.validateQuote(m, b, actor, args, ref) end,
        executeAction = function(b, actor, args, ref) return O.execute(m, b, actor, args, ref) end,
    }
end
