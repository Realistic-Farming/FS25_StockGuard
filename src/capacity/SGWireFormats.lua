-- =========================================================
-- FS25_StockGuard - format 2 material wire pairs (SG-6)
-- =========================================================
-- Installed at final freeze when the session is READY. Each pair replaces a
-- native read/write pair whole, preserving the original superclass call,
-- direction and dirty guards, and widening only what the profile's format
-- flags say: UInt16 material counts (SellingStation price lists,
-- ProductionPoint direct-sell and auto-deliver lists) and the self-describing
-- Storage payload (UInt16 entryCount, ascending frozen-width ids, present
-- Bool, Float32 level when present). Native indices stay UIntN(final width).
--
-- Readers stage a complete list into temporaries and validate it before any
-- setter runs; duplicate or unknown ids, unsupported counts or a set that
-- differs from the receiver's own supported set apply nothing.
--
-- Native bodies mirrored (D:\FS25_Decoded\dataS\scripts_decompiled):
--   SellingStation read/write(Update)Stream objects/SellingStation.lua:146-205
--   ProductionPoint readStream :412 / writeStream :449 (the two leading lists)
--   Storage read/writeStream :169/:179, read/writeUpdateStream :189/:201,
--     setFillLevel :287
-- The adapter seam: SGWireFormats.registerTail(owner, spec) lets a named
-- stream-tail adapter (ProductionControl and the Pumps N' Hoses sandbox
-- pairs) compose after the widened parent. No adapter is bound in this
-- build; see SGCapacity.UNBOUND_ADAPTERS.
-- =========================================================

SGWireFormats = SGWireFormats or {}

SGWireFormats.COUNT_BOUND = 32767

local function isInt(n) return type(n) == "number" and n == math.floor(n) and n == n end
local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- =========================================================
-- Pure validation helpers (bench-covered)
-- =========================================================

--- A material count is within the UInt16 field, the finite bound and the registry.
function SGWireFormats.countValid(count, registeredCount)
    return isInt(count) and count >= 0 and count <= SGWireFormats.COUNT_BOUND
        and (registeredCount == nil or count <= registeredCount)
end

--- A native fill index is a valid registered id within the frozen width.
function SGWireFormats.idValid(id, widthBits, registeredCount)
    return isInt(id) and id >= 1 and id < 2 ^ widthBits and (registeredCount == nil or id <= registeredCount)
end

--- Validate a staged Storage list against the receiver's own sorted set.
--- entries: array of { id, present, level }. Returns ok, reason.
function SGWireFormats.validateStorageFrame(entries, count, supported, widthBits, registeredCount)
    if not SGWireFormats.countValid(count, registeredCount) then return false, "INVALID_COUNT" end
    if type(entries) ~= "table" or #entries ~= count then return false, "INVALID_COUNT" end
    if type(supported) ~= "table" or #supported ~= count then return false, "SET_MISMATCH" end
    local prev = 0
    for i, e in ipairs(entries) do
        if not SGWireFormats.idValid(e.id, widthBits, registeredCount) or e.id <= prev then return false, "INVALID_ID" end
        if e.id ~= supported[i] then return false, "SET_MISMATCH" end
        if e.present and (not isFinite(e.level) or e.level < 0) then return false, "INVALID_LEVEL" end
        prev = e.id
    end
    return true, nil
end

--- Validate a staged price or output list. rows: array of { id, ... }.
function SGWireFormats.validateIdList(rows, count, widthBits, registeredCount)
    if not SGWireFormats.countValid(count, registeredCount) then return false, "INVALID_COUNT" end
    if type(rows) ~= "table" or #rows ~= count then return false, "INVALID_COUNT" end
    local seen = {}
    for _, r in ipairs(rows) do
        if not SGWireFormats.idValid(r.id, widthBits, registeredCount) or seen[r.id] then return false, "INVALID_ID" end
        seen[r.id] = true
    end
    return true, nil
end

-- =========================================================
-- Installation (native classes, once per process, active only when READY)
-- =========================================================
local installed = false
local ctl = nil   -- the capacity controller (width and registry facts)

