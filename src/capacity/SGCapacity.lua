-- =========================================================
-- FS25_StockGuard - native material capacity controller (SG-6 core)
-- =========================================================
-- One session-local controller. It sizes native fill identity during
-- registration, arranges Soil's ground preparation before native ground
-- initialization, fixes the realized profile before the first object data,
-- admits peers against that profile, and ends with the mission. Native
-- managers keep their definitions, quantities, map data and lifecycle.
--
-- Phases: LOADING (sizing open), READY (frozen, admitting), FAILED (first
-- immutable reason retained, completion refused once).
--
-- SCOPE (Tyson through Operator, 2026-09-15, after Bob's cold review):
-- the core is built from the decompiled engine scripts on D:. Of the brief's
-- third-party packages, the startup-floor writers whose sources are in the
-- Active Mods zips on C: are BOUND here as named floor writers (fixed
-- extender 9, Realistic Livestock 10, Montana's temporary map-loading width),
-- realSilo is bound as the consumer bound 16383 plus integration bit 2 (its
-- events stay untouched; no source needed for that contract), and four
-- packages are REFUSED at preflight: ProductionControl and Pumps N' Hoses
-- because brief 4.7 requires their stream-tail adapters (build-now items
-- before release), and UnlimitedFillTypes and Distribution Redux as the
-- accepted interim scope. The brief's unknown-writer rule (line 277) covers
-- writers of the changed formats only; floor owners are supported neighbours
-- (line 276). Packages are matched by exact native modName, never substring.
-- See ADAPTERS below.
--
-- Engine seams (D:\FS25_Decoded\dataS\scripts_decompiled):
--   FillTypeManager SEND_NUM_BITS :6, loadMapData :65, unloadMapData :98,
--     addFillType :203 (index = #fillTypes + 1, refuses at 2^bits - 1)
--   Mission00:setMissionInfo mission00.lua:98 (queues map tasks); cancelLoading
--     read by the next task; OnInGameMenuMenu menu.lua:66 (flush + teardown)
--   DensityMapHeightManager sortHeightTypes :187, loadFromXMLFile lowercase
--     tipTypeMappings :150-164, initialize :350 (overlap warning :378;
--     heightToDensityValue :374, the updater :382, forceTypeConversion :398-408),
--   SnowSystem:onTerrainLoad SnowSystem.lua:89-125 (1 / heightToDensityValue :108),
--     FSBaseMission terrain order :1375 initialize, :1384 snow, :1391 TERRAIN target,
--     heightTypeFirstChannel/NumChannels :117-118
--   FSBaseMission densityMapHeightXMLLoad :1372 (loadFromXMLFile then
--     initialize), missionInfo:getIsDensityMapValid :1933, onFinishedLoading :701
--     (sends BaseMissionFinishedLoadingEvent), onConnectionFinishedLoading :731,
--     onConnectionRequestAnswer :652; missionDynamicInfo.mods FSCareerMissionInfo:366
--   BaseMissionFinishedLoadingEvent events/...:16-29 (readStream runs itself)
--   ConnectionRequestAnswerEvent UIntN 4, answers 0..7 (:4-11, :28); 8 is free
--   InfoDialog.show gui/dialogs/InfoDialog.lua:8; Utils.overwrittenFunction utils/Utils.lua:394
-- =========================================================

SGCapacity = SGCapacity or {}
SGCapacity_mt = Class(SGCapacity)

SGCapacity.PHASE_LOADING = "LOADING"
SGCapacity.PHASE_READY   = "READY"
SGCapacity.PHASE_FAILED  = "FAILED"

SGCapacity.PROTOCOL_VERSION  = 2
SGCapacity.MIN_WIDTH         = 8
SGCapacity.MAX_WIDTH         = 15
SGCapacity.FRAMING_BOUND     = 32767
SGCapacity.ANSWER_PROFILE_MISMATCH = 8

-- The adapter records. modNames are exact native modName spellings (matched
-- case-insensitively, whole string, never substring). role:
--   floor      a named startup-floor writer (brief 4.5); bound records supply
--              floorBits from their real source
--   temporary  Montana's map-loading width (10 during loadMapData, restored
--              to max(required, old) after): never a floor, never a refusal
--   consumer   realSilo: an actual maximum registered id and a profile flag
--   tail       a stream-tail adapter the brief requires (4.7); unbound here
-- A selected record with bound = false is refused at preflight with
-- UNBOUND_ADAPTER and the package name.
SGCapacity.ADAPTERS = {
    { key = "productionControl", modNames = { "FS25_ProductionControl" }, role = "tail", flagBit = 1, bound = false,
      basis = "brief 4.7: the appended stream tail must be composed; build-now item" },
    { key = "pumpsAndHoses", modNames = { "pdlc_pumpsAndHosesPack" }, role = "tail", flagBit = 2, bound = false,
      basis = "brief 4.7: all four SandboxProductionPoint callbacks required; build-now item" },
    { key = "realSilo", modNames = { "FS25_realSilo" }, role = "consumer", flagBit = 4, consumerBound = 16383, bound = true,
      basis = "brief 4.5/4.7: maximum registered id 16383, flag bit 2, events untouched" },
    { key = "unlimitedFillTypes", modNames = { "FS25_UnlimitedFillTypes" }, role = "floor", floorBits = 12, bound = false,
      basis = "accepted interim (Tyson 2026-09-15): source not on C:" },
    { key = "fillTypeExtender", modNames = { "FS25_fillTypeExtender" }, role = "floor", floorBits = 9, bound = true,
      basis = "FS25_fillTypeExtender.zip src/fillTypeExtender.lua:3-6 (SEND_NUM_BITS < 9 -> 9 at file load)" },
    { key = "distributionRedux", modNames = { "FS25_DistributionRedux", "FS25_Distribution_Redux" }, role = "floor", floorBits = 10, bound = false,
      basis = "accepted interim (Tyson 2026-09-15): source not on C:" },
    { key = "realisticLivestock", modNames = { "FS25_RealisticLivestockRM", "FS25_RealisticLivestock" }, role = "floor", floorBits = 10, bound = true,
      basis = "FS25_RealisticLivestockRM.zip scripts/fillTypes/RealisticLivestock_FillTypeManager.lua:6 (SEND_NUM_BITS < 10 -> 10 at file load; :17 appends its fill types to loadMapData)" },
    -- Ours. Added when SoilFertilizer absorbed FillType Extender's capability so
    -- players on large maps can drop that mod. Our floor is 10, ABOVE FTE's 9 and
    -- equal to Realistic Livestock's, because 9 caps at 511 and the one heavy modset
    -- anyone has measured carries 513+ live fill types. A player dropping FTE still
    -- sees no regression: 10 is strictly above 9 and we never lower. Declared here
    -- rather than discovered later, because a width writer the fleet does not know
    -- about is one found by accident. This record and the source it cites shipped
    -- together.
    { key = "soilFertilizer", modNames = { "FS25_SoilFertilizer" }, role = "floor", floorBits = 10, bound = true,
      basis = "FS25_SoilFertilizer src/utils/SoilFillTypeWidth.lua FLOOR_BITS = 10, raises only when current < floor and never lowers; called at top-level file scope from src/main.lua before any addFillType. 10 rather than FillType Extender's 9 deliberately: 9 caps at 511 and a measured tester modset carries 513+ live fill types" },
    { key = "montana", modNames = { "FS25_Montana_MF" }, role = "temporary", temporaryWidth = 10, bound = true,
      basis = "FS25_Montana_MF.zip multifruit/scripts/FillTypeLimitIncrease.lua:22-33 (10 during loadMapData, then max(getNumRequiredBits(#fillTypes), old), utils/MathUtil.lua:707)" },
}
SGCapacity.UNBOUND_ADAPTERS = SGCapacity.ADAPTERS   -- earlier name, same table
SGCapacity.SOIL_MOD_NAME = "FS25_SoilFertilizer"

--- The adapter record a native modName selects, or nil. Exact whole-string
--- comparison, case-insensitive: "FS25_DistributionCenterMap" selects nothing.
function SGCapacity.matchAdapter(modName)
    if type(modName) ~= "string" then return nil end
    local lower = string.lower(modName)
    for _, a in ipairs(SGCapacity.ADAPTERS) do
        for _, n in ipairs(a.modNames) do
            if string.lower(n) == lower then return a end
        end
    end
    return nil
end

local function log(msg) print("[StockGuard] capacity: " .. tostring(msg)) end
local function isInt(n) return type(n) == "number" and n == math.floor(n) and n == n end

-- =========================================================
-- Construction and state
-- =========================================================
function SGCapacity.new()
    local self = setmetatable({}, SGCapacity_mt)
    self.phase = SGCapacity.PHASE_LOADING
    self.reasonCode = nil
    self.offending = nil
    self.widthBits = nil                 -- the width this controller last owned/froze
    self.externalStartupFloor = nil      -- captured before SG-6 growth, kept across unload
    self.ownGrowth = nil
    self.consumerBound = 2 ^ SGCapacity.MAX_WIDTH - 1
    self.registeredCount = nil
    self.names = nil
    self.profile = nil
    self.groundSignature = nil           -- from the initialize pass
    self.groundInitialized = false
    self.groundTypeBits = nil
    self.groundCapacity = nil
    self.mission = nil
    self.mapId = nil
    self.soilApi = nil
    self.soilJoined = false
    self.integrationFlags = 0
    self.formatFlags = SGCanonicalProfile.FORMAT_WIDE_COUNTS + SGCanonicalProfile.FORMAT_SELF_STORAGE
    self.admitted = {}                   -- connection -> true
    self.noticeIssued = false
    self.completionDone = false
    self.nextLoadIncompatible = nil
    self.lastWireRefusal = nil
    self.namedFloor = nil                -- max floorBits of the selected bound floor writers
    self.temporaryWidthWriter = nil      -- Montana's loading width when selected
    self.selectedFloorWriters = nil      -- { {adapterKey, nativeModName, floorBits}, ... } for this mission
    self.retainedFloorWriters = nil      -- the previous mission's records (brief 4.5)
    self.savedMappingLoaded = nil        -- loadFromXMLFile result for the accepted save (nil = not observed)
    self.savedMappingDuplicate = nil     -- first duplicate lowercase name in the raw XML rows
    self.wireNoticeIssued = false
    return self
end

function SGCapacity:isReady() return self.phase == SGCapacity.PHASE_READY end
function SGCapacity:getFrozenWidth() return self.widthBits or FillTypeManager.SEND_NUM_BITS end
function SGCapacity:getFrozenRegisteredCount() return self.registeredCount end

function SGCapacity:fail(reason, offending)
    if self.phase == SGCapacity.PHASE_FAILED then return false end
    self.phase = SGCapacity.PHASE_FAILED
    self.reasonCode = reason
    self.offending = offending
    log(string.format("FAILED: %s%s", tostring(reason), offending ~= nil and (" (" .. tostring(offending) .. ")") or ""))
    return false
end

--- Detached state for consumers (4.3).
function SGCapacity:getState()
    return {
        phase = self.phase, reasonCode = self.reasonCode, offending = self.offending,
        widthBits = self:isReady() and self.widthBits or nil,
        registeredCount = self:isReady() and self.registeredCount or nil,
        typeCapacity = self:isReady() and (2 ^ self.widthBits - 1) or nil,
        groundTypeBits = self:isReady() and self.groundTypeBits or nil,
        groundCapacity = self:isReady() and self.groundCapacity or nil,
        integrationFlags = self.integrationFlags, formatFlags = self.formatFlags,
        protocolVersion = SGCapacity.PROTOCOL_VERSION,
        consumerBound = self.consumerBound,
        selectedFloorWriters = self:copyFloorWriters(),
    }
end

function SGCapacity:copyFloorWriters()
    local out = {}
    for _, w in ipairs(self.selectedFloorWriters or {}) do
        out[#out + 1] = { adapterKey = w.adapterKey, nativeModName = w.nativeModName, floorBits = w.floorBits }
    end
    return out
end

--- Detached availability for one canonical material name.
function SGCapacity:getMaterialAvailability(name)
    local out = { nativeRegistered = false, groundRegistered = false, canBeTipped = false, reasonCode = "UNAVAILABLE" }
    if not self:isReady() or type(name) ~= "string" then out.reasonCode = self.phase == SGCapacity.PHASE_READY and "UNKNOWN_NAME" or "NOT_READY" return out end
    for i, n in ipairs(self.names) do
        if n == name then out.nativeRegistered = true out.nativeIndex = i break end
    end
    if not out.nativeRegistered then out.reasonCode = "UNKNOWN_NAME" return out end
    for _, g in ipairs(self.groundSignature or {}) do
        if g.name == name then
            out.groundRegistered = true
            out.groundIndex = g.index
            out.canBeTipped = g.canBeTipped == true
        end
    end
    out.reasonCode = "OK"
    return out
end

-- =========================================================
-- Width sizing (LOADING only)
-- =========================================================
function SGCapacity.requiredWidth(nextIndex)
    local b = SGCapacity.MIN_WIDTH
    while nextIndex > 2 ^ b - 1 and b < SGCapacity.MAX_WIDTH do b = b + 1 end
    return b
end

--- Decide the width for a registration that will take nextIndex. Returns
--- bits or nil, reason. Does not write the native field.
function SGCapacity:sizeFor(nextIndex, currentWidth)
    if self.phase ~= SGCapacity.PHASE_LOADING then return nil, "FROZEN" end
    if not isInt(nextIndex) or nextIndex < 1 then return nil, "INVALID" end
    if not isInt(currentWidth) or currentWidth < SGCapacity.MIN_WIDTH or currentWidth > SGCapacity.MAX_WIDTH then
        return nil, "INVALID_WIDTH"   -- never silently treated as eight and overwritten
    end
    local cur = currentWidth
    local floor = self.externalStartupFloor or SGCapacity.MIN_WIDTH
    local b = math.max(cur, floor, SGCapacity.MIN_WIDTH, SGCapacity.requiredWidth(nextIndex))
    if nextIndex > 2 ^ b - 1 or b > SGCapacity.MAX_WIDTH then return nil, "CAPACITY" end
    if nextIndex > self.consumerBound or nextIndex > SGCapacity.FRAMING_BOUND then return nil, "CAPACITY" end
    return b, "ADMITTED"
end

--- Map-data entry: apply the named selected floors and capture an
--- established larger valid width before growth. The floor is the maximum of
--- the named bound floor writers (brief 4.5); a larger observed width is kept
--- only when it cannot be Montana's temporary loading width (a temporary
--- writer is selected and the observed width equals its value), so that
--- width is never promoted into the floor. setWidth, when given, raises the
--- native field to the floor before default registration.
function SGCapacity:onMapDataEntry(currentWidth, setWidth)
    if self.nextLoadIncompatible ~= nil then
        self:fail(self.nextLoadIncompatible.reason, self.nextLoadIncompatible.offending)
        self.nextLoadIncompatible = nil
        return
    end
    local floor = math.max(SGCapacity.MIN_WIDTH, self.namedFloor or SGCapacity.MIN_WIDTH)
    if isInt(currentWidth) and currentWidth >= SGCapacity.MIN_WIDTH and currentWidth <= SGCapacity.MAX_WIDTH and currentWidth > floor then
        if self.temporaryWidthWriter ~= nil and currentWidth == self.temporaryWidthWriter then
            log(string.format("map-data entry width %d is the selected temporary loading width; not a floor", currentWidth))
        else
            floor = currentWidth
        end
    end
    if self.externalStartupFloor == nil or floor > self.externalStartupFloor then
        self.externalStartupFloor = floor
    end
    self.widthBits = math.max(self.externalStartupFloor, SGCapacity.MIN_WIDTH)
    if setWidth ~= nil and isInt(currentWidth) and currentWidth < self.widthBits then
        setWidth(self.widthBits)
    end
end

--- Epoch reset at native unloadMapData entry. Restores the external floor
--- only when the native field still equals the width this controller owned.
function SGCapacity:onEpochReset(currentWidth, setWidth)
    if self.widthBits ~= nil and currentWidth ~= self.widthBits then
        self.nextLoadIncompatible = { reason = "EXTERNAL_WIDTH_CHANGE", offending = tostring(currentWidth) }
    elseif self.externalStartupFloor ~= nil and setWidth ~= nil then
        setWidth(self.externalStartupFloor)
    end
    if self.soilApi ~= nil and self.mission ~= nil then
        pcall(self.soilApi.endCapacityLoad, self.mission)
    end
    self.phase = SGCapacity.PHASE_LOADING
    self.reasonCode, self.offending = nil, nil
    self.ownGrowth = nil
    self.registeredCount, self.names, self.profile = nil, nil, nil
    self.groundSignature, self.groundInitialized = nil, false
    self.groundTypeBits, self.groundCapacity = nil, nil
    self.mission, self.mapId = nil, nil
    self.soilApi, self.soilJoined = nil, false
    self.integrationFlags = 0
    self.consumerBound = 2 ^ SGCapacity.MAX_WIDTH - 1
    self.admitted = {}
    self.noticeIssued, self.completionDone, self.wireNoticeIssued = false, false, false
    self.savedMappingLoaded, self.savedMappingDuplicate = nil, nil
    -- The adapter identities are retained across an ordinary unload (brief
    -- 4.5); the next preflight resolves the new selection against them.
    if self.selectedFloorWriters ~= nil then self.retainedFloorWriters = self.selectedFloorWriters end
    self.selectedFloorWriters = nil
    self.widthBits = self.externalStartupFloor
end

-- =========================================================
-- Preflight (first action of the setMissionInfo wrapper)
-- =========================================================
local function modNamesOf(missionDynamicInfo)
    local names = {}
    local mods = missionDynamicInfo ~= nil and missionDynamicInfo.mods or nil
    if type(mods) == "table" then
        for _, item in pairs(mods) do
            local n = type(item) == "table" and item.modName or item
            if type(n) == "string" then names[#names + 1] = n end
        end
    end
    return names
end

--- Returns ok, reason, offending. resolveSoil() returns the Soil API table or nil.
local function writerIdentity(records)
    local ids = {}
    for _, w in ipairs(records or {}) do ids[#ids + 1] = w.adapterKey .. ":" .. w.nativeModName .. ":" .. tostring(w.floorBits) end
    table.sort(ids)
    return table.concat(ids, ",")
end
SGCapacity.writerIdentity = writerIdentity

function SGCapacity:preflight(mission, missionDynamicInfo, resolveSoil)
    if type(mission) ~= "table" then return false, "INVALID_MISSION", nil end
    self.mission = mission
    local names = modNamesOf(missionDynamicInfo)
    -- Selected adapter records, by exact native modName.
    local floorWriters = {}
    local namedFloor, temporary, consumerBound, flags = nil, nil, 2 ^ SGCapacity.MAX_WIDTH - 1, 0
    for _, n in ipairs(names) do
        local a = SGCapacity.matchAdapter(n)
        if a ~= nil then
            if not a.bound then return false, "UNBOUND_ADAPTER", n end
            if a.role == "floor" then
                floorWriters[#floorWriters + 1] = { adapterKey = a.key, nativeModName = n, floorBits = a.floorBits }
                if namedFloor == nil or a.floorBits > namedFloor then namedFloor = a.floorBits end
            elseif a.role == "temporary" then
                floorWriters[#floorWriters + 1] = { adapterKey = a.key, nativeModName = n, floorBits = nil }
                temporary = a.temporaryWidth
            elseif a.role == "consumer" then
                if a.consumerBound ~= nil and a.consumerBound < consumerBound then consumerBound = a.consumerBound end
                if a.flagBit ~= nil then flags = flags + a.flagBit end
            end
        end
    end
    -- A changed selection after an ordinary unload requires the native full
    -- reload path, never a stale selected set (brief 4.5). Equal floors do
    -- not make different writers identical: identity is key and modName.
    if self.retainedFloorWriters ~= nil and writerIdentity(self.retainedFloorWriters) ~= writerIdentity(floorWriters) then
        local offending = nil
        local seen = {}
        for _, w in ipairs(self.retainedFloorWriters) do seen[w.adapterKey .. ":" .. w.nativeModName] = true end
        for _, w in ipairs(floorWriters) do
            if not seen[w.adapterKey .. ":" .. w.nativeModName] then offending = w.nativeModName break end
        end
        if offending == nil then
            local now = {}
            for _, w in ipairs(floorWriters) do now[w.adapterKey .. ":" .. w.nativeModName] = true end
            for _, w in ipairs(self.retainedFloorWriters) do
                if not now[w.adapterKey .. ":" .. w.nativeModName] then offending = w.nativeModName break end
            end
        end
        return false, "SELECTION_CHANGED", offending
    end
    self.selectedFloorWriters = floorWriters
    self.namedFloor = namedFloor
    self.temporaryWidthWriter = temporary
    self.consumerBound = consumerBound
    self.integrationFlags = flags
    local soilSelected = false
    for _, n in ipairs(names) do if n == SGCapacity.SOIL_MOD_NAME then soilSelected = true end end
    if soilSelected then
        local api = resolveSoil ~= nil and resolveSoil() or nil
        if type(api) ~= "table" or api.protocolVersion ~= 2 or type(api.beginCapacityLoad) ~= "function"
            or type(api.prepareGroundTypes) ~= "function" or type(api.endCapacityLoad) ~= "function" then
            return false, "SOIL_PROTOCOL", SGCapacity.SOIL_MOD_NAME
        end
        local ok, began = pcall(api.beginCapacityLoad, mission)
        if not ok or began ~= true then
            return false, "SOIL_BEGIN_REFUSED", SGCapacity.SOIL_MOD_NAME
        end
        self.soilApi = api
        self.soilJoined = true
        self.integrationFlags = self.integrationFlags + SGCanonicalProfile.FLAG_SOIL_GROUND_PREP
    end
    return true, "OK", nil
end

--- The saved density-map mapping load, observed through the conditional
--- loadFromXMLFile wrapper: whether the native loader succeeded and the first
--- lowercase name that appears twice in the raw XML rows (the native loader
--- collapses duplicates, DensityMapHeightManager.lua:158-164, so the collapsed
--- table alone cannot show them).
function SGCapacity:onSavedMappingLoaded(loaded, duplicateName)
    self.savedMappingLoaded = loaded == true
    self.savedMappingDuplicate = duplicateName
end

-- =========================================================
-- Ground preparation (initialize wrapper)
-- =========================================================
--- channels = { typeFirst, typeNum, heightFirst, heightNum }; savedAccepted is
--- true for an accepted existing density-map save. Returns true or false.
function SGCapacity:prepareGround(heightManager, fillManager, channels, savedAccepted)
    if self.phase == SGCapacity.PHASE_FAILED then return false end
    if type(heightManager) ~= "table" or type(heightManager.heightTypes) ~= "table" then return self:fail("GROUND_MANAGER") end
    if type(heightManager.sortHeightTypes) == "function" then heightManager:sortHeightTypes() end
    local typeNum = channels.typeNum
    if not isInt(typeNum) or typeNum < 1 then return self:fail("GROUND_CHANNELS") end
    local capacity = 2 ^ typeNum - 1
    if self.soilJoined and self.soilApi ~= nil then
        local ok, prepared, reason, name = pcall(self.soilApi.prepareGroundTypes, heightManager, fillManager, capacity)
        if not ok then return self:fail("SOIL_PREPARE_THREW", tostring(prepared)) end
        if prepared ~= true then return self:fail("SOIL_PREPARE:" .. tostring(reason), name) end
    end
    -- Channel layout: type range and height range must not overlap.
    local tf, hf, hn = channels.typeFirst, channels.heightFirst, channels.heightNum
    if isInt(tf) and isInt(hf) and isInt(hn) and hf < tf + typeNum and tf < hf + hn then
        return self:fail("GROUND_CHANNEL_OVERLAP")
    end
    -- Definitions: unique in-range indices and known names.
    local sig, seenIdx, seenName = {}, {}, {}
    for _, ht in ipairs(heightManager.heightTypes) do
        local idx, name = ht.index, ht.fillTypeName
        if not isInt(idx) or idx < 1 or idx > capacity or seenIdx[idx] then return self:fail("GROUND_INDEX", tostring(name)) end
        if type(name) ~= "string" or name == "" or seenName[name] then return self:fail("GROUND_NAME", tostring(name)) end
        seenIdx[idx], seenName[name] = true, true
        sig[#sig + 1] = { index = idx, name = name, canBeTipped = ht.canBeTipped == true, fillTypeIndex = ht.fillTypeIndex }
    end
    table.sort(sig, function(a, b) return a.index < b.index end)
    -- Saved mapping (lowercase keys) must reproduce at the same indices.
    if savedAccepted then
        if self.savedMappingLoaded == false then return self:fail("SAVED_MAPPING_MISSING", "loadFromXMLFile") end
        if self.savedMappingDuplicate ~= nil then return self:fail("SAVED_MAPPING_DUPLICATE", self.savedMappingDuplicate) end
        local saved = heightManager.tipTypeMappings
        if type(saved) ~= "table" or next(saved) == nil then return self:fail("SAVED_MAPPING_MISSING") end
        local byLower = {}
        for _, g in ipairs(sig) do byLower[string.lower(g.name)] = g.index end
        local used = {}
        for lname, index in pairs(saved) do
            if not isInt(index) or index < 1 or used[index] then return self:fail("SAVED_MAPPING_INVALID", lname) end
            used[index] = true
            if byLower[lname] ~= index then return self:fail("SAVED_MAPPING_CHANGED", lname) end
        end
    end
    self.groundSignature = sig
    self.groundTypeBits = typeNum
    self.groundCapacity = capacity
    return true
end

function SGCapacity:markGroundInitialized(updaterExists)
    self.groundInitialized = updaterExists == true
end

-- =========================================================
-- Final freeze (first action of the onFinishedLoading wrapper)
-- =========================================================
--- Returns true when READY, false when the failure completion must run.
--- The freeze reads the FINAL native field and requires it to cover the
--- realized registry, the external floor and the named floors; a temporary
--- loading width (Montana) that was restored by now is therefore no failure,
--- while a field too narrow for the registered count is. zeroGround marks a
--- map without a terrainDetailHeight layer, where native initialize never
--- runs (FSBaseMission.lua:1370) and an empty ground layout is the truth.
function SGCapacity:freeze(fillManager, heightManager, mapId, channels, currentWidth, zeroGround)
    if self.phase == SGCapacity.PHASE_FAILED then return false end
    if not isInt(currentWidth) or currentWidth < SGCapacity.MIN_WIDTH or currentWidth > SGCapacity.MAX_WIDTH then return self:fail("INVALID_WIDTH", tostring(currentWidth)) end
    if type(fillManager) ~= "table" or type(fillManager.fillTypes) ~= "table" then return self:fail("FILL_MANAGER") end
    local names = {}
    for i, ft in ipairs(fillManager.fillTypes) do
        local n = ft.name
        if type(n) ~= "string" or n == "" then return self:fail("FILL_NAME", tostring(i)) end
        names[i] = n
    end
    if #names < 1 then return self:fail("NO_FILL_TYPES") end
    if #names > 2 ^ currentWidth - 1 or #names > self.consumerBound then return self:fail("CAPACITY", tostring(#names)) end
    local required = math.max(SGCapacity.MIN_WIDTH, self.externalStartupFloor or SGCapacity.MIN_WIDTH, SGCapacity.requiredWidth(#names))
    if currentWidth < required then return self:fail("INSUFFICIENT_WIDTH", tostring(currentWidth) .. "<" .. tostring(required)) end
    if self.groundSignature == nil and zeroGround == true then
        self.groundSignature = {}
        self.groundTypeBits = isInt(channels.typeNum) and channels.typeNum or 0
        self.groundCapacity = self.groundTypeBits > 0 and (2 ^ self.groundTypeBits - 1) or 0
        log("map without a terrainDetailHeight layer: zero-ground layout frozen")
    end
    if self.groundSignature == nil then return self:fail("GROUND_NOT_INITIALIZED") end
    -- The live roster must still equal the initialized signature.
    local live = {}
    for _, ht in ipairs(heightManager.heightTypes or {}) do live[#live + 1] = ht end
    if #live ~= #self.groundSignature then return self:fail("GROUND_CHANGED") end
    table.sort(live, function(a, b) return a.index < b.index end)
    for i, g in ipairs(self.groundSignature) do
        local ht = live[i]
        if ht.index ~= g.index or ht.fillTypeName ~= g.name or (ht.canBeTipped == true) ~= g.canBeTipped then return self:fail("GROUND_CHANGED", tostring(g.name)) end
    end
    local ground = {}
    for _, g in ipairs(self.groundSignature) do ground[#ground + 1] = { index = g.index, name = g.name, canBeTipped = g.canBeTipped } end
    local profile, why = SGCanonicalProfile.build({
        widthBits = currentWidth, mapId = mapId,
        typeFirstChannel = channels.typeFirst, typeNumChannels = channels.typeNum,
        heightFirstChannel = channels.heightFirst, heightNumChannels = channels.heightNum,
        integrationFlags = self.integrationFlags, effectiveMaximumNativeIndex = self.consumerBound,
        names = names, ground = ground,
    }, self.formatFlags)
    if profile == nil then return self:fail("PROFILE:" .. tostring(why)) end
    self.widthBits = currentWidth
    self.registeredCount = #names
    self.names = names
    self.mapId = mapId
    self.profile = profile
    self.phase = SGCapacity.PHASE_READY
    log(string.format("READY: width %d bits, %d fill types, %d ground types, map %s, digest %s", currentWidth, #names, #ground, tostring(mapId), profile.digestHex:sub(1, 16)))
    return true
end

--- The header this peer sends (client) or compares against (server).
function SGCapacity:getHeader()
    if not self:isReady() then return nil end
    local p = self.profile
    return { magic = SGCanonicalProfile.HEADER_MAGIC, version = p.version, widthBits = p.widthBits, registeredCount = p.registeredCount, formatFlags = p.formatFlags, digest = p.digest }
end

--- Server: admit a joining connection's header. Returns true or false, component.
function SGCapacity:admit(connection, header)
    if not self:isReady() then return false, "not-ready" end
    if not SGCanonicalProfile.headerIsWellFormed(header) then return false, "header" end
    local ok, component = SGCanonicalProfile.compare(self:getHeader(), header)
    if not ok then return false, component end
    self.admitted[connection] = true
    return true, nil
end

--- A refused material frame closes synchronization with that peer (brief
--- 4.7: invalid data closes synchronization, never a partial list). On the
--- server the offending connection is closed; on a client the session with
--- the server ends through the same notice-and-teardown path as answer 8.
function SGCapacity:refuseConnection(what, why, connection)
    self.lastWireRefusal = { what = what, why = why }
    log(string.format("wire refusal: %s (%s); no partial material update applied; synchronization closed", tostring(what), tostring(why)))
    if g_server ~= nil then
        if connection ~= nil then pcall(function() g_server:closeConnection(connection) end) end
        return
    end
    if self.wireNoticeIssued then return end
    self.wireNoticeIssued = true
    if g_currentMission ~= nil then g_currentMission.connectionWasClosed = true end
    local key = "sg6_profile_mismatch"
    local text = (g_i18n ~= nil and g_i18n:getText(key)) or key
    if text == key or text == "" then text = "StockGuard: the material and map capacity profile differs from the server. Obtain the matching setup and consult the host log." end
    local function teardown() if OnInGameMenuMenu ~= nil then OnInGameMenuMenu() end end
    if InfoDialog ~= nil and InfoDialog.INSTANCE ~= nil and InfoDialog.show ~= nil then InfoDialog.show(text, teardown, nil) else teardown() end
end

-- =========================================================
-- Notices and completion
-- =========================================================
function SGCapacity:noticeText()
    local key = "sg6_capacity_refused"
    local text = (g_i18n ~= nil and g_i18n:getText(key)) or key
    if text == key or text == "" then text = "StockGuard could not arrange material capacity for this session: %s. Loading stops so no goods are misread." end
    local reason = tostring(self.reasonCode or "UNKNOWN")
    if self.offending ~= nil then reason = reason .. " (" .. tostring(self.offending) .. ")" end
    return string.format(text, reason)
end

--- The one failure-completion path: cancel, notice once, native teardown.
function SGCapacity:presentFailure(mission)
    if self.noticeIssued then return end
    self.noticeIssued = true
    if mission ~= nil then mission.cancelLoading = true end
    local text = self:noticeText()
    log(text)
    local function teardown() if OnInGameMenuMenu ~= nil then OnInGameMenuMenu() end end
    if InfoDialog ~= nil and InfoDialog.INSTANCE ~= nil and InfoDialog.show ~= nil and g_dedicatedServer == nil then
        InfoDialog.show(text, teardown, nil)
    else
        teardown()
    end
end

-- =========================================================
-- Hook installation (once per process)
-- =========================================================
local controller = nil

local function channelsNow()
    local hm = g_densityMapHeightManager
    local id = g_currentMission ~= nil and g_currentMission.terrainDetailHeightId or nil
    local hf, hn = nil, nil
    if id ~= nil and id ~= 0 and getDensityMapHeightFirstChannel ~= nil then
        local ok1, a = pcall(getDensityMapHeightFirstChannel, id)
        local ok2, b = pcall(getDensityMapHeightNumChannels, id)
        if ok1 then hf = a end
        if ok2 then hn = b end
    end
    return { typeFirst = hm and hm.heightTypeFirstChannel or 0, typeNum = hm and hm.heightTypeNumChannels or 6, heightFirst = hf or 0, heightNum = hn or 0 }
end

local function resolveSoilApi()
    local env = _G[SGCapacity.SOIL_MOD_NAME]
    if type(env) ~= "table" then return nil end
    return env.SoilCapacityIntegration
end

function SGCapacity.installHooks(ctl)
    controller = ctl
    -- The install-once flag lives on the global table so a re-sourced main.lua
    -- (a mods-set change at the main menu) cannot stack a second set of hooks.
    if SGCapacity._hooksInstalled then return true end
    SGCapacity._hooksInstalled = true

    -- Registration sizing and the READY guard, one wrapper for the process.
    if FillTypeManager ~= nil and type(FillTypeManager.addFillType) == "function" then
        local native = FillTypeManager.addFillType
        SGCapacity._addFillTypeGuard = function(self, fillTypeDesc)
            if controller:isReady() then
                log("late fill type registration refused after freeze: " .. tostring(fillTypeDesc and fillTypeDesc.name))
                return false
            end
            if controller.phase == SGCapacity.PHASE_LOADING then
                local nextIndex = #self.fillTypes + 1
                local bits, why = controller:sizeFor(nextIndex, FillTypeManager.SEND_NUM_BITS)
                if bits == nil then
                    controller:fail(why, tostring(fillTypeDesc and fillTypeDesc.name))
                    return false
                end
                if bits ~= FillTypeManager.SEND_NUM_BITS then
                    FillTypeManager.SEND_NUM_BITS = bits
                    controller.ownGrowth = bits
                end
                controller.widthBits = bits
            end
            return native(self, fillTypeDesc)
        end
        FillTypeManager.addFillType = SGCapacity._addFillTypeGuard
        local nativeLoad = FillTypeManager.loadMapData
        FillTypeManager.loadMapData = function(self, ...)
            controller:onMapDataEntry(FillTypeManager.SEND_NUM_BITS, function(w) FillTypeManager.SEND_NUM_BITS = w end)
            return nativeLoad(self, ...)
        end
        local nativeUnload = FillTypeManager.unloadMapData
        FillTypeManager.unloadMapData = function(self, ...)
            controller:onEpochReset(FillTypeManager.SEND_NUM_BITS, function(w) FillTypeManager.SEND_NUM_BITS = w end)
            return nativeUnload(self, ...)
        end
    end

    -- Preflight before any map work.
    if Mission00 ~= nil and type(Mission00.setMissionInfo) == "function" then
        Mission00.setMissionInfo = Utils.overwrittenFunction(Mission00.setMissionInfo, function(mission, superFunc, missionInfo, missionDynamicInfo)
            local ok, reason, offending = controller:preflight(mission, missionDynamicInfo, resolveSoilApi)
            if not ok then
                controller:fail(reason, offending)
                controller:presentFailure(mission)
                return
            end
            return superFunc(mission, missionInfo, missionDynamicInfo)
        end)
    end

    -- The saved mapping load: record the native result and scan the raw rows
    -- for duplicate names before the native loader collapses them.
    if DensityMapHeightManager ~= nil and type(DensityMapHeightManager.loadFromXMLFile) == "function" then
        DensityMapHeightManager.loadFromXMLFile = Utils.overwrittenFunction(DensityMapHeightManager.loadFromXMLFile, function(hm, superFunc, xmlFilename)
            local ok = superFunc(hm, xmlFilename)
            local duplicate = nil
            if ok == true and xmlFilename ~= nil and XMLFile ~= nil and type(XMLFile.load) == "function" then
                local xmlFile = XMLFile.load("sg6DensityMapHeightScan", xmlFilename)
                if xmlFile ~= nil then
                    local seen = {}
                    pcall(function()
                        xmlFile:iterate("tipTypeMappings.tipTypeMapping", function(_, key)
                            local name = xmlFile:getString(key .. "#fillType")
                            if name ~= nil then
                                local lower = string.lower(name)
                                if seen[lower] and duplicate == nil then duplicate = lower end
                                seen[lower] = true
                            end
                        end)
                    end)
                    xmlFile:delete()
                end
            end
            controller:onSavedMappingLoaded(ok == true, duplicate)
            return ok
        end)
    end

    -- Ground preparation before native initialization.
    if DensityMapHeightManager ~= nil and type(DensityMapHeightManager.initialize) == "function" then
        DensityMapHeightManager.initialize = Utils.overwrittenFunction(DensityMapHeightManager.initialize, function(hm, superFunc, isServer, ...)
            local mi = g_currentMission and g_currentMission.missionInfo
            local savedAccepted = false
            if mi ~= nil and mi.isValid and type(mi.getIsDensityMapValid) == "function" then
                local ok, v = pcall(mi.getIsDensityMapValid, mi, g_currentMission)
                savedAccepted = ok and v == true
            end
            if controller:prepareGround(hm, g_fillTypeManager, channelsNow(), savedAccepted) then
                local results = { superFunc(hm, isServer, ...) }
                local updater = type(hm.getTerrainDetailHeightUpdater) == "function" and hm:getTerrainDetailHeightUpdater() or nil
                controller:markGroundInitialized(updater ~= nil)
                return unpack(results)
            end
            -- FAILED (MAINTENANCE row 140; Tyson's ruling 2026-09-26, DEVIATES from the SG-6
            -- brief's "skips native initialize" in service of its 4.9, "failure returns the
            -- user to a usable loading/mod-selection route"). Skipping native initialize left
            -- heightToDensityValue and the updater unset (DensityMapHeightManager.lua:374,
            -- :382), so the terrain load died in SnowSystem:onTerrainLoad (1 / nil,
            -- SnowSystem.lua:108) before hitLoadingTarget(TERRAIN) (FSBaseMission.lua:1375,
            -- :1384, :1391), and finished loading, where the failure is presented, never came.
            -- So native initialize runs, with the saved mapping WITHHELD: with no
            -- tipTypeMappings native requests no type conversion (:398-408), so it never
            -- interprets a saved raster under a mapping SG-6 refused (the reason the brief
            -- skipped it, "refuse before initialization"). The ground is NOT marked
            -- initialized, the phase stays FAILED, and the finished-loading wrapper presents
            -- the failure and cancels the load; nothing is saved.
            hm.tipTypeMappings = nil
            return superFunc(hm, isServer, ...)
        end)
    end

    -- Final freeze and the failure-completion site.
    if FSBaseMission ~= nil and type(FSBaseMission.onFinishedLoading) == "function" then
        FSBaseMission.onFinishedLoading = Utils.overwrittenFunction(FSBaseMission.onFinishedLoading, function(mission, superFunc, ...)
            local mapId = mission.missionInfo and mission.missionInfo.mapId or nil
            -- Another mod's hook on one of the SG-6 stream pairs after our
            -- install would be skipped silently while READY; that is an
            -- omitted adapter and fails the load naming Class.method.
            local hooksOk, hookName = SGWireFormats.verifyInstalled()
            if not hooksOk then controller:fail("STREAM_HOOK_CHANGED", hookName) end
            local zeroGround = mission.terrainDetailHeightId == nil or mission.terrainDetailHeightId == 0
            local ready = controller:freeze(g_fillTypeManager, g_densityMapHeightManager, mapId, channelsNow(), FillTypeManager.SEND_NUM_BITS, zeroGround)
            if not ready then
                if not controller.completionDone then
                    controller.completionDone = true
                    controller:presentFailure(mission)
                end
                return
            end
            -- Outer READY guard around the CURRENT callable when it is neither
            -- the sizing guard nor an outer guard already installed (no
            -- identical wrapper on later missions).
            if FillTypeManager.addFillType ~= SGCapacity._addFillTypeGuard and FillTypeManager.addFillType ~= SGCapacity._outerGuard then
                local current = FillTypeManager.addFillType
                SGCapacity._outerGuard = function(self, desc)
                    if controller:isReady() then
                        log("late fill type registration refused after freeze: " .. tostring(desc and desc.name))
                        return false
                    end
                    return current(self, desc)
                end
                SGCapacity._outerGuardInstalls = (SGCapacity._outerGuardInstalls or 0) + 1
                FillTypeManager.addFillType = SGCapacity._outerGuard
            end
            SGWireFormats.install(controller)
            if mission.stockGuard ~= nil then mission.stockGuard.capacity = controller end
            return superFunc(mission, ...)
        end)
    end

    -- Admission header on the finished-loading event, both directions.
    if BaseMissionFinishedLoadingEvent ~= nil then
        local nativeWrite = BaseMissionFinishedLoadingEvent.writeStream
        BaseMissionFinishedLoadingEvent.writeStream = function(self, streamId, connection)
            nativeWrite(self, streamId, connection)
            local h = controller:getHeader()
            if h ~= nil then
                SGCanonicalProfile.writeHeader(streamId, h)
            else
                -- A peer that is not READY sends a zero header the server will refuse.
                SGCanonicalProfile.writeHeader(streamId, { version = 0, widthBits = 0, registeredCount = 0, formatFlags = 0, digest = (function() local z = {} for i = 1, 32 do z[i] = 0 end return z end)() })
            end
        end
        BaseMissionFinishedLoadingEvent.readStream = function(self, streamId, connection)
            self.posX = streamReadFloat32(streamId)
            self.posY = streamReadFloat32(streamId)
            self.posZ = streamReadFloat32(streamId)
            self.viewDistanceCoeff = streamReadFloat32(streamId)
            local header = SGCanonicalProfile.readHeader(streamId)
            local ok, component = controller:admit(connection, header)
            if not ok then
                log("join refused before object synchronization: profile component '" .. tostring(component) .. "' differs")
                -- force = true: a refused join never reached setIsReadyForEvents
                -- (FSBaseMission.lua:742), and Connection:sendEvent sends only
                -- when ready or forced (network/Connection.lua:75), as the native
                -- refusals do (FSBaseMission.lua:473).
                if connection ~= nil and connection.sendEvent ~= nil and ConnectionRequestAnswerEvent ~= nil then
                    pcall(function() connection:sendEvent(ConnectionRequestAnswerEvent.new(SGCapacity.ANSWER_PROFILE_MISMATCH), nil, true) end)
                end
                if g_server ~= nil and connection ~= nil then pcall(function() g_server:closeConnection(connection) end) end
                return
            end
            self:run(connection)
        end
    end

    -- The static answer 8: the client shows the component-level message and
    -- tears down once, without the native reconnect half.
    if ConnectionRequestAnswerEvent ~= nil then
        ConnectionRequestAnswerEvent.ANSWER_SG6_PROFILE_MISMATCH = SGCapacity.ANSWER_PROFILE_MISMATCH
    end
    if FSBaseMission ~= nil and type(FSBaseMission.onConnectionRequestAnswer) == "function" then
        FSBaseMission.onConnectionRequestAnswer = Utils.overwrittenFunction(FSBaseMission.onConnectionRequestAnswer, function(mission, superFunc, connection, answer, ...)
            if answer == SGCapacity.ANSWER_PROFILE_MISMATCH then
                mission.connectionWasClosed = true
                local key = "sg6_profile_mismatch"
                local text = (g_i18n ~= nil and g_i18n:getText(key)) or key
                if text == key or text == "" then text = "StockGuard: the material and map capacity profile differs from the server. Obtain the matching setup and consult the host log." end
                local function teardown() if OnInGameMenuMenu ~= nil then OnInGameMenuMenu() end end
                if InfoDialog ~= nil and InfoDialog.INSTANCE ~= nil then InfoDialog.show(text, teardown, nil) else log(text) teardown() end
                return
            end
            return superFunc(mission, connection, answer, ...)
        end)
    end
    return true
end
