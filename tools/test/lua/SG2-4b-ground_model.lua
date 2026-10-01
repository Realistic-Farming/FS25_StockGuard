-- SG2-4b-ground_model.lua - the ground engine the SG2-4b bench runs against.
--
-- NOT A TEST. A bar lists it FOURTH in --!load, after SG2-2-engine_model.lua,
-- SG2-3-engine_model.lua and SG2-4a-savegame_model.lua, and before any StockGuard file,
-- as the game defines its classes before a mod's source().
--
-- Bodies marked VERBATIM follow D:\FS25_Decoded\dataS\scripts_decompiled (1.24.0.0) at the
-- cited lines through every quantity they touch, with the decompiler's reused local names
-- restored from the control flow; presentation (debug drawing, effects, sounds, dirty
-- flags) is abbreviated and said so. Bodies marked MODELED stand in for C functions with
-- no Lua body: the terrain height layer, DensityMapModifier / DensityMapFilter and the
-- line and smoothing primitives of the height updater.

local WHEAT, BARLEY = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY

-- ── bit32, completed ─────────────────────────────────────────────────────────────
-- FS25's Lua 5.1 ships the whole bit32 library (SGSha256.lua:9-10). SG2-3's model defines
-- only the two functions its fruit code calls; the ground carrier's owner key is a SHA-256
-- digest, so the rest is added here, arithmetically, over 32-bit unsigned values.
do
    local MOD = 4294967296
    local function norm(x) return x % MOD end
    local function bitop(a, c, f)
        a, c = norm(a), norm(c)
        local result, bitv = 0, 1
        for _ = 1, 32 do
            local abit, cbit = a % 2, c % 2
            if f(abit, cbit) then result = result + bitv end
            a, c, bitv = (a - abit) / 2, (c - cbit) / 2, bitv * 2
        end
        return result
    end
    bit32 = bit32 or {}
    bit32.band = function(a, c) return bitop(a, c, function(x, y) return x == 1 and y == 1 end) end
    bit32.bor = bit32.bor or function(a, c) return bitop(a, c, function(x, y) return x == 1 or y == 1 end) end
    bit32.bxor = bit32.bxor or function(a, c) return bitop(a, c, function(x, y) return x ~= y end) end
    bit32.bnot = bit32.bnot or function(a) return MOD - 1 - norm(a) end
    bit32.rshift = function(a, n) return math.floor(norm(a) / 2 ^ n) end
    bit32.lshift = bit32.lshift or function(a, n) return (norm(a) * 2 ^ n) % MOD end
end

-- ── engine enums the modifiers take (C) ────────────────────────────────────────
DensityRoundingMode = DensityRoundingMode or { INCLUSIVE = 0, NEAREST = 1, NEAREST_EXPAND = 2 }
DensityCoordType = DensityCoordType or { POINT_POINT_POINT = 0, POINT_VECTOR_VECTOR = 1 }
DensityValueCompareType = DensityValueCompareType or { EQUAL = 0, NOTEQUAL = 1, GREATER = 2, GREATER_EQUAL = 3, LESS = 4, LESS_EQUAL = 5 }
VehicleDebug = VehicleDebug or { state = 0, DEBUG_ATTRIBUTES = 1 }
g_terrainNode = g_terrainNode or { terrain = true }

