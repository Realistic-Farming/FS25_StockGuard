-- =========================================================
-- FS25_StockGuard - the ground cell sampler (SG2-4b)
-- =========================================================
-- SG-2 v2.3 :164. The one reader of native ground material: a terrain-height pixel's
-- type and quantity, read with the construction the engine's own area reader uses
-- (DensityMapHeightUtil.getFillLevelAtArea, :80-109): dedicated type- and height-channel
-- DensityMapModifiers with NEAREST_EXPAND polygon rounding, a positive-height filter and
-- a per-type filter, and litres as raw height times the type's live
-- getMinValidLiterValue (DensityMapHeightManager.lua:498-501).
--
-- THE GRID. Pixel (x, z) of the height layer spans world
-- [x * p - T/2, (x + 1) * p - T/2] on each axis, with p = terrainSize / getDensityMapSize
-- (DensityMapHeightManager.lua:358-359 derives the same pitch; DebugDensityMap.lua:37-52
-- draws pixel boundaries at multiples of it). A read uses a square inset 0.1 pixel on
-- every side, strictly inside the intended pixel (the DebugDensityMap coordinate
-- precedent; only the construction, not its rounding mode).
--
-- ONE PIXEL, PROVED. Every read requires totalNumPixels == 1 on the type channels and on
-- the height channels; the positive-height count must agree with the raw height; an
-- occupied pixel's type index must resolve through the height manager, and the same
-- polygon queried with that exact type and the positive-height filter must answer one
-- matching pixel. An empty pixel answers zero. A failure is a refused read with its
-- reason: the cell is never guessed, a neighbour is never summed, an unknown index is
-- never accepted. These counts prove the sampled cardinality, not the engine's C++
-- coordinate identity; the grid transform stays an in-game observation (:164).
--
-- AN EMPTY BLOCK IS PROVED WITH ONE QUERY. The inset of a block of pixels answers its
-- positive-height count; with totalNumPixels equal to the block size and a count of 0,
-- every pixel in it is empty. A block holding material is split in four until each
-- occupied pixel is read on its own, so the grain and the result never change (:237).
--
-- NOT A POLLER. Nothing here scans the world: a caller names the pixels (an operation's
-- envelope) and this reads them.
-- =========================================================

SGGroundSampler = SGGroundSampler or {}
local GS = SGGroundSampler
local GS_mt = { __index = GS }

GS.INSET = 0.1            -- of a pixel, on every side
GS.MAX_CELLS = 16384      -- the largest envelope an operation may declare
-- The grid and scale proofs whose failure means this binding cannot claim support (:164,
-- :257): the first one met on ANY read path (the observer's envelopes, the adapter's
-- refreshCarrier, the save boundary's re-read) latches the sampler for the session.
GS.LATCHING = { CARDINALITY = true, INCONSISTENT = true, SAMPLE = true, SCALE = true, TYPE_UNVERIFIED = true }

local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function isInteger(n) return isFinite(n) and math.floor(n) == n end

--- Bind to the mission's height layer. Returns the sampler, or nil and a reason.
function GS.bind(mission)
    mission = mission or g_currentMission
    local hm = g_densityMapHeightManager
    if mission == nil then return nil, "NO_MISSION" end
    if hm == nil or type(hm.getIsValid) ~= "function" or not hm:getIsValid() then return nil, "NO_HEIGHT_MANAGER" end
    if DensityMapModifier == nil or DensityMapFilter == nil or DensityRoundingMode == nil or DensityCoordType == nil or DensityValueCompareType == nil then
        return nil, "NO_MODIFIER_API"
    end
    local identity, why = SGGround.currentIdentity(mission)
    if identity == nil then return nil, why end
    local id = identity.heightId
    local size = getDensityMapSize(id)
    local terrainSize = mission.terrainSize
    if not isInteger(size) or size <= 0 or not isFinite(terrainSize) or terrainSize <= 0 then return nil, "NO_GRID" end
    local heightFirst, heightNum = getDensityMapHeightFirstChannel(id), getDensityMapHeightNumChannels(id)
    local typeFirst, typeNum = hm.heightTypeFirstChannel, hm.heightTypeNumChannels
    if not isInteger(heightFirst) or not isInteger(heightNum) or not isInteger(typeFirst) or not isInteger(typeNum) then return nil, "NO_CHANNELS" end

    local self = setmetatable({}, GS_mt)
    self.identity = identity
    self.heightId = id
    self.size = size
    self.terrainSize = terrainSize
    self.pitch = terrainSize / size
    self.half = terrainSize * 0.5
    self.typeFirst, self.typeNum = typeFirst, typeNum
    self.heightModifier = DensityMapModifier.new(id, heightFirst, heightNum)
    self.heightModifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST_EXPAND)
    self.typeModifier = DensityMapModifier.new(id, typeFirst, typeNum)
    self.typeModifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST_EXPAND)
    self.heightFilter = DensityMapFilter.new(self.heightModifier)
    self.heightFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    self.typeFilters = {}
    self.reads = 0            -- single-pixel reads, for the in-game cost observation
    self.blockProofs = 0      -- empty blocks proved with one query
    return self
