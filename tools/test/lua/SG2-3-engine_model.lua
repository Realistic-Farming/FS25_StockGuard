-- SG2-3-engine_model.lua - the harvest engine the SG2-3 bench runs against.
--
-- NOT A TEST. A bar lists it SECOND in --!load, after SG2-2-engine_model.lua (whose
-- storage, station, discharge and system classes it keeps) and before any StockGuard
-- file, as the game defines its classes before a mod's source().
--
-- Bodies marked VERBATIM follow D:\FS25_Decoded\dataS\scripts_decompiled at the cited
-- lines through every quantity they touch; presentation (effects, sounds, dirty flags,
-- statistics) is abbreviated and said so. Bodies marked MODELED stand in for engine
-- code with no usable Lua body: the fruit density plane and cutFruitArea's accumulators
-- are C or missing from the decompile (FSDensityMapUtil.lua:154-201 omits them, SG-2
-- :503), and Combine:addCutterArea's decompile reuses five names for different locals.

ENGINE_FT.STRAW = 5
local FT_NAMES = { [1] = "WHEAT", [2] = "BARLEY", [4] = "GRASS", [5] = "STRAW" }
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return FT_NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(FT_NAMES) do if v == n then return i end end return nil end,
}

getWorldTranslation = getWorldTranslation or function(node)
    if type(node) == "table" then return node.x or 0, node.y or 0, node.z or 0 end
    return 0, 0, 0
end
MathUtil = MathUtil or {}
MathUtil.areaToHa = MathUtil.areaToHa or function(area, pixelsToSqm) return area * (pixelsToSqm or 1) / 10000 end
AccessHandler = AccessHandler or { EVERYONE = 0 }
g_farmManager = g_farmManager or { updateFarmStats = function() end }

--- FieldChopperType.lua:1-7 VERBATIM (Enum() abbreviated): a chopper type's ground
--- value is the mission's field ground system's.
FieldChopperType = { CHOPPER_STRAW = 1, CHOPPER_MAIZE = 2 }
function FieldChopperType.getValueByType(typeIndex)
    return g_currentMission.fieldGroundSystem:getChopperTypeValue(typeIndex)
end
--- The field ground system MODELED: one density value per chopper type. A spec's
--- mission carries it as fieldGroundSystem.
ENGINE_FIELD_GROUND = { getChopperTypeValue = function(_, typeIndex) return 20 + typeIndex end }

-- ── fruit types (FruitTypeDesc.lua) ─────────────────────────────────────────
FruitType = { UNKNOWN = 0, WHEAT = 11, BARLEY = 12 }
ENGINE_FRUIT = FruitType
-- utils bit32, the Lua 5.1 library the engine's scripts call; written arithmetically
-- because the bench runs Lua 5.3 and the syntax gate parses 5.1.
bit32 = bit32 or {
    rshift = function(a, n) return math.floor(a / 2 ^ n) end,
    band = function(a, b)
        local r, bit = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + bit end
            a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
        end
        return r
    end,
}
local FruitDesc = {}
FruitDesc.__index = FruitDesc
--- FruitTypeDesc.lua:800-802 VERBATIM.
function FruitDesc:getYieldScale(growthState) return self.yieldScales[growthState] or 1 end
--- FruitTypeDesc.lua:794-799 VERBATIM.
function FruitDesc:getGrowthStateByDensityState(state)
    if state == nil then
        return nil
    end
    return bit32.band(bit32.rshift(state, self.startStateChannel), 2 ^ self.numStateChannels - 1)
end
-- The state channels sit at offset 2 in the shared plane, with other bits below them,
-- so a decode that skipped the shift or the mask would read the wrong state.
local DESCS = {
    -- Wheat chops to a ground type (CHOPPER_STRAW); the model's barley stands in for a
    -- haulm crop (no chopper type, chopperUseHaulm), so Combine.lua:983-991 runs both ways.
    [FruitType.WHEAT] = setmetatable({ index = FruitType.WHEAT, name = "WHEAT", fillTypeIndex = ENGINE_FT.WHEAT, windrowFillTypeIndex = ENGINE_FT.STRAW,
        literPerSqm = 1, windrowLiterPerSqm = 1, hasWindrow = true, chopperType = FieldChopperType.CHOPPER_STRAW, chopperUseHaulm = false,
        minHarvestingGrowthState = 3, maxHarvestingGrowthState = 4, minForageGrowthState = 3, cutState = 6,
        harvestTransitions = { [3] = 6, [4] = 6 }, yieldScales = { [3] = 0.5, [4] = 1 }, terrainDataPlaneId = 1,
        densityTypeIndex = 1, startStateChannel = 2, numStateChannels = 3 }, FruitDesc),
    [FruitType.BARLEY] = setmetatable({ index = FruitType.BARLEY, name = "BARLEY", fillTypeIndex = ENGINE_FT.BARLEY, windrowFillTypeIndex = ENGINE_FT.STRAW,
        literPerSqm = 1, windrowLiterPerSqm = 1, hasWindrow = true, chopperType = nil, chopperUseHaulm = true,
        minHarvestingGrowthState = 3, maxHarvestingGrowthState = 4, minForageGrowthState = 3, cutState = 6,
        harvestTransitions = { [3] = 6, [4] = 6 }, yieldScales = { [3] = 0.5, [4] = 1 }, terrainDataPlaneId = 1,
        densityTypeIndex = 2, startStateChannel = 2, numStateChannels = 3 }, FruitDesc),
}
g_fruitTypeManager = {
    -- FruitTypeManager.lua:472 and :491.
    getDefaultDataPlaneId = function() return 1 end,
    getFruitTypeByDensityTypeIndex = function(_, index) for _, d in pairs(DESCS) do if d.densityTypeIndex == index then return d end end return nil end,
    getFruitTypeByIndex = function(_, i) return DESCS[i] end,
    -- FruitTypeManager.lua:220.
    getFruitTypeIndexByName = function(_, name) for i, d in pairs(DESCS) do if d.name == name then return i end end return nil end,
    getFruitTypeByFillTypeIndex = function(_, ft) for _, d in pairs(DESCS) do if d.fillTypeIndex == ft then return d end end return nil end,
    getFruitTypeIndexByFillTypeIndex = function(_, ft) for i, d in pairs(DESCS) do if d.fillTypeIndex == ft then return i end end return nil end,
    getFillTypeIndexByFruitTypeIndex = function(_, i) return DESCS[i] and DESCS[i].fillTypeIndex or nil end,
    getWindrowFillTypeIndexByFruitTypeIndex = function(_, i) return DESCS[i] and DESCS[i].windrowFillTypeIndex or nil end,
    -- FruitTypeManager MODELED: one litre per harvested (scaled) pixel.
    getFruitTypeAreaLiters = function(_, i, area, _useWindrowed) return area * (DESCS[i] and DESCS[i].literPerSqm or 1) end,
    getCutHeightByFruitTypeIndex = function() return 0.1 end,
}

