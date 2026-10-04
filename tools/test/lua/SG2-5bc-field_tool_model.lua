-- SG2-5bc-field_tool_model.lua - the Tedder and the Mower the SG2-5bc-save bench runs against.
--
-- NOT A TEST. A launch bar lists it after SG2-4b-ground_model.lua and before any StockGuard
-- file, as the game defines its specializations before a mod's source() (MPLoadingScreen.lua
-- :352, then :735).
--
-- The quantity bodies are the SG2-5b and SG2-5c benches' ports, unchanged (each says what it
-- follows). What a save and a load reach is added here: each class's loadWorkAreaFromXML
-- VERBATIM (Tedder.lua:238-254, Mower.lua:477-496: the buffers zeroed at load), each class's
-- onPostLoad (Tedder.lua:104-124 MODELED, it reads no buffer; Mower.lua:167-180 VERBATIM through
-- spec.workAreas), neither class with a saveToXMLFile (grep: none in either file), the vehicle
-- types as vehicleTypes.xml composes them (tedder and mower: baseGroundTool's workArea, no
-- fillUnit), and initSpecializations over every class the models define. The engine's FLOAT
-- writer (MAINTENANCE row 206's model, measured from the save files) writes every schema FLOAT.

-- ── The windrow types (a model extension, as the SG2-5b and SG2-5c benches) ───────────────────
local WHEAT, BARLEY = ENGINE_FT.WHEAT, ENGINE_FT.BARLEY
local GRASS_W, DRY_W, STRAW_W = 6, 7, 8
local NAMES = { [WHEAT] = "WHEAT", [BARLEY] = "BARLEY", [4] = "GRASS", [5] = "STRAW", [GRASS_W] = "GRASS_WINDROW", [DRY_W] = "DRYGRASS_WINDROW", [STRAW_W] = "STRAW_WINDROW" }
g_fillTypeManager = {
    getFillTypeNameByIndex = function(_, i) return NAMES[i] end,
    getFillTypeIndexByName = function(_, n) for i, v in pairs(NAMES) do if v == n then return i end end return nil end,
}
FillType.GRASS_WINDROW, FillType.DRYGRASS_WINDROW, FillType.STRAW_WINDROW = GRASS_W, DRY_W, STRAW_W
do
    local hm = g_densityMapHeightManager
    for _, e in ipairs({ { GRASS_W, "GRASS_WINDROW" }, { DRY_W, "DRYGRASS_WINDROW" }, { STRAW_W, "STRAW_WINDROW" } }) do
        local ht = { index = #hm.heightTypes + 1, fillTypeIndex = e[1], fillTypeName = e[2], maxSurfaceAngle = math.rad(45), fillToGroundScale = 1,
                     canBeTipped = true, allowsSmoothing = true, collisionBaseOffset = 0 }
        hm.heightTypes[ht.index] = ht
        hm.fillTypeIndexToHeightType[e[1]] = ht
        hm.fillTypeNameToHeightType[e[2]] = ht
    end
end
ENGINE_HT.GRASS_WINDROW = g_densityMapHeightManager.fillTypeIndexToHeightType[GRASS_W]
ENGINE_HT.DRYGRASS_WINDROW = g_densityMapHeightManager.fillTypeIndexToHeightType[DRY_W]
MathUtil.vector3Length = MathUtil.vector3Length or function(x, y, z) return math.sqrt(x * x + y * y + z * z) end
-- DensityMapHeightUtil.lua:425-449 VERBATIM, and :450-455 (as the SG2-5a, 5b and 5c benches carry them).
DensityMapHeightUtil.getLineByAreaDimensions = DensityMapHeightUtil.getLineByAreaDimensions or function(sx, sy, sz, wx, wy, wz, hx, hy, hz, radiusOverlap)
    local swDirX, swDirY, swDirZ = wx - sx, wy - sy, wz - sz
    local shDirX, shDirY, shDirZ = hx - sx, hy - sy, hz - sz
    local swLength = math.sqrt(swDirX * swDirX + swDirY * swDirY + swDirZ * swDirZ)
    local shLength = math.sqrt(shDirX * shDirX + shDirY * shDirY + shDirZ * shDirZ)
    shDirX, shDirY, shDirZ = shDirX / shLength, shDirY / shLength, shDirZ / shLength
    swDirX, swDirY, swDirZ = swDirX / swLength, swDirY / swLength, swDirZ / swLength
    if shLength < swLength then
        local radius = shLength * 0.5
        local shrink = radiusOverlap ~= nil and radiusOverlap and 0 or radius
        return sx + shDirX * shLength * 0.5 + swDirX * shrink, sy + shDirY * shLength * 0.5 + swDirY * shrink, sz + shDirZ * shLength * 0.5 + swDirZ * shrink, wx + shDirX * shLength * 0.5 - swDirX * shrink, wy + shDirY * shLength * 0.5 - swDirY * shrink, wz + shDirZ * shLength * 0.5 - swDirZ * shrink, radius
    else
        local radius = swLength * 0.5
        local shrink = radiusOverlap ~= nil and radiusOverlap and 0 or radius
        return sx + swDirX * swLength * 0.5 + shDirX * shrink, sy + swDirY * swLength * 0.5 + shDirY * shrink, sz + swDirZ * swLength * 0.5 + shDirZ * shrink, hx + swDirX * swLength * 0.5 - shDirX * shrink, hy + swDirY * swLength * 0.5 - shDirY * shrink, hz + swDirZ * swLength * 0.5 - shDirZ * shrink, radius
    end
end
DensityMapHeightUtil.getLineByArea = DensityMapHeightUtil.getLineByArea or function(start, width, height, radiusOverlap)
    local sx, sy, sz = getWorldTranslation(start)
    local wx, wy, wz = getWorldTranslation(width)
    local hx, hy, hz = getWorldTranslation(height)
    return DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, radiusOverlap)
