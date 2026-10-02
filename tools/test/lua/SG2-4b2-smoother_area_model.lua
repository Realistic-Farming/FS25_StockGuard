-- SG2-4b2-smoother_area_model.lua - the smoothing brush and the polygon methods the SG2-4b2
-- bench runs against.
--
-- NOT A TEST. A bar lists it FIFTH in --!load, right after SG2-4b-ground_model.lua, and
-- before any StockGuard file. VERBATIM and MODELED as in that file: VERBATIM bodies follow
-- D:\FS25_Decoded\dataS\scripts_decompiled (1.24.0.0) at the cited lines through every
-- quantity they touch, names restored; MODELED bodies stand in for C functions.

local WHEAT = ENGINE_FT.WHEAT

-- ── the height types' collision constants (MODELED) ─────────────────────────────
-- WheelDestruction.smoothHeightAtPosition (:107-121) reads them; one value for every type.
for _, ht in pairs(g_densityMapHeightManager.heightTypes) do
    ht.collisionScale, ht.minCollisionOffset, ht.maxCollisionOffset = 1, 0, 2
end

-- ── smoothDensityMapHeightAtWorldPos (C, MODELED) ───────────────────────────────
-- Lua does not show what the C++ brush does (SG-2 :219, :235). The model moves raw units of
-- the brush's type inside its radius: each move takes one unit from the highest core pixel
-- (centre within `radius`) holding at least two and gives it to the lowest core pixel of
-- that type or empty (a fringe pixel, centre within `outerRadius` but not `radius`, when
-- ENGINE_SMOOTH.fringe). Knobs for fault rows:
--   moves    unit moves per call
--   fromFringe  each move takes its unit from the highest FRINGE pixel instead
--   loseRaw  units taken from the highest core pixel and placed nowhere (a shortage)
--   gainRaw  units added to the lowest core pixel from nowhere (a surplus)
--   typeTo   the height type the receiving pixel is written with (a type change)
--   error    a message the call throws after its write
ENGINE_SMOOTH = {}
function ENGINE_SMOOTH.reset()
    ENGINE_SMOOTH.log, ENGINE_SMOOTH.moves, ENGINE_SMOOTH.loseRaw, ENGINE_SMOOTH.gainRaw = {}, 1, 0, 0
    ENGINE_SMOOTH.typeTo, ENGINE_SMOOTH.fringe, ENGINE_SMOOTH.fromFringe, ENGINE_SMOOTH.error = nil, false, false, nil