-- ── the fruit density plane (MODELED: C) ──────────────────────────────────────
-- One shared plane of 1 m pixels over a 256 m terrain centred on the origin; a pixel
-- holds one fruit. ENGINE_PLANE.bias adds a constant to cutFruitArea's returned area,
-- for the bar that needs the native's total and the pixels to disagree.
ENGINE_PLANE = { cells = {}, size = 256, bias = 0 }
local function pkey(fruit, px, pz) return fruit .. "|" .. px .. ":" .. pz end
--- Sow `fruit` at growth `state` on every 1 m pixel of the box [x0, x1) x [z0, z1).
function ENGINE_PLANE.sow(fruit, x0, z0, x1, z1, state)
    for px = x0, x1 - 1 do
        for pz = z0, z1 - 1 do
            for other in pairs(DESCS) do ENGINE_PLANE.cells[pkey(other, px, pz)] = nil end
            ENGINE_PLANE.cells[pkey(fruit, px, pz)] = state
        end
    end
end
function ENGINE_PLANE.state(fruit, px, pz) return ENGINE_PLANE.cells[pkey(fruit, px, pz)] end
local function fruitAt(px, pz)
    for index in pairs(DESCS) do
        local s = ENGINE_PLANE.cells[pkey(index, px, pz)]
        if s ~= nil then return DESCS[index], s end
    end
    return nil, nil
end
-- Engine functions (C, MODELED), their contracts per the LUADOC's Terrain Detail pages.
function getDensityMapSize(_plane) return ENGINE_PLANE.size end
function getDensityTypeIndexAtWorldPos(_plane, x, _y, z)
    local desc = fruitAt(math.floor(x), math.floor(z))
    return desc ~= nil and desc.densityTypeIndex or 0
end
function getDensityStatesAtWorldPos(_plane, x, _y, z)
    local desc, state = fruitAt(math.floor(x), math.floor(z))
    if desc == nil then return 0 end
    return state * 2 ^ desc.startStateChannel + 1   -- the low bit stands for an unrelated channel
end

FSDensityMapUtil = FSDensityMapUtil or {}
--- FSDensityMapUtil.lua:22-201 MODELED. Kept: the per-state harvest transitions of
--- every pixel between the min and max harvesting states inside the envelope, the
--- returned SCALED area (each harvested pixel times its state's yield scale, the
--- accumulator the decompile omits), the total, the dominant state and its count. The
--- spray, plow, lime, weed, stubble and roller factors are 1: the harvest multiplier
--- they feed is the mission's (held at 1 by the bench).
function FSDensityMapUtil.cutFruitArea(fruitIndex, sx, sz, wx, wz, hx, hz, _destroySpray, useMinForageState, _excluded, _, _limitToField)
    if ENGINE_PLANE.throwNext then
        ENGINE_PLANE.throwNext = false
        error("native cut failed")
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if desc == nil or desc.terrainDataPlaneId == nil or desc.cutState == 0 then return 0 end
    local minState = useMinForageState and desc.minForageGrowthState or desc.minHarvestingGrowthState
    local x0, x1 = math.min(sx, wx, hx), math.max(sx, wx, hx)
    local z0, z1 = math.min(sz, wz, hz), math.max(sz, wz, hz)
    local scaled, total, byState = 0, 0, {}
    for px = math.floor(x0), math.ceil(x1) - 1 do
        for pz = math.floor(z0), math.ceil(z1) - 1 do
            local cx, cz = px + 0.5, pz + 0.5
            if cx >= x0 and cx < x1 and cz >= z0 and cz < z1 then
                local state = ENGINE_PLANE.state(fruitIndex, px, pz)
                if state ~= nil then
                    total = total + 1
                    local target = desc.harvestTransitions[state]
                    if target ~= nil and state >= minState and state <= desc.maxHarvestingGrowthState then
                        ENGINE_PLANE.cells[pkey(fruitIndex, px, pz)] = target
                        byState[state] = (byState[state] or 0) + 1
                        scaled = scaled + desc:getYieldScale(state)
                    end
                end
            end
        end
    end
    local growthState, maxArea = minState, 0
    for state, n in pairs(byState) do if n > maxArea then growthState, maxArea = state, n end end
    if scaled > 0 then scaled = scaled + ENGINE_PLANE.bias end
    return scaled, total, 1, 1, 1, 1, 1, 1, 0, growthState, maxArea, total
end

