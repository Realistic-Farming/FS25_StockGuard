-- SG2-4b-exact_pixel_rounding_spec_test.lua
--
-- THE GROUND SAMPLER ASKS FOR AN EXACT NUMBER OF PIXELS, SO IT MUST ROUND EXACTLY.
--
-- `GS.bind` built both DensityMapModifiers with NEAREST_EXPAND, copied from the engine's
-- own area reader (DensityMapHeightUtil.getFillLevelAtArea, :80-109). That reader is asked
-- for an AREA and may widen to cover it. This sampler asks for exactly one pixel, or
-- exactly one rectangle of pixels, and then PROVES the cardinality it was given, so any
-- widening makes a correct read fail its own proof.
--
-- WHAT WAS MEASURED IN GAME, and it is only this:
--   TEST-951  NEAREST_EXPAND, MapUS, block (35,2555)+27x27: expected 729, actual 841.
--   TEST-959  NEAREST, same map and block: exactly 729, and a 1x1 read: exactly 1.
--             reads 1068->1069, blockProofs 582->583, fault=none.
--
-- The proof came from an isolated read-only diagnostic package built on the Pumps N' Hoses
-- 842 base (SG958), NOT from this tree, and that adapter work is a separate scope. One map,
-- one site, two block shapes. Nothing here claims more.
--
-- HOW THE GROUPS DIVIDE, which matters for whether they can fail:
--   A to E ask the ENGINE MODEL directly with a mode this spec passes in. They pin what
--          each mode means, but they would still pass if production reverted.
--   P      reads the mode PRODUCTION configured and exercises production's own proof, and
--          is therefore the mutation control: revert src/native/SGGroundSampler.lua to
--          NEAREST_EXPAND and P1, P2, P4 and P6 fail.
--
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGGroundSampler.lua, src/native/SGGroundObserver.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, main.lua

local GS = SGGroundSampler
local G_ = ENGINE_GROUND

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The bench layer: 256 m over 512 px, a 0.5 m pitch centred on the origin. The pitch
-- matches Ally's 2048 / 4096 exactly, which is what makes the pixel arithmetic here the
-- same arithmetic as the native line's.
local TERRAIN, SIZE, PITCH = 256, 512, 0.5

local function mission()
    return { missionInfo = { mapId = "bench.map" }, terrainDetailHeightId = ENGINE_HEIGHT_ID,
             terrainSize = TERRAIN }
end

local function bound(expand)
    G_.reset()
    G_.expand = expand or 0
    g_currentMission = mission()
    local s, why = GS.bind(g_currentMission)
    if s == nil then error("bind refused: " .. tostring(why), 0) end
    return s
end

--- The pixel count a given rounding mode answers for the inset box over
--- [x0, x0+n-1] x [z0, z0+n-1], asked of the MODEL's own modifier rather than
--- re-derived here.
local function totalFor(mode, x0, z0, nx, nz)
    local s = bound(0)
    local m = DensityMapModifier.new(ENGINE_HEIGHT_ID, 6, 6)
    m:setPolygonRoundingMode(mode)
    local ax, az, bx, bz, cx, cz = s:polygon(x0, z0, nx, nz)
    m:setParallelogramWorldCoords(ax, az, bx, bz, cx, cz, DensityCoordType.POINT_POINT_POINT)
    local _, _, total = m:executeGet()
    return total
end

-- =====================================================================
-- GROUP A: the model now matches the native measurement
-- =====================================================================
group("A", function()
    T.eq("A1 the native case: a 27x27 inset block under NEAREST_EXPAND answers 29x29",
         totalFor(DensityRoundingMode.NEAREST_EXPAND, 35, 40, 27, 27), 841)
    T.eq("A2 which is exactly the 841 Tina's log reported against an expected 729",
         27 * 27, 729)
    T.eq("A3 a one-ring expansion is consistent with 29x29", 29 * 29, 841)
    T.eq("A4 the model predicts a 3x3 result for one pixel under this mode",
         totalFor(DensityRoundingMode.NEAREST_EXPAND, 35, 40, 1, 1), 9)
end)

-- =====================================================================
-- GROUP B: both candidates answer exactly N on the same geometry
-- =====================================================================
group("B", function()
    for _, c in ipairs({ { "NEAREST", DensityRoundingMode.NEAREST },
                         { "INCLUSIVE", DensityRoundingMode.INCLUSIVE } }) do
        local name, mode = c[1], c[2]
        -- 27 x 27 at a position that FITS the bench grid. Ally's z was 2555 on a
        -- 4096 px map; reducing that modulo this bench's 512 would sit 5 px from the
        -- edge and clip to 135, which is a property of the bench and not of the mode.
        -- The pitch is identical (2048/4096 = 256/512 = 0.5), so the pixel arithmetic
        -- is the same arithmetic; group A pins the native count itself.
        T.eq("B " .. name .. ": a 27x27 inset block answers exactly 729, not 841",
             totalFor(mode, 35, 40, 27, 27), 729)
        T.eq("B " .. name .. ": a single pixel answers exactly 1",
             totalFor(mode, 35, 40, 1, 1), 1)
        T.eq("B " .. name .. ": a 1 x 9 strip answers exactly 9",
             totalFor(mode, 35, 40, 1, 9), 9)
        T.eq("B " .. name .. ": a 9 x 1 strip answers exactly 9",
             totalFor(mode, 35, 40, 9, 1), 9)
    end
end)