end
ENGINE_SMOOTH.reset()
local function key(x, z) return ENGINE_GROUND.key(x, z) end
function smoothDensityMapHeightAtWorldPos(updater, x, y, z, smoothAmount, heightTypeIndex, minRadius, radius, outerRadius, tireTrackSystemId)
    ENGINE_GROUND.smoothCalls = ENGINE_GROUND.smoothCalls + 1
    ENGINE_SMOOTH.log[#ENGINE_SMOOTH.log + 1] = { x = x, z = z, amount = smoothAmount, heightTypeIndex = heightTypeIndex, minRadius = minRadius, radius = radius, outerRadius = outerRadius }
    local core, fringe = {}, {}
    local x0, z0 = ENGINE_GROUND.cellOf(x - outerRadius, z - outerRadius)
    local x1, z1 = ENGINE_GROUND.cellOf(x + outerRadius, z + outerRadius)
    for pz = z0, z1 do
        for px = x0, x1 do
            local cx, cz = ENGINE_GROUND.centre(px, pz)
            local d = math.sqrt((cx - x) ^ 2 + (cz - z) ^ 2)
            if d <= radius then core[#core + 1] = { x = px, z = pz, d = d }
            elseif d <= outerRadius then fringe[#fringe + 1] = { x = px, z = pz, d = d } end
        end
    end
    local function order(list) table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end if a.z ~= b.z then return a.z < b.z end return a.x < b.x end) end
    order(core) order(fringe)
    local function raw(c) return ENGINE_GROUND.heights[key(c.x, c.z)] or 0 end
    local function kind(c) return ENGINE_GROUND.types[key(c.x, c.z)] or 0 end
    local function highest(list)
        local best = nil
        for _, c in ipairs(list or core) do if kind(c) == heightTypeIndex and raw(c) >= 2 and (best == nil or raw(c) > raw(best)) then best = c end end
        return best
    end
    local function lowest(list, except)
        local best = nil
        for _, c in ipairs(list) do
            if c ~= except and (raw(c) == 0 or kind(c) == heightTypeIndex) and (best == nil or raw(c) < raw(best)) then best = c end
        end
        return best
    end
    for _ = 1, ENGINE_SMOOTH.moves do
        local src = highest(ENGINE_SMOOTH.fromFringe and fringe or core)
        local dst = src ~= nil and lowest(ENGINE_SMOOTH.fringe and fringe or core, src) or nil
        if src == nil or dst == nil then break end
        local ks, kd = key(src.x, src.z), key(dst.x, dst.z)
        ENGINE_GROUND.heights[ks] = raw(src) - 1
        ENGINE_GROUND.heights[kd], ENGINE_GROUND.types[kd] = raw(dst) + 1, ENGINE_SMOOTH.typeTo or heightTypeIndex
    end
    if ENGINE_SMOOTH.loseRaw > 0 then
        local src = highest()
        if src ~= nil then
            local k = key(src.x, src.z)
            local left = raw(src) - ENGINE_SMOOTH.loseRaw
            ENGINE_GROUND.heights[k] = left > 0 and left or nil
            if left <= 0 then ENGINE_GROUND.types[k] = nil end
        end
    end
    if ENGINE_SMOOTH.gainRaw > 0 then
        local dst = lowest(core, nil)
        if dst ~= nil then
            local k = key(dst.x, dst.z)
            ENGINE_GROUND.heights[k], ENGINE_GROUND.types[k] = raw(dst) + ENGINE_SMOOTH.gainRaw, heightTypeIndex
        end
    end
    if ENGINE_SMOOTH.error ~= nil then error(ENGINE_SMOOTH.error, 0) end
end

-- ── Shovel, with its smoothing (vehicles/specializations/Shovel.lua) ──────────────
-- SG2-4b's model gives the pickup (:141-195). This adds :196-217 VERBATIM, names restored
-- (the decompile reuses fillLevel/capacity/freeCapacity for the node's world direction and
-- minValidLiter for the smooth amount), run after the node loop's pickup; with the bench's
-- one active node that is native's order, the pickup line (:170) and credit (:178) then the
-- brush (:212).
local loadShovelPickup = ENGINE_LOAD_SHOVEL
function ENGINE_LOAD_SHOVEL()
    loadShovelPickup()
    local pickup = Shovel.onUpdateTick
    function Shovel:onUpdateTick(dt, ...)
        pickup(self, dt, ...)
        local spec = self.spec_shovel
        if self.isServer then
            for _, shovelNode in pairs(spec.shovelNodes) do
                if shovelNode.allowsSmoothing then
                    local _, dirY, _ = localDirectionToWorld(shovelNode.node, 0, 0, 1)
                    if math.acos(dirY) > shovelNode.maxPickupAngle then
                        local smoothAmount = 0
                        if self.lastSpeedReal > 0.0002 then
                            smoothAmount = spec.smoothAccumulation + math.max(self.lastMovedDistance * 0.5, 0.0003 * dt)
                            spec.smoothAccumulation = smoothAmount - DensityMapHeightUtil.getRoundedHeightValue(smoothAmount)
                        else
                            spec.smoothAccumulation = 0
                        end
                        if smoothAmount > 0 then
                            DensityMapHeightUtil.smoothAroundLine(shovelNode.node, shovelNode.width, shovelNode.smoothGroundRadius, shovelNode.smoothOverlap, smoothAmount, true)
                        end
                    end
                end
            end
        end
    end
end
local newShovel = ENGINE_NEW_SHOVEL
--- A front loader shovel as SG2-4b builds it; opts.smooth adds the smoothing node fields.
function ENGINE_NEW_SHOVEL(uid, opts)
    local v = newShovel(uid, opts)
    opts = opts or {}
    v.lastSpeedReal, v.lastMovedDistance = 0.01, 0.4
    v.spec_shovel.smoothAccumulation = 0
    for _, node in ipairs(v.spec_shovel.shovelNodes) do
        node.allowsSmoothing, node.maxPickupAngle = opts.smooth == true, 0.5
        node.smoothGroundRadius, node.smoothOverlap = 0.5, 1.5
    end
    return v
end
--- :410-415 VERBATIM (the manager's heightToDensityValue MODELED as 100 per metre).
g_densityMapHeightManager.heightToDensityValue = 100
function DensityMapHeightUtil.getRoundedHeightValue(height)
    if not g_densityMapHeightManager:getIsValid() then
        return height
    end
    return math.floor(height * g_densityMapHeightManager.heightToDensityValue) / g_densityMapHeightManager.heightToDensityValue
end

-- ── WheelDestruction (vehicles/wheels/WheelDestruction.lua) ──────────────────────
-- Sourced through Wheel.lua:7 from the specialization Wheels.lua:10, so a new class table
-- with every map load. update (:35-80) calls self:smoothHeightAtPosition, resolved on the
-- class at call time; ENGINE_WHEEL_SMOOTH makes that call.
function ENGINE_LOAD_WHEELDESTRUCTION()
    WheelDestruction = {}
    WheelDestruction.MAX_UPDATE_DISTANCE = 40
    --- :3-12 VERBATIM.
    function WheelDestruction.new(wheel)
        local self = setmetatable({}, { __index = WheelDestruction })
        self.wheel = wheel
        self.vehicle = wheel.vehicle
        self.destructionNodes = {}
        self.wheelSmoothAccumulation = 0
        return self
    end
    --- :107-121 VERBATIM, the debug drawing (:118-120) left out.
    function WheelDestruction.smoothHeightAtPosition(_, x, y, z, radius, amount)
        local heightType = DensityMapHeightUtil.getHeightTypeDescAtWorldPos(x, y, z, radius)
        if heightType ~= nil and heightType.allowsSmoothing then
            local terrainHeightUpdater = g_densityMapHeightManager:getTerrainDetailHeightUpdater()
            if terrainHeightUpdater ~= nil then
                local terrainHeight = getTerrainHeightAtWorldPos(g_terrainNode, x, y, z)
                local physicsDeltaHeight = y - terrainHeight
                local internalHeight = terrainHeight + math.max(math.min(math.max((physicsDeltaHeight + heightType.collisionBaseOffset) / heightType.collisionScale, physicsDeltaHeight + heightType.minCollisionOffset), physicsDeltaHeight + heightType.maxCollisionOffset) + -0.1, 0)
                smoothDensityMapHeightAtWorldPos(terrainHeightUpdater, x, internalHeight, z, amount, heightType.index, 0, radius, radius + 1.2, 0)
            end
        end
    end
end
ENGINE_LOAD_WHEELDESTRUCTION()
function ENGINE_NEW_WHEEL(vehicle)
    local wd = WheelDestruction.new({ vehicle = vehicle })
    wd.smoothGroundRadius = 0.5
    return wd
end
--- One wheel brush as WheelDestruction:update makes it (:80), through self.
function ENGINE_WHEEL_SMOOTH(wd, x, z, amount) return wd:smoothHeightAtPosition(x, 0.5, z, wd.smoothGroundRadius, amount or 0.01) end

-- ── DensityMapHeightUtil's other polygon methods ─────────────────────────────────
--- :335-361 VERBATIM.
function DensityMapHeightUtil.changeFillTypeAtArea(x0, z0, x1, z1, x2, z2, fillTypeIndex, newFillTypeIndex)
    if not g_densityMapHeightManager:getIsValid() then
        return 0
    end
    local heightType = g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex)
    local newHeightType = g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(newFillTypeIndex)
    if heightType == nil or newHeightType == nil then
        return 0
    end
    local modifiers = DensityMapHeightUtil.modifiersCache.changeFillTypeAtArea
    if modifiers == nil then
        modifiers = {
            ["typeModifier"] = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.typeFirstChannel, DensityMapHeightUtil.typeNumChannels),
            ["typeFilters"] = {}
        }
        DensityMapHeightUtil.modifiersCache.changeFillTypeAtArea = modifiers
    end
    local typeFilter = modifiers.typeFilters[heightType]
    if typeFilter == nil then
        typeFilter = DensityMapFilter.new(modifiers.typeModifier)
        typeFilter:setValueCompareParams(DensityValueCompareType.EQUAL, heightType.index)
        modifiers.typeFilters[heightType] = typeFilter
    end
    local typeModifier = modifiers.typeModifier
    typeModifier:setParallelogramWorldCoords(x0, z0, x1, z1, x2, z2, DensityCoordType.POINT_POINT_POINT)
    return typeModifier:executeSetWithStats(newHeightType.index, typeFilter) * g_densityMapHeightManager:getMinValidLiterValue(fillTypeIndex)
end
--- :362-377 VERBATIM.
function DensityMapHeightUtil.clearArea(x0, z0, x1, z1, x2, z2)
    local modifiers = DensityMapHeightUtil.modifiersCache.clearArea
    if modifiers == nil then
        modifiers = {
            ["heightModifier"] = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.heightFirstChannel, DensityMapHeightUtil.heightNumChannels),
            ["typeModifier"] = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.typeFirstChannel, DensityMapHeightUtil.typeNumChannels)
        }
        DensityMapHeightUtil.modifiersCache.clearArea = modifiers
    end
    local heightModifier = modifiers.heightModifier
    local typeModifier = modifiers.typeModifier
    heightModifier:setParallelogramWorldCoords(x0, z0, x1, z1, x2, z2, DensityCoordType.POINT_POINT_POINT)
    typeModifier:setParallelogramWorldCoords(x0, z0, x1, z1, x2, z2, DensityCoordType.POINT_POINT_POINT)
    heightModifier:executeSet(0)
    typeModifier:executeSet(0)