-- ── Cutter (vehicles/specializations/Cutter.lua) ──────────────────────────────
Cutter = {}
Cutter.CLIENT_DM_UPDATE_RADIUS = 50
-- :584-668 VERBATIM through the quantities (cutFruitArea, the harvest multiplier,
-- lastMultiplierArea, lastArea, lastFruitType, the fruit change). Abbreviated: the
-- growth-state timer, test areas, cut height, the chopper area and the stone read.
function Cutter:processCutterArea(workArea, dt)
    local spec = self.spec_cutter
    if not self.isServer and self.currentUpdateDistance > Cutter.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    if spec.workAreaParameters.combineVehicle == nil then
        return 0, 0
    end
    local xs, _, zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)
    local lastArea = 0
    local lastMultiplierArea = 0
    local lastTotalArea = 0
    for _, fruitTypeIndex in ipairs(spec.workAreaParameters.fruitTypeIndicesToUse) do
        local area, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState = FSDensityMapUtil.cutFruitArea(fruitTypeIndex, xs, zs, xw, zw, xh, zh, true, spec.allowsForageGrowthState, nil)
        if area > 0 then
            if self.isServer and fruitTypeIndex ~= spec.currentInputFruitType then
                spec.currentInputFruitType = fruitTypeIndex
                spec.currentOutputFillType = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(spec.currentInputFruitType)
                if spec.fruitTypeConverters[spec.currentInputFruitType] ~= nil then
                    spec.currentOutputFillType = spec.fruitTypeConverters[spec.currentInputFruitType].fillTypeIndex
                    spec.currentConversionFactor = spec.fruitTypeConverters[spec.currentInputFruitType].conversionFactor
                end
            end
            lastMultiplierArea = area * g_currentMission:getHarvestScaleMultiplier(fruitTypeIndex, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc)
            spec.workAreaParameters.lastFruitType = fruitTypeIndex
            lastArea = area
            break
        end
    end
    spec.workAreaParameters.lastArea = spec.workAreaParameters.lastArea + lastArea
    spec.workAreaParameters.lastMultiplierArea = spec.workAreaParameters.lastMultiplierArea + lastMultiplierArea
    return spec.workAreaParameters.lastArea, lastTotalArea
end
-- :729-768 VERBATIM for the resets and the combine lookup; the AI required-fill-type
-- branch is abbreviated (no bench cutter is AI-driven).
function Cutter:onStartWorkAreaProcessing(_)
    local spec = self.spec_cutter
    spec.workAreaParameters.combineVehicle = self:getCombine()
    spec.workAreaParameters.lastLiters = 0
    spec.workAreaParameters.lastArea = 0
    spec.workAreaParameters.lastMultiplierArea = 0
    if spec.workAreaParameters.lastFruitType == nil then
        spec.workAreaParameters.fruitTypeIndicesToUse = spec.fruitTypeIndices
    else
        for i = 1, #spec.workAreaParameters.lastFruitTypeToUse do spec.workAreaParameters.lastFruitTypeToUse[i] = nil end
        spec.workAreaParameters.lastFruitTypeToUse[1] = spec.workAreaParameters.lastFruitType
        spec.workAreaParameters.fruitTypeIndicesToUse = spec.workAreaParameters.lastFruitTypeToUse
    end
    spec.workAreaParameters.lastFruitType = nil
    spec.isWorking = false
end
-- :770-840 MODELED names, VERBATIM flow: the decompile reuses `requirement(s)` for
-- the liters, the output type and the AI requirement. Kept: server only, the frame's
-- liters from lastMultiplierArea plus lastLiters, the conversion factor, ONE
-- addCutterArea per frame with the native seven arguments. Abbreviated: statistics,
-- dirty flags, AI requirements.
function Cutter:onEndWorkAreaProcessing(_, _)
    if not self.isServer then return end
    local spec = self.spec_cutter
    local lastArea = spec.workAreaParameters.lastArea
    local lastLiters = spec.workAreaParameters.lastLiters
    if (lastArea > 0 or lastLiters > 0) and spec.workAreaParameters.combineVehicle ~= nil then
        local inputFruitType = spec.workAreaParameters.lastFruitType
        local liters = g_fruitTypeManager:getFruitTypeAreaLiters(inputFruitType, spec.workAreaParameters.lastMultiplierArea, false) + lastLiters
        local outputFillType = spec.currentOutputFillType
        if spec.lastPrioritizedOutputType ~= FillType.UNKNOWN then outputFillType = spec.lastPrioritizedOutputType end
        local conversionFactor = spec.currentConversionFactor or 1
        liters = liters * conversionFactor
        local farmId = self:getLastTouchedFarmlandFarmId()
        spec.lastAddResult = spec.workAreaParameters.combineVehicle:addCutterArea(lastArea, liters, inputFruitType, outputFillType, spec.strawRatio * (1 / conversionFactor), farmId, self:getCutterLoad())
    end
end