-- ── the terrain height layer (C, MODELED) ────────────────────────────────────────
-- The mission's terrainDetailHeight map (ENGINE_HEIGHT_ID, SG2-4a's model): 512 pixels a
-- side over the bench's 256 m terrain, so a pixel is 0.5 m, centred on the origin. Each
-- pixel holds a raw height (the height channels, 6 bits) and a height-type index (the
-- type channels). Knobs for fault rows:
--   expand      extra pixels NEAREST_EXPAND adds on every side (0 = the engine's rounding)
--   typedLie    a pixel key whose type filter answers false (a type/height disagreement)
--   stepRaw     the most raw units one line call adds to one pixel (spreads a drop)
--   roundUp     the line writes ceil(budget) instead of floor(budget)
--   extraRaw    raw units the line writes beyond the request without reporting them
--   shortRaw    raw units the line leaves unwritten while still reporting its budget
--   onWrite     function(key) called after each line call's write (fault injection)
--   lineError   the line raises after writing
ENGINE_GROUND = { size = 512, heights = {}, types = {}, queries = 0, lineCalls = {}, smoothCalls = 0 }
local function gkey(x, z) return x .. ":" .. z end
ENGINE_GROUND.key = gkey
function ENGINE_GROUND.reset()
    ENGINE_GROUND.heights, ENGINE_GROUND.types = {}, {}
    ENGINE_GROUND.expand, ENGINE_GROUND.typedLie, ENGINE_GROUND.stepRaw = 0, nil, 4
    ENGINE_GROUND.roundUp, ENGINE_GROUND.extraRaw, ENGINE_GROUND.shortRaw = false, 0, 0
    ENGINE_GROUND.onWrite, ENGINE_GROUND.lineError = nil, nil
    ENGINE_GROUND.queries, ENGINE_GROUND.lineCalls, ENGINE_GROUND.smoothCalls = 0, {}, 0
end
ENGINE_GROUND.reset()
function ENGINE_GROUND.pitch() return g_currentMission.terrainSize / ENGINE_GROUND.size end
function ENGINE_GROUND.half() return g_currentMission.terrainSize * 0.5 end
--- The pixel a world position falls in.
function ENGINE_GROUND.cellOf(wx, wz)
    local p, h = ENGINE_GROUND.pitch(), ENGINE_GROUND.half()
    return math.floor((wx + h) / p), math.floor((wz + h) / p)
end
function ENGINE_GROUND.centre(x, z)
    local p, h = ENGINE_GROUND.pitch(), ENGINE_GROUND.half()
    return (x + 0.5) * p - h, (z + 0.5) * p - h
end
--- Put `raw` of height type `typeIndex` on pixel (x, z) (a pile the map already has).
function ENGINE_GROUND.put(x, z, typeIndex, raw)
    local k = gkey(x, z)
    ENGINE_GROUND.heights[k] = raw > 0 and raw or nil
    ENGINE_GROUND.types[k] = raw > 0 and typeIndex or nil
end
function ENGINE_GROUND.raw(x, z) return ENGINE_GROUND.heights[gkey(x, z)] or 0 end
function ENGINE_GROUND.typeAt(x, z) return ENGINE_GROUND.types[gkey(x, z)] or 0 end
--- Every occupied pixel as "x:z=type/raw", sorted.
function ENGINE_GROUND.dump()
    local out = {}
    for k, raw in pairs(ENGINE_GROUND.heights) do out[#out + 1] = k .. "=" .. tostring(ENGINE_GROUND.types[k]) .. "/" .. tostring(raw) end
    table.sort(out)
    return table.concat(out, ",")
end
function ENGINE_GROUND.totalRaw(typeIndex)
    local n = 0
    for k, raw in pairs(ENGINE_GROUND.heights) do if typeIndex == nil or ENGINE_GROUND.types[k] == typeIndex then n = n + raw end end
    return n
end

local planeSize = getDensityMapSize
function getDensityMapSize(id)
    if id == ENGINE_HEIGHT_ID then return ENGINE_GROUND.size end
    return planeSize(id)
end
function getDensityMapMaxHeight(id) return 4 end

local function channelValue(mapId, first, num, x, z)
    local m = ENGINE_MAPS[ENGINE_HEIGHT_ID]
    if mapId ~= ENGINE_HEIGHT_ID then error("MODEL: no density map " .. tostring(mapId)) end
    if first == m.heightFirstChannel and num == m.heightNumChannels then return ENGINE_GROUND.heights[gkey(x, z)] or 0 end
    local hm = g_densityMapHeightManager
    if first == hm.heightTypeFirstChannel and num == hm.heightTypeNumChannels then return ENGINE_GROUND.types[gkey(x, z)] or 0 end
    error("MODEL: no channel range " .. tostring(first) .. "+" .. tostring(num))
end

-- ── DensityMapModifier and DensityMapFilter (C, MODELED) ───────────────────────
-- setParallelogramWorldCoords(start, width point, height point, POINT_POINT_POINT); the
-- polygon covers the parallelogram's bounding box. NEAREST_EXPAND takes every pixel the
-- box touches (an inset square strictly inside one pixel is exactly that pixel); any other
-- mode takes the pixels whose centres lie inside. executeGet(f1, f2) answers the sum of
-- the modifier's channel over the pixels passing both filters, their count (with no
-- filter: the pixels whose value is nonzero) and the total pixel count of the area.
DensityMapModifier = {}
DensityMapModifier.__index = DensityMapModifier
function DensityMapModifier.new(mapId, firstChannel, numChannels, terrainNode)
    return setmetatable({ mapId = mapId, first = firstChannel, num = numChannels, rounding = nil, poly = nil }, DensityMapModifier)
end
function DensityMapModifier:setPolygonRoundingMode(mode) self.rounding = mode end
function DensityMapModifier:setParallelogramWorldCoords(ax, az, bx, bz, cx, cz, coordType)
    if coordType ~= DensityCoordType.POINT_POINT_POINT then error("MODEL: coord type") end
    self.poly = { ax = ax, az = az, bx = bx, bz = bz, cx = cx, cz = cz }
end
local function pixelsOf(poly, rounding)
    local dx, dz = poly.bx + poly.cx - poly.ax, poly.bz + poly.cz - poly.az
    local minx, maxx = math.min(poly.ax, poly.bx, poly.cx, dx), math.max(poly.ax, poly.bx, poly.cx, dx)
    local minz, maxz = math.min(poly.az, poly.bz, poly.cz, dz), math.max(poly.az, poly.bz, poly.cz, dz)
    local p, h, size = ENGINE_GROUND.pitch(), ENGINE_GROUND.half(), ENGINE_GROUND.size
    local x0, x1, z0, z1
    if rounding == DensityRoundingMode.NEAREST_EXPAND then
        local e = ENGINE_GROUND.expand
        x0, x1 = math.floor((minx + h) / p) - e, math.ceil((maxx + h) / p) - 1 + e
        z0, z1 = math.floor((minz + h) / p) - e, math.ceil((maxz + h) / p) - 1 + e
    else
        x0, x1 = math.ceil((minx + h) / p - 0.5), math.floor((maxx + h) / p - 0.5)
        z0, z1 = math.ceil((minz + h) / p - 0.5), math.floor((maxz + h) / p - 0.5)
    end
    return math.max(0, x0), math.max(0, z0), math.min(size - 1, x1), math.min(size - 1, z1)
end
function DensityMapModifier:executeGet(f1, f2)
    ENGINE_GROUND.queries = ENGINE_GROUND.queries + 1
    local x0, z0, x1, z1 = pixelsOf(self.poly, self.rounding)
    local sum, n, total = 0, 0, 0
    for z = z0, z1 do
        for x = x0, x1 do
            total = total + 1
            local v = channelValue(self.mapId, self.first, self.num, x, z)
            if f1 == nil and f2 == nil then
                sum = sum + v
                if v ~= 0 then n = n + 1 end
            elseif (f1 == nil or f1:passes(x, z)) and (f2 == nil or f2:passes(x, z)) then
                sum = sum + v
                n = n + 1
            end
        end
    end
    return sum, n, total
end
DensityMapFilter = {}
DensityMapFilter.__index = DensityMapFilter
function DensityMapFilter.new(a, first, num)
    if type(a) == "table" then return setmetatable({ mapId = a.mapId, first = a.first, num = a.num }, DensityMapFilter) end
    return setmetatable({ mapId = a, first = first, num = num }, DensityMapFilter)
end
function DensityMapFilter:setValueCompareParams(compareType, value) self.compareType, self.value = compareType, value end
function DensityMapFilter:passes(x, z)
    local v = channelValue(self.mapId, self.first, self.num, x, z)
    local c = self.compareType
    if c == DensityValueCompareType.EQUAL then
        if ENGINE_GROUND.typedLie == gkey(x, z) then return false end
        return v == self.value
    elseif c == DensityValueCompareType.NOTEQUAL then return v ~= self.value
    elseif c == DensityValueCompareType.GREATER then return v > self.value end
    error("MODEL: compare type " .. tostring(c))
end

-- ── the height updater's primitives (C, MODELED) ─────────────────────────────────
local function segmentDistance(px, pz, sx, sz, ex, ez)
    local dx, dz = ex - sx, ez - sz
    local len2 = dx * dx + dz * dz
    local t = len2 > 0 and math.max(0, math.min(1, ((px - sx) * dx + (pz - sz) * dz) / len2)) or 0
    local qx, qz = sx + t * dx, sz + t * dz
    return math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
end
--- The pixels whose centres lie within r of the segment, nearest first, then (z, x).
local function candidates(sx, sz, ex, ez, r)
    local list = {}
    local x0, z0 = ENGINE_GROUND.cellOf(math.min(sx, ex) - r, math.min(sz, ez) - r)
    local x1, z1 = ENGINE_GROUND.cellOf(math.max(sx, ex) + r, math.max(sz, ez) + r)
    for z = z0, z1 do
        for x = x0, x1 do
            local cx, cz = ENGINE_GROUND.centre(x, z)
            local d = segmentDistance(cx, cz, sx, sz, ex, ez)
            if d <= r then list[#list + 1] = { x = x, z = z, d = d } end
        end
    end
    table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end if a.z ~= b.z then return a.z < b.z end return a.x < b.x end)
    return list
end
--- addDensityMapHeightAtWorldLine (C, MODELED). A positive delta adds up to floor(delta)
--- raw units (ceil with roundUp), at most stepRaw per pixel, onto empty pixels or pixels of
--- the same type within max(innerRadius, radius) of the line, nearest first; a negative
--- delta removes up to floor(-delta) raw units of that type, nearest first. Answers the
--- signed raw amount moved and the next line offset. applyChanges false writes nothing.
function addDensityMapHeightAtWorldLine(updater, sx, sy, sz, ex, ey, ez, delta, heightTypeIndex, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, tireTrackSystemId)
    ENGINE_GROUND.lineCalls[#ENGINE_GROUND.lineCalls + 1] = { delta = delta, heightTypeIndex = heightTypeIndex, innerRadius = innerRadius, radius = radius,
        applyChanges = applyChanges, sx = sx, sz = sz, ex = ex, ez = ez, lineOffset = lineOffset }
    local maxRaw = 2 ^ ENGINE_MAPS[ENGINE_HEIGHT_ID].heightNumChannels - 1
    local r = math.max(innerRadius or 0, radius or 0)
    local write = applyChanges ~= false
    local moved = 0
    if delta > 0 then
        local budget = ENGINE_GROUND.roundUp and math.ceil(delta) or math.floor(delta)
        local writeBudget = budget - ENGINE_GROUND.shortRaw
        for _, c in ipairs(candidates(sx, sz, ex, ez, r)) do
            if moved >= writeBudget then break end
            local k = gkey(c.x, c.z)
            local t, h = ENGINE_GROUND.types[k] or 0, ENGINE_GROUND.heights[k] or 0
            if h == 0 or t == heightTypeIndex then
                local take = math.min(maxRaw - h, ENGINE_GROUND.stepRaw, writeBudget - moved)
                if take > 0 then
                    if write then ENGINE_GROUND.heights[k], ENGINE_GROUND.types[k] = h + take, heightTypeIndex end
                    moved = moved + take
                end
            end
        end
        if ENGINE_GROUND.shortRaw > 0 then moved = moved + ENGINE_GROUND.shortRaw end
        if write and ENGINE_GROUND.extraRaw > 0 then
            for _, c in ipairs(candidates(sx, sz, ex, ez, r)) do
                local k = gkey(c.x, c.z)
                if (ENGINE_GROUND.types[k] or heightTypeIndex) == heightTypeIndex and (ENGINE_GROUND.heights[k] or 0) + ENGINE_GROUND.extraRaw <= maxRaw then
                    ENGINE_GROUND.heights[k], ENGINE_GROUND.types[k] = (ENGINE_GROUND.heights[k] or 0) + ENGINE_GROUND.extraRaw, heightTypeIndex
                    break
                end
            end
        end
    elseif delta < 0 then
        local budget = math.floor(-delta)
        for _, c in ipairs(candidates(sx, sz, ex, ez, r)) do
            if moved >= budget then break end
            local k = gkey(c.x, c.z)
            local h = ENGINE_GROUND.heights[k] or 0
            if h > 0 and ENGINE_GROUND.types[k] == heightTypeIndex then
                local take = math.min(h, budget - moved)
                if write then
                    ENGINE_GROUND.heights[k] = h - take > 0 and h - take or nil
                    if h - take <= 0 then ENGINE_GROUND.types[k] = nil end
                end
                moved = moved + take
            end
        end
        moved = -moved
    end
    if write and ENGINE_GROUND.onWrite ~= nil then ENGINE_GROUND.onWrite() end
    if write and ENGINE_GROUND.lineError ~= nil then error(ENGINE_GROUND.lineError, 0) end
    return moved, (lineOffset or 0) + 1
end
--- smoothDensityMapHeightAtWorldPos (C, MODELED). Moves one raw unit from the highest pixel
--- of the type within the outer radius to the lowest of its four neighbours of the same type
--- or empty. Nothing observes it before 2-4b2: the bench's unobserved writer.
function smoothDensityMapHeightAtWorldPos(updater, x, y, z, smoothAmount, heightTypeIndex, minRadius, radius, outerRadius, tireTrackSystemId)
    ENGINE_GROUND.smoothCalls = ENGINE_GROUND.smoothCalls + 1
    local best, bestH = nil, 0
    for _, c in ipairs(candidates(x, z, x, z, outerRadius or radius or 1)) do
        local k = gkey(c.x, c.z)
        if ENGINE_GROUND.types[k] == heightTypeIndex and (ENGINE_GROUND.heights[k] or 0) > bestH then best, bestH = c, ENGINE_GROUND.heights[k] end
    end
    if best == nil or bestH < 2 then return end
    local low, lowH = nil, math.huge
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local k = gkey(best.x + d[1], best.z + d[2])
        local t, h = ENGINE_GROUND.types[k] or 0, ENGINE_GROUND.heights[k] or 0
        if (h == 0 or t == heightTypeIndex) and h < lowH then low, lowH = k, h end
    end
    if low == nil then return end
    local bk = gkey(best.x, best.z)
    ENGINE_GROUND.heights[bk] = bestH - 1
    ENGINE_GROUND.heights[low], ENGINE_GROUND.types[low] = lowH + 1, heightTypeIndex
end
function addDensityMapHeightOcclusionArea() end
--- getDensityMapHeightTypeAtWorldLine (C, MODELED): the type of the nearest occupied pixel
--- within the radius, or 0.
function getDensityMapHeightTypeAtWorldLine(updater, sx, sy, sz, ex, ey, ez, radius)
    for _, c in ipairs(candidates(sx, sz, ex, ez, radius or 0.5)) do
        local k = gkey(c.x, c.z)
        if (ENGINE_GROUND.heights[k] or 0) > 0 then return ENGINE_GROUND.types[k] end
    end
    return 0
end
function getDensityHeightAtWorldPos(id, x, y, z) local cx, cz = ENGINE_GROUND.cellOf(x, z) return ENGINE_GROUND.raw(cx, cz) * 0.01, 0 end
function getTerrainHeightAtWorldPos(node, x, y, z) return 0 end
--- The world's nodes: a node is { x, y, z } with no rotation.
function localToWorld(node, x, y, z) return (node.x or 0) + x, (node.y or 0) + y, (node.z or 0) + z end
function localDirectionToWorld(node, x, y, z) return x, y, z end
MathUtil.lerp = MathUtil.lerp or function(v1, v2, alpha) return v1 + (v2 - v1) * alpha end
MathUtil.vector3Length = MathUtil.vector3Length or function(x, y, z) return math.sqrt(x * x + y * y + z * z) end
MathUtil.vector3Normalize = MathUtil.vector3Normalize or function(x, y, z) local l = math.sqrt(x * x + y * y + z * z) if l == 0 then return 0, 0, 0 end return x / l, y / l, z / l end
MathUtil.getXZWidthAndHeight = MathUtil.getXZWidthAndHeight or function(sx, sz, wx, wz, hx, hz) return sx, sz, wx - sx, wz - sz, hx - sx, hz - sz end
--- MathUtil.hasRectangleLineIntersection2D (MathUtil.lua:435) MODELED for axis-aligned
--- rectangles: does the segment touch the rectangle?
MathUtil.hasRectangleLineIntersection2D = function(x1, z1, dirX1, dirZ1, dirX2, dirZ2, x3, z3, dirX3, dirZ3)
    local minx, maxx = math.min(x1, x1 + dirX1 + dirX2), math.max(x1, x1 + dirX1 + dirX2)
    local minz, maxz = math.min(z1, z1 + dirZ1 + dirZ2), math.max(z1, z1 + dirZ1 + dirZ2)
    for i = 0, 20 do
        local t = i / 20
        local px, pz = x3 + dirX3 * t, z3 + dirZ3 * t
        if px >= minx and px <= maxx and pz >= minz and pz <= maxz then return true end
    end
    return false
end

-- ── DensityMapHeightManager (densityMaps/DensityMapHeightManager.lua) ──────────────
-- SG2-4a's model made g_densityMapHeightManager with the type channels; this adds the
-- height types and the updater. MODELED constants: fillToGroundScale 0.5 and
-- minValidLiterValue 2 (initialize :370-372 derives both from the map; with these one raw
-- unit is 2 L of a type whose own fillToGroundScale is 1, and the util's litres and the
-- sampler's litres agree).
local hm = g_densityMapHeightManager
hm.fillToGroundScale = 0.5
hm.minValidLiterValue = 2
hm.heightTypes, hm.fillTypeIndexToHeightType, hm.fillTypeNameToHeightType = {}, {}, {}
hm.fixedFillTypesAreas, hm.convertingFillTypesAreas = {}, {}
ENGINE_HEIGHT_UPDATER = { name = "TerrainDetailHeightUpdater" }
hm.terrainDetailHeightUpdater = ENGINE_HEIGHT_UPDATER
local function addHeightType(fillTypeIndex, name)
    local ht = { index = #hm.heightTypes + 1, fillTypeIndex = fillTypeIndex, fillTypeName = name, maxSurfaceAngle = math.rad(45), fillToGroundScale = 1,
                 canBeTipped = true, allowsSmoothing = true, collisionBaseOffset = 0 }
    hm.heightTypes[ht.index] = ht
    hm.fillTypeIndexToHeightType[fillTypeIndex] = ht
    hm.fillTypeNameToHeightType[name] = ht
    return ht
end
ENGINE_HT = { WHEAT = addHeightType(WHEAT, "WHEAT"), BARLEY = addHeightType(BARLEY, "BARLEY") }
-- :252-300 and :492-501 VERBATIM.
function hm:getDensityMapHeightTypeByIndex(index) if index == nil then return nil else return self.heightTypes[index] end end
function hm:getFillTypeIndexByDensityHeightMapIndex(index) if index == nil or self.heightTypes[index] == nil then return nil else return self.heightTypes[index].fillTypeIndex end end
function hm:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex) if fillTypeIndex == nil then return nil else return self.fillTypeIndexToHeightType[fillTypeIndex] end end
function hm:getDensityMapHeightTypes() return self.heightTypes end
function hm:getFixedFillTypesAreas() return self.fixedFillTypesAreas end
function hm:getConvertingFillTypesAreas() return self.convertingFillTypesAreas end
function hm:getIsValid() return self.terrainDetailHeightUpdater ~= nil end
function hm:getTerrainDetailHeightUpdater() return self.terrainDetailHeightUpdater end
function hm:getMinValidLiterValue(fillTypeIndex)
    local heightType = self:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex)
    return heightType == nil and 0 or self.minValidLiterValue / heightType.fillToGroundScale