end
--- :385-402 VERBATIM.
function DensityMapHeightUtil.clear(area)
    local modifiers = DensityMapHeightUtil.modifiersCache.clearArea
    if modifiers == nil then
        modifiers = {
            ["heightModifier"] = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.heightFirstChannel, DensityMapHeightUtil.heightNumChannels),
            ["typeModifier"] = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.typeFirstChannel, DensityMapHeightUtil.typeNumChannels)
        }
        DensityMapHeightUtil.modifiersCache.clearArea = modifiers
    end
    local heightModifier = modifiers.heightModifier
    local typeModifier = modifiers.typeModifier
    area:applyToModifier(heightModifier)
    area:applyToModifier(typeModifier)
    heightModifier:executeSet(0)
    typeModifier:executeSet(0)
    heightModifier:clearPolygonPoints()
    typeModifier:clearPolygonPoints()
end
function DensityMapModifier:clearPolygonPoints() self.poly = nil end

-- ── DensityMapCircle (densityMaps/DensityMapCircle.lua) ──────────────────────────
-- The fields :6-10 VERBATIM; createCircle and applyToModifier MODELED: the circle reaches
-- the modifier as its bounding square (the C polygon of numSegments points is not modeled).
DensityMapCircle = DensityMapCircle or {}
DensityMapCircle.__index = DensityMapCircle
function DensityMapCircle.createCircle(worldPosX, worldPosZ, radius, numSegments)
    return setmetatable({ worldPosX = worldPosX, worldPosZ = worldPosZ, radius = radius, numSegments = numSegments, points = {} }, DensityMapCircle)
