-- MAINT-197-born_stock_unexplained_spec_test.lua
--
-- MAINTENANCE row 197: SG-1's settle demoted a KNOWN stock to PARTIAL on an unexplained delta only
-- when it UPDATEd. A stock BORN or REPLACED with part of its amount unexplained kept the reason
-- and stayed KNOWN, though it holds material no contribution explains. The BIRTH and REPLACE
-- install now mirrors UPDATE (src/core/SGOperations.lua): KNOWN becomes PARTIAL with reason
-- UNEXPLAINED_DELTA; a knowledge that is not KNOWN is left as it is. The SG-1 brief: ":90" known,
-- partially known and unknown are distinguishable and a summary must not imply uniform condition
-- where members differ; ":108" unexplained change is uncertain; its reference test: "unexplained
-- increase is unknown only for added amount".
--
-- THE ENTRY-POINT BAR is row Q2 of SG2-5d-b-baler_frame_spec_test.lua: main.lua's install, the live
-- Baler class's listeners and WorkArea's order, a pickup the bracket could not observe, so the
-- empty chamber is born with half its amount unexplained. This file holds the settle's own rows,
-- through SG-1's real operations API, as SG-1-core_spec_test.lua's group G drives it.
--
--!load: src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua

FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15, MAX_FARM_ID = 8, MAX_NUM_FARMS = 8 }