local function width() return ctl ~= nil and ctl:getFrozenWidth() or FillTypeManager.SEND_NUM_BITS end
local function registered() return ctl ~= nil and ctl:getFrozenRegisteredCount() or nil end
local function active() return ctl ~= nil and ctl:isReady() end
local function refuse(what, why)
    if ctl ~= nil then ctl:refuseConnection(what, why) end
end

--- Bind the controller and replace the native pairs. Safe to call once.
function SGWireFormats.install(controller)
    ctl = controller
    if installed then return true end
    if SellingStation == nil or ProductionPoint == nil or Storage == nil then return false end
    installed = true

    -- ---------------- SellingStation ----------------
    local function writePriceList(self, streamId)
        local rows = {}
        for fillType, _ in pairs(self.acceptedFillTypes) do
            if self.originalFillTypePrices[fillType] > 0 then rows[#rows + 1] = { id = fillType } end
        end
        table.sort(rows, function(a, b) return a.id < b.id end)
        local ok = SGWireFormats.validateIdList(rows, #rows, width(), registered())
        if not ok then rows = {} end
        streamWriteUInt16(streamId, #rows)
        for _, r in ipairs(rows) do
            streamWriteUIntN(streamId, r.id, width())
            local price = math.floor(self:getEffectiveFillTypePrice(r.id) * 1000 + 0.5)
            streamWriteUInt16(streamId, (math.min(price, 65535)))
            streamWriteUIntN(streamId, self:getCurrentPricingTrend(r.id), 6)
        end
    end
    local function readPriceList(self, streamId)
        local count = streamReadUInt16(streamId)
        local rows = {}
        local safeCount = math.min(count, SGWireFormats.COUNT_BOUND)
        for _ = 1, safeCount do
            rows[#rows + 1] = { id = streamReadUIntN(streamId, width()), price = streamReadUInt16(streamId) / 1000, info = streamReadUIntN(streamId, 6) }
        end
        local ok, why = SGWireFormats.validateIdList(rows, count, width(), registered())
        if not ok then refuse("SellingStation price list", why) return end
        for _, r in ipairs(rows) do
            self.fillTypePrices[r.id] = r.price
            self.fillTypePriceInfo[r.id] = r.info
        end
    end
    local sellRead, sellWrite = SellingStation.readStream, SellingStation.writeStream
    local sellReadU, sellWriteU = SellingStation.readUpdateStream, SellingStation.writeUpdateStream
    SellingStation.readStream = function(self, streamId, connection)
        if not active() then return sellRead(self, streamId, connection) end
        local moneyTypeId = streamReadUInt16(streamId)
        self.moneyChangeType = MoneyType.registerWithId(moneyTypeId, "soldMaterials", "finance_other")
        SellingStation:superClass().readStream(self, streamId, connection)
        if connection:getIsServer() then readPriceList(self, streamId) end
    end
    SellingStation.writeStream = function(self, streamId, connection)
        if not active() then return sellWrite(self, streamId, connection) end
        streamWriteUInt16(streamId, self.moneyChangeType.id)
        SellingStation:superClass().writeStream(self, streamId, connection)
        if not connection:getIsServer() then writePriceList(self, streamId) end
    end
    SellingStation.readUpdateStream = function(self, streamId, timestamp, connection)
        if not active() then return sellReadU(self, streamId, timestamp, connection) end
        SellingStation:superClass().readUpdateStream(self, streamId, timestamp, connection)
        if connection:getIsServer() and streamReadBool(streamId) then readPriceList(self, streamId) end
    end
    SellingStation.writeUpdateStream = function(self, streamId, connection, dirtyMask)
        if not active() then return sellWriteU(self, streamId, connection, dirtyMask) end
        SellingStation:superClass().writeUpdateStream(self, streamId, connection, dirtyMask)
        if not connection:getIsServer() then
            local flag = self.unloadingStationDirtyFlag
            if streamWriteBool(streamId, bit32.band(dirtyMask, flag) ~= 0) then writePriceList(self, streamId) end
        end
    end

    -- ---------------- ProductionPoint (two leading lists) ----------------
    local prodRead, prodWrite = ProductionPoint.readStream, ProductionPoint.writeStream
    local function writeIdSet(streamId, set)
        local rows = {}
        for id in pairs(set) do rows[#rows + 1] = { id = id } end
        table.sort(rows, function(a, b) return a.id < b.id end)
        if not SGWireFormats.validateIdList(rows, #rows, width(), registered()) then rows = {} end
        streamWriteUInt16(streamId, #rows)
        for _, r in ipairs(rows) do streamWriteUIntN(streamId, r.id, width()) end
    end
    local function readIdSet(streamId, what)
        local count = streamReadUInt16(streamId)
        local rows = {}
        for _ = 1, math.min(count, SGWireFormats.COUNT_BOUND) do rows[#rows + 1] = { id = streamReadUIntN(streamId, width()) } end
        local ok, why = SGWireFormats.validateIdList(rows, count, width(), registered())
        if not ok then refuse(what, why) return nil end
        return rows
    end
    ProductionPoint.readStream = function(self, streamId, connection)
        if not active() then return prodRead(self, streamId, connection) end
        ProductionPoint:superClass().readStream(self, streamId, connection)
        if connection:getIsServer() then
            local sell = readIdSet(streamId, "ProductionPoint direct-sell list")
            local deliver = readIdSet(streamId, "ProductionPoint auto-deliver list")
            if sell ~= nil and deliver ~= nil then
                for _, r in ipairs(sell) do self:setOutputDistributionMode(r.id, ProductionPoint.OUTPUT_MODE.DIRECT_SELL, true) end
                for _, r in ipairs(deliver) do self:setOutputDistributionMode(r.id, ProductionPoint.OUTPUT_MODE.AUTO_DELIVER, true) end
            end
            local unloadingStationId = NetworkUtil.readNodeObjectId(streamId)
            self.unloadingStation:readStream(streamId, connection)
            g_client:finishRegisterObject(self.unloadingStation, unloadingStationId)
            if self.loadingStation ~= nil then
                local id = NetworkUtil.readNodeObjectId(streamId)
                self.loadingStation:readStream(streamId, connection)
                g_client:finishRegisterObject(self.loadingStation, id)
            end
            local storageId = NetworkUtil.readNodeObjectId(streamId)
            self.storage:readStream(streamId, connection)
            g_client:finishRegisterObject(self.storage, storageId)
            local numActive = streamReadUInt8(streamId)
            for _ = 1, numActive do
                local productionIndex = streamReadUInt8(streamId)
                local production = self.productions[productionIndex]
                local productionStatus = streamReadUIntN(streamId, ProductionPoint.PROD_STATUS_NUM_BITS)
                if production ~= nil then
                    self:setProductionState(production.id, true, true)
                    self:setProductionStatus(production.id, productionStatus, true)
                end
            end
            self.palletLimitReached = streamReadBool(streamId)
        end
        SGWireFormats.runTails("ProductionPoint", "read", self, streamId, connection)
    end
    ProductionPoint.writeStream = function(self, streamId, connection)
        if not active() then return prodWrite(self, streamId, connection) end
        ProductionPoint:superClass().writeStream(self, streamId, connection)
        if not connection:getIsServer() then
            writeIdSet(streamId, self.outputFillTypeIdsDirectSell)
            writeIdSet(streamId, self.outputFillTypeIdsAutoDeliver)
            NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.unloadingStation))
            self.unloadingStation:writeStream(streamId, connection)
            g_server:registerObjectInStream(connection, self.unloadingStation)
            if self.loadingStation ~= nil then
                NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.loadingStation))
                self.loadingStation:writeStream(streamId, connection)
                g_server:registerObjectInStream(connection, self.loadingStation)
            end
            NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.storage))
            self.storage:writeStream(streamId, connection)
            g_server:registerObjectInStream(connection, self.storage)
            local activeRows = {}
            for index, production in ipairs(self.productions) do
                if self:getIsProductionEnabled(production.id) then activeRows[#activeRows + 1] = { index = index, id = production.id } end
            end
            streamWriteUInt8(streamId, math.min(#activeRows, 255))
            for i = 1, math.min(#activeRows, 255) do
                streamWriteUInt8(streamId, activeRows[i].index)
                streamWriteUIntN(streamId, self:getProductionStatus(activeRows[i].id), ProductionPoint.PROD_STATUS_NUM_BITS)
            end
            streamWriteBool(streamId, self.palletLimitReached == true)
        end
        SGWireFormats.runTails("ProductionPoint", "write", self, streamId, connection)
    end

    -- ---------------- Storage ----------------
    local stRead, stWrite = Storage.readStream, Storage.writeStream
    local stReadU, stWriteU = Storage.readUpdateStream, Storage.writeUpdateStream
    local function writeStoragePayload(self, streamId)
        local list = self.sortedFillTypes
        streamWriteUInt16(streamId, #list)
        for _, fillType in ipairs(list) do
            streamWriteUIntN(streamId, fillType, width())
            local level = self.fillLevels[fillType]
            if streamWriteBool(streamId, level > 0) then
                streamWriteFloat32(streamId, level)
                self.fillLevelsLastSynced[fillType] = level
            end
        end
    end
    local function readStoragePayload(self, streamId)
        local count = streamReadUInt16(streamId)
        local entries = {}
        for _ = 1, math.min(count, SGWireFormats.COUNT_BOUND) do
            local e = { id = streamReadUIntN(streamId, width()), present = streamReadBool(streamId) }
            if e.present then e.level = streamReadFloat32(streamId) end
            entries[#entries + 1] = e
        end
        local ok, why = SGWireFormats.validateStorageFrame(entries, count, self.sortedFillTypes, width(), registered())
        if not ok then refuse("Storage payload", why) return end
        for _, e in ipairs(entries) do self:setFillLevel(e.present and e.level or 0, e.id) end
    end
    Storage.readStream = function(self, streamId, connection)
        if not active() then return stRead(self, streamId, connection) end
        Storage:superClass().readStream(self, streamId, connection)
        readStoragePayload(self, streamId)
    end
    Storage.writeStream = function(self, streamId, connection)
        if not active() then return stWrite(self, streamId, connection) end
        Storage:superClass().writeStream(self, streamId, connection)
        writeStoragePayload(self, streamId)
    end
    Storage.readUpdateStream = function(self, streamId, timestamp, connection)
        if not active() then return stReadU(self, streamId, timestamp, connection) end
        Storage:superClass().readUpdateStream(self, streamId, timestamp, connection)
        if connection:getIsServer() and streamReadBool(streamId) then readStoragePayload(self, streamId) end
    end
    Storage.writeUpdateStream = function(self, streamId, connection, dirtyMask)
        if not active() then return stWriteU(self, streamId, connection, dirtyMask) end
        Storage:superClass().writeUpdateStream(self, streamId, connection, dirtyMask)
        if not connection:getIsServer() then
            local flag = self.storageDirtyFlag
            if streamWriteBool(streamId, bit32.band(dirtyMask, flag) ~= 0) then writeStoragePayload(self, streamId) end
        end
    end
    return true
end

-- =========================================================
-- Adapter seam: named stream tails composed once after the widened parent.
-- Unbound in this build; the registry exists so a follow-up branch can bind
-- ProductionControl and the Pumps N' Hoses sandbox pairs by their real
-- sources without touching the pairs above.
-- =========================================================
local tails = {}
function SGWireFormats.registerTail(owner, spec)
    if type(owner) ~= "string" or type(spec) ~= "table" then return false end
    tails[owner] = tails[owner] or {}
    tails[owner][#tails[owner] + 1] = spec
    return true
end
function SGWireFormats.runTails(owner, direction, obj, streamId, connection)
    local list = tails[owner]
    if list == nil then return end
    for _, spec in ipairs(list) do
        local fn = spec[direction]
        if type(fn) == "function" then pcall(fn, obj, streamId, connection) end
    end
end
function SGWireFormats.isInstalled() return installed end