end

-- ── DensityMapHeightUtil (densityMaps/DensityMapHeightUtil.lua) ─────────────────────
DensityMapHeightUtil = DensityMapHeightUtil or {}
DensityMapHeightUtil.lastVehiclesInRange = {}
--- :38-47 VERBATIM.
function DensityMapHeightUtil.getFillTypeAtLine(sx, sy, sz, ex, ey, ez, radius)
    if g_densityMapHeightManager:getIsValid() then
        local heightTypeIndex = getDensityMapHeightTypeAtWorldLine(g_densityMapHeightManager:getTerrainDetailHeightUpdater(), sx, sy, sz, ex, ey, ez, radius)
        local fillTypeIndex = g_densityMapHeightManager:getFillTypeIndexByDensityHeightMapIndex(heightTypeIndex)
        if fillTypeIndex ~= nil then
            return fillTypeIndex
        end
    end
    return FillType.UNKNOWN
end
--- :139-156 VERBATIM (a vehicle has no components here, so none is in range).
function DensityMapHeightUtil.getVehiclesInRange(refVehicle, x, y, z, radiusSq)
    for i = #DensityMapHeightUtil.lastVehiclesInRange, 1, -1 do DensityMapHeightUtil.lastVehiclesInRange[i] = nil end
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle ~= refVehicle and vehicle.components ~= nil then
            for _, component in pairs(vehicle.components) do
                local cx, cy, cz = getWorldTranslation(component.node)
                if MathUtil.vector3LengthSq(x - cx, y - cy, z - cz) < radiusSq then
                    table.insert(DensityMapHeightUtil.lastVehiclesInRange, vehicle)
                    break
                end
            end
        end
    end
    return DensityMapHeightUtil.lastVehiclesInRange