end

--- A refused read. A grid or scale proof failure latches the binding (GS.LATCHING); a read
--- refused for its own reasons (out of the map, an unknown type index) does not.
function GS:refuse(reason)
    if self.fault == nil and GS.LATCHING[reason] then
        self.fault = { reason = reason }
        self.faultQualified = {}
    end
    return nil, reason
end

--- The filter on one height type's index, as getFillLevelAtArea builds it (:102-104).
function GS:typeFilterOf(heightType)
    local f = self.typeFilters[heightType.index]
    if f == nil then
        f = DensityMapFilter.new(self.heightId, self.typeFirst, self.typeNum)
        f:setValueCompareParams(DensityValueCompareType.EQUAL, heightType.index)
        self.typeFilters[heightType.index] = f
    end
    return f
end

--- The inset parallelogram over pixels [x0, x0 + nx - 1] x [z0, z0 + nz - 1], as
--- start, width and height points (DensityCoordType.POINT_POINT_POINT).
function GS:polygon(x0, z0, nx, nz)
    local p, h = self.pitch, self.half
    local inset = GS.INSET * p
    local ax, az = x0 * p - h + inset, z0 * p - h + inset
    local bx, bz = (x0 + nx) * p - h - inset, (z0 + nz) * p - h - inset
    return ax, az, bx, az, ax, bz
end

function GS:inMap(x, z)
    return isInteger(x) and isInteger(z) and x >= 0 and z >= 0 and x < self.size and z < self.size
end

--- The pixel a world position falls in.
function GS:cellOfWorld(wx, wz)
    return math.floor((wx + self.half) / self.pitch), math.floor((wz + self.half) / self.pitch)
end

--- The world centre of a pixel.
function GS:cellCentre(x, z)
    return (x + 0.5) * self.pitch - self.half, (z + 0.5) * self.pitch - self.half
end

local function set(modifier, ax, az, bx, bz, cx, cz)
    modifier:setParallelogramWorldCoords(ax, az, bx, bz, cx, cz, DensityCoordType.POINT_POINT_POINT)
end

