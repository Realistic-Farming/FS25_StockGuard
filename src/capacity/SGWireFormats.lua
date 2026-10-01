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
-- pairs) compose after the widened parent. No tail adapter is bound in this
-- build; see SGCapacity.ADAPTERS.
--
-- READY immutability: every pair re-reads the live width and registry count
-- before a frame and refuses the peer when either differs from the frozen
-- profile. verifyInstalled() reports a stream method that another mod
-- replaced after our install (checked at every freeze). A wrapper installed
-- BEFORE our first install is indistinguishable from the native callable
-- (Lua closures are opaque); that limit is reported to Design in the PR.
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
local ctl = nil   -- the capacity controller (width and registry facts)
-- Class.method -> the wrapper on the class (its SGClassHook trampoline, the same
-- function for the whole process). A mods-set change at the main menu re-sources this
-- file: into the SAME environment on console (mods.lua:483-485) but into a FRESH one on
-- PC (:482, :489-493), where this map and every flag start over. So install always
-- rebinds the records and refills the map from them (MAINTENANCE row 187).
SGWireFormats._ours = SGWireFormats._ours or {}
local ours = SGWireFormats._ours

local function width() return ctl ~= nil and ctl:getFrozenWidth() or FillTypeManager.SEND_NUM_BITS end
local function registered() return ctl ~= nil and ctl:getFrozenRegisteredCount() or nil end
local function refuse(what, why, connection)
    if ctl ~= nil then ctl:refuseConnection(what, why, connection) end
end

--- READY, and the live width and registry still equal the frozen profile.
--- Returns "active", "inactive" (not READY: the native pair runs) or
--- "refused" (READY but changed: the peer was refused, nothing is written or
--- applied).
local function liveState(connection, what)
    if ctl == nil or not ctl:isReady() then return "inactive" end
    if FillTypeManager ~= nil and FillTypeManager.SEND_NUM_BITS ~= ctl.widthBits then
        refuse(what, "WIDTH_CHANGED_AFTER_FREEZE", connection)
        return "refused"
    end
    local count = g_fillTypeManager ~= nil and type(g_fillTypeManager.fillTypes) == "table" and #g_fillTypeManager.fillTypes or nil
    if count ~= nil and count ~= ctl.registeredCount then
        refuse(what, "REGISTRY_CHANGED_AFTER_FREEZE", connection)
        return "refused"
    end
    return "active"
end
SGWireFormats.liveState = liveState

