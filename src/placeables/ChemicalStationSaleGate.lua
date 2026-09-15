-- =========================================================
-- FS25_StockGuard - EP-1 chemical station: shop sale gate (pure logic)
-- =========================================================
-- Arissani's ruling: every bay empty before sale. canBeSold returns false while
-- any actual PRODUCT_A / PRODUCT_B / WATER / RF_WIP / RF_FINISHED Storage has
-- positive native quantity, or a live batch, reservation, active recovery or
-- unfinished restore prevents a proved empty close (brief, section 3).
--
-- Per role, every entry of the actual Storage:getFillLevels() table is
-- checked, including unexpected material identities. Any positive entry
-- blocks. A missing or non-table quantity, or a non-finite or negative entry,
-- is UNAVAILABLE, never empty. Positive and negative entries are never summed
-- into a false zero. Before zero counts as empty the role Storage must exist,
-- its slot must be READY and the expected fill type must actually be
-- supported (native Storage:getFillLevel returns zero for an absent type).
--
-- The overwritten method is canBeSold(superFunc): superFunc(self) once, native
-- refusal preserved; otherwise exactly (false, localizedReason) when any role
-- is positive or unavailable or live work remains. It never returns
-- (false, nil): the single-item ShopController path (gui/ShopController.lua:
-- 889-896) treats a nil warning as permission to continue. The server
-- SellPlaceableEvent calls canBeSold again before onSell, so the same gate is
-- rechecked there.
--
-- Registration: SpecializationUtil.registerOverwrittenFunction (specialization/
-- SpecializationUtil.lua:50-60) is silent when the slot is nil, and the
-- installed composite (utils/Utils.lua:394-401) is not pointer-equal to our
-- function. attach() therefore proves the base slot exists first and then
-- proves the slot was replaced, not that it equals our function.
-- =========================================================

ChemicalStationSaleGate = ChemicalStationSaleGate or {}

local SaleGate = ChemicalStationSaleGate

SaleGate.REASON_L10N_KEY = "stockGuard_chemicalStation_emptyAllBays"

-- Gate reason codes (reference bar vocabulary).
SaleGate.EMPTY_ALL_BAYS_REQUIRED = "EMPTY_ALL_BAYS_REQUIRED"
SaleGate.BAY_QUANTITY_UNAVAILABLE = "BAY_QUANTITY_UNAVAILABLE"
SaleGate.FACILITY_WORK_ACTIVE = "FACILITY_WORK_ACTIVE"

-- Per-role verdicts.
SaleGate.ROLE_EMPTY = "EMPTY"
SaleGate.ROLE_OCCUPIED = "OCCUPIED"
SaleGate.ROLE_UNAVAILABLE = "UNAVAILABLE"

-- Attach results.
SaleGate.ATTACH_WRAPPED = "WRAPPED"
SaleGate.ATTACH_SLOT_MISSING = "CAN_BE_SOLD_SLOT_MISSING"
SaleGate.ATTACH_NOT_REPLACED = "CAN_BE_SOLD_NOT_REPLACED"
SaleGate.ATTACH_BAD_TYPE = "PLACEABLE_TYPE_INVALID"

SaleGate.ROLE_ORDER = { "PRODUCT_A", "PRODUCT_B", "WATER", "RF_WIP", "RF_FINISHED" }

local function isFinite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- =========================================================
-- Per-role inspection
-- =========================================================

--- Inspect one role slot ({ state, storage, fillType } as built by
-- ChemicalStationRoles). Returns verdict, detail.
function SaleGate.inspectRole(slot)
    if type(slot) ~= "table" or slot.state ~= "READY" then
        return SaleGate.ROLE_UNAVAILABLE, "ROLE_NOT_READY"
    end
    local storage = slot.storage
    if type(storage) ~= "table" then
        return SaleGate.ROLE_UNAVAILABLE, "STORAGE_MISSING"
    end
    if slot.fillType == nil then
        return SaleGate.ROLE_UNAVAILABLE, "FILLTYPE_MISSING"
    end
    if type(storage.getIsFillTypeSupported) ~= "function" or storage:getIsFillTypeSupported(slot.fillType) ~= true then
        return SaleGate.ROLE_UNAVAILABLE, "FILLTYPE_UNSUPPORTED"
    end
    if type(storage.getFillLevels) ~= "function" then
        return SaleGate.ROLE_UNAVAILABLE, "LEVELS_UNREADABLE"
    end
    local levels = storage:getFillLevels()
    if type(levels) ~= "table" then
        return SaleGate.ROLE_UNAVAILABLE, "LEVELS_NOT_TABLE"
    end

    -- Two passes on purpose: an unreadable entry anywhere makes the role
    -- unavailable even when another entry is positive, and no arithmetic is
    -- done across entries.
    local positive = false
    for _, level in pairs(levels) do
        if not isFinite(level) or level < 0 then
            return SaleGate.ROLE_UNAVAILABLE, "LEVEL_INVALID"
        end
        if level > 0 then
            positive = true
        end
    end
    if positive then
        return SaleGate.ROLE_OCCUPIED, nil
    end
    return SaleGate.ROLE_EMPTY, nil
