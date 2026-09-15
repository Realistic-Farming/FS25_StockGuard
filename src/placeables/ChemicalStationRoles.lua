-- =========================================================
-- FS25_StockGuard - EP-1 chemical station: fixed role slots (pure logic)
-- =========================================================
-- The station has five persistent roles, each bound to one native Storage.
-- Slots are declared by fixed index and never slide: a role whose material
-- cannot resolve, or whose Storage.load failed, stays an explicit UNAVAILABLE
-- slot at its declared index with no attached route. Iteration, save, stream
-- and restore address a store by its declared role, never by array position
-- after a missing role (brief, section 3 "fixed declared role slots").
--
-- Ingredient matching (brief, "physical operation closure"): PRODUCT_A and
-- PRODUCT_B are physical slots, not first/second chemical identities. A pair
-- recipe matches its two ingredients to whichever bay holds each, unordered.
-- A single-product recipe held in both bays binds the ordered draw list
-- {PRODUCT_A, PRODUCT_B}: A is drawn first, then B; each bound role is
-- revalidated on every increment. Water stays the separate DILUENT role.
--
-- No engine call is made at load. The physical binding (Storage.new/load,
-- station registration) is the held facility Lua; this module only decides.
-- =========================================================

ChemicalStationRoles = ChemicalStationRoles or {}

local Roles = ChemicalStationRoles

Roles.PRODUCT_A   = "PRODUCT_A"
Roles.PRODUCT_B   = "PRODUCT_B"
Roles.WATER       = "WATER"
Roles.RF_WIP      = "RF_WIP"
Roles.RF_FINISHED = "RF_FINISHED"

-- Declared slot indexes. Fixed by the brief; independent of which Storage loads.
Roles.INDEX = {
    PRODUCT_A = 1,
    PRODUCT_B = 2,
    WATER = 3,
    RF_WIP = 4,
    RF_FINISHED = 5,
}

-- Declared order, index 1..5.
Roles.ORDER = { "PRODUCT_A", "PRODUCT_B", "WATER", "RF_WIP", "RF_FINISHED" }

Roles.COUNT = 5

-- Approved starting capacities in litres (physical-prep config, roles[].capacityLitres).
Roles.CAPACITY_LITRES = {
    PRODUCT_A = 2500,
    PRODUCT_B = 2500,
    WATER = 10000,
    RF_WIP = 5000,
    RF_FINISHED = 5000,
}

-- Material policy per role (physical-prep config, roles[].materialPolicy).
Roles.MATERIAL_POLICY = {
    PRODUCT_A = "SOIL_PROFILE_ATOMIC_PRODUCT_A",
    PRODUCT_B = "SOIL_PROFILE_ATOMIC_PRODUCT_B",
    WATER = "WATER",
    RF_WIP = "RF_PREPARED_TREATMENT",
    RF_FINISHED = "RF_PREPARED_TREATMENT",
}

-- Slot states.
Roles.READY = "READY"
Roles.UNAVAILABLE = "UNAVAILABLE"

-- Unavailable reasons.
Roles.REASON_NOT_RESOLVED = "NOT_RESOLVED"
Roles.REASON_MATERIAL_UNRESOLVED = "MATERIAL_UNRESOLVED"
Roles.REASON_STORAGE_MISSING = "STORAGE_MISSING"
Roles.REASON_STORAGE_LOAD_FAILED = "STORAGE_LOAD_FAILED"
Roles.REASON_UNKNOWN_ROLE = "UNKNOWN_ROLE"
Roles.REASON_ROLE_MISMATCH = "ROLE_MISMATCH"

-- Ingredient matching reasons (existing SG-4 shortage/incompatible contract).
Roles.MATCH_OK = "MATCHED"
Roles.MATCH_SHORTAGE = "INGREDIENT_SHORTAGE"
Roles.MATCH_INCOMPATIBLE = "INGREDIENT_INCOMPATIBLE"
Roles.MATCH_SOURCE_UNAVAILABLE = "SOURCE_UNAVAILABLE"
Roles.MATCH_INVALID_DEFINITION = "INVALID_DEFINITION"

local function isKnownRole(role)
    return type(role) == "string" and Roles.INDEX[role] ~= nil
end

--- True for a nonempty string material name.
local function isMaterialName(v)
    return type(v) == "string" and v ~= ""
end

-- =========================================================
-- Slot table
-- =========================================================

--- Build the five declared slots, all UNAVAILABLE / NOT_RESOLVED.
-- Returns an array indexed 1..5 whose entries carry their declared role and index.
function Roles.newSlots()
    local slots = {}
    for index, role in ipairs(Roles.ORDER) do
        slots[index] = {
            index = index,
            role = role,
            state = Roles.UNAVAILABLE,
            reason = Roles.REASON_NOT_RESOLVED,
            storage = nil,
            fillType = nil,
            capacity = Roles.CAPACITY_LITRES[role],
            route = nil,
        }
    end
    return slots
end

--- Slot for a declared role, or nil for an unknown role. Never shifts.
function Roles.getSlot(slots, role)
    if type(slots) ~= "table" or not isKnownRole(role) then
        return nil
    end
    return slots[Roles.INDEX[role]]