--- Read one pixel. Returns { x, z, raw, liters, fillTypeIndex?, fillTypeName? } (no
--- fill type when empty), or nil and a reason.
function GS:readCell(x, z)
    -- A latched binding reads nothing more through its faulted grid (:261, "disable ... for
    -- the exact failing adapter binding").
    if self.fault ~= nil then return nil, "BINDING_FAULT" end
    if not self:inMap(x, z) then return self:refuse("OUT_OF_MAP") end
    self.reads = self.reads + 1
    local ax, az, bx, bz, cx, cz = self:polygon(x, z, 1, 1)
    set(self.typeModifier, ax, az, bx, bz, cx, cz)
    local typeValue, _, typeTotal = self.typeModifier:executeGet()
    if typeTotal ~= 1 then return self:refuse("CARDINALITY") end
    set(self.heightModifier, ax, az, bx, bz, cx, cz)
    local raw, _, heightTotal = self.heightModifier:executeGet()
    if heightTotal ~= 1 then return self:refuse("CARDINALITY") end
    if not isInteger(raw) or raw < 0 or not isInteger(typeValue) or typeValue < 0 then return self:refuse("SAMPLE") end
    local _, positive, positiveTotal = self.heightModifier:executeGet(self.heightFilter)
    if positiveTotal ~= 1 then return self:refuse("CARDINALITY") end
    local hm = g_densityMapHeightManager
    local heightType = hm:getDensityMapHeightTypeByIndex(typeValue)
    if raw == 0 then
        if positive ~= 0 then return self:refuse("INCONSISTENT") end
        if heightType ~= nil then
            local _, typed, typedTotal = self.heightModifier:executeGet(self.heightFilter, self:typeFilterOf(heightType))
            if typedTotal ~= 1 or typed ~= 0 then return self:refuse("TYPE_UNVERIFIED") end
        end
        return { x = x, z = z, raw = 0, liters = 0 }
    end
    if positive ~= 1 then return self:refuse("INCONSISTENT") end
    if heightType == nil or heightType.fillTypeIndex == nil then return self:refuse("UNKNOWN_TYPE_INDEX") end
    local _, typed, typedTotal = self.heightModifier:executeGet(self.heightFilter, self:typeFilterOf(heightType))
    if typedTotal ~= 1 or typed ~= 1 then return self:refuse("TYPE_UNVERIFIED") end
    local name = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(heightType.fillTypeIndex) or nil
    if type(name) ~= "string" or name == "" then return self:refuse("FILL_TYPE_UNNAMED") end
    local perRaw = hm:getMinValidLiterValue(heightType.fillTypeIndex)
    if not isFinite(perRaw) or perRaw <= 0 then return self:refuse("SCALE") end
    return { x = x, z = z, raw = raw, liters = raw * perRaw, fillTypeIndex = heightType.fillTypeIndex, fillTypeName = name }
end

--- Is every pixel of the block empty? True, false, or nil and a reason.
function GS:blockEmpty(x0, z0, nx, nz)
    if self.fault ~= nil then return nil, "BINDING_FAULT" end
    local ax, az, bx, bz, cx, cz = self:polygon(x0, z0, nx, nz)
    set(self.heightModifier, ax, az, bx, bz, cx, cz)
    local _, positive, total = self.heightModifier:executeGet(self.heightFilter)
    if total ~= nx * nz then return self:refuse("CARDINALITY") end
    self.blockProofs = self.blockProofs + 1
    return positive == 0
end

--- The occupied pixels of an inclusive pixel rectangle: key -> cell. Empty pixels are
--- absent. Returns nil and a reason on the first refused read.
function GS:sampleRect(x0, z0, x1, z1)
    local out = {}
    local function visit(bx0, bz0, bx1, bz1)
        local nx, nz = bx1 - bx0 + 1, bz1 - bz0 + 1
        if nx <= 0 or nz <= 0 then return true end
        if nx == 1 and nz == 1 then
            local cell, why = self:readCell(bx0, bz0)
            if cell == nil then return nil, why end
            if cell.raw > 0 then out[SGGround.cellKey(bx0, bz0)] = cell end
            return true
        end
        local empty, why = self:blockEmpty(bx0, bz0, nx, nz)
        if empty == nil then return nil, why end
        if empty then return true end
        local mx = bx0 + math.floor((nx - 1) / 2)
        local mz = bz0 + math.floor((nz - 1) / 2)
        local parts
        if nx > 1 and nz > 1 then
            parts = { { bx0, bz0, mx, mz }, { mx + 1, bz0, bx1, mz }, { bx0, mz + 1, mx, bz1 }, { mx + 1, mz + 1, bx1, bz1 } }
        elseif nx > 1 then
            parts = { { bx0, bz0, mx, bz1 }, { mx + 1, bz0, bx1, bz1 } }
        else
            parts = { { bx0, bz0, bx1, mz }, { bx0, mz + 1, bx1, bz1 } }
        end
        for _, q in ipairs(parts) do
            local ok, whyQ = visit(q[1], q[2], q[3], q[4])
            if not ok then return nil, whyQ end
        end
        return true
    end
    local ok, why = visit(x0, z0, x1, z1)
    if not ok then return nil, why end
    return out
end

--- The envelope of an elementary line primitive: the bounding box of the resolved
--- segment widened by its resolved inner AND outer radius together, plus one complete pixel
--- of edge margin, clipped to the map (:164, :235, :257). Whether the native write reaches
--- the outer radius or inner plus outer from the line is engine C code no reference
--- documents; the sum is a superset under either reading, so it is the conservative
--- envelope :257 asks for. Returns x0, z0, x1, z1 (inclusive), or nil and a reason. An
--- envelope larger than MAX_CELLS is not a finite supported envelope.
function GS:lineEnvelope(sx, sz, ex, ez, innerRadius, radius)
    if not (isFinite(sx) and isFinite(sz) and isFinite(ex) and isFinite(ez)) then return nil, "LINE" end
    if not isFinite(radius) or radius < 0 then return nil, "RADIUS" end
    local inner = isFinite(innerRadius) and math.max(0, innerRadius) or 0
    local r = inner + radius
    local x0, z0 = self:cellOfWorld(math.min(sx, ex) - r, math.min(sz, ez) - r)
    local x1, z1 = self:cellOfWorld(math.max(sx, ex) + r, math.max(sz, ez) + r)
    x0, z0 = math.max(0, x0 - 1), math.max(0, z0 - 1)
    x1, z1 = math.min(self.size - 1, x1 + 1), math.min(self.size - 1, z1 + 1)
    if x1 < x0 or z1 < z0 then return nil, "OFF_MAP" end
    if (x1 - x0 + 1) * (z1 - z0 + 1) > GS.MAX_CELLS then return nil, "ENVELOPE_TOO_LARGE" end
    return x0, z0, x1, z1
end