end
--- :157-300 VERBATIM, names restored; the debug drawing (:238-246, :263-271, :278-282) is
--- left out.
function DensityMapHeightUtil.tipToGroundAroundLine(vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, limitToLineHeight, occlusionAreas, useOcclusionAreas, applyChanges)
    if not g_densityMapHeightManager:getIsValid() then
        return 0, 0
    end
    local heightType = g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex)
    if heightType == nil then
        return 0, 0
    end
    if occlusionAreas == nil and (vehicle ~= nil and vehicle.getTipOcclusionAreas ~= nil) then
        occlusionAreas = vehicle:getTipOcclusionAreas()
    end
    if radius == nil then
        local maxHeight = getDensityMapMaxHeight(DensityMapHeightUtil.terrainDetailHeightId)
        radius = maxHeight / math.tan(heightType.maxSurfaceAngle)
    end
    innerRadius = innerRadius == nil and 0 or innerRadius
    lineOffset = lineOffset == nil and 0 or lineOffset
    if limitToLineHeight == nil then
        limitToLineHeight = false
    end
    applyChanges = applyChanges == nil and true or applyChanges
    if delta < 0 then
        useOcclusionAreas = false
    end
    if delta > 0 then
        local fixedFillTypeAreas = g_densityMapHeightManager:getFixedFillTypesAreas()
        if fixedFillTypeAreas ~= nil then
            for area, fixedFillTypeArea in pairs(fixedFillTypeAreas) do
                if area ~= nil and fixedFillTypeArea ~= nil then
                    local validFillType = false
                    for availableFillType, _ in pairs(fixedFillTypeArea.fillTypes) do
                        if availableFillType == fillTypeIndex then
                            validFillType = true
                        end
                    end
                    if area ~= nil and not validFillType then
                        local x1, _, z1 = getWorldTranslation(area.start)
                        local x2, _, z2 = getWorldTranslation(area.width)
                        local x3, _, z3 = getWorldTranslation(area.height)
                        if MathUtil.hasRectangleLineIntersection2D(x1, z1, x2 - x1, z2 - z1, x3 - x1, z3 - z1, sx, sz, ex - sx, ez - sz) then
                            return 0, 0
                        end
                    end
                end
            end
        end
        local convertingFillTypesAreas = g_densityMapHeightManager:getConvertingFillTypesAreas()
        if convertingFillTypesAreas ~= nil then
            for area, converting in pairs(convertingFillTypesAreas) do
                if area ~= nil and converting ~= nil then
                    local x1, _, z1 = getWorldTranslation(area.start)
                    local x2, _, z2 = getWorldTranslation(area.width)
                    local x3, _, z3 = getWorldTranslation(area.height)
                    if MathUtil.hasRectangleLineIntersection2D(x1, z1, x2 - x1, z2 - z1, x3 - x1, z3 - z1, sx, sz, ex - sx, ez - sz) then
                        if converting.fillTypes[fillTypeIndex] ~= true then
                            return 0, 0
                        end
                        fillTypeIndex = converting.fillTypeTarget
                        heightType = g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex)
                        if heightType == nil then
                            return 0, 0
                        end
                    end
                end
            end
        end
    end
    local fillToGroundScale = g_densityMapHeightManager.fillToGroundScale * heightType.fillToGroundScale
    if useOcclusionAreas ~= nil and useOcclusionAreas then
        if occlusionAreas ~= nil then
            local updater = g_densityMapHeightManager:getTerrainDetailHeightUpdater()
            if updater ~= nil then
                for _, occlusionArea in pairs(occlusionAreas) do
                    local x1, y1, z1 = getWorldTranslation(occlusionArea.start)
                    local x2, y2, z2 = getWorldTranslation(occlusionArea.width)
                    local x3, y3, z3 = getWorldTranslation(occlusionArea.height)
                    local allowPropagation = occlusionArea.allowPropagation
                    if allowPropagation == nil then
                        allowPropagation = false
                    end
                    addDensityMapHeightOcclusionArea(updater, x1, y1, z1, x2 - x1, y2 - y1, z2 - z1, x3 - x1, y3 - y1, z3 - z1, allowPropagation)
                end
            end
        end
        local updater = g_densityMapHeightManager:getTerrainDetailHeightUpdater()
        if updater ~= nil then
            local maxDistSq = (20 + 0.5 * MathUtil.vector3Length(sx - ex, sy - ey, sz - ez) + radius) ^ 2
            local vehicles = DensityMapHeightUtil.getVehiclesInRange(vehicle, 0.5 * (sx + ex), 0.5 * (sy + ey), 0.5 * (sz + ez), maxDistSq)
            if vehicles ~= nil then
                for _, other in pairs(vehicles) do
                    if other.getTipOcclusionAreas ~= nil then
                        for _, a in pairs(other:getTipOcclusionAreas()) do
                            local x1, y1, z1 = getWorldTranslation(a.start)
                            local xw, yw, zw = getWorldTranslation(a.width)
                            local xh, yh, zh = getWorldTranslation(a.height)
                            addDensityMapHeightOcclusionArea(updater, x1, y1, z1, xw - x1, yw - y1, zw - z1, xh - x1, yh - y1, zh - z1, false)
                        end
                    end
                end
            end
        end
    end
    local dropped = 0
    local updater = g_densityMapHeightManager:getTerrainDetailHeightUpdater()
    if updater ~= nil then
        local maxDelta = delta * fillToGroundScale
        if not applyChanges then
            maxDelta = math.max(maxDelta, g_densityMapHeightManager:getMinValidLiterValue(fillTypeIndex))
        end
        dropped, lineOffset = addDensityMapHeightAtWorldLine(updater, sx, sy, sz, ex, ey, ez, maxDelta, heightType.index, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, g_currentMission.tireTrackSystem.tireTrackSystemId)
        if not applyChanges then
            dropped = math.min(dropped, maxDelta)
        end
    end
    local converted = dropped / fillToGroundScale
    if math.abs(delta) - math.abs(converted) >= 0.001 then
        delta = converted
    end
    return delta, lineOffset
