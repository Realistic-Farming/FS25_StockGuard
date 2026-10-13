-- =========================================================
-- FS25_StockGuard - SG-4, the recipe library member (SG-4 Part 2a)
-- =========================================================
-- SG-4 v2.4 build brief :62-72, :112-120, :345-385, :407-417; Bob's SG-4 intake Part 2 and his R-15
-- of 2026-10-08 (Desk Office/Drafts/BOB-R15-SG4-PART2-LIBRARY-NATIVE-MIXER-2026-10-08.md). Tyson
-- split Part 2: this is 2a, the library and its plumbing. The native mixer GUIDANCE profile is 2b,
-- parked until Design answers on its labels.
--
-- SERVER, at trusted initialization (main.lua's native kernel install, beside SG-3, before the restore
-- barrier, so a saved library finds its section):
--   * the "sg4" save section (SG4Library), farmRestorePolicy OWNER;
--   * the management owner "sg4" for LIBRARY targets (SG4Owner): SAVE_RECIPE and RETIRE_RECIPE, QUOTED;
--   * the RECIPE_LIBRARY view's one owner (SG-1's registerRecipeLibraryView, SG-4 Part 1), building
--     SG4_RECIPE_LIBRARY_1 for the actor's library ("@current" or its own explicit id);
--   * on the handle: registerPreparationProfile (SG4Profiles), and the server-local, farm-scoped reads
--     listRecipes(trustedActor, profileId) and readRecipe(trustedActor, recipeId, revision) (:345);
--   * the farm lifecycle: FARM_DELETED and FARM_CREATED (:363).
-- CLIENT: the RECIPE_LIBRARY view's row check only, so a client can decode the library (:367). It
-- builds nothing; the library is the server's.
--
-- RELEASE (:417): library persistence is core plumbing with an empty lock set. No preparation gameplay
-- ships here, so nothing in this part is locked.
--
-- WITHHELD (unbuilt dependencies, Bob's R-15): arming, binding, guidanceCarriers and recipeBinding
-- (SG2-7); sg4.composition and sg4.mixerGroups; preparation, execution and recovery (EP-1); the feeding
-- robot; compareRecipe; a profile's CARRIER resolution and native-access callbacks; and the native mixer
-- profile itself (2b, pending Design on its labels).

SG4 = SG4 or {}
local M = SG4
local S = SG4Schema
local copy = SGValues.copy

M.current = nil
M.VIEW_OWNER_ID = "sg4"

local function log(msg) print("[StockGuard] SG-4: " .. tostring(msg)) end

--- SG-1's own state for the "sg4" section when nothing was committed: LOADING before the staged load,
--- READY on first use or with no saved section, UNAVAILABLE when SG-1 retained it.
function M.sectionState(host)
    local save = host ~= nil and host.save or nil
    if save == nil or save.loadResult == nil then return "LOADING" end
    local st = save.sectionState[SG4Library.SECTION_ID]
    if st ~= nil and st.ready == true then return "READY", st.reason end
    return "UNAVAILABLE", (st and st.reason) or save.loadResult.reason
end

-- ---------------------------------------------------------
-- The RECIPE_LIBRARY view (SG-1 builds the envelope; this builds the rows)
-- ---------------------------------------------------------
--- The actor's library view. "@current" creates the first-use library only while the library is READY.
function M.buildView(m, actor, selection)
    local id, libOrState, reason = m.library:resolve(actor, selection.libraryId, true)
    if id == nil then
        return { state = libOrState == "NONE" and "UNAVAILABLE" or libOrState, reason = reason or S.REASON.UNAVAILABLE }
    end
    local rows = { m.library:libraryRow(id) }
    for _, r in ipairs(m.library:recipeRows(id)) do rows[#rows + 1] = r end
    for _, p in ipairs(m.profiles:list()) do rows[#rows + 1] = SG4Profiles.row(p) end
    -- The store's revision advances on every library change and every profile registration (:369).
    return { state = "READY", libraryId = id, dataRevision = "d" .. tostring(m.library.dataRevision), rows = rows }
end

function M.viewSpec(m)
    return {
        version = 1, schemaVersion = S.LIBRARY_SCHEMA_VERSION,
        buildView = function(actor, selection) return M.buildView(m, actor, selection) end,
        validateRows = S.validateRows,
        readiness = function()
            local state, reason = m.library:readiness()
            return { state = state, reasonCode = reason ~= nil and tostring(reason) or nil }
        end,
    }
end

-- ---------------------------------------------------------
-- The handle's reads (:345), server-local and farm-scoped
-- ---------------------------------------------------------
--- The actor's recipes (current revisions), optionally of one profile.
function M.listRecipes(m, actor, profileId)
    local id, libOrState, reason = m.library:resolve(actor, S.CURRENT, false)
    if id == nil then
        if libOrState == "NONE" then return { state = "READY", recipes = {} } end
        return { state = libOrState, reason = reason, recipes = {} }
    end
    local out = {}
    for _, r in ipairs(m.library:recipeRows(id)) do
        if profileId == nil or r.definition.profileId == profileId then
            out[#out + 1] = { recipeId = r.recipeId, recipeRevision = r.recipeRevision, label = r.definition.label, profileId = r.definition.profileId,
                              intent = r.definition.intent, retired = r.retired, availability = r.availability, reasonCode = r.reasonCode }
        end
    end
    return { state = "READY", libraryId = id, recipes = out }
end

--- One recipe revision of the actor's library, detached; a retired recipe stays readable.
function M.readRecipe(m, actor, recipeId, revision)
    local id, libOrState, reason = m.library:resolve(actor, S.CURRENT, false)
    if id == nil then return { state = libOrState == "NONE" and "UNAVAILABLE" or libOrState, reason = reason or S.REASON.RECIPE_UNKNOWN } end
    local r = type(recipeId) == "string" and m.library.libraries[id].recipes[recipeId] or nil
    local rev = tonumber(revision)
    local definition = r ~= nil and rev ~= nil and m.library:definitionOf(id, recipeId, rev) or nil
    if definition == nil then return { state = "UNAVAILABLE", reason = S.REASON.RECIPE_UNKNOWN } end
    local lock = m.library:lock(SG4Library.defKey(id, recipeId, rev))
    return { state = "READY", libraryId = id, recipeId = recipeId, recipeRevision = tostring(rev), current = rev == r.currentRevision, retired = r.retired,
             availability = lock.available and "AVAILABLE" or "UNAVAILABLE", reasonCode = lock.reasonCode, definition = copy(definition) }
end

-- ---------------------------------------------------------
-- Install and teardown
-- ---------------------------------------------------------
--- Server: the whole member. Returns the member, or nil and a reason.
function M.install(handle, host)
    if g_server == nil then return nil, "CLIENT" end
    if type(handle) ~= "table" or type(handle.registerSaveSection) ~= "function" or type(handle.registerRecipeLibraryView) ~= "function" then return nil, "NO_HANDLE" end
    local m = { handle = handle, host = host }
    m.profiles = SG4Profiles.new(function() if m.library ~= nil then m.library:onProfileRegistered() end end)
    m.library = SG4Library.new(m.profiles, function() return M.sectionState(host) end)
    m.library.onChanged = function()
        if host ~= nil and host.transport ~= nil then host.transport:markDirty() end
    end
    local section, whyS = handle.registerSaveSection(SG4Library.SECTION_ID, {
        schemaVersion = SG4Library.SECTION_SCHEMA,
        farmRestorePolicy = "OWNER",
        serialize = function() return m.library:serialize() end,
        stageLoad = function(payload, context) return SG4Library.stage(payload, context) end,
        commitLoad = function(candidate) m.library:commit(candidate) end,
        clearReadiness = function(reason) m.library:clear(reason) end,
    })
    if section == nil then return nil, "SECTION:" .. tostring(whyS) end
    m.sectionLease = section
    local owner, whyO = handle.registerManagementOwner(SG4Owner.OWNER_ID, SG4Owner.spec(m))
    if owner == nil then return nil, "OWNER:" .. tostring(whyO) end
    m.ownerLease = owner
    local view, whyV = handle.registerRecipeLibraryView(M.VIEW_OWNER_ID, M.viewSpec(m))
    if view == nil then return nil, "VIEW:" .. tostring(whyV) end
    m.viewLease = view
    handle.registerPreparationProfile = function(providerId, profileId, version, definition, callbacks)
        return m.profiles:register(providerId, profileId, version, definition, callbacks)
    end
    handle.listRecipes = function(trustedActor, profileId) return M.listRecipes(m, trustedActor, profileId) end
    handle.readRecipe = function(trustedActor, recipeId, revision) return M.readRecipe(m, trustedActor, recipeId, revision) end
    -- The farm lifecycle (:363). FarmManager publishes FARM_DELETED (delayed) on a deleted farm object and
    -- FARM_CREATED from createFarm (farms/FarmManager.lua:244-247, :323).
    if g_messageCenter ~= nil and type(g_messageCenter.subscribe) == "function" and MessageType ~= nil then
        if MessageType.FARM_DELETED ~= nil then
            g_messageCenter:subscribe(MessageType.FARM_DELETED, function(_, farmId) m.library:retireLibrariesOf(farmId, "FARM_DELETED") end, m)
        end
        if MessageType.FARM_CREATED ~= nil then
            g_messageCenter:subscribe(MessageType.FARM_CREATED, function(_, farmId) m.library:retireLibrariesOf(farmId, "FARM_ID_REUSED") end, m)
        end
    end
    M.current = m
    log("installed: the recipe library section, its owner and its view; no preparation profile is registered in this part")
    return m
end

--- Client: the library view's row check, so the client decodes what the server publishes.
function M.installClient(handle)
    if type(handle) ~= "table" or type(handle.registerRecipeLibraryView) ~= "function" then return nil, "NO_HANDLE" end
    return handle.registerRecipeLibraryView(M.VIEW_OWNER_ID, {
        version = 1, schemaVersion = S.LIBRARY_SCHEMA_VERSION,
        buildView = function() return { state = "UNAVAILABLE", reason = S.REASON.UNAVAILABLE } end,
        validateRows = S.validateRows,
    })
end

function M.teardown(handle)
    local m = M.current
    if m ~= nil and g_messageCenter ~= nil and type(g_messageCenter.unsubscribeAll) == "function" then pcall(g_messageCenter.unsubscribeAll, g_messageCenter, m) end
    if type(handle) == "table" then
        handle.registerPreparationProfile, handle.listRecipes, handle.readRecipe = nil, nil, nil
    end
    M.current = nil
end