-- ── Combine (vehicles/specializations/Combine.lua) ────────────────────────────
Combine = {}
-- :956-1057 MODELED names (the decompile reuses damage/fruitTypeDesc/inputBuffer/slot
-- for five different locals), VERBATIM flow: the stale-area refusal, the straw slot
-- written BEFORE the infinite-capacity buffer-time return, the additive boost, the
-- buffer-or-hopper destination, the no-delay direct add returning the ACCEPTED amount,
-- the first free delay slot, and the delta returned with nothing stored when no slot
-- is free. Abbreviated: rain and damage (both empty in the decompile), statistics.
function Combine:addCutterArea(area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)
    local spec = self.spec_combine
    if area <= 0 and liters <= 0 or spec.lastCuttersFruitType ~= FruitType.UNKNOWN and (spec.lastCuttersArea ~= 0 and spec.lastCuttersOutputFillType ~= outputFillType) then
        return 0
    end
    spec.lastCuttersArea = spec.lastCuttersArea + area
    spec.lastCuttersOutputFillType = outputFillType
    spec.lastCuttersInputFruitType = inputFruitType
    spec.lastCuttersAreaTime = g_currentMission.time
    spec.lastAreaZeroTime = 0
    local deltaFillLevel = liters * spec.threshingScale
    if self:getFillUnitLastValidFillType(spec.fillUnitIndex) == outputFillType or self:getFillUnitLastValidFillType(spec.bufferFillUnitIndex) == outputFillType then
        if inputFruitType == nil then
            inputFruitType = g_fruitTypeManager:getFruitTypeIndexByFillTypeIndex(outputFillType)
        end
        if inputFruitType ~= nil then
            local inputBuffer = spec.processing.inputBuffer
            local slot = inputBuffer.buffer[inputBuffer.fillIndex]
            local fruitTypeDesc = g_fruitTypeManager:getFruitTypeByIndex(inputFruitType)
            -- :983-991 VERBATIM: the slot's straw identity the drop reads (:1347-1348).
            if fruitTypeDesc.chopperType == nil then
                if fruitTypeDesc.chopperUseHaulm then
                    slot.strawGroundType = nil
                    slot.strawHaulmFruitTypeIndex = inputFruitType
                end
            else
                slot.strawGroundType = FieldChopperType.getValueByType(fruitTypeDesc.chopperType)
                slot.strawHaulmFruitTypeIndex = nil
            end
            local strawLiters = liters / fruitTypeDesc.literPerSqm * (fruitTypeDesc.windrowLiterPerSqm or fruitTypeDesc.literPerSqm)
            slot.area = slot.area + area
            slot.liters = slot.liters + strawLiters
            slot.inputLiters = slot.inputLiters + strawLiters
            slot.strawRatio = strawRatio
            slot.effectDensity = cutterLoad * strawRatio * 0.8 + 0.2
        end
    end
    if spec.additives.available then
        local hasAdditive = false
        for i = 1, #spec.additives.fillTypes do
            if outputFillType == spec.additives.fillTypes[i] then hasAdditive = true break end
        end
        if hasAdditive then
            local additiveLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
            if additiveLevel > 0 then
                local usage = spec.additives.usage * deltaFillLevel
                if usage > 0 then
                    deltaFillLevel = deltaFillLevel * (1 + 0.05 * math.min(additiveLevel / usage, 1))
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                end
            end
        end
    end
    if self:getFillUnitCapacity(spec.fillUnitIndex) == math.huge and self:getFillUnitFillLevel(spec.fillUnitIndex) > 0.001 then
        if spec.lastDischargeTime + (self:getIsAIActive() and math.huge or spec.fillLevelBufferTime) < g_currentMission.time then
            return deltaFillLevel
        end
    end
    local fillUnitIndex = spec.fillUnitIndex
    if spec.bufferFillUnitIndex ~= nil and self:getFillUnitFreeCapacity(spec.bufferFillUnitIndex) > 0 then
        fillUnitIndex = spec.bufferFillUnitIndex
    end
    if spec.loadingDelay <= 0 then
        return self:addFillUnitFillLevel(self:getOwnerFarmId(), fillUnitIndex, deltaFillLevel, outputFillType, ToolType.UNDEFINED, nil)
    end
    for i = 1, #spec.loadingDelaySlots do
        if not spec.loadingDelaySlots[i].valid then
            spec.loadingDelaySlots[i].valid = true
            spec.loadingDelaySlots[i].fillLevelDelta = deltaFillLevel
            spec.loadingDelaySlots[i].fillType = outputFillType
            if spec.loadingDelaySlotsDelayedInsert then
                spec.loadingDelaySlots[i].time = g_currentMission.time
            else
                spec.loadingDelaySlots[i].time = g_currentMission.time + (spec.unloadingDelay - spec.loadingDelay)
            end
            spec.loadingDelaySlotsDelayedInsert = not spec.loadingDelaySlotsDelayedInsert
            return deltaFillLevel
        end
    end
    return deltaFillLevel
end
-- :407-471 VERBATIM for the three material movements: the straw input buffer's
-- rotation (:441-458), the buffer fill unit's drain (:459-462) and the due delay
-- slots' drain, each slot cleared before its hopper add (:463-471). Abbreviated: the
-- fill toggles, effects and dirty flags.
function Combine:onUpdateTick(dt, _, _, _)
    if not self.isServer then return end
    local spec = self.spec_combine
    -- :409-414 VERBATIM: the last valid input fruit type survives the frame's reset.
    spec.lastInputFruitType = spec.lastCuttersInputFruitType
    spec.lastCuttersArea = 0
    spec.lastCuttersInputFruitType = FruitType.UNKNOWN
    spec.lastCuttersFruitType = FruitType.UNKNOWN
    if spec.lastInputFruitType ~= nil and spec.lastInputFruitType ~= FruitType.UNKNOWN then
        spec.lastValidInputFruitType = spec.lastInputFruitType
    end
    local inputBuffer = spec.processing.inputBuffer
    inputBuffer.slotTimer = inputBuffer.slotTimer - dt
    if inputBuffer.slotTimer < 0 then
        inputBuffer.slotTimer = inputBuffer.slotDuration
        inputBuffer.fillIndex = inputBuffer.fillIndex + 1
        if inputBuffer.fillIndex > inputBuffer.slotCount then
            inputBuffer.fillIndex = 1
        end
        local lastDropIndex = inputBuffer.dropIndex
        inputBuffer.dropIndex = inputBuffer.dropIndex + 1
        if inputBuffer.dropIndex > inputBuffer.slotCount then
            inputBuffer.dropIndex = 1
        end
        inputBuffer.buffer[inputBuffer.dropIndex].liters = inputBuffer.buffer[inputBuffer.dropIndex].liters + inputBuffer.buffer[lastDropIndex].liters
        inputBuffer.buffer[inputBuffer.dropIndex].inputLiters = inputBuffer.buffer[inputBuffer.dropIndex].inputLiters + inputBuffer.buffer[lastDropIndex].liters
        inputBuffer.buffer[lastDropIndex].area = 0
        inputBuffer.buffer[lastDropIndex].liters = 0
        inputBuffer.buffer[lastDropIndex].inputLiters = 0
    end
    if spec.bufferFillUnitIndex ~= nil and (spec.lastCuttersAreaTime + dt * 10 < g_currentMission.time and self:getFillUnitFillLevel(spec.bufferFillUnitIndex) > 0) then
        local request = dt * (self:getFillUnitCapacity(spec.bufferFillUnitIndex) / spec.bufferUnloadingTime)
        local debit = self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.bufferFillUnitIndex, -request, self:getFillUnitFillType(spec.bufferFillUnitIndex), ToolType.UNDEFINED)
        self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -debit, self:getFillUnitFillType(spec.bufferFillUnitIndex), ToolType.UNDEFINED, nil)
    end
    if spec.loadingDelay > 0 then
        for i = 1, #spec.loadingDelaySlots do
            local slot = spec.loadingDelaySlots[i]
            if slot.valid and slot.time + spec.loadingDelay < g_currentMission.time then
                slot.valid = false
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, slot.fillLevelDelta, slot.fillType, ToolType.UNDEFINED, nil)
            end
        end
    end
