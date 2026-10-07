-- MAINT-238-view_row_knowledge_spec_test.lua
--
-- MAINTENANCE row 238 (Desk's dispatch on Bob's SG-3 2.1 R-15, 2026-10-07; SG-1 :255, :295; SG-3 :47,
-- :505, :507): the player view's STOCK row derives its knowledge from the children the row shows, so a
-- property whose disclosure is DISCLOSURE_DENIED leaves no trace in it, and carries over the inventory's
-- own state (an unexplained delta's PARTIAL, an unresolved settlement's UNAVAILABLE). SG-1's own
-- stock.knowledge is unchanged for trusted reads. Bob's R-15: reconcile now marks every amount change it
-- applies UNEXPLAINED_DELTA (unless an unresolved settlement holds the stock), so the row reads a drift
-- from the stock's reason and never from its records, which a hidden one would move.
--
-- WHY. SG-1 derives stock.knowledge from every record on the stock (SGOperations.knowledgeOf), and the
-- row copied it. With SG-3 Part 2.1's locked qualityBasisV1 on every born stock, a trailer whose own
-- property is KNOWN read PARTIAL in the player view because of a record that view never shows.
--
-- THE ENTRY-POINT BAR IS GROUP S: the harvest world booted through main.lua (as SG2-3b's), a real cut
-- through the engine's own frame order, the settle asking two STORED birth producers (one disclosed,
-- one DISCLOSURE_DENIED, as SG-3's), and the player view read through the mission handle's
-- getManagementView. Nothing sets a record or a knowledge by hand.
--
-- Groups:
--   S  the entry-point bar: a hidden record leaves the row KNOWN; with nothing hidden, row and stock agree;
--      a real fall through the FillUnit observer reads PARTIAL either way
--   D  through SG-1's operations API: an unexplained delta beside a hidden record still reads PARTIAL; a
--      clean birth beside it reads KNOWN; a native fall or rise is marked UNEXPLAINED_DELTA and reads
--      PARTIAL, on a stock a hidden record already made PARTIAL too
--   U  an unresolved settlement reads UNAVAILABLE whether or not a hidden record is there, and keeps its
--      reason through a later fall; a stock whose
--      only record is hidden reads as a stock with none, with or without an unexplained delta
--   T  trusted reads unchanged: readMaterial carries SG-1's own knowledge and every record
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local NH, NA = SGNativeHost, SGNativeAdapters
local WHEAT_FRUIT = ENGINE_FRUIT.WHEAT

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── two stand-in STORED producers that declare births ──────────────────────────
-- SHOWN records every birth KNOWN and discloses it. HIDDEN records every birth as an unavailable origin
-- and denies every player view, as SG-3 Part 2.1's locked qualityBasisV1 does.
local SHOWN, HIDDEN = "bench.shown", "bench.hidden"
local function shownRecord(amount, unit)
    return { propertyId = SHOWN, schemaVersion = 1, producerId = "benchShown", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount,
             amountUnit = unit or "LITRE", payload = { v = 1 } }
end
local shownSpec = { schemaVersion = 1, producerId = "benchShown", residency = "STORED", birth = true,
    validate = function() return true end,
    combine = function(ctx, contributions, before)
        local total = 0
        for _, c in ipairs(contributions) do total = total + (c.amount or 0) end
        if before ~= nil then total = total + (before.observedAmount or 0) end
        if total <= 0 then return nil, "NO_MATERIAL" end
        return shownRecord(total)
    end,
    transform = function(ctx, inputs, outputs) local o = outputs[1] return shownRecord(o.amount, o.unit) end,
    disclosure = function(_, r) return r end }
local hiddenSpec = { schemaVersion = 1, producerId = "benchHidden", residency = "STORED", birth = true,
    validate = function() return true end,
    combine = function() return nil, "HIDDEN_ORIGIN" end,
    transform = function() return nil, "HIDDEN_ORIGIN" end,
    disclosure = function() return nil, "DISCLOSURE_DENIED" end }

local ACTOR = { farmId = 1, userId = "host", actorState = "RESOLVED", connectionId = "local" }

--- The player view's STOCK row for a carrier: "knowledge|child,child".
local function viewRow(page, carrierId)
    for _, row in ipairs(page and page.view and page.view.rows or {}) do
        if row.rowKind == "STOCK" and row.carrierId == carrierId then
            local kids = {}
            for _, p in ipairs(row.properties or {}) do kids[#kids + 1] = p.propertyId end
            return tostring(row.knowledge) .. "|" .. table.concat(kids, ",")
        end
    end
    return "no row"
end

-- ── the harvest world (as SG2-3b's) ──────────────────────────────────────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) return 1 end
function Mission:getHarvestScaleMultiplier() return 1 end
function Mission:getFruitPixelsToSqm() return 1 end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission()
    local m = setmetatable({ _server = true, playerUserId = "host", missionInfo = {}, missionDynamicInfo = { isMultiplayer = false }, time = 1000, terrainSize = 256, fieldGroundSystem = ENGINE_FIELD_GROUND,
        userManager = { getUserByConnection = function() return nil end }, _placeables = {}, _vehicles = {} }, Mission)
    m.accessHandler = { canFarmAccess = function(_, farmId, object) return object ~= nil and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function(_, id) for _, v in ipairs(m._vehicles) do if v.uniqueId == id then return v end end return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

local function boot(withHidden)
    ENGINE_PLANE.cells = {}
    ENGINE_PLANE.bias = 0
    local m = newMission()
    g_server = {}
    g_currentMission = m
    local combine = ENGINE_NEW_COMBINE("vehicle:combine")
    local header = ENGINE_NEW_HEADER("vehicle:header", combine, { areas = 1, width = 4, depth = 1 })
    m._vehicles[1], m._vehicles[2] = combine, header
    ENGINE_PLANE.sow(WHEAT_FRUIT, 0, 0, 4, 1, 4)
    Mission00.load(m)
    Mission00.loadMission00Finished(m)
    m:onFinishedLoading()
    m.stockGuard.registerProperty(SHOWN, shownSpec)
    if withHidden then m.stockGuard.registerProperty(HIDDEN, hiddenSpec) end
    return m, NH.current, combine, header
end

local function hopperId(combine) return SGRecords.carrierKeyString(NA.fillUnitBinding(combine, 1).carrierKey) end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: A REAL CUT, THE PLAYER VIEW THROUGH THE HANDLE
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local m, host, combine, header = boot(true)
    ENGINE_HARVEST_TICK(header, combine, 16)
    local sg = StockGuard.hostOf(m)
    local id = hopperId(combine)
    local stock = sg.operations.stocks[sg.operations.carriers[id].stockId]
    local recs = {}
    for pid, p in pairs(stock.properties) do recs[#recs + 1] = pid .. ":" .. tostring(p.knowledge) end
    table.sort(recs)
    T.eq("S1 [world] the cut was born with both records: the shown one KNOWN, the hidden one an unavailable origin",
        table.concat(recs, ","), "bench.hidden:UNAVAILABLE,bench.shown:KNOWN")
    T.eq("S2 SG-1's own stock.knowledge, for trusted reads, is PARTIAL: its records disagree (unchanged)", tostring(stock.knowledge), "PARTIAL")
    local page = m.stockGuard.getManagementView(ACTOR, { route = "STOCK", selectionKind = "FARM" })
    T.eq("S3 [entry point] the player view's row reads KNOWN and shows the one property it discloses: the hidden one leaves no trace (SG-3 :47, :507)",
        viewRow(page, id), "KNOWN|bench.shown")
    -- A real fall outside any operation: the engine takes 1 L from the hopper, the installed FillUnit
    -- observer sees it with no frame open and marks the carrier dirty, and the host's update past its flush interval (main.lua's
    -- FSBaseMission.update append; SGNativeHost.flush, refreshCarrier) reconciles the stock.
    local taken = combine:addFillUnitFillLevel(1, 1, -1, ENGINE_FT.WHEAT, ToolType.UNDEFINED)
    FSBaseMission.update(m, SGNativeHost.FLUSH_INTERVAL_MS + 100)
    page = m.stockGuard.getManagementView(ACTOR, { route = "STOCK", selectionKind = "FARM" })
    T.eq("S5 [entry point] a native fall the host reconciles marks the stock UNEXPLAINED_DELTA, and the row reads PARTIAL, hidden record or not (Bob's R-15)",
        tostring(taken) .. "/" .. tostring(stock.knowledge) .. "/" .. tostring(stock.reason) .. "/" .. viewRow(page, id), "-1/PARTIAL/UNEXPLAINED_DELTA/PARTIAL|bench.shown")
    FSBaseMission.delete(m)
    -- The same cut with nothing hidden: the row and the stock agree, as before this row.
    local m2, host2, combine2, header2 = boot(false)
    ENGINE_HARVEST_TICK(header2, combine2, 16)
    local sg2 = StockGuard.hostOf(m2)
    local id2 = hopperId(combine2)
    local page2 = m2.stockGuard.getManagementView(ACTOR, { route = "STOCK", selectionKind = "FARM" })
    T.eq("S4 with nothing hidden the row reads what the stock reads",
        tostring(sg2.operations.stocks[sg2.operations.carriers[id2].stockId].knowledge) .. "/" .. viewRow(page2, id2), "KNOWN/KNOWN|bench.shown")
    combine2:addFillUnitFillLevel(1, 1, -1, ENGINE_FT.WHEAT, ToolType.UNDEFINED)
    FSBaseMission.update(m2, SGNativeHost.FLUSH_INTERVAL_MS + 100)
    page2 = m2.stockGuard.getManagementView(ACTOR, { route = "STOCK", selectionKind = "FARM" })
    T.eq("S6 the same fall with nothing hidden reads the same PARTIAL", viewRow(page2, id2), "PARTIAL|bench.shown")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D, U, T. SG-1's OPERATIONS API (as MAINT-197's bench drives it) AND THE VIEW
-- ══════════════════════════════════════════════════════════════════════════
local function world(tag)
    local reg = SGRegistry.new(tag)
    local o = SGOperations.new(reg, tag)
    local vw = SGViews.new(reg, o, SGSiteBinding.new())
    vw.ready = true
    local ad = reg:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end, readNativeState = function() end,
        enumerateCarriers = function() return {} end, hasAccess = function(_, actor) return actor.farmId == 1 end })
    local shown = reg:registerProperty(SHOWN, shownSpec)
    local hidden = reg:registerProperty(HIDDEN, hiddenSpec)
    local w = { reg = reg, o = o, vw = vw, ad = ad, shown = shown, hidden = hidden }
    function w.bind(owner, amount, material)
        return o:bindCarrier(ad, { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = "1" }, adapterVersion = 1, profileId = "silo", profileVersion = 1,
            quantityBasisKey = owner .. "/1" }, { materialRef = material, amount = amount, unit = "l", label = owner, ownerFarmId = 1 })
    end
    function w.stock(c) local sid = o.carriers[c.carrierId].stockId return sid and o.stocks[sid] or nil end
    function w.publish(lease, c, record)
        return o:publishProperties(lease, { { stockRef = o:stockRef(w.stock(c)), expectedPropertyRevision = 0, record = record } })
    end
    function w.transfer(src, dst, srcAfter, dstAfter, n)
        local parts = { { carrierId = src.carrierId, expectedStockRef = o:stockRef(w.stock(src)) } }
        local d = w.stock(dst)
        parts[2] = d and { carrierId = dst.carrierId, expectedStockRef = o:stockRef(d) } or { carrierId = dst.carrierId }
        local cap = o:captureOperation(ad, "TRANSFER", parts)
        return o:settleOperation(cap.handle, { participantsAfter = { [src.carrierId] = srcAfter, [dst.carrierId] = dstAfter },
            allocations = { { source = { carrierId = src.carrierId }, destination = { carrierId = dst.carrierId }, sourceAmount = n, sourceUnit = "l", destinationAmount = n, destinationUnit = "l" } } })
    end
    function w.row(c) return viewRow(vw:getManagementView({ farmId = 1, userId = "u1", actorState = "RESOLVED", connectionId = "c1" }, { route = "STOCK", selectionKind = "FARM" }), c.carrierId) end
    function w.inner(c) local s = w.stock(c) return s and (tostring(s.knowledge) .. "/" .. tostring(s.reason)) or "none" end
    return w
