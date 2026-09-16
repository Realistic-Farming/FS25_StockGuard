-- EP-1: chemical station pure-logic subset (roles, address, WIP route, sale gate).
--!load: src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua
-- Part 1 is the delivered reference bar (Office Tyson/StockGuard-First-Family-
-- 2026-09-15/reference-tests/EP-1-chemical_station_sale_gate_spec_test.lua) kept
-- as shipped minus its trailing summary call. Part 2 (appended below) drives the
-- built modules. No file-local T: the bench concatenates files and the prelude
-- owns T.

-- EP1 chemical station sale gate reference. No production source exists yet.
-- Models the required overwritten canBeSold decision and server recheck only.
local function gate(superAllowed,superReason,bays,live)
 if not superAllowed then return false,superReason end
 for _,role in ipairs({"PRODUCT_A","PRODUCT_B","WATER","RF_WIP","RF_FINISHED"}) do
  local q=bays[role]
  if type(q)~="number" or q<0 then return false,"BAY_QUANTITY_UNAVAILABLE" end
  if q>0 then return false,"EMPTY_ALL_BAYS_REQUIRED" end
 end
 if live.batch or live.reservation or live.recovery or live.restore then return false,"FACILITY_WORK_ACTIVE" end
 return true,superReason
end
local empty={PRODUCT_A=0,PRODUCT_B=0,WATER=0,RF_WIP=0,RF_FINISHED=0}
local ok,reason=gate(true,nil,empty,{})
T.eq("proved empty idle station may be sold",ok,true)
T.eq("empty idle station preserves native warning",reason,nil)
local raw={PRODUCT_A=1,PRODUCT_B=0,WATER=0,RF_WIP=0,RF_FINISHED=0}
local rawOk,rawReason=gate(true,nil,raw,{})
T.eq("raw product blocks sale",rawOk,false)
T.eq("occupied sale refusal carries a warning",rawReason,"EMPTY_ALL_BAYS_REQUIRED")
local finished={PRODUCT_A=0,PRODUCT_B=0,WATER=0,RF_WIP=0,RF_FINISHED=1}
T.eq("finished product blocks sale",gate(true,nil,finished,{}),false)
local missing={PRODUCT_A=0,PRODUCT_B=0,WATER=0,RF_WIP=0}
local mok,mreason=gate(true,nil,missing,{})
T.eq("unknown bay quantity is not empty",mok,false)
T.eq("unknown bay has explicit reason",mreason,"BAY_QUANTITY_UNAVAILABLE")
T.eq("live batch blocks otherwise empty sale",gate(true,nil,empty,{batch=true}),false)
T.eq("active recovery blocks otherwise empty sale",gate(true,nil,empty,{recovery=true}),false)
T.eq("unfinished restore blocks otherwise empty sale",gate(true,nil,empty,{restore=true}),false)
local sok,sreason=gate(false,"NATIVE_REFUSAL",empty,{})
T.eq("native refusal remains controlling",sok,false)
T.eq("native refusal reason is preserved",sreason,"NATIVE_REFUSAL")
local calls=0
local function serverSell(bays,live) calls=calls+1;local allowed=gate(true,nil,bays,live);return allowed end
T.eq("server sell event rechecks occupied station",serverSell(raw,{}),false)
T.eq("server gate is evaluated once per sell attempt",calls,1)
T.eq("server sell event accepts proved empty idle station",serverSell(empty,{}),true)
T.eq("second attempt receives its own server recheck",calls,2)
local function localShopProceeds(allowed,warning)
 return warning==nil
end
T.eq("false nil is unsafe in the reconstructed single-item shop path",localShopProceeds(false,nil),true)
T.eq("false plus localized reason stops the reconstructed local confirmation",localShopProceeds(false,"EMPTY_ALL_BAYS_REQUIRED"),false)
local function attach(baseSlotPresent)
 if not baseSlotPresent then return false,"CAN_BE_SOLD_SLOT_MISSING" end
 return true,"WRAPPED"
end
T.eq("missing base canBeSold slot fails facility readiness",attach(false),false)
T.eq("inherited Placeable canBeSold slot accepts facility wrapper",attach(true),true)

-- =========================================================
-- Part 2: the built modules
-- =========================================================
local Roles = ChemicalStationRoles
local Address = ChemicalStationAddress
local WipRoute = ChemicalStationWipRoute
local SaleGate = ChemicalStationSaleGate

-- Minimal native Storage stand-in: supported set + fillLevels table, native accessors.
local function makeStorage(supported, levels)
    local s = { fillTypes = {}, fillLevels = levels or {} }
    for _, ft in ipairs(supported or {}) do s.fillTypes[ft] = true end
    function s:getIsFillTypeSupported(ft) return self.fillTypes[ft] == true end
    function s:getFillLevel(ft) return self.fillLevels[ft] or 0 end
    function s:getFillLevels() return self.fillLevels end
    return s
end

-- Fill type indexes for the bench.
local FT_A, FT_B, FT_WATER, FT_RF, FT_STRAY = 11, 12, 13, 14, 99

-- Build a fully READY five-role slot set with the given per-role level tables.
local function readySlots(levelsByRole)
    local slots = Roles.newSlots()
    local ftByRole = { PRODUCT_A = FT_A, PRODUCT_B = FT_B, WATER = FT_WATER, RF_WIP = FT_RF, RF_FINISHED = FT_RF }
    for _, role in ipairs(Roles.ORDER) do
        local ft = ftByRole[role]
        local storage = makeStorage({ ft }, (levelsByRole or {})[role] or { [ft] = 0 })
        Roles.resolveSlot(slots, role, { storage = storage, fillType = ft, loadOk = true })
    end
    return slots
end

local function byRole(slots)
    local m = {}
    for _, role in ipairs(Roles.ORDER) do m[role] = Roles.getSlot(slots, role) end
    return m