end

-- ── vehicles as the engine builds them ────────────────────────────────────────
local function fillUnitFunctions(v)
    v.getFillUnitFillLevel = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.fillLevel or 0 end
    v.getFillUnitFillType = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.fillType or FillType.UNKNOWN end
    v.getFillUnitLastValidFillType = function(self, i) local u = i and self.spec_fillUnit.fillUnits[i] return u and u.lastValidFillType or FillType.UNKNOWN end
    v.getFillUnitCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.capacity or 0 end
    v.getFillUnitFreeCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and math.max(0, u.capacity - u.fillLevel) or 0 end
    -- FillUnit:addFillUnitFillLevel MODELED: refuse a type the unit does not support
    -- (FillUnit.lua getFillUnitSupportsFillType is a supportedFillTypes lookup, and
    -- UNKNOWN is never in it), clamp to [0, capacity], and return the accepted delta. An
    -- emptied unit's type becomes UNKNOWN, as native's does.
    v.addFillUnitFillLevel = function(self, farmId, i, delta, ft)
        local u = self.spec_fillUnit.fillUnits[i]
        if u == nil then return 0 end
        if ft == nil or ft == FillType.UNKNOWN then return 0 end
        local before = u.fillLevel
        u.fillLevel = math.max(0, math.min(u.fillLevel + delta, u.capacity))
        if u.fillLevel > 0 and delta > 0 then u.fillType, u.lastValidFillType = ft, ft end
        if u.fillLevel == 0 then u.fillType = FillType.UNKNOWN end
        return u.fillLevel - before
    end
    -- FillUnit.lua:739-745 and :774-783 VERBATIM, over each unit's supportedFillTypes and
    -- the fillTypeChangeThreshold FillUnit loads (0.05 by default, :273; :785-790).
    v.getFillTypeChangeThreshold = function(self) return self.spec_fillUnit.fillTypeChangeThreshold end
    v.getFillUnitSupportsFillType = function(self, fillUnitIndex, fillType)
        local spec = self.spec_fillUnit
        if spec.fillUnits[fillUnitIndex] == nil then
            return false
        else
            return spec.fillUnits[fillUnitIndex].supportedFillTypes[fillType]
        end
    end
    v.getFillUnitAllowsFillType = function(self, fillUnitIndex, fillType)
        local spec = self.spec_fillUnit
        if spec.fillUnits[fillUnitIndex] == nil or not self:getFillUnitSupportsFillType(fillUnitIndex, fillType) then
            return false
        end
        if fillType == spec.fillUnits[fillUnitIndex].fillType then
            return true
        end
        return spec.fillUnits[fillUnitIndex].fillLevel / math.max(spec.fillUnits[fillUnitIndex].capacity, 0.0001) <= self:getFillTypeChangeThreshold()
    end
end

-- ── Dischargeable's discharge (vehicles/specializations/Dischargeable.lua) ─────
-- :3-5 VERBATIM.
Dischargeable.DISCHARGE_STATE_OFF = 0
Dischargeable.DISCHARGE_STATE_OBJECT = 1
Dischargeable.DISCHARGE_STATE_GROUND = 2
--- :751-765 VERBATIM, with the `local spec = self.spec_dischargeable` the decompile
--- drops restored (the OBJECT test at :761 reads spec). The server runs it each frame of
--- an unload (:470, :505); the OBJECT state hands the raycast's object and fill unit to
--- dischargeToObject through the instance slot. The ground state is SG2-4's; it is
--- reached only with dischargeHitTerrain, which no SG2-3d vehicle sets.
function Dischargeable:discharge(dischargeNode, emptyLiters)
    local spec = self.spec_dischargeable
    local dischargedLiters = 0
    local minDropReached = true
    local hasMinDropFillLevel = true
    local object, fillUnitIndex = self:getDischargeTargetObject(dischargeNode)
    dischargeNode.currentDischargeObject = nil
    if object == nil then
        if dischargeNode.dischargeHitTerrain and self.spec_dischargeable.currentDischargeState == Dischargeable.DISCHARGE_STATE_GROUND then
            dischargedLiters, minDropReached, hasMinDropFillLevel = self:dischargeToGround(dischargeNode, emptyLiters)
        end
    elseif spec.currentDischargeState == Dischargeable.DISCHARGE_STATE_OBJECT then
        return self:dischargeToObject(dischargeNode, emptyLiters, object, fillUnitIndex), minDropReached, hasMinDropFillLevel
    end
    return dischargedLiters, minDropReached, hasMinDropFillLevel
end
--- :702-704 VERBATIM: the object and fill unit the raycast found (:1167-1176).
function Dischargeable.getDischargeTargetObject(_, dischargeNode)
    return dischargeNode.dischargeObject, dischargeNode.dischargeFillUnitIndex
end

--- The raycast's result, as :1167-1176 leaves it on the node, and the state the
--- discharge runs in: what one server frame of an overload sees. MODELED: the raycast
--- itself is C.
function ENGINE_AIM_DISCHARGE(vehicle, object, fillUnitIndex)
    local node = vehicle.spec_dischargeable.dischargeNodes[1]
    node.dischargeObject, node.dischargeFillUnitIndex = object, fillUnitIndex
    vehicle.spec_dischargeable.currentDischargeState = object ~= nil and Dischargeable.DISCHARGE_STATE_OBJECT or Dischargeable.DISCHARGE_STATE_OFF
    return node
end