end
function DensityMapCircle:applyToModifier(modifier)
    local r = self.radius
    modifier:setParallelogramWorldCoords(self.worldPosX - r, self.worldPosZ - r, self.worldPosX + r, self.worldPosZ - r, self.worldPosX - r, self.worldPosZ + r, DensityCoordType.POINT_POINT_POINT)
end

-- ── the callers ──────────────────────────────────────────────────────────────────
--- FSDensityMapUtil.updateCultivatorArea (:688-748) reduced to its height clear (:746,
--- VERBATIM): the foliage and ground-type work before it touches no height.
function FSDensityMapUtil.updateCultivatorArea(startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
    DensityMapHeightUtil.clearArea(startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
end

-- The silage fill types a bunker converts between (indices MODELED).
ENGINE_FT.CHAFF, ENGINE_FT.FERMENTING, ENGINE_FT.SILAGE = 9, 10, 11
FillType.CHAFF, FillType.FERMENTING, FillType.SILAGE = 9, 10, 11
do
    local names = { [9] = "CHAFF", [10] = "FERMENTING", [11] = "SILAGE" }
    local byIndex, byName = g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager.getFillTypeIndexByName
    g_fillTypeManager.getFillTypeNameByIndex = function(m, i) return names[i] or byIndex(m, i) end
    g_fillTypeManager.getFillTypeIndexByName = function(m, n) for i, v in pairs(names) do if v == n then return i end end return byName(m, n) end
    for i, n in pairs(names) do
        local ht = { index = #g_densityMapHeightManager.heightTypes + 1, fillTypeIndex = i, fillTypeName = n, maxSurfaceAngle = math.rad(45), fillToGroundScale = 1,
                     canBeTipped = true, allowsSmoothing = true, collisionBaseOffset = 0, collisionScale = 1, minCollisionOffset = 0, maxCollisionOffset = 2 }
        g_densityMapHeightManager.heightTypes[ht.index] = ht
        g_densityMapHeightManager.fillTypeIndexToHeightType[i] = ht
        g_densityMapHeightManager.fillTypeNameToHeightType[n] = ht
        ENGINE_HT[n] = ht
    end
end

-- BunkerSilo (objects/BunkerSilo.lua), reduced to the polygon calls of each path.
BunkerSilo = BunkerSilo or {}
BunkerSilo.__index = BunkerSilo
BunkerSilo.STATE_FILL, BunkerSilo.STATE_CLOSED, BunkerSilo.STATE_FERMENTED, BunkerSilo.STATE_DRAIN = 0, 1, 2, 3
--- A silo over the world box [x0, x1) x [z0, z1), filled with `input`, fermenting into
--- `fermenting`, fermented into `output`.
function ENGINE_NEW_BUNKER(x0, z0, x1, z1, input, fermenting, output)
    local area = { sx = x0, sz = z0, wx = x1, wz = z0, hx = x0, hz = z1,
                   start = { x = x0, y = 0, z = z0 }, width = { x = x1, y = 0, z = z0 }, height = { x = x0, y = 0, z = z1 } }
    return setmetatable({ bunkerSiloArea = area, inputFillType = input, fermentingFillType = fermenting, outputFillType = output,
                          state = BunkerSilo.STATE_FILL, isServer = true }, BunkerSilo)
end
--- loadFromXMLFile (:237-296): the restore's polygon calls in a FERMENTED silo, :285-286 and
--- :290 VERBATIM (the fill-level test before :285 and the XML reads reduced to `emptied`).
function BunkerSilo:loadFromXMLFile(emptied)
    local area = self.bunkerSiloArea
    if emptied then
        DensityMapHeightUtil.removeFromGroundByArea(area.sx, area.sz, area.wx, area.wz, area.hx, area.hz, self.fermentingFillType)
        DensityMapHeightUtil.removeFromGroundByArea(area.sx, area.sz, area.wx, area.wz, area.hx, area.hz, self.outputFillType)
    end
    DensityMapHeightUtil.changeFillTypeAtArea(area.sx, area.sz, area.wx, area.wz, area.hx, area.hz, self.inputFillType, self.outputFillType)
end
--- updateFillLevel (:399-418) in the DRAIN state below the threshold: :412-413 VERBATIM.
function BunkerSilo:drainResidue()
    local area = self.bunkerSiloArea
    DensityMapHeightUtil.removeFromGroundByArea(area.sx, area.sz, area.wx, area.wz, area.hx, area.hz, self.fermentingFillType)
    DensityMapHeightUtil.removeFromGroundByArea(area.sx, area.sz, area.wx, area.wz, area.hx, area.hz, self.outputFillType)
    self.state = BunkerSilo.STATE_FILL
end
--- setState to CLOSED (:420-460): :448 VERBATIM over the whole area (the front and back
--- offsets, :439-446, reduced to 0).
function BunkerSilo:close()
    local area = self.bunkerSiloArea
    if self.isServer then
        DensityMapHeightUtil.changeFillTypeAtArea(area.sx, area.sz, area.wx, area.wz, area.hx, area.hz, self.inputFillType, self.fermentingFillType)
    end
    self.state = BunkerSilo.STATE_CLOSED
end
--- :580-585 VERBATIM.
function BunkerSilo:clearSiloArea()
    local xs, _, zs = getWorldTranslation(self.bunkerSiloArea.start)
    local xw, _, zw = getWorldTranslation(self.bunkerSiloArea.width)
    local xh, _, zh = getWorldTranslation(self.bunkerSiloArea.height)
    DensityMapHeightUtil.clearArea(xs, zs, xw, zw, xh, zh)
end

-- The classes as the game defines them before a mod is sourced (the Shovel again, now with
-- its smoothing).
ENGINE_LOAD_SHOVEL()