end

-- ── The forage crop (a model extension, as the SG2-5c bench) ──────────────────────────────────
-- The model's WHEAT descriptor stands in for the meadow: harvestable at 3 (yield scale 0.5) and 4 (1).
FruitType.MEADOW = FruitType.WHEAT
do
    local d = g_fruitTypeManager:getFruitTypeByIndex(FruitType.WHEAT)
    d.regrows, d.firstRegrowthState = true, 3
end
-- WorkAreaType (WorkAreaTypeManager): the four types these two classes read, by value.
WorkAreaType = WorkAreaType or {}
WorkAreaType.DEFAULT = WorkAreaType.DEFAULT or 20
WorkAreaType.MOWER = WorkAreaType.MOWER or 21
WorkAreaType.AUXILIARY = WorkAreaType.AUXILIARY or 22
WorkAreaType.TEDDER = WorkAreaType.TEDDER or 23
-- A work area of a type neither class reads (a roller's, say), for a config whose drop binding names it.
WorkAreaType.OTHER = WorkAreaType.OTHER or 99

-- ── WorkArea (vehicles/specializations/WorkArea.lua), what these two read ─────────────────────
-- The workArea specialization's class: nothing of it saves a buffer. Its loadWorkAreaFromXML is
-- MODELED as far as the two overrides read it: the area's type from its config (DEFAULT when
-- unset). The index is the area's place in load order and the captured processing pointer is the
-- instance function the type names (WorkArea.lua:266), both set by ENGINE_LOAD_WORK_AREAS.
ENGINE_WORKAREA = {}
function ENGINE_WORKAREA.loadWorkAreaFromXML(_self, workArea, xmlFile, key)
    workArea.type = xmlFile:getValue(key .. "#type", WorkAreaType.DEFAULT)
    return true
end
--- A vehicle config's work areas, as a stand-in XML: one value per "<key>#<attr>".
local function configXml(values)
    return { getValue = function(_, k, d) local v = values[k] if v == nil then return d end return v end }