--- A trailer: FillUnit's functions COPIED into the instance (Vehicle.lua:486,
--- copyTypeFunctionsInto). opts: level, fillType, capacity, ownerFarmId, supported
--- (fill type -> true; default WHEAT).
function ENGINE_NEW_TRAILER(uid, opts)
    opts = opts or {}
    local v = { uniqueId = uid, configFileName = "data/vehicles/trailer.xml", ownerFarmId = opts.ownerFarmId or 1, activeFarm = opts.ownerFarmId or 1, isServer = true,
        rootNode = { x = 0, z = 0 } }
    local unit = { fillLevel = opts.level or 0, capacity = opts.capacity or 10000, fillType = FillType.UNKNOWN, lastValidFillType = FillType.UNKNOWN,
        supportedFillTypes = opts.supported or { [ENGINE_FT.WHEAT] = true } }
    if (opts.level or 0) > 0 then unit.fillType, unit.lastValidFillType = opts.fillType or ENGINE_FT.WHEAT, opts.fillType or ENGINE_FT.WHEAT end
    v.spec_fillUnit = { fillUnits = { unit }, fillTypeChangeThreshold = 0.05 }
    fillUnitFunctions(v)
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.specClasses = {}
    v.specializations = { ENGINE_FILLUNIT }
    v.specializationNames = { "fillUnit" }
    v.eventListeners = { onPostLoad = { ENGINE_FILLUNIT } }
    return v
end

--- A combine with its hopper (fill unit 1), an optional buffer fill unit (2), an
--- optional loading delay (opts.loadingDelay ms, slots per :520), and a straw input
--- buffer of opts.strawSlots slots. Its functions are COPIED into the instance,
--- Dischargeable's too (a combine overloads through its pipe's discharge node, fill
--- unit 1; opts.converter is that node's fill type converter).
function ENGINE_NEW_COMBINE(uid, opts)
    opts = opts or {}
    local v = { uniqueId = uid, configFileName = "data/vehicles/combine.xml", ownerFarmId = 1, activeFarm = 1, isServer = true,
        currentUpdateDistance = 0, rootNode = { x = 0, z = 0 } }
    local grain = { [ENGINE_FT.WHEAT] = true, [ENGINE_FT.BARLEY] = true }
    local units = { { fillLevel = opts.hopperLevel or 0, capacity = opts.hopperCapacity or 10000, fillType = FillType.UNKNOWN, lastValidFillType = opts.lastValid or ENGINE_FT.WHEAT, supportedFillTypes = grain } }
    if (opts.hopperLevel or 0) > 0 then units[1].fillType = ENGINE_FT.WHEAT end
    if opts.buffer then units[2] = { fillLevel = 0, capacity = opts.bufferCapacity or 500, fillType = FillType.UNKNOWN, lastValidFillType = ENGINE_FT.WHEAT, supportedFillTypes = grain } end
    v.spec_fillUnit = { fillUnits = units, fillTypeChangeThreshold = 0.05 }
    fillUnitFunctions(v)
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getIsAIActive = function() return false end
    v.addCutterArea = Combine.addCutterArea
    -- Dischargeable's registered functions (Dischargeable.lua:93, :95, :97, :101), copied.
    v.discharge = Dischargeable.discharge
    v.dischargeToObject = Dischargeable.dischargeToObject
    v.getDischargeFillType = Dischargeable.getDischargeFillType
    v.getDischargeTargetObject = Dischargeable.getDischargeTargetObject
    v.spec_fillVolume = { unloadInfos = { {} } }
    v.getFillVolumeUnloadInfo = function(self, index) return self.spec_fillVolume.unloadInfos[index] end
    v.spec_dischargeable = { currentDischargeState = Dischargeable.DISCHARGE_STATE_OFF,
        dischargeNodes = { { index = 1, fillUnitIndex = 1, toolType = ToolType.DISCHARGEABLE, info = {}, unloadInfoIndex = 1, fillTypeConverter = opts.converter,
                             canDischargeToVehicle = true } } }
    local slots = {}
    local strawSlots = opts.strawSlots or 4
    local buffer = {}
    for i = 1, strawSlots do buffer[i] = { area = 0, liters = 0, inputLiters = 0, strawRatio = 0, effectDensity = 0 } end
    local slotDuration = opts.slotDuration or 100000
    v.spec_combine = {
        fillUnitIndex = 1, bufferFillUnitIndex = opts.buffer and 2 or nil, bufferUnloadingTime = opts.bufferUnloadingTime or 1000,
        loadingDelay = opts.loadingDelay or 0, unloadingDelay = opts.loadingDelay or 0, loadingDelaySlotsDelayedInsert = false,
        threshingScale = opts.threshingScale or 1, fillLevelBufferTime = 2000, lastDischargeTime = 0,
        lastCuttersArea = 0, lastCuttersFruitType = FruitType.UNKNOWN, lastCuttersOutputFillType = FillType.UNKNOWN, lastCuttersAreaTime = -math.huge,
        lastInputFruitType = FruitType.UNKNOWN, lastValidInputFruitType = FruitType.UNKNOWN, lastValidInputFillType = FillType.UNKNOWN,
        additives = { available = false, fillTypes = {} },
        -- :589-599: the cursors, the timers and the buffer.
        processing = { inputBuffer = { buffer = buffer, fillIndex = 1, dropIndex = strawSlots, slotCount = strawSlots, slotTimer = slotDuration, slotDuration = slotDuration,
                                       activeTimeout = slotDuration * (strawSlots + 2), activeTimer = slotDuration * (strawSlots + 2) } },
        swath = { isAvailable = false }, workedHectars = 0, numAttachedCutters = 0,
    }
    if (opts.loadingDelay or 0) > 0 then
        v.spec_combine.loadingDelaySlots = slots
        -- :517-525: every slot invalid after a load; native saves none of them.
        for i = 1, opts.loadingDelay / 1000 * 60 + 1 do slots[i] = { time = -math.huge, fillLevelDelta = 0, fillType = 0, valid = false } end
    end
    v.specClasses = { Combine }
    -- The vehicle's specialization tables as Vehicle:saveToXMLFile (:1210-1212) and
    -- SpecializationUtil.raiseAsyncEvent (:2-16) read them: the class tables, by name.
    v.specializations = { ENGINE_FILLUNIT, Combine }
    v.specializationNames = { "fillUnit", "combine" }
    v.eventListeners = { onPostLoad = { ENGINE_FILLUNIT, Combine } }
    return v
end

--- Combine.lua:81-84 VERBATIM: the native combine's three savegame paths, registered
--- on the schema Vehicle.init built (the vehicle xml schema entries above them, :60-80,
--- are abbreviated).
function Combine.initSpecialization()
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    schemaSavegame:register(XMLValueType.BOOL, "vehicles.vehicle(?).combine#isSwathActive", "Swath is active")
    schemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?).combine#workedHectars", "Worked hectars")
    schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).combine#numAttachedCutters", "Number of last attached cutters")