end
local WHEAT = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
local function hiddenKnown(amount)
    return { propertyId = HIDDEN, schemaVersion = 1, producerId = "benchHidden", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { h = 1 } }
end

group("D", function()
    local w = world("d")
    -- A source carrying both records; whatever it moves carries the shown record and an unavailable hidden one.
    local silo = w.bind("silo", 100, WHEAT)
    w.publish(w.shown, silo, shownRecord(100))
    w.publish(w.hidden, silo, hiddenKnown(100))
    local t1 = w.bind("trailer1", 0, nil)
    local out = w.transfer(silo, t1, { materialRef = WHEAT, amount = 60, unit = "l" }, { materialRef = WHEAT, amount = 60, unit = "l" }, 40)
    T.eq("D1 a stock BORN with 20 of its 60 L unexplained, beside a hidden record: SG-1 keeps PARTIAL with the reason, and the player row reads PARTIAL too, never KNOWN",
        tostring(out) .. "|" .. w.inner(t1) .. "|" .. w.row(t1), "COMMITTED|PARTIAL/UNEXPLAINED_DELTA|PARTIAL|bench.shown")
    local t2 = w.bind("trailer2", 0, nil)
    out = w.transfer(silo, t2, { materialRef = WHEAT, amount = 30, unit = "l" }, { materialRef = WHEAT, amount = 30, unit = "l" }, 30)
    T.eq("D2 a clean BIRTH beside a hidden record: SG-1 keeps PARTIAL (its records disagree), the player row reads KNOWN",
        tostring(out) .. "|" .. w.inner(t2) .. "|" .. w.row(t2), "COMMITTED|PARTIAL/nil|KNOWN|bench.shown")
    -- Reconcile's drift. On a fall the record keeps KNOWN with its coverage scaled (SGOperations
    -- scaleCoverage) while the stock is demoted and marked UNEXPLAINED_DELTA.
    local bin = w.bind("bin", 50, WHEAT)
    w.publish(w.shown, bin, shownRecord(50))
    w.o:reconcileCarrier(bin.carrierId, { materialRef = WHEAT, amount = 45, unit = "l" }, "DRIFT")
    local rec = w.stock(bin).properties[SHOWN]
    T.eq("D3 a native fall on a bound stock (reason INITIAL_OBSERVATION) demotes it and marks it UNEXPLAINED_DELTA while its record stays KNOWN; the row reads PARTIAL",
        w.inner(bin) .. "/" .. tostring(rec.knowledge) .. "|" .. w.row(bin), "PARTIAL/UNEXPLAINED_DELTA/KNOWN|PARTIAL|bench.shown")
    -- On a rise the record itself turns PARTIAL as well.
    local bin2 = w.bind("bin2", 50, WHEAT)
    w.publish(w.shown, bin2, shownRecord(50))
    w.o:reconcileCarrier(bin2.carrierId, { materialRef = WHEAT, amount = 55, unit = "l" }, "DRIFT")
    T.eq("D4 a native rise marks it too, and its record turns PARTIAL",
        w.inner(bin2) .. "/" .. tostring(w.stock(bin2).properties[SHOWN].knowledge) .. "|" .. w.row(bin2), "PARTIAL/UNEXPLAINED_DELTA/PARTIAL|PARTIAL|bench.shown")
    -- Bob's R-15 case: a stock already PARTIAL inside because of a hidden record (t2: shown KNOWN, hidden
    -- unavailable). Before the reason, a fall left no mark and the row kept reading KNOWN.
    w.o:reconcileCarrier(t2.carrierId, { materialRef = WHEAT, amount = 25, unit = "l" }, "DRIFT")
    T.eq("D5 a fall on a stock a hidden record already made PARTIAL is marked, and the row reads PARTIAL like the bound stock's",
        w.inner(t2) .. "|" .. w.row(t2), "PARTIAL/UNEXPLAINED_DELTA|PARTIAL|bench.shown")