end

--- Resolve a role from an actual binding attempt.
-- resolution = { storage = <Storage or nil>, fillType = <index or nil>, loadOk = <bool> }
-- A slot only becomes READY when the material resolved, the Storage exists and
-- its load succeeded. Anything else leaves the slot at its index as UNAVAILABLE
-- with an explicit reason and no route. Returns state, reason.
function Roles.resolveSlot(slots, role, resolution)
    local slot = Roles.getSlot(slots, role)
    if slot == nil then
        return Roles.UNAVAILABLE, Roles.REASON_UNKNOWN_ROLE
    end
    resolution = resolution or {}

    slot.storage = nil
    slot.fillType = nil
    slot.route = nil

    if resolution.fillType == nil then
        slot.state, slot.reason = Roles.UNAVAILABLE, Roles.REASON_MATERIAL_UNRESOLVED
    elseif resolution.storage == nil then
        slot.state, slot.reason = Roles.UNAVAILABLE, Roles.REASON_STORAGE_MISSING
    elseif resolution.loadOk ~= true then
        slot.state, slot.reason = Roles.UNAVAILABLE, Roles.REASON_STORAGE_LOAD_FAILED
    else
        slot.state, slot.reason = Roles.READY, nil
        slot.storage = resolution.storage
        slot.fillType = resolution.fillType
    end
    return slot.state, slot.reason
end

--- Withdraw a resolved slot (teardown, removed binding). Index and role stay.
function Roles.withdrawSlot(slots, role, reason)
    local slot = Roles.getSlot(slots, role)
    if slot == nil then
        return false
    end
    slot.state = Roles.UNAVAILABLE
    slot.reason = reason or Roles.REASON_STORAGE_MISSING
    slot.storage = nil
    slot.fillType = nil
    slot.route = nil
    return true
end

function Roles.isReady(slots, role)
    local slot = Roles.getSlot(slots, role)
    return slot ~= nil and slot.state == Roles.READY
end

--- Attach a route to a READY slot only. An UNAVAILABLE slot never gets a route.
function Roles.attachRoute(slots, role, route)
    local slot = Roles.getSlot(slots, role)
    if slot == nil or slot.state ~= Roles.READY then
        return false
    end
    slot.route = route
    return true
end

--- Visit every slot in declared index order (READY and UNAVAILABLE alike).
-- fn(index, role, slot). Callers that only want resolved stores test slot.state.
function Roles.forEachSlot(slots, fn)
    for index, role in ipairs(Roles.ORDER) do
        fn(index, role, slots[index])
    end
end

--- Visit only READY slots, still reporting each one's declared index.
function Roles.forEachReady(slots, fn)
    for index, role in ipairs(Roles.ORDER) do
        local slot = slots[index]
        if slot ~= nil and slot.state == Roles.READY then
            fn(index, role, slot)
        end
    end
end

--- Restore a saved role payload only into its own declared role.
-- payload = { role = <name>, index = <declared index> }. A payload whose role or
-- index does not match the declared slot is refused; nothing is rebound by
-- ordinal position. Returns ok, reason.
function Roles.admitRestore(slots, payload)
    if type(payload) ~= "table" or not isKnownRole(payload.role) then
        return false, Roles.REASON_UNKNOWN_ROLE
    end
    local slot = Roles.getSlot(slots, payload.role)
    if payload.index ~= slot.index then
        return false, Roles.REASON_ROLE_MISMATCH
    end
    if slot.state ~= Roles.READY then
        return false, slot.reason
    end
    return true, nil
end

--- Publish the honest readiness of every declared slot (for resolvePhysicalRoles).
-- Returns an array 1..5 of { index, role, state, reason, capacity }.
function Roles.publish(slots)
    local out = {}
    for index, role in ipairs(Roles.ORDER) do
        local slot = slots[index]
        out[index] = {
            index = index,
            role = role,
            state = slot and slot.state or Roles.UNAVAILABLE,
            reason = slot and slot.reason or Roles.REASON_NOT_RESOLVED,
            capacity = Roles.CAPACITY_LITRES[role],
        }
    end
    return out
end

-- =========================================================
-- Ingredient matching
-- =========================================================