end
--- Combine.lua:275-282 VERBATIM: the native combine saves no slot.
function Combine:saveToXMLFile(xmlFile, key, _)
    local spec = self.spec_combine
    if spec.swath.isAvailable then
        xmlFile:setValue(key .. "#isSwathActive", spec.isSwathActive)
    end
    xmlFile:setValue(key .. "#workedHectars", spec.workedHectars)
    xmlFile:setValue(key .. "#numAttachedCutters", spec.numAttachedCutters)
end
--- Combine.lua:207-215 MODELED: the two values the native post-load reads back.
function Combine:onPostLoad(savegame)
    local spec = self.spec_combine
    if savegame == nil then return end
    spec.workedHectars = savegame.xmlFile:getValue(savegame.key .. ".combine#workedHectars", spec.workedHectars)
    spec.numAttachedCutters = savegame.xmlFile:getValue(savegame.key .. ".combine#numAttachedCutters", spec.numAttachedCutters)
end

--- FillUnit.lua:430 and :333 MODELED: each unit's level and type name saved, and on
--- post-load added back through addFillUnitFillLevel, which sets the unit's last valid
--- type only when something fills it (:1280); an empty unit's stays UNKNOWN (:1311).
ENGINE_FILLUNIT = {}
--- FillUnit.lua:136-138 VERBATIM: the fill unit's savegame paths.
function ENGINE_FILLUNIT.initSpecialization()
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).fillUnit.unit(?)#index", "Fill Unit index")
    schemaSavegame:register(XMLValueType.STRING, "vehicles.vehicle(?).fillUnit.unit(?)#fillType", "Fill type")
    schemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?).fillUnit.unit(?)#fillLevel", "Fill level")
end
function ENGINE_FILLUNIT.saveToXMLFile(self, xmlFile, key, _)
    for i, unit in ipairs(self.spec_fillUnit.fillUnits) do
        local k = string.format("%s.unit(%d)", key, i - 1)
        xmlFile:setValue(k .. "#fillLevel", unit.fillLevel)
        xmlFile:setValue(k .. "#fillType", g_fillTypeManager:getFillTypeNameByIndex(unit.fillType) or "UNKNOWN")
    end
end
function ENGINE_FILLUNIT.onPostLoad(self, savegame)
    if savegame == nil or not savegame.xmlFile:hasProperty(savegame.key .. ".fillUnit") then return end
    for i in ipairs(self.spec_fillUnit.fillUnits) do
        local k = string.format("%s.fillUnit.unit(%d)", savegame.key, i - 1)
        local level = savegame.xmlFile:getValue(k .. "#fillLevel", 0)
        local ft = g_fillTypeManager:getFillTypeIndexByName(savegame.xmlFile:getValue(k .. "#fillType", "UNKNOWN"))
        if level > 0 and ft ~= nil then self:addFillUnitFillLevel(self:getOwnerFarmId(), i, level, ft, ToolType.UNDEFINED, nil) end
    end
end

--- Vehicle.lua:1210-1212 VERBATIM: every specialization's class-table saver, by name.
function ENGINE_SAVE_VEHICLE(self, xmlFile, key, usedModNames)
    for k, component in pairs(self.specializations) do
        if component.saveToXMLFile ~= nil then
            component.saveToXMLFile(self, xmlFile, key .. "." .. self.specializationNames[k], usedModNames)
        end
    end