end
--- :491-522 VERBATIM, names restored, the debug drawing (:510-517) left out.
function DensityMapHeightUtil.smoothAroundLine(node, width, radius, overlap, smoothAmount, resetDisplacement)
    local r = width / (radius * 2 / overlap)
    local steps = math.ceil(r)
    r = width / steps * 0.5
    local heightType = nil
    for step = 1, steps do
        local x, y, z = localToWorld(node, -(width * 0.5) + r * 2 * (step - 0.5), 0, 0)
        local smoothGroundRadius = r * overlap
        heightType = heightType or DensityMapHeightUtil.getHeightTypeDescAtWorldPos(x, y, z, smoothGroundRadius)
        if heightType ~= nil and heightType.allowsSmoothing then
            local terrainHeightUpdater = g_densityMapHeightManager:getTerrainDetailHeightUpdater()
            if terrainHeightUpdater ~= nil then
                local densityHeight = DensityMapHeightUtil.getHeightAtWorldPos(x, y, z)
                if y < densityHeight then
                    smoothDensityMapHeightAtWorldPos(terrainHeightUpdater, x, densityHeight - heightType.collisionBaseOffset, z, smoothAmount, heightType.index, 0, smoothGroundRadius, smoothGroundRadius + 1.2, g_currentMission.tireTrackSystem.tireTrackSystemId)
                end
            end
        end
    end
end
--- :128-131 and :416-424 VERBATIM (the C calls modeled above).
function DensityMapHeightUtil.getHeightAtWorldPos(x, y, z) return getDensityHeightAtWorldPos(DensityMapHeightUtil.terrainDetailHeightId, x, y, z) end
function DensityMapHeightUtil.getHeightTypeDescAtWorldPos(x, y, z, radius)
    local cx, cz = ENGINE_GROUND.cellOf(x, z)
    local index = ENGINE_GROUND.typeAt(cx, cz)
    if index == 0 then return nil end
    return g_densityMapHeightManager:getDensityMapHeightTypeByIndex(index)
end

