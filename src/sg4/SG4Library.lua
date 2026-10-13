-- =========================================================
-- FS25_StockGuard - SG-4 recipe library: the store (SG-4 Part 2a)
-- =========================================================
-- SG-4 v2.4 build brief :353-363 and :62-72.
--
-- THE PAYLOAD. extensions.sg4 = { schemaVersion = 1, nextSerial, libraries, recipeDefinitions },
-- SG-1's registerSaveSection("sg4") with farmRestorePolicy OWNER and no domain dependency, so an
-- absent profile can never fail the library's load. guidanceCarriers is SG-1's injected
-- carrier-pending collection and lands with arming (SG2-7, WITHHELD).
--   libraries[libraryId]          = { ownerFarmId, retired, retiredReason?, libraryRevision,
--                                      recipes[recipeId] = { currentRevision, retired } }
--   recipeDefinitions[defKey]     = { libraryId, recipeId, revision, definition } (immutable)
-- Identities are opaque, minted from one saved serial ("lib<n>", "r<n>"), never a native index.
--
-- READINESS. A failed stageLoad or commitLoad leaves the section UNAVAILABLE, never an empty library:
-- SG-1 retains the original payload, and nothing here is created or saved while UNAVAILABLE. A save
-- with no sg4 section at all is first use (SG-1's READY_EMPTY): a library may then be created. An
-- initialized section with no payload is refused by SG-1's envelope check before this is reached
-- (SGSave.validateEnvelope, MISSING_INITIALIZED_SECTION).
--
-- REVISIONS. Saving an edit makes a new immutable revision and advances the library's revision; a
-- stale edit refuses. Retiring removes a recipe from selection and keeps its revision readable. In
-- this part nothing outside the library can reference a revision (binding, batches and pending
-- guidance are WITHHELD), so an edit's superseded revision is dropped at once; reference enumeration
-- joins with the first referrer.
--
-- FARMS (:363). FARM_DELETED retires the farm's library; a FARM_CREATED for a farm id that still has a
-- live library retires that one too (its deletion was not observed), so a reused id gets a new
-- library. A singleplayer opening of a multiplayer save retires each merged farm's library under its
-- old identity at staged load (SGFarmRestore.library); the survivor's library is untouched.

SG4Library = SG4Library or {}
local L = SG4Library
local L_mt = { __index = L }

local S = SG4Schema
local copy = SGValues.copy
local nonempty = SGRecords.nonemptyString
local isInteger = SGValues.isInteger

L.SECTION_ID = "sg4"
L.SECTION_SCHEMA = 1

local function defKey(libraryId, recipeId, revision) return libraryId .. "|" .. recipeId .. "|" .. tostring(revision) end
L.defKey = defKey

--- readinessSource() -> "LOADING" | "READY" | "UNAVAILABLE", reason: SG-1's own state for the section
--- when nothing was committed (first use, or before the load).
function L.new(profiles, readinessSource)
    local self = setmetatable({}, L_mt)
    self.profiles = profiles
    self.readinessSource = readinessSource
    self.libraries = {}
    self.definitions = {}
    self.nextSerial = 0
    self.committed = nil
    self.reason = nil
    self.locks = {}
    self.dataRevision = 1
    self.onChanged = nil
    return self
end

function L:changed()
    self.dataRevision = self.dataRevision + 1
    if self.onChanged ~= nil then pcall(self.onChanged) end
end

function L:readiness()
    if self.committed == "UNAVAILABLE" then return "UNAVAILABLE", self.reason end
    if self.committed == "READY" then return "READY" end
    if self.readinessSource == nil then return "LOADING" end
    local ok, state, reason = pcall(self.readinessSource)
    if not ok or state == nil then return "LOADING" end
    return state, reason
end

-- ---------------------------------------------------------
-- The save section
-- ---------------------------------------------------------
--- The payload, or nil while the library is not READY (SG-1 then keeps whatever it holds).
function L:serialize()
    if self:readiness() ~= "READY" then return nil end
    local libs = {}
    for id, lib in pairs(self.libraries) do
        local recipes = {}
        for rid, r in pairs(lib.recipes) do recipes[rid] = { currentRevision = r.currentRevision, retired = r.retired } end
        libs[id] = { ownerFarmId = lib.ownerFarmId, retired = lib.retired, retiredReason = lib.retiredReason, libraryRevision = lib.libraryRevision, recipes = recipes }
    end
    local defs = {}
    for key, d in pairs(self.definitions) do defs[key] = { libraryId = d.libraryId, recipeId = d.recipeId, revision = d.revision, definition = copy(d.definition) } end
    return { schemaVersion = L.SECTION_SCHEMA, nextSerial = self.nextSerial, libraries = libs, recipeDefinitions = defs }
end

local function serialOf(id)
    local n = tonumber(string.match(tostring(id), "(%d+)$"))
    return n
end

--- Validate the complete payload into a detached candidate (:361): schema, identities, every current
--- revision present, no orphan definition, no id above the saved serial. Then the farm conversion.
--- Returns the candidate, or nil and a reason (SG-1 then retains the payload and the library is
--- UNAVAILABLE).
function L.stage(payload, context)
    if type(payload) ~= "table" or payload.schemaVersion ~= L.SECTION_SCHEMA then return nil, "SCHEMA" end
    if not isInteger(payload.nextSerial) or payload.nextSerial < 0 then return nil, "SERIAL" end
    local libs, defs = payload.libraries or {}, payload.recipeDefinitions or {}
    if type(libs) ~= "table" or type(defs) ~= "table" then return nil, "SHAPE" end
    local out = { nextSerial = payload.nextSerial, libraries = {}, definitions = {} }
    for key, d in pairs(defs) do
        if type(key) ~= "string" or type(d) ~= "table" or not nonempty(d.libraryId, 128) or not nonempty(d.recipeId, 128)
            or not isInteger(d.revision) or d.revision < 1 then
            return nil, "DEFINITION_ENTRY"
        end
        if key ~= defKey(d.libraryId, d.recipeId, d.revision) then return nil, "DEFINITION_KEY" end
        if not S.validateDefinitionShape(d.definition) then return nil, "DEFINITION_SHAPE" end
        out.definitions[key] = { libraryId = d.libraryId, recipeId = d.recipeId, revision = d.revision, definition = copy(d.definition) }
    end
    for id, lib in pairs(libs) do
        if not nonempty(id, 128) or type(lib) ~= "table" or not isInteger(lib.ownerFarmId) or type(lib.retired) ~= "boolean"
            or not isInteger(lib.libraryRevision) or lib.libraryRevision < 1 or type(lib.recipes) ~= "table"
            or (lib.retiredReason ~= nil and not nonempty(lib.retiredReason, 64)) then
            return nil, "LIBRARY_ENTRY"
        end
        if (serialOf(id) or math.huge) > payload.nextSerial then return nil, "SERIAL" end
        local recipes = {}
        for rid, r in pairs(lib.recipes) do
            if not nonempty(rid, 128) or type(r) ~= "table" or not isInteger(r.currentRevision) or r.currentRevision < 1 or type(r.retired) ~= "boolean" then
                return nil, "RECIPE_ENTRY"
            end
            if (serialOf(rid) or math.huge) > payload.nextSerial then return nil, "SERIAL" end
            if out.definitions[defKey(id, rid, r.currentRevision)] == nil then return nil, "REFERENCE_MISSING" end
            recipes[rid] = { currentRevision = r.currentRevision, retired = r.retired }
        end
        out.libraries[id] = { ownerFarmId = lib.ownerFarmId, retired = lib.retired, retiredReason = lib.retiredReason, libraryRevision = lib.libraryRevision, recipes = recipes }
    end
    for _, d in pairs(out.definitions) do
        local lib = out.libraries[d.libraryId]
        if lib == nil or lib.recipes[d.recipeId] == nil then return nil, "ORPHAN_DEFINITION" end
    end
    -- A singleplayer opening of a multiplayer save (:363): each merged farm's library is retired under its
    -- old identity; the survivor's is untouched. SG-1 retains an OWNER section under a FAILED or WAITING
    -- conversion, so only MERGED and UNCHANGED reach here.
    local fr = type(context) == "table" and context.farmRestore or nil
    if type(fr) == "table" and fr.phase == SGFarmRestore.PHASE_MERGED and type(fr.sourceToTarget) == "table" then
        for _, lib in pairs(out.libraries) do
            local r = SGFarmRestore.library({ owner = lib.ownerFarmId, retired = lib.retired }, fr.sourceToTarget)
            if r.retired and not lib.retired then
                lib.retired = true
                lib.retiredReason = "FARM_MERGED"
                lib.libraryRevision = lib.libraryRevision + 1
            end
        end
    end
    return out
end

function L:commit(candidate)
    self.libraries = candidate.libraries
    self.definitions = candidate.definitions
    self.nextSerial = candidate.nextSerial
    self.committed = "READY"
    self.reason = nil
    self.locks = {}
    self:changed()
end

function L:clear(reason)
    self.libraries = {}
    self.definitions = {}
    self.locks = {}
    self.committed = "UNAVAILABLE"
    self.reason = tostring(reason or "CLEARED")
    self:changed()
end

-- ---------------------------------------------------------
-- Libraries and their resolution
-- ---------------------------------------------------------
function L:mint(prefix)
    self.nextSerial = self.nextSerial + 1
    return prefix .. tostring(self.nextSerial)
end

--- The farm's live library: its id and record, or nil.
function L:liveLibraryOf(farmId)
    for id, lib in pairs(self.libraries) do
        if not lib.retired and lib.ownerFarmId == farmId then return id, lib end
    end
    return nil
end

function L:createLibrary(farmId)
    local id = self:mint("lib")
    local lib = { ownerFarmId = farmId, retired = false, libraryRevision = 1, recipes = {} }
    self.libraries[id] = lib
    self:changed()
    return id, lib
end

--- Resolve a library selector for a server-built actor (:375). "@current" is the actor's own live
--- library, created on first use when `create` and the library is READY; an explicit id names only the
--- actor's own live library. Returns libraryId, library, or nil, availability, reason (nil, "NONE" for
--- "@current" with no library and no creation).
function L:resolve(actor, selector, create)
    local state = self:readiness()
    if state == "LOADING" then return nil, "WAITING", S.REASON.LOADING end
    if state ~= "READY" then return nil, "UNAVAILABLE", S.REASON.UNAVAILABLE end
    local farmId = type(actor) == "table" and actor.farmId or nil
    if not SGRecords.isOrdinaryFarmId(farmId) then return nil, "DENIED", S.REASON.NOT_OWNED end
    if selector == S.CURRENT then
        local id, lib = self:liveLibraryOf(farmId)
        if id == nil and create then id, lib = self:createLibrary(farmId) end
        if id == nil then return nil, "NONE" end
        return id, lib
    end
    local lib = self.libraries[selector]
    if lib == nil or lib.ownerFarmId ~= farmId then return nil, "DENIED", S.REASON.NOT_OWNED end
    if lib.retired then return nil, "UNAVAILABLE", S.REASON.RETIRED end
    return selector, lib