--- Match a recipe definition's ingredients against the actual bay contents.
-- definition.ingredients: array of { ingredientId = <canonical name>, kind = "PRODUCT" | "DILUENT" }
-- bays: { PRODUCT_A = <canonical name or nil>, PRODUCT_B = ..., WATER = ... }
--   A bay value of nil means empty; a non-string, non-nil value means unreadable.
-- Returns ok, reason, bindings where bindings maps ingredientId -> role, or,
-- for a single product held in both bays, -> the ordered draw list
-- { "PRODUCT_A", "PRODUCT_B" } (A first, then B; one chemical, never two
-- partners). Pair recipes match unordered (SULFUR in B and COPPER_HYDROXIDE in
-- A is the same pair as the reverse). Each bay serves at most one ingredient.
-- Wrong, missing or unreadable sources refuse before any debit.
function Roles.matchIngredients(definition, bays)
    if type(definition) ~= "table" or type(definition.ingredients) ~= "table" or #definition.ingredients == 0 then
        return false, Roles.MATCH_INVALID_DEFINITION, nil
    end
    if type(bays) ~= "table" then
        return false, Roles.MATCH_SOURCE_UNAVAILABLE, nil
    end

    -- Unreadable bay contents are unavailable, never treated as empty or as a match.
    for _, role in ipairs({ Roles.PRODUCT_A, Roles.PRODUCT_B, Roles.WATER }) do
        local v = bays[role]
        if v ~= nil and not isMaterialName(v) then
            return false, Roles.MATCH_SOURCE_UNAVAILABLE, nil
        end
    end

    local products, diluents = {}, {}
    local seen = {}
    for _, ing in ipairs(definition.ingredients) do
        if type(ing) ~= "table" or not isMaterialName(ing.ingredientId) or seen[ing.ingredientId] then
            return false, Roles.MATCH_INVALID_DEFINITION, nil
        end
        seen[ing.ingredientId] = true
        if ing.kind == "DILUENT" then
            diluents[#diluents + 1] = ing.ingredientId
        elseif ing.kind == "PRODUCT" or ing.kind == nil then
            products[#products + 1] = ing.ingredientId
        else
            return false, Roles.MATCH_INVALID_DEFINITION, nil
        end
    end
    if #products > 2 or #diluents > 1 then
        return false, Roles.MATCH_INVALID_DEFINITION, nil
    end

    local bindings = {}
    local used = {}

    -- Products, phase 1: bind every ingredient that a bay actually holds.
    -- Fixed A-then-B search per ingredient, each bay used once. For a pair this
    -- is order independent: each ingredient claims whichever bay holds it.
    local unbound = {}
    for _, id in ipairs(products) do
        local found = nil
        for _, role in ipairs({ Roles.PRODUCT_A, Roles.PRODUCT_B }) do
            if not used[role] and bays[role] == id then
                found = role
                break
            end
        end
        if found ~= nil then
            used[found] = true
            bindings[id] = found
        else
            unbound[#unbound + 1] = id
        end
    end

    -- Phase 2: an unbound ingredient is a shortage when the remaining bays are
    -- empty, and incompatible when a remaining bay holds something else: a
    -- chemical outside this recipe, or a duplicate of a partner already bound.
    if #unbound > 0 then
        for _, role in ipairs({ Roles.PRODUCT_A, Roles.PRODUCT_B }) do
            if not used[role] and bays[role] ~= nil then
                return false, Roles.MATCH_INCOMPATIBLE, nil
            end
        end
        return false, Roles.MATCH_SHORTAGE, nil
    end

    -- A single product present in both bays draws from both, A then B.
    if #products == 1 and bays[Roles.PRODUCT_A] == products[1] and bays[Roles.PRODUCT_B] == products[1] then
        bindings[products[1]] = { Roles.PRODUCT_A, Roles.PRODUCT_B }
    end

    -- Diluent: WATER must actually be water. Any other content is incompatible.
    for _, id in ipairs(diluents) do
        if bays[Roles.WATER] == nil then
            return false, Roles.MATCH_SHORTAGE, nil
        end
        if bays[Roles.WATER] ~= id then
            return false, Roles.MATCH_INCOMPATIBLE, nil
        end
        bindings[id] = Roles.WATER
    end

    return true, Roles.MATCH_OK, bindings
end

--- Revalidate a frozen ingredient -> role binding against the current bays.
-- Every bound role (each role of an ordered draw list) must still hold exactly
-- its bound ingredient. Returns ok, reason.
function Roles.revalidateBindings(bindings, bays)
    if type(bindings) ~= "table" or type(bays) ~= "table" then
        return false, Roles.MATCH_SOURCE_UNAVAILABLE
    end
    local function check(id, role)
        local v = bays[role]
        if v == nil then
            return false, Roles.MATCH_SHORTAGE
        end
        if not isMaterialName(v) then
            return false, Roles.MATCH_SOURCE_UNAVAILABLE
        end
        if v ~= id then
            return false, Roles.MATCH_INCOMPATIBLE
        end
        return true
    end
    for id, role in pairs(bindings) do
        if type(role) == "table" then
            if #role == 0 then
                return false, Roles.MATCH_SOURCE_UNAVAILABLE
            end
            for _, r in ipairs(role) do
                local ok, why = check(id, r)
                if not ok then
                    return false, why
                end
            end
        else
            local ok, why = check(id, role)
            if not ok then
                return false, why
            end
        end
    end
    return true, Roles.MATCH_OK
end

--- The ordered list of roles an ingredient is drawn from (a single role or
-- the A-then-B draw list). Returns a fresh array.
function Roles.drawOrder(bindings, ingredientId)
    local role = type(bindings) == "table" and bindings[ingredientId] or nil
    if type(role) == "table" then
        local out = {}
        for i, r in ipairs(role) do out[i] = r end
        return out
    elseif role ~= nil then
        return { role }
    end
    return {}
end