-- ── Dischargeable's ground discharge (vehicles/specializations/Dischargeable.lua) ───
--- :766-805 VERBATIM, names restored: the frame's cap is emptySpeed * 250 L, at least one
--- raw unit; the util drops litersToDrop * factor; the unit is debited what it dropped.
function Dischargeable:dischargeToGround(dischargeNode, emptyLiters)
    if emptyLiters == 0 then
        return 0, false, false
    end
    local fillType, factor = self:getDischargeFillType(dischargeNode)
    local fillLevel = self:getFillUnitFillLevel(dischargeNode.fillUnitIndex)
    local minLiterToDrop = g_densityMapHeightManager:getMinValidLiterValue(fillType)
    local wanted = dischargeNode.litersToDrop + emptyLiters
    local perFrame = dischargeNode.emptySpeed * 250
    local cap = math.max(perFrame, minLiterToDrop)
    dischargeNode.litersToDrop = math.min(wanted, cap)
    if dischargeNode.limitGroundTipToFillLevel then
        dischargeNode.litersToDrop = math.min(dischargeNode.litersToDrop, fillLevel)
    end
    local hasMinDropFillLevel = minLiterToDrop < fillLevel
    local info = dischargeNode.info
    local dischargedLiters = 0
    local sx, sy, sz = localToWorld(info.node, -info.width, 0, info.zOffset)
    local ex, ey, ez = localToWorld(info.node, info.width, 0, info.zOffset)
    sy = sy + info.yOffset
    ey = ey + info.yOffset
    if info.limitToGround then
        local h1 = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz) + 0.1
        sy = math.max(h1, sy)
        local h2 = getTerrainHeightAtWorldPos(g_terrainNode, ex, 0, ez) + 0.1
        ey = math.max(h2, ey)
    end
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, dischargeNode.litersToDrop * factor, fillType, sx, sy, sz, ex, ey, ez, info.length, nil, dischargeNode.lineOffset, true, nil, true)
    dropped = dropped / factor
    dischargeNode.lineOffset = lineOffset
    dischargeNode.litersToDrop = dischargeNode.litersToDrop - dropped
    if dropped > 0 then
        local unloadInfo = self:getFillVolumeUnloadInfo(dischargeNode.unloadInfoIndex)
        dischargedLiters = self:addFillUnitFillLevel(self:getOwnerFarmId(), dischargeNode.fillUnitIndex, -dropped, self:getFillUnitFillType(dischargeNode.fillUnitIndex), ToolType.UNDEFINED, unloadInfo)
    end
    local levelAfter = self:getFillUnitFillLevel(dischargeNode.fillUnitIndex)
    if levelAfter > 0 and levelAfter <= minLiterToDrop then
        dischargeNode.litersToDrop = minLiterToDrop
    end
    return dischargedLiters, minLiterToDrop < dischargeNode.litersToDrop, hasMinDropFillLevel
end