end
--- Load `defs` ({ type?, start, width, height, attrs }) through `class.loadWorkAreaFromXML` (an
--- overwritten function, so WorkArea's is its superFunc), in order, then capture each area's
--- processing pointer by the name its type gives (WorkArea.lua:266).
local function loadWorkAreas(v, class, defs, functionByType)
    local values = {}
    for i, def in ipairs(defs) do
        local key = string.format("vehicle.workAreas.workArea(%d)", i - 1)
        if def.type ~= nil then values[key .. "#type"] = def.type end
        for attr, value in pairs(def.attrs or {}) do values[key .. attr] = value end
    end
    local xml = configXml(values)
    v.spec_workArea = { workAreas = {} }
    for i, def in ipairs(defs) do
        local wa = { index = i, start = def.start, width = def.width, height = def.height }
        class.loadWorkAreaFromXML(v, ENGINE_WORKAREA.loadWorkAreaFromXML, wa, xml, string.format("vehicle.workAreas.workArea(%d)", i - 1))
        v.spec_workArea.workAreas[i] = wa
    end
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        wa.functionName = functionByType[wa.type]
        if wa.functionName ~= nil then wa.processingFunction = v[wa.functionName] end
    end
end
local function corners(x0, x1, z) return { x = x0, y = 0, z = z - 0.5 }, { x = x1, y = 0, z = z - 0.5 }, { x = x0, y = 0, z = z + 0.5 } end
local function baseVehicle(uid, configFileName)
    local v = { uniqueId = uid, configFileName = configFileName, ownerFarmId = 1, activeFarm = 1, isServer = true, currentUpdateDistance = 0, rootNode = { x = 0, z = 0 } }
    v.getUniqueId = function(self) return self.uniqueId end
    v.getOwnerFarmId = function(self) return self.ownerFarmId end
    v.getActiveFarm = function(self) return self.activeFarm end
    v.getTypedWorkAreas = function(self, t)
        local out = {}
        for _, wa in ipairs(self.spec_workArea.workAreas) do if wa.type == t then out[#out + 1] = wa end end
        return out
    end
    return v
end

-- ── The engine's Tedder (vehicles/specializations/Tedder.lua) ───────────────────────────────
Tedder = Tedder or {}
Tedder.CLIENT_DM_UPDATE_RADIUS = 50
--- :3-16 MODELED: it registers vehicle-xml paths only, no savegame path.
function Tedder.initSpecialization() end
--- :104-124 MODELED: the effects' work areas and the client's update listener; it reads no buffer.
function Tedder:onPostLoad(_) end
--- :238-254 VERBATIM.
function Tedder:loadWorkAreaFromXML(superFunc, workArea, xmlFile, key)
    local retValue = superFunc(self, workArea, xmlFile, key)
    if workArea.type == WorkAreaType.DEFAULT then
        workArea.type = WorkAreaType.TEDDER
    end
    if workArea.type == WorkAreaType.TEDDER then
        workArea.dropWindrowWorkAreaIndex = xmlFile:getValue(key .. ".tedder#dropWindrowWorkAreaIndex", 1)
        workArea.litersToDrop = 0
        workArea.lastPickupLiters = 0
        workArea.lastDropFillType = FillType.UNKNOWN
        workArea.lastDroppedLiters = 0
        workArea.tedderParticlesActive = false
        workArea.tedderParticlesActiveSent = false
        local spec = self.spec_tedder
        if spec.tedderWorkAreaFillTypes == nil then
            spec.tedderWorkAreaFillTypes = {}
        end
        table.insert(spec.tedderWorkAreaFillTypes, FruitType.UNKNOWN)
        workArea.tedderWorkAreaIndex = #spec.tedderWorkAreaFillTypes
    end
    return retValue
end
-- :360-362 VERBATIM.
function Tedder:onStartWorkAreaProcessing(_)
    self.spec_tedder.lastDroppedLiters = 0
end
-- :279-350 VERBATIM through the quantities (the SG2-5b bench's port): the effect, sound, dirty-flag
-- and stone lines out. The decompile prints `local targetFillType = workArea.lastDropFillType` at
-- :294, a shadow that would do nothing; SG-2 :199 names the zero-pickup lastDropFillType
-- substitution, so this port assigns it.
function Tedder:processTedderArea(workArea, _)
    local spec = self.spec_tedder
    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, true)
    for targetFillType, inputFillTypes in pairs(spec.fillTypeConvertersReverse) do
        local pickedUpLiters = 0
        for _, inputFillType in ipairs(inputFillTypes) do
            pickedUpLiters = pickedUpLiters + DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, inputFillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, nil, false, nil)
        end
        if pickedUpLiters == 0 and workArea.lastDropFillType ~= FillType.UNKNOWN then
            targetFillType = workArea.lastDropFillType
        end
        workArea.lastPickupLiters = -pickedUpLiters
        workArea.litersToDrop = workArea.litersToDrop + workArea.lastPickupLiters
        local dropArea = self.spec_workArea.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil and workArea.litersToDrop > 0 then
            local dropped = self:processDropArea(dropArea, targetFillType, workArea.litersToDrop)
            workArea.lastDropFillType = targetFillType
            workArea.lastDroppedLiters = dropped
            spec.lastDroppedLiters = spec.lastDroppedLiters + dropped
            workArea.litersToDrop = workArea.litersToDrop - dropped
        end
    end
    local area = MathUtil.vector3Length(lsx - lex, lsy - ley, lsz - lez) * self.lastMovedDistance
    return area, area
end
-- :351-358 VERBATIM (the client-distance guard is the server's always-pass branch).
function Tedder:processDropArea(dropArea, fillType, litersToDrop)
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height, true)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, litersToDrop, fillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset
    return dropped
end

--- A tedder (vehicleTypes.xml `tedder`: baseGroundTool, turnOnVehicle, workMode, tedder; no fill
--- unit), its functions COPIED into the instance (Vehicle.lua:486), built through Tedder:onLoad
--- (:49-55, the converters as :47-65 and the SG2-5b bench build them, forward and reverse) and its
--- work areas through Tedder:loadWorkAreaFromXML. The pickup spans x -1..1 at z = opts.z (default
--- 30) and drops into its AUXILIARY drop area at x 8..10. opts.extraPickup adds a second TEDDER area
--- (a changed layout); opts.dropTo = 3 binds the pickup to a third area of another type (a changed
--- drop binding in the same layout); opts.configFileName another configuration.
function ENGINE_NEW_TEDDER(uid, opts)
    opts = opts or {}
    local z = opts.z or 30
    local v = baseVehicle(uid, opts.configFileName or "data/vehicles/tedder.xml")
    v.lastMovedDistance = 1
    v.processTedderArea, v.processDropArea = Tedder.processTedderArea, Tedder.processDropArea
    local forward, reverse = {}, {}
    for _, t in ipairs(opts.targets or { { DRY_W, { GRASS_W, DRY_W } } }) do
        reverse[t[1]] = {}
        for _, input in ipairs(t[2]) do
            forward[input] = { targetFillTypeIndex = t[1] }
            table.insert(reverse[t[1]], input)
        end
    end
    v.spec_tedder = { fillTypeConverters = forward, fillTypeConvertersReverse = reverse, lastDroppedLiters = 0 }
    local ps, pw, ph = corners(-1, 1, z)
    local ds, dw, dh = corners(8, 10, z)
    local defs = { { start = ps, width = pw, height = ph, attrs = { [".tedder#dropWindrowWorkAreaIndex"] = opts.dropTo or 2 } },
                   { type = WorkAreaType.AUXILIARY, start = ds, width = dw, height = dh } }
    if opts.dropTo ~= nil then
        local os_, ow, oh = corners(12, 14, z)
        defs[3] = { type = WorkAreaType.OTHER, start = os_, width = ow, height = oh }
    end
    if opts.extraPickup then
        local es, ew, eh = corners(-1, 1, z + 3)
        defs[3] = { start = es, width = ew, height = eh, attrs = { [".tedder#dropWindrowWorkAreaIndex"] = 2 } }
    end
    loadWorkAreas(v, Tedder, defs, { [WorkAreaType.TEDDER] = "processTedderArea" })
    v.specClasses = { Tedder }
    v.specializations = { ENGINE_WORKAREA, Tedder }
    v.specializationNames = { "workArea", "tedder" }
    v.eventListeners = { onPostLoad = { Tedder } }
    return v
end
--- WorkArea's tick for a Tedder (WorkArea.lua:124-200): the start event, then each TEDDER area's
--- captured pointer.
function ENGINE_TEDDER_TICK(v)
    Tedder.onStartWorkAreaProcessing(v, nil)
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        if wa.processingFunction ~= nil then wa.processingFunction(v, wa, 16) end
    end
end

-- ── The engine's Mower (vehicles/specializations/Mower.lua) ────────────────────────────────────
Mower = Mower or {}
Mower.CLIENT_DM_UPDATE_RADIUS = 50
--- The chord's two draws (math.random at :389 and :393, MODELED as fixed values).
ENGINE_MOWER = { draws = { 0.5, 0.5 } }
--- Mowable decorative foliage on 1 m fruit pixels ("px:pz" = true), for the meadow preparation.
ENGINE_DECO = {}
--- :3-39 MODELED: it registers vehicle-xml paths only, no savegame path.
function Mower.initSpecialization() end
--- :167-180 VERBATIM (the drop effects are the config's; the model has none).
function Mower:onPostLoad(_)
    local spec = self.spec_mower
    spec.workAreas = self:getTypedWorkAreas(WorkAreaType.MOWER)
    for i = 1, #spec.workAreas do
        local workArea = spec.workAreas[i]
        workArea.dropEffects = {}
        for _, dropEffect in pairs(spec.dropEffects) do
            if dropEffect.workAreaIndex == workArea.index then
                table.insert(workArea.dropEffects, dropEffect)
            end
        end
    end
end
--- :477-496 VERBATIM.
function Mower:loadWorkAreaFromXML(superFunc, workArea, xmlFile, key)
    local retValue = superFunc(self, workArea, xmlFile, key)
    if workArea.type == WorkAreaType.DEFAULT then
        workArea.type = WorkAreaType.MOWER
    end
    if workArea.type == WorkAreaType.MOWER then
        workArea.dropWindrow = xmlFile:getValue(key .. ".mower#dropWindrow", true)
        workArea.dropAreaIndex = xmlFile:getValue(key .. ".mower#dropAreaIndex", 1)
        workArea.lastPickupLiters = 0
        workArea.pickedUpLiters = 0
    end
    if workArea.type == WorkAreaType.AUXILIARY then
        workArea.litersToDrop = 0
        if self.spec_mower.dropAreas == nil then
            self.spec_mower.dropAreas = {}
        end
        table.insert(self.spec_mower.dropAreas, workArea)
    end
    return retValue
end
--- FSDensityMapUtil.lua:1886-1921 VERBATIM through the quantities (the SG2-5c bench's port). The
--- preparation's multi-modifier execute (:1916-1918) is C, MODELED: each fruit pixel whose centre
--- lies in the parallelogram and carries mowable decorative foliage takes the meadow at its first
--- regrowth state.
function FSDensityMapUtil.updateMowerArea(fruitType, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, limitToField)
    local desc = g_fruitTypeManager:getFruitTypeByIndex(FruitType.MEADOW)
    if desc ~= nil and desc.terrainDataPlaneId ~= nil then
        if not limitToField and desc.regrows and desc.firstRegrowthState ~= nil then
            local x0, x1 = math.min(startWorldX, widthWorldX, heightWorldX), math.max(startWorldX, widthWorldX, heightWorldX)
            local z0, z1 = math.min(startWorldZ, widthWorldZ, heightWorldZ), math.max(startWorldZ, widthWorldZ, heightWorldZ)
            for key in pairs(ENGINE_DECO) do
                local px, pz = key:match("^(-?%d+):(-?%d+)$")
                px, pz = tonumber(px), tonumber(pz)
                local cx, cz = px + 0.5, pz + 0.5
                if cx >= x0 and cx < x1 and cz >= z0 and cz < z1 then ENGINE_PLANE.sow(FruitType.MEADOW, px, pz, px + 1, pz + 1, desc.firstRegrowthState) end
            end
        end
    end
    return FSDensityMapUtil.cutFruitArea(fruitType, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, true, false, nil, nil, limitToField)
end
--- :328-382 VERBATIM through the quantities (the SG2-5c bench's port); the decompile's global
--- `pickup` at :363 made a local, and workAreaChanged left as the decompile returns it.
function Mower:processMowerArea(workArea, _)
    local spec = self.spec_mower
    if not self.isServer and self.currentUpdateDistance > Mower.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local xs, _, zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)
    if self:getLastSpeed() > 1 then
        spec.isWorking = true
        spec.stoneLastState = FSDensityMapUtil.getStoneArea(xs, zs, xw, zw, xh, zh)
    else
        spec.stoneLastState = 0
    end
    local workAreaChanged = 0
    local workAreaTotal = 0
    local limitToField = self:getIsAIActive()
    for inputFruitType, converterData in pairs(spec.fruitTypeConverters) do
        local changedArea, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState, _ = FSDensityMapUtil.updateMowerArea(inputFruitType, xs, zs, xw, zw, xh, zh, limitToField)
        if changedArea > 0 then
            local multiplier = g_currentMission:getHarvestScaleMultiplier(inputFruitType, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc)
            local litersToDrop = g_fruitTypeManager:getFruitTypeAreaLiters(inputFruitType, changedArea, true) * multiplier * converterData.conversionFactor
            workArea.lastPickupLiters = litersToDrop
            workArea.pickedUpLiters = litersToDrop
            local dropArea = self:getDropArea(workArea)
            if dropArea == nil then
                if spec.fillUnitIndex ~= nil and self.isServer then
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, litersToDrop, converterData.fillTypeIndex, ToolType.UNDEFINED)
                end
            else
                dropArea.litersToDrop = dropArea.litersToDrop + litersToDrop
                dropArea.fillType = converterData.fillTypeIndex
                dropArea.workAreaIndex = workArea.index
                if dropArea.fillType == FillType.GRASS_WINDROW then
                    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height, true)
                    local pickup
                    pickup, workArea.lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, workArea.lineOffset or 0, false, nil, false)
                    dropArea.litersToDrop = dropArea.litersToDrop - pickup
                end
                local lsy = dropArea.litersToDrop
                dropArea.litersToDrop = math.min(lsy, 1000)
            end
            spec.workAreaParameters.lastInputFruitType = inputFruitType
            spec.workAreaParameters.lastInputGrowthState = growthState
            spec.workAreaParameters.lastCutTime = g_time
            spec.workAreaParameters.lastChangedArea = spec.workAreaParameters.lastChangedArea + changedArea
            spec.workAreaParameters.lastStatsArea = spec.workAreaParameters.lastStatsArea + totalArea
            spec.workAreaParameters.lastTotalArea = spec.workAreaParameters.lastTotalArea + totalArea
            spec.workAreaParameters.lastUsedAreas = spec.workAreaParameters.lastUsedAreas + 1
            self:setTestAreaRequirements(inputFruitType)
            workAreaTotal = totalArea
        end
    end
    spec.workAreaParameters.lastUsedAreasSum = spec.workAreaParameters.lastUsedAreasSum + 1
    return workAreaChanged, workAreaTotal