end)

group("U", function()
    local w = world("u")
    -- An unresolved settlement: the captured stocks are qualified UNAVAILABLE with the operation's reason.
    local onlyHidden = w.bind("hiddenOnly", 40, WHEAT)
    w.publish(w.hidden, onlyHidden, hiddenKnown(40))
    local bare = w.bind("bare", 40, WHEAT)
    local cap = w.o:captureOperation(w.ad, "TRANSFER", { { carrierId = onlyHidden.carrierId, expectedStockRef = w.o:stockRef(w.stock(onlyHidden)) },
        { carrierId = bare.carrierId, expectedStockRef = w.o:stockRef(w.stock(bare)) } })
    w.o:abandonOperation(cap.handle, "BENCH", nil)
    T.eq("U1 an abandoned operation: a stock holding only a hidden record and a stock holding none both read UNAVAILABLE to the player, alike",
        w.inner(onlyHidden) .. "|" .. w.row(onlyHidden) .. " / " .. w.inner(bare) .. "|" .. w.row(bare),
        "UNAVAILABLE/ABANDONED:BENCH|UNAVAILABLE| / UNAVAILABLE/ABANDONED:BENCH|UNAVAILABLE|")
    w.o:reconcileCarrier(onlyHidden.carrierId, { materialRef = WHEAT, amount = 35, unit = "l" }, "DRIFT")
    w.o:reconcileCarrier(bare.carrierId, { materialRef = WHEAT, amount = 35, unit = "l" }, "DRIFT")
    T.eq("U1b a fall afterwards keeps the settlement's reason: both still read UNAVAILABLE",
        w.inner(onlyHidden) .. "|" .. w.row(onlyHidden) .. " / " .. w.inner(bare) .. "|" .. w.row(bare),
        "UNAVAILABLE/ABANDONED:BENCH|UNAVAILABLE| / UNAVAILABLE/ABANDONED:BENCH|UNAVAILABLE|")
    -- Not a settlement's state: a stock whose only record is a hidden unavailable origin reads as a stock with none.
    local src = w.bind("src", 100, WHEAT)
    w.publish(w.hidden, src, hiddenKnown(100))
    local plain = w.bind("plain", 100, WHEAT)
    local a = w.bind("a", 0, nil)
    local b = w.bind("b", 0, nil)
    w.transfer(src, a, { materialRef = WHEAT, amount = 70, unit = "l" }, { materialRef = WHEAT, amount = 30, unit = "l" }, 30)
    w.transfer(plain, b, { materialRef = WHEAT, amount = 70, unit = "l" }, { materialRef = WHEAT, amount = 30, unit = "l" }, 30)
    T.eq("U2 a stock whose one record is hidden reads to the player as a stock with no record: UNKNOWN, no child",
        w.inner(a) .. "|" .. w.row(a) .. " / " .. w.inner(b) .. "|" .. w.row(b), "UNAVAILABLE/nil|UNKNOWN| / UNKNOWN/nil|UNKNOWN|")
    -- UNAVAILABLE with a reason that is not a settlement's: the hidden record's own reason differs.
    local c = w.bind("c", 0, nil)
    local d = w.bind("d", 0, nil)
    w.transfer(src, c, { materialRef = WHEAT, amount = 40, unit = "l" }, { materialRef = WHEAT, amount = 50, unit = "l" }, 30)
    w.transfer(plain, d, { materialRef = WHEAT, amount = 40, unit = "l" }, { materialRef = WHEAT, amount = 50, unit = "l" }, 30)
    T.eq("U3 the same with an unexplained gain: a hidden-only stock and a bare one both read UNKNOWN (a delta never raises UNKNOWN), never UNAVAILABLE",
        w.inner(c) .. "|" .. w.row(c) .. " / " .. w.inner(d) .. "|" .. w.row(d), "UNAVAILABLE/UNEXPLAINED_DELTA|UNKNOWN| / UNKNOWN/UNEXPLAINED_DELTA|UNKNOWN|")
end)