--- A tipper: a trailer (SG2-3's) with Dischargeable's registered functions COPIED into the
--- instance and one discharge node over fill unit 1, aimed at the ground at `at` (x, z).
--- opts: level, fillType, converter, at = { x, z }, width, length (the line's inner radius),
--- emptySpeed.
function ENGINE_NEW_TIPPER(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = opts.level, fillType = opts.fillType, capacity = opts.capacity or 20000,
        supported = opts.supported or { [WHEAT] = true, [BARLEY] = true } })
    v.configFileName = "data/vehicles/tipper.xml"
    v.discharge = Dischargeable.discharge
    v.dischargeToGround = Dischargeable.dischargeToGround
    v.dischargeToObject = Dischargeable.dischargeToObject
    v.getDischargeFillType = Dischargeable.getDischargeFillType
    v.getDischargeTargetObject = Dischargeable.getDischargeTargetObject
    v.getTipOcclusionAreas = function() return {} end
    v.spec_fillVolume = { unloadInfos = { {} } }
    v.getFillVolumeUnloadInfo = function(self, index) return self.spec_fillVolume.unloadInfos[index] end
    local at = opts.at or { x = 0, z = 0 }
    v.spec_dischargeable = { currentDischargeState = Dischargeable.DISCHARGE_STATE_GROUND,
        dischargeNodes = { { index = 1, fillUnitIndex = 1, toolType = ToolType.DISCHARGEABLE, unloadInfoIndex = 1, fillTypeConverter = opts.converter,
            emptySpeed = opts.emptySpeed or 1, litersToDrop = 0, lineOffset = 0, limitGroundTipToFillLevel = true, dischargeHitTerrain = true,
            info = { node = { x = at.x, y = 0, z = at.z }, width = opts.width or 1, length = opts.length or 0.5, zOffset = 0, yOffset = 0, limitToGround = false } } } }
    return v
end
--- One server frame of a ground tip: Dischargeable:discharge in the GROUND state (SG2-3's
--- :751-765 body), which calls dischargeToGround through self.
function ENGINE_TIP(vehicle, liters)
    local node = vehicle.spec_dischargeable.dischargeNodes[1]
    node.dischargeObject = nil
    vehicle.spec_dischargeable.currentDischargeState = Dischargeable.DISCHARGE_STATE_GROUND
    return vehicle:discharge(node, liters)
end

-- ── SpecializationUtil.raiseEvent (specializations/SpecializationUtil.lua:18-25) ─────
--- VERBATIM in effect: every listener spec of the event, its function fetched BY NAME from
--- the class table at raise time (:22-23).
function ENGINE_RAISE(object, eventName, ...)
    for _, spec in ipairs(object.eventListeners[eventName] or {}) do
        spec[eventName](object, ...)
    end
end

-- ── the async raycasts (C, MODELED) ─────────────────────────────────────────────
-- raycastAllAsync queues the cast; ENGINE_DELIVER_RAYCASTS(hits) calls the callback BY
-- NAME on its target for each hit (hitObjectId, x, y, z, distance, ..., isLast): `hits`
-- object hits first, then the terrain hit that is last.
ENGINE_RAYCASTS = {}
function raycastAllAsync(x, y, z, dx, dy, dz, distance, callbackName, target, collisionMask)
    ENGINE_RAYCASTS[#ENGINE_RAYCASTS + 1] = { callbackName = callbackName, target = target }
end
function ENGINE_DELIVER_RAYCASTS(hits)
    local queue = ENGINE_RAYCASTS
    ENGINE_RAYCASTS = {}
    for _, cast in ipairs(queue) do
        for i = 1, (hits or 0) do cast.target[cast.callbackName](cast.target, 77, 0, 0, 0, 1, nil, nil, nil, nil, nil, false) end
        cast.target[cast.callbackName](cast.target, g_terrainNode, 0, 0, 0, 1, nil, nil, nil, nil, nil, true)
    end
end

g_farmlandManager = g_farmlandManager or { getCanAccessLandAtWorldPosition = function() return true end }
I3DUtil = I3DUtil or {}
I3DUtil.setWorldDirection = I3DUtil.setWorldDirection or function() end

-- ── Leveler (vehicles/specializations/Leveler.lua) ─────────────────────────────────
-- Re-sourced with every map load: a new class table each boot (ENGINE_LOAD_LEVELER).
function ENGINE_LOAD_LEVELER()
    Leveler = {}
    --- :119-259 VERBATIM through the quantities, names restored (the decompile reuses
    --- dirX, dirZ, sz, ey and ey2 for different locals): per node, the pickup line and its
    --- credit, the drop line and its debit with the tiny-drop rule, the raycast launch and
    --- the smoothing. The client effects (:120-139), the force (:277-284) and the moved-pct
    --- filter (:208-218, :268-276) are left out; the farmland check (:143-148) passes.
    function Leveler:onUpdate(dt)
        local spec = self.spec_leveler
        if self.isServer then
            for _, levelerNode in pairs(spec.nodes) do
                local fillType = self:getFillUnitFillType(levelerNode.fillUnitIndex)
                local fillLevel = self:getFillUnitFillLevel(levelerNode.fillUnitIndex)
                local sx0, sy0, sz0 = localToWorld(levelerNode.node, -levelerNode.halfWidth, levelerNode.yOffset, levelerNode.maxDropDirOffset)
                local ex0, ey0, ez0 = localToWorld(levelerNode.node, levelerNode.halfWidth, levelerNode.yOffset, levelerNode.maxDropDirOffset)
                local newFillType
                if fillType == FillType.UNKNOWN or fillLevel < g_densityMapHeightManager:getMinValidLiterValue(fillType) + 0.001 then
                    newFillType = DensityMapHeightUtil.getFillTypeAtLine(sx0, sy0, sz0, ex0, ey0, ez0, 0.5 * levelerNode.maxDropDirOffset)
                    if newFillType == FillType.UNKNOWN or (newFillType == fillType or not self:getFillUnitSupportsFillType(levelerNode.fillUnitIndex, newFillType)) then
                        newFillType = fillType
                    else
                        self:addFillUnitFillLevel(self:getOwnerFarmId(), levelerNode.fillUnitIndex, -math.huge)
                    end
                else
                    newFillType = fillType
                end
                local heightType = g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(newFillType)
                if newFillType ~= FillType.UNKNOWN and heightType ~= nil then
                    local capacity = self:getFillUnitCapacity(levelerNode.fillUnitIndex)
                    if levelerNode.pickupActive and self.movingDirection == spec.pickUpDirection and self.lastSpeed > 0.0001 then
                        local sx, sy, sz = localToWorld(levelerNode.node, -levelerNode.halfWidth, levelerNode.yOffset, levelerNode.zOffset)
                        local ex, ey, ez = localToWorld(levelerNode.node, levelerNode.halfWidth, levelerNode.yOffset, levelerNode.zOffset)
                        local delta = -(capacity - self:getFillUnitFillLevel(levelerNode.fillUnitIndex))
                        local picked, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, delta, newFillType, sx, sy, sz, ex, ey, ez, 0.5, 2, levelerNode.lineOffsetPickUp, true, nil)
                        levelerNode.lastPickUp = picked
                        levelerNode.lineOffsetPickUp = lineOffset
                        if levelerNode.lastPickUp < 0 then
                            levelerNode.lastPickUp = levelerNode.lastPickUp + spec.litersToPickup
                            spec.litersToPickup = 0
                            self:addFillUnitFillLevel(self:getOwnerFarmId(), levelerNode.fillUnitIndex, -levelerNode.lastPickUp, newFillType, ToolType.UNDEFINED, nil)
                        end
                    end
                    local level = self:getFillUnitFillLevel(levelerNode.fillUnitIndex)
                    if level > 0 and levelerNode.dropActive then
                        local f = level / capacity
                        local w = MathUtil.lerp(levelerNode.halfMinDropWidth, levelerNode.halfMaxDropWidth, f)
                        local sx, sy, sz = localToWorld(levelerNode.node, -w, levelerNode.yOffset, levelerNode.zOffset)
                        local ex, ey, ez = localToWorld(levelerNode.node, w, levelerNode.yOffset, levelerNode.zOffset)
                        local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, level, newFillType, sx, sy - 0.15, sz, ex, ey - 0.15, ez, 0.5, 2, levelerNode.lineOffsetDrop1, true, nil)
                        levelerNode.lastDrop1 = dropped
                        levelerNode.lineOffsetDrop1 = lineOffset
                        if levelerNode.lastDrop1 > 0 then
                            local remaining = level - levelerNode.lastDrop1
                            if remaining <= g_densityMapHeightManager:getMinValidLiterValue(newFillType) then
                                levelerNode.lastDrop1 = level
                                spec.litersToPickup = spec.litersToPickup + remaining
                            end
                            self:addFillUnitFillLevel(self:getOwnerFarmId(), levelerNode.fillUnitIndex, -levelerNode.lastDrop1, newFillType, ToolType.UNDEFINED, nil)
                        end
                    end
                    if self:getFillUnitFillLevel(levelerNode.fillUnitIndex) > 0 and levelerNode.castActive then
                        levelerNode.raycastLastFillType = newFillType
                        levelerNode.raycastLastRadius = 2
                        levelerNode.raycastHitObject = false
                        raycastAllAsync(0, 0, 0, 0, -1, 0, 5, "onLevelerRaycastCallback", levelerNode, 0)
                    end
                end
                if levelerNode.allowsSmoothing then
                    DensityMapHeightUtil.smoothAroundLine(levelerNode.node, levelerNode.width, levelerNode.smoothGroundRadius, levelerNode.smoothOverlap, 1, true)
                end
            end
        end
    end
    --- :361-400 VERBATIM, names restored: the terminal no-hit cast drops the current unit's
    --- litres at the node's current offset and radius; the tiny-drop rule as :231-234.
    function Leveler.onLevelerRaycastCallback(levelerNode, hitObjectId, _, _, _, _, _, _, _, _, _, isLast)
        local self = levelerNode.vehicle
        if not (self.isDeleted or self.isDeleting) then
            if hitObjectId ~= 0 and hitObjectId ~= g_terrainNode then
                levelerNode.raycastHitObject = true
            end
            if isLast and not levelerNode.raycastHitObject then
                local fillLevel = self:getFillUnitFillLevel(levelerNode.fillUnitIndex)
                if fillLevel > 0 then
                    local fillType = levelerNode.raycastLastFillType
                    local f = self.spec_leveler.lastFillLevelMovedPct
                    local width = MathUtil.lerp(levelerNode.halfMinDropWidth, levelerNode.halfMaxDropWidth, f)
                    local dropOffset = MathUtil.lerp(levelerNode.minDropDirOffset, levelerNode.maxDropDirOffset, f)
                    local sx, sy, sz = localToWorld(levelerNode.node, -width, levelerNode.yOffset, levelerNode.zOffset + dropOffset)
                    local ex, ey, ez = localToWorld(levelerNode.node, width, levelerNode.yOffset, levelerNode.zOffset + dropOffset)
                    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, fillLevel, fillType, sx, sy, sz, ex, ey, ez, 0, levelerNode.raycastLastRadius, levelerNode.lineOffsetDrop2, false, nil)
                    levelerNode.lastDrop2 = dropped
                    levelerNode.lineOffsetDrop2 = lineOffset
                    if levelerNode.lastDrop2 > 0 then
                        local remaining = fillLevel - levelerNode.lastDrop2
                        if remaining <= g_densityMapHeightManager:getMinValidLiterValue(fillType) then
                            levelerNode.lastDrop2 = fillLevel
                            self.spec_leveler.litersToPickup = self.spec_leveler.litersToPickup + remaining
                        end
                        self:addFillUnitFillLevel(self:getOwnerFarmId(), levelerNode.fillUnitIndex, -levelerNode.lastDrop2, fillType, ToolType.UNDEFINED, nil)
                    end
                end
            end
        end
    end
end