end
--- :383-405 VERBATIM through the quantities (the SG2-5c bench's port); the two draws are
--- ENGINE_MOWER's, and the decompile's reused name at :393-395 restored.
function Mower:processDropArea(dropArea, _)
    if self.isServer or self.currentUpdateDistance <= Mower.CLIENT_DM_UPDATE_RADIUS then
        if dropArea.litersToDrop > g_densityMapHeightManager:getMinValidLiterValue(dropArea.fillType) then
            local xs, _, zs = getWorldTranslation(dropArea.start)
            local xw, _, zw = getWorldTranslation(dropArea.width)
            local xh, _, zh = getWorldTranslation(dropArea.height)
            local f = ENGINE_MOWER.draws[1]
            local sx = xs + f * (xh - xs)
            local sz = zs + f * (zh - zs)
            local sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)
            local f2 = ENGINE_MOWER.draws[2]
            local ex = xw + f2 * (xh - xs)
            local ez = zw + f2 * (zh - zs)
            local ey = getTerrainHeightAtWorldPos(g_terrainNode, ex, 0, ez)
            local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, dropArea.litersToDrop, dropArea.fillType, sx, sy, sz, ex, ey, ez, 0, nil, dropArea.dropLineOffset, false, nil, false)
            dropArea.litersToDrop = dropArea.litersToDrop - dropped
            dropArea.dropLineOffset = lineOffset
            if dropped ~= 0 then
                self.spec_mower.lastDropTime = g_time
            end
        end
    end