-- =====================================================================
-- GROUP C: what separates them is MARGIN, and it is measurable
-- =====================================================================
group("C", function()
    -- How far the box edge could drift before the answer changes. The inset is 0.1 px.
    -- Under centres the left edge sits at X + 0.1 and the decision boundary is X + 0.5,
    -- so 0.4 px of a pitch. Under touched pixels the boundary is X itself, so 0.1 px.
    local inset = GS.INSET
    T.near("C1 the inset is a tenth of a pixel", inset, 0.1, 1e-12)
    T.near("C2 NEAREST clears its decision boundary by 0.4 px", 0.5 - inset, 0.4, 1e-12)
    T.near("C3 INCLUSIVE clears its decision boundary by only the inset", inset, 0.1, 1e-12)
    T.ok("C4 so NEAREST has four times the margin against float error",
         (0.5 - inset) > inset * 3.9)

    -- Demonstrated, not just computed: push the geometry by 0.25 px, less than NEAREST's
    -- margin and more than INCLUSIVE's, and only one of them keeps the exact answer.
    local s = bound(0)
    local p = PITCH
    local function totalShifted(mode, shift)
        local m = DensityMapModifier.new(ENGINE_HEIGHT_ID, 6, 6)
        m:setPolygonRoundingMode(mode)
        local ax, az, bx, bz, cx, cz = s:polygon(35, 40, 4, 4)
        local d = shift * p
        m:setParallelogramWorldCoords(ax - d, az - d, bx - d, bz - d, cx - d, cz - d,
                                      DensityCoordType.POINT_POINT_POINT)
        local _, _, total = m:executeGet()
        return total
    end
    T.eq("C5 shifted a quarter pixel, NEAREST still answers the exact 16",
         totalShifted(DensityRoundingMode.NEAREST, 0.25), 16)
    T.ok("C6 while INCLUSIVE picks up a neighbouring column and row",
         totalShifted(DensityRoundingMode.INCLUSIVE, 0.25) > 16)
end)

-- =====================================================================
-- GROUP D: the proof that must hold whatever the mode is. No neighbour
-- may be included or attributed.
-- =====================================================================
group("D", function()
    local s = bound(0)
    -- Fill a ring of neighbours around an empty 4x4 block. If the query widened by even
    -- one pixel it would see material and the block could never be certified empty; if
    -- it widened and we accepted the count, that material would be attributed here.
    for x = 34, 40 do
        for z = 39, 45 do
            local inner = (x >= 35 and x <= 38 and z >= 40 and z <= 43)
            if not inner then G_.put(x, z, ENGINE_HT.BARLEY.index, 20) end
        end
    end

    T.eq("D1 the 4x4 block is proved EMPTY despite being ringed by filled pixels",
         s:blockEmpty(35, 40, 4, 4), true)
    T.eq("D2 and the binding did not fault", s.fault, nil)

    -- The same ring with one INNER pixel filled must answer not-empty, so D1 cannot be
    -- passing because the query sees nothing at all.
    local s2 = bound(0)
    for x = 34, 40 do
        for z = 39, 45 do
            local inner = (x >= 35 and x <= 38 and z >= 40 and z <= 43)
            if not inner then G_.put(x, z, ENGINE_HT.BARLEY.index, 20) end
        end
    end
    G_.put(37, 42, ENGINE_HT.BARLEY.index, 20)
    T.eq("D3 one filled pixel inside the same block answers NOT empty",
         s2:blockEmpty(35, 40, 4, 4), false)

    -- And a single-cell read on a pixel whose neighbours are full reads its own value.
    local s3 = bound(0)
    for x = 34, 36 do
        for z = 39, 41 do
            if not (x == 35 and z == 40) then G_.put(x, z, ENGINE_HT.BARLEY.index, 31) end
        end
    end
    local cell, why = s3:readCell(35, 40)
    T.ok("D4 the centre pixel reads (" .. tostring(why) .. ")", cell ~= nil)
    T.eq("D5 as its own empty self, with no neighbour summed in",
         cell ~= nil and cell.raw or nil, 0)
    T.eq("D6 and no fill type attributed to it", cell ~= nil and cell.fillTypeIndex or nil, nil)
end)