end

-- (A) Fixed role slots.
do
    local slots = Roles.newSlots()
    T.eq("A1 five declared slots", #slots, 5)
    T.eq("A2 RF_WIP is slot 4 by declaration", Roles.getSlot(slots, "RF_WIP").index, 4)
    T.eq("A3 fresh slot is UNAVAILABLE", Roles.getSlot(slots, "WATER").state, "UNAVAILABLE")
    T.eq("A4 fresh slot reason", Roles.getSlot(slots, "WATER").reason, "NOT_RESOLVED")
    T.eq("A5 unknown role has no slot", Roles.getSlot(slots, "COMPOST"), nil)

    local st, why = Roles.resolveSlot(slots, "PRODUCT_A", { storage = nil, fillType = nil, loadOk = false })
    T.eq("A6 unresolved material stays UNAVAILABLE", st, "UNAVAILABLE")
    T.eq("A7 unresolved material reason", why, "MATERIAL_UNRESOLVED")
    st, why = Roles.resolveSlot(slots, "PRODUCT_A", { storage = nil, fillType = FT_A, loadOk = true })
    T.eq("A8 missing storage reason", why, "STORAGE_MISSING")
    st, why = Roles.resolveSlot(slots, "PRODUCT_A", { storage = {}, fillType = FT_A, loadOk = false })
    T.eq("A9 failed Storage.load is not advertised ready", why, "STORAGE_LOAD_FAILED")
    T.eq("A10 failed load slot has no route", Roles.attachRoute(slots, "PRODUCT_A", { name = "r" }), false)

    -- Resolve B and WATER, leave A unavailable: A keeps index 1, B stays 2, nothing slides.
    Roles.resolveSlot(slots, "PRODUCT_B", { storage = makeStorage({ FT_B }), fillType = FT_B, loadOk = true })
    Roles.resolveSlot(slots, "WATER", { storage = makeStorage({ FT_WATER }), fillType = FT_WATER, loadOk = true })
    local seen = {}
    Roles.forEachReady(slots, function(index, role) seen[#seen + 1] = index .. ":" .. role end)
    T.eq("A11 ready iteration keeps declared indexes", table.concat(seen, ","), "2:PRODUCT_B,3:WATER")
    T.eq("A12 unavailable slot still at index 1", slots[1].role, "PRODUCT_A")
    T.eq("A13 unavailable slot still index 1 state", slots[1].state, "UNAVAILABLE")
    T.eq("A14 route attaches only to READY", Roles.attachRoute(slots, "PRODUCT_B", { name = "r" }), true)

    local pub = Roles.publish(slots)
    T.eq("A15 publish reports unavailable raw role honestly", pub[1].state, "UNAVAILABLE")
    T.eq("A16 publish keeps five entries", #pub, 5)
    T.eq("A17 publish carries approved capacity", pub[3].capacity, 10000)

    T.eq("A18 restore into own role admitted", (Roles.admitRestore(slots, { role = "WATER", index = 3 })), true)
    T.eq("A19 restore with wrong index refused", select(2, Roles.admitRestore(slots, { role = "WATER", index = 1 })), "ROLE_MISMATCH")
    T.eq("A19b restore without an index is refused, never admitted by role name alone", select(2, Roles.admitRestore(slots, { role = "WATER" })), "ROLE_MISMATCH")
    T.eq("A20 restore into unavailable role refused", select(2, Roles.admitRestore(slots, { role = "PRODUCT_A", index = 1 })), "STORAGE_LOAD_FAILED")
    T.eq("A21 restore into unknown role refused", select(2, Roles.admitRestore(slots, { role = "COMPOST" })), "UNKNOWN_ROLE")

    T.eq("A22 withdraw keeps the slot", Roles.withdrawSlot(slots, "WATER", "TEARDOWN"), true)
    T.eq("A23 withdrawn slot is UNAVAILABLE at its index", slots[3].state, "UNAVAILABLE")
    T.eq("A24 withdrawn slot drops the route", slots[3].route, nil)
    T.eq("A24b withdrawn slot drops its fill type too", slots[3].fillType, nil)
end

-- (B) Unordered ingredient matching.
do
    local pair = { ingredients = { { ingredientId = "COPPER_HYDROXIDE", kind = "PRODUCT" }, { ingredientId = "SULFUR", kind = "PRODUCT" }, { ingredientId = "WATER", kind = "DILUENT" } } }
    local ok1, r1, b1 = Roles.matchIngredients(pair, { PRODUCT_A = "COPPER_HYDROXIDE", PRODUCT_B = "SULFUR", WATER = "WATER" })
    T.eq("B1 pair in declared order matches", ok1, true)
    T.eq("B2 copper bound to A", b1.COPPER_HYDROXIDE, "PRODUCT_A")
    T.eq("B3 sulfur bound to B", b1.SULFUR, "PRODUCT_B")
    local ok2, r2, b2 = Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", PRODUCT_B = "COPPER_HYDROXIDE", WATER = "WATER" })
    T.eq("B4 reversed pair is the same eligible pair", ok2, true)
    T.eq("B5 reversed: copper bound to B", b2.COPPER_HYDROXIDE, "PRODUCT_B")
    T.eq("B6 reversed: sulfur bound to A", b2.SULFUR, "PRODUCT_A")
    T.eq("B7 diluent bound to WATER", b2.WATER, "WATER")

    T.eq("B8 missing partner is shortage", select(2, Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", WATER = "WATER" })), "INGREDIENT_SHORTAGE")
    T.eq("B9 wrong chemical is incompatible", select(2, Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", PRODUCT_B = "UREA", WATER = "WATER" })), "INGREDIENT_INCOMPATIBLE")
    T.eq("B10 same chemical in both bays is not a pair", select(2, Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", PRODUCT_B = "SULFUR", WATER = "WATER" })), "INGREDIENT_INCOMPATIBLE")
    T.eq("B11 unreadable bay is unavailable, not empty", select(2, Roles.matchIngredients(pair, { PRODUCT_A = 42, PRODUCT_B = "SULFUR", WATER = "WATER" })), "SOURCE_UNAVAILABLE")
    T.eq("B12 missing water is shortage", select(2, Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", PRODUCT_B = "COPPER_HYDROXIDE" })), "INGREDIENT_SHORTAGE")
    T.eq("B13 non-water in water bay is incompatible", select(2, Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", PRODUCT_B = "COPPER_HYDROXIDE", WATER = "UREA" })), "INGREDIENT_INCOMPATIBLE")

    local single = { ingredients = { { ingredientId = "SULFUR", kind = "PRODUCT" }, { ingredientId = "WATER", kind = "DILUENT" } } }
    local ok3, r3, b3 = Roles.matchIngredients(single, { PRODUCT_A = "SULFUR", PRODUCT_B = "SULFUR", WATER = "WATER" })
    T.eq("B14 single product across both bays matches", ok3, true)
    T.eq("B15 single product held in both bays binds the ordered draw list, A first then B", type(b3.SULFUR) .. "/" .. b3.SULFUR[1] .. "/" .. b3.SULFUR[2] .. "/" .. #b3.SULFUR, "table/PRODUCT_A/PRODUCT_B/2")
    T.eq("B15b drawOrder exposes the same order", table.concat(Roles.drawOrder(b3, "SULFUR"), ","), "PRODUCT_A,PRODUCT_B")
    T.eq("B15c the dual-bay binding revalidates each role", (Roles.revalidateBindings(b3, { PRODUCT_A = "SULFUR", PRODUCT_B = "SULFUR", WATER = "WATER" })), true)
    -- CORRECTED after Bob's re-check of #5. An ordered draw list is satisfied by ANY
    -- ONE of its roles, not by all of them. Requiring all of them defeated the exact
    -- case this binding exists for: with one product in both bays, draining A made the
    -- nil bay read as a shortage and the draw stopped before it ever reached B.
    T.eq("B15d draining the SECOND bay leaves the list satisfied by the first", (Roles.revalidateBindings(b3, { PRODUCT_A = "SULFUR", WATER = "WATER" })), true)
    T.eq("B15d2 DRAINING THE LEADING BAY IS PROGRESS, NOT A SHORTAGE: the draw continues on B", (Roles.revalidateBindings(b3, { PRODUCT_B = "SULFUR", WATER = "WATER" })), true)
    T.eq("B15d3 only when EVERY role of the list is drained is it a shortage", select(2, Roles.revalidateBindings(b3, { WATER = "WATER" })), "INGREDIENT_SHORTAGE")
    T.eq("B15e swapping the second bay makes it incompatible", select(2, Roles.revalidateBindings(b3, { PRODUCT_A = "SULFUR", PRODUCT_B = "UREA", WATER = "WATER" })), "INGREDIENT_INCOMPATIBLE")
    T.eq("B15e2 a role holding something else refuses even while another still holds", select(2, Roles.revalidateBindings(b3, { PRODUCT_A = "UREA", PRODUCT_B = "SULFUR", WATER = "WATER" })), "INGREDIENT_INCOMPATIBLE")
    T.eq("B15e3 an unreadable bay refuses even while another still holds", select(2, Roles.revalidateBindings(b3, { PRODUCT_A = {}, PRODUCT_B = "SULFUR", WATER = "WATER" })), "SOURCE_UNAVAILABLE")
    T.eq("B15e4 a single-role binding is unchanged: its one drained bay is still a shortage", select(2, Roles.revalidateBindings({ SULFUR = "PRODUCT_A" }, { WATER = "WATER" })), "INGREDIENT_SHORTAGE")
    local ok3b, r3b, b3b = Roles.matchIngredients(single, { PRODUCT_A = "SULFUR", PRODUCT_B = "COPPER_HYDROXIDE", WATER = "WATER" })
    T.eq("B15f a single product with another chemical in B binds A only", tostring(ok3b) .. "/" .. tostring(b3b.SULFUR) .. "/" .. table.concat(Roles.drawOrder(b3b, "SULFUR"), ","), "true/PRODUCT_A/PRODUCT_A")
    local ok4, r4, b4 = Roles.matchIngredients(single, { PRODUCT_B = "SULFUR", WATER = "WATER" })
    T.eq("B16 single product in B alone matches", ok4, true)
    T.eq("B17 single product in B binds B", b4.SULFUR .. "/" .. table.concat(Roles.drawOrder(b4, "SULFUR"), ","), "PRODUCT_B/PRODUCT_B")
    T.eq("B18 one chemical does not become two partners", select(2, Roles.matchIngredients(pair, { PRODUCT_A = "SULFUR", WATER = "WATER" })), "INGREDIENT_SHORTAGE")

    T.eq("B19 empty definition invalid", select(2, Roles.matchIngredients({ ingredients = {} }, {})), "INVALID_DEFINITION")
    T.eq("B20 three products invalid", select(2, Roles.matchIngredients({ ingredients = { { ingredientId = "X" }, { ingredientId = "Y" }, { ingredientId = "Z" } } }, {})), "INVALID_DEFINITION")
    T.eq("B21 duplicate ingredient invalid", select(2, Roles.matchIngredients({ ingredients = { { ingredientId = "X" }, { ingredientId = "X" } } }, {})), "INVALID_DEFINITION")

    T.eq("B22 revalidate holds while bays unchanged", (Roles.revalidateBindings(b1, { PRODUCT_A = "COPPER_HYDROXIDE", PRODUCT_B = "SULFUR", WATER = "WATER" })), true)
    T.eq("B23 swapped chemical cannot rewrite the frozen binding", select(2, Roles.revalidateBindings(b1, { PRODUCT_A = "SULFUR", PRODUCT_B = "COPPER_HYDROXIDE", WATER = "WATER" })), "INGREDIENT_INCOMPATIBLE")
    T.eq("B24 emptied bay on revalidate is shortage", select(2, Roles.revalidateBindings(b1, { PRODUCT_A = "COPPER_HYDROXIDE", WATER = "WATER" })), "INGREDIENT_SHORTAGE")
    T.eq("B25 unreadable bay on revalidate is unavailable", select(2, Roles.revalidateBindings(b1, { PRODUCT_A = "COPPER_HYDROXIDE", PRODUCT_B = {}, WATER = "WATER" })), "SOURCE_UNAVAILABLE")
end

-- (C) Address validation and anchor.
do
    T.eq("C1 plain address valid", (Address.validate("farm:1/station/7")), true)
    T.eq("C2 nil refused", select(2, Address.validate(nil)), "ADDRESS_NOT_STRING")
    T.eq("C3 empty refused", select(2, Address.validate("")), "ADDRESS_EMPTY")
    T.eq("C4 exactly 4096 bytes valid", (Address.validate(string.rep("a", 4096))), true)
    T.eq("C5 4097 bytes refused, not truncated", select(2, Address.validate(string.rep("a", 4097))), "ADDRESS_OVERSIZED")
    T.eq("C6 multibyte UTF-8 valid", (Address.validate("st\195\164tion")), true)
    T.eq("C7 truncated multibyte refused", select(2, Address.validate("st\195")), "ADDRESS_INVALID_UTF8")
    T.eq("C8 overlong encoding refused", select(2, Address.validate("\192\128")), "ADDRESS_INVALID_UTF8")
    T.eq("C9 surrogate refused", select(2, Address.validate("\237\160\128")), "ADDRESS_INVALID_UTF8")
    T.eq("C10 byte bound counts bytes not characters", select(2, Address.validate(string.rep("\195\164", 2049))), "ADDRESS_OVERSIZED")

    local st = Address.new()
    T.eq("C11 fresh anchor absent", Address.get(st), nil)
    T.eq("C12 READY on PRODUCT_A cannot install", Address.onCarrierBindingChanged(st, { role = "PRODUCT_A", state = "READY", carrierId = "x" }), false)
    T.eq("C13 still absent", Address.get(st), nil)
    T.eq("C14 READY on RF_WIP installs", Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "wip-1" }), true)
    T.eq("C15 anchor is the carrier id", Address.get(st), "wip-1")
    T.eq("C16 same value again is not a change", Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "wip-1" }), false)
    T.eq("C17 WITHDRAWN on WATER cannot clear", Address.onCarrierBindingChanged(st, { role = "WATER", state = "WITHDRAWN" }), false)
    T.eq("C18 anchor survives other-role withdrawal", Address.get(st), "wip-1")
    T.eq("C19 READY on RF_WIP with invalid id clears", Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "" }), true)
    T.eq("C20 cleared", Address.get(st), nil)
    Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "wip-2" })
    T.eq("C21 WITHDRAWN on RF_WIP clears", Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "WITHDRAWN", carrierId = "wip-2" }), true)
    T.eq("C22 cleared after withdrawal", Address.get(st), nil)
    Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "wip-3" })
    T.eq("C23 non-table notification ignored", Address.onCarrierBindingChanged(st, "junk"), false)
    local throwing = setmetatable({ role = "RF_WIP", state = "READY" }, { __index = function() error("boom") end })
    T.eq("C24 throwing candidate read is staged and clears, no error", Address.onCarrierBindingChanged(st, throwing), true)
    T.eq("C25 cleared after failed mapping", Address.get(st), nil)
    Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "wip-4" })
    T.eq("C26 set to same value not a change", Address.set(st, "wip-4"), false)
    T.eq("C27 set to nil is a change (revocation)", Address.set(st, nil), true)
    T.eq("C28 set invalid value clears rather than stores", Address.set(st, string.rep("b", 5000)), false)
    T.eq("C29 still absent after invalid set", Address.get(st), nil)
    Address.set(st, "wip-5")
    Address.invalidate(st)
    T.eq("C30 invalidated getter answers nil", Address.get(st), nil)
    T.eq("C31 invalidated state refuses new binding", Address.onCarrierBindingChanged(st, { role = "RF_WIP", state = "READY", carrierId = "wip-6" }), false)
end

-- (D) Address stream codec.
do
    local st = Address.new()
    Address.set(st, "yard/3")
    local s = NewStream()
    Address.writeStream(st, s)
    T.eq("D1 full stream present: two cells", s.w, 2)
    T.eq("D2 first cell is presence true", s.cells[1], true)
    T.eq("D3 second cell is the exact string", s.cells[2], "yard/3")
    T.eq("D4 full stream reads back", Address.readStream(s), "yard/3")

    local absent = Address.new()
    local s2 = NewStream()
    Address.writeStream(absent, s2)
    T.eq("D5 absent writes only presence false", s2.w, 1)
    T.eq("D6 absent reads as nil", Address.readStream(s2), nil)

    local s3 = NewStream()
    streamWriteBool(s3, true)
    streamWriteString(s3, string.rep("z", 4097))
    T.eq("D7 oversized received address stages nil", Address.readStream(s3), nil)
    local s4 = NewStream()
    streamWriteBool(s4, true)
    streamWriteString(s4, "")
    T.eq("D8 present flag with empty string stages nil", Address.readStream(s4), nil)

    local s5 = NewStream()
    Address.writeUpdateStream(st, s5, false)
    T.eq("D9 unchanged update writes one false cell", s5.w, 1)
    local ch, val = Address.readUpdateStream(s5)
    T.eq("D10 unchanged update reads changed=false", ch, false)
    T.eq("D11 unchanged update carries no value", val, nil)

    local s6 = NewStream()
    Address.writeUpdateStream(st, s6, true)
    T.eq("D12 changed update writes changed, presence, string", s6.w, 3)
    ch, val = Address.readUpdateStream(s6)
    T.eq("D13 changed update reads changed=true", ch, true)
    T.eq("D14 changed update carries the value", val, "yard/3")

    Address.set(st, nil)
    local s7 = NewStream()
    Address.writeUpdateStream(st, s7, true)
    ch, val = Address.readUpdateStream(s7)
    T.eq("D15 revocation update: changed with absent value", ch, true)
    T.eq("D16 revocation clears the client value", val, nil)

    local client = Address.new()
    Address.applyReceived(client, "yard/3")
    T.eq("D17 client applies received", Address.get(client), "yard/3")
    T.eq("D18 client apply of absence clears", Address.applyReceived(client, nil), true)
    T.eq("D19 client cleared", Address.get(client), nil)
end

-- (E) WIP route flags and AI exclusion.
do
    -- Native LoadTrigger:load shape: automaticFilling from Platform, timer 0, autoStart from XML.
    local trigger = { automaticFilling = true, requiresActiveVehicle = false, automaticFillingTimer = 250, autoStart = true }
    T.eq("E1 flags apply", (WipRoute.applyTriggerFlags(trigger)), true)
    T.eq("E2 automaticFilling false", trigger.automaticFilling, false)
    T.eq("E3 requiresActiveVehicle true", trigger.requiresActiveVehicle, true)
    T.eq("E4 timer reset", trigger.automaticFillingTimer, 0)
    T.eq("E5 autoStart false", trigger.autoStart, false)
    T.eq("E5b supportsAILoading cleared so a station rebuild cannot re-advertise", trigger.supportsAILoading, false)
    T.eq("E6 verify passes after apply", (WipRoute.verifyTriggerFlags(trigger)), true)
    trigger.automaticFilling = true
    T.eq("E7 verify catches a recreated trigger", select(2, WipRoute.verifyTriggerFlags(trigger)), "TRIGGER_FLAGS_WRONG")
    trigger.automaticFilling = false
    trigger.supportsAILoading = true
    T.eq("E7b verify catches a re-advertised AI approach", select(2, WipRoute.verifyTriggerFlags(trigger)), "TRIGGER_FLAGS_WRONG")
    T.eq("E8 missing trigger refused", select(2, WipRoute.applyTriggerFlags(nil)), "TRIGGER_MISSING")

    local station = { aiSupportedFillTypes = { [FT_RF] = true } }
    function station:getAISupportedFillTypes() return self.aiSupportedFillTypes end
    function station:getIsFillTypeAISupported(ft) return self.aiSupportedFillTypes[ft] ~= nil end
    T.eq("E9 AI advertised before clear", select(2, WipRoute.verifyNoAiSupport(station)), "AI_ADVERTISED")
    T.eq("E10 clear AI support", (WipRoute.clearAiSupport(station)), true)
    T.eq("E11 getAISupportedFillTypes empty", next(station:getAISupportedFillTypes()), nil)
    T.eq("E12 getIsFillTypeAISupported false", station:getIsFillTypeAISupported(FT_RF), false)
    T.eq("E13 verify passes", (WipRoute.verifyNoAiSupport(station)), true)
end

-- (F) Permit cap.
do
    T.eq("F1 min of four", (WipRoute.permitCap(5000, 800, 1000, 600)), 600)
    T.eq("F2 source is the bound", (WipRoute.permitCap(100, 800, 1000, 600)), 100)
    T.eq("F3 receiver is the bound", (WipRoute.permitCap(5000, 50, 1000, 600)), 50)
    T.eq("F4 request is the bound", (WipRoute.permitCap(5000, 800, 20, 600)), 20)
    T.eq("F5 empty source moves nothing", (WipRoute.permitCap(0, 800, 1000, 600)), 0)
    T.eq("F5b empty source reason", select(2, WipRoute.permitCap(0, 800, 1000, 600)), "NOTHING_TO_MOVE")
    T.eq("F6 zero maxCarrierLitres is no permit", select(2, WipRoute.permitCap(5000, 800, 1000, 0)), "PERMIT_INVALID")
    T.eq("F7 negative maxCarrierLitres is no permit", select(2, WipRoute.permitCap(5000, 800, 1000, -5)), "PERMIT_INVALID")
    T.eq("F8 NaN source is unavailable", select(2, WipRoute.permitCap(0 / 0, 800, 1000, 600)), "SOURCE_UNAVAILABLE")
    T.eq("F9 infinite receiver is unavailable", select(2, WipRoute.permitCap(5000, math.huge, 1000, 600)), "RECEIVER_UNAVAILABLE")
    T.eq("F10 negative request is invalid", select(2, WipRoute.permitCap(5000, 800, -1, 600)), "PERMIT_INVALID")
    T.eq("F11 nil maxCarrierLitres is no permit", select(2, WipRoute.permitCap(5000, 800, 1000, nil)), "PERMIT_INVALID")
end

-- (G) Station wrapper: permit-or-zero before the captured native method.
do
    local nativeCalls = {}
    local source = makeStorage({ FT_RF }, { [FT_RF] = 300 })
    local station = { sourceStorages = { source } }
    function station:addFillLevelToFillableObject(fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
        nativeCalls[#nativeCalls + 1] = { obj = fillableObject, unit = fillUnitIndex, ft = fillTypeIndex, delta = fillDelta }
        source.fillLevels[fillTypeIndex] = source.fillLevels[fillTypeIndex] - fillDelta
        return fillDelta
    end
    local receiver = { free = 1000 }
    function receiver:getFillUnitFreeCapacity(unit) return self.free end

    -- Injected SG-4 stub: hands out whatever permit the test sets.
    local sg4 = { permit = nil, requests = 0 }
    function sg4:prepareMaterialAddition(request) self.requests = self.requests + 1; self.lastRequest = request; return self.permit end

    T.eq("G1 install refuses without provider", select(2, WipRoute.installPermitWrapper(station, nil)), "NO_PERMIT")
    T.eq("G2 install with provider", (WipRoute.installPermitWrapper(station, sg4)), true)

    -- No permit: zero, no native call, no mutation.
    T.eq("G3 no permit returns zero", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 0)
    T.eq("G4 no permit makes no native call", #nativeCalls, 0)
    T.eq("G5 no permit leaves source untouched", source.fillLevels[FT_RF], 300)
    T.eq("G6 no permit reason", WipRoute.getLastReason(station), "NO_PERMIT")
    T.eq("G7 provider was asked with the actual request", sg4.lastRequest.requested, 100)

    -- Permit for a different receiver: mismatch, zero.
    sg4.permit = { fillableObject = {}, fillUnitIndex = 1, fillTypeIndex = FT_RF, maxCarrierLitres = 500 }
    T.eq("G8 permit for another object refused", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 0)
    T.eq("G9 mismatch reason", WipRoute.getLastReason(station), "PERMIT_MISMATCH")
    sg4.permit = { fillableObject = receiver, fillUnitIndex = 2, fillTypeIndex = FT_RF, maxCarrierLitres = 500 }
    T.eq("G10 permit for another fill unit refused", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 0)
    sg4.permit = { fillableObject = receiver, fillUnitIndex = 1, fillTypeIndex = FT_STRAY, maxCarrierLitres = 500 }
    T.eq("G11 permit for another fill type refused", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 0)
    T.eq("G12 still no native call", #nativeCalls, 0)

    -- Valid permit: capped by maxCarrierLitres, native called once with the cap.
    sg4.permit = { fillableObject = receiver, fillUnitIndex = 1, fillTypeIndex = FT_RF, maxCarrierLitres = 60 }
    T.eq("G13 permitted increment returns native result", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 60)
    T.eq("G14 native called once", #nativeCalls, 1)
    T.eq("G15 native saw the capped delta", nativeCalls[1].delta, 60)
    T.eq("G16 source debited by the cap only", source.fillLevels[FT_RF], 240)
    T.eq("G17 permitted reason", WipRoute.getLastReason(station), "PERMITTED")

    -- Receiver bound.
    receiver.free = 10
    sg4.permit = { fillableObject = receiver, fillUnitIndex = 1, fillTypeIndex = FT_RF, maxCarrierLitres = 500 }
    T.eq("G18 receiver free capacity caps", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 10)
    receiver.free = 1000

    -- Source bound.
    source.fillLevels[FT_RF] = 5
    T.eq("G19 source availability caps", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 5)
    T.eq("G20 depleted source: zero, no native call", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 0)
    T.eq("G21 native call count unchanged after depletion", #nativeCalls, 3)

    -- Unreadable source or receiver.
    source.fillLevels[FT_RF] = 0 / 0
    T.eq("G22 NaN source: zero", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil), 0)
    T.eq("G23 NaN source reason", WipRoute.getLastReason(station), "SOURCE_UNAVAILABLE")
    source.fillLevels[FT_RF] = 200
    local blind = {}
    sg4.permit = { fillableObject = blind, fillUnitIndex = 1, fillTypeIndex = FT_RF, maxCarrierLitres = 500 }
    T.eq("G24 receiver without capacity getter: zero", station:addFillLevelToFillableObject(blind, 1, FT_RF, 100, nil, nil), 0)
    T.eq("G25 receiver reason", WipRoute.getLastReason(station), "RECEIVER_UNAVAILABLE")

    -- A provider that throws inside the increment is no permit, and the trigger survives.
    local before = #nativeCalls
    sg4.prepareMaterialAddition = function() error("provider blew up") end
    T.eq("G25b a throwing permit provider returns zero with no native call", station:addFillLevelToFillableObject(receiver, 1, FT_RF, 100, nil, nil) .. "/" .. (#nativeCalls - before), "0/0")
    T.eq("G25c the reason is NO_PERMIT", WipRoute.getLastReason(station), "NO_PERMIT")
    function sg4:prepareMaterialAddition(request) self.requests = self.requests + 1; self.lastRequest = request; return self.permit end
    -- Reinstall keeps the first captured native.
    local firstNative = station._sgWipNative
    T.eq("G26 second install ok", (WipRoute.installPermitWrapper(station, sg4)), true)
    T.eq("G27 captured native unchanged", station._sgWipNative, firstNative)
end

-- (H) Sale gate: per-role inspection.
do
    local ready = { state = "READY", storage = makeStorage({ FT_A }, { [FT_A] = 0 }), fillType = FT_A }
    T.eq("H1 proved empty role", (SaleGate.inspectRole(ready)), "EMPTY")
    ready.storage.fillLevels[FT_A] = 0.5
    T.eq("H2 positive expected type occupied", (SaleGate.inspectRole(ready)), "OCCUPIED")
    ready.storage.fillLevels[FT_A] = 0
    ready.storage.fillLevels[FT_STRAY] = 3
    T.eq("H3 unexpected material identity blocks", (SaleGate.inspectRole(ready)), "OCCUPIED")
    ready.storage.fillLevels[FT_STRAY] = nil
    ready.storage.fillLevels[FT_A] = -2
    T.eq("H4 negative entry is unavailable, not empty", (SaleGate.inspectRole(ready)), "UNAVAILABLE")
    ready.storage.fillLevels[FT_A] = 0 / 0
    T.eq("H5 NaN entry is unavailable", (SaleGate.inspectRole(ready)), "UNAVAILABLE")
    ready.storage.fillLevels[FT_A] = math.huge
    T.eq("H6 infinite entry is unavailable", (SaleGate.inspectRole(ready)), "UNAVAILABLE")
    ready.storage.fillLevels[FT_A] = 5
    ready.storage.fillLevels[FT_STRAY] = -5
    T.eq("H7 positive and negative never sum to a false zero", (SaleGate.inspectRole(ready)), "UNAVAILABLE")
    ready.storage.fillLevels = { [FT_A] = 0 }
    T.eq("H8 back to empty", (SaleGate.inspectRole(ready)), "EMPTY")

    local unready = { state = "UNAVAILABLE", storage = makeStorage({ FT_A }, { [FT_A] = 0 }), fillType = FT_A }
    T.eq("H9 non-READY role with zero levels is not empty", (SaleGate.inspectRole(unready)), "UNAVAILABLE")
    T.eq("H10 non-READY detail", select(2, SaleGate.inspectRole(unready)), "ROLE_NOT_READY")
    T.eq("H11 missing slot is unavailable", (SaleGate.inspectRole(nil)), "UNAVAILABLE")
    local noStore = { state = "READY", storage = nil, fillType = FT_A }
    T.eq("H12 missing storage is unavailable", select(2, SaleGate.inspectRole(noStore)), "STORAGE_MISSING")
    local unsupported = { state = "READY", storage = makeStorage({ FT_B }, {}), fillType = FT_A }
    T.eq("H13 expected type not supported: absent slot is not hidden empty", select(2, SaleGate.inspectRole(unsupported)), "FILLTYPE_UNSUPPORTED")
    local nonTable = { state = "READY", storage = makeStorage({ FT_A }, {}), fillType = FT_A }
    nonTable.storage.getFillLevels = function() return 0 end
    T.eq("H14 non-table quantity is unavailable", select(2, SaleGate.inspectRole(nonTable)), "LEVELS_NOT_TABLE")
    local noGetter = { state = "READY", storage = { getIsFillTypeSupported = function() return true end }, fillType = FT_A }
    T.eq("H15 missing getFillLevels is unavailable", select(2, SaleGate.inspectRole(noGetter)), "LEVELS_UNREADABLE")
end

-- (I) Sale gate: whole facility and the overwritten method.
do
    local slots = readySlots()
    local allowed, code = SaleGate.evaluate(byRole(slots), {})
    T.eq("I1 all five proved empty, idle: allowed", allowed, true)
    T.eq("I2 allowed carries no code", code, nil)

    Roles.getSlot(slots, "RF_FINISHED").storage.fillLevels[FT_RF] = 1
    allowed, code = SaleGate.evaluate(byRole(slots), {})
    T.eq("I3 finished stock blocks", allowed, false)
    T.eq("I4 occupied code", code, "EMPTY_ALL_BAYS_REQUIRED")
    Roles.getSlot(slots, "RF_FINISHED").storage.fillLevels[FT_RF] = 0

    Roles.withdrawSlot(slots, "WATER", "TEARDOWN")
    allowed, code = SaleGate.evaluate(byRole(slots), {})
    T.eq("I5 withdrawn role is unavailable, not empty", code, "BAY_QUANTITY_UNAVAILABLE")
    slots = readySlots()

    local four = byRole(slots)
    four.RF_WIP = nil
    T.eq("I6 missing role entry is unavailable", select(2, SaleGate.evaluate(four, {})), "BAY_QUANTITY_UNAVAILABLE")

    T.eq("I7 live batch blocks", select(2, SaleGate.evaluate(byRole(slots), { batch = true })), "FACILITY_WORK_ACTIVE")
    T.eq("I8 reservation blocks", select(2, SaleGate.evaluate(byRole(slots), { reservation = true })), "FACILITY_WORK_ACTIVE")
    T.eq("I9 recovery blocks", select(2, SaleGate.evaluate(byRole(slots), { recovery = true })), "FACILITY_WORK_ACTIVE")
    T.eq("I10 restore blocks", select(2, SaleGate.evaluate(byRole(slots), { restore = true })), "FACILITY_WORK_ACTIVE")
    T.eq("I11 nil live table means idle", (SaleGate.evaluate(byRole(slots), nil)), true)

    -- Occupied and unavailable: unavailable is reported for the first failing role in order.
    local mixed = readySlots({ PRODUCT_A = { [FT_A] = 7 } })
    Roles.withdrawSlot(mixed, "RF_WIP", "TEARDOWN")
    T.eq("I12 first failing role in declared order decides the code", select(2, SaleGate.evaluate(byRole(mixed), {})), "EMPTY_ALL_BAYS_REQUIRED")

    -- The overwritten method.
    local superCalls = 0
    local function makeFacility(slotSet, live, text, superResult)
        local f = {}
        function f:getSaleGateSlots() return byRole(slotSet) end
        function f:getSaleGateLive() return live or {} end
        f.getSaleGateText = text
        f._super = superResult
        return f
    end
    local function superOk(self) superCalls = superCalls + 1; return true, nil end
    local function superWarn(self) superCalls = superCalls + 1; return true, "NATIVE_WARNING" end
    local function superRefuse(self) superCalls = superCalls + 1; return false, "NATIVE_REFUSAL" end
    local function superRefuseNil(self) superCalls = superCalls + 1; return false, nil end
    local function getText(key) return "L10N:" .. key end

    local emptyFacility = makeFacility(readySlots(), {}, getText)
    local a, w = SaleGate.canBeSold(emptyFacility, superOk)
    T.eq("I13 empty idle: native allow passes through", a, true)
    T.eq("I14 empty idle: native nil warning preserved", w, nil)
    T.eq("I15 superFunc called once", superCalls, 1)
    a, w = SaleGate.canBeSold(emptyFacility, superWarn)
    T.eq("I16 empty idle: native warning preserved", w, "NATIVE_WARNING")
    T.eq("I17 empty idle with native warning still allowed", a, true)

    local occupiedFacility = makeFacility(readySlots({ WATER = { [FT_WATER] = 100 } }), {}, getText)
    superCalls = 0
    a, w = SaleGate.canBeSold(occupiedFacility, superOk)
    T.eq("I18 occupied: false", a, false)
    T.eq("I19 occupied: localized empty-all-bays reason", w, "L10N:stockGuard_chemicalStation_emptyAllBays")
    T.eq("I20 occupied: superFunc still called exactly once", superCalls, 1)

    a, w = SaleGate.canBeSold(occupiedFacility, superRefuse)
    T.eq("I21 native refusal controls", a, false)
    T.eq("I22 native refusal reason preserved", w, "NATIVE_REFUSAL")

    a, w = SaleGate.canBeSold(emptyFacility, superRefuseNil)
    T.eq("I23 native (false, nil) never propagates as (false, nil)", a, false)
    T.eq("I24 native (false, nil) gets the localized reason", w, "L10N:stockGuard_chemicalStation_emptyAllBays")

    local noTextFacility = makeFacility(readySlots({ PRODUCT_B = { [FT_B] = 1 } }), {}, nil)
    a, w = SaleGate.canBeSold(noTextFacility, superOk)
    T.eq("I25 no i18n: warning is the key, never nil", w, "stockGuard_chemicalStation_emptyAllBays")
    local badText = makeFacility(readySlots({ PRODUCT_B = { [FT_B] = 1 } }), {}, function() error("no i18n") end)
    a, w = SaleGate.canBeSold(badText, superOk)
    T.eq("I26 throwing i18n: warning falls back to the key", w, "stockGuard_chemicalStation_emptyAllBays")
    local emptyText = makeFacility(readySlots({ PRODUCT_B = { [FT_B] = 1 } }), {}, function() return "" end)
    a, w = SaleGate.canBeSold(emptyText, superOk)
    T.eq("I27 empty i18n string: warning falls back to the key", w, "stockGuard_chemicalStation_emptyAllBays")

    local liveFacility = makeFacility(readySlots(), { recovery = true }, getText)
    a, w = SaleGate.canBeSold(liveFacility, superOk)
    T.eq("I28 live recovery on empty station: false with reason", a == false and w ~= nil, true)

    -- Server recheck: each call is its own evaluation of current state.
    local station = readySlots({ PRODUCT_A = { [FT_A] = 9 } })
    local serverFacility = makeFacility(station, {}, getText)
    T.eq("I29 server recheck refuses occupied", (SaleGate.canBeSold(serverFacility, superOk)), false)
    Roles.getSlot(station, "PRODUCT_A").storage.fillLevels[FT_A] = 0
    T.eq("I30 server recheck accepts once emptied", (SaleGate.canBeSold(serverFacility, superOk)), true)
end

-- (J) Registration proof through the native helper shape.
do
    -- Mirror SpecializationUtil.registerOverwrittenFunction + Utils.overwrittenFunction:
    -- silent on a nil slot, composite closure otherwise.
    local function registerOverwritten(objectType, funcName, func)
        if objectType.functions[funcName] ~= nil then
            local old = objectType.functions[funcName]
            objectType.functions[funcName] = function(self, ...) return func(self, old, ...) end
        end
    end
    local baseCanBeSold = function(self) return true, nil end
    local typeWithSlot = { functions = { canBeSold = baseCanBeSold } }
    local ok, why = SaleGate.attach(typeWithSlot, registerOverwritten)
    T.eq("J1 inherited Placeable canBeSold slot accepts facility wrapper", ok, true)
    T.eq("J2 attach reports WRAPPED", why, "WRAPPED")
    T.eq("J3 slot replaced by the composite", typeWithSlot.functions.canBeSold ~= baseCanBeSold, true)
    T.eq("J4 composite is not pointer-equal to our function (and that is fine)", typeWithSlot.functions.canBeSold ~= SaleGate.canBeSold, true)

    -- The installed composite behaves as the gate.
    local facility = { }
    function facility:getSaleGateSlots() return byRole(readySlots({ RF_WIP = { [FT_RF] = 2 } })) end
    function facility:getSaleGateLive() return {} end
    facility.getSaleGateText = function(k) return "L:" .. k end
    local a, w = typeWithSlot.functions.canBeSold(facility)
    T.eq("J5 installed occupied path refuses", a, false)
    T.eq("J6 installed occupied path reason", w, "L:stockGuard_chemicalStation_emptyAllBays")
    function facility:getSaleGateSlots() return byRole(readySlots()) end
    a, w = typeWithSlot.functions.canBeSold(facility)
    T.eq("J7 installed empty path allows", a, true)
    T.eq("J8 installed empty path native warning nil", w, nil)

    local typeNoSlot = { functions = {} }
    ok, why = SaleGate.attach(typeNoSlot, registerOverwritten)
    T.eq("J9 missing base canBeSold slot fails facility readiness", ok, false)
    T.eq("J10 missing slot reason", why, "CAN_BE_SOLD_SLOT_MISSING")
    T.eq("J11 missing slot: nothing installed, no silent native allow", typeNoSlot.functions.canBeSold, nil)

    local typeSilent = { functions = { canBeSold = baseCanBeSold } }
    ok, why = SaleGate.attach(typeSilent, function() end)
    T.eq("J12 a helper that does not replace the slot is a failure", why, "CAN_BE_SOLD_NOT_REPLACED")
    T.eq("J13 invalid placeable type refused", select(2, SaleGate.attach(nil, registerOverwritten)), "PLACEABLE_TYPE_INVALID")
    T.eq("J14 no helper available is a failure, not native allow", select(2, SaleGate.attach({ functions = { canBeSold = baseCanBeSold } }, nil)), "CAN_BE_SOLD_NOT_REPLACED")
end