end
--- :406-424 VERBATIM, the decompile's fall-through after an invalid index (:413-416) restored as
--- an else (the SG2-5c bench's port).
function Mower:getDropArea(workArea)
    if not workArea.dropWindrow then
        return nil
    end
    local dropArea = nil
    if workArea.dropAreaIndex ~= nil then
        dropArea = self.spec_workArea.workAreas[workArea.dropAreaIndex]
        if dropArea == nil then
            workArea.dropAreaIndex = nil
        elseif dropArea.type ~= WorkAreaType.AUXILIARY then
            workArea.dropAreaIndex = nil
            dropArea = nil
        end
    end
    return dropArea
end
--- :541-561 VERBATIM through the quantities (the drop effects, :543-552, left out).
function Mower:onStartWorkAreaProcessing(_)
    local spec = self.spec_mower
    local workAreas = self:getTypedWorkAreas(WorkAreaType.MOWER)
    for i = 1, #workAreas do
        workAreas[i].pickedUpLiters = 0
    end
    spec.workAreaParameters.lastChangedArea = 0
    spec.workAreaParameters.lastStatsArea = 0
    spec.workAreaParameters.lastTotalArea = 0
    spec.isWorking = false
end
--- :562-566 VERBATIM (the drop loop; the effects, statistics and sound after it left out).
function Mower:onEndWorkAreaProcessing(dt, _)
    local spec = self.spec_mower
    for _, dropArea in ipairs(spec.dropAreas) do
        self:processDropArea(dropArea, dt)
    end
end

--- A mower (vehicleTypes.xml `mower`: baseGroundTool, turnOnVehicle, fruitExtraObjects, mower,
--- workMode; no fill unit, so no spec_fillUnit), its functions COPIED into the instance
--- (Vehicle.lua:486), built through Mower:onLoad (abbreviated to the converters, the drop effects
--- and the work-area parameters) and its work areas through Mower:loadWorkAreaFromXML: the cut at
--- x -1..1, z -0.5..0.5 (two fruit pixels, the SG2-5c bench's), dropping into its AUXILIARY drop
--- area at x 20..22, the meadow converted to grass windrow at 200.37 L per scaled square metre.
--- opts.factor another conversion factor; opts.cutDropsTo = 3 binds the cut to a third area of another
--- type (a changed binding in the same layout); opts.extraDrop adds a second AUXILIARY area (a changed layout);
--- opts.configFileName another configuration.
function ENGINE_NEW_MOWER(uid, opts)
    opts = opts or {}
    local v = baseVehicle(uid, opts.configFileName or "data/vehicles/mower.xml")
    v.getLastSpeed = function() return 0 end
    v.getIsAIActive = function() return false end
    v.setTestAreaRequirements = function() end
    v.processMowerArea, v.processDropArea, v.getDropArea = Mower.processMowerArea, Mower.processDropArea, Mower.getDropArea
    -- The converter's factor is not a round number, so its litres are no float32 and the save's FLOAT
    -- rounding shows (the SG2-5c bench's 200, with .37 added).
    v.spec_mower = { fruitTypeConverters = opts.converters or { [FruitType.MEADOW] = { fillTypeIndex = GRASS_W, conversionFactor = opts.factor or 200.37 } },
        dropEffects = {}, isWorking = false, stoneLastState = 0, lastDropTime = 0,
        workAreaParameters = { lastInputGrowthState = 0, lastCutTime = 0, lastChangedArea = 0, lastStatsArea = 0, lastTotalArea = 0, lastUsedAreas = 0, lastUsedAreasSum = 0 } }
    local cs, cw, ch = corners(-1, 1, 0)
    local ds, dw, dh = corners(20, 22, 0)
    local defs = { { start = cs, width = cw, height = ch, attrs = { [".mower#dropAreaIndex"] = opts.cutDropsTo or 2 } },
                   { type = WorkAreaType.AUXILIARY, start = ds, width = dw, height = dh } }
    if opts.cutDropsTo ~= nil then
        local os_, ow, oh = corners(30, 32, 0)
        defs[3] = { type = WorkAreaType.OTHER, start = os_, width = ow, height = oh }
    end
    if opts.extraDrop then
        local es, ew, eh = corners(30, 32, 0)
        defs[3] = { type = WorkAreaType.AUXILIARY, start = es, width = ew, height = eh }
    end
    loadWorkAreas(v, Mower, defs, { [WorkAreaType.MOWER] = "processMowerArea" })
    v.specClasses = { Mower }
    v.specializations = { ENGINE_WORKAREA, Mower }
    v.specializationNames = { "workArea", "mower" }
    v.eventListeners = { onPostLoad = { Mower } }
    return v
end
--- WorkArea's tick for a Mower (WorkArea.lua:124-200): the start event, each MOWER area's
--- captured pointer, the end event (the drop loop).
function ENGINE_MOWER_TICK(v)
    Mower.onStartWorkAreaProcessing(v, nil)
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        if wa.processingFunction ~= nil then wa.processingFunction(v, wa, 16) end
    end
    Mower.onEndWorkAreaProcessing(v, 16, nil)
end

--- SpecializationManager:addSpecialization (:68-95, from loadMapData, MPLoadingScreen.lua:352) sources
--- each specialization's file again on every map load: Tedder.lua:1 and Mower.lua:1 make NEW class
--- tables, the native functions only, nothing a mod wrote on the old ones. A mod is not sourced again
--- (mods.lua:974-979). MODELED: fresh tables from the pristine classes this file defined.
local PRISTINE = { Tedder = {}, Mower = {} }
for k, v in pairs(Tedder) do PRISTINE.Tedder[k] = v end
for k, v in pairs(Mower) do PRISTINE.Mower[k] = v end
function ENGINE_RESOURCE_FIELD_TOOLS()
    local t, m = {}, {}
    for k, v in pairs(PRISTINE.Tedder) do t[k] = v end
    for k, v in pairs(PRISTINE.Mower) do m[k] = v end
    Tedder, Mower = t, m
end

--- SpecializationManager.lua:97-104 MODELED (the SG2-3 model's, over every class the models define):
--- each specialization's initSpecialization, read from its class table when called.
g_specializationManager.initSpecializations = function()
    for _, specialization in ipairs({ ENGINE_FILLUNIT, Combine, Tedder, Mower }) do
        if specialization.initSpecialization ~= nil then specialization.initSpecialization() end
    end
end

-- ── THE ENGINE'S FLOAT WRITER (MAINTENANCE row 206's model, its G rows check it) ──────────────
-- An XMLValueType.FLOAT is written as its float32, to six decimals, ties to even, and read back
-- as the float32 of that text. Every schema FLOAT path of every file goes through it.
local function f32(x) return (string.unpack("<f", string.pack("<f", x))) end
local function halfEvenInt(z)
    local r = math.floor(z)
    local f = z - r
    if f > 0.5 or (f == 0.5 and r % 2 == 1) then r = r + 1 end
    return r
end
function ENGINE_WRITE_FLOAT(x)
    local y = f32(x)
    local neg = y < 0
    if neg then y = -y end
    local s = string.format("%.0f", halfEvenInt(y * 1000000))
    while #s < 7 do s = "0" .. s end
    return (neg and "-" or "") .. s:sub(1, -7) .. "." .. s:sub(-6)
end
local function isFloatPath(o, k)
    local pd = o.schema ~= nil and o.schema.paths[(string.gsub(k, "%(%d*%)", "(?)"))] or nil
    return pd ~= nil and pd.valueTypeId == "FLOAT"
end
local createXml, loadXml = XMLFile.create, XMLFile.load
local function faithful(o)
    if o == nil then return nil end
    local set, get = o.setValue, o.getValue
    function o:setValue(k, v)
        if type(v) == "number" and isFloatPath(self, k) then return set(self, k, ENGINE_WRITE_FLOAT(v)) end
        return set(self, k, v)
    end
    function o:getValue(k, d)
        local v = get(self, k, d)
        if type(v) == "string" and isFloatPath(self, k) then return f32(tonumber(v)) end
        return v
    end
    return o
end
XMLFile.create = function(...) return faithful(createXml(...)) end
XMLFile.load = function(...) return faithful(loadXml(...)) end
XMLFile.loadIfExists = XMLFile.load