end

-- ---------------------------------------------------------
-- Recipes
-- ---------------------------------------------------------
--- Save a validated definition as a new recipe (recipeId nil) or a new revision of one. Returns
--- recipeId, revision.
function L:saveRecipe(libraryId, recipeId, definition)
    local lib = self.libraries[libraryId]
    local revision
    if recipeId == nil then
        recipeId = self:mint("r")
        revision = 1
        lib.recipes[recipeId] = { currentRevision = revision, retired = false }
    else
        local r = lib.recipes[recipeId]
        local old = defKey(libraryId, recipeId, r.currentRevision)
        revision = r.currentRevision + 1
        r.currentRevision = revision
        -- Nothing outside the library references a revision in this part: the superseded one goes.
        self.definitions[old] = nil
        self.locks[old] = nil
    end
    self.definitions[defKey(libraryId, recipeId, revision)] = { libraryId = libraryId, recipeId = recipeId, revision = revision, definition = copy(definition) }
    lib.libraryRevision = lib.libraryRevision + 1
    self:changed()
    return recipeId, revision
end

function L:retireRecipe(libraryId, recipeId)
    local lib = self.libraries[libraryId]
    lib.recipes[recipeId].retired = true
    lib.libraryRevision = lib.libraryRevision + 1
    self:changed()