--- A leveler (a front blade with a bucket unit): FillUnit's and Leveler's registered
--- functions COPIED into the instance (:45), and each node's callback copied from the
--- vehicle at load (:76). opts: level, fillType, at = { x, z }, pickup, drop, cast, smooth.
function ENGINE_NEW_LEVELER(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = opts.level, fillType = opts.fillType, capacity = opts.capacity or 2000,
        supported = { [WHEAT] = true, [BARLEY] = true } })
    v.configFileName = "data/vehicles/leveler.xml"
    v.isServer = true
    v.movingDirection, v.lastSpeed = 1, 0.01
    v.onLevelerRaycastCallback = Leveler.onLevelerRaycastCallback
    local at = opts.at or { x = 0, z = 0 }
    local node = { node = { x = at.x, y = 0, z = at.z }, fillUnitIndex = 1, halfWidth = 1, yOffset = 0, zOffset = 0, maxDropDirOffset = 0.2, minDropDirOffset = 0.1,
        halfMinDropWidth = 0.5, halfMaxDropWidth = 1, lineOffsetPickUp = 0, lineOffsetDrop1 = 0, lineOffsetDrop2 = 0, lastPickUp = 0, lastDrop1 = 0, lastDrop2 = 0,
        pickupActive = opts.pickup == true, dropActive = opts.drop == true, castActive = opts.cast == true, allowsSmoothing = opts.smooth == true,
        width = 2, smoothGroundRadius = 0.5, smoothOverlap = 1.5, vehicle = v }
    v.spec_leveler = { nodes = { node }, litersToPickup = 0, pickUpDirection = 1, lastFillLevelMovedPct = 0 }
    node.onLevelerRaycastCallback = v.onLevelerRaycastCallback
    v.eventListeners = { onUpdate = { Leveler }, onPostLoad = { ENGINE_FILLUNIT } }
    return v
end

-- ── Shovel (vehicles/specializations/Shovel.lua) ──────────────────────────────────
function ENGINE_LOAD_SHOVEL()
    Shovel = {}
    --- :141-245 VERBATIM through the quantities, names restored (the decompile reuses
    --- pickupFillType for the pickup litres and the pickup type): an active node's pickup
    --- line (:170), the capacity raise when native took more than was free (:171-174), the
    --- credit (:176-178); the bunker notify (:179) and the smoothing (:196-217) left out.
    function Shovel:onUpdateTick(dt)
        local spec = self.spec_shovel
        if self.isServer then
            for _, shovelNode in pairs(spec.shovelNodes) do
                if shovelNode.active then
                    local fillLevel = self:getFillUnitFillLevel(shovelNode.fillUnitIndex)
                    local capacity = self:getFillUnitCapacity(shovelNode.fillUnitIndex)
                    local freeCapacity = math.min(capacity - fillLevel, self:getFillUnitFreeCapacity(shovelNode.fillUnitIndex))
                    local pickupLiters = math.min(freeCapacity, shovelNode.fillLitersPerSecond * dt)
                    if pickupLiters > 0 then
                        local pickupFillType = self:getFillUnitFillType(shovelNode.fillUnitIndex)
                        if fillLevel / capacity < self:getFillTypeChangeThreshold() then
                            pickupFillType = FillType.UNKNOWN
                        end
                        local minValidLiter = g_densityMapHeightManager:getMinValidLiterValue(pickupFillType) or 0
                        local sx, sy, sz = localToWorld(shovelNode.node, -shovelNode.width * 0.5, shovelNode.yOffset, shovelNode.zOffset)
                        local ex, ey, ez = localToWorld(shovelNode.node, shovelNode.width * 0.5, shovelNode.yOffset, shovelNode.zOffset)
                        if pickupFillType == FillType.UNKNOWN then
                            pickupFillType = DensityMapHeightUtil.getFillTypeAtLine(sx, sy, sz, ex, ey, ez, shovelNode.length)
                        end
                        if pickupFillType ~= FillType.UNKNOWN and self:getFillUnitSupportsFillType(shovelNode.fillUnitIndex, pickupFillType) and self:getFillUnitAllowsFillType(shovelNode.fillUnitIndex, pickupFillType) then
                            local fillDelta, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, -pickupLiters - minValidLiter, pickupFillType, sx, sy, sz, ex, ey, ez, shovelNode.length, nil, shovelNode.lineOffset, true, nil)
                            shovelNode.lineOffset = lineOffset
                            if pickupLiters < -fillDelta then
                                self:setFillUnitCapacity(shovelNode.fillUnitIndex, fillLevel - fillDelta)
                                shovelNode.capacityChanged = true
                            end
                            if fillDelta < 0 then
                                self:addFillUnitFillLevel(self:getOwnerFarmId(), shovelNode.fillUnitIndex, -fillDelta, pickupFillType, ToolType.UNDEFINED, nil)
                            end
                        end
                    end
                elseif shovelNode.resetFillLevel then
                    -- :186-193 VERBATIM: an inactive node that resets empties its unit.
                    local fillLevel = self:getFillUnitFillLevel(shovelNode.fillUnitIndex)
                    if fillLevel > 0 then
                        self:addFillUnitFillLevel(self:getOwnerFarmId(), shovelNode.fillUnitIndex, -fillLevel, self:getFillUnitFillType(shovelNode.fillUnitIndex), ToolType.UNDEFINED)
                    end
                end
            end
        end
    end
end

--- A front loader shovel: fill unit 1 behind one shovel node at `at`.
function ENGINE_NEW_SHOVEL(uid, opts)
    opts = opts or {}
    local v = ENGINE_NEW_TRAILER(uid, { level = opts.level, fillType = opts.fillType, capacity = opts.capacity or 1000,
        supported = { [WHEAT] = true, [BARLEY] = true } })
    v.configFileName = "data/vehicles/shovel.xml"
    v.isServer = true
    v.setFillUnitCapacity = function(self, i, capacity) self.spec_fillUnit.fillUnits[i].capacity = capacity end
    local at = opts.at or { x = 0, z = 0 }
    v.spec_shovel = { shovelNodes = { { node = { x = at.x, y = 0, z = at.z }, fillUnitIndex = 1, width = 2, yOffset = 0, zOffset = 0, length = 0.5,
        lineOffset = 0, fillLitersPerSecond = opts.rate or 0.1, active = opts.active ~= false } } }
    if opts.secondUnitLevel ~= nil then
        -- A second node over unit 2 that is inactive and resets (Shovel.lua:186-193).
        v.spec_fillUnit.fillUnits[2] = { fillLevel = opts.secondUnitLevel, capacity = 1000, fillType = opts.secondUnitLevel > 0 and WHEAT or FillType.UNKNOWN,
            lastValidFillType = WHEAT, supportedFillTypes = { [WHEAT] = true, [BARLEY] = true } }
        v.spec_shovel.shovelNodes[2] = { node = { x = at.x, y = 0, z = at.z }, fillUnitIndex = 2, width = 2, yOffset = 0, zOffset = 0, length = 0.5,
            lineOffset = 0, fillLitersPerSecond = 0, active = false, resetFillLevel = true }
    end
    v.eventListeners = { onUpdateTick = { Shovel }, onPostLoad = { ENGINE_FILLUNIT } }
    return v
end

-- The mission's tire track system (TireTrackSystem is C; its id is all the util reads).
ENGINE_TIRE_TRACKS = { tireTrackSystemId = 5 }

-- The classes as the game defines them before a mod is sourced.
ENGINE_LOAD_LEVELER()
ENGINE_LOAD_SHOVEL()