do
    local reg = SGRegistry.new("m197")
    local o = SGOperations.new(reg, "m197")
    local function adapterSpecFor() return { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end, readNativeState = function() end, enumerateCarriers = function() return {} end, hasAccess = function() return true end } end
    local ad = reg:registerCarrierAdapter("sg2", adapterSpecFor())
    local function b(owner, comp) return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp }, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = owner .. "/" .. comp } end
    local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
    local barley = { kind = "FILL_TYPE", fillTypeName = "BARLEY" }
    -- The owner's combine, as SG-1's core bench writes it: the record covers what the
    -- contributions (and the stock before) brought, never the unexplained rest.
    local moistureSpec = { schemaVersion = 1, producerId = "soil", residency = "STORED",
        validate = function(r) return r.payload ~= nil end,
        combine = function(ctx, contributions, before)
            local total, w = 0, 0
            for _, c in ipairs(contributions) do local p = c.properties["sf.moisture"] total = total + c.amount if p and p.payload then w = w + p.payload.m * c.amount end end
            if before then local p = before.properties["sf.moisture"] total = total + before.observedAmount if p and p.payload then w = w + p.payload.m * before.observedAmount end end
            if total == 0 then return nil, "NO_MATERIAL" end
            return { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = total, basisAmount = total, amountUnit = "LITRE", payload = { m = w / total } }
        end,
        transform = function() return nil end,
        disclosure = function(_, r) return r end }
    local moisture = reg:registerProperty("sf.moisture", moistureSpec)
    local function moist(m, amount) return { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN", knownAmount = amount, basisAmount = amount, amountUnit = "LITRE", payload = { m = m } } end
    local function stockOf(c) local id = o.carriers[c.carrierId].stockId return id and o.stocks[id] or nil end
    local function alloc(src, dst, n)
        return { source = { carrierId = src.carrierId }, destination = { carrierId = dst.carrierId }, sourceAmount = n, sourceUnit = "l", destinationAmount = n, destinationUnit = "l" }
    end
    local function filled(owner, material, amount, m)
        local c = o:bindCarrier(ad, b(owner, "1"), { materialRef = material, amount = amount, unit = "l" })
        if m ~= nil then o:publishProperties(moisture, { { stockRef = o:stockRef(stockOf(c)), expectedPropertyRevision = 0, record = moist(m, amount) } }) end
        return c
    end
    local function transfer(src, dst, srcAfter, dstAfter, n)
        local parts = { { carrierId = src.carrierId, expectedStockRef = o:stockRef(stockOf(src)) } }
        local d = stockOf(dst)
        parts[2] = d and { carrierId = dst.carrierId, expectedStockRef = o:stockRef(d) } or { carrierId = dst.carrierId }
        local cap = o:captureOperation(ad, "TRANSFER", parts)
        return o:settleOperation(cap.handle, { participantsAfter = { [src.carrierId] = srcAfter, [dst.carrierId] = dstAfter }, allocations = { alloc(src, dst, n) } })
    end
    local function state(c)
        local s = stockOf(c)
        if s == nil then return "none" end
        local p = s.properties["sf.moisture"]
        return tostring(s.knowledge) .. "/" .. tostring(s.reason) .. "/" .. tostring(s.observedAmount) .. "/" .. tostring(p and p.knownAmount)
    end

    -- U1: a BIRTH whose destination gains 20 L more than the 40 L it was credited.
    local silo = filled("silo", wheat, 100, 0.10)
    local trailer = o:bindCarrier(ad, b("trailer", "1"), { amount = 0, unit = "l" })
    local out, why = transfer(silo, trailer, { materialRef = wheat, amount = 60, unit = "l" }, { materialRef = wheat, amount = 60, unit = "l" }, 40)
    T.eq("U1 NAMED: a stock BORN with 20 of its 60 L unexplained reads PARTIAL with reason UNEXPLAINED_DELTA; its record covers the 40 L explained",
        tostring(out) .. "/" .. tostring(why) .. "|" .. state(trailer), "COMMITTED/nil|PARTIAL/UNEXPLAINED_DELTA/60/40")

    -- U2: a clean BIRTH stays KNOWN.
    local trailer2 = o:bindCarrier(ad, b("trailer", "2"), { amount = 0, unit = "l" })
    out = transfer(silo, trailer2, { materialRef = wheat, amount = 30, unit = "l" }, { materialRef = wheat, amount = 30, unit = "l" }, 30)
    T.eq("U2 a stock born with all of its amount explained stays KNOWN, with no reason", tostring(out) .. "|" .. state(trailer2), "COMMITTED|KNOWN/nil/30/30")

    -- U3: a REPLACE (the destination's material changes) with an unexplained gain.
    local bin = filled("bin", barley, 50, 0.20)
    local before = stockOf(silo)
    out = transfer(bin, silo, { amount = 0, unit = "l" }, { materialRef = barley, amount = 120, unit = "l" }, 50)
    T.eq("U3 NAMED: a stock REPLACED with part of its amount unexplained reads PARTIAL with reason UNEXPLAINED_DELTA, in a new generation",
        tostring(out) .. "/" .. tostring(stockOf(silo) ~= nil and stockOf(silo).stockId ~= before.stockId) .. "|" .. state(silo), "COMMITTED/true|PARTIAL/UNEXPLAINED_DELTA/120/50")

    -- U4: a knowledge that is not KNOWN is left as it is: a source with no property record.
    local plain = filled("plain", wheat, 100, nil)
    local trailer4 = o:bindCarrier(ad, b("trailer", "4"), { amount = 0, unit = "l" })
    out = transfer(plain, trailer4, { materialRef = wheat, amount = 60, unit = "l" }, { materialRef = wheat, amount = 60, unit = "l" }, 40)
    T.eq("U4 a stock born UNKNOWN with an unexplained gain stays UNKNOWN (never raised to PARTIAL), with the reason", tostring(out) .. "|" .. state(trailer4), "COMMITTED|UNKNOWN/UNEXPLAINED_DELTA/60/nil")

    -- U5: UPDATE is unchanged: an unexplained gain demotes KNOWN to PARTIAL; a later clean update
    -- derives KNOWN again from the uniform records.
    local src5 = filled("src", wheat, 100, 0.10)
    local dst5 = filled("dst", wheat, 20, 0.30)
    out = transfer(src5, dst5, { materialRef = wheat, amount = 70, unit = "l" }, { materialRef = wheat, amount = 60, unit = "l" }, 30)
    T.eq("U5 an UPDATE with an unexplained gain reads PARTIAL with the reason, as before", tostring(out) .. "|" .. state(dst5), "COMMITTED|PARTIAL/UNEXPLAINED_DELTA/60/50")
    out = transfer(src5, dst5, { materialRef = wheat, amount = 60, unit = "l" }, { materialRef = wheat, amount = 70, unit = "l" }, 10)
    -- The combine above counts the stock before (60) plus the 10 L contribution: 70.
    T.eq("U5b a clean UPDATE derives KNOWN again and clears the reason, as before", tostring(out) .. "|" .. state(dst5), "COMMITTED|KNOWN/nil/70/70")
end
