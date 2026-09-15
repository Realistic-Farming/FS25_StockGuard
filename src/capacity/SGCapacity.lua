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
-- THE SPLIT (Tyson, 2026-09-15): this build binds only what the decompiled
-- engine scripts on D: supply. The brief's third-party adapters cite sources
-- on E: which is unreachable here, so they are declared as a seam and left
-- unbound: a selection that includes one of those packages is refused at
-- preflight, exactly as the brief's unknown-writer rule requires, and their
-- integrationFlags bits stay 0. See UNBOUND_ADAPTERS below; the follow-up
-- branch binds them by their real sources.
--
-- Engine seams (D:\FS25_Decoded\dataS\scripts_decompiled):
--   FillTypeManager SEND_NUM_BITS :6, loadMapData :65, unloadMapData :98,
--     addFillType :203 (index = #fillTypes + 1, refuses at 2^bits - 1)
--   Mission00:setMissionInfo mission00.lua:98 (queues map tasks); cancelLoading
--     read by the next task; OnInGameMenuMenu menu.lua:66 (flush + teardown)
--   DensityMapHeightManager sortHeightTypes :187, loadFromXMLFile lowercase
--     tipTypeMappings :150-164, initialize :350 (overlap warning :378),
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

-- The adapter seam. Each record names a package family the brief binds by an
-- E:-sourced adapter. None is bound in this build (bound = false), so a
-- selection that includes one is refused at preflight with UNBOUND_ADAPTER
-- and the package name; the follow-up branch sets bound = true per record
-- and supplies its floor or stream tail through SGWireFormats.registerTail.
SGCapacity.UNBOUND_ADAPTERS = {
    { key = "productionControl", pattern = "productioncontrol", flagBit = 1, bound = false },
    { key = "pumpsAndHoses",     pattern = "pumpsandhoses",     flagBit = 2, bound = false },
    { key = "realSilo",          pattern = "realsilo",          flagBit = 4, bound = false },
    { key = "unlimitedFillTypes", pattern = "unlimitedfilltypes", floorBits = 12, bound = false },
    { key = "fillTypeExtender",  pattern = "filltypeextender",  floorBits = 9,  bound = false },
    { key = "distributionRedux", pattern = "distribution",      floorBits = 10, bound = false },
    { key = "realisticLivestock", pattern = "realisticlivestock", floorBits = 10, bound = false },
}
SGCapacity.SOIL_MOD_NAME = "FS25_SoilFertilizer"

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
    }
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
    local cur = (isInt(currentWidth) and currentWidth >= SGCapacity.MIN_WIDTH and currentWidth <= SGCapacity.MAX_WIDTH) and currentWidth or SGCapacity.MIN_WIDTH
    local floor = self.externalStartupFloor or SGCapacity.MIN_WIDTH
    local b = math.max(cur, floor, SGCapacity.MIN_WIDTH, SGCapacity.requiredWidth(nextIndex))
    if nextIndex > 2 ^ b - 1 or b > SGCapacity.MAX_WIDTH then return nil, "CAPACITY" end
    if nextIndex > self.consumerBound or nextIndex > SGCapacity.FRAMING_BOUND then return nil, "CAPACITY" end
    return b, "ADMITTED"
end

--- Map-data entry: capture the external floor (valid 8..15) before growth.
function SGCapacity:onMapDataEntry(currentWidth)
    if self.nextLoadIncompatible ~= nil then
        self:fail(self.nextLoadIncompatible.reason, self.nextLoadIncompatible.offending)
        self.nextLoadIncompatible = nil
        return
    end
    if isInt(currentWidth) and currentWidth >= SGCapacity.MIN_WIDTH and currentWidth <= SGCapacity.MAX_WIDTH then
        if self.externalStartupFloor == nil or currentWidth > self.externalStartupFloor then
            self.externalStartupFloor = currentWidth
        end
    end
    self.widthBits = math.max(self.externalStartupFloor or SGCapacity.MIN_WIDTH, SGCapacity.MIN_WIDTH)
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
    self.admitted = {}
    self.noticeIssued, self.completionDone = false, false
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
function SGCapacity:preflight(mission, missionDynamicInfo, resolveSoil)
    if type(mission) ~= "table" then return false, "INVALID_MISSION", nil end
    self.mission = mission
    local names = modNamesOf(missionDynamicInfo)
    for _, n in ipairs(names) do
        local lower = string.lower(n)
        for _, a in ipairs(SGCapacity.UNBOUND_ADAPTERS) do
            if not a.bound and lower:find(a.pattern, 1, true) ~= nil then
                return false, "UNBOUND_ADAPTER", n
            end
        end
    end
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
        self.integrationFlags = SGCanonicalProfile.FLAG_SOIL_GROUND_PREP
    end
    return true, "OK", nil
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
function SGCapacity:freeze(fillManager, heightManager, mapId, channels, currentWidth)
    if self.phase == SGCapacity.PHASE_FAILED then return false end
    if self.widthBits ~= nil and currentWidth ~= self.widthBits then return self:fail("WIDTH_CHANGED", tostring(currentWidth)) end
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

function SGCapacity:refuseConnection(what, why)
    self.lastWireRefusal = { what = what, why = why }
    log(string.format("wire refusal: %s (%s); no partial material update applied", tostring(what), tostring(why)))
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
local hooksInstalled = false
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
    if hooksInstalled then return true end
    hooksInstalled = true

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
            controller:onMapDataEntry(FillTypeManager.SEND_NUM_BITS)
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
            -- FAILED: native initialize is skipped; completion happens at finished loading.
        end)
    end

    -- Final freeze and the failure-completion site.
    if FSBaseMission ~= nil and type(FSBaseMission.onFinishedLoading) == "function" then
        FSBaseMission.onFinishedLoading = Utils.overwrittenFunction(FSBaseMission.onFinishedLoading, function(mission, superFunc, ...)
            local mapId = mission.missionInfo and mission.missionInfo.mapId or nil
            local ready = controller:freeze(g_fillTypeManager, g_densityMapHeightManager, mapId, channelsNow(), FillTypeManager.SEND_NUM_BITS)
            if not ready then
                if not controller.completionDone then
                    controller.completionDone = true
                    controller:presentFailure(mission)
                end
                return
            end
            -- Outer READY guard around the CURRENT callable if it is not already ours.
            if FillTypeManager.addFillType ~= SGCapacity._addFillTypeGuard then
                local current = FillTypeManager.addFillType
                FillTypeManager.addFillType = function(self, desc)
                    if controller:isReady() then
                        log("late fill type registration refused after freeze: " .. tostring(desc and desc.name))
                        return false
                    end
                    return current(self, desc)
                end
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
                if connection ~= nil and connection.sendEvent ~= nil and ConnectionRequestAnswerEvent ~= nil then
                    pcall(function() connection:sendEvent(ConnectionRequestAnswerEvent.new(SGCapacity.ANSWER_PROFILE_MISMATCH)) end)
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