end
--- Vehicle.lua:903-906 queues SpecializationUtil.raiseAsyncEvent(self, "onPostLoad",
--- self.savegame); raiseAsyncEvent (:2-16 VERBATIM in what it reads) queues one task per
--- listener and reads the listener's class table when the task runs. The vehicle's task
--- queue is drained here in order, as the loading step does.
function ENGINE_POST_LOAD_VEHICLE(object, savegame)
    object.asyncTasks = {}
    function object:addAsyncTask(fn) self.asyncTasks[#self.asyncTasks + 1] = fn end
    local eventName, typeName = "onPostLoad", { savegame }
    for _, spec in ipairs(object.eventListeners[eventName]) do
        object:addAsyncTask(function() spec[eventName](object, unpack(typeName)) end)
    end
    for _, task in ipairs(object.asyncTasks) do task() end
end

--- Vehicle.lua:249 MODELED: the savegame schema is built fresh on every mission load
--- (MPLoadingScreen.lua:767); the store and vehicle-type schemas are abbreviated.
Vehicle = Vehicle or {}
function Vehicle.init() Vehicle.xmlSchemaSavegame = XMLSchema.new("savegame_vehicles") end
--- SpecializationManager.lua:97-104 MODELED (the async subtasks run in order): each
--- specialization's initSpecialization, read from its class table when called
--- (MPLoadingScreen.lua:776, after Vehicle.init).
g_specializationManager = {
    initSpecializations = function()
        for _, specialization in ipairs({ ENGINE_FILLUNIT, Combine }) do
            if specialization.initSpecialization ~= nil then specialization.initSpecialization() end
        end
    end,
}

-- ── XMLSchema and XMLFile (the engine's savegame files), MODELED in memory ──
-- XMLSchema.new(name) and schema:register(valueType, path, description) as Combine.lua
-- :81-84 calls them: a registered path is keyed with "(?)" for every index. XMLFile
-- create/load take the schema (VehicleSystem.lua:293, :324); setValue and getValue go
-- through XMLFile:getValueType (XMLFile.lua:273-294): the path's indices normalised to
-- "(?)", an unregistered path logs "Path not registered", setValue then sets nothing
-- (:181-186) and getValue answers nil (:166-168); a file with no schema logs "Unable to
-- get schema" the same way. The typed setString/getString and their kin, and
-- hasProperty, read and write the file without the schema (:69-72). ENGINE_XML_ERRORS
-- counts the errors logged, for the bar.
XMLValueType = XMLValueType or {}
for _, id in ipairs({ "INT", "FLOAT", "BOOL", "STRING" }) do XMLValueType[id] = XMLValueType[id] or { id = id } end
XMLSchema = XMLSchema or {}
function XMLSchema.new(name)
    local schema = { name = name, paths = {} }
    function schema:register(valueType, path, _description) self.paths[path] = { valueTypeId = valueType.id } end
    return schema
end
ENGINE_DISK = ENGINE_DISK or {}
ENGINE_XML_ERRORS = 0
ENGINE_XML_ERROR_LOG = {}
local function xmlObject(path, data, schema)
    local o = { path = path, data = data, schema = schema }
    function o:getValueType(k)
        if self.schema == nil then
            ENGINE_XML_ERRORS = ENGINE_XML_ERRORS + 1
            ENGINE_XML_ERROR_LOG[#ENGINE_XML_ERROR_LOG + 1] = "no schema: " .. tostring(self.path) .. " " .. tostring(k)
            print("[xml] Unable to get schema for xml file " .. tostring(self.path) .. ".")
            return nil
        end
        local normalized = string.gsub(k, "%(%d*%)", "(?)")
        local pathData = self.schema.paths[normalized]
        if pathData ~= nil then return pathData.valueTypeId end
        ENGINE_XML_ERRORS = ENGINE_XML_ERRORS + 1
        ENGINE_XML_ERROR_LOG[#ENGINE_XML_ERROR_LOG + 1] = "not registered: " .. tostring(k)
        print("[xml] Failed to validate xml path '" .. tostring(k) .. "' for schema '" .. tostring(self.schema.name) .. "'. Path not registered.")
        return nil
    end
    function o:setValue(k, v) if self:getValueType(k) ~= nil then self.data[k] = v end end
    function o:getValue(k, d)
        if self:getValueType(k) == nil then return nil end
        local v = self.data[k] if v == nil then return d end return v
    end
    -- The typed pairs read and write the handle directly, no schema (XMLFile.lua:152-159
    -- getBool and kin; setString and kin the same way), as StockGuard's own files do.
    local function typedGet(k, d) local v = o.data[k] if v == nil then return d end return v end
    function o:setInt(k, v) self.data[k] = v end
    function o:getInt(k, d) return typedGet(k, d) end
    function o:setString(k, v) self.data[k] = v end
    function o:getString(k, d) return typedGet(k, d) end
    function o:setBool(k, v) self.data[k] = v end
    function o:getBool(k, d) return typedGet(k, d) end
    function o:hasProperty(k)
        if self.data[k] ~= nil then return true end
        for key in pairs(self.data) do
            if key:sub(1, #k) == k then
                local rest = key:sub(#k + 1, #k + 1)
                if rest == "#" or rest == "." or rest == "(" then return true end
            end
        end
        return false
    end
    function o:save() ENGINE_DISK[self.path] = self.data return true end
    function o:delete() end
    return o
end
XMLFile = XMLFile or {}
XMLFile.create = function(_, path, _root, schema) return xmlObject(path, {}, schema) end
XMLFile.load = function(_, path, schema) local d = ENGINE_DISK[path] if d == nil then return nil end return xmlObject(path, d, schema) end
XMLFile.loadIfExists = XMLFile.load

--- A cutter header attached to `combine`, with opts.areas work areas side by side,
--- each opts.width wide and opts.depth deep from (x0, z0). Its processCutterArea is
--- COPIED into the instance and each work area's pointer CAPTURED (WorkArea.lua:266).
function ENGINE_NEW_HEADER(uid, combine, opts)
    opts = opts or {}
    local v = { uniqueId = uid, configFileName = "data/vehicles/header.xml", ownerFarmId = 1, isServer = true, currentUpdateDistance = 0 }
    v.processCutterArea = Cutter.processCutterArea
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getCombine = function(self) return self._combine end
    v.getLastTouchedFarmlandFarmId = function() return 1 end
    v.getCutterLoad = function() return 1 end
    v._combine = combine
    v.spec_cutter = {
        workAreaParameters = { lastArea = 0, lastMultiplierArea = 0, lastLiters = 0, fruitTypeIndicesToUse = opts.fruitTypes or { FruitType.WHEAT }, lastFruitTypeToUse = {} },
        fruitTypeIndices = opts.fruitTypes or { FruitType.WHEAT }, fruitTypeConverters = {}, currentConversionFactor = 1, strawRatio = opts.strawRatio or 0.5,
        lastPrioritizedOutputType = FillType.UNKNOWN, allowsForageGrowthState = false,
    }
    local areas = {}
    local n, x0, z0, w, d = opts.areas or 1, opts.x0 or 0, opts.z0 or 0, opts.width or 4, opts.depth or 1
    for i = 1, n do
        local xa = x0 + (i - 1) * w
        areas[i] = { index = i, functionName = "processCutterArea",
            start = { x = xa, z = z0 }, width = { x = xa + w, z = z0 }, height = { x = xa, z = z0 + d } }
    end
    v.spec_workArea = { workAreas = areas }
    for _, wa in ipairs(areas) do wa.processingFunction = v[wa.functionName] end
    v.specClasses = { Cutter }
    return v
end

--- One frame, in WorkArea:onUpdateTick's order (WorkArea.lua:126, :179-193, :206):
--- the header's classes' start, each captured pointer, the end (which calls the
--- combine), then the combine's own update tick. The mission clock advances by dt.
function ENGINE_HARVEST_TICK(header, combine, dt)
    dt = dt or 16
    g_currentMission.time = (g_currentMission.time or 0) + dt
    if header ~= nil then
        for _, class in ipairs(header.specClasses) do class.onStartWorkAreaProcessing(header, dt) end
        for _, wa in ipairs(header.spec_workArea.workAreas) do
            if wa.processingFunction ~= nil then
                local xs = wa.processingFunction(header, wa, dt)
                if xs > 0 then wa.lastWorkedHectares = xs end
            end
        end
        for _, class in ipairs(header.specClasses) do class.onEndWorkAreaProcessing(header, dt, true) end
    end
    if combine ~= nil then
        for _, class in ipairs(combine.specClasses) do class.onUpdateTick(combine, dt, false, false, false) end
    end
end