-- =====================================================================
-- GROUP E: edge clipping, and the latch and one-shot detail are intact
-- =====================================================================
group("E", function()
    local s = bound(0)
    -- A block at the map's own corner: the query must not run off the grid.
    T.eq("E1 a block at the origin corner proves empty", s:blockEmpty(0, 0, 4, 4), true)
    T.eq("E2 a block at the far corner proves empty",
         s:blockEmpty(SIZE - 4, SIZE - 4, 4, 4), true)
    T.eq("E3 a single pixel at the far corner reads",
         (select(1, s:readCell(SIZE - 1, SIZE - 1)) ~= nil), true)
    T.eq("E4 and off-map is still refused on its own terms, without latching",
         select(2, s:readCell(SIZE, 0)), "OUT_OF_MAP")
    T.eq("E5 so the binding is still healthy", s.fault, nil)

    -- The latch and the one-shot record still work, through the fault injector.
    local s2 = bound(1)
    local empty, why = s2:blockEmpty(10, 10, 4, 4)
    T.eq("E6 an expanded query is still refused", empty, nil)
    T.eq("E7 for CARDINALITY", why, "CARDINALITY")
    T.ok("E8 CARDINALITY still latches", GS.LATCHING.CARDINALITY == true)
    -- [dev] This tree's latch records the REASON only. SG948's one-shot detail record and
    -- its faultReport() line are not in development - that is the separate MAINT-321
    -- ground-fault-evidence work - so these rows assert the latch this tree really has
    -- rather than a richer one it does not.
    T.eq("E9 and the binding latched with that reason",
         s2.fault ~= nil and s2.fault.reason or nil, "CARDINALITY")
    T.eq("E10 resetting the qualified-type table", type(s2.faultQualified), "table")
    -- The latch is one-shot: a later, different refusal must not overwrite the first.
    s2:refuse("SCALE")
    T.eq("E11 and a later refusal does not overwrite the first reason",
         s2.fault ~= nil and s2.fault.reason or nil, "CARDINALITY")
end)

-- =====================================================================
-- GROUP P: PRODUCTION's own configuration and proof. THE MUTATION CONTROL.
-- =====================================================================
-- Groups A to E construct their own modifier and pass a mode in, so a revert of the
-- product source would leave every one of them green. These rows read what `GS.bind`
-- actually configured, and then run production's own cardinality proof on the native
-- block shape.
group("P", function()
    local s = bound(0)
    T.eq("P1 production configures the HEIGHT modifier to NEAREST",
         s.heightModifier.rounding, DensityRoundingMode.NEAREST)
    T.eq("P2 and the TYPE modifier to NEAREST",
         s.typeModifier.rounding, DensityRoundingMode.NEAREST)
    T.ok("P3 so neither is NEAREST_EXPAND any more",
         s.heightModifier.rounding ~= DensityRoundingMode.NEAREST_EXPAND
         and s.typeModifier.rounding ~= DensityRoundingMode.NEAREST_EXPAND)

    -- Behaviour, not only configuration: production's own proof on TEST-959's block shape.
    T.eq("P4 production proves the 27x27 native block shape empty, so its own cardinality "
         .. "proof was answered exactly 729", s:blockEmpty(35, 40, 27, 27), true)
    T.eq("P5 and the binding did not latch", s.fault, nil)
    local cell, why = s:readCell(35, 40)
    T.ok("P6 production reads a single pixel, the 1x1 case (" .. tostring(why) .. ")",
         cell ~= nil)
    T.eq("P7 and the binding is still healthy afterwards", s.fault, nil)

    -- THE MUTATION ITSELF, so P4 cannot be a vacuous pass: put the SAME sampler's
    -- modifiers back to NEAREST_EXPAND and production's own call refuses.
    local s2 = bound(0)
    s2.heightModifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST_EXPAND)
    s2.typeModifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST_EXPAND)
    local empty, whyOld = s2:blockEmpty(35, 40, 27, 27)
    T.eq("P8 reverted to NEAREST_EXPAND, the same production call REFUSES", empty, nil)
    T.eq("P9 for CARDINALITY, which is TEST-951's 841-against-729 failure",
         whyOld, "CARDINALITY")
    T.eq("P10 and that refusal latches the binding, as it did on the Ally",
         s2.fault ~= nil and s2.fault.reason or nil, "CARDINALITY")

    -- And the 1x1 case fails the same way under the old mode, which is the second shape
    -- TEST-959 measured.
    local s3 = bound(0)
    s3.heightModifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST_EXPAND)
    s3.typeModifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST_EXPAND)
    local c3, why3 = s3:readCell(35, 40)
    T.eq("P11 reverted, a single-pixel read is refused too", c3, nil)
    T.eq("P12 for CARDINALITY, the 1x1 shape TEST-959 also measured", why3, "CARDINALITY")
end)