end

-- =========================================================
-- Whole-facility evaluation
-- =========================================================

--- Evaluate the five fixed roles plus live work.
-- slotsByRole: { PRODUCT_A = slot, ... } (any missing role is unavailable)
-- live: { batch, reservation, recovery, restore } truthy flags
-- Returns allowed (bool), reasonCode (nil when allowed), detail table.
function SaleGate.evaluate(slotsByRole, live)
    local detail = { roles = {} }
    slotsByRole = slotsByRole or {}
    for _, role in ipairs(SaleGate.ROLE_ORDER) do
        local verdict, why = SaleGate.inspectRole(slotsByRole[role])
        detail.roles[role] = { verdict = verdict, detail = why }
        if verdict == SaleGate.ROLE_UNAVAILABLE then
            return false, SaleGate.BAY_QUANTITY_UNAVAILABLE, detail
        end
        if verdict == SaleGate.ROLE_OCCUPIED then
            return false, SaleGate.EMPTY_ALL_BAYS_REQUIRED, detail
        end
    end
    live = live or {}
    if live.batch or live.reservation or live.recovery or live.restore then
        return false, SaleGate.FACILITY_WORK_ACTIVE, detail
    end
    return true, nil, detail
end

--- Localized reason. getText is injected (g_i18n:getText in the facility);
-- the l10n key itself is the fallback so the warning is never nil.
function SaleGate.localizedReason(getText)
    local text = nil
    if type(getText) == "function" then
        local ok, value = pcall(getText, SaleGate.REASON_L10N_KEY)
        if ok and type(value) == "string" and value ~= "" then
            text = value
        end
    end
    return text or SaleGate.REASON_L10N_KEY
end

-- =========================================================
-- The overwritten method
-- =========================================================

--- Decide canBeSold for a facility. Pure: the facility exposes
--   facility:getSaleGateSlots() -> slotsByRole
--   facility:getSaleGateLive()  -> live flags
--   facility.getSaleGateText    -> optional getText(key) (may be nil)
-- superFunc is called exactly once. Returns allowed, warning where warning is
-- never nil when allowed is false.
function SaleGate.decide(facility, superFunc)
    local superAllowed, superWarning = superFunc(facility)
    if not superAllowed then
        if superWarning == nil then
            superWarning = SaleGate.localizedReason(facility and facility.getSaleGateText)
        end
        return false, superWarning
    end
    local slots = facility.getSaleGateSlots and facility:getSaleGateSlots() or nil
    local live = facility.getSaleGateLive and facility:getSaleGateLive() or nil
    local allowed = SaleGate.evaluate(slots, live)
    if not allowed then
        return false, SaleGate.localizedReason(facility.getSaleGateText)
    end
    return superAllowed, superWarning
end

--- The specialization method body: canBeSold(self, superFunc).
function SaleGate.canBeSold(facility, superFunc)
    return SaleGate.decide(facility, superFunc)
end

-- =========================================================
-- Registration proof
-- =========================================================

--- Install the gate on a placeable type through the native helper and prove
-- the slot was replaced. registerFn defaults to
-- SpecializationUtil.registerOverwrittenFunction when the engine is present.
-- Returns ok, reason. A missing base slot or an unchanged slot is a failure
-- that makes the facility type unavailable; it never falls back to native allow.
function SaleGate.attach(placeableType, registerFn)
    if type(placeableType) ~= "table" or type(placeableType.functions) ~= "table" then
        return false, SaleGate.ATTACH_BAD_TYPE
    end
    local before = placeableType.functions.canBeSold
    if before == nil then
        return false, SaleGate.ATTACH_SLOT_MISSING
    end
    if registerFn == nil and SpecializationUtil ~= nil then
        registerFn = SpecializationUtil.registerOverwrittenFunction
    end
    if type(registerFn) ~= "function" then
        return false, SaleGate.ATTACH_NOT_REPLACED
    end
    registerFn(placeableType, "canBeSold", SaleGate.canBeSold)
    local after = placeableType.functions.canBeSold
    if after == nil or after == before then
        return false, SaleGate.ATTACH_NOT_REPLACED
    end
    return true, SaleGate.ATTACH_WRAPPED
end