group("T", function()
    local w = world("t")
    local silo = w.bind("silo", 100, WHEAT)
    w.publish(w.shown, silo, shownRecord(100))
    w.publish(w.hidden, silo, hiddenKnown(100))
    local t1 = w.bind("trailer", 0, nil)
    w.transfer(silo, t1, { materialRef = WHEAT, amount = 70, unit = "l" }, { materialRef = WHEAT, amount = 30, unit = "l" }, 30)
    local consumer = w.reg:registerConsumer("bench.trusted", { version = 1, requiredSchemas = { [SHOWN] = 1, [HIDDEN] = 1 }, materialKinds = { "FILL_TYPE" },
        resolveReadContext = function(q) return { stockRefs = q.stockRefs, purpose = "BENCH" } end })
    local res = w.o:readMaterial(consumer, { stockRefs = { w.o:stockRef(w.stock(t1)) } })
    local rec = res.records and res.records[1] or {}
    T.eq("T1 trusted reads are unchanged: readMaterial's snapshot carries SG-1's own PARTIAL and both records, the hidden one included",
        tostring(rec.knowledge) .. "/" .. tostring(rec.properties and rec.properties[HIDDEN] ~= nil and rec.properties[HIDDEN].knowledge) .. "/" .. w.row(t1),
        "PARTIAL/UNAVAILABLE/KNOWN|bench.shown")
    local direct = SGViews.rowKnowledge({ knowledge = "KNOWN", reason = nil, properties = {} }, {})
    T.eq("T2 a stock with no record and no inventory mark reads UNKNOWN, as SG-1's own rule gives", tostring(direct), "UNKNOWN")
end)