--- Bind the controller and replace the native pairs: one SGClassHook record per pair for
--- the process, rebound by every call, so the pairs that run are always this module's,
--- reading this controller, and never two stacked copies (MAINTENANCE row 187).
SGWireFormats.HOOK_ID = "wireFormats"
function SGWireFormats.install(controller)
    ctl = controller
    if SellingStation == nil or ProductionPoint == nil or Storage == nil then return false end
    SGWireFormats._installed = true
    local ID = SGWireFormats.HOOK_ID

    -- ---------------- SellingStation ----------------
    local function writePriceList(self, streamId, connection)
        local rows = {}
        for fillType, _ in pairs(self.acceptedFillTypes) do
            if self.originalFillTypePrices[fillType] > 0 then rows[#rows + 1] = { id = fillType } end
        end
        table.sort(rows, function(a, b) return a.id < b.id end)
        local ok, why = SGWireFormats.validateIdList(rows, #rows, width(), registered())
        if not ok then
            -- Never a truncated list: the peer is refused. The zero count that
            -- follows only keeps the closed stream well-formed.
            refuse("SellingStation price list (writer)", why, connection)
            rows = {}
        end
        streamWriteUInt16(streamId, #rows)
        for _, r in ipairs(rows) do
            streamWriteUIntN(streamId, r.id, width())
            local price = math.floor(self:getEffectiveFillTypePrice(r.id) * 1000 + 0.5)
            streamWriteUInt16(streamId, (math.min(price, 65535)))
            streamWriteUIntN(streamId, self:getCurrentPricingTrend(r.id), 6)
        end
    end
    local function readPriceList(self, streamId, connection)
        local count = streamReadUInt16(streamId)
        local rows = {}
        local safeCount = math.min(count, SGWireFormats.COUNT_BOUND)
        for _ = 1, safeCount do
            rows[#rows + 1] = { id = streamReadUIntN(streamId, width()), price = streamReadUInt16(streamId) / 1000, info = streamReadUIntN(streamId, 6) }
        end
        local ok, why = SGWireFormats.validateIdList(rows, count, width(), registered())
        if not ok then refuse("SellingStation price list", why, connection) return false end
        for _, r in ipairs(rows) do
            self.fillTypePrices[r.id] = r.price
            self.fillTypePriceInfo[r.id] = r.info
        end
        return true
    end
    SGClassHook.wrap(SellingStation, "readStream", ID, function(sellRead, self, streamId, connection)
        local st = liveState(connection, "SellingStation.readStream")
        if st == "inactive" then return sellRead(self, streamId, connection) end
        if st == "refused" then return end
        local moneyTypeId = streamReadUInt16(streamId)
        self.moneyChangeType = MoneyType.registerWithId(moneyTypeId, "soldMaterials", "finance_other")
        SellingStation:superClass().readStream(self, streamId, connection)
        if connection:getIsServer() then readPriceList(self, streamId, connection) end
    end, SGWireFormats)
    SGClassHook.wrap(SellingStation, "writeStream", ID, function(sellWrite, self, streamId, connection)
        local st = liveState(connection, "SellingStation.writeStream")
        if st == "inactive" then return sellWrite(self, streamId, connection) end
        if st == "refused" then return end
        streamWriteUInt16(streamId, self.moneyChangeType.id)
        SellingStation:superClass().writeStream(self, streamId, connection)
        if not connection:getIsServer() then writePriceList(self, streamId, connection) end
    end, SGWireFormats)
    SGClassHook.wrap(SellingStation, "readUpdateStream", ID, function(sellReadU, self, streamId, timestamp, connection)
        local st = liveState(connection, "SellingStation.readUpdateStream")
        if st == "inactive" then return sellReadU(self, streamId, timestamp, connection) end
        if st == "refused" then return end
        SellingStation:superClass().readUpdateStream(self, streamId, timestamp, connection)
        if connection:getIsServer() and streamReadBool(streamId) then readPriceList(self, streamId, connection) end
    end, SGWireFormats)
    SGClassHook.wrap(SellingStation, "writeUpdateStream", ID, function(sellWriteU, self, streamId, connection, dirtyMask)
        local st = liveState(connection, "SellingStation.writeUpdateStream")
        if st == "inactive" then return sellWriteU(self, streamId, connection, dirtyMask) end
        if st == "refused" then return end
        SellingStation:superClass().writeUpdateStream(self, streamId, connection, dirtyMask)
        if not connection:getIsServer() then
            local flag = self.unloadingStationDirtyFlag
            if streamWriteBool(streamId, bit32.band(dirtyMask, flag) ~= 0) then writePriceList(self, streamId, connection) end
        end
    end, SGWireFormats)
    ours["SellingStation.readStream"] = SGClassHook.record(SellingStation, "readStream", ID).wrapper
    ours["SellingStation.writeStream"] = SGClassHook.record(SellingStation, "writeStream", ID).wrapper
    ours["SellingStation.readUpdateStream"] = SGClassHook.record(SellingStation, "readUpdateStream", ID).wrapper
    ours["SellingStation.writeUpdateStream"] = SGClassHook.record(SellingStation, "writeUpdateStream", ID).wrapper

    -- ---------------- ProductionPoint (two leading lists) ----------------
    local function writeIdSet(streamId, set, connection, what)
        local rows = {}
        for id in pairs(set) do rows[#rows + 1] = { id = id } end
        table.sort(rows, function(a, b) return a.id < b.id end)
        local ok, why = SGWireFormats.validateIdList(rows, #rows, width(), registered())
        if not ok then
            refuse(what .. " (writer)", why, connection)
            rows = {}   -- alignment only; the peer has been refused
        end
        streamWriteUInt16(streamId, #rows)
        for _, r in ipairs(rows) do streamWriteUIntN(streamId, r.id, width()) end
    end
    local function readIdSet(streamId, what, connection)
        local count = streamReadUInt16(streamId)
        local rows = {}
        for _ = 1, math.min(count, SGWireFormats.COUNT_BOUND) do rows[#rows + 1] = { id = streamReadUIntN(streamId, width()) } end
        local ok, why = SGWireFormats.validateIdList(rows, count, width(), registered())
        if not ok then refuse(what, why, connection) return nil end
        return rows
    end
    SGClassHook.wrap(ProductionPoint, "readStream", ID, function(prodRead, self, streamId, connection)
        local st = liveState(connection, "ProductionPoint.readStream")
        if st == "inactive" then return prodRead(self, streamId, connection) end
        if st == "refused" then return end
        ProductionPoint:superClass().readStream(self, streamId, connection)
        if connection:getIsServer() then
            -- A refused list stops the read here: nothing after it is applied
            -- and the peer has been refused (a misaligned stream is never
            -- decoded further).
            local sell = readIdSet(streamId, "ProductionPoint direct-sell list", connection)
            if sell == nil then return end
            local deliver = readIdSet(streamId, "ProductionPoint auto-deliver list", connection)
            if deliver == nil then return end
            for _, r in ipairs(sell) do self:setOutputDistributionMode(r.id, ProductionPoint.OUTPUT_MODE.DIRECT_SELL, true) end
            for _, r in ipairs(deliver) do self:setOutputDistributionMode(r.id, ProductionPoint.OUTPUT_MODE.AUTO_DELIVER, true) end
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
    end, SGWireFormats)
    SGClassHook.wrap(ProductionPoint, "writeStream", ID, function(prodWrite, self, streamId, connection)
        local st = liveState(connection, "ProductionPoint.writeStream")
        if st == "inactive" then return prodWrite(self, streamId, connection) end
        if st == "refused" then return end
        ProductionPoint:superClass().writeStream(self, streamId, connection)
        if not connection:getIsServer() then
            writeIdSet(streamId, self.outputFillTypeIdsDirectSell, connection, "ProductionPoint direct-sell list")
            writeIdSet(streamId, self.outputFillTypeIdsAutoDeliver, connection, "ProductionPoint auto-deliver list")
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
            -- Native order: activeProductions, index and status per entry
            -- (objects/ProductionPoint.lua:471-476); the UInt8 count is the
            -- native contract, not widened here.
            local active = self.activeProductions or {}
            streamWriteUInt8(streamId, math.min(#active, 255))
            for i = 1, math.min(#active, 255) do
                streamWriteUInt8(streamId, active[i].index)
                streamWriteUIntN(streamId, active[i].status, ProductionPoint.PROD_STATUS_NUM_BITS)
            end
            streamWriteBool(streamId, self.palletLimitReached == true)
        end
        SGWireFormats.runTails("ProductionPoint", "write", self, streamId, connection)
    end, SGWireFormats)
    ours["ProductionPoint.readStream"] = SGClassHook.record(ProductionPoint, "readStream", ID).wrapper
    ours["ProductionPoint.writeStream"] = SGClassHook.record(ProductionPoint, "writeStream", ID).wrapper

    -- ---------------- Storage ----------------
    local function writeStoragePayload(self, streamId, connection)
        local list = self.sortedFillTypes
        -- Same validate-before-write rule as the list writers (brief 4.7): the
        -- object's own sorted set must be valid registered ids in ascending
        -- order within the frozen width, or the peer is refused.
        local rows = {}
        for i, fillType in ipairs(list) do rows[i] = { id = fillType, present = false } end
        local ok, why = SGWireFormats.validateStorageFrame(rows, #rows, list, width(), registered())
        if not ok then
            refuse("Storage payload (writer)", why, connection)
            streamWriteUInt16(streamId, 0)   -- alignment only; the peer has been refused
            return
        end
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
    local function readStoragePayload(self, streamId, connection)
        local count = streamReadUInt16(streamId)
        local entries = {}
        for _ = 1, math.min(count, SGWireFormats.COUNT_BOUND) do
            local e = { id = streamReadUIntN(streamId, width()), present = streamReadBool(streamId) }
            if e.present then e.level = streamReadFloat32(streamId) end
            entries[#entries + 1] = e
        end
        local ok, why = SGWireFormats.validateStorageFrame(entries, count, self.sortedFillTypes, width(), registered())
        if not ok then refuse("Storage payload", why, connection) return false end
        for _, e in ipairs(entries) do self:setFillLevel(e.present and e.level or 0, e.id) end
        return true
    end
    SGClassHook.wrap(Storage, "readStream", ID, function(stRead, self, streamId, connection)
        local st = liveState(connection, "Storage.readStream")
        if st == "inactive" then return stRead(self, streamId, connection) end
        if st == "refused" then return end
        Storage:superClass().readStream(self, streamId, connection)
        readStoragePayload(self, streamId, connection)
    end, SGWireFormats)
    SGClassHook.wrap(Storage, "writeStream", ID, function(stWrite, self, streamId, connection)
        local st = liveState(connection, "Storage.writeStream")
        if st == "inactive" then return stWrite(self, streamId, connection) end
        if st == "refused" then return end
        Storage:superClass().writeStream(self, streamId, connection)
        writeStoragePayload(self, streamId, connection)
    end, SGWireFormats)
    SGClassHook.wrap(Storage, "readUpdateStream", ID, function(stReadU, self, streamId, timestamp, connection)
        local st = liveState(connection, "Storage.readUpdateStream")
        if st == "inactive" then return stReadU(self, streamId, timestamp, connection) end
        if st == "refused" then return end
        Storage:superClass().readUpdateStream(self, streamId, timestamp, connection)
        if connection:getIsServer() and streamReadBool(streamId) then readStoragePayload(self, streamId, connection) end
    end, SGWireFormats)
    SGClassHook.wrap(Storage, "writeUpdateStream", ID, function(stWriteU, self, streamId, connection, dirtyMask)
        local st = liveState(connection, "Storage.writeUpdateStream")
        if st == "inactive" then return stWriteU(self, streamId, connection, dirtyMask) end
        if st == "refused" then return end
        Storage:superClass().writeUpdateStream(self, streamId, connection, dirtyMask)
        if not connection:getIsServer() then
            local flag = self.storageDirtyFlag
            if streamWriteBool(streamId, bit32.band(dirtyMask, flag) ~= 0) then writeStoragePayload(self, streamId, connection) end
        end
    end, SGWireFormats)
    ours["Storage.readStream"] = SGClassHook.record(Storage, "readStream", ID).wrapper
    ours["Storage.writeStream"] = SGClassHook.record(Storage, "writeStream", ID).wrapper
    ours["Storage.readUpdateStream"] = SGClassHook.record(Storage, "readUpdateStream", ID).wrapper
    ours["Storage.writeUpdateStream"] = SGClassHook.record(Storage, "writeUpdateStream", ID).wrapper
    return true
end

--- Every installed pair must still be the current callable; a replacement by
--- another mod after our install is an unclassified stream hook. Returns
--- true, or false and "Class.method". True before the first install.
function SGWireFormats.verifyInstalled()
    if not SGWireFormats._installed then return true, nil end
    local classes = { SellingStation = SellingStation, ProductionPoint = ProductionPoint, Storage = Storage }
    for name, fn in pairs(ours) do
        local cls, method = name:match("^(%w+)%.(%w+)$")
        local tbl = classes[cls]
        if tbl ~= nil and tbl[method] ~= fn then return false, name end
    end
    return true, nil
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
function SGWireFormats.isInstalled() return SGWireFormats._installed == true end