end

--- Retire every live library of a farm. Returns how many.
function L:retireLibrariesOf(farmId, reason)
    local n = 0
    for _, lib in pairs(self.libraries) do
        if not lib.retired and lib.ownerFarmId == farmId then
            lib.retired = true
            lib.retiredReason = reason
            lib.libraryRevision = lib.libraryRevision + 1
            n = n + 1
        end
    end
    if n > 0 then self:changed() end
    return n
end

--- A saved revision's availability, from its profile (:357, :359), cached until the next registration.
function L:lock(key)
    local l = self.locks[key]
    if l == nil then
        local d = self.definitions[key]
        local ok, why = false, S.REASON.RECIPE_UNKNOWN
        if d ~= nil then ok, why = self.profiles:accept(d.definition) end
        l = { available = ok == true, reasonCode = ok and "" or tostring(why) }
        self.locks[key] = l
    end
    return l
end

--- A profile registered: every saved revision is read again (a LOCKED one unlocks on EXACT_ACCEPT).
function L:onProfileRegistered()
    self.locks = {}
    self:changed()
end

-- ---------------------------------------------------------
-- Rows (SG4_RECIPE_LIBRARY_1, :381)
-- ---------------------------------------------------------
function L:libraryRow(libraryId)
    local lib = self.libraries[libraryId]
    return { rowKind = "LIBRARY", libraryId = libraryId, libraryRevision = tostring(lib.libraryRevision), retired = lib.retired }
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- The library's recipes, each at its current revision, retired ones flagged.
function L:recipeRows(libraryId)
    local lib = self.libraries[libraryId]
    local rows = {}
    for _, rid in ipairs(sortedKeys(lib.recipes)) do
        local r = lib.recipes[rid]
        local key = defKey(libraryId, rid, r.currentRevision)
        local lock = self:lock(key)
        rows[#rows + 1] = { rowKind = "RECIPE", libraryId = libraryId, recipeId = rid, recipeRevision = tostring(r.currentRevision), current = true,
                            retired = r.retired, availability = lock.available and "AVAILABLE" or "UNAVAILABLE", reasonCode = lock.reasonCode,
                            definition = copy(self.definitions[key].definition) }
    end
    return rows
end

--- One revision's saved definition, or nil.
function L:definitionOf(libraryId, recipeId, revision)
    local d = self.definitions[defKey(libraryId, recipeId, revision)]
    return d ~= nil and d.definition or nil
end
